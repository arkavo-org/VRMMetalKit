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

/// Regression for vrm-conformance issue #226. The MToon parametric-rim
/// fresnel block in `MToonShader.metal` computed `dot(viewNormal, V')` where
/// `viewNormal` was built from a compound `viewMatrix * normalMatrix * float4(N, 0)`
/// — and that compound carries a w-component leak whenever the model has a
/// non-zero translation AND the view matrix has a non-zero translation:
///
///   `normalMatrix = modelMatrix.inverse.transpose` of a translated
///   `modelMatrix` puts the negated translation into the *4th row* of the
///   inverse, and the transpose moves that into the *w-component* of the
///   per-axis columns. So `normalMatrix * float4(N, 0)` produces a vec4
///   with non-zero `w`, and the subsequent `viewMatrix * …` applies
///   `viewMatrix`'s translation column scaled by that `w`, contaminating the
///   `xyz` we then normalize.
///
/// The bug was asymptomatic for tests with an identity view matrix (no
/// translation column to multiply into), but bit every realistic camera
/// setup — including the conformance corpus's `lookAt(eye=(0,1.4,1.5), ...)`
/// against a sphere translated to `y=1.4`. The rim ended up appearing at
/// the *bottom* of the sphere (where the sign-flipped w-leak saturated
/// NdotV to 0 → full rim) while *vanishing* at the top (where w-leak
/// inflated NdotV toward 1 → rimF^5 ≈ 0, invisible at 8-bit). Sweep-
/// invariant SSIM 0.91 vs the three other reference renderers' 0.98+
/// cluster.
///
/// Fix: compute the rim fresnel in *world space*, mirroring the
/// `additiveDirectionalRim` block in the same shader. `worldNormal` is
/// already correctly computed (single matrix multiply + explicit `.xyz`
/// extraction → no compound w-leak). `viewDirection` is also already
/// world-space. The MToon-1.0 spec defines the rim fresnel in world
/// space, three-vrm + UniVRM Built-in RP both implement it that way.
@MainActor
final class MToonRimFresnelTests: XCTestCase {
    private static let dimSceneKeyIntensity: Float = 0.3
    private static let dimSceneAmbient = SIMD3<Float>(0.05, 0.05, 0.05)

