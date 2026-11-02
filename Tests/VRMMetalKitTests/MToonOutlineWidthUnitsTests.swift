// Copyright 2026 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
@testable import VRMMetalKit

/// MToon 1.0 `outlineWidthFactor` units: metres in `worldCoordinates`, a ratio
/// to the screen height in `screenCoordinates`.
///
/// The middle swatch sphere (radius 0.5 at the origin) is seen from z = 5
/// with a 45° vertical field of view in a 512 px frame. Its outline is
/// near-black and its lit and shaded surface are far brighter, so the dark
/// pixels on the rows through its centre are the outline ring on both sides.
@MainActor
final class MToonOutlineWidthUnitsTests: XCTestCase {

    private var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        self.device = device
    }

    /// A 0.05 m shell around the 0.5 m sphere grows its silhouette radius on
    /// screen from tan(asin(0.1)) to tan(asin(0.11)) of the half-frame, about
    /// 6.3 px per side.
    func testWorldOutlineWidthIsMetres() async throws {
        let expected = Self.worldPixelsPerSide(widthMetres: 0.05)
        try await assertRingWidth(mode: .worldCoordinates, factor: 0.05, expectedPerSide: expected)
    }

    /// 0.01 of a 512 px screen height is 5.12 px per side.
    func testScreenOutlineWidthIsAFractionOfScreenHeight() async throws {
        try await assertRingWidth(mode: .screenCoordinates, factor: 0.01, expectedPerSide: 0.01 * 512)
    }

    // MARK: - Harness

    private func assertRingWidth(
        mode: VRMOutlineWidthMode,
        factor: Float,
        expectedPerSide: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for fixture in [SwatchScene.Fixture.rigid, .skinned] {
            for doubleSided in [false, true] {
                let label = "\(fixture.rawValue), \(doubleSided ? "dedicated" : "merged") hull, \(mode.rawValue) \(factor)"
                let model = try await SwatchScene.load(fixture, device: device)
                for material in model.materials {
                    material.doubleSided = doubleSided
                    if var mtoon = material.mtoon {
                        mtoon.outlineWidthMode = mode
                        mtoon.outlineWidthFactor = factor
                        material.mtoon = mtoon
                    }
                }
                let setup = SwatchScene.Setup()
                let frame = try SwatchScene.render(model, device: device, setup: setup)
                let perSide = Self.meanDarkRunPerSide(frame, size: setup.size)
                XCTAssertEqual(perSide, expectedPerSide, accuracy: 1.5,
                    "\(label): outline is \(perSide) px per side, expected \(expectedPerSide)",
                    file: file, line: line)
            }
        }
    }

    /// Screen-space radius growth of a sphere of radius 0.5 at distance 5 when
    /// it gains a shell `widthMetres` thick, for the default swatch camera.
    private static func worldPixelsPerSide(widthMetres: Double) -> Double {
        let distance = 5.0
        let radius = 0.5
        let cotHalfFov = 1 / tan(Double.pi / 8)
        let halfFrame = 256.0
        func screenRadius(_ r: Double) -> Double { tan(asin(r / distance)) * cotHalfFov * halfFrame }
        return screenRadius(radius + widthMetres) - screenRadius(radius)
    }

    /// Mean count of outline-dark pixels per side on the rows through the
    /// middle sphere's centre, within the middle third of the frame.
    private static func meanDarkRunPerSide(_ bytes: [UInt8], size: Int) -> Double {
        let columns = SwatchScene.third(1, size: size)
        let rows = (size / 2 - 4)...(size / 2 + 4)
        var total = 0
        for y in rows {
            for x in columns where SwatchScene.luma(bytes, (y * size + x) * 4) < 0.10 {
                total += 1
            }
        }
        return Double(total) / Double(rows.count) / 2
    }
}
