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

/// TDD: hair spring-bones must not penetrate the head collider during animation
/// playback. This guards against the symptom user observed in the "fixed" walk
/// render where bangs and side-hair clipped through the cheek/eye.
///
/// Empirical pre-fix measurement from /tmp/A_fixed_v2.mov: 8.1% of hair-bone
/// samples penetrate the J_Bip_C_Head sphere collider by >5 mm during a
/// 5-second walk; worst case is 2.4 cm of penetration. After the fix this
/// rate should be <1%.
@MainActor
final class HairHeadCollisionTests: XCTestCase {

    private var device: MTLDevice!

    override func setUp() async throws {
        guard let d = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        device = d
    }

    private func resourcesDirectory() -> String {
        ProcessInfo.processInfo.environment["MUSE_RESOURCES_PATH"]
            ?? FileManager.default.currentDirectoryPath
    }

    /// Static-pose baseline: with no animation movement, after warmup the
    /// hair must already be settled OUTSIDE the head collider. If this
    /// fails the collision math itself (not animation-driven lag) is broken.
    func testHairBonesStayOutsideHeadColliderInStaticPose() async throws {
        let modelPath = resourcesDirectory() + "/AvatarSample_A_1.0.vrm.glb"
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "AvatarSample_A_1.0.vrm.glb not found")

        let model = try await VRMModel.load(
            from: URL(fileURLWithPath: modelPath), device: device)

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        config.synchronousSpringBone = true  // see #267 — eliminates the 1-frame physics lag
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.enableSpringBone = true
        renderer.viewMatrix = matrix_identity_float4x4
        renderer.projectionMatrix = matrix_identity_float4x4

        guard let headNodeIndex = model.humanoid?.getBoneNode(.head),
              let headNode = model.nodes[safe: headNodeIndex],
              let springBone = model.springBone else {
            XCTFail("Could not locate head node or spring-bone data"); return
        }
        var offset = SIMD3<Float>(0, 0, 0); var radius: Float = 0
        for c in springBone.colliders where c.node == headNodeIndex {
            if case .sphere(let o, let r) = c.shape { offset = o; radius = r; break }
        }
        XCTAssertGreaterThan(radius, 0)

        // Track root joints separately — these are kinematically driven from
        // the head bone, so collision response intentionally skips them.
        var hairJointNodeIndices: [Int] = []
        var hairRootJointNodeIndices: Set<Int> = []
        for spring in springBone.springs where (spring.name ?? "").lowercased().contains("hair") {
            for (i, j) in spring.joints.enumerated() {
                hairJointNodeIndices.append(j.node)
                if i == 0 { hairRootJointNodeIndices.insert(j.node) }
            }
        }

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

        // Run physics for 60 frames without any animation update — pure static pose.
        let dt: Float = 1.0 / 30
        for _ in 0..<60 {
            guard let cb = queue.makeCommandBuffer() else { break }
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = colorTex
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            rpd.colorAttachments[0].storeAction = .store
            rpd.depthAttachment.texture = depthTex
            rpd.depthAttachment.loadAction = .clear; rpd.depthAttachment.clearDepth = 1.0
            rpd.depthAttachment.storeAction = .dontCare
            renderer.drawOffscreenHeadless(
                to: colorTex, depth: depthTex,
                commandBuffer: cb, renderPassDescriptor: rpd)
            cb.commit()
            while cb.status != .completed && cb.status != .error { await Task.yield() }
            _ = dt
        }

        let headWorld = headNode.worldMatrix
        let headRot = simd_float3x3(
            SIMD3<Float>(headWorld[0][0], headWorld[0][1], headWorld[0][2]),
            SIMD3<Float>(headWorld[1][0], headWorld[1][1], headWorld[1][2]),
            SIMD3<Float>(headWorld[2][0], headWorld[2][1], headWorld[2][2]))
        let headPos = SIMD3<Float>(headWorld[3][0], headWorld[3][1], headWorld[3][2])
        let center = headPos + headRot * offset
        let margin: Float = 0.005

