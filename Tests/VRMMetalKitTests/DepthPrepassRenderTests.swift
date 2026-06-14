// Copyright 2026 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Verifies the experimental opaque depth prepass (#195) does not change the
/// rendered image: with `.lessEqual` + no-write on the opaque main pass, enabling
/// the prepass must produce a pixel-identical (or near-identical) frame versus the
/// single-pass default. A divergence here means the prepass depth does not match
/// the main pass — i.e. the shared `vrm_skin` helper drifted.
@MainActor
final class DepthPrepassRenderTests: XCTestCase {

    func testDepthPrepassProducesIdenticalImage() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let path = getTestVRM10ModelPath()
        try requireFixture(path, hint: testVRM10Filename)

        func render(depthPrepass: Bool) async throws -> [UInt8] {
            let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)
            var config = RendererConfig()
            config.sampleCount = 1
            config.strict = .off
            config.colorPixelFormat = .rgba8Unorm_srgb
            config.enableDepthPrepass = depthPrepass
            let renderer = VRMRenderer(device: device, config: config)
            renderer.loadModel(model)
            let fov: Float = 45.0 * .pi / 180.0
            renderer.projectionMatrix = RenderTestSupport.makePerspective(
                fovRadians: fov, aspect: 1.0, near: 0.01, far: 100.0)
            renderer.viewMatrix = RenderTestSupport.makeLookAt(
                eye: SIMD3<Float>(0, 1.3, 1.8),
                center: SIMD3<Float>(0, 1.3, 0),
                up: SIMD3<Float>(0, 1, 0))
            renderer.setupBrightToonLighting()
            return try RenderTestSupport.renderFrame(
                renderer: renderer, device: device, size: 512,
                pixelFormat: .rgba8Unorm_srgb,
                clearColor: MTLClearColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1.0))
        }

        let reference = try await render(depthPrepass: false)
        let prepass = try await render(depthPrepass: true)
        XCTAssertEqual(reference.count, prepass.count)

        // Count differing bytes. `.lessEqual` early-Z must not drop visible
        // fragments, so the images should be identical or differ only in a
        // negligible fraction of subpixel-edge bytes.
        var differing = 0
        var maxDelta = 0
        for i in 0..<reference.count where reference[i] != prepass[i] {
            differing += 1
            maxDelta = max(maxDelta, abs(Int(reference[i]) - Int(prepass[i])))
        }
        let fraction = Double(differing) / Double(reference.count)
        XCTAssertLessThan(fraction, 0.001,
            "Depth prepass changed \(differing) bytes (\(String(format: "%.4f%%", fraction * 100)), maxDelta \(maxDelta)) — expected pixel-identical")
    }
}
