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

/// Regression for #377 — hair must not pierce the FRONT of the authored
/// chest/breast spheres. The discrete inside-sphere push-out is entry-blind: a
/// hair joint that tunnels in near the collarbone and drifts past the sphere
/// centre is ejected radially out the FRONT of the breast mesh. The fix (A′)
/// emits a synthetic SWEPT twin co-located with each authored chest/upperChest/
/// spine sphere; because synthetic colliders are the only group the compute path
/// sweeps, the twin clamps the fast tunnel-in at the entry surface before the
/// strand can settle inside and get lofted through the front.
///
/// The twins matter specifically at the OFFSET breast spheres (VRoid authors two
/// `J_Bip_C_UpperChest` spheres at ±x): the synthetic midline torso capsule
/// (`HairChestPenetrationTests`) covers the central trunk but NOT the breast
/// bulge, so that bulge only gets swept coverage from the twins.
///
/// Metric: oracle = the authored chest/upperChest/spine spheres (re-projected to
/// world each frame, the same math the GPU upload path uses). A (frame × non-root
/// hair joint) sample is a `deepInside` when the joint centre is MORE THAN 5 mm
/// inside an authored chest sphere — the settled-inside precursor to the visible
/// front-pierce. A fast greeting/wave emote (mirroring the #377 host reproducer)
/// throws front hair at the chest; the swept twins must keep the deep-inside rate
/// negligible.
@MainActor
final class HairChestFrontPierceTests: XCTestCase {

    private var device: MTLDevice!

    override func setUp() async throws {
        guard let d = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        device = d
    }

    private let penetrationMargin: Float = 0.005

    struct FrontPierceMeasurement {
        var totalSamples = 0
        var deepInside = 0          // joint centre > 5 mm inside an authored chest sphere
        var rawInside = 0           // centre inside at all (diagnostic)
        var worstDepth: Float = 0   // deepest joint-centre penetration (m)
        var segTotal = 0
        var segDeep = 0             // strand SEGMENT spans an authored chest sphere >5 mm
        var segWorst: Float = 0     // deepest segment penetration (m)
        var syntheticCount = 0
        var breastTwinCount = 0
        var authoredChestSpheres = 0
        var hairJoints = 0
        var rate: Float { totalSamples > 0 ? Float(deepInside) / Float(totalSamples) : 0 }
        var segRate: Float { segTotal > 0 ? Float(segDeep) / Float(segTotal) : 0 }
    }

    /// Shortest distance from point `p` to segment [a,b].
    private func pointSegmentDistance(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let ab = b - a
        let len2 = simd_length_squared(ab)
        if len2 < 1e-12 { return simd_length(p - a) }
        let t = max(0, min(1, simd_dot(p - a, ab) / len2))
        return simd_length(p - (a + t * ab))
    }

    /// Authored chest/upperChest/spine (+ VRoid `*_Bust`/`*_Breast`) OUTSIDE
    /// spheres — the same predicate `SpringBoneBoneGeometry.breastTwinSpheres`
    /// twins. Returned in LOCAL space (node, offset, radius); world-projected per
    /// frame by the caller.
    private func authoredChestSpheres(model: VRMModel, humanoid: VRMHumanoid)
        -> [(node: Int, offset: SIMD3<Float>, radius: Float)] {
        let chestNodes = Set([VRMHumanoidBone.chest, .upperChest, .spine]
            .compactMap { humanoid.getBoneNode($0) })
        var out: [(node: Int, offset: SIMD3<Float>, radius: Float)] = []
        for c in model.springBone?.colliders ?? [] {
            guard c.node >= 0, c.node < model.nodes.count else { continue }
            let name = (model.nodes[c.node].name ?? "").lowercased()
            let isBust = name.contains("bust") || name.contains("breast")
            guard chestNodes.contains(c.node) || isBust else { continue }
            if case let .sphere(off, r) = c.shape { out.append((c.node, off, r)) }
        }
        return out
    }

