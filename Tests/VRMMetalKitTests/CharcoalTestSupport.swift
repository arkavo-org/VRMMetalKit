// Copyright 2026 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// One loaded model and one renderer under the Creator lighting rig, rendering
/// frames of the charcoal materialization on paper. Byte comparisons are only
/// meaningful between frames from the same harness: the loader jitters node
/// transforms by about 1e-7 between loads.
@MainActor
final class CharcoalHarness {
    enum Framing { case body, bust }

    let pixelFormat: MTLPixelFormat
    let size: Int
    let sampleCount: Int
    private let device: MTLDevice
    private let renderer: VRMRenderer

    init(device: MTLDevice,
         modelPath: String = getTestVRM10ModelPath(),
         size: Int = 512,
         sampleCount: Int = 1,
         framing: Framing = .body,
         orthographic: Bool = false,
         pixelFormat: MTLPixelFormat = .bgra8Unorm,
         enableMaterialization: Bool = true,
         camera: (eye: SIMD3<Float>, target: SIMD3<Float>)? = nil,
         configure: ((VRMModel, VRMRenderer) -> Void)? = nil) async throws {
        try requireFixture(modelPath, hint: URL(fileURLWithPath: modelPath).lastPathComponent)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: modelPath), device: device)

        var config = RendererConfig()
        config.sampleCount = sampleCount
        config.strict = .off
        config.colorPixelFormat = pixelFormat
        config.enableMaterialization = enableMaterialization
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        configure?(model, renderer)

        renderer.setLight(0, direction: SIMD3<Float>(-0.62, -0.52, -0.59),
                          color: SIMD3<Float>(1.0, 0.95, 0.88), intensity: 1.1)
        renderer.setLight(1, direction: SIMD3<Float>(0.25, -0.12, -0.96),
                          color: SIMD3<Float>(0.75, 0.82, 0.95), intensity: 0.55)
        renderer.setLight(2, direction: SIMD3<Float>(0.51, -0.41, 0.76),
                          color: SIMD3<Float>(0.85, 0.92, 1.0), intensity: 0.55)
        renderer.setAmbientColor(SIMD3<Float>(0.20, 0.20, 0.22))
        renderer.setLightNormalizationMode(.radiometric)

        let view: (eye: SIMD3<Float>, target: SIMD3<Float>)
        if let camera {
            view = camera
        } else {
            switch framing {
            case .body:
                view = (SIMD3<Float>(0, 0.85, 2.6), SIMD3<Float>(0, 0.82, 0))
            case .bust:
                view = (SIMD3<Float>(0.15, 1.38, 0.75), SIMD3<Float>(0, 1.33, 0))
            }
        }
        let fov: Float = 40.0 * .pi / 180.0
        renderer.viewMatrix = RenderTestSupport.makeLookAt(
            eye: view.eye, center: view.target, up: SIMD3<Float>(0, 1, 0))
        if orthographic {
            let halfHeight = simd_length(view.target - view.eye) * tan(fov * 0.5)
            renderer.projectionMatrix = Self.makeOrthographic(
                halfHeight: halfHeight, aspect: 1.0, near: 0.01, far: 100.0)
        } else {
            renderer.projectionMatrix = RenderTestSupport.makePerspective(
                fovRadians: fov, aspect: 1.0, near: 0.01, far: 100.0)
        }

        self.device = device
        self.renderer = renderer
        self.size = size
        self.sampleCount = sampleCount
        self.pixelFormat = pixelFormat
    }

    /// One frame as bytes in R, G, B, A order. `nil` renders without
    /// materialization.
    func render(_ materialization: VRMMaterialization?) throws -> [UInt8] {
        renderer.materialization = materialization
        let clear = VRMMaterialization.charcoalPaperColor
        let clearColor = MTLClearColor(
            red: Double(clear.x), green: Double(clear.y), blue: Double(clear.z), alpha: 1.0)
        var bytes: [UInt8]
        if sampleCount > 1 {
            bytes = try RenderTestSupport.renderFrameMSAA(
                renderer: renderer, device: device, size: size, sampleCount: sampleCount,
                pixelFormat: pixelFormat, clearColor: clearColor)
        } else {
            bytes = try RenderTestSupport.renderFrame(
                renderer: renderer, device: device, size: size,
                pixelFormat: pixelFormat, clearColor: clearColor)
        }
        if Self.isBGRA(pixelFormat) {
            for i in stride(from: 0, to: bytes.count, by: 4) {
                bytes.swapAt(i, i + 2)
            }
        }
        return bytes
    }

    /// Charcoal at `progress`, seed 3.
    func charcoal(_ progress: Float,
                  color: SIMD3<Float>? = nil,
                  boilPhase: UInt32 = 0,
                  heightRange: ClosedRange<Float> = 0.0...1.62) -> VRMMaterialization {
        VRMMaterialization(progress: progress, style: .charcoal, color: color,
                           heightRange: heightRange, seed: 3, boilPhase: boilPhase)
    }

    static func isBGRA(_ format: MTLPixelFormat) -> Bool {
        format == .bgra8Unorm || format == .bgra8Unorm_srgb
    }

    private static func makeOrthographic(halfHeight: Float, aspect: Float,
                                         near: Float, far: Float) -> matrix_float4x4 {
        let halfWidth = halfHeight * aspect
        return matrix_float4x4(columns: (
            SIMD4<Float>(1.0 / halfWidth, 0, 0, 0),
            SIMD4<Float>(0, 1.0 / halfHeight, 0, 0),
            SIMD4<Float>(0, 0, -1.0 / (far - near), 0),
            SIMD4<Float>(0, 0, -near / (far - near), 1)
        ))
    }
}