    /// End-to-end repro against the actual conformance asset that surfaced
    /// the bug. Skips if the asset isn't on disk — regenerate from a checkout
    /// of `github.com/arkavo-org/vrm-conformance` via:
    ///
    ///     cargo run --release -p vrm-asset-generator -- \
    ///       emit-sweep --output-dir /tmp/repro226
    ///
    /// then copy `mtoon_rimLightingMix_1.vrm` to the path below.
    ///
    /// Pre-fix: VMK renders the sphere with NO rim at the top half (gray)
    /// and a sharp horizontal band of orange at the bottom. The horizontal
    /// centerline shows the rim is *missing where it should be*. The
    /// test asserts the rim is visible across the silhouette — specifically
    /// that the left edge of the visible sphere carries an orange tint
    /// (`R > B + ε`) where pre-fix it was pure gray.
    func testRimVisibleAtLeftSilhouetteOfConformanceAsset() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let path = "/tmp/repro226/mtoon_rimLightingMix_1.vrm"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("vrm-conformance rim asset not at \(path). " +
                "Regenerate from a checkout of github.com/arkavo-org/vrm-conformance with: " +
                "`cargo run --release -p vrm-asset-generator -- emit-sweep --output-dir /tmp/repro226`")
        }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)

        // Conformance pipeline + cache key fix lands separately in #214.
        // Construct the renderer with the same setup the QA adapter uses
        // (sRGB framebuffer, 4× MSAA, the conformance test_yaml camera +
        // lighting).
        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        config.colorPixelFormat = .rgba8Unorm_srgb
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)

        let size = 256
        let aspect: Float = 1.0
        let fov: Float = 30.0 * .pi / 180.0
        renderer.projectionMatrix = RenderTestSupport.makePerspective(fovRadians: fov, aspect: aspect, near: 0.01, far: 100.0)
        renderer.viewMatrix = RenderTestSupport.makeLookAt(
            eye:    SIMD3<Float>(0, 1.4, 1.5),
            center: SIMD3<Float>(0, 1.4, 0),
            up:     SIMD3<Float>(0, 1, 0)
        )
        // The dim scene is load-bearing: full-intensity scene light + bright
        // rim can saturate at silhouette, hiding the orange tint that this
        // test measures. Lower intensity keeps the rim's orange contribution
        // visible against the body without changing what the test actually
        // verifies (rim fires across all silhouette directions, not just the
        // pre-#226 w-leak direction).
        renderer.setLight(0, direction: SIMD3<Float>(-0.3, -0.6, -0.7),
                          color: SIMD3<Float>(1, 1, 1),
                          intensity: Self.dimSceneKeyIntensity)
        renderer.disableLight(1)
        renderer.disableLight(2)
        renderer.setAmbientColor(Self.dimSceneAmbient)

        let pixels = try RenderTestSupport.renderFrame(
            renderer: renderer,
            device: device,
            size: size,
            pixelFormat: .rgba8Unorm_srgb,
            clearColor: MTLClearColor(red: 1.0, green: 0.0, blue: 1.0, alpha: 1.0)
        )

        // The sphere's visible disk fills roughly x=12-88% of the image (30°
        // FOV, sphere radius 0.3 at distance 1.5). Sample close to the left
        // silhouette where rimF^5 ≈ 1 (vf=1 → full rim). Sampling at
        // x=18-22% is *inside* the body where rimF drops to ~0.06 and the
        // rim tint disappears at 8-bit; that won't surface the bug.
        let xRange = Int(Double(size) * 0.13)...Int(Double(size) * 0.16)
        let yRange = Int(Double(size) * 0.47)...Int(Double(size) * 0.53)
        let stripR = RenderTestSupport.meanChannelRGBA(pixels, size: size, channel: 0, xRange: xRange, yRange: yRange, skippingMagentaClear: true)
        let stripG = RenderTestSupport.meanChannelRGBA(pixels, size: size, channel: 1, xRange: xRange, yRange: yRange, skippingMagentaClear: true)
        let stripB = RenderTestSupport.meanChannelRGBA(pixels, size: size, channel: 2, xRange: xRange, yRange: yRange, skippingMagentaClear: true)

        print("[#226] left silhouette R/G/B = (\(stripR), \(stripG), \(stripB))")

        // Thresholds calibrated for VRM 1.0 spec-correct shading (raw dot(N,L)).
        // The left silhouette is in shadow with this lighting, so the rim is
        // dimmed by the lighting modulation (rimLightingMix=1.0).  Pre-#226
        // the bug manifests as R≈G≈B (no rim); any R>G>B separation is signal.
        //
        // Observed on macOS arm64 (post-#232 load-time coordinate conversion):
        //   R=0.416, G=0.380, B=0.341  →  R-G≈0.035, G-B≈0.039
        // The 0.02 threshold leaves ≥75% headroom on both channels.  Tighten
        // toward 0.03 only if Metal pipeline cache invalidation makes the
        // observed values reliable across runs.
        XCTAssertGreaterThan(stripR, stripG + 0.02,
            "Left silhouette strip must show orange rim (R > G). Got R=\(stripR), G=\(stripG). " +
            "Pre-fix #226 the parametric-rim fresnel only fired at one specific normal direction " +
            "(the sign-aligned w-leak in compound viewMatrix·normalMatrix) — every other silhouette " +
            "point received zero rim.")
        // The G-B gap is intentionally smaller than R-G because the rim
        // colour (1, 0.5, 0) is blended *additively* on top of the shadow-
        // side body (gray) — G picks up 0.5·rimF, B picks up 0·rimF, so the
        // G-B delta is half the R-G delta when both come from the rim term.
        XCTAssertGreaterThan(stripG, stripB + 0.02,
            "Left silhouette strip must show orange (G > B). Got G=\(stripG), B=\(stripB).")
    }

    /// Same asset, top-silhouette sample. Pre-fix this is pure gray (181,181,181
    /// in 8-bit) because the w-leak's NdotV ≈ 0.4 → vf=0.6 → rimF=0.07, invisible
    /// at 8-bit. Post-fix the top silhouette carries the same orange rim as the
    /// rest of the visible disk's edge.
    func testRimVisibleAtTopSilhouetteOfConformanceAsset() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let path = "/tmp/repro226/mtoon_rimLightingMix_1.vrm"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("vrm-conformance rim asset not at \(path). " +
                "Regenerate as in `testRimVisibleAtLeftSilhouetteOfConformanceAsset`'s skip note.")
        }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        config.colorPixelFormat = .rgba8Unorm_srgb
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)

        let size = 256
        let aspect: Float = 1.0
        let fov: Float = 30.0 * .pi / 180.0
        renderer.projectionMatrix = RenderTestSupport.makePerspective(fovRadians: fov, aspect: aspect, near: 0.01, far: 100.0)
        renderer.viewMatrix = RenderTestSupport.makeLookAt(
            eye:    SIMD3<Float>(0, 1.4, 1.5),
            center: SIMD3<Float>(0, 1.4, 0),
            up:     SIMD3<Float>(0, 1, 0)
        )
        // The dim scene is load-bearing: full-intensity scene light + bright
        // rim can saturate at silhouette, hiding the orange tint that this
        // test measures. Lower intensity keeps the rim's orange contribution
        // visible against the body without changing what the test actually
        // verifies (rim fires across all silhouette directions, not just the
        // pre-#226 w-leak direction).
        renderer.setLight(0, direction: SIMD3<Float>(-0.3, -0.6, -0.7),
                          color: SIMD3<Float>(1, 1, 1),
                          intensity: Self.dimSceneKeyIntensity)
        renderer.disableLight(1)
        renderer.disableLight(2)
        renderer.setAmbientColor(Self.dimSceneAmbient)

        let pixels = try RenderTestSupport.renderFrame(
            renderer: renderer,
            device: device,
            size: size,
            pixelFormat: .rgba8Unorm_srgb,
            clearColor: MTLClearColor(red: 1.0, green: 0.0, blue: 1.0, alpha: 1.0)
        )

        // Top silhouette: just inside the sphere top edge. Sphere visible
        // disk fills y=12-88%, so y=15-18% is one band inside the top edge
        // where NdotV ≈ 0 and rimF ≈ 1.
        let xRange = Int(Double(size) * 0.47)...Int(Double(size) * 0.53)
        let yRange = Int(Double(size) * 0.15)...Int(Double(size) * 0.18)
        let stripR = RenderTestSupport.meanChannelRGBA(pixels, size: size, channel: 0, xRange: xRange, yRange: yRange, skippingMagentaClear: true)
        let stripG = RenderTestSupport.meanChannelRGBA(pixels, size: size, channel: 1, xRange: xRange, yRange: yRange, skippingMagentaClear: true)
        let stripB = RenderTestSupport.meanChannelRGBA(pixels, size: size, channel: 2, xRange: xRange, yRange: yRange, skippingMagentaClear: true)

        print("[#226] top silhouette R/G/B = (\(stripR), \(stripG), \(stripB))")

        // Observed on macOS arm64 (post-#232 load-time coordinate conversion):
        //   R=0.729, G=0.600, B=0.416  →  R-G≈0.129, G-B≈0.184
        // Top silhouette is on the lit side, so the rim's orange is dominant
        // and well above the looser threshold than the shadowed left strip.
        XCTAssertGreaterThan(stripR, stripG + 0.05,
            "Top silhouette strip must show orange rim (R > G). Got R=\(stripR), G=\(stripG). " +
            "Pre-fix #226 this was pure gray because the w-leak inflated NdotV at +Y normals.")
        XCTAssertGreaterThan(stripG, stripB + 0.10,
            "Top silhouette strip must show orange (G > B). Got G=\(stripG), B=\(stripB).")
    }

    /// Regression for vrm-conformance issue #228, which claimed VMK 0.13.6
    /// produced **no front-face rim contribution** on `mtoon_rimLightingMix_1`
    /// (`parametricRimLiftFactor=0.0`, `rimLightingMixFactor=1.0`) — its
    /// reported VMK center pixel `(181,181,181)` was byte-identical to
    /// `mtoon_default`'s center, while UniVRM reported `(255,255,132)` and
    /// three-vrm `(255,255,195)`.
    ///
    /// The hypothesis in #228 was that VMK's parametric-rim formula had `lift`
    /// outside `pow(...)`. It does not: `MToonShader.metal:731-732` reads
    /// `pow(saturate(vf + parametricRimLiftFactor), max(power, 1e-4))`, which
    /// is byte-identical to UniVRM's HLSL at
    /// `MToon10/Shaders/vrmc_materials_mtoon_lighting_mtoon.hlsl:126`.
    ///
    /// Empirical measurement on HEAD (post-#214 pipeline cache + #232 load-time
    /// coord conversion) at the conformance sample point on `mtoon_rimLightingMix_1`:
    ///
    ///     mtoon_rimLightingMix_1  →  (178, 164, 148)
    ///     mtoon_default           →  (148, 148, 148)
    ///     rim contribution        →  ( 30,  16,   0)
    ///
    /// The rim Δ ratio (30:16:0) normalizes to (1.00, 0.53, 0.00) — within
    /// rounding of the asset's `parametricRimColorFactor` (1.0, 0.5, 0.0).
    /// The rim path is firing.
    ///
    /// The remaining gap vs UniVRM `(255,255,132)` is **body brightness**,
    /// not rim: VMK's lit base at this sample (`148`) sits well below
    /// UniVRM's saturated `255`. That residual is tracked by
    /// [VMK#213](https://github.com/arkavo-org/VRMMetalKit/issues/213) (the
    /// shadingToony / shading-curve cluster).
    ///
    /// This test locks in that the rim contribution is positive and orange-tinted
    /// (`R > G > B`, `R−G > 10 bytes`, `G−B > 5 bytes`) so any future change
    /// that re-introduces the "byte-identical to mtoon_default" symptom fails
    /// CI loudly.
    func testRimContributionPositiveAtConformanceSamplePoint() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let path = "/tmp/repro226/mtoon_rimLightingMix_1.vrm"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("vrm-conformance rim asset not at \(path).")
        }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        config.colorPixelFormat = .rgba8Unorm_srgb
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)

        // Conformance test_yaml setup (mtoon_rimLightingMix_1.test.yaml). The
        // QA suite renders at 1024×1024 with 4× MSAA; we use 256×256 to keep
        // the test cheap and oversample MSAA via the same in-shader pipeline.
        let size = 256
        let fov: Float = 30.0 * .pi / 180.0
        renderer.projectionMatrix = RenderTestSupport.makePerspective(fovRadians: fov, aspect: 1.0, near: 0.01, far: 100.0)
        renderer.viewMatrix = RenderTestSupport.makeLookAt(
            eye:    SIMD3<Float>(0, 1.4, 1.5),
            center: SIMD3<Float>(0, 1.4, 0),
            up:     SIMD3<Float>(0, 1, 0)
        )
        renderer.setLight(0, direction: SIMD3<Float>(-0.3, -0.6, -0.7),
                          color: SIMD3<Float>(1, 1, 1),
                          intensity: 1.0)
        renderer.disableLight(1)
        renderer.disableLight(2)
        renderer.setAmbientColor(SIMD3<Float>(0.5 * 0.3, 0.5 * 0.3, 0.5 * 0.3))

        let pixels = try RenderTestSupport.renderFrame(
            renderer: renderer,
            device: device,
            size: size,
            pixelFormat: .rgba8Unorm_srgb,
            clearColor: MTLClearColor(red: 1.0, green: 0.0, blue: 1.0, alpha: 1.0)
        )

        // Issue #228 samples (512, 600) on a 1024×1024 render — 50% horizontal,
        // 58.6% vertical. At 256² that maps to (128, 150). Sample a small
        // window centered there.
        let cx = Int(Double(size) * 0.50)
        let cy = Int(Double(size) * 0.586)
        let xRange = (cx - 2)...(cx + 2)
        let yRange = (cy - 2)...(cy + 2)
        let centerR = RenderTestSupport.meanChannelRGBA(pixels, size: size, channel: 0, xRange: xRange, yRange: yRange, skippingMagentaClear: true)
        let centerG = RenderTestSupport.meanChannelRGBA(pixels, size: size, channel: 1, xRange: xRange, yRange: yRange, skippingMagentaClear: true)
        let centerB = RenderTestSupport.meanChannelRGBA(pixels, size: size, channel: 2, xRange: xRange, yRange: yRange, skippingMagentaClear: true)

        let r8 = Int(centerR * 255), g8 = Int(centerG * 255), b8 = Int(centerB * 255)
        print("[#228] mtoon_rimLightingMix_1 center (x=\(cx), y=\(cy)) R/G/B = (\(r8), \(g8), \(b8)) — issue claims UniVRM=(255,255,132), three-vrm=(255,255,195)")

        // Comparison render: same camera/lighting against mtoon_default (no rim
        // configured) to isolate the rim contribution from the body's lit
        // color. If `default` produces ~same R/G/B and `rimLightingMix_1`
        // produces R>G>B with an orange offset, the rim is firing — and the
        // issue's "byte-identical to mtoon_default" claim is wrong on HEAD.
        let defaultPath = "/tmp/repro226/mtoon_default.vrm"
        if FileManager.default.fileExists(atPath: defaultPath) {
            let defaultModel = try await VRMModel.load(from: URL(fileURLWithPath: defaultPath), device: device)
            let defaultRenderer = VRMRenderer(device: device, config: config)
            defaultRenderer.loadModel(defaultModel)
            defaultRenderer.projectionMatrix = renderer.projectionMatrix
            defaultRenderer.viewMatrix = renderer.viewMatrix
            defaultRenderer.setLight(0, direction: SIMD3<Float>(-0.3, -0.6, -0.7),
                                     color: SIMD3<Float>(1, 1, 1),
                                     intensity: 1.0)
            defaultRenderer.disableLight(1)
            defaultRenderer.disableLight(2)
            defaultRenderer.setAmbientColor(SIMD3<Float>(0.15, 0.15, 0.15))
            let defaultPixels = try RenderTestSupport.renderFrame(
                renderer: defaultRenderer, device: device, size: size,
                pixelFormat: .rgba8Unorm_srgb,
                clearColor: MTLClearColor(red: 1.0, green: 0.0, blue: 1.0, alpha: 1.0)
            )
            let dR = RenderTestSupport.meanChannelRGBA(defaultPixels, size: size, channel: 0, xRange: xRange, yRange: yRange, skippingMagentaClear: true)
            let dG = RenderTestSupport.meanChannelRGBA(defaultPixels, size: size, channel: 1, xRange: xRange, yRange: yRange, skippingMagentaClear: true)
            let dB = RenderTestSupport.meanChannelRGBA(defaultPixels, size: size, channel: 2, xRange: xRange, yRange: yRange, skippingMagentaClear: true)
            print("[#228] mtoon_default            center (x=\(cx), y=\(cy)) R/G/B = (\(Int(dR*255)), \(Int(dG*255)), \(Int(dB*255)))")
            print("[#228] rim contribution         = (\(r8 - Int(dR*255)), \(g8 - Int(dG*255)), \(b8 - Int(dB*255)))")
        }

        // Regression assertions: rim must be visibly orange-tinted at this
        // front-facing sample point. The thresholds (Δ R-G ≥ 10, Δ G-B ≥ 5
        // bytes) leave ~30% headroom on the observed (30, 16, 0) delta so
        // small lighting recalibration in future PRs doesn't trip the test,
        // while still failing loudly if the rim path stops firing.
        XCTAssertGreaterThan(r8 - g8, 10,
            "Front-face rim must show orange (R > G + 10 bytes). Got R=\(r8), G=\(g8). " +
            "Pre-#228 VMK 0.13.6 reported R=G=B at this point — that regression must not return.")
        XCTAssertGreaterThan(g8 - b8, 5,
            "Front-face rim must show orange (G > B + 5 bytes). Got G=\(g8), B=\(b8).")
    }
}
