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

/// Regression coverage for vrm-conformance issue #213. The corpus reported
/// VMK rendering `mtoon_shadingToony_0..0p75` and `mtoon_shadingShift_0p8/1`
/// as "flat mid-gray" against UniVRM's spec-correct Lambert gradient.
///
/// Root cause was an input-convention mismatch, not curve math: VMK applies
/// `BRDF_LAMBERT_NORM = 1/π` (correctly, per #205), but the conformance
/// adapter passed `intensity: 1.0` raw where UniVRM Built-in RP's
/// `_LightColor0` and three-vrm's adapter both pre-absorb π into the light
/// value. Net VMK brightness was ~32% of the reference cluster at the same
/// plan inputs, collapsing the visible Lambert curve into the ambient floor.
///
/// `LightNormalizationMode.radiometric` (new in this PR) sets
/// `lightNormalizationFactor = π`, which cancels the shader's `1/π` and
/// makes a caller-passed `intensity: 1.0` produce reference-matching
/// brightness.
@MainActor
final class MToonRadiometricLightingTests: XCTestCase {

    private struct ConformanceLighting {
        static let lightDir = SIMD3<Float>(-0.3, -0.6, -0.7)
        static let lightColor = SIMD3<Float>(1, 1, 1)
        static let lightIntensity: Float = 1.0
        static let ambient = SIMD3<Float>(0.15, 0.15, 0.15) // (0.5, 0.5, 0.5) × 0.3
    }

    /// Set up the renderer with the verbatim `mtoon_*.test.yaml` camera + lighting
    /// (eye=(0, 1.4, 1.5) looking at (0, 1.4, 0), 30° FOV, single directional + small
    /// ambient) and the `.radiometric` normalization mode.
    private func configureConformanceScene(_ renderer: VRMRenderer) {
        let fov: Float = 30.0 * .pi / 180.0
        renderer.projectionMatrix = RenderTestSupport.makePerspective(
            fovRadians: fov, aspect: 1.0, near: 0.01, far: 100.0)
        renderer.viewMatrix = RenderTestSupport.makeLookAt(
            eye:    SIMD3<Float>(0, 1.4, 1.5),
            center: SIMD3<Float>(0, 1.4, 0),
            up:     SIMD3<Float>(0, 1, 0))
        renderer.setLight(0,
                          direction: ConformanceLighting.lightDir,
                          color: ConformanceLighting.lightColor,
                          intensity: ConformanceLighting.lightIntensity)
        renderer.disableLight(1)
        renderer.disableLight(2)
        renderer.setAmbientColor(ConformanceLighting.ambient)
        renderer.setLightNormalizationMode(.radiometric)
    }

