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
import CryptoKit
@testable import VRMMetalKit

/// VMK#239: shadingShift / shadingToony boundary collapse — render-level
/// verification that the parser's Int-vs-Double fix from 0.15.0
/// (`MToonParameterFlowTests`) actually produces distinct rendered output
/// at the MToon shader boundaries. The parser tests confirm boundary
/// values reach `VRMMToonMaterial`; this test closes the end-to-end loop
/// by asserting the shader differentiates them in pixel space.
///
/// Pattern mirrors `SpringBoneRenderConformanceTests` — same conformance
/// camera + lighting + 256×256 PNG hash methodology — so the surface is
/// directly comparable to the existing spring-bone boundary coverage. The
/// renderer uses `synchronousSpringBone = true` so the test is
/// determinism-clean (no wall-clock substep jitter, per VMK#283).
final class MToonShadingBoundaryRenderTests: XCTestCase {

    // Conformance camera + lighting (matches test.yaml + SpringBoneRenderConformanceTests).
    private let cameraPosition = SIMD3<Float>(0, 1.4, 1.5)
    private let cameraTarget   = SIMD3<Float>(0, 1.4, 0)
    private let cameraUp       = SIMD3<Float>(0, 1, 0)
    private let cameraFovYDeg: Float = 30
    private let keyLightDir   = SIMD3<Float>(-0.3, -0.6, -0.7)
    private let keyLightColor = SIMD3<Float>(1, 1, 1)
    private let keyLightIntensity: Float = 1.0
    private let ambientColor: SIMD3<Float> = SIMD3<Float>(0.5, 0.5, 0.5) * 0.3
    private let renderWidth = 256
    private let renderHeight = 256

    /// shadingShift sweep at boundary values: −1, 0 (default), +1. These
    /// are the literals the 0.15.0 parse fix (Int-vs-Double coercion) was
    /// shown to round-trip correctly. The shader must turn them into
    /// distinct pixels.
    func testShadingShiftBoundarySweepRendersDistinctHashes() async throws {
        try await assertDistinctHashes(fixtures: [
            "mtoon_shadingShift_neg1",
            "mtoon_default",
            "mtoon_shadingShift_1"
        ], label: "shadingShift")
    }

    /// shadingToony sweep at boundary values: 0, 0.9 (default), 1.0. The
    /// 0 and 1 endpoints are the parse-coercion failure surface from
    /// VMK#239; they must render distinctly from each other and from the
    /// default.
    func testShadingToonyBoundarySweepRendersDistinctHashes() async throws {
        try await assertDistinctHashes(fixtures: [
            "mtoon_shadingToony_0",
            "mtoon_default",
            "mtoon_shadingToony_1"
        ], label: "shadingToony")
    }

    /// rimLightingMix sweep at boundary values: 0, 0.5, 1.0. Same
    /// boundary-coercion bug class as shadingShift/shadingToony — closed
    /// alongside in 0.15.0 — and the existing fixtures bundle the
    /// intermediate `0p5` value so it's a tighter sweep than the others.
    func testRimLightingMixBoundarySweepRendersDistinctHashes() async throws {
        try await assertDistinctHashes(fixtures: [
            "mtoon_rimLightingMix_0",
            "mtoon_rimLightingMix_0p5",
            "mtoon_rimLightingMix_1"
        ], label: "rimLightingMix")
    }

    // MARK: - Harness

