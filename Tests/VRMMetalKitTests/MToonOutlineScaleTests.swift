// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// The explicit outline multiplier and the minimum-width guard band, on every
/// hull path: merged (single-sided) and dedicated (double-sided), rigid and
/// skinned.
@MainActor
final class MToonOutlineScaleTests: XCTestCase {
    private var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    func testExplicitScaleDefaultsToAuthoredWidth() {
        var config = RendererConfig()
        config.colorPixelFormat = .rgba8Unorm
        let renderer = VRMRenderer(device: device, config: config)
        XCTAssertEqual(renderer.outlineWidth, 0.02, accuracy: 0.0001)
        XCTAssertEqual(renderer.outlineScale, 1.0, accuracy: 0.0001)
        XCTAssertEqual(renderer.outlineMinimumPixels, 0.0, accuracy: 0.0001)
        XCTAssertEqual(renderer.effectiveOutlineWidthScale, 1.0, accuracy: 0.0001,
            "Default outlineWidth + outlineScale must reproduce the authored width")

        renderer.outlineWidth = 0.08
        XCTAssertEqual(renderer.effectiveOutlineWidthScale, 4.0, accuracy: 0.0001,
            "Legacy outlineWidth keeps its 0.02 = 1x semantics")

        renderer.outlineWidth = 0.02
        renderer.outlineScale = 4.0
        XCTAssertEqual(renderer.effectiveOutlineWidthScale, 4.0, accuracy: 0.0001,
            "outlineScale is a direct authored-width multiplier")

        renderer.outlineScale = 0
        XCTAssertEqual(renderer.effectiveOutlineWidthScale, 0.0, accuracy: 0.0001)
    }

    /// The swatches' authored 0.0006 world width is far below a pixel, so a
    /// 3 px minimum must add a visible ring on all four hull paths.
    func testMinimumWidthWidensEveryHullPath() async throws {
        for fixture in [SwatchScene.Fixture.rigid, .skinned] {
            for doubleSided in [false, true] {
                let label = "\(fixture.rawValue), \(doubleSided ? "dedicated" : "merged") hull"
                let thin = try await outlineFrame(fixture, doubleSided: doubleSided, minimumPixels: 0)
                let guarded = try await outlineFrame(fixture, doubleSided: doubleSided, minimumPixels: 3)
                let added = darkPixelCount(guarded) - darkPixelCount(thin)
                XCTAssertGreaterThan(added, 1500, "\(label): the 3 px minimum added only \(added) outline pixels")
            }
        }
    }

    /// The minimum is scaled by the width mask: texels masked to zero stay
    /// outline-free instead of gaining a full minimum-width line.
    func testMinimumWidthHonoursTheWidthMask() async throws {
        for doubleSided in [false, true] {
            let unmasked = try await outlineFrame(.rigid, doubleSided: doubleSided, minimumPixels: 3)
            let masked = try await outlineFrame(.rigid, doubleSided: doubleSided, minimumPixels: 3, widthMask: 0)
            let none = try await outlineFrame(.rigid, doubleSided: doubleSided, minimumPixels: 0, widthMask: 0)
            XCTAssertGreaterThan(darkPixelCount(unmasked), darkPixelCount(none) + 1500)
            XCTAssertEqual(darkPixelCount(masked), darkPixelCount(none),
                "\(doubleSided ? "Dedicated" : "Merged") hull drew a minimum-width line where the width mask is zero")
        }
    }

    func testMinimumWidthNeverAddsALineToAZeroWidthOutline() async throws {
        let none = try await outlineFrame(.rigid, doubleSided: false, minimumPixels: 0, authoredWidth: 0)
        let guarded = try await outlineFrame(.rigid, doubleSided: false, minimumPixels: 3, authoredWidth: 0)
        XCTAssertEqual(none, guarded)
    }

    func testMinimumWidthMakesWorldOutlineReadableAtEverySize() async throws {
        let model = try await SwatchScene.load(.rigid, device: device)
        var guardedCounts: [Int: Int] = [:]
        for size in [512, 1024, 2048] {
            var setup = SwatchScene.Setup()
            setup.size = size
            let thin = darkPixelCount(try SwatchScene.render(model, device: device, setup: setup))
            setup.outlineMinimumPixels = 1.5
            let guarded = darkPixelCount(try SwatchScene.render(model, device: device, setup: setup))
            guardedCounts[size] = guarded
            XCTAssertGreaterThan(guarded, thin, "The \(size)px guard band should widen a subpixel world outline")
            XCTAssertGreaterThan(guarded, 300, "The \(size)px render should show a readable outline ring")
        }
        // Measured in device pixels, so the ring's pixel count grows with the
        // silhouette perimeter as resolution rises.
        XCTAssertGreaterThan(guardedCounts[2048] ?? 0, guardedCounts[512] ?? 0)
    }

    // MARK: - Helpers

    private func outlineFrame(
        _ fixture: SwatchScene.Fixture,
        doubleSided: Bool,
        minimumPixels: Float,
        widthMask: UInt8? = nil,
        authoredWidth: Float? = nil
    ) async throws -> [UInt8] {
        let model = try await SwatchScene.load(fixture, device: device)
        var maskIndex: Int?
        if let widthMask {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
            descriptor.usage = .shaderRead
            let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            var pixel: [UInt8] = [widthMask, widthMask, widthMask, 255]
            texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
            model.textures.append(VRMTexture(name: "outlineMask", mtlTexture: texture))
            maskIndex = model.textures.count - 1
        }
        for material in model.materials {
            material.doubleSided = doubleSided
            if var mtoon = material.mtoon {
                if let maskIndex { mtoon.outlineWidthMultiplyTexture = maskIndex }
                if let authoredWidth { mtoon.outlineWidthFactor = authoredWidth }
                material.mtoon = mtoon
            }
        }
        var setup = SwatchScene.Setup()
        setup.outlineMinimumPixels = minimumPixels
        return try SwatchScene.render(model, device: device, setup: setup)
    }

    /// Pixels dark enough to be outline colour (the swatch outline colour is
    /// near-black; the lit and shaded spheres are far brighter).
    private func darkPixelCount(_ bytes: [UInt8]) -> Int {
        var count = 0
        for i in stride(from: 0, to: bytes.count, by: 4) where SwatchScene.luma(bytes, i) < 0.10 {
            count += 1
        }
        return count
    }
}