    /// `mtoon_shadingToony_0p25` — pre-#213 VMK rendered this as flat ~0.32
    /// linear gray (the issue's "flat mid-gray" symptom — visible disc sat at
    /// the ambient floor because /π darkened direct lighting to ~32% of UniVRM).
    /// With `.radiometric` the shader's `/π` is cancelled and the visible disc
    /// renders at spec-correct brightness (lit pole > 0.50 linear, matching
    /// UniVRM's ~0.75).
    ///
    /// Note: the conformance plan's light `(-0.3, -0.6, -0.7)` has a strong
    /// `+Z` component (light comes from in front of camera-right-above), so
    /// most of the visible disc is on the lit hemisphere. The "Lambert
    /// gradient" the issue references is real but compressed across the disc;
    /// the dominant signal in the fix is **brightness uplift**, not gradient
    /// spread. Two-point sampling across the disc captures both signals.
    func testRadiometricRestoresLambertGradientOnShadingToony0p25() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let path = "/tmp/repro226/mtoon_shadingToony_0p25.vrm"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("vrm-conformance asset not at \(path). " +
                "Regenerate from a checkout of github.com/arkavo-org/vrm-conformance with: " +
                "`cargo run --release -p vrm-asset-generator -- emit-sweep --output-dir /tmp/repro226`")
        }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        config.colorPixelFormat = .rgba8Unorm_srgb
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        configureConformanceScene(renderer)

        let size = 256
        let pixels = try RenderTestSupport.renderFrame(
            renderer: renderer, device: device, size: size,
            pixelFormat: .rgba8Unorm_srgb,
            clearColor: MTLClearColor(red: 1.0, green: 0.0, blue: 1.0, alpha: 1.0))

        // Light direction `(-0.3, -0.6, -0.7)` (light traveling toward scene)
        // means the source is at world `(+0.3, +0.6, +0.7)`. On a sphere
        // centered at `(0, 1.4, 0)` viewed from `(0, 1.4, 1.5)`:
        //   - Upper-right of disc (world +X +Y) — normal aligned with light
        //     direction → highest NdotL (~0.94). Screen pixel (0.62, 0.38).
        //   - Center of disc (world +Z) — normal ≈ (0,0,1), NdotL ≈ 0.7.
        //   - Lower-left of disc (world -X -Y) — normal ≈ (-0.5,-0.5,0.7),
        //     NdotL ≈ 0.04. Screen pixel (0.38, 0.62).
        let litPoleC = (Int(Double(size) * 0.60)...Int(Double(size) * 0.64))
        let litPoleR = (Int(Double(size) * 0.36)...Int(Double(size) * 0.40))
        let termC = (Int(Double(size) * 0.48)...Int(Double(size) * 0.52))
        let termR = (Int(Double(size) * 0.48)...Int(Double(size) * 0.52))
        let dimC = (Int(Double(size) * 0.36)...Int(Double(size) * 0.40))
        let dimR = (Int(Double(size) * 0.60)...Int(Double(size) * 0.64))

        let litLuma = RenderTestSupport.meanRec709LumaRGBA(pixels, size: size,
                                                            xRange: litPoleC, yRange: litPoleR)
        let termLuma = RenderTestSupport.meanRec709LumaRGBA(pixels, size: size,
                                                             xRange: termC, yRange: termR)
        let dimLuma = RenderTestSupport.meanRec709LumaRGBA(pixels, size: size,
                                                            xRange: dimC, yRange: dimR)

        print("[#213] shadingToony_0p25 lit=\(litLuma) term=\(termLuma) dim=\(dimLuma) Δ=\(litLuma - dimLuma)")

        // Brightness uplift — the dominant signal. Pre-#213 all three sample
        // regions sat near 0.32 (the "flat mid-gray" the issue reports). With
        // .radiometric the lit pole and disc center should be ≥0.70 linear.
        // Thresholds floored at 0.50 leave ~30% headroom.
        XCTAssertGreaterThan(litLuma, 0.50,
            "Lit pole brightness must rise with .radiometric. Got luma=\(litLuma). " +
            "Pre-#213 VMK collapsed to ~0.32 across the whole visible disc.")
        XCTAssertGreaterThan(termLuma, 0.50,
            "Disc center brightness must rise with .radiometric. Got luma=\(termLuma).")
        // Gradient — must be visible in the right direction. Observed Δ ≈ 0.106
        // on macOS arm64 against this conformance asset; threshold 0.05 leaves
        // ~50% headroom while still failing loudly if the lit/dim signal
        // collapses (the symptom #213 originally surfaced as Δ ≈ 0).
        XCTAssertGreaterThan(litLuma - dimLuma, 0.05,
            "Lambert gradient must be visible (lit − dim > 0.05). " +
            "Got lit=\(litLuma), dim=\(dimLuma), Δ=\(litLuma - dimLuma).")
    }

    /// `mtoon_shadingShift_0p8` — at this strongly-positive shift the lit/shade
    /// boundary is pushed far toward the shadow pole, leaving most of the
    /// visible hemisphere fully lit. Pre-#213 VMK rendered this as flat mid-
    /// gray (identical to `shadingShift_0`). With `.radiometric` the lit pole
    /// should read substantially brighter than the issue's reported VMK ≈0.32.
    func testRadiometricFixesShadingShift0p8FlatGray() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let path = "/tmp/repro226/mtoon_shadingShift_0p8.vrm"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("vrm-conformance asset not at \(path).")
        }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        config.colorPixelFormat = .rgba8Unorm_srgb
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        configureConformanceScene(renderer)

        let size = 256
        let pixels = try RenderTestSupport.renderFrame(
            renderer: renderer, device: device, size: size,
            pixelFormat: .rgba8Unorm_srgb,
            clearColor: MTLClearColor(red: 1.0, green: 0.0, blue: 1.0, alpha: 1.0))

        // Sample at sphere center on the visible disc — the issue reports VMK
        // pre-fix renders flat gray (~0.32 linear) where UniVRM produces ~0.75
        // (mostly-lit sphere). With shift=0.8 the visible disc should be at
        // or near the lit-pole brightness across most of its area.
        let cx = Int(Double(size) * 0.50)
        let cy = Int(Double(size) * 0.50)
        let xRange = (cx - 4)...(cx + 4)
        let yRange = (cy - 4)...(cy + 4)
        let centerLuma = RenderTestSupport.meanRec709LumaRGBA(pixels, size: size,
                                                                xRange: xRange, yRange: yRange)

        print("[#213] shadingShift_0p8 center luma=\(centerLuma) — issue reports VMK pre-fix ≈0.32, UniVRM ≈0.75")

        XCTAssertGreaterThan(centerLuma, 0.50,
            "shadingShift_0p8 should render mostly-lit with .radiometric. " +
            "Got luma=\(centerLuma). Pre-#213 collapsed to ~0.32; UniVRM ~0.75.")
    }

    /// Lock-in for the constraint that production apps using the auto-installed
    /// `setup3PointLighting()` (per #147) do not inadvertently inherit
    /// `.radiometric`. The CLI tools explicitly opt in; the auto-default stays
    /// at `.automatic` so existing app behaviour is preserved across this PR.
    func testSetup3PointLightingPreservesAutomaticMode() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let config = RendererConfig()
        let renderer = VRMRenderer(device: device, config: config)
        // init auto-invokes setup3PointLighting; verify the normalization mode
        // sentinel is .automatic (not .radiometric, not .manual).
        if case .automatic = renderer.lightNormalizationMode {
            // ok
        } else {
            XCTFail("Auto-installed setup3PointLighting must leave lightNormalizationMode at .automatic. " +
                    "Found \(renderer.lightNormalizationMode).")
        }
    }

    /// Code-path verification: `setupBrightToonLighting()` (the `VRMRender`
    /// CLI preset) must opt into `.radiometric`, not the previous
    /// `.manual(1.25)`. Without this assertion, a future revert of the preset
    /// could silently re-enter the dim photometric path while the bundled
    /// `AvatarSample_A.png` regression test (`chest luma > 0.30`) keeps
    /// passing on its loose threshold.
    func testSetupBrightToonLightingOptsIntoRadiometric() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let renderer = VRMRenderer(device: device, config: RendererConfig())
        renderer.setupBrightToonLighting()
        if case .radiometric = renderer.lightNormalizationMode {
            // ok
        } else {
            XCTFail("setupBrightToonLighting must set lightNormalizationMode to .radiometric. " +
                    "Found \(renderer.lightNormalizationMode).")
        }
    }
}
