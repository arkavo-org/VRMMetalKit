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

/// Regression: hair spring-bones must not penetrate the FRONT-SHOULDER /
/// deltoid volume during locomotion. The pocket between the midline torso
/// capsule and the upper-arm capsule's thin proximal cap (the arm shaft's
/// 0.22-fraction radius does not fill the deltoid bulge at the socket) was the
/// residual clip-through after the #372 torso/upper-arm set: hair draping
/// forward over the shoulder sank into the front shoulder. Guards the two
/// synthetic shoulder SPHERES `SpringBoneColliderAugmentor` appends at the
/// upperArm node origins (sphere buffer — capsule slot order untouched).
///
/// Measurement harness mirrors `HairChestPenetrationTests`
/// (AnimationPlayer + `drawOffscreenHeadless`, `synchronousSpringBone = true`,
/// 150 frames @ 30 fps). The oracle spheres are computed from the SKELETON via
/// the shared `SpringBoneBoneGeometry.shoulderSphere` helper (bind-pose radius,
/// node-anchored center) — the same math the augmentor uses, so the oracle and
/// the uploaded colliders cannot disagree about WHAT the sphere is; only about
/// whether the sim respects it. Each frame the center re-applies the upperArm
/// node's CURRENT world transform to the sphere's local offset.
///
/// Metric: a (frame × non-root hair joint) sample counts as penetration when
/// the joint center is MORE THAN 5 mm inside a shoulder sphere — the same
/// resting-contact margin the chest gate uses.
@MainActor
final class HairShoulderPenetrationTests: XCTestCase {

    private var device: MTLDevice!

    override func setUp() async throws {
        guard let d = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        device = d
    }

    /// >5 mm inside counts — mirrors HairChestPenetrationTests.
    private let penetrationMargin: Float = 0.005

    struct ShoulderPenetrationMeasurement {
        var totalSamples = 0
        var penetrations = 0        // center > 5 mm inside a sphere
        var rawPenetrations = 0     // center inside at all (d < r) — diagnostic only
        var nearSamples = 0         // distance < 2×radius of a center (non-vacuity)
        var worstDepth: Float = 0
        var syntheticCount = 0
        var breastTwinCount = 0     // #377 breast twins in the synthetic set (fixture-derived)
        var breastColliderCount = 0 // #377 mesh-fitted breast capsules (fixture-derived)
        var shoulderColliderCount = 0 // #377 mesh-fitted shoulder spheres (fixture-derived)
        var torsoColliderCount = 0    // #377 mesh-fitted upper-torso capsule (fixture-derived)
        var hairJoints = 0
        var rate: Float { totalSamples > 0 ? Float(penetrations) / Float(totalSamples) : 0 }
        var nearRate: Float { totalSamples > 0 ? Float(nearSamples) / Float(totalSamples) : 0 }
    }

    /// Loads `modelFile` with collider augmentation on/off, plays the locomotion
    /// clip, and measures the fraction of (frame × non-root hair joint) samples
    /// whose joint center is >5 mm inside either shoulder sphere.
    private func measureShoulderPenetration(
        modelFile: String, vrmaFile: String, augment: Bool
    ) async throws -> ShoulderPenetrationMeasurement {
        let modelPath = getTestModelPath(modelFile)
        let vrmaPath = getTestModelPath("VRMA_Locomotion_Pack/" + vrmaFile)
        try requireFixture(modelPath, hint: modelFile)
        try requireFixture(vrmaPath, hint: vrmaFile)

        let model = try await VRMModel.load(
            from: URL(fileURLWithPath: modelPath), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: augment))
        let clip = try VRMAnimationLoader.loadVRMA(from: URL(fileURLWithPath: vrmaPath), model: model)
        let player = AnimationPlayer()
        player.load(clip)
        player.play()

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        config.synchronousSpringBone = true  // see #267 — eliminates the 1-frame physics lag
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.enableSpringBone = true
        renderer.viewMatrix = matrix_identity_float4x4
        renderer.projectionMatrix = matrix_identity_float4x4

        let humanoid = try XCTUnwrap(model.humanoid, "fixture must rig a humanoid")
        let springBone = try XCTUnwrap(model.springBone, "fixture must declare spring bones")

