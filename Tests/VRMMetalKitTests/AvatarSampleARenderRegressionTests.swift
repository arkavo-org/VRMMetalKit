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
/// restores Half-Lambert and the original brightness. The synthetic-sphere
/// side of that tradeoff remains tracked by VMK#230 and covered by an
/// expected-failure test; this test exercises the bundled real asset with
/// the same default lighting `VRMRender` ships so a future #183-style
/// over-correction is caught at PR time.
///
/// The same revert also restores the pre-#187 winding and outline-cull
/// behavior. That is intentionally reviewed as part of the #183 rollback:
/// the load-time winding normalizer and outline cull-mode change were coupled
/// to the synthetic-sphere fix and are not needed by the bundled avatar
/// fixture guarded here.
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
        // stronger key light + subtle back-rim + low neutral ambient.
        let size = 256
        let fov: Float = 45.0 * .pi / 180.0
        renderer.projectionMatrix = RenderTestSupport.makePerspective(fovRadians: fov, aspect: 1.0, near: 0.01, far: 100.0)
        renderer.viewMatrix = RenderTestSupport.makeLookAt(
            eye:    SIMD3<Float>(0, 1.3, 1.8),
            center: SIMD3<Float>(0, 1.3, 0),
            up:     SIMD3<Float>(0, 1, 0)
        )
        renderer.setLight(0, direction: SIMD3<Float>(-0.2, 0.5, -0.85),
                          color: SIMD3<Float>(1, 1, 1), intensity: 1.25)
        renderer.disableLight(1)
        renderer.setLight(2, direction: SIMD3<Float>(0.0, 0.2, 1.0),
                          color: SIMD3<Float>(1, 1, 1), intensity: 0.35)
        renderer.setAmbientColor(SIMD3<Float>(0.08, 0.08, 0.08))
        renderer.setLightNormalizationMode(.manual(1.1))

        let pixels = try RenderTestSupport.renderFrame(
            renderer: renderer,
            device: device,
            size: size,
            pixelFormat: .rgba8Unorm_srgb,
            clearColor: MTLClearColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1.0)
        )

        // Sample the cardigan/chest region. At default framing the avatar's
        // head is around y_norm 0.40, chest ~0.60, hips ~0.78. Width-wise the
        // body fills roughly x_norm 0.40–0.60.
        let xRange = Int(Double(size) * 0.42)...Int(Double(size) * 0.58)
        let yRange = Int(Double(size) * 0.55)...Int(Double(size) * 0.68)
        let meanR = RenderTestSupport.meanChannelRGBA(pixels, size: size, channel: 0, xRange: xRange, yRange: yRange)
        let meanG = RenderTestSupport.meanChannelRGBA(pixels, size: size, channel: 1, xRange: xRange, yRange: yRange)
        let meanB = RenderTestSupport.meanChannelRGBA(pixels, size: size, channel: 2, xRange: xRange, yRange: yRange)
        let meanLuma = RenderTestSupport.meanRec709LumaRGBA(pixels, size: size, xRange: xRange, yRange: yRange)
        print("[#183] AvatarSample_A chest mean R/G/B = (\(meanR), \(meanG), \(meanB)) luma=\(meanLuma)")

        XCTAssertGreaterThan(meanLuma, 0.30,
            "Chest region renders too dim (luma=\(meanLuma)). The Half-Lambert " +
            "remap in MToonShader.metal (restored by the #183 revert on this " +
            "branch) is what keeps AvatarSample_A's authored shadingShiftFactor " +
            "from pushing the visible body into shadow under default lighting. " +
            "A failure here likely means a #183-style shading-curve change was " +
            "reintroduced.")
    }
}
