// Copyright 2026 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Materialization (avatar spawn effect) — VMK#materialize.
///
/// Covers the `VRMMaterialization` renderer API: uniform layout growth, the
/// progress-driven styles compiling and actually changing the framebuffer,
/// and the completed/disabled states being pixel-identical to a plain render.
@MainActor
final class MaterializationTests: XCTestCase {

    // MARK: - Struct layout

    /// `Uniforms` grew by one 48-byte materialization tail (3 × float4):
    /// 432 → 480 bytes. Metal-side struct and StrictMode constant must match.
    func testUniformsStructSize_includesMaterializationBlock() {
        XCTAssertEqual(MemoryLayout<Uniforms>.stride, 480,
                       "Uniforms should be 480 bytes (30 x 16-byte blocks) after the materialization tail")
        XCTAssertEqual(MetalSizeConstants.uniformsSize, 480,
                       "StrictMode uniforms size constant must track the Swift struct")
    }

    /// The packed fields land on the 16-byte block boundaries the Metal
    /// struct mirrors (432, 448, 464).
    func testMaterializationFieldOffsets() {
        XCTAssertEqual(MemoryLayout<Uniforms>.offset(of: \Uniforms.materializeParams), 432)
        XCTAssertEqual(MemoryLayout<Uniforms>.offset(of: \Uniforms.materializeColor_packed), 448)
        XCTAssertEqual(MemoryLayout<Uniforms>.offset(of: \Uniforms.materializeOrigin_packed), 464)
    }

    func testAllTwelveStylesEnumerated() {
        XCTAssertEqual(VRMMaterializationStyle.allCases.count, 12)
        XCTAssertEqual(Set(VRMMaterializationStyle.allCases.map(\.rawValue)),
                       Set(1...12))
    }

    // MARK: - API defaults