        // Oracle spheres from the SKELETON in bind pose via the SHARED helper —
        // never from `springBone.syntheticColliders`.
        let ratios = SpringBoneColliderAugmentor.Ratios()
        var oracleSpheres: [(node: Int, offset: SIMD3<Float>, radius: Float)] = []
        for (upper, lower) in [(VRMHumanoidBone.leftUpperArm, VRMHumanoidBone.leftLowerArm),
                               (VRMHumanoidBone.rightUpperArm, VRMHumanoidBone.rightLowerArm)] {
            if let c = SpringBoneBoneGeometry.shoulderSphere(
                upperArmBone: upper, lowerArmBone: lower,
                radiusFraction: ratios.shoulderSphereRadiusFraction,
                downFraction: ratios.shoulderSphereDownFraction,
                humanoid: humanoid, model: model),
               case let .sphere(offset, radius) = c.shape {
                oracleSpheres.append((c.node, offset, radius))
            }
        }
        XCTAssertEqual(oracleSpheres.count, 2,
            "fixture must yield left + right shoulder oracle spheres")

        // Hair joints, excluding root joints (kinematically driven; collision
        // intentionally skips them per the VRM spec).
        var hairJointNodeIndices: [Int] = []
        for spring in springBone.springs {
            guard let name = spring.name, name.lowercased().contains("hair") else { continue }
            for (i, joint) in spring.joints.enumerated() where i > 0 {
                hairJointNodeIndices.append(joint.node)
            }
        }
        XCTAssertGreaterThan(hairJointNodeIndices.count, 0,
            "\(modelFile) must declare Hair spring chains with child joints")

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

        var m = ShoulderPenetrationMeasurement()
        m.syntheticCount = springBone.syntheticColliders.count
        m.breastTwinCount = SpringBoneBoneGeometry.breastTwinSpheres(humanoid: humanoid, model: model).count
        m.breastColliderCount = SpringBoneBreastCollider.computeBreastColliders(model: model).count
        m.shoulderColliderCount = SpringBoneBreastCollider.computeShoulderColliders(model: model).count
        m.torsoColliderCount = SpringBoneBreastCollider.computeTorsoCollider(model: model).count
        m.hairJoints = hairJointNodeIndices.count

        let fps: Float = 30
        let frameCount = 150
        let dt: Float = 1.0 / fps

