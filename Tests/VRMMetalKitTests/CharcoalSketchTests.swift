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

    // MARK: - Reference frames

    /// Writes body and bust frames of every `AvatarSample` fixture at the repo
    /// root for judging the look by eye:
    /// `CHARCOAL_REFERENCE_OUT=<dir> swift test --filter testWriteReferenceFrames --disable-sandbox`.
    /// `CHARCOAL_REFERENCE_SAMPLES=4` renders under 4x MSAA. The VRM 1.0
    /// fixture lands in `<dir>`, the others in a folder named after the file.
    func testWriteReferenceFrames() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let outputDirectory = environment["CHARCOAL_REFERENCE_OUT"] else {
            throw XCTSkip("CHARCOAL_REFERENCE_OUT not set")
        }
        let sampleCount = environment["CHARCOAL_REFERENCE_SAMPLES"].flatMap(Int.init) ?? 1
        let root = URL(fileURLWithPath: outputDirectory)
        let models: [(path: String, folder: String?)] = [
            (getTestVRM10ModelPath(), nil),
            (getTestVRM00ModelPath(), "AvatarSample_A_0.0"),
            (getTestModelPath("AvatarSample_U_1.0.vrm.glb"), "AvatarSample_U_1.0"),
        ]
        let framings: [(CharcoalHarness.Framing, String)] = [(.body, "body"), (.bust, "bust")]
        for model in models where FileManager.default.fileExists(atPath: model.path) {
            let directory = model.folder.map { root.appendingPathComponent($0) } ?? root
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (framing, name) in framings {
                let harness = try await CharcoalHarness(device: device(), modelPath: model.path, size: 1080,
                                                        sampleCount: sampleCount, framing: framing)
                for progress: Float in [0.0, 0.15, 0.30, 0.45, 0.60, 0.70, 0.80, 0.90, 1.0] {
                    let file = String(format: "%@_t%03d.png", name, Int((progress * 100).rounded()))
                    try harness.writePNG(try harness.render(harness.charcoal(progress)),
                                         to: directory.appendingPathComponent(file))
                }
            }
        }
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
        XCTAssertGreaterThan(orthographicInk, 0.40, "orthographic contours and tone should still be drawn")
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
        XCTAssertGreaterThan(mean, 0.40)
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
        XCTAssertGreaterThan(mean, 0.40)
    }

    func testThumbnailSize() async throws {
        let harness = try await CharcoalHarness(device: device(), size: 256)
        let hold = try harness.render(harness.charcoal(0.6))
        XCTAssertLessThan(maxOffLine(hold), 0.03)
        let silhouette = CharcoalMeasure.silhouette(plain: try harness.render(nil))
        let mean = CharcoalMeasure.meanInk(hold, within: silhouette, format: harness.pixelFormat)
        XCTAssertGreaterThan(mean, 0.40)
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

    func testEndStateMatchesPlainRenderOffTheSentinel() async throws {
        let body = try await CharcoalHarness(device: device())
        let plain = try body.render(nil)
        XCTAssertEqual(try body.render(body.charcoal(0.98)), plain, "default body framing")
        XCTAssertEqual(try body.render(body.charcoal(0.98, heightRange: 0.0...0.5)), plain,
                       "mismatched height range")

        let cases: [(CharcoalHarness.SwatchFixture, CharcoalHarness.SwatchHull)] = [
            (.rigid, .dedicated), (.rigid, .merged), (.skinned, .merged), (.skinned, .dedicated),
        ]
        for (fixture, hull) in cases {
            let harness = try await CharcoalHarness.swatches(device: device(), fixture: fixture, hull: hull)
            XCTAssertEqual(try harness.render(harness.swatchCharcoal(0.98)), try harness.render(nil),
                           "\(fixture) \(hull)")
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

    // MARK: - Ember and boil

    private func redMinusBlue(_ frame: [UInt8], format: MTLPixelFormat) -> [Float] {
        CharcoalMeasure.colours(frame, format: format).map { $0.x - $0.z }
    }

    func testEmberGlowsAtColourFront() async throws {
        let harness = try await CharcoalHarness(device: device())
        let glowing = try harness.render(harness.charcoal(0.8))
        let monochrome = try harness.render(harness.charcoal(0.8, color: .zero))
        let glowRB = redMinusBlue(glowing, format: harness.pixelFormat)
        let monoRB = redMinusBlue(monochrome, format: harness.pixelFormat)
        var differing = 0
        var gain: Float = 0
        for pixel in glowRB.indices {
            let i = pixel * 4
            guard Array(glowing[i..<i + 4]) != Array(monochrome[i..<i + 4]) else { continue }
            differing += 1
            gain += glowRB[pixel] - monoRB[pixel]
        }
        XCTAssertGreaterThan(differing, 100)
        XCTAssertLessThan(differing, 1100, "the ember should stay an edge along the colour front")
        XCTAssertGreaterThan(gain / Float(max(differing, 1)), 0.2)
    }

    func testEmberOffIsMonochrome() async throws {
        let harness = try await CharcoalHarness(device: device())
        let plain = try harness.render(nil)
        let frame = try harness.render(harness.charcoal(0.8, color: .zero))
        let paper = VRMMaterialization.charcoalPaperColor
        let paperRB = paper.x - paper.z
        let plainRB = redMinusBlue(plain, format: harness.pixelFormat)
        let frameRB = redMinusBlue(frame, format: harness.pixelFormat)
        var offenders = 0
        for pixel in frameRB.indices
        where frameRB[pixel] > paperRB + 0.05 && frameRB[pixel] > plainRB[pixel] + 0.05 {
            offenders += 1
        }
        XCTAssertEqual(offenders, 0)
    }

    func testHeldSketchDoesNotGlow() async throws {
        let harness = try await CharcoalHarness(device: device())
        XCTAssertEqual(try harness.render(harness.charcoal(0.6)),
                       try harness.render(harness.charcoal(0.6, color: .zero)))
    }

    func testBoilPhaseChangesStrokes() async throws {
        let harness = try await CharcoalHarness(device: device())
        let base = try harness.render(harness.charcoal(0.6, boilPhase: 0))
        let boiled = try harness.render(harness.charcoal(0.6, boilPhase: 1))
        XCTAssertTrue(boiled != base, "boil phase 1 must change the strokes")
        XCTAssertEqual(try harness.render(harness.charcoal(0.6, boilPhase: 1)), boiled)
    }

    func testBoilPhaseWrapsEvery64Steps() async throws {
        let harness = try await CharcoalHarness(device: device())
        let frames = try [0, 1, 64, 65].map { try harness.render(harness.charcoal(0.6, boilPhase: UInt32($0))) }
        XCTAssertNotEqual(frames[0], frames[1], "phases 0 and 1 must differ for the wrap check to mean anything")
        XCTAssertEqual(frames[2], frames[0], "boil phase 64 must repeat phase 0")
        XCTAssertEqual(frames[3], frames[1], "boil phase 65 must repeat phase 1")
    }

    func testBoilLeavesRubbedToneStill() async throws {
        let harness = try await CharcoalHarness(device: device(), framing: .bust)
        let plainBytes = try harness.render(nil)
        let silhouette = CharcoalMeasure.silhouette(plain: plainBytes)
        let plain = CharcoalMeasure.colours(plainBytes, format: harness.pixelFormat)
        let first = CharcoalMeasure.colours(try harness.render(harness.charcoal(0.6, boilPhase: 0)),
                                            format: harness.pixelFormat).map(CharcoalMeasure.ink)
        let second = CharcoalMeasure.colours(try harness.render(harness.charcoal(0.6, boilPhase: 1)),
                                             format: harness.pixelFormat).map(CharcoalMeasure.ink)
        var tone = 0
        var moved = 0
        for i in plain.indices where silhouette[i] && Self.plainLuma(plain[i]) > 0.5
            && first[i] < 0.35 && second[i] < 0.35 {
            tone += 1
            if abs(first[i] - second[i]) > 0.05 { moved += 1 }
        }
        XCTAssertGreaterThan(tone, 20_000, "too few pale pixels free of strokes")
        XCTAssertLessThan(Float(moved), 0.02 * Float(tone),
                          "\(moved) of \(tone) rubbed-tone pixels moved with the boil phase")
    }

    func testBoilStaysStableAtHighPhase() async throws {
        let harness = try await CharcoalHarness(device: device())
        let silhouette = CharcoalMeasure.silhouette(plain: try harness.render(nil))
        let base = CharcoalMeasure.meanInk(try harness.render(harness.charcoal(0.6, boilPhase: 0)),
                                           within: silhouette, format: harness.pixelFormat)
        let late = CharcoalMeasure.meanInk(try harness.render(harness.charcoal(0.6, boilPhase: 60000)),
                                           within: silhouette, format: harness.pixelFormat)
        XCTAssertGreaterThan(base, 0.05)
        XCTAssertEqual(late, base, accuracy: base * 0.10)
    }

    // MARK: - Face shadow and lingering lines

    /// Pixel rectangle of the viewer-left cheek and jaw, the side of the face
    /// turned from the key light, in the 512-pixel bust frame of
    /// `AvatarSample_A_1.0.vrm.glb`.
    private static let shadeJaw = (x: 190..<250, y: 225..<275)

    func testFaceShadowIsToneNotStrokes() async throws {
        let harness = try await CharcoalHarness(device: device(), size: 512, framing: .bust)
        let size = harness.size
        let plainBytes = try harness.render(nil)
        let silhouette = CharcoalMeasure.silhouette(plain: plainBytes)
        let plain = CharcoalMeasure.colours(plainBytes, format: harness.pixelFormat)
        let hold = CharcoalMeasure.colours(try harness.render(harness.charcoal(0.6)),
                                           format: harness.pixelFormat)
        let skin = plain.indices.map { silhouette[$0] && Self.plainLuma(plain[$0]) > 0.5 }

        var counted = 0
        var strokes = 0
        var sum: Float = 0
        for y in Self.shadeJaw.y {
            for x in Self.shadeJaw.x {
                let clearOfLines = (-4...4).allSatisfy { dy in
                    (-4...4).allSatisfy { dx in skin[(y + dy) * size + x + dx] }
                }
                guard clearOfLines else { continue }
                let ink = CharcoalMeasure.ink(hold[y * size + x])
                counted += 1
                sum += ink
                if ink > 0.5 { strokes += 1 }
            }
        }
        let mean = sum / Float(max(counted, 1))
        XCTAssertGreaterThan(counted, 800, "too few skin pixels clear of the jaw line and mouth")
        XCTAssertGreaterThan(mean, 0.05, "the shade side of the face should carry a soft tone")
        XCTAssertLessThan(mean, 0.23, "the shade side of the face should stay a light tone")
        XCTAssertLessThan(strokes, 15, "\(strokes) of \(counted) skin pixels carry a stroke")
    }

    func testHoldFrameIsSmudged() async throws {
        let harness = try await CharcoalHarness(device: device(), framing: .bust)
        let silhouette = CharcoalMeasure.silhouette(plain: try harness.render(nil))
        let ink = CharcoalMeasure.colours(try harness.render(harness.charcoal(0.6)),
                                          format: harness.pixelFormat).map(CharcoalMeasure.ink)
        var inside = 0
        var bare = 0
        var rubbed = 0
        for i in ink.indices where silhouette[i] {
            inside += 1
            if ink[i] < 0.03 { bare += 1 }
            if (0.15...0.9).contains(ink[i]) { rubbed += 1 }
        }
        XCTAssertGreaterThan(inside, 10_000, "the bust fixture should fill the frame")
        XCTAssertLessThan(Float(bare), 0.12 * Float(inside), "drawn surfaces should carry rubbed-in tone")
        XCTAssertGreaterThan(Float(rubbed), 0.29 * Float(inside), "the drawing should hold smudged greys")
    }

    func testContourLinesLingerOverArrivingColour() async throws {
        let harness = try await CharcoalHarness(device: device(), framing: .bust)
        let size = harness.size
        let plainBytes = try harness.render(nil)
        let frameBytes = try harness.render(harness.charcoal(0.7, color: .zero))
        let silhouette = CharcoalMeasure.silhouette(plain: plainBytes)
        let plain = CharcoalMeasure.colours(plainBytes, format: harness.pixelFormat)
        let frame = CharcoalMeasure.colours(frameBytes, format: harness.pixelFormat)
        let settled = silhouette.indices.map { pixel -> Bool in
            let i = pixel * 4
            return silhouette[pixel] && frameBytes[i] == plainBytes[i]
                && frameBytes[i + 1] == plainBytes[i + 1] && frameBytes[i + 2] == plainBytes[i + 2]
        }

        var lingering = 0
        for y in 4..<(size - 4) {
            for x in 4..<(size - 4) {
                let i = y * size + x
                guard silhouette[i], !settled[i],
                      Self.plainLuma(plain[i]) - Self.plainLuma(frame[i]) > 0.05 else { continue }
                var settledNeighbours = 0
                for dy in -4...4 {
                    for dx in -4...4 where settled[(y + dy) * size + x + dx] { settledNeighbours += 1 }
                }
                if settledNeighbours > 40 { lingering += 1 }
            }
        }
        XCTAssertGreaterThan(lingering, 100,
                             "contour lines should still darken pixels where the colour has arrived")
    }

    // MARK: - Outline hull

    private func outsideSilhouetteCount(_ frame: [UInt8], silhouette: [Bool], format: MTLPixelFormat,
                                        inkRange: ClosedRange<Float>) -> Int {
        let ink = CharcoalMeasure.colours(frame, format: format).map(CharcoalMeasure.ink)
        return ink.indices.filter { !silhouette[$0] && inkRange.contains(ink[$0]) }.count
    }

    func testHullWidensBeyondSilhouette() async throws {
        let harness = try await CharcoalHarness(device: device(), size: 512)
        let silhouette = CharcoalMeasure.silhouette(plain: try harness.render(nil))
        let hold = outsideSilhouetteCount(try harness.render(harness.charcoal(0.6)), silhouette: silhouette,
                                          format: harness.pixelFormat, inkRange: 0.5...1.0)
        XCTAssertGreaterThan(hold, 200, "the hull should stroke outside the silhouette")
        let done = outsideSilhouetteCount(try harness.render(harness.charcoal(1.0)), silhouette: silhouette,
                                          format: harness.pixelFormat, inkRange: 0.5...1.0)
        XCTAssertEqual(done, 0)
    }

    func testUndrawnHullIsFaint() async throws {
        let harness = try await CharcoalHarness(device: device(), size: 512)
        let size = harness.size
        let silhouette = CharcoalMeasure.silhouette(plain: try harness.render(nil))
        let frame = try harness.render(harness.charcoal(0.0))
        XCTAssertEqual(outsideSilhouetteCount(frame, silhouette: silhouette, format: harness.pixelFormat,
                                              inkRange: 0.5...1.0), 0)

        let ink = CharcoalMeasure.colours(frame, format: harness.pixelFormat).map(CharcoalMeasure.ink)
        var rim = 0
        for y in 0..<size {
            for x in 0..<size where silhouette[y * size + x] && (0.1...0.3).contains(ink[y * size + x]) {
                let nearOutside = (-3...3).contains { dy in
                    (-3...3).contains { dx in
                        let yy = y + dy
                        let xx = x + dx
                        return yy < 0 || xx < 0 || yy >= size || xx >= size || !silhouette[yy * size + xx]
                    }
                }
                if nearOutside { rim += 1 }
            }
        }
        XCTAssertGreaterThan(rim, 800, "the undrawn hull should read as faint grey dashes along the rim")
    }

    func testHullRunsUnderMSAA() async throws {
        let harness = try await CharcoalHarness(device: device(), size: 512, sampleCount: 4)
        let silhouette = CharcoalMeasure.silhouette(plain: try harness.render(nil))
        let hold = try harness.render(harness.charcoal(0.6))
        XCTAssertLessThan(maxOffLine(hold), 0.03)
        XCTAssertGreaterThan(outsideSilhouetteCount(hold, silhouette: silhouette, format: harness.pixelFormat,
                                                    inkRange: 0.5...1.0), 0)
    }

    func testOutlinedFixturesInkTheirHull() async throws {
        let cases: [(CharcoalHarness.SwatchFixture, CharcoalHarness.SwatchHull)] = [
            (.rigid, .dedicated), (.rigid, .merged), (.skinned, .merged), (.skinned, .dedicated),
        ]
        for guardBand in [false, true] {
            for (fixture, hull) in cases {
                let harness = try await CharcoalHarness.swatches(
                    device: device(), fixture: fixture, hull: hull,
                    minimumOutlinePixels: guardBand ? 3 : nil)
                let plain = try harness.render(nil)
                let silhouette = CharcoalMeasure.silhouette(plain: plain)
                let hold = outsideSilhouetteCount(try harness.render(harness.swatchCharcoal(0.6)),
                                                  silhouette: silhouette, format: harness.pixelFormat,
                                                  inkRange: 0.5...1.0)
                let label = "\(fixture) \(hull) guardBand=\(guardBand)"
                XCTAssertGreaterThan(hold, 100, "\(label): hull ink outside the silhouette at the hold frame")
                XCTAssertEqual(try harness.render(harness.swatchCharcoal(1.0)), plain, label)
            }
        }
    }

    // MARK: - Blended overlays

    private func colouredBlendHarness(colour: SIMD3<Float> = [0.2, 0.65, 1.0]) async throws
        -> (CharcoalHarness, (Float) -> Void) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "finish_swatches", withExtension: "vrm",
                                                subdirectory: "TestData/MToon"))
        var setAlpha: ((Float) -> Void)?
        let harness = try await CharcoalHarness(device: device(), modelPath: url.path, size: 256,
                                                camera: (eye: [0.4, 0.5, 5], target: [0, 0, 0]),
                                                configure: { model, renderer in
            for material in model.materials {
                material.baseColorTexture = nil
                material.alphaMode = "BLEND"
                material.transparentWithZWrite = false
                material.mtoon?.outlineWidthMode = .none
            }
            renderer.disableAutoMaterialOverrides = true
            setAlpha = { alpha in
                for material in model.materials {
                    material.baseColorFactor = SIMD4<Float>(colour, alpha)
                }
            }
            setAlpha?(1)
        })
        return (harness, try XCTUnwrap(setAlpha))
    }

    func testOpaqueColouredBlendedFeaturesRemainVisible() async throws {
        let (harness, setAlpha) = try await colouredBlendHarness()
        let plain = CharcoalMeasure.colours(try harness.render(nil), format: harness.pixelFormat)
        setAlpha(0)
        let plainUnder = CharcoalMeasure.colours(try harness.render(nil), format: harness.pixelFormat)
        let holdUnder = CharcoalMeasure.colours(try harness.render(harness.charcoal(0.6)),
                                                format: harness.pixelFormat)
        let mask = plain.indices.filter { simd_length(plain[$0] - plainUnder[$0]) > 0.15 }
        XCTAssertGreaterThan(mask.count, 100, "fixture must expose the coloured blended surface")

        for alpha: Float in [0.55, 0.8, 1.0] {
            setAlpha(alpha)
            let hold = CharcoalMeasure.colours(try harness.render(harness.charcoal(0.6)),
                                               format: harness.pixelFormat)
            let visible = mask.filter {
                CharcoalMeasure.ink(hold[$0]) - CharcoalMeasure.ink(holdUnder[$0]) > 0.12
            }.count
            XCTAssertGreaterThan(Float(visible), Float(mask.count) * 0.8,
                                 "opaque coloured feature disappeared at alpha \(alpha): \(visible)/\(mask.count)")
            XCTAssertLessThan(hold.map(CharcoalMeasure.offLineDistance).max() ?? 0, 0.03)
        }
        setAlpha(1)
        XCTAssertEqual(try harness.render(harness.charcoal(1)), try harness.render(nil))
    }

    func testSheerColouredBlendedFeaturesStayHidden() async throws {
        let (harness, setAlpha) = try await colouredBlendHarness()
        setAlpha(0)
        let hidden = try harness.render(harness.charcoal(0.6))
        for alpha: Float in [0.2, 0.5, 0.54] {
            setAlpha(alpha)
            XCTAssertEqual(try harness.render(harness.charcoal(0.6)), hidden,
                           "sheer tint at alpha \(alpha) should not stain the sketch")
        }
    }

    /// Pixel rectangle of both eyes in the 512-pixel bust frame of
    /// `AvatarSample_A_1.0.vrm.glb`. Bangs overlap the brows and hang between
    /// the eyes, so the rectangle is the tightest one around the eyes and lashes
    /// and still holds a few hair pixels.
    private static let eyeBand = (x: 182..<305, y: 168..<201)

    private static func plainLuma(_ colour: SIMD3<Float>) -> Float {
        simd_dot(colour, SIMD3<Float>(0.2126, 0.7152, 0.0722))
    }

    /// The 512-pixel bust harness without blended primitives. A pixel that is
    /// darker in the ordinary plain render is covered by an overlay.
    private func bustWithoutOverlays() async throws -> CharcoalHarness {
        try await CharcoalHarness(device: device(), size: 512, framing: .bust, configure: { model, _ in
            for mesh in model.meshes {
                mesh.primitives.removeAll { primitive in
                    guard let index = primitive.materialIndex, model.materials.indices.contains(index) else {
                        return false
                    }
                    return model.materials[index].alphaMode.uppercased() == "BLEND"
                }
            }
        })
    }

    func testBlendedDarkOverlaysDrawAsInk() async throws {
        let (harness, _) = try await colouredBlendHarness(colour: [0.02, 0.02, 0.02])
        let plain = CharcoalMeasure.colours(try harness.render(nil), format: harness.pixelFormat)
        let hold = CharcoalMeasure.colours(try harness.render(harness.charcoal(0.6)),
                                           format: harness.pixelFormat)
        let overlay = plain.indices.filter { Self.plainLuma(plain[$0]) < 0.10 }
        let inked = overlay.filter { CharcoalMeasure.ink(hold[$0]) > 0.75 }
        XCTAssertGreaterThan(overlay.count, 100, "fixture must expose dark blended surfaces")
        XCTAssertGreaterThanOrEqual(Float(inked.count), 0.95 * Float(overlay.count),
                                    "\(inked.count) of \(overlay.count) dark-source pixels are solid ink")
        XCTAssertLessThan(hold.map(CharcoalMeasure.offLineDistance).max() ?? 0, 0.03)
    }

    /// Pixel rows of both brows in the 512-pixel bust frame, above `eyeBand`.
    private static let browRows = 140..<168

    func testBlendedOverlaysLeaveSkinClean() async throws {
        let harness = try await CharcoalHarness(device: device(), size: 512, framing: .bust)
        let plain = CharcoalMeasure.colours(try harness.render(nil), format: harness.pixelFormat)
        let under = CharcoalMeasure.colours(try await bustWithoutOverlays().render(nil),
                                            format: harness.pixelFormat)
        let hold = CharcoalMeasure.colours(try harness.render(harness.charcoal(0.6)),
                                           format: harness.pixelFormat)
        var skin = 0
        var inked = 0
        for y in Self.browRows {
            for x in Self.eyeBand.x where Self.plainLuma(plain[y * harness.size + x]) > 0.3
                && simd_length(plain[y * harness.size + x] - under[y * harness.size + x]) < 0.03 {
                skin += 1
                if CharcoalMeasure.ink(hold[y * harness.size + x]) > 0.5 { inked += 1 }
            }
        }
        XCTAssertGreaterThan(skin, 300, "too few skin pixels around the brows")
        XCTAssertLessThan(inked, 80, "\(inked) of \(skin) skin pixels around the brows are ink")
    }

    func testBlendedHighlightsCutToPaper() async throws {
        let harness = try await CharcoalHarness(device: device(), size: 512, framing: .bust)
        let plain = CharcoalMeasure.colours(try harness.render(nil), format: harness.pixelFormat)
        let hold = CharcoalMeasure.colours(try harness.render(harness.charcoal(0.6)),
                                           format: harness.pixelFormat)

        var highlights: [Int] = []
        for y in Self.eyeBand.y {
            for x in Self.eyeBand.x where Self.plainLuma(plain[y * harness.size + x]) > 0.9 {
                var darkNeighbours = 0
                for dy in -7...7 {
                    for dx in -7...7 where Self.plainLuma(plain[(y + dy) * harness.size + x + dx]) < 0.1 {
                        darkNeighbours += 1
                    }
                }
                if darkNeighbours > 90 { highlights.append(y * harness.size + x) }
            }
        }
        let paper = highlights.filter { CharcoalMeasure.ink(hold[$0]) < 0.2 }.count
        XCTAssertGreaterThan(highlights.count, 10, "too few highlight pixels found")
        XCTAssertGreaterThanOrEqual(Float(paper), 0.7 * Float(highlights.count),
                                    "\(paper) of \(highlights.count) highlight pixels are paper")
    }
}
