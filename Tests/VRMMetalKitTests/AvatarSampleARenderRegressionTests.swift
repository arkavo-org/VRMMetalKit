// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Regression coverage for the "dim AvatarSample_A render" that commit
/// `83c9da1` (#183: MToon flat-white output on factor-only spheres)
/// introduced — and that this branch reverts.
///
/// #183 removed the Half-Lambert remap (`NdotL * 0.5 + 0.5`) from
/// `MToonShader.metal` to fix a synthetic factor-only sphere flat-whiting
/// in the conformance corpus. Real Unity-exported VRM assets like
/// `AvatarSample_A` had their `shadingShiftFactor` authored against the
/// Half-Lambert input range [0, 1]; removing the remap shifted their shading
/// curve by -0.5 and pushed the visible body into shadow under default
/// lighting — the avatar rendered as a near-black silhouette where it had
/// previously shown a cream cardigan, dark shorts, and visible face.
///
/// #183's own regression test (`MToonFlatWhiteLightingTests`) only validated
/// the synthetic sphere it was tuned for, so the bigger real-asset regression
/// slipped through. The reverting commit on this branch
/// (`Revert "fix: MToon flat-white output on factor-only spheres (#183)"`)
/// restores Half-Lambert and the original brightness; this test exercises
/// the bundled real asset with the same default lighting `VRMRender` ships
/// so a future #183-style over-correction is caught at PR time.
@MainActor
final class AvatarSampleARenderRegressionTests: XCTestCase {

    /// Render `AvatarSample_A_1.0.vrm.glb` with `VRMRender` CLI defaults and
    /// assert the avatar's chest region is visibly lit (not a near-black
    /// silhouette). Empirical magnitudes:
    ///
    ///   - With Half-Lambert (post-revert): chest mean ~0.50 (cream cardigan)
    ///   - Without Half-Lambert (#183-era):  chest mean ~0.06 (darker than bg)
    ///   - Background clear color: ~0.13
    ///
    /// Threshold 0.30 sits between the two regimes — guarantees the avatar
    /// is recognizably lit with margin both above the background and below
    /// the lit brightness.
    func testAvatarRendersWithDefaultLightingIsNotDimSilhouette() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let path = getTestVRM10ModelPath()
        try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        config.colorPixelFormat = .rgba8Unorm_srgb
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)

        // Match `Sources/VRMRender/main.swift` defaults verbatim: 45° FOV at
        // square aspect, camera at (0, 1.3, 1.8) looking at (0, 1.3, 0); single
        // key light + dim back-rim + low-ambient anime-style lighting.
        let size = 256
        let fov: Float = 45.0 * .pi / 180.0
        renderer.projectionMatrix = makePerspective(fovRadians: fov, aspect: 1.0, near: 0.01, far: 100.0)
        renderer.viewMatrix = makeLookAt(
            eye:    SIMD3<Float>(0, 1.3, 1.8),
            center: SIMD3<Float>(0, 1.3, 0),
            up:     SIMD3<Float>(0, 1, 0)
        )
        renderer.setLight(0, direction: SIMD3<Float>(-0.2, 0.5, -0.85),
                          color: SIMD3<Float>(1, 1, 1), intensity: 1.0)
        renderer.disableLight(1)
        renderer.setLight(2, direction: SIMD3<Float>(0.0, 0.2, 1.0),
                          color: SIMD3<Float>(1, 1, 1), intensity: 0.3)
        renderer.setAmbientColor(SIMD3<Float>(0.04, 0.04, 0.04))

        let pixels = try renderFrame(renderer: renderer, device: device, size: size)

        // Sample the cardigan/chest region. At default framing the avatar's
        // head is around y_norm 0.40, chest ~0.60, hips ~0.78. Width-wise the
        // body fills roughly x_norm 0.40–0.60.
        let xRange = Int(Double(size) * 0.42)...Int(Double(size) * 0.58)
        let yRange = Int(Double(size) * 0.55)...Int(Double(size) * 0.68)
        let meanR = sampleMeanChannel(pixels, size: size, channel: 0, xRange: xRange, yRange: yRange)
        let meanG = sampleMeanChannel(pixels, size: size, channel: 1, xRange: xRange, yRange: yRange)
        let meanB = sampleMeanChannel(pixels, size: size, channel: 2, xRange: xRange, yRange: yRange)
        let meanLuma = (meanR + meanG + meanB) / 3.0
        print("[#183] AvatarSample_A chest mean R/G/B = (\(meanR), \(meanG), \(meanB)) luma=\(meanLuma)")

        XCTAssertGreaterThan(meanLuma, 0.30,
            "Chest region renders too dim (luma=\(meanLuma)). The Half-Lambert " +
            "remap in MToonShader.metal (restored by the #183 revert on this " +
            "branch) is what keeps AvatarSample_A's authored shadingShiftFactor " +
            "from pushing the visible body into shadow under default lighting. " +
            "A failure here likely means a #183-style shading-curve change was " +
            "reintroduced.")
    }

    // MARK: - Helpers (mirrors `MToonRimFresnelTests`)

    private func renderFrame(renderer: VRMRenderer, device: MTLDevice, size: Int) throws -> [UInt8] {
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb, width: size, height: size, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .shared
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: size, height: size, mipmapped: false)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private

        guard let colorTex = device.makeTexture(descriptor: colorDesc),
              let depthTex = device.makeTexture(descriptor: depthDesc),
              let queue = device.makeCommandQueue(),
              let cb = queue.makeCommandBuffer() else {
            throw XCTSkip("Could not allocate Metal render targets")
        }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = colorTex
        rpd.colorAttachments[0].loadAction = .clear
        // VRMRender CLI's navy background (matches its default behavior).
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1.0)
        rpd.colorAttachments[0].storeAction = .store
        rpd.depthAttachment.texture = depthTex
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1.0
        rpd.depthAttachment.storeAction = .dontCare

        renderer.drawOffscreenHeadless(to: colorTex, depth: depthTex, commandBuffer: cb, renderPassDescriptor: rpd)
        cb.commit()
        cb.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        bytes.withUnsafeMutableBytes { buf in
            colorTex.getBytes(buf.baseAddress!, bytesPerRow: size * 4,
                              from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        }
        return bytes
    }

    private func sampleMeanChannel(
        _ bytes: [UInt8], size: Int, channel: Int,
        xRange: ClosedRange<Int>, yRange: ClosedRange<Int>
    ) -> Float {
        var sum: Float = 0
        var count: Int = 0
        for y in yRange {
            for x in xRange {
                let base = (y * size + x) * 4
                sum += Float(bytes[base + channel]) / 255.0
                count += 1
            }
        }
        return count > 0 ? sum / Float(count) : 0
    }

    private func makePerspective(fovRadians: Float, aspect: Float, near: Float, far: Float) -> matrix_float4x4 {
        let yScale = 1.0 / tan(fovRadians * 0.5)
        let xScale = yScale / aspect
        let zRange = far - near
        return matrix_float4x4(columns: (
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, -(far + near) / zRange, -1),
            SIMD4<Float>(0, 0, -2.0 * far * near / zRange, 0)
        ))
    }

    private func makeLookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> matrix_float4x4 {
        let f = normalize(center - eye)
        let s = normalize(cross(f, up))
        let u = cross(s, f)
        return matrix_float4x4(columns: (
            SIMD4<Float>(s.x, u.x, -f.x, 0),
            SIMD4<Float>(s.y, u.y, -f.y, 0),
            SIMD4<Float>(s.z, u.z, -f.z, 0),
            SIMD4<Float>(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)
        ))
    }
}