    func testRendererDefaultsToNoMaterialization() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let renderer = VRMRenderer(device: device, config: RendererConfig())
        XCTAssertNil(renderer.materialization)
    }

    func testMaterializationClampsProgress() {
        var mat = VRMMaterialization(progress: 2.5, style: .dissolve)
        XCTAssertEqual(mat.clampedProgress, 1.0)
        mat.progress = -1
        XCTAssertEqual(mat.clampedProgress, 0.0)
    }

    /// Depth-prepass skip must follow the compile-time gate: setting
    /// `materialization` on a renderer whose pipelines dead-stripped the
    /// effect must not drop early-Z.
    func testMaterializationUsesDiscardRequiresConfigFlag() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }

        var off = RendererConfig()
        off.enableMaterialization = false
        let stripped = VRMRenderer(device: device, config: off)
        stripped.materialization = VRMMaterialization(progress: 0.4, style: .dissolve)
        XCTAssertFalse(stripped.materializationUsesDiscard,
                       "compiled-out materialization must not skip the depth prepass")

        var on = RendererConfig()
        on.enableMaterialization = true
        let live = VRMRenderer(device: device, config: on)
        live.materialization = VRMMaterialization(progress: 0.4, style: .dissolve)
        XCTAssertTrue(live.materializationUsesDiscard)
        live.materialization = VRMMaterialization(progress: 0.4, style: .glitch)
        XCTAssertFalse(live.materializationUsesDiscard,
                       "glitch does not discard, so the prepass should still run")
        live.materialization = VRMMaterialization(progress: 1.0, style: .dissolve)
        XCTAssertFalse(live.materializationUsesDiscard)
        live.materialization = nil
        XCTAssertFalse(live.materializationUsesDiscard)
    }

    // MARK: - Render smoke tests (shader compiles, effect changes pixels)

    private func render(materialization: VRMMaterialization?,
                        device: MTLDevice,
                        enableMaterialization: Bool = true,
                        eye: SIMD3<Float> = SIMD3<Float>(0, 1.3, 1.8),
                        center: SIMD3<Float> = SIMD3<Float>(0, 1.3, 0)) async throws -> [UInt8] {
        let path = getTestVRM10ModelPath()
        try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)
        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        config.colorPixelFormat = .rgba8Unorm_srgb
        config.enableMaterialization = enableMaterialization
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        let fov: Float = 45.0 * .pi / 180.0
        renderer.projectionMatrix = RenderTestSupport.makePerspective(
            fovRadians: fov, aspect: 1.0, near: 0.01, far: 100.0)
        renderer.viewMatrix = RenderTestSupport.makeLookAt(
            eye: eye, center: center, up: SIMD3<Float>(0, 1, 0))
        renderer.setupBrightToonLighting()
        renderer.materialization = materialization
        return try RenderTestSupport.renderFrame(
            renderer: renderer, device: device, size: 256,
            pixelFormat: .rgba8Unorm_srgb,
            clearColor: MTLClearColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
    }

    private func differingFraction(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1.0 }
        var differing = 0
        for i in 0..<a.count where a[i] != b[i] { differing += 1 }
        return Double(differing) / Double(a.count)
    }

    /// Every style at mid-progress must (a) not crash the pipeline and
    /// (b) visibly change the frame versus a plain render.
    func testEveryStyleAtMidProgressChangesFrame() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let reference = try await render(materialization: nil, device: device)
        for style in VRMMaterializationStyle.allCases {
            let mat = VRMMaterialization(progress: 0.45, style: style,
                                         heightRange: 0.0...1.7, seed: 3)
            let frame = try await render(materialization: mat, device: device)
            let fraction = differingFraction(reference, frame)
            XCTAssertGreaterThan(fraction, 0.005,
                "style \(style) at progress 0.45 should visibly alter the frame")
        }
    }

    /// progress >= 1 must be pixel-identical to no materialization at all —
    /// the effect ends clean, with no residual tint or discard.
    func testCompletedMaterializationIsIdenticalToPlainRender() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let reference = try await render(materialization: nil, device: device)
        for style in VRMMaterializationStyle.allCases {
            let mat = VRMMaterialization(progress: 1.0, style: style,
                                         heightRange: 0.0...1.7, seed: 3)
            let frame = try await render(materialization: mat, device: device)
            let fraction = differingFraction(reference, frame)
            XCTAssertLessThan(fraction, 0.001,
                "style \(style) at progress 1.0 should render identically to no effect")
        }
    }

    /// A renderer whose config does NOT opt into materialization dead-strips
    /// the effect via function constant: even an active mid-progress
    /// materialization must render pixel-identical to a plain frame.
    func testDisabledConfigStripsEffectEntirely() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let reference = try await render(materialization: nil, device: device,
                                         enableMaterialization: false)
        let mat = VRMMaterialization(progress: 0.45, style: .dissolve,
                                     heightRange: 0.0...1.7, seed: 3)
        let frame = try await render(materialization: mat, device: device,
                                     enableMaterialization: false)
        XCTAssertLessThan(differingFraction(reference, frame), 0.001,
            "materialization must be compiled out when the config flag is off")
    }

    /// Near-zero progress on a discard style should leave the frame almost
    /// entirely background — the body has not materialized yet.
    func testDissolveAtZeroProgressDiscardsBody() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let reference = try await render(materialization: nil, device: device)
        let mat = VRMMaterialization(progress: 0.0, style: .dissolve,
                                     heightRange: 0.0...1.7, seed: 3)
        let frame = try await render(materialization: mat, device: device)
        // The frame with the body fully discarded differs from the reference
        // wherever the body was drawn.
        let fraction = differingFraction(reference, frame)
        XCTAssertGreaterThan(fraction, 0.02,
            "dissolve at progress 0 should remove (most of) the body")
    }

    /// Tron hologram fresnel is `1 - |N·V|`. Dummy interpolator `(0,0,1)`
    /// matches a frontal camera and paints camera-facing surfaces as hologram
    /// from the side. Correct V discards those faces (low fresnel). Measure
    /// the fraction of *plain-render body pixels* in the upper bbox that
    /// become clear — not a raw white count, which is similar for any V.
    func testTronShellUsesCameraViewDirection() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let eye = SIMD3<Float>(1.8, 1.3, 0)
        let center = SIMD3<Float>(0, 1.3, 0)
        let plain = try await render(materialization: nil, device: device,
                                     eye: eye, center: center)
        let mat = VRMMaterialization(progress: 0.45, style: .tron,
                                     heightRange: 0.0...1.7, seed: 3)
        let tron = try await render(materialization: mat, device: device,
                                    eye: eye, center: center)
        let size = 256
        func isNearWhite(_ pixels: [UInt8], _ i: Int) -> Bool {
            pixels[i] > 240 && pixels[i + 1] > 240 && pixels[i + 2] > 240
        }
        var minX = size, maxX = 0, minY = size, maxY = 0
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                if !isNearWhite(plain, i) {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        XCTAssertLessThan(minX, maxX, "side-camera plain render should contain the body")
        // Temple/side of the head: camera-facing, N ≈ +X. Correct V discards
        // (low fresnel); dummy (0,0,1) holograms (N·Z ≈ 0). Hair cards lower
        // in the frame face ±Z and hologram either way — do not sample those.
        let cx = (minX + maxX) / 2
        let cy = minY + 20
        var body = 0
        var discarded = 0
        for y in (cy - 6)...(cy + 6) {
            for x in (cx - 6)...(cx + 6) {
                guard (0..<size).contains(x), (0..<size).contains(y) else { continue }
                let i = (y * size + x) * 4
                if isNearWhite(plain, i) { continue }
                body += 1
                if isNearWhite(tron, i) { discarded += 1 }
            }
        }
        XCTAssertGreaterThan(body, 20, "head patch should hit the silhouette (bbox \(minX)...\(maxX)x\(minY)...\(maxY))")
        let fraction = Double(discarded) / Double(body)
        XCTAssertGreaterThan(fraction, 0.7,
            "side-camera tron must discard the camera-facing head (dummy V=(0,0,1) paints it as hologram); discarded \(discarded)/\(body) = \(fraction)")
    }
}
