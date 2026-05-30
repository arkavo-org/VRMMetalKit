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
/// The measurement drives AvatarSample_A into one of four stress poses
/// (`StressPoseFactory`), runs the SpringBone simulation headless with
/// deterministic 35 ms pacing (mirroring `SpringBoneRegressionTests` and
/// `HairHeadCollisionTests`), then measures how often a cloth joint's world
/// position lands *inside* the frozen skin-reference ORACLE
/// (`SkinReferenceOracle`).
///
/// The three reproduction tests use `augment: false` (today's coarse
/// colliders) and assert penetration EXISTS. The augmentation generator
/// (Tasks 6–8) does not exist yet, so `augment: true` currently yields the
/// same coarse colliders; these tests pin the coarse-collider bug and must
/// keep passing. The seated baseline merely records a value and asserts the
/// harness runs — it becomes a real over-subscription guard once the
/// generator lands (Task 7).
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
    /// chain whose name mentions hair / skirt / hood, EXCEPT the chain root
    /// (index 0), which is kinematically driven by its parent bone and thus
    /// intentionally exempt from collision response.
    @MainActor
    private func clothJointNodeIndices(_ model: VRMModel) -> [Int] {
        guard let springBone = model.springBone else { return [] }
        var indices: [Int] = []
        for spring in springBone.springs {
            let name = (spring.name ?? "").lowercased()
            guard name.contains("hair") || name.contains("skirt") || name.contains("hood") else {
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
        pose: StressPose,
        augment: Bool
    ) async throws -> (rate: Float, worst: Float) {
        let modelPath = getTestVRM10ModelPath()
        try requireFixture(modelPath, hint: testVRM10Filename)

        let options = VRMLoadingOptions(augmentSpringBoneColliders: augment)
        let model = try await VRMModel.load(
            from: URL(fileURLWithPath: modelPath),
            device: device,
            options: options
        )

        let oracle = try SkinReferenceOracle.load(named: "avatar_a_skin_reference")

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
            "AvatarSample_A must declare hair/skirt/hood spring chains with child joints")

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

    // MARK: - Reproduction tests (RED gate; pin augment:false = coarse)

    @MainActor
    func testLookUp_currentColliders_penetrate() async throws {
        let (rate, worst) = try await measurePenetrationRate(pose: .lookUp, augment: false)
        print("[#309 repro] lookUp current-collider penetration rate=\(rate) worst=\(worst)m")
        XCTAssertGreaterThan(rate, Self.maxPenetrationRate,
            "Expected look-up to penetrate the oracle with coarse colliders (rate \(rate), worst \(worst)m). If 0, the pose isn't driving hair to the brow or the oracle is too loose.")
    }

    /// NOTE: AvatarSample_A's only cloth chains are a short head-hugging
    /// Hair bob plus Hood/HoodString around the head/neck — there is no skirt
    /// and the hair never reaches the limbs. Measured arm world positions under
    /// this pose stay at X≈±0.08…0.14 while the hair centroid sits at X≈0.01
    /// over the head, so the penetration this reproduces is cloth-vs-head, not
    /// cloth-vs-arm. The assertion still pins a genuine coarse-collider body
    /// penetration that augmentation must fix; it does not claim arm contact.
    @MainActor
    func testArmsRaised_currentColliders_penetrate() async throws {
        let (rate, worst) = try await measurePenetrationRate(pose: .armsRaised, augment: false)
        print("[#309 repro] armsRaised current-collider penetration rate=\(rate) worst=\(worst)m")
        XCTAssertGreaterThan(rate, Self.maxPenetrationRate,
            "Expected arms-raised to leave cloth penetrating the body oracle with coarse colliders (rate \(rate), worst \(worst)m). On AvatarSample_A this is dominated by hair/hood-vs-head; the asset has no cloth long enough to reach the arms.")
    }

    /// See `testArmsRaised_currentColliders_penetrate` — same caveat. The
    /// crossed arms swing the hands to Z≈-0.48 at chest height, far from the
    /// head-level hair; the reproduced penetration is cloth-vs-head.
    @MainActor
    func testArmsCrossed_currentColliders_penetrate() async throws {
        let (rate, worst) = try await measurePenetrationRate(pose: .armsCrossed, augment: false)
        print("[#309 repro] armsCrossed current-collider penetration rate=\(rate) worst=\(worst)m")
        XCTAssertGreaterThan(rate, Self.maxPenetrationRate,
            "Expected arms-crossed to leave cloth penetrating the body oracle with coarse colliders (rate \(rate), worst \(worst)m). On AvatarSample_A this is dominated by hair/hood-vs-head; the asset has no cloth long enough to reach the arms.")
    }

    // MARK: - Seated baseline (records, never fails)

    @MainActor
    func testSeatedDeepFlexion_currentColliders_baseline() async throws {
        let (rate, worst) = try await measurePenetrationRate(pose: .seatedDeepFlexion, augment: false)
        print("[#309 baseline] seatedDeepFlexion current-collider penetration rate=\(rate) worst=\(worst)m")
        XCTAssertGreaterThanOrEqual(rate, 0)  // always true; documents the baseline, asserts the harness runs
    }
}