    private func assertDistinctHashes(fixtures: [String], label: String) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }
        guard let queue = device.makeCommandQueue() else {
            XCTFail("Could not create command queue"); return
        }

        let cameraPos = cameraPosition
        let cameraTgt = cameraTarget
        let cameraUpV = cameraUp
        let fovYDeg = cameraFovYDeg
        let lightDir = keyLightDir
        let lightCol = keyLightColor
        let lightInt = keyLightIntensity
        let ambient = ambientColor
        let w = renderWidth
        let h = renderHeight

        var hashes: [String: String] = [:]
        for fixture in fixtures {
            let model = try await VRMModel.load(
                from: try bundleURL(for: fixture),
                device: device
            )
            hashes[fixture] = await MainActor.run {
                Self.renderFixtureToHash(
                    model: model, device: device, commandQueue: queue,
                    cameraPosition: cameraPos, cameraTarget: cameraTgt, cameraUp: cameraUpV,
                    cameraFovYDeg: fovYDeg,
                    keyLightDir: lightDir, keyLightColor: lightCol, keyLightIntensity: lightInt,
                    ambientColor: ambient,
                    renderWidth: w, renderHeight: h
                )
            }
        }

        let unique = Set(hashes.values)
        XCTAssertEqual(unique.count, fixtures.count,
            "VMK#239: \(label) sweep must render \(fixtures.count) distinct " +
            "pixel hashes (one per boundary value). Got \(unique.count) " +
            "distinct out of \(fixtures.count) fixtures. Per-fixture hashes: " +
            "\(hashes.map { "\($0.key) → \($0.value.prefix(8))" }.sorted().joined(separator: ", ")). " +
            "A collision means the MToon shader is collapsing parser-fixed " +
            "boundary values into the same rendered output — the original " +
            "VMK#239 signature, re-emerging.")
    }

    private func bundleURL(for fixture: String) throws -> URL {
        guard let url = Bundle.module.url(
            forResource: fixture,
            withExtension: "vrm",
            subdirectory: "TestData/Conformance"
        ) else {
            throw XCTSkip("\(fixture).vrm not bundled in Conformance/")
        }
        return url
    }

    @MainActor
    private static func renderFixtureToHash(
        model: VRMModel,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        cameraPosition: SIMD3<Float>,
        cameraTarget: SIMD3<Float>,
        cameraUp: SIMD3<Float>,
        cameraFovYDeg: Float,
        keyLightDir: SIMD3<Float>,
        keyLightColor: SIMD3<Float>,
        keyLightIntensity: Float,
        ambientColor: SIMD3<Float>,
        renderWidth: Int,
        renderHeight: Int
    ) -> String {
        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        // Determinism-clean render path. simulationDeltaTime is irrelevant
        // for these static MToon fixtures (no animation loop runs), but
        // synchronousSpringBone forces the deterministic-timestep default
        // so the test is robust to future fixture changes that add hair.
        config.synchronousSpringBone = true
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)

        let aspect = Float(renderWidth) / Float(renderHeight)
        let fovY = cameraFovYDeg * .pi / 180
        renderer.projectionMatrix = perspectiveProjection(
            fovY: fovY, aspect: aspect, near: 0.05, far: 100
        )
        renderer.viewMatrix = lookAt(
            eye: cameraPosition, target: cameraTarget, up: cameraUp
        )
        renderer.setLight(0, direction: keyLightDir, color: keyLightColor,
                          intensity: keyLightIntensity)
        renderer.setAmbientColor(ambientColor)

        let colorTexture = makeTexture(
            device: device, width: renderWidth, height: renderHeight,
            format: .bgra8Unorm, usage: [.renderTarget, .shaderRead], storage: .shared
        )
        let depthTexture = makeTexture(
            device: device, width: renderWidth, height: renderHeight,
            format: .depth32Float, usage: [.renderTarget], storage: .private
        )
        guard let cb = commandQueue.makeCommandBuffer() else {
            XCTFail("makeCommandBuffer failed"); return ""
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = colorTexture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.depthAttachment.texture = depthTexture
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.storeAction = .dontCare
        rpd.depthAttachment.clearDepth = 1.0
        renderer.drawOffscreenHeadless(to: colorTexture, depth: depthTexture,
                                        commandBuffer: cb, renderPassDescriptor: rpd)
        let sem = DispatchSemaphore(value: 0)
        cb.addCompletedHandler { _ in sem.signal() }
        cb.commit()
        sem.wait()

        let bytesPerRow = renderWidth * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * renderHeight)
        pixels.withUnsafeMutableBufferPointer { ptr in
            colorTexture.getBytes(ptr.baseAddress!, bytesPerRow: bytesPerRow,
                                  from: MTLRegionMake2D(0, 0, renderWidth, renderHeight),
                                  mipmapLevel: 0)
        }
        let digest = SHA256.hash(data: Data(pixels))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Camera helpers (copy of conformance camera convention)

    private static func perspectiveProjection(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0)
        )
    }

    private static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = normalize(eye - target)
        let x = normalize(cross(up, z))
        let y = cross(z, x)
        return simd_float4x4(
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
        )
    }

    private static func makeTexture(
        device: MTLDevice, width: Int, height: Int,
        format: MTLPixelFormat, usage: MTLTextureUsage, storage: MTLStorageMode
    ) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false
        )
        desc.usage = usage
        desc.storageMode = storage
        return device.makeTexture(descriptor: desc)!
    }
}
