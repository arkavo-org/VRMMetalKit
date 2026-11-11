// Copyright 2026 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Charcoal sketch materialization (style 13): the Swift API, the inert and
/// stripped states, and the two-front timeline from flat paper to the lit
/// render.
@MainActor
final class CharcoalSketchTests: XCTestCase {

    private func device() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        return device
    }

    private func maxOffLine(_ rgba: [UInt8], format: MTLPixelFormat = .bgra8Unorm) -> Float {
        CharcoalMeasure.colours(rgba, format: format).map(CharcoalMeasure.offLineDistance).max() ?? 0
    }

    // MARK: - API

    func testCharcoalConstants() {
        XCTAssertEqual(VRMMaterializationStyle.charcoal.rawValue, 13)
        XCTAssertEqual(VRMMaterialization.charcoalHoldProgress, 0.6)
        XCTAssertEqual(VRMMaterialization.charcoalPaperColor, SIMD3<Float>(0.86, 0.83, 0.77))
        XCTAssertEqual(VRMMaterialization.charcoalInkColor, SIMD3<Float>(0.030, 0.028, 0.026))
        XCTAssertEqual(VRMMaterialization.defaultColor(for: .charcoal), SIMD3<Float>(1.0, 0.42, 0.10))
        XCTAssertEqual(VRMMaterialization(progress: 0.5, style: .charcoal).color,
                       SIMD3<Float>(1.0, 0.42, 0.10))
        XCTAssertTrue(VRMMaterializationStyle.charcoal.usesDiscard)
        XCTAssertTrue(VRMMaterializationStyle.charcoal.requiresHostBackground)
        for style in VRMMaterializationStyle.allCases where style != .charcoal {
            XCTAssertFalse(style.requiresHostBackground, "style \(style)")
        }
    }

    func testBoilPhaseEncodesAsOrdinaryFloat() {
        func encoded(_ phase: UInt32) -> Float {
            VRMMaterialization(progress: 0.5, style: .charcoal, boilPhase: phase).encodedBoilPhase
        }
        XCTAssertEqual(encoded(0), 0.0)
        XCTAssertEqual(encoded(1), 1.0)
        XCTAssertEqual(encoded(65535), 65535.0)
        XCTAssertEqual(encoded(65536), 0.0)
    }

    // MARK: - Inert and stripped states

    func testInertAtFullProgress() async throws {
        let harness = try await CharcoalHarness(device: device())
        XCTAssertEqual(try harness.render(harness.charcoal(1.0)), try harness.render(nil))
    }

    func testStrippedWhenDisabled() async throws {
        let harness = try await CharcoalHarness(device: device(), enableMaterialization: false)
        XCTAssertEqual(try harness.render(harness.charcoal(0.3)), try harness.render(nil))
    }

    // MARK: - Timeline

    func testBlankStartIsPaper() async throws {
        let harness = try await CharcoalHarness(device: device())
        let frame = try harness.render(harness.charcoal(0.0))
        XCTAssertLessThan(maxOffLine(frame), 0.03)
    }

    func testHoldFrameHasNoColour() async throws {
        let harness = try await CharcoalHarness(device: device())
        for progress: Float in [0.3, 0.6] {
            let frame = try harness.render(harness.charcoal(progress))
            XCTAssertLessThan(maxOffLine(frame), 0.03, "progress \(progress)")
        }
    }

    func testColourArrivalIsMonotonic() async throws {
        let harness = try await CharcoalHarness(device: device())
        let plain = try harness.render(nil)
        let chromatic = CharcoalMeasure.colours(plain, format: harness.pixelFormat)
            .map { CharcoalMeasure.offLineDistance($0) > 0.04 }
        XCTAssertGreaterThan(chromatic.filter { $0 }.count, 1000, "fixture should contain coloured pixels")

        var previous: Int?
        for step in 0...8 {
            let progress = 0.6 + Float(step) * 0.05
            let frame = try harness.render(harness.charcoal(progress))
            var matches = 0
            for (pixel, isChromatic) in chromatic.enumerated() where isChromatic {
                let i = pixel * 4
                if frame[i] == plain[i] && frame[i + 1] == plain[i + 1]
                    && frame[i + 2] == plain[i + 2] && frame[i + 3] == plain[i + 3] {
                    matches += 1
                }
            }
            if let previous {
                XCTAssertGreaterThanOrEqual(matches, previous - 16,
                    "matching pixels dropped from \(previous) to \(matches) at progress \(progress)")
            }
            if step == 0 { XCTAssertEqual(matches, 0, "progress 0.6 must show no colour") }
            if step == 8 {
                XCTAssertEqual(matches, chromatic.filter { $0 }.count, "progress 1.0 must be the plain render")
            }
            previous = matches
        }
    }

    func testDeterministic() async throws {
        let harness = try await CharcoalHarness(device: device())
        let first = try harness.render(harness.charcoal(0.45))
        let second = try harness.render(harness.charcoal(0.45))
        XCTAssertEqual(first, second)
    }

    func testMismatchedHeightRangeStillEndsClean() async throws {
        let harness = try await CharcoalHarness(device: device())
        let plain = try harness.render(nil)
        let done = try harness.render(harness.charcoal(1.0, heightRange: 0.0...0.5))
        XCTAssertEqual(done, plain)
        let hold = try harness.render(harness.charcoal(0.6, heightRange: 0.0...0.5))
        XCTAssertLessThan(maxOffLine(hold), 0.03)
    }

    func testHoldFrameHasNoColourOnSRGBTarget() async throws {
        let harness = try await CharcoalHarness(device: device(), pixelFormat: .rgba8Unorm_srgb)
        let hold = try harness.render(harness.charcoal(0.6))
        XCTAssertLessThan(maxOffLine(hold, format: harness.pixelFormat), 0.03)
        XCTAssertEqual(try harness.render(harness.charcoal(1.0)), try harness.render(nil))
    }
}
