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

/// Regression: hair spring-bones must not penetrate the chest/breast volume or
/// the upper arms during locomotion. Guards the synthetic torso capsule
/// (spine → upperChest ?? chest ?? neck) and the two upper-arm capsules
/// (upperArm → lowerArm) that `SpringBoneColliderAugmentor` appends in capsule
/// slots 7–9 — the own-body hair-protection gap left by the original #309 set.
///
/// Measurement harness mirrors `HairHeadCollisionTests.measureWalkPenetrationRate`
/// (AnimationPlayer + `drawOffscreenHeadless`, `synchronousSpringBone = true`,
/// 150 frames @ 30 fps). The oracle capsules are computed INDEPENDENTLY of the
/// augmentor's output: `SpringBoneContactColliderSet.torsoCollider(model:)` and
/// `SpringBoneBoneGeometry.limbCapsule(fromBone:toBone:radiusFraction:humanoid:model:)`
/// derive the same local-space, node-anchored geometry from the skeleton (bind
/// pose), and each frame `SpringBoneContactColliderSet.worldCapsule` re-applies
/// the CURRENT node world transform — the same math the GPU upload path uses.
///
/// Metric: a (frame × non-root hair joint) sample counts as penetration when the
/// joint center is MORE THAN 5 mm inside a capsule (distance to the capsule axis
/// < radius − 5 mm). The raw `d < radius` metric is NOT gated: the XPBD solver
/// parks resting contact a hair's breadth under the surface, so shallow `d < r`
/// samples persist even in fully-protected runs (augment-on raw rates measure
/// 0.3–5.3%). Depth past 5 mm is what reads as clip-through.
///
/// Measured on this tree (Walk.vrma, 150 frames):
///   H (AvatarSample_H_1.0.vrm):  off 7.82% (worst 83 mm)  →  on 0.00% (0/8850)
///   A (AvatarSample_A_1.0.vrm.glb): off 3.69% (worst 27 mm) → on 0.11% (4/3600)
///   (Run/Jog on A: off 1.92%/2.50% → on 0.03%/0.08%)
///
/// Fixture choice: AvatarSample_A also authors chest/breast spheres, so its
/// authored-only (augment-off) run is already partially protected — the off/on
/// gap is real (33×) but smaller. H has no such authored torso protection and is
/// the honest discriminator: its off-run penetrates deeply (7.8%, up to 83 mm)
/// and its on-run is clean, so the discriminator below can genuinely fail if the
/// synthetic capsules stop doing the work.
@MainActor
final class HairChestPenetrationTests: XCTestCase {

    private var device: MTLDevice!

    override func setUp() async throws {
        guard let d = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        device = d
    }

    /// How deep (past the capsule surface) a joint center must be to count:
    /// >5 mm inside. Mirrors the 5 mm margin in HairHeadCollisionTests.
    private let penetrationMargin: Float = 0.005

    struct TorsoPenetrationMeasurement {
        var totalSamples = 0
        var penetrations = 0        // center > 5 mm inside a capsule
        var rawPenetrations = 0     // center inside at all (d < r) — diagnostic only
        var nearSamples = 0         // axis distance < 2×radius (non-vacuity)
        var torsoPenetrations = 0   // raw, torso capsule only — diagnostic
        var armPenetrations = 0     // raw, either upper-arm capsule — diagnostic
        var worstDepth: Float = 0
        var syntheticCount = 0
        var breastTwinCount = 0     // #377 breast twins in the synthetic set (fixture-derived)
        var breastColliderCount = 0 // #377 mesh-fitted breast capsules (fixture-derived)
        var hairJoints = 0
        var rate: Float { totalSamples > 0 ? Float(penetrations) / Float(totalSamples) : 0 }
        var nearRate: Float { totalSamples > 0 ? Float(nearSamples) / Float(totalSamples) : 0 }
    }

    private func pointSegmentDistance(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let ab = b - a
        let len2 = simd_length_squared(ab)
        if len2 < 1e-12 { return simd_length(p - a) }
        let t = max(0, min(1, simd_dot(p - a, ab) / len2))
        return simd_length(p - (a + t * ab))
    }