    private func measureFrontPierce(
        modelFile: String, vrmaRelPath: String, augment: Bool
    ) async throws -> FrontPierceMeasurement {
        let modelPath = getTestModelPath(modelFile)
        let vrmaPath = getTestModelPath(vrmaRelPath)
        try requireFixture(modelPath, hint: modelFile)
        try requireFixture(vrmaPath, hint: vrmaRelPath)

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
        config.synchronousSpringBone = true
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.enableSpringBone = true
        renderer.springBoneQuality = .ultra
        renderer.viewMatrix = matrix_identity_float4x4
        renderer.projectionMatrix = matrix_identity_float4x4

        let humanoid = try XCTUnwrap(model.humanoid, "fixture must rig a humanoid")
        let springBone = try XCTUnwrap(model.springBone, "fixture must declare spring bones")

        let oracle = authoredChestSpheres(model: model, humanoid: humanoid)
        XCTAssertFalse(oracle.isEmpty, "\(modelFile) must author chest spheres for the #377 oracle")

        var hairJointNodeIndices: [Int] = []
        var hairSegments: [(a: Int, b: Int)] = []
        for spring in springBone.springs {
            guard let name = spring.name, name.lowercased().contains("hair") else { continue }
            for (i, joint) in spring.joints.enumerated() where i > 0 {
                hairJointNodeIndices.append(joint.node)
                hairSegments.append((spring.joints[i - 1].node, joint.node))
            }
        }
        XCTAssertGreaterThan(hairJointNodeIndices.count, 0,
            "\(modelFile) must declare Hair spring chains with child joints")

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]; colorDesc.storageMode = .private
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: 64, height: 64, mipmapped: false)
        depthDesc.usage = .renderTarget; depthDesc.storageMode = .private
        guard let colorTex = device.makeTexture(descriptor: colorDesc),
              let depthTex = device.makeTexture(descriptor: depthDesc),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Could not allocate Metal resources")
        }

        var m = FrontPierceMeasurement()
        m.syntheticCount = springBone.syntheticColliders.count
        m.breastTwinCount = SpringBoneBoneGeometry.breastTwinSpheres(humanoid: humanoid, model: model).count
        m.authoredChestSpheres = oracle.count
        m.hairJoints = hairJointNodeIndices.count

        for _ in 0..<200 {
            player.update(deltaTime: 1.0 / 30.0, model: model)
            guard let cb = queue.makeCommandBuffer() else { break }
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = colorTex
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.depthAttachment.texture = depthTex
            rpd.depthAttachment.loadAction = .clear
            rpd.depthAttachment.clearDepth = 1.0
            rpd.depthAttachment.storeAction = .dontCare
            renderer.drawOffscreenHeadless(to: colorTex, depth: depthTex, commandBuffer: cb, renderPassDescriptor: rpd)
            cb.commit()
            while cb.status != .completed && cb.status != .error { await Task.yield() }

            // World-project the authored chest spheres this frame (node world
            // transform × local offset), the same math the upload path uses.
            var worldSpheres: [(center: SIMD3<Float>, r: Float)] = []
            for o in oracle {
                guard o.node < model.nodes.count else { continue }
                let node = model.nodes[o.node]
                let rot = SpringBoneBoneGeometry.upperLeft3x3(node.worldMatrix)
                worldSpheres.append((node.worldPosition + rot * o.offset, o.radius))
            }
            for jn in hairJointNodeIndices {
                guard jn < model.nodes.count else { continue }
                let p = model.nodes[jn].worldPosition
                m.totalSamples += 1
                for s in worldSpheres {
                    let d = simd_length(p - s.center)
                    let depth = s.r - d               // >0 ⇒ inside
                    if depth > 0 { m.rawInside += 1 }
                    if depth > penetrationMargin {
                        m.deepInside += 1
                        if depth > m.worstDepth { m.worstDepth = depth }
                    }
                }
            }

            // Segment-spanning (#376 leading indicator): a strand SEGMENT can cut
            // the sphere while BOTH endpoint joints stay legal (outside). The
            // joint-centre metric above cannot see this; the twins' swept
            // entry-clamp cannot cure it either (it acts on joints, not segments).
            for seg in hairSegments {
                guard seg.a < model.nodes.count, seg.b < model.nodes.count else { continue }
                let pa = model.nodes[seg.a].worldPosition
                let pb = model.nodes[seg.b].worldPosition
                m.segTotal += 1
                for s in worldSpheres {
                    let depth = s.r - pointSegmentDistance(s.center, pa, pb)
                    if depth > penetrationMargin {
                        m.segDeep += 1
                        if depth > m.segWorst { m.segWorst = depth }
                    }
                }
            }
        }
        return m
    }

    /// GATE: with augmentation ON, hair must stay OUT of the authored chest
    /// spheres — no joint centre and no strand segment more than 5 mm inside —
    /// during a fast greeting emote that (augment OFF) drives front hair into the
    /// chest. This guards that the swept synthetic torso capsule + the #377 breast
    /// twins keep the trunk-front clear, so the entry-blind discrete push-out
    /// never gets a deep-inside joint to eject out the front.
    ///
    /// Measured baseline (AvatarSample_A × Action_Greeting, 200 f):
    ///   augment OFF: joint ≈ 0.3 % (worst ≈ 8 mm), segment ≈ 0.3 %
    ///   augment ON : joint 0.00 %, segment 0.00 %
    /// The OFF baseline is printed (non-gating) as the discriminator signal.
    func testAugmentationKeepsHairOutOfAuthoredChestSpheres_A() async throws {
        let emote = "VRMA_Avatar_Mega_Pack/Action_Greeting.vrma"
        try requireFixture(getTestModelPath(emote), hint: emote)

        let on = try await measureFrontPierce(modelFile: testVRM10Filename, vrmaRelPath: emote, augment: true)
        let off = try await measureFrontPierce(modelFile: testVRM10Filename, vrmaRelPath: emote, augment: false)
        print(String(format: "[FrontPierce A greet] OFF joint=%.2f%%/seg=%.2f%% (worst %.1f/%.1f mm)  ON joint=%.2f%%/seg=%.2f%% synth=%d twins=%d chest=%d",
            off.rate * 100, off.segRate * 100, off.worstDepth * 1000, off.segWorst * 1000,
            on.rate * 100, on.segRate * 100, on.syntheticCount, on.breastTwinCount, on.authoredChestSpheres))

        XCTAssertGreaterThan(on.breastTwinCount, 0, "fixture must author chest spheres to twin")
        // Non-vacuity: the emote must genuinely bring hair near the chest.
        XCTAssertGreaterThan(on.rawInside + off.rawInside, 0,
            "greet emote must drive hair into contact with the chest spheres")
        XCTAssertEqual(on.deepInside, 0,
            "augment ON: no hair joint may sit >5 mm inside an authored chest sphere (#377)")
        XCTAssertEqual(on.segDeep, 0,
            "augment ON: no hair segment may span an authored chest sphere >5 mm (#377)")
    }
}
