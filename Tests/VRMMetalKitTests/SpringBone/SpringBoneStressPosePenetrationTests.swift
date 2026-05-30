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

    /// AvatarSample_U cloth-vs-body reproduction under arms-raised.
    ///
    /// EMPIRICAL FINDING (#309, measured via UPenetrationDiagnostic): U's Skirt
    /// and Sleeve spring chains do NOT reproduce limb (arm/leg) penetration with
    /// tight measured limb capsules, because each is parented to the very limb it
    /// covers — `SkirtBack`→upperLeg, `Sleeve`→lowerArm/hand — so it rides
    /// rigidly with that limb and settles to a fixed offset OUTSIDE the skin
    /// (nearest sleeve→arm stays +0.022 m across all sensible poses). The
    /// penetration this test pins is U's long 7-joint body `Hair` chain clipping
    /// the skull-sphere oracle (worst ≈ 0.039 m), a genuine coarse-collider body
    /// penetration of the same class as A's `lookUp`. It is pose-independent here
    /// (the hair is head-driven), so this and the seated test reproduce the same
    /// hair-vs-head manifestation; the arm/leg manifestation could not be driven
    /// on this asset without loosening the oracle (which we refuse to do).
    @MainActor
    func testU_armsRaised_currentColliders_penetrate() async throws {
        let (rate, worst) = try await measurePenetrationRate(
            modelPath: getTestModelPath("AvatarSample_U_1.0.vrm.glb"),
            oracleName: "avatar_u_skin_reference",
            pose: .armsRaised, augment: false)
        print("[#309 repro] U armsRaised current-collider penetration rate=\(rate) worst=\(worst)m")
        XCTAssertGreaterThan(rate, Self.maxPenetrationRate,
            "Expected U cloth (hair) to penetrate the body oracle with coarse colliders (rate \(rate), worst \(worst)m). Measured penetration is hair-vs-skull; U's limb-parented Skirt/Sleeve ride with their limbs and do not clip the arm/leg capsules.")
    }

    /// AvatarSample_U cloth-vs-body reproduction under seated deep flexion.
    /// See `testU_armsRaised_currentColliders_penetrate` for the empirical
    /// finding: the skirt does NOT reach the legs (its panels splay outward and
    /// the back panels ride with the thigh), so the reproduced penetration is
    /// again the head-driven `Hair` chain vs the skull sphere (≈ 0.039 m).
    @MainActor
    func testU_seatedDeepFlexion_currentColliders_penetrate() async throws {
        let (rate, worst) = try await measurePenetrationRate(
            modelPath: getTestModelPath("AvatarSample_U_1.0.vrm.glb"),
            oracleName: "avatar_u_skin_reference",
            pose: .seatedDeepFlexion, augment: false)
        print("[#309 repro] U seatedDeepFlexion current-collider penetration rate=\(rate) worst=\(worst)m")
        XCTAssertGreaterThan(rate, Self.maxPenetrationRate,
            "Expected U cloth (hair) to penetrate the body oracle with coarse colliders (rate \(rate), worst \(worst)m). Measured penetration is hair-vs-skull; U's Skirt does not reach the leg capsules under seated flexion.")
    }
}
