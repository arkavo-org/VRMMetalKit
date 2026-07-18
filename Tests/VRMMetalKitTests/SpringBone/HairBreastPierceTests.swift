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

/// #377 — hair must not pierce the forward breast MESH. The visible breast rides
/// forward on the spring `Bust` bones, far beyond the authored/synthetic chest
/// colliders; this measures hair-joint penetration into the per-side breast
/// bounding sphere fitted to the skinned mesh (`SpringBoneBreastCollider`),
/// which the authored chest colliders do NOT cover.
@MainActor
final class HairBreastPierceTests: XCTestCase {

    private var device: MTLDevice!
    private let margin: Float = 0.005

    override func setUp() async throws {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device not available") }
        device = d
    }

    struct BreastPierce {
        var total = 0
        var deep = 0
        var worst: Float = 0
        var spheres = 0
        var rate: Float { total > 0 ? Float(deep) / Float(total) : 0 }
    }

    private func measure(modelPath: String, vrmaPath: String,
                         quality: VRMConstants.SpringBoneQuality = .ultra) async throws -> BreastPierce {
        try requireFixture(modelPath, hint: modelPath)
        try requireFixture(vrmaPath, hint: vrmaPath)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: modelPath), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        let clip = try VRMAnimationLoader.loadVRMA(from: URL(fileURLWithPath: vrmaPath), model: model)
        let player = AnimationPlayer(); player.load(clip); player.play()

        var config = RendererConfig()
        config.sampleCount = 1; config.strict = .off; config.synchronousSpringBone = true
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.enableSpringBone = true
        renderer.springBoneQuality = quality
        renderer.viewMatrix = matrix_identity_float4x4
        renderer.projectionMatrix = matrix_identity_float4x4

        let springBone = try XCTUnwrap(model.springBone)

        // Oracle: per-side breast surface fitted to the skinned mesh at a FIXED
        // 0.95 percentile — the measuring stick, independent of whatever radius
        // the load-path collider is tuned to (so tuning can't move the target).
        let breast = SpringBoneBreastCollider.computeBreastSpheres(model: model, radiusPercentile: 0.95)
        for b in breast {
            print(String(format: "[BreastPierce fit] node=%d offset=(%.3f,%.3f,%.3f) r=%.4f",
                b.node, b.offset.x, b.offset.y, b.offset.z, b.radius))
        }

        var hairJoints: [Int] = []
        for spring in springBone.springs where (spring.name ?? "").lowercased().contains("hair") {
            for (i, joint) in spring.joints.enumerated() where i > 0 { hairJoints.append(joint.node) }
        }

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]; colorDesc.storageMode = .private
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 64, height: 64, mipmapped: false)
        depthDesc.usage = .renderTarget; depthDesc.storageMode = .private
        guard let colorTex = device.makeTexture(descriptor: colorDesc),
              let depthTex = device.makeTexture(descriptor: depthDesc),
              let queue = device.makeCommandQueue() else { throw XCTSkip("no Metal resources") }

        var m = BreastPierce(); m.spheres = breast.count
        for _ in 0..<200 {
            player.update(deltaTime: 1.0 / 30.0, model: model)
            guard let cb = queue.makeCommandBuffer() else { break }
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = colorTex
            rpd.colorAttachments[0].loadAction = .clear; rpd.colorAttachments[0].storeAction = .store
            rpd.depthAttachment.texture = depthTex
            rpd.depthAttachment.loadAction = .clear; rpd.depthAttachment.clearDepth = 1.0
            rpd.depthAttachment.storeAction = .dontCare
            renderer.drawOffscreenHeadless(to: colorTex, depth: depthTex, commandBuffer: cb, renderPassDescriptor: rpd)
            cb.commit()
            while cb.status != .completed && cb.status != .error { await Task.yield() }

            var worldSpheres: [(SIMD3<Float>, Float)] = []
            for b in breast where b.node < model.nodes.count {
                let c4 = model.nodes[b.node].worldMatrix * SIMD4<Float>(b.offset, 1)
                worldSpheres.append((SIMD3<Float>(c4.x, c4.y, c4.z), b.radius))
            }
            for jn in hairJoints where jn < model.nodes.count {
                let p = model.nodes[jn].worldPosition
                m.total += 1
                for (c, r) in worldSpheres {
                    let depth = r - simd_length(p - c)
                    if depth > margin { m.deep += 1; if depth > m.worst { m.worst = depth } }
                }
            }
        }
        return m
    }

    /// Diagnostic: print the breast-pierce rate on AvatarSample_A during a fast
    /// greeting emote. Establishes the #377 baseline against the breast MESH.
    func testBreastPierceBaseline_A() async throws {
        let m = try await measure(
            modelPath: getTestModelPath(testVRM10Filename),
            vrmaPath: getTestModelPath("VRMA_Avatar_Mega_Pack/Action_Greeting.vrma"))
        print(String(format: "[BreastPierce A greet] spheres=%d deep=%.2f%% (%d/%d) worst=%.1fmm",
            m.spheres, m.rate * 100, m.deep, m.total, m.worst * 1000))
    }

    /// GATE (#377): AvatarSample_H — long hair reaches the breast during a fast
    /// greeting emote and, without the mesh-fitted bust capsule, pierces the
    /// forward breast surface (measured baseline: 0.16% of hair-joint samples
    /// >5 mm inside the breast, worst 24.5 mm). With the capsule + the `Bust`
    /// spring decoupled from its own collider, hair is held at the breast surface.
    func testHairDoesNotPierceBreastMesh_H() async throws {
        let m = try await measure(
            modelPath: getTestModelPath("AvatarSample_H_1.0.vrm"),
            vrmaPath: getTestModelPath("VRMA_Avatar_Mega_Pack/Action_Greeting.vrma"))
        print(String(format: "[BreastPierce H greet] spheres=%d deep=%.2f%% (%d/%d) worst=%.1fmm",
            m.spheres, m.rate * 100, m.deep, m.total, m.worst * 1000))
        XCTAssertEqual(m.spheres, 2, "fixture must fit left+right breast spheres")
        XCTAssertLessThan(m.rate, 0.001,
            "augment ON: hair must not pierce the breast mesh >5 mm (#377); got \(String(format: "%.2f%%", m.rate*100)), worst \(String(format: "%.1f mm", m.worst*1000))")
    }
}
