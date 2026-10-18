// Copyright 2026 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Renders the MToon swatch fixtures (three spheres at x = -1.3, 0, 1.3, radius
/// 0.5) through `VRMRenderer` for the finish, outline and contact-shadow tests.
/// With the default camera the spheres land in the left, middle and right
/// thirds of a square frame.
@MainActor
enum SwatchScene {
    enum Fixture: String {
        case rigid = "finish_swatches"
        case skinned = "finish_swatches_skinned"
        case floor = "floor_plane"
    }

    struct Setup {
        var config = RendererConfig()
        var size = 512
        var eye = SIMD3<Float>(0, 0, 5)
        var center = SIMD3<Float>(0, 0, 0)
        var lightDirection = SIMD3<Float>(-0.3, -0.4, -0.9)
        var lightIntensity: Float = 2.5
        var normalization: VRMRenderer.LightNormalizationMode = .automatic
        var outlineWidth: Float = 0.02
        var outlineScale: Float = 1.0
        var outlineMinimumPixels: Float = 0
        var clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
    }

    static func load(_ fixture: Fixture, device: MTLDevice) async throws -> VRMModel {
        guard let url = Bundle.module.url(
            forResource: fixture.rawValue,
            withExtension: "vrm",
            subdirectory: "TestData/MToon") else {
            throw XCTSkip("\(fixture.rawValue).vrm fixture missing")
        }
        return try await VRMModel.load(from: url, device: device)
    }

    static func makeRenderer(model: VRMModel, device: MTLDevice, setup: Setup) -> VRMRenderer {
        var config = setup.config
        config.colorPixelFormat = .rgba8Unorm
        config.sampleCount = 1
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.disableLegacyAnimation = true
        renderer.outlineWidth = setup.outlineWidth
        renderer.outlineScale = setup.outlineScale
        renderer.outlineMinimumPixels = setup.outlineMinimumPixels
        renderer.setLightNormalizationMode(setup.normalization)
        renderer.setLight(0, direction: setup.lightDirection, color: SIMD3<Float>(1, 1, 1), intensity: setup.lightIntensity)
        renderer.disableLight(1)
        renderer.disableLight(2)
        renderer.setAmbientColor(SIMD3<Float>(0.08, 0.08, 0.08))
        renderer.viewMatrix = RenderTestSupport.makeLookAt(eye: setup.eye, center: setup.center, up: SIMD3<Float>(0, 1, 0))
        renderer.projectionMatrix = RenderTestSupport.makePerspective(
            fovRadians: Float.pi / 4, aspect: 1, near: 0.1, far: 100)
        return renderer
    }

    static func render(
        _ model: VRMModel,
        device: MTLDevice,
        setup: Setup = Setup(),
        prepare: ((VRMRenderer) -> Void)? = nil
    ) throws -> [UInt8] {
        let renderer = makeRenderer(model: model, device: device, setup: setup)
        prepare?(renderer)
        return try RenderTestSupport.renderFrame(
            renderer: renderer,
            device: device,
            size: setup.size,
            pixelFormat: .rgba8Unorm,
            clearColor: setup.clearColor)
    }

    // MARK: - Pixel statistics

    struct RegionStats {
        var changedPixels = 0
        var maxDelta = 0
        var maxLuma = 0.0
        /// Sum over changed pixels of the luma gained (positive) or lost.
        var lumaDelta = 0.0
    }

    /// Columns of the left, middle and right swatch at the default camera.
    static func third(_ index: Int, size: Int) -> Range<Int> {
        let width = size / 3
        return (index * width)..<(index == 2 ? size : (index + 1) * width)
    }

    static func luma(_ bytes: [UInt8], _ i: Int) -> Double {
        (0.2126 * Double(bytes[i]) + 0.7152 * Double(bytes[i + 1]) + 0.0722 * Double(bytes[i + 2])) / 255.0
    }

    static func stats(
        _ bytes: [UInt8],
        reference: [UInt8],
        size: Int,
        columns: Range<Int>? = nil,
        rows: Range<Int>? = nil,
        threshold: Int = 3
    ) -> RegionStats {
        var result = RegionStats()
        for y in rows ?? 0..<size {
            for x in columns ?? 0..<size {
                let i = (y * size + x) * 4
                let delta = abs(Int(bytes[i]) - Int(reference[i]))
                    + abs(Int(bytes[i + 1]) - Int(reference[i + 1]))
                    + abs(Int(bytes[i + 2]) - Int(reference[i + 2]))
                result.maxDelta = max(result.maxDelta, delta)
                if delta > threshold {
                    result.changedPixels += 1
                    result.lumaDelta += luma(bytes, i) - luma(reference, i)
                }
                result.maxLuma = max(result.maxLuma, luma(bytes, i))
            }
        }
        return result
    }

    /// Centroid of the pixels that differ from `reference` by more than
    /// `threshold` (summed RGB).
    static func changeCentroid(
        _ bytes: [UInt8],
        reference: [UInt8],
        size: Int,
        columns: Range<Int>? = nil,
        threshold: Int = 10
    ) -> SIMD2<Float>? {
        var sum = SIMD2<Float>(0, 0)
        var count: Float = 0
        for y in 0..<size {
            for x in columns ?? 0..<size {
                let i = (y * size + x) * 4
                let delta = abs(Int(bytes[i]) - Int(reference[i]))
                    + abs(Int(bytes[i + 1]) - Int(reference[i + 1]))
                    + abs(Int(bytes[i + 2]) - Int(reference[i + 2]))
                if delta > threshold {
                    sum += SIMD2<Float>(Float(x), Float(y))
                    count += 1
                }
            }
        }
        return count > 0 ? sum / count : nil
    }

    /// Bytes that differ between two frames.
    static func differingBytes(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
    }
}
