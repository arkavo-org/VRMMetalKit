// Copyright 2026 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Guards bitwise render determinism across independent loads of the same
/// model file in one process.
///
/// Two regressions historically broke this and surfaced as hair-tip pixel
/// flicker between loads (both in `SpringBoneComputeSystem.warmupPhysics`,
/// which `VRMRenderer.loadModel` runs before the first frame):
///
/// 1. The warmup's XPBD steps dispatched `springBoneApplyCenterDelta`
///    against an uninitialized `centerDeltaBuffer` — zero pages on the
///    process's first load (benign no-op), recycled heap garbage afterward.
/// 2. Warmup committed each GPU step asynchronously, then immediately
///    rewrote the shared buffers (global params, collider/root positions)
///    the in-flight step was reading.
///
/// Golden-image testing and the MSAA A2C determinism control both depend
/// on this invariant.
@MainActor
final class LoadDeterminismTests: XCTestCase {

    func testFreshLoadsRenderBitwiseIdentically() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let modelPath = getTestVRM10ModelPath()
        try requireFixture(modelPath, hint: testVRM10Filename)

        let size = 384
        func renderFreshLoad() async throws -> [UInt8] {
            var config = RendererConfig(strict: .off, sampleCount: 1)
            config.synchronousSpringBone = true
            let renderer = VRMRenderer(device: device, config: config)
            let model = try await VRMModel.load(
                from: URL(fileURLWithPath: modelPath), device: device)
            renderer.loadModel(model)
            renderer.projectionMatrix = RenderTestSupport.makePerspective(
                fovRadians: 30 * .pi / 180, aspect: 1, near: 0.05, far: 100)
            renderer.viewMatrix = RenderTestSupport.makeLookAt(
                eye: SIMD3<Float>(0, 1.45, 1.5),
                center: SIMD3<Float>(0, 1.45, 0),
                up: SIMD3<Float>(0, 1, 0))
            return try RenderTestSupport.renderFrame(
                renderer: renderer, device: device, size: size,
                pixelFormat: .bgra8Unorm,
                clearColor: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1))
        }

        let first = try await renderFreshLoad()
        let second = try await renderFreshLoad()

        var differingPixels = 0
        for p in stride(from: 0, to: size * size * 4, by: 4)
        where first[p] != second[p] || first[p + 1] != second[p + 1]
            || first[p + 2] != second[p + 2] {
            differingPixels += 1
        }
        XCTAssertEqual(differingPixels, 0,
            "Two independent loads of the same model must render identically; "
            + "\(differingPixels) pixels differ. Look for uninitialized GPU "
            + "buffers or CPU/GPU races in load-time work (e.g. spring-bone "
            + "warmup).")
    }
}
