//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Reproduction gate for #309: hair/cloth SpringBone joints clip through the
/// avatar's body under static stress poses because the shipped colliders are
/// too coarse.
///
/// Two complementary reproductions, both asserting penetration of the frozen
/// skin-reference ORACLE (`SkinReferenceOracle`) with `augment: false` (today's
/// coarse colliders):
///
///  1. `testLookUp` — AvatarSample_A held in a static look-up pose
///     (`StressPoseFactory`), measured via `measurePenetrationRate` over a
///     settle window with deterministic 35 ms pacing. Reproduces the PERSISTENT
///     hair→forehead sink (#309 manifestation 1).
///  2. `testU_armSwing` / `testU_legMarch` — AvatarSample_U driven through fast
///     oscillating limb motion (`DynamicPoseFactory`) on a fixed `1/60 s`
///     timestep (`simulationDeltaTime`, no wall-clock pacing), measured via
///     `measurePeakLimbPenetration` for PEAK penetration of the LIMB-ONLY
///     oracle shapes across the whole motion. Reproduces the MOTION-TRANSIENT
///     sleeve/hair→arm and skirt→leg clipping (#309 manifestations 2/3) that
///     static poses cannot surface.
///
/// The augmentation generator (Tasks 6–8) does not exist yet, so `augment:
/// true` currently yields the same coarse colliders; these tests pin the
/// coarse-collider bug and must keep passing (`augment: false` is wired so they
/// stay valid once augmentation ships default-on).
final class SpringBoneStressPosePenetrationTests: XCTestCase {

    private static let minFrameIntervalNanos: UInt64 = 35_000_000
    private static let frameCount = 150
    private static let fps: Float = 30
    private static let penetrationTolerance: Float = 0.005   // 5 mm
    private static let maxPenetrationRate: Float = 0.01

    private var device: MTLDevice!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    // MARK: - Cloth joint discovery

    /// Cloth joints whose penetration we measure: every joint of any spring
    /// chain whose name mentions hair / skirt / hood / sleeve, EXCEPT the chain
    /// root (index 0), which is kinematically driven by its parent bone and thus
    /// intentionally exempt from collision response. AvatarSample_U adds
    /// `Sleeve` chains at arm height, so "sleeve" is included here.
    @MainActor
    private func clothJointNodeIndices(_ model: VRMModel) -> [Int] {
        guard let springBone = model.springBone else { return [] }
        var indices: [Int] = []
        for spring in springBone.springs {
            let name = (spring.name ?? "").lowercased()
            guard name.contains("hair") || name.contains("skirt")
                || name.contains("hood") || name.contains("sleeve") else {
                continue
            }
            for (i, joint) in spring.joints.enumerated() where i > 0 {
                indices.append(joint.node)
            }
        }
        return indices
    }

    // MARK: - Measurement harness