    /// Loads `modelFile` with collider augmentation on/off, plays the locomotion
    /// clip, and measures the fraction of (frame × non-root hair joint) samples
    /// whose joint center is >5 mm inside the torso or an upper-arm capsule.
    private func measureTorsoPenetration(
        modelFile: String, vrmaFile: String, augment: Bool
    ) async throws -> TorsoPenetrationMeasurement {
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

        // Oracle capsules from the SKELETON in bind pose (node-anchored local
        // space) — never from `springBone.syntheticColliders`. Same fallback
        // chain and radius fractions the augmentor uses, via the shared geometry
        // helpers, so the oracle and the uploaded colliders cannot disagree
        // about WHAT the capsule is; only about whether the sim respects it.
        var localCapsules: [VRMCollider] = []
        if let torso = SpringBoneContactColliderSet.torsoCollider(model: model) {
            localCapsules.append(torso)
        }
        for (from, to) in [(VRMHumanoidBone.leftUpperArm, VRMHumanoidBone.leftLowerArm),
                           (VRMHumanoidBone.rightUpperArm, VRMHumanoidBone.rightLowerArm)] {
            if let c = SpringBoneBoneGeometry.limbCapsule(
                fromBone: from, toBone: to,
                radiusFraction: SpringBoneContactColliderSet.upperArmRadiusFractionOfLength,
                humanoid: humanoid, model: model) {
                localCapsules.append(c)
            }
        }
        XCTAssertEqual(localCapsules.count, 3,
            "fixture must yield torso + two upper-arm oracle capsules")

        // Hair joints, excluding root joints (kinematically driven by the head
        // bone; collision intentionally skips them per the VRM spec).
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

        var m = TorsoPenetrationMeasurement()
        m.syntheticCount = springBone.syntheticColliders.count
        m.breastTwinCount = SpringBoneBoneGeometry.breastTwinSpheres(humanoid: humanoid, model: model).count
        m.breastColliderCount = SpringBoneBreastCollider.computeBreastColliders(model: model).count
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

            // World-space oracle capsules for THIS frame (current node matrices,
            // re-applied per frame exactly like the GPU collider upload path).
            var worldCaps: [(p0: SIMD3<Float>, p1: SIMD3<Float>, r: Float)] = []
            for local in localCapsules {
                if let wc = SpringBoneContactColliderSet.worldCapsule(local, model: model) {
                    worldCaps.append((wc.p0, wc.p1, wc.radius))
                }
            }

            for nodeIdx in hairJointNodeIndices {
                guard let node = model.nodes[safe: nodeIdx] else { continue }
                let p = node.worldPosition
                m.totalSamples += 1
                var minClearance = Float.greatestFiniteMagnitude  // d_axis − r over all capsules
                var minAxisOverRadius = Float.greatestFiniteMagnitude
                for (i, c) in worldCaps.enumerated() {
                    let d = pointSegmentDistance(p, c.p0, c.p1)
                    minClearance = min(minClearance, d - c.r)
                    minAxisOverRadius = min(minAxisOverRadius, d / max(c.r, 1e-6))
                    if d < c.r {
                        if i == 0 { m.torsoPenetrations += 1 } else { m.armPenetrations += 1 }
                        m.worstDepth = max(m.worstDepth, c.r - d)
                    }
                }
                if minClearance < 0 { m.rawPenetrations += 1 }
                if minClearance < -penetrationMargin { m.penetrations += 1 }
                if minAxisOverRadius < 2.0 { m.nearSamples += 1 }
            }
        }
        return m
    }

    /// Non-vacuity: the measurement must have sampled hair joints that actually
    /// COME NEAR the protected volumes — otherwise a gate could pass because the
    /// hair simply never reaches the torso. Measured near-rates (within 2
    /// capsule-radii of an axis) are 40–75% across A/H/K/O × Walk; 5% is a floor
    /// that cannot pass on a far-away-hair accident but never false-fires here.
    private func assertNonVacuous(_ m: TorsoPenetrationMeasurement, _ label: String) {
        XCTAssertGreaterThan(m.totalSamples, 0, "\(label): no hair-joint samples collected")
        XCTAssertGreaterThan(m.nearRate, 0.05,
            "\(label): only \(String(format: "%.1f%%", m.nearRate * 100)) of samples come within 2 radii of a torso/upper-arm axis — the gate would be vacuous")
    }

    /// GATE: with augmentation ON, hair must stay out of the torso and upper-arm
    /// capsules (>5 mm deep) on at least 99% of samples. H measured 0.00%
    /// (0/8850) and A 0.11% (4/3600) — the 1% bound carries ~9× margin over the
    /// worst measured cell while tripping toward the 1.9–7.8% augment-off range.
    private func assertGate(modelFile: String, expectedBaseSynthetic: Int) async throws {
        let m = try await measureTorsoPenetration(modelFile: modelFile, vrmaFile: "Walk.vrma", augment: true)
        print("[HairChest \(modelFile) ON] samples=\(m.totalSamples) joints=\(m.hairJoints) synth=\(m.syntheticCount) "
            + "rate=\(String(format: "%.2f%%", m.rate * 100)) raw=\(m.rawPenetrations) "
            + "near=\(String(format: "%.1f%%", m.nearRate * 100)) worst=\(String(format: "%.1f mm", m.worstDepth * 1000))")
        XCTAssertEqual(m.syntheticCount, expectedBaseSynthetic + m.breastTwinCount + m.breastColliderCount,
            "augmentation must be active in the gated run (\(expectedBaseSynthetic) base + \(m.breastTwinCount) #377 breast twins + \(m.breastColliderCount) breast capsules)")
        assertNonVacuous(m, modelFile)
        XCTAssertLessThan(m.rate, 0.01,
            "\(modelFile): hair penetrates a torso/upper-arm capsule >5mm on \(String(format: "%.1f%%", m.rate * 100)) of samples (expected < 1%; augment-off baseline for this fixture is 3.7–7.8%). Worst: \(String(format: "%.1f mm", m.worstDepth * 1000))")
    }

    func testHairStaysOutOfTorsoAndUpperArmCapsulesDuringWalk_H() async throws {
        try await assertGate(modelFile: "AvatarSample_H_1.0.vrm", expectedBaseSynthetic: 15)
    }

    func testHairStaysOutOfTorsoAndUpperArmCapsulesDuringWalk_A() async throws {
        try await assertGate(modelFile: testVRM10Filename, expectedBaseSynthetic: 15)
    }

    /// DISCRIMINATOR (anti-vacuity for the gate itself): the SAME measurement
    /// with `augmentSpringBoneColliders: false` must show materially MORE
    /// penetration against the SAME oracle capsules — proving the synthetic
    /// torso/upper-arm capsules are what keeps the hair out, not something the
    /// authored asset already guaranteed. Runs on H: A's authored chest/breast
    /// spheres already protect its off-run (3.69%), while H's off-run penetrates
    /// deeply (7.82%, worst 83 mm), so both assertions below can genuinely fail:
    /// if the synthetic capsules were dropped from the upload or lost their
    /// group-mask bit, the on-run would climb to the off-run's rate.
    func testSyntheticTorsoCapsulesDiscriminatePenetration() async throws {
        let off = try await measureTorsoPenetration(
            modelFile: "AvatarSample_H_1.0.vrm", vrmaFile: "Walk.vrma", augment: false)
        let on = try await measureTorsoPenetration(
            modelFile: "AvatarSample_H_1.0.vrm", vrmaFile: "Walk.vrma", augment: true)
        print("[HairChest H discriminator] off=\(String(format: "%.2f%%", off.rate * 100)) (\(off.penetrations)/\(off.totalSamples), worst \(String(format: "%.1f mm", off.worstDepth * 1000))) "
            + "on=\(String(format: "%.2f%%", on.rate * 100)) (\(on.penetrations)/\(on.totalSamples), worst \(String(format: "%.1f mm", on.worstDepth * 1000)))")

        XCTAssertEqual(off.syntheticCount, 0, "augment-off run must have no synthetic colliders")
        XCTAssertEqual(on.syntheticCount, 15 + on.breastTwinCount + on.breastColliderCount,
                       "augment-on run must carry 15 synthetic colliders + \(on.breastTwinCount) breast twins + \(on.breastColliderCount) breast capsules (#377)")
        assertNonVacuous(off, "H off")
        assertNonVacuous(on, "H on")

        // The off-run must actually suffer: an absolute floor (measured 7.82%)
        // proves the fixture/clip genuinely stresses the chest/upper-arm volume —
        // without it, a "no difference" result could pass vacuously on a clip
        // where hair never reaches the torso.
        XCTAssertGreaterThanOrEqual(off.rate, 0.015,
            "discriminator is vacuous: augment-off rate \(String(format: "%.2f%%", off.rate * 100)) < 1.5% — fixture/clip no longer stresses the torso capsules (measured 7.82% when written)")
        // And the on-run must be materially better: 4× lower (measured: 7.82% →
        // 0.00%). Trips if the synthetic capsules lose effect (rates converge).
        XCTAssertLessThan(on.rate, off.rate / 4,
            "synthetic capsules not discriminating: on=\(String(format: "%.2f%%", on.rate * 100)) vs off=\(String(format: "%.2f%%", off.rate * 100)) — expected on < off/4")
    }
}
