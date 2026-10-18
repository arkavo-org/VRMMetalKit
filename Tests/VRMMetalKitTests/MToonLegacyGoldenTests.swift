// Copyright 2026 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Byte-exact goldens for the default (feature-off) renderer output on the
/// rigid and skinned swatch fixtures, captured through `VRMRenderer` at
/// VRMMetalKit 1.1.2. They guard every opt-in shading and outline feature:
/// with the defaults left alone the production pipelines must reproduce the
/// 1.1.2 frame exactly, including both outline hull paths (merged for
/// single-sided materials, dedicated for double-sided ones).
///
/// Regenerate only on a 1.1.2 checkout, never from the current tree:
/// `VMK_WRITE_MTOON_GOLDENS=<dir> swift test --filter MToonLegacyGoldenTests`.
@MainActor
final class MToonLegacyGoldenTests: XCTestCase {
    enum Fixture: String, CaseIterable {
        case rigid = "finish_swatches"
        case skinned = "finish_swatches_skinned"
    }

    enum Scene: String, CaseIterable {
        case defaults
        case outlinedSingleSided
        case outlinedDoubleSided
    }

    static let size = 256

    func testRigidDefaultsMatch112() async throws { try await assertGolden(.rigid, .defaults) }
    func testRigidMergedHullMatches112() async throws { try await assertGolden(.rigid, .outlinedSingleSided) }
    func testRigidDedicatedHullMatches112() async throws { try await assertGolden(.rigid, .outlinedDoubleSided) }
    func testSkinnedDefaultsMatch112() async throws { try await assertGolden(.skinned, .defaults) }
    func testSkinnedMergedHullMatches112() async throws { try await assertGolden(.skinned, .outlinedSingleSided) }
    func testSkinnedDedicatedHullMatches112() async throws { try await assertGolden(.skinned, .outlinedDoubleSided) }

    private func assertGolden(_ fixture: Fixture, _ scene: Scene) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let rendered = try await Self.render(fixture: fixture, scene: scene, device: device)
        let name = "golden_\(fixture.rawValue)_\(scene.rawValue)"

        if let outputDirectory = ProcessInfo.processInfo.environment["VMK_WRITE_MTOON_GOLDENS"] {
            let compressed = try (Data(rendered) as NSData).compressed(using: .zlib) as Data
            let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(name).rgba.zlib")
            try compressed.write(to: url)
            return
        }

        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "rgba.zlib",
            subdirectory: "TestData/MToon") else {
            return XCTFail("Missing golden TestData/MToon/\(name).rgba.zlib")
        }
        let golden = try (Data(contentsOf: url) as NSData).decompressed(using: .zlib) as Data
        XCTAssertEqual(golden.count, rendered.count)
        guard golden.count == rendered.count else { return }

        var changed = 0
        var maxDelta = 0
        golden.withUnsafeBytes { raw in
            let reference = raw.bindMemory(to: UInt8.self)
            for i in 0..<rendered.count where reference[i] != rendered[i] {
                changed += 1
                maxDelta = max(maxDelta, abs(Int(reference[i]) - Int(rendered[i])))
            }
        }
        XCTAssertEqual(changed, 0,
            "\(fixture.rawValue)/\(scene.rawValue): \(changed) bytes differ from the 1.1.2 frame (max delta \(maxDelta)). Default renderer output must be byte-identical to 1.1.2.")
        if changed > 0 {
            let diffURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)_actual.rgba")
            try? Data(rendered).write(to: diffURL)
        }
    }

    static func render(fixture: Fixture, scene: Scene, device: MTLDevice) async throws -> [UInt8] {
        guard let url = Bundle.module.url(
            forResource: fixture.rawValue,
            withExtension: "vrm",
            subdirectory: "TestData/MToon") else {
            throw XCTSkip("\(fixture.rawValue).vrm fixture missing")
        }
        let model = try await VRMModel.load(from: url, device: device)
        if scene == .outlinedDoubleSided {
            for material in model.materials { material.doubleSided = true }
        }

        var config = RendererConfig()
        config.colorPixelFormat = .rgba8Unorm
        config.sampleCount = 1
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.disableLegacyAnimation = true
        if scene != .defaults {
            renderer.outlineWidth = 40
        }
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
        return try RenderTestSupport.renderFrame(
            renderer: renderer,
            device: device,
            size: size,
            pixelFormat: .rgba8Unorm,
            clearColor: MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1))
    }
}
