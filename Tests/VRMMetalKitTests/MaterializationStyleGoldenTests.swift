// Copyright 2026 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Goldens for the twelve materialization styles that predate the charcoal
/// style, captured on the outlined skinned swatch fixture at mid progress.
/// They guard those styles against every later change to the shared
/// materialization code: each frame must reproduce within one count per
/// channel.
///
/// Regenerate only deliberately, on a checkout where the twelve styles are
/// meant to change:
/// `VMK_WRITE_MATERIALIZE_GOLDENS=<dir> swift test --filter MaterializationStyleGoldenTests --disable-sandbox`.
@MainActor
final class MaterializationStyleGoldenTests: XCTestCase {
    static let size = 256
    static let progress: Float = 0.45
    static let seed: Float = 3
    static let heightRange: ClosedRange<Float> = -0.5...0.5

    func testDissolveMatchesGolden() async throws { try await assertStyle(.dissolve) }
    func testTronMatchesGolden() async throws { try await assertStyle(.tron) }
    func testRainMatchesGolden() async throws { try await assertStyle(.rain) }
    func testGlitchMatchesGolden() async throws { try await assertStyle(.glitch) }
    func testVoxelMatchesGolden() async throws { try await assertStyle(.voxel) }
    func testBlueprintMatchesGolden() async throws { try await assertStyle(.blueprint) }
    func testChromeMatchesGolden() async throws { try await assertStyle(.chrome) }
    func testShutterMatchesGolden() async throws { try await assertStyle(.shutter) }
    func testHexMatchesGolden() async throws { try await assertStyle(.hex) }
    func testSignalMatchesGolden() async throws { try await assertStyle(.signal) }
    func testFrostMatchesGolden() async throws { try await assertStyle(.frost) }
    func testConstellationMatchesGolden() async throws { try await assertStyle(.constellation) }

    private func assertStyle(_ style: VRMMaterializationStyle) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let model = try await Self.loadSwatches(device: device)
        let rendered = try Self.render(model: model, style: style, device: device)
        try assertGolden(rendered, raw: Int(style.rawValue))
    }

    private func assertGolden(_ rendered: [UInt8], raw: Int) throws {
        let name = "golden_style_\(raw)"
        if let outputDirectory = ProcessInfo.processInfo.environment["VMK_WRITE_MATERIALIZE_GOLDENS"] {
            let compressed = try (Data(rendered) as NSData).compressed(using: .zlib) as Data
            let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(name).rgba.zlib")
            try compressed.write(to: url)
            return
        }

        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "rgba.zlib",
            subdirectory: "TestData/Materialize") else {
            return XCTFail("Missing golden TestData/Materialize/\(name).rgba.zlib")
        }
        let golden = try (Data(contentsOf: url) as NSData).decompressed(using: .zlib) as Data
        XCTAssertEqual(golden.count, rendered.count, "style \(raw)")
        guard golden.count == rendered.count else { return }

        var changed = 0
        var maxDelta = 0
        golden.withUnsafeBytes { raw in
            let reference = raw.bindMemory(to: UInt8.self)
            for i in 0..<rendered.count {
                let delta = abs(Int(reference[i]) - Int(rendered[i]))
                if delta > 1 { changed += 1 }
                maxDelta = max(maxDelta, delta)
            }
        }
        XCTAssertEqual(changed, 0,
            "style \(raw): \(changed) bytes differ from the golden by more than 1 (max delta \(maxDelta)).")
        if changed > 0 {
            let diffURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)_actual.rgba")
            try? Data(rendered).write(to: diffURL)
        }
    }

    private static func loadSwatches(device: MTLDevice) async throws -> VRMModel {
        guard let url = Bundle.module.url(
            forResource: "finish_swatches_skinned",
            withExtension: "vrm",
            subdirectory: "TestData/MToon") else {
            throw XCTSkip("finish_swatches_skinned.vrm fixture missing")
        }
        return try await VRMModel.load(from: url, device: device)
    }

    private static func render(model: VRMModel, style: VRMMaterializationStyle, device: MTLDevice) throws -> [UInt8] {
        var config = RendererConfig()
        config.colorPixelFormat = .rgba8Unorm
        config.sampleCount = 1
        config.enableMaterialization = true
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.disableLegacyAnimation = true
        renderer.outlineWidth = 40
        renderer.setLight(0, direction: SIMD3<Float>(-0.3, -0.4, -0.9), color: SIMD3<Float>(1, 1, 1), intensity: 2.5)
        renderer.setLight(1, direction: SIMD3<Float>(0.6, -0.2, -0.5), color: SIMD3<Float>(0.6, 0.7, 1.0), intensity: 0.8)
        renderer.disableLight(2)
        renderer.setAmbientColor(SIMD3<Float>(0.08, 0.08, 0.08))
        renderer.viewMatrix = RenderTestSupport.makeLookAt(
            eye: SIMD3<Float>(0.4, 0.5, 5),
            center: SIMD3<Float>(0, 0, 0),
            up: SIMD3<Float>(0, 1, 0))
        renderer.projectionMatrix = RenderTestSupport.makePerspective(
            fovRadians: Float.pi / 4,
            aspect: 1,
            near: 0.1,
            far: 100)
        renderer.materialization = VRMMaterialization(
            progress: progress, style: style, heightRange: heightRange, seed: seed)
        return try RenderTestSupport.renderFrame(
            renderer: renderer,
            device: device,
            size: size,
            pixelFormat: .rgba8Unorm,
            clearColor: MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1))
    }
}
