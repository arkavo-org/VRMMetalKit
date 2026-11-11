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

    func testContoursDrawByHoldFrame() async throws {
        let harness = try await CharcoalHarness(device: device())
        let plain = try harness.render(nil)
        let silhouette = CharcoalMeasure.silhouette(plain: plain)
        let frame = try harness.render(harness.charcoal(0.6))
        let mean = CharcoalMeasure.meanInk(frame, within: silhouette, format: harness.pixelFormat)
        XCTAssertGreaterThan(mean, 0.02)
    }

    func testConstructionDashesAreFaint() async throws {
        let harness = try await CharcoalHarness(device: device())
        let silhouette = CharcoalMeasure.silhouette(plain: try harness.render(nil))
        let frame = try harness.render(harness.charcoal(0.0))
        let mean = CharcoalMeasure.meanInk(frame, within: nil, format: harness.pixelFormat)
        XCTAssertGreaterThan(mean, 0)
        XCTAssertLessThan(mean, 0.01)

        let ink = CharcoalMeasure.colours(frame, format: harness.pixelFormat).map(CharcoalMeasure.ink)
        let dashes = ink.indices.filter { silhouette[$0] && (0.08...0.30).contains(ink[$0]) }.count
        XCTAssertGreaterThan(dashes, 50, "construction dashes should be drawn as faint grey")
        XCTAssertLessThanOrEqual(ink.max() ?? 0, 0.5, "no drawn ink before the front arrives")
    }

    func testFaceDetailIsDrawn() async throws {
        let harness = try await CharcoalHarness(device: device(), framing: .bust)
        let plain = try harness.render(nil)
        let frame = try harness.render(harness.charcoal(0.6))
        let silhouette = CharcoalMeasure.silhouette(plain: plain)
        let plainColours = CharcoalMeasure.colours(plain, format: harness.pixelFormat)
        let charcoalColours = CharcoalMeasure.colours(frame, format: harness.pixelFormat)
        let luma = plainColours.map { simd_dot($0, SIMD3<Float>(0.2126, 0.7152, 0.0722)) }
        let size = harness.size

        var edges = 0
        var inked = 0
        for y in 1..<(size - 1) {
            for x in 1..<(size - 1) {
                let i = y * size + x
                guard silhouette[i] else { continue }
                let neighbours = [i - 1, i + 1, i - size, i + size]
                guard neighbours.contains(where: { abs(luma[i] - luma[$0]) > 0.25 }) else { continue }
                edges += 1
                if CharcoalMeasure.ink(charcoalColours[i]) > 0.4 { inked += 1 }
            }
        }
        XCTAssertGreaterThan(edges, 200, "the bust fixture should contain texture and shape edges")
        XCTAssertGreaterThanOrEqual(Double(inked), 0.3 * Double(edges),
                                    "\(inked) of \(edges) edge pixels carry ink")
    }

    func testOrthographicContourDoesNotFlood() async throws {
        let ortho = try await CharcoalHarness(device: device(), orthographic: true)
        let perspective = try await CharcoalHarness(device: device())

        func meanInk(_ harness: CharcoalHarness) throws -> Float {
            let silhouette = CharcoalMeasure.silhouette(plain: try harness.render(nil))
            let frame = try harness.render(harness.charcoal(0.6))
            return CharcoalMeasure.meanInk(frame, within: silhouette, format: harness.pixelFormat)
        }
        let orthographicInk = try meanInk(ortho)
        let perspectiveInk = try meanInk(perspective)
        XCTAssertLessThanOrEqual(orthographicInk, 1.5 * perspectiveInk,
                                 "orthographic \(orthographicInk) vs perspective \(perspectiveInk)")
    }

    // MARK: - Tone and hatching

    private func silhouetteInk(_ harness: CharcoalHarness, progress: Float) throws -> Float {
        let silhouette = CharcoalMeasure.silhouette(plain: try harness.render(nil))
        let frame = try harness.render(harness.charcoal(progress))
        return CharcoalMeasure.meanInk(frame, within: silhouette, format: harness.pixelFormat)
    }

    private func meanInk(_ harness: CharcoalHarness, progress: Float,
                         plainLuma matches: (Float) -> Bool) throws -> Float {
        let plain = try harness.render(nil)
        let silhouette = CharcoalMeasure.silhouette(plain: plain)
        let luma = CharcoalMeasure.colours(plain, format: harness.pixelFormat)
            .map { simd_dot($0, SIMD3<Float>(0.2126, 0.7152, 0.0722)) }
        let ink = CharcoalMeasure.colours(try harness.render(harness.charcoal(progress)),
                                          format: harness.pixelFormat).map(CharcoalMeasure.ink)
        var sum: Float = 0
        var count = 0
        for i in ink.indices where silhouette[i] && matches(luma[i]) {
            sum += ink[i]
            count += 1
        }
        XCTAssertGreaterThan(count, 200, "too few pixels to measure")
        return count > 0 ? sum / Float(count) : 0
    }

    func testHoldFrameIsShaded() async throws {
        let harness = try await CharcoalHarness(device: device())
        let mean = try silhouetteInk(harness, progress: 0.6)
        XCTAssertGreaterThan(mean, 0.20)
    }

    func testShadingArrivesAfterContour() async throws {
        let harness = try await CharcoalHarness(device: device())
        let early = try silhouetteInk(harness, progress: 0.25)
        let hold = try silhouetteInk(harness, progress: 0.6)
        XCTAssertGreaterThan(hold, 1.4 * early, "hold \(hold) vs early \(early)")
    }

    func testDarkSurfacesDrawDarker() async throws {
        let harness = try await CharcoalHarness(device: device())
        let dark = try meanInk(harness, progress: 0.6) { $0 < 0.05 }
        let pale = try meanInk(harness, progress: 0.6) { $0 > 0.5 }
        XCTAssertGreaterThanOrEqual(dark - pale, 0.29, "dark \(dark) vs pale \(pale)")
    }

    func testHoldFrameOnVRM0Avatar() async throws {
        let harness = try await CharcoalHarness(device: device(), modelPath: getTestVRM00ModelPath())
        XCTAssertEqual(try harness.render(harness.charcoal(1.0)), try harness.render(nil))
        let hold = try harness.render(harness.charcoal(0.6))
        XCTAssertLessThan(maxOffLine(hold), 0.03)
        let silhouette = CharcoalMeasure.silhouette(plain: try harness.render(nil))
        let mean = CharcoalMeasure.meanInk(hold, within: silhouette, format: harness.pixelFormat)
        XCTAssertGreaterThan(mean, 0.20)
    }

    func testThumbnailSize() async throws {
        let harness = try await CharcoalHarness(device: device(), size: 256)
        let hold = try harness.render(harness.charcoal(0.6))
        XCTAssertLessThan(maxOffLine(hold), 0.03)
        let silhouette = CharcoalMeasure.silhouette(plain: try harness.render(nil))
        let mean = CharcoalMeasure.meanInk(hold, within: silhouette, format: harness.pixelFormat)
        XCTAssertGreaterThan(mean, 0.15)
    }

    func testPaleSurfacesStayLight() async throws {
        let harness = try await CharcoalHarness(device: device(), framing: .bust)
        let pale = try meanInk(harness, progress: 0.6) { $0 > 0.5 }
        XCTAssertLessThan(pale, 0.25)
    }

    func testHoldFrameHasNoColour() async throws {
        let harness = try await CharcoalHarness(device: device())
        for progress: Float in [0.0, 0.3, 0.6] {
            let frame = try harness.render(harness.charcoal(progress))
            XCTAssertLessThan(maxOffLine(frame), 0.03, "progress \(progress)")
        }
    }

    func testColourArrivalIsMonotonic() async throws {
        let harness = try await CharcoalHarness(device: device())
        let plain = try harness.render(nil)
        let chromatic = CharcoalMeasure.colours(plain, format: harness.pixelFormat)
            .map { CharcoalMeasure.offLineDistance($0) > 0.04 }
        let total = chromatic.filter { $0 }.count
        XCTAssertGreaterThan(total, 1000, "fixture should contain coloured pixels")

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
            if step == 4 {
                XCTAssertGreaterThan(matches, 0, "progress 0.8 must have colour arrived somewhere")
                XCTAssertLessThan(matches, total, "progress 0.8 must not be complete")
            }
            if step == 7 {
                XCTAssertGreaterThan(Double(matches), 0.8 * Double(total), "progress 0.95 must be nearly complete")
            }
            if step == 8 {
                XCTAssertEqual(matches, total, "progress 1.0 must be the plain render")
            }
            previous = matches
        }
    }

    func testColourFrontSettlesExactly() async throws {
        let harness = try await CharcoalHarness(device: device())
        let plain = try harness.render(nil)
        let frame = try harness.render(harness.charcoal(0.9))
        let colours = CharcoalMeasure.colours(plain, format: harness.pixelFormat)
        let silhouette = CharcoalMeasure.silhouette(plain: plain)
        let rows = (0..<harness.size).filter { y in
            (0..<harness.size).contains { silhouette[y * harness.size + $0] }
        }
        let first = try XCTUnwrap(rows.first)
        let last = try XCTUnwrap(rows.last)
        let limit = first + Int(0.1 * Float(last - first))

        var counted = 0
        var mismatched = 0
        for y in first...limit {
            for x in 0..<harness.size {
                let pixel = y * harness.size + x
                guard CharcoalMeasure.offLineDistance(colours[pixel]) > 0.04 else { continue }
                counted += 1
                let i = pixel * 4
                if Array(frame[i..<i + 4]) != Array(plain[i..<i + 4]) { mismatched += 1 }
            }
        }
        XCTAssertGreaterThan(counted, 100, "the top of the silhouette should contain coloured pixels")
        XCTAssertEqual(mismatched, 0, "the colour front has settled over the head at progress 0.9")
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
        let plain = try harness.render(nil)
        let chromatic = CharcoalMeasure.colours(plain, format: harness.pixelFormat)
            .filter { CharcoalMeasure.offLineDistance($0) > 0.04 }.count
        XCTAssertGreaterThan(chromatic, 1000, "fixture should contain coloured pixels")
        let hold = try harness.render(harness.charcoal(0.6))
        XCTAssertLessThan(maxOffLine(hold, format: harness.pixelFormat), 0.03)
        XCTAssertEqual(try harness.render(harness.charcoal(1.0)), plain)
    }
}
