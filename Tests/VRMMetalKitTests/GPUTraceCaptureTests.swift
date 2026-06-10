// Copyright 2026 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Captures a `.gputrace` of the bundled avatar render for offline
/// inspection with `gpudebug` (Xcode 27 command-line GPU debugger).
///
/// Skipped unless `VRM_GPUTRACE_OUT` names the output path. Capture also
/// requires `METAL_CAPTURE_ENABLED=1` in the environment. The bundled
/// VRM 1.0 fixture is rendered by default; set `VRM_GPUTRACE_MODEL=vrm0`
/// for the VRM 0.0 fixture. `VRM_GPUTRACE_SIZE` overrides the render
/// resolution (default 512; use 2048+ for fragment-bound profiling).
/// Typical use:
///
///     make gputrace
///
/// then browse with `gpudebug -t /tmp/vrmmetalkit/avatar.gputrace`.
@MainActor
final class GPUTraceCaptureTests: XCTestCase {

    func testCaptureAvatarFrameGPUTrace() async throws {
        guard let outPath = ProcessInfo.processInfo.environment["VRM_GPUTRACE_OUT"] else {
            throw XCTSkip("Set VRM_GPUTRACE_OUT=/path/to/out.gputrace to capture a GPU trace")
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let manager = MTLCaptureManager.shared()
        guard manager.supportsDestination(.gpuTraceDocument) else {
            throw XCTSkip("GPU trace capture unsupported — run with METAL_CAPTURE_ENABLED=1")
        }

        let path: String
        let hint: String
        if ProcessInfo.processInfo.environment["VRM_GPUTRACE_MODEL"] == "vrm0" {
            path = getTestVRM00ModelPath()
            hint = testVRM00Filename
        } else {
            path = getTestVRM10ModelPath()
            hint = testVRM10Filename
        }
        try requireFixture(path, hint: hint)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        config.colorPixelFormat = .rgba8Unorm_srgb
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)

        let fov: Float = 45.0 * .pi / 180.0
        renderer.projectionMatrix = RenderTestSupport.makePerspective(fovRadians: fov, aspect: 1.0, near: 0.01, far: 100.0)
        renderer.viewMatrix = RenderTestSupport.makeLookAt(
            eye:    SIMD3<Float>(0, 1.3, 1.8),
            center: SIMD3<Float>(0, 1.3, 0),
            up:     SIMD3<Float>(0, 1, 0)
        )
        renderer.setupBrightToonLighting()

        let outURL = URL(fileURLWithPath: outPath)
        try? FileManager.default.removeItem(at: outURL)
        try FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let captureDesc = MTLCaptureDescriptor()
        captureDesc.captureObject = device
        captureDesc.destination = .gpuTraceDocument
        captureDesc.outputURL = outURL
        try manager.startCapture(with: captureDesc)

        let size = ProcessInfo.processInfo.environment["VRM_GPUTRACE_SIZE"].flatMap { Int($0) } ?? 512
        let pixels: [UInt8]
        do {
            pixels = try RenderTestSupport.renderFrame(
                renderer: renderer,
                device: device,
                size: size,
                pixelFormat: .rgba8Unorm_srgb,
                clearColor: MTLClearColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1.0)
            )
        } catch {
            manager.stopCapture()
            throw error
        }
        manager.stopCapture()

        XCTAssertFalse(pixels.allSatisfy { $0 == 0 }, "Captured frame rendered all-black")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outURL.path),
            "No .gputrace written at \(outURL.path)")
        print("[gputrace] Captured \(outURL.path)")
    }
}
