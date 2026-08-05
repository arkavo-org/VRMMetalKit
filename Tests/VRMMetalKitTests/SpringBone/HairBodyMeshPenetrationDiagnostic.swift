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

/// SCRATCH DIAGNOSTIC (machine-local; self-skips off-machine) — locates where
/// hair penetrates the skinned BODY skin mesh (behind the nearest skin vertex's
/// normal), grouped by the region's dominant bone. Scopes the shoulder /
/// upper-body coverage gaps the way `SpringBoneBreastCollider` scoped the breast.
@MainActor
final class HairBodyMeshPenetrationDiagnostic: XCTestCase {

    /// Machine-local host avatar, supplied via `VMK_HOST_VRM`. Absent by
    /// default, so this diagnostic self-skips everywhere but the machine that
    /// has the asset. Hardcoding the path would trip the repo's static-path
    /// lint and would not resolve on anyone else's checkout.
    static func hostVRMPath() -> String {
        ProcessInfo.processInfo.environment["VMK_HOST_VRM"] ?? ""
    }

    private var device: MTLDevice!
    override func setUp() async throws {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        device = d
    }

    /// Measures hair penetration into the fitted shoulder oracle during the spin
    /// dance (host). Toggle VMK_NO_SHOULDER for the before/after.
    func testShoulderPierce_Host() async throws {
        let host = Self.hostVRMPath()
        let dance = getTestModelPath("VRMA_Avatar_Mega_Pack/Dance_Northern_Soul_Spin.vrma")
        try requireFixture(host, hint: "host VRM"); try requireFixture(dance, hint: "dance VRMA")
        let model = try await VRMModel.load(from: URL(fileURLWithPath: host), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        let clip = try VRMAnimationLoader.loadVRMA(from: URL(fileURLWithPath: dance), model: model)
        let player = AnimationPlayer(); player.load(clip); player.play()
        var config = RendererConfig(); config.sampleCount = 1; config.strict = .off; config.synchronousSpringBone = true
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model); renderer.enableSpringBone = true; renderer.springBoneQuality = .high
        renderer.viewMatrix = matrix_identity_float4x4; renderer.projectionMatrix = matrix_identity_float4x4
        let springBone = try XCTUnwrap(model.springBone)

        // Oracle = fitted shoulder spheres (node = upperArm, offset local, radius).
        let shoulders = SpringBoneBreastCollider.computeShoulderColliders(model: model)
        var oracle: [(node: Int, offset: SIMD3<Float>, r: Float)] = []
        for c in shoulders { if case let .sphere(o, r) = c.shape { oracle.append((c.node, o, r)) } }
        for o in oracle { print(String(format: "[ShoulderFit] node=%d offset=(%.3f,%.3f,%.3f) r=%.4f", o.node, o.offset.x, o.offset.y, o.offset.z, o.r)) }

        var hairJoints: [Int] = []
        for spring in springBone.springs where (spring.name ?? "").lowercased().contains("hair") {
            for (i, j) in spring.joints.enumerated() where i > 0 { hairJoints.append(j.node) }
        }
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]; colorDesc.storageMode = .private
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 64, height: 64, mipmapped: false)
        depthDesc.usage = .renderTarget; depthDesc.storageMode = .private
        guard let colorTex = device.makeTexture(descriptor: colorDesc), let depthTex = device.makeTexture(descriptor: depthDesc),
              let queue = device.makeCommandQueue() else { throw XCTSkip("no Metal") }
        var deep = 0, total = 0; var worst: Float = 0
        for _ in 0..<200 {
            player.update(deltaTime: 1.0/30.0, model: model)
            guard let cb = queue.makeCommandBuffer() else { break }
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = colorTex; rpd.colorAttachments[0].loadAction = .clear; rpd.colorAttachments[0].storeAction = .store
            rpd.depthAttachment.texture = depthTex; rpd.depthAttachment.loadAction = .clear; rpd.depthAttachment.clearDepth = 1.0; rpd.depthAttachment.storeAction = .dontCare
            renderer.drawOffscreenHeadless(to: colorTex, depth: depthTex, commandBuffer: cb, renderPassDescriptor: rpd)
            cb.commit(); while cb.status != .completed && cb.status != .error { await Task.yield() }
            var ws: [(SIMD3<Float>, Float)] = []
            for o in oracle where o.node < model.nodes.count {
                let c4 = model.nodes[o.node].worldMatrix * SIMD4<Float>(o.offset, 1)
                ws.append((SIMD3(c4.x, c4.y, c4.z), o.r))
            }
            for jn in hairJoints where jn < model.nodes.count {
                let p = model.nodes[jn].worldPosition; total += 1
                for (c, r) in ws { let d = r - simd_length(p - c); if d > 0.005 { deep += 1; worst = max(worst, d) } }
            }
        }
        print(String(format: "[ShoulderPierce HOST dance] deep=%.2f%% (%d/%d) worst=%.1fmm noShoulder=%@",
            total>0 ? Float(deep)/Float(total)*100 : 0, deep, total, worst*1000,
            ProcessInfo.processInfo.environment["VMK_NO_SHOULDER"] ?? "no"))
    }

    /// Measures hair penetration into the fitted upper-torso capsule during the
    /// spin dance (host). Toggle VMK_NO_TORSO for before/after.
    func testTorsoPierce_Host() async throws {
        let host = Self.hostVRMPath()
        let dance = getTestModelPath("VRMA_Avatar_Mega_Pack/Dance_Northern_Soul_Spin.vrma")
        try requireFixture(host, hint: "host VRM"); try requireFixture(dance, hint: "dance VRMA")
        let model = try await VRMModel.load(from: URL(fileURLWithPath: host), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        let clip = try VRMAnimationLoader.loadVRMA(from: URL(fileURLWithPath: dance), model: model)
        let player = AnimationPlayer(); player.load(clip); player.play()
        var config = RendererConfig(); config.sampleCount = 1; config.strict = .off; config.synchronousSpringBone = true
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model); renderer.enableSpringBone = true; renderer.springBoneQuality = .high
        renderer.viewMatrix = matrix_identity_float4x4; renderer.projectionMatrix = matrix_identity_float4x4
        let springBone = try XCTUnwrap(model.springBone)

        // Oracle = the fitted upper-torso capsule (spine-anchored).
        guard let cap = SpringBoneBreastCollider.computeTorsoCollider(model: model).first,
              case let .capsule(offset, radius, tail) = cap.shape else { throw XCTSkip("no torso fit") }
        print(String(format: "[TorsoFit] node=%d offset=(%.3f,%.3f,%.3f) r=%.4f tail=(%.3f,%.3f,%.3f)",
            cap.node, offset.x, offset.y, offset.z, radius, tail.x, tail.y, tail.z))

        var hairJoints: [Int] = []
        for spring in springBone.springs where (spring.name ?? "").lowercased().contains("hair") {
            for (i, j) in spring.joints.enumerated() where i > 0 { hairJoints.append(j.node) }
        }
        func segDist(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            let ab = b - a; let l2 = simd_length_squared(ab)
            let t = l2 < 1e-9 ? 0 : max(0, min(1, simd_dot(p - a, ab) / l2))
            return simd_length(p - (a + t * ab))
        }
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]; colorDesc.storageMode = .private
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 64, height: 64, mipmapped: false)
        depthDesc.usage = .renderTarget; depthDesc.storageMode = .private
        guard let colorTex = device.makeTexture(descriptor: colorDesc), let depthTex = device.makeTexture(descriptor: depthDesc),
              let queue = device.makeCommandQueue() else { throw XCTSkip("no Metal") }
        var deep = 0, total = 0; var worst: Float = 0
        for _ in 0..<200 {
            player.update(deltaTime: 1.0/30.0, model: model)
            guard let cb = queue.makeCommandBuffer() else { break }
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = colorTex; rpd.colorAttachments[0].loadAction = .clear; rpd.colorAttachments[0].storeAction = .store
            rpd.depthAttachment.texture = depthTex; rpd.depthAttachment.loadAction = .clear; rpd.depthAttachment.clearDepth = 1.0; rpd.depthAttachment.storeAction = .dontCare
            renderer.drawOffscreenHeadless(to: colorTex, depth: depthTex, commandBuffer: cb, renderPassDescriptor: rpd)
            cb.commit(); while cb.status != .completed && cb.status != .error { await Task.yield() }
            let wm = model.nodes[cap.node].worldMatrix
            let a4 = wm * SIMD4<Float>(offset, 1); let b4 = wm * SIMD4<Float>(offset + tail, 1)
            let a = SIMD3<Float>(a4.x, a4.y, a4.z); let b = SIMD3<Float>(b4.x, b4.y, b4.z)
            for jn in hairJoints where jn < model.nodes.count {
                let p = model.nodes[jn].worldPosition; total += 1
                let d = radius - segDist(p, a, b); if d > 0.005 { deep += 1; worst = max(worst, d) }
            }
        }
        print(String(format: "[TorsoPierce HOST dance] deep=%.2f%% (%d/%d) worst=%.1fmm noTorso=%@",
            total>0 ? Float(deep)/Float(total)*100 : 0, deep, total, worst*1000,
            ProcessInfo.processInfo.environment["VMK_NO_TORSO"] ?? "no"))
    }

    func testWhereHairEntersBody_Host() async throws {
        let host = Self.hostVRMPath()
        // Spinning dance — dynamic hair flow that falls THROUGH the dress (the
        // user's reported trigger), unlike the gentle greet.
        let greet = getTestModelPath("VRMA_Avatar_Mega_Pack/Dance_Northern_Soul_Spin.vrma")
        try requireFixture(host, hint: "host VRM")
        try requireFixture(greet, hint: "dance VRMA")

        let model = try await VRMModel.load(from: URL(fileURLWithPath: host), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        let clip = try VRMAnimationLoader.loadVRMA(from: URL(fileURLWithPath: greet), model: model)
        let player = AnimationPlayer(); player.load(clip); player.play()

        var config = RendererConfig()
        config.sampleCount = 1; config.strict = .off; config.synchronousSpringBone = true
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.enableSpringBone = true
        renderer.springBoneQuality = .high
        renderer.viewMatrix = matrix_identity_float4x4
        renderer.projectionMatrix = matrix_identity_float4x4

        let springBone = try XCTUnwrap(model.springBone)
        let humanoid = try XCTUnwrap(model.humanoid)

        // Body SKIN mesh: the primitive whose material name contains SKIN.
        guard let bodyMeshIdx = model.meshes.firstIndex(where: { ($0.name ?? "").lowercased().contains("body") }),
              let bodyNode = model.nodes.first(where: { $0.mesh == bodyMeshIdx }),
              let skinIdx = bodyNode.skin, skinIdx < model.skins.count else {
            throw XCTSkip("no body skin mesh")
        }
        let skin = model.skins[skinIdx]

        // Static (bind-space) skin vertices/normals + per-vertex dominant bone.
        struct SV { var pos: SIMD3<Float>; var nrm: SIMD3<Float>; var joints: SIMD4<UInt32>; var weights: SIMD4<Float>; var domNode: Int }
        var skinVerts: [SV] = []
        for primitive in model.meshes[bodyMeshIdx].primitives {
            guard let mi = primitive.materialIndex else { continue }
            let matName = (model.materials[mi].name ?? "").uppercased()
            guard (matName.contains("SKIN") || matName.contains("CLOTH")), !matName.contains("HAIR") else { continue }
            guard let vb = primitive.vertexBuffer, primitive.vertexCount > 0 else { continue }
            let ptr = vb.contents().bindMemory(to: VRMVertex.self, capacity: primitive.vertexCount)
            for vi in 0..<primitive.vertexCount {
                let v = ptr[vi]
                let js = [Int(v.joints.x), Int(v.joints.y), Int(v.joints.z), Int(v.joints.w)]
                let ws = [v.weights.x, v.weights.y, v.weights.z, v.weights.w]
                var dom = -1; var dw: Float = 0
                for k in 0..<4 where ws[k] > dw { dw = ws[k]; dom = js[k] }
                let domNode = (dom >= 0 && dom < skin.joints.count) ? skin.joints[dom].index : -1
                skinVerts.append(SV(pos: v.position, nrm: v.normal, joints: v.joints, weights: v.weights, domNode: domNode))
            }
        }

        var hairJoints: [Int] = []
        var nodeSpring: [Int: String] = [:]
        for spring in springBone.springs where (spring.name ?? "").lowercased().contains("hair") {
            for (i, j) in spring.joints.enumerated() where i > 0 {
                hairJoints.append(j.node); nodeSpring[j.node] = spring.name ?? "?"
            }
        }

        // Map node index -> humanoid region label for reporting.
        func region(_ node: Int) -> String {
            for (bone, name) in [(VRMHumanoidBone.leftUpperArm, "shoulder/upperArm"),
                                 (.rightUpperArm, "shoulder/upperArm"),
                                 (.leftLowerArm, "lowerArm"), (.rightLowerArm, "lowerArm"),
                                 (.leftShoulder, "shoulder"), (.rightShoulder, "shoulder"),
                                 (.upperChest, "upperChest"), (.chest, "chest"), (.spine, "spine"),
                                 (.neck, "neck"), (.head, "head")] {
                if humanoid.getBoneNode(bone) == node { return name }
            }
            return "node\(node)"
        }

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]; colorDesc.storageMode = .private
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 64, height: 64, mipmapped: false)
        depthDesc.usage = .renderTarget; depthDesc.storageMode = .private
        guard let colorTex = device.makeTexture(descriptor: colorDesc),
              let depthTex = device.makeTexture(descriptor: depthDesc),
              let queue = device.makeCommandQueue() else { throw XCTSkip("no Metal resources") }

        var regionDeep: [String: Int] = [:]
        var regionWorst: [String: Float] = [:]
        var totalDeep = 0
        var samples: [(region: String, spring: String, pos: SIMD3<Float>, depth: Float)] = []

        for frame in 0..<200 {
            player.update(deltaTime: 1.0/30.0, model: model)
            guard let cb = queue.makeCommandBuffer() else { break }
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = colorTex
            rpd.colorAttachments[0].loadAction = .clear; rpd.colorAttachments[0].storeAction = .store
            rpd.depthAttachment.texture = depthTex
            rpd.depthAttachment.loadAction = .clear; rpd.depthAttachment.clearDepth = 1.0; rpd.depthAttachment.storeAction = .dontCare
            renderer.drawOffscreenHeadless(to: colorTex, depth: depthTex, commandBuffer: cb, renderPassDescriptor: rpd)
            cb.commit()
            while cb.status != .completed && cb.status != .error { await Task.yield() }

            // Skin only every 10th frame (cost), enough to locate the gaps.
            guard frame % 10 == 0 else { continue }
            let skinMatrices = skin.joints.indices.map { skin.joints[$0].worldMatrix * skin.inverseBindMatrices[$0] }
            func skinPN(_ sv: SV) -> (SIMD3<Float>, SIMD3<Float>) {
                let wsum = max(sv.weights.x+sv.weights.y+sv.weights.z+sv.weights.w, 1e-6)
                let w = sv.weights / wsum
                let js = [Int(sv.joints.x), Int(sv.joints.y), Int(sv.joints.z), Int(sv.joints.w)]
                let ws = [w.x, w.y, w.z, w.w]
                var m = float4x4(0)
                for k in 0..<4 where ws[k] > 0 && js[k] < skinMatrices.count { m += skinMatrices[js[k]] * ws[k] }
                let p = m * SIMD4<Float>(sv.pos, 1)
                let n3 = simd_float3x3(SIMD3(m.columns.0.x,m.columns.0.y,m.columns.0.z),
                                      SIMD3(m.columns.1.x,m.columns.1.y,m.columns.1.z),
                                      SIMD3(m.columns.2.x,m.columns.2.y,m.columns.2.z))
                return (SIMD3(p.x,p.y,p.z), simd_normalize(n3 * sv.nrm))
            }
            let world = skinVerts.map { ($0, skinPN($0)) }

            for jn in hairJoints where jn < model.nodes.count {
                let hp = model.nodes[jn].worldPosition
                // Nearest skin vertex; penetration = how far BEHIND its normal.
                var best: Float = .greatestFiniteMagnitude
                var bestSV: SV? = nil
                var bestDepth: Float = 0
                for (sv, pn) in world {
                    let d = simd_length(hp - pn.0)
                    if d < best {
                        let signed = simd_dot(hp - pn.0, pn.1)  // <0 ⇒ inside
                        best = d; bestSV = sv; bestDepth = -signed
                    }
                }
                // Count only genuinely-inside (behind surface) beyond 5 mm, and
                // near enough to be this surface (not a far vertex).
                if let sv = bestSV, best < 0.05, bestDepth > 0.005 {
                    let r = region(sv.domNode)
                    regionDeep[r, default: 0] += 1
                    regionWorst[r] = max(regionWorst[r] ?? 0, bestDepth)
                    totalDeep += 1
                    samples.append((r, nodeSpring[jn] ?? "?", hp, bestDepth))
                }
            }
        }

        print("[BodyMeshPen HOST] total inside-skin samples=\(totalDeep) across sampled frames")
        for (r, c) in regionDeep.sorted(by: { $0.value > $1.value }) {
            print(String(format: "[BodyMeshPen HOST]   %-18@ deep=%d worst=%.1fmm", r as NSString, c, (regionWorst[r] ?? 0)*1000))
        }
        print("[BodyMeshPen HOST] worst samples (region, strand, x,y,z, depth):")
        for s in samples.sorted(by: { $0.depth > $1.depth }).prefix(15) {
            print(String(format: "[BodyMeshPen HOST]   %-16@ %-14@ (%.3f,%.3f,%.3f) %.1fmm",
                s.region as NSString, s.spring as NSString, s.pos.x, s.pos.y, s.pos.z, s.depth*1000))
        }
    }
}
