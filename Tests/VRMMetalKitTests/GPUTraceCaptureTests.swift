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
/// requires `METAL_CAPTURE_ENABLED=1` in the environment.
///
/// Environment knobs:
/// - `VRM_GPUTRACE_MODEL=vrm0` renders the VRM 0.0 fixture (default: VRM 1.0).
/// - `VRM_TEST_VRM1_PATH` / `VRM_TEST_VRM0_PATH` override the fixture with a
///   full model path (e.g. point at the benchmark's `AvatarSample_A.vrm.glb`).
/// - `VRM_GPUTRACE_SIZE` overrides render resolution (default 512; use 1024
///   to match the benchmark baseline, 2048+ for fragment-bound profiling).
/// - `VRM_GPUTRACE_LIGHTING` = `bright` (default) | `standard` | `single` |
///   `ambient`. The latter three mirror `VRMBenchmark --lighting` (radiometric
///   rig) so a capture matches the baseline's shading.
/// - `VRM_GPUTRACE_VRMA=/path/to.vrma` plays an animation; the pose is advanced
///   one step per warmup frame and once more for the captured frame.
/// - `VRM_GPUTRACE_SPRING=1` enables spring-bone physics, bringing the SpringBone
///   compute encoder into the trace. `VRM_GPUTRACE_SPRING_QUALITY` =
///   off|low|medium|high|ultra (default ultra).
/// - `VRM_GPUTRACE_WARMUP` warmup frames before capture (default 30 when
///   animation or spring is active, else 0). `VRM_GPUTRACE_FPS` sets the
///   animation/sim step rate (default 60).
/// - `VRM_GPUTRACE_DEPTH_PREPASS=1` enables the opaque depth prepass
///   (`RendererConfig.enableDepthPrepass`), adding the depth-only draws to the
///   trace so its GPU-side early-Z effect can be A/B'd against a default capture.
///
/// Typical use:
///
///     make gputrace
///
/// then browse with `gpudebug -t /tmp/vrmmetalkit/avatar.gputrace`. To match the
/// 500-frame benchmark baseline (animated + spring + standard lighting at 1024):
///
///     METAL_CAPTURE_ENABLED=1 VRM_GPUTRACE_OUT=/tmp/vrmmetalkit/base.gputrace \
///       VRM_GPUTRACE_SIZE=1024 VRM_GPUTRACE_LIGHTING=standard \
///       VRM_GPUTRACE_SPRING=1 VRM_GPUTRACE_VRMA="$PWD/VRMA_01.vrma" \
///       VRM_TEST_VRM1_PATH="$PWD/AvatarSample_A.vrm.glb" \
///       swift test --filter GPUTraceCaptureTests --disable-sandbox
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

        let env = ProcessInfo.processInfo.environment
        let size = env["VRM_GPUTRACE_SIZE"].flatMap { Int($0) } ?? 512
        let fps = env["VRM_GPUTRACE_FPS"].flatMap { Double($0) } ?? 60.0
        let dt = Float(1.0 / max(fps, 1.0))
        let clearColor = MTLClearColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1.0)

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        config.colorPixelFormat = .rgba8Unorm_srgb
        config.enableDepthPrepass = ["1", "true", "yes"].contains((env["VRM_GPUTRACE_DEPTH_PREPASS"] ?? "").lowercased())
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)

        let fov: Float = 45.0 * .pi / 180.0
        renderer.projectionMatrix = RenderTestSupport.makePerspective(fovRadians: fov, aspect: 1.0, near: 0.01, far: 100.0)
        renderer.viewMatrix = RenderTestSupport.makeLookAt(
            eye:    SIMD3<Float>(0, 1.3, 1.8),
            center: SIMD3<Float>(0, 1.3, 0),
            up:     SIMD3<Float>(0, 1, 0)
        )

        // Lighting: `bright` keeps the original setupBrightToonLighting() default;
        // `standard`/`single`/`ambient` mirror VRMBenchmark --lighting (radiometric
        // rig) so a capture lines up with the baseline's shading.
        switch (env["VRM_GPUTRACE_LIGHTING"] ?? "bright").lowercased() {
        case "standard":
            renderer.setLight(0, direction: SIMD3<Float>(-0.2, 0.5, -0.85),
                              color: SIMD3<Float>(1, 1, 1), intensity: 0.3183)
            renderer.disableLight(1)
            renderer.setLight(2, direction: SIMD3<Float>(0, 0.2, 1),
                              color: SIMD3<Float>(1, 1, 1), intensity: 0.0955)
            renderer.setAmbientColor(SIMD3<Float>(0.04, 0.04, 0.04))
            renderer.setLightNormalizationMode(.radiometric)
        case "single":
            renderer.setLight(0, direction: SIMD3<Float>(-0.2, 0.5, -0.85),
                              color: SIMD3<Float>(1, 1, 1), intensity: 0.3183)
            renderer.disableLight(1)
            renderer.disableLight(2)
            renderer.setAmbientColor(SIMD3<Float>(0.04, 0.04, 0.04))
            renderer.setLightNormalizationMode(.radiometric)
        case "ambient":
            renderer.disableLight(0)
            renderer.disableLight(1)
            renderer.disableLight(2)
            renderer.setAmbientColor(SIMD3<Float>(0.04, 0.04, 0.04))
            renderer.setLightNormalizationMode(.radiometric)
        default:
            renderer.setupBrightToonLighting()
        }

        // Optional spring-bone physics. Enabling it brings the SpringBone compute
        // encoder into the captured trace. simulationDeltaTime pins the substep dt
        // so warmup settling is deterministic, not wall-clock dependent.
        let springEnabled = ["1", "true", "yes"].contains((env["VRM_GPUTRACE_SPRING"] ?? "").lowercased())
        if springEnabled {
            renderer.enableSpringBone = true
            renderer.simulationDeltaTime = TimeInterval(dt)
            switch (env["VRM_GPUTRACE_SPRING_QUALITY"] ?? "ultra").lowercased() {
            case "off":    renderer.springBoneQuality = .off
            case "low":    renderer.springBoneQuality = .low
            case "medium": renderer.springBoneQuality = .medium
            case "high":   renderer.springBoneQuality = .high
            default:       renderer.springBoneQuality = .ultra
            }
        }

        // Optional VRMA animation, advanced one dt per warmup frame and once more
        // for the captured frame so skinning, morphs, and spring physics reflect an
        // animated pose rather than the rest pose.
        var player: AnimationPlayer?
        if let vrmaPath = env["VRM_GPUTRACE_VRMA"], !vrmaPath.isEmpty {
            try requireFixture(vrmaPath, hint: (vrmaPath as NSString).lastPathComponent)
            let clip = try VRMAnimationLoader.loadVRMA(from: URL(fileURLWithPath: vrmaPath), model: model)
            let p = AnimationPlayer()
            p.load(clip)
            p.play()
            player = p
        }

        // Warmup before capture lets spring bones settle and advances the animation
        // so the captured frame isn't a cold transient. Defaults to 30 when either
        // is active, 0 otherwise (preserving the original static single-frame capture).
        let defaultWarmup = (springEnabled || player != nil) ? 30 : 0
        let warmup = env["VRM_GPUTRACE_WARMUP"].flatMap { Int($0) } ?? defaultWarmup
        for _ in 0..<warmup {
            player?.update(deltaTime: dt, model: model)
            _ = try RenderTestSupport.renderFrame(
                renderer: renderer, device: device, size: size,
                pixelFormat: .rgba8Unorm_srgb, clearColor: clearColor)
        }

        let outURL = URL(fileURLWithPath: outPath)
        try? FileManager.default.removeItem(at: outURL)
        try FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Advance one final step (outside the capture) so the captured pose continues
        // the warmed sequence; the render itself — and any spring dispatch — is what
        // the trace records.
        player?.update(deltaTime: dt, model: model)

        let captureDesc = MTLCaptureDescriptor()
        captureDesc.captureObject = device
        captureDesc.destination = .gpuTraceDocument
        captureDesc.outputURL = outURL
        try manager.startCapture(with: captureDesc)

        let pixels: [UInt8]
        do {
            pixels = try RenderTestSupport.renderFrame(
                renderer: renderer,
                device: device,
                size: size,
                pixelFormat: .rgba8Unorm_srgb,
                clearColor: clearColor
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
