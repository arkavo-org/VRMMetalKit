// Copyright 2026 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
@testable import VRMMetalKit

/// MToon 1.0 §GI Equalization with a directional ambient source:
/// `gi(n) = lerp(rawGi(n), uniformedGi, giEqualizationFactor)` with
/// `uniformedGi = (rawGi(up) + rawGi(down)) / 2`, and the indirect term
/// `gi(n) * litColor`. ``VRMRenderer/setHemisphereAmbient(sky:ground:)``
/// supplies `rawGi(n)`: the sky colour on surfaces facing world +Y, the ground
/// colour on surfaces facing -Y.
///
/// The middle swatch sphere is lit by ambient only (no direct light, rim or
/// matcap), red sky and blue ground. Its top rows face up and its bottom rows
/// face down.
@MainActor
final class MToonHemisphereAmbientTests: XCTestCase {

    private var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        self.device = device
    }

    func testZeroEqualizationLightsSurfacesByTheirDirection() async throws {
        let (top, bottom) = try await topAndBottom(giEqualization: 0)
        XCTAssertGreaterThan(top.x, bottom.x + 0.15, "Upward-facing surface should take the red sky. top \(top), bottom \(bottom)")
        XCTAssertGreaterThan(bottom.z, top.z + 0.15, "Downward-facing surface should take the blue ground. top \(top), bottom \(bottom)")
    }

    func testFullEqualizationLightsEverySurfaceWithTheUpDownAverage() async throws {
        let (top, bottom) = try await topAndBottom(giEqualization: 1)
        XCTAssertEqual(top.x, bottom.x, accuracy: 2.0 / 255.0, "giEqualizationFactor 1 must even out the ambient. top \(top), bottom \(bottom)")
        XCTAssertEqual(top.z, bottom.z, accuracy: 2.0 / 255.0, "giEqualizationFactor 1 must even out the ambient. top \(top), bottom \(bottom)")
        XCTAssertGreaterThan(top.x, 0.1, "The average of red sky and blue ground should still be lit. top \(top)")
        XCTAssertGreaterThan(top.z, 0.1, "The average of red sky and blue ground should still be lit. top \(top)")
    }

    func testSetAmbientColorStaysUniform() async throws {
        let renderer = VRMRenderer(device: device)
        renderer.setHemisphereAmbient(sky: [1, 0, 0], ground: [0, 0, 1])
        renderer.setAmbientColor([0.2, 0.3, 0.4])
        XCTAssertEqual(renderer.uniforms.ambientColor, [0.2, 0.3, 0.4])
        XCTAssertEqual(renderer.uniforms.groundAmbientColor, [0.2, 0.3, 0.4],
            "setAmbientColor must replace a hemisphere with a uniform ambient")
    }

    // MARK: - Harness

    /// Mean linear-ish RGB (0...1) of the middle sphere's top and bottom bands.
    private func topAndBottom(giEqualization: Float) async throws -> (SIMD3<Double>, SIMD3<Double>) {
        let model = try await SwatchScene.load(.rigid, device: device)
        for material in model.materials {
            material.baseColorFactor = [1, 1, 1, 1]
            material.baseColorTexture = nil
            if var mtoon = material.mtoon {
                mtoon.giEqualizationFactor = giEqualization
                mtoon.parametricRimColorFactor = [0, 0, 0]
                mtoon.matcapFactor = [0, 0, 0]
                mtoon.outlineWidthMode = .none
                material.mtoon = mtoon
            }
        }
        var setup = SwatchScene.Setup()
        setup.lightIntensity = 0
        let frame = try SwatchScene.render(model, device: device, setup: setup) { renderer in
            renderer.setHemisphereAmbient(sky: [1, 0, 0], ground: [0, 0, 1])
        }
        let size = setup.size
        let columns = (size / 2 - 12)..<(size / 2 + 12)
        // The sphere spans roughly rows 194...318 of 512; sample just inside
        // its top and bottom.
        return (mean(frame, size: size, rows: 205..<215, columns: columns),
                mean(frame, size: size, rows: 297..<307, columns: columns))
    }

    private func mean(_ bytes: [UInt8], size: Int, rows: Range<Int>, columns: Range<Int>) -> SIMD3<Double> {
        var sum = SIMD3<Double>(0, 0, 0)
        for y in rows {
            for x in columns {
                let i = (y * size + x) * 4
                sum += SIMD3<Double>(Double(bytes[i]), Double(bytes[i + 1]), Double(bytes[i + 2])) / 255
            }
        }
        return sum / Double(rows.count * columns.count)
    }
}