        var penetrations: [(String, Float, Bool)] = []  // name, depth, isRoot
        for idx in hairJointNodeIndices {
            guard let node = model.nodes[safe: idx] else { continue }
            let d = simd_length(node.worldPosition - center)
            if d < radius - margin {
                let name = node.name ?? "#\(idx)"
                penetrations.append((name, radius - d, hairRootJointNodeIndices.contains(idx)))
            }
        }
        let nonRootPenetrations = penetrations.filter { !$0.2 }
        print("[HairHeadCollision static] penetrations: \(penetrations.count) total (\(nonRootPenetrations.count) non-root) of \(hairJointNodeIndices.count) hair joints")
        for p in penetrations.prefix(12) {
            print("  \(p.0) (\(p.2 ? "root" : "child")): \(String(format: "%.1f mm", p.1 * 1000))")
        }
        // Root joints are kinematically driven by the head bone; collision
        // intentionally skips them. Only non-root joints should stay out.
        XCTAssertEqual(nonRootPenetrations.count, 0,
            "Static-pose non-root hair joints should be outside head collider after warmup; found \(nonRootPenetrations.count) penetrations")
    }

    /// During Walk.vrma playback, every non-root hair joint should stay outside
    /// the head collider (within a 5 mm margin) on at least 99% of frame samples.
    ///
    /// GREEN as of 0.17.0-rc.2 (rate 0.0%). #267's residual — historically ~1.4%
    /// even with `synchronousSpringBone = true`, attributed to the
    /// `writeBonesToNodes` position→rotation→FK reconstruction round-trip — was
    /// closed by the rc.2 collision work: swept (continuous) collision (#313) and
    /// the post-collision inward-velocity bleed (#315) together keep the hair
    /// outside the head sphere through the fast head swings that previously
    /// surfaced the round-trip error. The broader interactive (async) matrix is
    /// guarded by `testHairHead_asyncMatrix_regressionGuard` below.
    func testHairBonesStayOutsideHeadColliderDuringWalk() async throws {
        let modelPath = resourcesDirectory() + "/AvatarSample_A_1.0.vrm.glb"
        let vrmaPath = resourcesDirectory() + "/VRMA_Locomotion_Pack/Walk.vrma"
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "AvatarSample_A_1.0.vrm.glb not found")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "Walk.vrma not found")

        let model = try await VRMModel.load(
            from: URL(fileURLWithPath: modelPath), device: device)
        let clip = try VRMAnimationLoader.loadVRMA(
            from: URL(fileURLWithPath: vrmaPath), model: model)

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

        // Locate the head node + its collider (sphere on J_Bip_C_Head).
        guard let headNodeIndex = model.humanoid?.getBoneNode(.head),
              let headNode = model.nodes[safe: headNodeIndex],
              let springBone = model.springBone else {
            XCTFail("Could not locate head node or spring-bone data")
            return
        }
        var headColliderOffset = SIMD3<Float>(0, 0, 0)
        var headColliderRadius: Float = 0
        for c in springBone.colliders where c.node == headNodeIndex {
            if case .sphere(let offset, let radius) = c.shape {
                headColliderOffset = offset
                headColliderRadius = radius
                break
            }
        }
        XCTAssertGreaterThan(headColliderRadius, 0,
            "AvatarSample_A_1.0 must have a sphere collider on J_Bip_C_Head")

        // Hair joints, excluding root joints which are kinematically driven by
        // the head bone (collision intentionally skips them per the VRM spec).
        var hairJointNodeIndices: [Int] = []
        for spring in springBone.springs {
            guard let name = spring.name, name.lowercased().contains("hair") else { continue }
            for (i, joint) in spring.joints.enumerated() where i > 0 {
                hairJointNodeIndices.append(joint.node)
            }
        }
        XCTAssertGreaterThan(hairJointNodeIndices.count, 0,
            "Asset must declare Hair spring chains with child joints")

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

        let fps: Float = 30
        let frameCount = 150
        let dt: Float = 1.0 / fps
        let penetrationMargin: Float = 0.005   // 5 mm

        var totalSamples = 0
        var penetrationSamples = 0
        var worstPenetration: Float = 0
        var worstFrame = -1
        var worstJoint = -1

        for frameIndex in 0..<frameCount {
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

            // Compute head collider world center from the head bone's current matrix.
            let headWorld = headNode.worldMatrix
            let headRot = simd_float3x3(
                SIMD3<Float>(headWorld[0][0], headWorld[0][1], headWorld[0][2]),
                SIMD3<Float>(headWorld[1][0], headWorld[1][1], headWorld[1][2]),
                SIMD3<Float>(headWorld[2][0], headWorld[2][1], headWorld[2][2]))
            let headPos = SIMD3<Float>(headWorld[3][0], headWorld[3][1], headWorld[3][2])
            let colliderCenter = headPos + headRot * headColliderOffset

            for nodeIdx in hairJointNodeIndices {
                guard let node = model.nodes[safe: nodeIdx] else { continue }
                let p = node.worldPosition
                let d = simd_length(p - colliderCenter)
                totalSamples += 1
                if d < headColliderRadius - penetrationMargin {
                    penetrationSamples += 1
                    let pen = headColliderRadius - d
                    if pen > worstPenetration {
                        worstPenetration = pen
                        worstFrame = frameIndex
                        worstJoint = nodeIdx
                    }
                }
            }
        }

        let rate = Float(penetrationSamples) / Float(totalSamples)
        print("[HairHeadCollision] samples=\(totalSamples) penetrations=\(penetrationSamples) rate=\(String(format: "%.1f%%", rate * 100))")
        if worstFrame >= 0 {
            let bone = model.nodes[safe: worstJoint]?.name ?? "#\(worstJoint)"
            print("[HairHeadCollision] worst: \(bone) frame \(worstFrame) penetration=\(String(format: "%.1f mm", worstPenetration * 1000))")
        }

        // Acceptance threshold: hair must miss the head collider on at least
        // 99% of frame samples. Pre-fix observed: 8.1% penetration rate.
        XCTAssertLessThan(rate, 0.01,
            "Hair penetrates the head collider on \(String(format: "%.1f%%", rate*100)) of samples; expected < 1%. Worst penetration: \(String(format: "%.1f mm", worstPenetration*1000))")
    }

    /// Measures hair-vs-head-collider penetration over a locomotion clip in the
    /// INTERACTIVE (async) spring-bone path — the path Muse and live apps use,
    /// where the 1-frame physics-snapshot lag (#267) is present. Returns the
    /// fraction of (frame × hair-joint) samples inside the head sphere by > 5 mm.
    private func measureWalkPenetrationRate(
        modelFile: String, vrmaFile: String, sync: Bool
    ) async throws -> Float? {
        let modelPath = resourcesDirectory() + "/" + modelFile
        let vrmaPath = resourcesDirectory() + "/VRMA_Locomotion_Pack/" + vrmaFile
        guard FileManager.default.fileExists(atPath: modelPath),
              FileManager.default.fileExists(atPath: vrmaPath) else { return nil }

        let model = try await VRMModel.load(from: URL(fileURLWithPath: modelPath), device: device)
        let clip = try VRMAnimationLoader.loadVRMA(from: URL(fileURLWithPath: vrmaPath), model: model)
        let player = AnimationPlayer()
        player.load(clip)
        player.play()

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        config.synchronousSpringBone = sync
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.enableSpringBone = true
        renderer.viewMatrix = matrix_identity_float4x4
        renderer.projectionMatrix = matrix_identity_float4x4

        guard let headNodeIndex = model.humanoid?.getBoneNode(.head),
              let headNode = model.nodes[safe: headNodeIndex],
              let springBone = model.springBone else { return nil }
        var headColliderOffset = SIMD3<Float>(0, 0, 0)
        var headColliderRadius: Float = 0
        for c in springBone.colliders where c.node == headNodeIndex {
            if case .sphere(let offset, let radius) = c.shape {
                headColliderOffset = offset; headColliderRadius = radius; break
            }
        }
        guard headColliderRadius > 0 else { return nil }

        var hairJointNodeIndices: [Int] = []
        for spring in springBone.springs {
            guard let name = spring.name, name.lowercased().contains("hair") else { continue }
            for (i, joint) in spring.joints.enumerated() where i > 0 {
                hairJointNodeIndices.append(joint.node)
            }
        }
        guard !hairJointNodeIndices.isEmpty else { return nil }

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]; colorDesc.storageMode = .private
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: 64, height: 64, mipmapped: false)
        depthDesc.usage = .renderTarget; depthDesc.storageMode = .private
        guard let colorTex = device.makeTexture(descriptor: colorDesc),
              let depthTex = device.makeTexture(descriptor: depthDesc),
              let queue = device.makeCommandQueue() else { return nil }

        let fps: Float = 30, frameCount = 150
        let dt: Float = 1.0 / fps
        let penetrationMargin: Float = 0.005
        var totalSamples = 0, penetrationSamples = 0

        for _ in 0..<frameCount {
            player.update(deltaTime: dt, model: model)
            guard let cb = queue.makeCommandBuffer() else { break }
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

            let headWorld = headNode.worldMatrix
            let headRot = simd_float3x3(
                SIMD3<Float>(headWorld[0][0], headWorld[0][1], headWorld[0][2]),
                SIMD3<Float>(headWorld[1][0], headWorld[1][1], headWorld[1][2]),
                SIMD3<Float>(headWorld[2][0], headWorld[2][1], headWorld[2][2]))
            let headPos = SIMD3<Float>(headWorld[3][0], headWorld[3][1], headWorld[3][2])
            let colliderCenter = headPos + headRot * headColliderOffset

            for nodeIdx in hairJointNodeIndices {
                guard let node = model.nodes[safe: nodeIdx] else { continue }
                let d = simd_length(node.worldPosition - colliderCenter)
                totalSamples += 1
                if d < headColliderRadius - penetrationMargin { penetrationSamples += 1 }
            }
        }
        return totalSamples > 0 ? Float(penetrationSamples) / Float(totalSamples) : 0
    }

    /// Regression guard locking in the rc.2 collision improvement (#313/#315) that
    /// resolved #267 in the interactive (async) spring-bone path live apps use —
    /// not just the offline `synchronousSpringBone` path. Each cell must keep
    /// hair-vs-head penetration under the #267 acceptance bar (< 1%).
    ///
    /// Cells are the three highest-signal model×clip combinations measured on
    /// 0.17.0-rc.2 — the ones that actually exercise the residual 1-frame lag:
    /// A×Run (deepest transient, ~20 mm 1-frame flicker), A×Jog (highest rate,
    /// ~0.2%), and U×Walk (the U model's only non-zero cell, ~0.17%). The other
    /// matrix cells sit at 0%. The 1% bound carries comfortable margin over
    /// observed while still tripping if the lag regresses toward the ~2–8%
    /// pre-fix range.
    ///
    /// COUNT-CONSTRAINED: each cell loads a fresh VRM, and this class already
    /// loads two (static + walk). The headless Metal harness aborts (SIGTRAP)
    /// past ~7 model loads in one process, and CI runs each class in its own
    /// parallel worker, so the guard is capped at three cells to keep the class
    /// total at five. Cells skip silently when a fixture is absent.
    func testHairHead_asyncMatrix_regressionGuard() async throws {
        let cells = [
            ("AvatarSample_A_1.0.vrm.glb", "Run.vrma"),
            ("AvatarSample_A_1.0.vrm.glb", "Jog.vrma"),
            ("AvatarSample_U_1.0.vrm.glb", "Walk.vrma"),
        ]
        var measuredAnyCell = false
        for (m, c) in cells {
            guard let rate = try await measureWalkPenetrationRate(
                modelFile: m, vrmaFile: c, sync: false) else { continue }
            measuredAnyCell = true
            print("[#267 guard] async \(m) x \(c): rate=\(String(format: "%.2f%%", rate*100))")
            XCTAssertLessThan(rate, 0.01,
                "Async hair→head penetration regressed for \(m) x \(c): \(String(format: "%.2f%%", rate*100)) (expected < 1%, #267).")
        }
        try XCTSkipIf(!measuredAnyCell, "No locomotion fixtures available")
    }
}