enum CharcoalMeasure {
    /// The values the fragment wrote: bytes / 255, sRGB-decoded only when
    /// `format` is an `_srgb` format. `rgba` is in R, G, B, A order.
    static func colours(_ rgba: [UInt8], format: MTLPixelFormat) -> [SIMD3<Float>] {
        let decode = format == .rgba8Unorm_srgb || format == .bgra8Unorm_srgb
        func channel(_ byte: UInt8) -> Float {
            let v = Float(byte) / 255.0
            guard decode else { return v }
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(rgba.count / 4)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            out.append(SIMD3<Float>(channel(rgba[i]), channel(rgba[i + 1]), channel(rgba[i + 2])))
        }
        return out
    }

    private static func alongInkToPaper(_ c: SIMD3<Float>) -> Float {
        let paper = VRMMaterialization.charcoalPaperColor
        let axis = VRMMaterialization.charcoalInkColor - paper
        let t = simd_dot(c - paper, axis) / simd_dot(axis, axis)
        return min(max(t, 0), 1)
    }

    /// Euclidean distance from `c` to the segment between ink and paper.
    static func offLineDistance(_ c: SIMD3<Float>) -> Float {
        let paper = VRMMaterialization.charcoalPaperColor
        let axis = VRMMaterialization.charcoalInkColor - paper
        return simd_length(c - (paper + axis * alongInkToPaper(c)))
    }

    /// Position along the paper (0) to ink (1) segment, clamped to 0...1.
    static func ink(_ c: SIMD3<Float>) -> Float { alongInkToPaper(c) }

    /// Pixels that differ from the clear colour, taken from the first pixel.
    static func silhouette(plain: [UInt8]) -> [Bool] {
        guard plain.count >= 4 else { return [] }
        let clear = Array(plain[0..<4])
        var mask: [Bool] = []
        mask.reserveCapacity(plain.count / 4)
        for i in stride(from: 0, to: plain.count, by: 4) {
            mask.append(plain[i] != clear[0] || plain[i + 1] != clear[1]
                        || plain[i + 2] != clear[2] || plain[i + 3] != clear[3])
        }
        return mask
    }

    /// Mean of `ink` over the pixels in `mask` (every pixel when nil).
    static func meanInk(_ rgba: [UInt8], within mask: [Bool]?,
                        format: MTLPixelFormat = .rgba8Unorm) -> Float {
        let values = colours(rgba, format: format)
        var sum: Float = 0
        var count = 0
        for (i, c) in values.enumerated() where mask?[i] ?? true {
            sum += ink(c)
            count += 1
        }
        return count > 0 ? sum / Float(count) : 0
    }
}
