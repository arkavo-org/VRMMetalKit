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
/// `MToonShader.metal` to fix a synthetic VRM 1.0 factor-only sphere
/// flat-whiting in the conformance corpus. This branch keeps that spec path
/// for VRM 1.0 and relies on `VRMRender`'s scene lighting parameters, not a
/// production shader deviation, to keep the bundled sample render readable.
///
/// #183's own regression test (`MToonFlatWhiteLightingTests`) only validated
/// the synthetic sphere it was tuned for, so the sample-render brightness
/// regression slipped through. This test exercises the bundled real asset
/// with the same default lighting `VRMRender` ships.
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
    ///   - Bright VRMRender default: chest luma ~0.43 (cream cardigan)
    ///   - Pre-brightening default:   chest luma ~0.36
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
            "Chest region renders too dim (luma=\(meanLuma)). VRMRender's " +
            "default lighting should keep AvatarSample_A readable without " +
            "requiring a VRM 1.0 shader deviation.")
    }
}
