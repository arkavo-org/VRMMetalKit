//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// SCRATCH DIAGNOSTIC — not for merge. Measures the GoM menu-host avatar's
// hair-vs-shoulder behavior against the synthetic shoulder spheres.
//

import XCTest
import Metal
import simd
@testable import VRMMetalKit

@MainActor
final class HostAvatarShoulderDiagnostic: XCTestCase {

    /// Machine-local host avatar, supplied via `VMK_HOST_VRM`.
    private var hostVRM: String { ProcessInfo.processInfo.environment["VMK_HOST_VRM"] ?? "" }
    /// Machine-local idle clip, supplied via `VMK_HOST_VRMA`. Both default to
    /// empty so the diagnostic self-skips off-machine; hardcoding them would
    /// trip the repo's static-path lint and resolve on exactly one checkout.
    private var idleVRMA: String { ProcessInfo.processInfo.environment["VMK_HOST_VRMA"] ?? "" }

    func testDiagnoseHostShoulder() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        try requireFixture(hostVRM, hint: "GoM host VRM")
        try requireFixture(idleVRMA, hint: "GoM idle VRMA")

        let model = try await VRMModel.load(
            from: URL(fileURLWithPath: hostVRM), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        let humanoid = try XCTUnwrap(model.humanoid)
        let springBone = try XCTUnwrap(model.springBone)

        print("[HOST] synthetic colliders: \(springBone.syntheticColliders.count)")
        print("[HOST] authored colliders: \(springBone.colliders.count), groups: \(springBone.colliderGroups.count)")
        for c in springBone.colliders {
            let nodeName = model.nodes[safe: c.node]?.name ?? "?"
            switch c.shape {
            case let .sphere(off, r):
                print("[HOST] authored sphere node=\(nodeName) r=\(String(format: "%.3f", r)) off=\(off)")
            case let .capsule(off, r, tail):
                print("[HOST] authored capsule node=\(nodeName) r=\(String(format: "%.3f", r)) off=\(off) tail=\(tail)")
            default:
                print("[HOST] authored other node=\(nodeName)")
            }
        }

        // Shoulder sphere geometry on THIS rig.
        let ratios = SpringBoneColliderAugmentor.Ratios()
        for (upper, lower, label) in [(VRMHumanoidBone.leftUpperArm, VRMHumanoidBone.leftLowerArm, "L"),
                                      (VRMHumanoidBone.rightUpperArm, VRMHumanoidBone.rightLowerArm, "R")] {
            if let c = SpringBoneBoneGeometry.shoulderSphere(
                upperArmBone: upper, lowerArmBone: lower,
                radiusFraction: ratios.shoulderSphereRadiusFraction,
                downFraction: ratios.shoulderSphereDownFraction,
                humanoid: humanoid, model: model),
               case let .sphere(offset, radius) = c.shape {
                print("[HOST] shoulder \(label): node=\(c.node) offset=\(offset) radius=\(String(format: "%.4f", radius)) m")
            } else {
                print("[HOST] shoulder \(label): NOT SYNTHESIZED")
            }
        }

        // Spring naming + hitRadius distribution.
        var hairSprings = 0, otherSprings = 0
        var hitRadii: [Float] = []
        for spring in springBone.springs {
            let isHair = (spring.name?.lowercased().contains("hair")) ?? false
            if isHair { hairSprings += 1 } else { otherSprings += 1 }
            for joint in spring.joints { hitRadii.append(joint.hitRadius) }
            if isHair == false {
                print("[HOST] non-hair spring name: \(spring.name ?? "<nil>") joints=\(spring.joints.count)")
            }
        }
        hitRadii.sort()
        print("[HOST] springs: hair=\(hairSprings) other=\(otherSprings); hitRadius min=\(hitRadii.first ?? -1) median=\(hitRadii[hitRadii.count/2]) max=\(hitRadii.last ?? -1)")

        // Play each clip and measure. clipLabel is used by the prints below.
        let animRoot = URL(fileURLWithPath: idleVRMA).deletingLastPathComponent()
        let greetPath = animRoot.appendingPathComponent("b0096525231e9f49947a6fad0295575b1c2bfbc33c042d07f125c7c2fbe88995.vrma").path
        let wavePath = animRoot.appendingPathComponent("f35f9deb9a0f203f824ec0da5a36194381b75000f26015f3dd5783e68c381b58.vrma").path
        let clips: [(label: String, file: String, quality: VRMConstants.SpringBoneQuality)] = [
            ("greet@high(90Hz,GoM-today)", greetPath, .high),
            ("greet@ultra(120Hz)", greetPath, .ultra),
            ("greet@extreme(480Hz)", greetPath, .extreme),
            ("wave@extreme(480Hz)", wavePath, .extreme),
            ("idle@extreme(480Hz)", idleVRMA, .extreme),
        ]
        for (clipLabel, clipPath, clipQuality) in clips {
        guard FileManager.default.fileExists(atPath: clipPath) else {
            print("[HOST] clip \(clipLabel) missing, skipping"); continue
        }
        let clip = try VRMAnimationLoader.loadVRMA(from: URL(fileURLWithPath: clipPath), model: model)
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
        renderer.springBoneQuality = clipQuality
        renderer.viewMatrix = matrix_identity_float4x4
        renderer.projectionMatrix = matrix_identity_float4x4

        var oracle: [(node: Int, offset: SIMD3<Float>, radius: Float)] = []
        for (upper, lower) in [(VRMHumanoidBone.leftUpperArm, VRMHumanoidBone.leftLowerArm),
                               (VRMHumanoidBone.rightUpperArm, VRMHumanoidBone.rightLowerArm)] {
            if let c = SpringBoneBoneGeometry.shoulderSphere(
                upperArmBone: upper, lowerArmBone: lower,
                radiusFraction: ratios.shoulderSphereRadiusFraction,
                downFraction: ratios.shoulderSphereDownFraction,
                humanoid: humanoid, model: model),
               case let .sphere(offset, radius) = c.shape {
                oracle.append((c.node, offset, radius))
            }
        }

        // ALL spring joints (not just hair-named) — this model's naming may differ.
        var jointNodes: [(node: Int, hitRadius: Float, springName: String)] = []
        for spring in springBone.springs {
            for (i, joint) in spring.joints.enumerated() where i > 0 {
                jointNodes.append((joint.node, joint.hitRadius, spring.name ?? "?"))
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
              let queue = device.makeCommandQueue() else { throw XCTSkip("no Metal resources") }

        // Upper-arm capsule oracles (the volumes the screenshot shows strands
        // crossing) + segment-segment distance for spatial tunneling detection.
        var armCapsules: [VRMCollider] = []
        for (from, to) in [(VRMHumanoidBone.leftUpperArm, VRMHumanoidBone.leftLowerArm),
                           (VRMHumanoidBone.rightUpperArm, VRMHumanoidBone.rightLowerArm)] {
            if let c = SpringBoneBoneGeometry.limbCapsule(
                fromBone: from, toBone: to,
                radiusFraction: ratios.upperArmRadiusFractionOfLength,
                humanoid: humanoid, model: model) {
                armCapsules.append(c)
            }
        }
        print("[HOST] arm capsule oracles: \(armCapsules.count)")

        // Consecutive joint pairs per spring (strand segments).
        var strandSegments: [(a: Int, b: Int, springName: String)] = []
        for spring in springBone.springs {
            for i in 1..<max(spring.joints.count, 1) {
                strandSegments.append((spring.joints[i-1].node, spring.joints[i].node, spring.name ?? "?"))
            }
        }

        func segSegDistance(_ p1: SIMD3<Float>, _ q1: SIMD3<Float>,
                            _ p2: SIMD3<Float>, _ q2: SIMD3<Float>) -> Float {
            // Closest distance between segments [p1,q1] and [p2,q2].
            let d1 = q1 - p1, d2 = q2 - p2, r = p1 - p2
            let a = simd_dot(d1, d1), e = simd_dot(d2, d2), f = simd_dot(d2, r)
            var sN: Float = 0, tN: Float = 0
            if a <= 1e-9 && e <= 1e-9 { return simd_length(r) }
            if a <= 1e-9 { tN = max(0, min(1, f / e)) }
            else {
                let c = simd_dot(d1, r)
                if e <= 1e-9 { sN = max(0, min(1, -c / a)) }
                else {
                    let b = simd_dot(d1, d2)
                    let denom = a * e - b * b
                    sN = denom > 1e-9 ? max(0, min(1, (b * f - c * e) / denom)) : 0
                    tN = (b * sN + f) / e
                    if tN < 0 { tN = 0; sN = max(0, min(1, -c / a)) }
                    else if tN > 1 { tN = 1; sN = max(0, min(1, (b - c) / a)) }
                }
            }
            return simd_length((p1 + sN * d1) - (p2 + tN * d2))
        }

        var worstCenter: Float = .greatestFiniteMagnitude   // min (d - r) over all samples
        var worstSurface: Float = .greatestFiniteMagnitude  // min (d - r - hitRadius)
        var worstJoint = ""
        var samplesInside = 0, total = 0
        var worstSegArm: Float = .greatestFiniteMagnitude   // min segment-to-arm-capsule clearance
        var worstSegSpring = ""
        var segTunnelSamples = 0, segTotal = 0

        for _ in 0..<300 {
            player.update(deltaTime: 1.0/30.0, model: model)
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

            var worldSpheres: [(center: SIMD3<Float>, r: Float)] = []
            for o in oracle {
                guard let node = model.nodes[safe: o.node] else { continue }
                let rot = SpringBoneBoneGeometry.upperLeft3x3(node.worldMatrix)
                worldSpheres.append((node.worldPosition + rot * o.offset, o.radius))
            }
            for j in jointNodes {
                guard let node = model.nodes[safe: j.node] else { continue }
                let p = node.worldPosition
                total += 1
                for s in worldSpheres {
                    let d = simd_length(p - s.center)
                    let centerClear = d - s.r
                    let surfClear = d - s.r - j.hitRadius
                    if centerClear < worstCenter { worstCenter = centerClear }
                    if surfClear < worstSurface { worstSurface = surfClear; worstJoint = j.springName }
                    if centerClear < 0 { samplesInside += 1 }
                }
            }

            // Segment-vs-arm-capsule: strand SEGMENTS crossing the arm while
            // both endpoint joints are legal (spatial tunneling).
            var worldArm: [(p0: SIMD3<Float>, p1: SIMD3<Float>, r: Float)] = []
            for local in armCapsules {
                if let wc = SpringBoneContactColliderSet.worldCapsule(local, model: model) {
                    worldArm.append((wc.p0, wc.p1, wc.radius))
                }
            }
            for seg in strandSegments {
                guard let na = model.nodes[safe: seg.a], let nb = model.nodes[safe: seg.b] else { continue }
                segTotal += 1
                for c in worldArm {
                    let d = segSegDistance(na.worldPosition, nb.worldPosition, c.p0, c.p1)
                    let clear = d - c.r
                    if clear < worstSegArm { worstSegArm = clear; worstSegSpring = seg.springName }
                    if clear < -0.005 { segTunnelSamples += 1 }
                }
            }
        }
        print("[HOST \(clipLabel) 300f] jointSamples=\(total) inside(center)=\(samplesInside) "
            + "worstCenterClearance=\(String(format: "%.1f mm", worstCenter * 1000)) "
            + "worstSurfaceClearance=\(String(format: "%.1f mm", worstSurface * 1000)) (spring: \(worstJoint))")
        print("[HOST \(clipLabel) 300f SEGMENTS] segSamples=\(segTotal) tunneled=\(segTunnelSamples) "
            + "worstSegArmClearance=\(String(format: "%.1f mm", worstSegArm * 1000)) (spring: \(worstSegSpring))")
        }
    }
}