        for frameIndex in 0..<frameCount {
            player.update(deltaTime: dt, model: model)

            guard let cb = queue.makeCommandBuffer() else {
                XCTFail("Could not create command buffer at frame \(frameIndex)")
                break
            }
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = colorTex
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.depthAttachment.texture = depthTex
            rpd.depthAttachment.loadAction = .clear
            rpd.depthAttachment.clearDepth = 1.0
            rpd.depthAttachment.storeAction = .dontCare
            renderer.drawOffscreenHeadless(
                to: colorTex, depth: depthTex, commandBuffer: cb, renderPassDescriptor: rpd)
            cb.commit()
            while cb.status != .completed && cb.status != .error { await Task.yield() }

            // World-space centers for THIS frame: re-apply the upperArm node's
            // CURRENT world transform to the local offset — the same math the
            // GPU collider upload path uses.
            var worldSpheres: [(center: SIMD3<Float>, r: Float)] = []
            for o in oracleSpheres {
                guard let node = model.nodes[safe: o.node] else { continue }
                let rot = SpringBoneBoneGeometry.upperLeft3x3(node.worldMatrix)
                worldSpheres.append((node.worldPosition + rot * o.offset, o.radius))
            }

            for nodeIdx in hairJointNodeIndices {
                guard let node = model.nodes[safe: nodeIdx] else { continue }
                let p = node.worldPosition
                m.totalSamples += 1
                var minClearance = Float.greatestFiniteMagnitude
                var minDistOverRadius = Float.greatestFiniteMagnitude
                for s in worldSpheres {
                    let d = simd_length(p - s.center)
                    minClearance = min(minClearance, d - s.r)
                    minDistOverRadius = min(minDistOverRadius, d / max(s.r, 1e-6))
                    if d < s.r { m.worstDepth = max(m.worstDepth, s.r - d) }
                }
                if minClearance < 0 { m.rawPenetrations += 1 }
                if minClearance < -penetrationMargin { m.penetrations += 1 }
                if minDistOverRadius < 2.0 { m.nearSamples += 1 }
            }
        }
        return m
    }

    /// Non-vacuity: the hair must actually COME NEAR the shoulder spheres over
    /// the clip, else the gate could pass on hair that never reaches a shoulder.
    private func assertNonVacuous(_ m: ShoulderPenetrationMeasurement, _ label: String) {
        XCTAssertGreaterThan(m.totalSamples, 0, "\(label): no hair-joint samples collected")
        XCTAssertGreaterThan(m.nearRate, 0.05,
            "\(label): only \(String(format: "%.1f%%", m.nearRate * 100)) of samples come within 2 radii of a shoulder-sphere center — the gate would be vacuous")
    }

    /// GATE: with augmentation ON, hair must stay out of the shoulder spheres
    /// (>5 mm deep) on at least 99% of samples, and the synthetic set must carry
    /// the two shoulder spheres (15 total: 4 leg + 1 brow + 2 arm→hand + 1 torso
    /// + 2 upper-arm capsules, 1 skull + 2 palm + 2 shoulder spheres).
    private func assertGate(modelFile: String) async throws {
        let m = try await measureShoulderPenetration(modelFile: modelFile, vrmaFile: "Walk.vrma", augment: true)
        print("[HairShoulder \(modelFile) ON] samples=\(m.totalSamples) joints=\(m.hairJoints) synth=\(m.syntheticCount) "
            + "rate=\(String(format: "%.2f%%", m.rate * 100)) raw=\(m.rawPenetrations) "
            + "near=\(String(format: "%.1f%%", m.nearRate * 100)) worst=\(String(format: "%.1f mm", m.worstDepth * 1000))")
        XCTAssertEqual(m.syntheticCount, 15 + m.breastTwinCount + m.breastColliderCount + m.shoulderColliderCount + m.torsoColliderCount,
            "augmentation must include the two shoulder spheres + \(m.breastTwinCount) breast twins + \(m.breastColliderCount) breast capsules (#377)")
        assertNonVacuous(m, modelFile)
        XCTAssertLessThan(m.rate, 0.01,
            "\(modelFile): hair penetrates a shoulder sphere >5mm on \(String(format: "%.1f%%", m.rate * 100)) of samples (expected < 1%). Worst: \(String(format: "%.1f mm", m.worstDepth * 1000))")
    }

    func testHairStaysOutOfShoulderSpheresDuringWalk_H() async throws {
        try await assertGate(modelFile: "AvatarSample_H_1.0.vrm")
    }

    func testHairStaysOutOfShoulderSpheresDuringWalk_A() async throws {
        try await assertGate(modelFile: testVRM10Filename)
    }

    /// DISCRIMINATOR: the SAME measurement with augmentation OFF must show
    /// materially MORE penetration against the SAME oracle spheres — proving the
    /// synthetic shoulder coverage is what keeps hair out of the front shoulder.
    ///
    /// Fixture choice: runs on A, not H. On Walk, A's hair drapes forward over
    /// the shoulders and genuinely sinks into the shoulder volume (unaugmented:
    /// 2.28% >5 mm, worst 30.1 mm, against this oracle; with the
    /// PRE-shoulder-sphere 13-collider set the socket-centered variant of this
    /// oracle measured 11.56% — the torso/upper-arm capsules demonstrably do
    /// NOT close this pocket), while H's hair barely reaches it. A's authored
    /// chest/breast spheres do not protect the shoulder either, so its off-run
    /// is an honest baseline.
    func testShoulderSpheresDiscriminatePenetration() async throws {
        let off = try await measureShoulderPenetration(
            modelFile: testVRM10Filename, vrmaFile: "Walk.vrma", augment: false)
        let on = try await measureShoulderPenetration(
            modelFile: testVRM10Filename, vrmaFile: "Walk.vrma", augment: true)
        print("[HairShoulder A discriminator] off=\(String(format: "%.2f%%", off.rate * 100)) (\(off.penetrations)/\(off.totalSamples), worst \(String(format: "%.1f mm", off.worstDepth * 1000))) "
            + "on=\(String(format: "%.2f%%", on.rate * 100)) (\(on.penetrations)/\(on.totalSamples), worst \(String(format: "%.1f mm", on.worstDepth * 1000)))")

        XCTAssertEqual(off.syntheticCount, 0, "augment-off run must have no synthetic colliders")
        XCTAssertEqual(on.syntheticCount, 15 + on.breastTwinCount + on.breastColliderCount + on.shoulderColliderCount + on.torsoColliderCount,
                       "augment-on run must carry 15 synthetic colliders + \(on.breastTwinCount) breast twins + \(on.breastColliderCount) breast capsules (#377)")
        assertNonVacuous(off, "A off")
        assertNonVacuous(on, "A on")

        // The off-run must actually suffer: 2.28% (worst 30.1 mm) measured
        // unaugmented against this oracle — a 1% floor proves the fixture/clip
        // still stresses the shoulder pocket without false-firing on jitter.
        XCTAssertGreaterThanOrEqual(off.rate, 0.01,
            "discriminator is vacuous: augment-off rate \(String(format: "%.2f%%", off.rate * 100)) < 1% — fixture/clip no longer stresses the shoulder volume (measured 2.28% when written)")
        XCTAssertLessThan(on.rate, off.rate / 4,
            "shoulder spheres not discriminating: on=\(String(format: "%.2f%%", on.rate * 100)) vs off=\(String(format: "%.2f%%", off.rate * 100)) — expected on < off/4")
    }
}
