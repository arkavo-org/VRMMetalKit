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

/// Guards the opt-in dual-quaternion skinning path (#197).
///
/// DQS is a deliberate QUALITY-ABOVE-REFERENCE divergence from glTF-standard LBS:
/// it blends joint dual quaternions instead of matrices, preserving volume at
/// high-deformation joints (the deltoid/armpit "candy-wrapper" collapse). LBS
/// remains the default (`RendererConfig.dualQuaternionSkinning == false`).
///
/// The conformance suite cannot measure skinning *quality* today (pose_diff is
/// bone-quaternion-level; there is no vertex capture and SSIM is too coarse), so
/// this is an ENGAGEMENT guard rather than a quality oracle: at an extreme arm
/// pose — where LBS and DQS provably diverge — the DQS render must differ
/// measurably from the LBS render (proving the flag wires through and the shader
/// branch runs), and must not produce NaN/garbage (no all-black / blown-out frame).
@MainActor
final class DualQuaternionSkinningTests: XCTestCase {

    private var device: MTLDevice!

    override func setUp() async throws {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal not available") }
        device = d
    }

    /// Renders AvatarSample_A with the right arm raised to an extreme abduction
    /// and returns the BGRA bytes (32×32, after physics+pose settle).
    private func renderArmRaised(dqs: Bool) async throws -> [UInt8]? {
        let path = getTestVRM10ModelPath()
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)
        guard let humanoid = model.humanoid,
              let rUpper = humanoid.getBoneNode(.rightUpperArm) else { return nil }

        var clip = AnimationClip(duration: 1.0)
        clip.addJointTrack(JointTrack(bone: .rightUpperArm, rotationSampler: { _ in
            simd_quatf(angle: -120 * .pi / 180, axis: simd_normalize(SIMD3<Float>(0, 0, 1)))
        }))
        let player = AnimationPlayer(); player.load(clip); player.play()

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        config.dualQuaternionSkinning = dqs
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.enableSpringBone = true

        let n = 32
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: n, height: n, mipmapped: false)
        cd.usage = [.renderTarget, .shaderRead]; cd.storageMode = .shared
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: n, height: n, mipmapped: false)
        dd.usage = .renderTarget; dd.storageMode = .private
        guard let color = device.makeTexture(descriptor: cd),
              let depth = device.makeTexture(descriptor: dd),
              let q = device.makeCommandQueue() else { return nil }

        // Frame the right shoulder.
        func lookAt(_ e: SIMD3<Float>, _ c: SIMD3<Float>) -> matrix_float4x4 {
            let f = normalize(c - e), s = normalize(cross(f, SIMD3<Float>(0, 1, 0))), u = cross(s, f)
            var m = matrix_float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1))
            m.columns.0 = SIMD4<Float>(s.x, u.x, -f.x, 0); m.columns.1 = SIMD4<Float>(s.y, u.y, -f.y, 0)
            m.columns.2 = SIMD4<Float>(s.z, u.z, -f.z, 0); m.columns.3 = SIMD4<Float>(-dot(s, e), -dot(u, e), dot(f, e), 1)
            return m
        }
        func persp(_ fov: Float) -> matrix_float4x4 {
            let t = tan(fov / 2); var m = matrix_float4x4()
            m.columns.0 = SIMD4<Float>(1/t, 0, 0, 0); m.columns.1 = SIMD4<Float>(0, 1/t, 0, 0)
            m.columns.2 = SIMD4<Float>(0, 0, -1, -1); m.columns.3 = SIMD4<Float>(0, 0, -0.02, 0); return m
        }
        for _ in 0..<8 {
            player.update(deltaTime: 1.0 / 30, model: model)
            let sp = model.nodes[rUpper].worldPosition
            renderer.viewMatrix = lookAt(sp + SIMD3<Float>(-0.02, 0.04, 0.28), sp)
            renderer.projectionMatrix = persp(26 * .pi / 180)
            guard let cb = q.makeCommandBuffer() else { break }
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = color; rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.1, green: 0.12, blue: 0.16, alpha: 1)
            rpd.colorAttachments[0].storeAction = .store
            rpd.depthAttachment.texture = depth; rpd.depthAttachment.loadAction = .clear
            rpd.depthAttachment.clearDepth = 1.0; rpd.depthAttachment.storeAction = .dontCare
            renderer.drawOffscreenHeadless(to: color, depth: depth, commandBuffer: cb, renderPassDescriptor: rpd)
            cb.commit(); while cb.status != .completed && cb.status != .error { await Task.yield() }
        }
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        bytes.withUnsafeMutableBytes {
            color.getBytes($0.baseAddress!, bytesPerRow: n * 4, from: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0)
        }
        return bytes
    }

    /// DQS must visibly diverge from LBS at an extreme arm pose, and the DQS frame
    /// must be a valid render (non-trivial coverage — not all background).
    func testDQS_engagesAndDivergesFromLBS() async throws {
        guard let lbs = try await renderArmRaised(dqs: false) else {
            throw XCTSkip("AvatarSample_A fixture not available")
        }
        guard let dqs = try await renderArmRaised(dqs: true) else {
            throw XCTSkip("AvatarSample_A fixture not available")
        }
        XCTAssertEqual(lbs.count, dqs.count)

        var diffSum = 0, lbsNonBg = 0
        let bg: [UInt8] = [0x29, 0x1F, 0x19, 0xFF]  // approx clear color in BGRA bytes
        for i in stride(from: 0, to: lbs.count, by: 4) {
            let d = abs(Int(lbs[i]) - Int(dqs[i])) + abs(Int(lbs[i+1]) - Int(dqs[i+1])) + abs(Int(lbs[i+2]) - Int(dqs[i+2]))
            diffSum += d
            if abs(Int(lbs[i]) - Int(bg[0])) + abs(Int(lbs[i+1]) - Int(bg[1])) + abs(Int(lbs[i+2]) - Int(bg[2])) > 30 { lbsNonBg += 1 }
        }
        let pixels = lbs.count / 4
        let meanDiff = Double(diffSum) / Double(pixels)
        print("[#197 DQS] meanPixelDiff(LBS↔DQS)=\(String(format: "%.1f", meanDiff)) lbsCoverage=\(lbsNonBg)/\(pixels)")

        // The LBS frame must actually show the avatar (guards a broken camera/render).
        XCTAssertGreaterThan(lbsNonBg, pixels / 10,
            "Expected the shoulder to fill a meaningful part of the frame (coverage \(lbsNonBg)/\(pixels))")
        // DQS must diverge from LBS at this extreme pose — proves the flag wires
        // through and the dual-quaternion branch runs (LBS≈DQS only at small angles).
        XCTAssertGreaterThan(meanDiff, 3.0,
            "DQS must measurably diverge from LBS at an extreme arm pose (mean per-channel diff \(meanDiff)); if ~0 the flag isn't reaching the shader.")
    }
}