    @MainActor
    private func measurePenetrationRate(
        modelPath: String,
        oracleName: String,
        pose: StressPose,
        augment: Bool
    ) async throws -> (rate: Float, worst: Float) {
        try requireFixture(modelPath, hint: (modelPath as NSString).lastPathComponent)

        let options = VRMLoadingOptions(augmentSpringBoneColliders: augment)
        let model = try await VRMModel.load(
            from: URL(fileURLWithPath: modelPath),
            device: device,
            options: options
        )

        let oracle = try SkinReferenceOracle.load(named: oracleName)

        // Drive the static stress pose.
        let clip = StressPoseFactory.clip(pose, duration: Float(Self.frameCount) / Self.fps)
        let player = AnimationPlayer()
        player.load(clip)
        player.play()

        // Renderer setup mirrored from HairHeadCollisionTests, with
        // synchronousSpringBone (see #267) for deterministic physics.
        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        config.synchronousSpringBone = true
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.enableSpringBone = true
        renderer.viewMatrix = matrix_identity_float4x4
        renderer.projectionMatrix = matrix_identity_float4x4

        let clothJoints = clothJointNodeIndices(model)
        XCTAssertFalse(clothJoints.isEmpty,
            "Model must declare hair/skirt/hood/sleeve spring chains with child joints")

        // Offscreen render target (we only need the spring-bone update path).
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .private
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: 64, height: 64, mipmapped: false)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private
        guard let colorTex = device.makeTexture(descriptor: colorDesc),
              let depthTex = device.makeTexture(descriptor: depthDesc),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Could not allocate Metal resources")
        }

        let dt: Float = 1.0 / Self.fps
        let measureFromFrame = Self.frameCount / 2

        var totalSamples = 0
        var penetrationSamples = 0
        var worstPenetration: Float = 0

        for frameIndex in 0..<Self.frameCount {
            // Pin the renderer's wall-clock spring deltaTime to its 1/30 s
            // clamp by holding ≥ 35 ms before each render. Skipped on frame 0
            // (renderer uses its 1/60 s default when lastUpdateTime is zero).
            if frameIndex > 0 {
                try await Task.sleep(nanoseconds: Self.minFrameIntervalNanos)
            }

            player.update(deltaTime: dt, model: model)

            guard let cb = queue.makeCommandBuffer() else {
                XCTFail("Could not create command buffer at frame \(frameIndex)")
                break
            }
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = colorTex
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            rpd.colorAttachments[0].storeAction = .store
            rpd.depthAttachment.texture = depthTex
            rpd.depthAttachment.loadAction = .clear
            rpd.depthAttachment.clearDepth = 1.0
            rpd.depthAttachment.storeAction = .dontCare
            renderer.drawOffscreenHeadless(
                to: colorTex, depth: depthTex,
                commandBuffer: cb, renderPassDescriptor: rpd)
            cb.commit()
            while cb.status != .completed && cb.status != .error { await Task.yield() }

            // Only measure after the pose has settled (second half).
            guard frameIndex >= measureFromFrame else { continue }

            let shapes = oracle.resolveWorldShapes(model: model)
            for nodeIdx in clothJoints {
                guard nodeIdx >= 0, nodeIdx < model.nodes.count else { continue }
                let p = model.nodes[nodeIdx].worldPosition
                let pen = SkinReferenceOracle.worstPenetration(of: p, shapes: shapes)
                totalSamples += 1
                if pen > Self.penetrationTolerance {
                    penetrationSamples += 1
                    if pen > worstPenetration { worstPenetration = pen }
                }
            }
        }

        XCTAssertGreaterThan(totalSamples, 0, "No penetration samples collected")
        let rate = totalSamples > 0 ? Float(penetrationSamples) / Float(totalSamples) : 0
        return (rate, worstPenetration)
    }

    // MARK: - Dynamic peak-penetration harness (#309 motion-transient repro)

    /// Drives a fast OSCILLATING clip through the SpringBone simulation and, on
    /// EVERY frame across the whole motion, measures how far cloth joints
    /// (hair/skirt/hood/sleeve, root joints exempt) penetrate the LIMB-ONLY
    /// oracle. Returns the global peak depth, the count of frames in which any
    /// cloth joint penetrated > 5 mm, and the total frame count.
    ///
    /// Determinism: uses the renderer's fixed-timestep path. With
    /// `synchronousSpringBone = true` and an explicit `simulationDeltaTime`, the
    /// integrator gets the same delta every render call regardless of wall clock
    /// (see DeterministicRendering.docc), so NO `Task.sleep` pacing is needed.
    @MainActor
    private func measurePeakLimbPenetration(
        modelPath: String,
        oracleName: String,
        clip: AnimationClip,
        augment: Bool
    ) async throws -> (peak: Float, penetratingFrames: Int, totalFrames: Int) {
        try requireFixture(modelPath, hint: (modelPath as NSString).lastPathComponent)

        let options = VRMLoadingOptions(augmentSpringBoneColliders: augment)
        let model = try await VRMModel.load(
            from: URL(fileURLWithPath: modelPath),
            device: device,
            options: options
        )

        let oracle = try SkinReferenceOracle.load(named: oracleName)

        let player = AnimationPlayer()
        player.load(clip)
        player.play()

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        config.synchronousSpringBone = true
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.enableSpringBone = true
        renderer.viewMatrix = matrix_identity_float4x4
        renderer.projectionMatrix = matrix_identity_float4x4

        // Fixed 1/60 s timestep, fed identically to physics and animation. No
        // wall-clock sleep — fully deterministic under fast motion.
        let dt: Float = 1.0 / 60.0
        renderer.simulationDeltaTime = TimeInterval(dt)

        let clothJoints = clothJointNodeIndices(model)
        XCTAssertFalse(clothJoints.isEmpty,
            "Model must declare hair/skirt/hood/sleeve spring chains with child joints")

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .private
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: 64, height: 64, mipmapped: false)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private
        guard let colorTex = device.makeTexture(descriptor: colorDesc),
              let depthTex = device.makeTexture(descriptor: depthDesc),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Could not allocate Metal resources")
        }

        let totalFrames = 180   // 3 s at 60 fps
        var peak: Float = 0
        var closest = Float.greatestFiniteMagnitude
        var penetratingFrames = 0

        for frameIndex in 0..<totalFrames {
            player.update(deltaTime: dt, model: model)

            guard let cb = queue.makeCommandBuffer() else {
                XCTFail("Could not create command buffer at frame \(frameIndex)")
                break
            }
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = colorTex
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            rpd.colorAttachments[0].storeAction = .store
            rpd.depthAttachment.texture = depthTex
            rpd.depthAttachment.loadAction = .clear
            rpd.depthAttachment.clearDepth = 1.0
            rpd.depthAttachment.storeAction = .dontCare
            renderer.drawOffscreenHeadless(
                to: colorTex, depth: depthTex,
                commandBuffer: cb, renderPassDescriptor: rpd)
            cb.commit()
            while cb.status != .completed && cb.status != .error { await Task.yield() }

            let shapes = oracle.resolveLimbWorldShapes(model: model)
            guard !shapes.isEmpty else { continue }
            var framePenetrated = false
            for nodeIdx in clothJoints {
                guard nodeIdx >= 0, nodeIdx < model.nodes.count else { continue }
                let p = model.nodes[nodeIdx].worldPosition
                let pen = SkinReferenceOracle.worstPenetration(of: p, shapes: shapes)
                if pen > peak { peak = pen }
                if pen > Self.penetrationTolerance { framePenetrated = true }
                if pen <= 0 {
                    let near = SkinReferenceOracle.closestApproach(of: p, shapes: shapes)
                    if near < closest { closest = near }
                }
            }
            if framePenetrated { penetratingFrames += 1 }
        }

        if peak <= Self.penetrationTolerance, closest < Float.greatestFiniteMagnitude {
            print("[#309 repro] closest cloth→limb approach=\(closest)m (no >5mm penetration)")
        }
        return (peak, penetratingFrames, totalFrames)
    }

    // MARK: - Reproduction tests (RED gate; pin augment:false = coarse)

    /// AvatarSample_A head reproduction: the short head-hugging Hair/Hood chains
    /// clip into the skull/brow oracle when the head tips back. A has no
    /// limb-reaching cloth, so this is the only A penetration manifestation; the
    /// arm/leg manifestations live on AvatarSample_U below.
    @MainActor
    func testLookUp_currentColliders_penetrate() async throws {
        let (rate, worst) = try await measurePenetrationRate(
            modelPath: getTestVRM10ModelPath(),
            oracleName: "avatar_a_skin_reference",
            pose: .lookUp, augment: false)
        print("[#309 repro] A lookUp current-collider penetration rate=\(rate) worst=\(worst)m")
        XCTAssertGreaterThan(rate, Self.maxPenetrationRate,
            "Expected look-up to penetrate the oracle with coarse colliders (rate \(rate), worst \(worst)m). If 0, the pose isn't driving hair to the brow or the oracle is too loose.")
    }

    // MARK: - Dynamic U limb reproduction (#309 motion-transient manifestations)

    /// AvatarSample_U sleeve/hair vs ARM oracle under a fast oscillating arm
    /// swing. U's Sleeve chain is parented to the limb it covers, so a STATIC
    /// pose lets it settle OUTSIDE the arm capsule (nearest +0.022 m). A fast
    /// swing makes the trailing spring-bone cloth LAG and transiently dip into
    /// the arm for a few frames before recovering — manifestation 2 of #309.
    @MainActor
    func testU_armSwing_currentColliders_penetrateArm() async throws {
        let (peak, frames, total) = try await measurePeakLimbPenetration(
            modelPath: getTestModelPath("AvatarSample_U_1.0.vrm.glb"),
            oracleName: "avatar_u_skin_reference",
            clip: DynamicPoseFactory.armSwingFast(), augment: false)
        print("[#309 repro] U armSwing current-collider LIMB peak=\(peak)m frames=\(frames)/\(total)")
        XCTAssertGreaterThan(peak, 0.005,
            "Expected sleeve/hair to transiently penetrate the ARM oracle during a fast arm swing with coarse colliders (peak \(peak)m over \(frames)/\(total) frames).")
    }

    /// AvatarSample_U skirt vs LEG oracle under a fast oscillating knee-raise
    /// march. Manifestation 3 of #309. See the report: the skirt hangs well
    /// outside the tight leg capsule even when the thigh drives up into it, so
    /// this may NOT reproduce; the harness prints the closest approach.
    @MainActor
    func testU_legMarch_currentColliders_penetrateLeg() async throws {
        let (peak, frames, total) = try await measurePeakLimbPenetration(
            modelPath: getTestModelPath("AvatarSample_U_1.0.vrm.glb"),
            oracleName: "avatar_u_skin_reference",
            clip: DynamicPoseFactory.legMarchFast(), augment: false)
        print("[#309 repro] U legMarch current-collider LIMB peak=\(peak)m frames=\(frames)/\(total)")
        XCTAssertGreaterThan(peak, 0.005,
            "Expected skirt to transiently penetrate the LEG oracle during a fast leg march with coarse colliders (peak \(peak)m over \(frames)/\(total) frames).")
    }
}
