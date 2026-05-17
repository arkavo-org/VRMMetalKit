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
@testable import VRMMetalKit

/// vrm-conformance VMK#238 + VMK#239: cross-impl image-hash sweeps show
/// `shadingShift`, `shadingToony`, and `rimLightingMix` collapse to a single
/// SHA across all sweep values, while reference renderers (three-vrm 3.5.0,
/// UniVRM 0.131) distinguish each value. This test isolates the parse layer
/// — if the loader correctly captures the per-fixture MToon factor, the bug
/// is downstream (renderer uniform path or shader); if the loader gets the
/// wrong value, the bug is in the parser.
final class MToonParameterFlowTests: XCTestCase {

    func testShadingShiftFactorIsParsed() async throws {
        let cases: [(fixture: String, expected: Float)] = [
            ("mtoon_default",          0.0),
            ("mtoon_shadingShift_1",   1.0),
            ("mtoon_shadingShift_neg1", -1.0)
        ]
        for c in cases {
            let model = try await loadConformanceFixture(named: c.fixture)
            let mtoon = try XCTUnwrap(model.materials.first?.mtoon,
                "\(c.fixture) is missing MToon material data after load")
            XCTAssertEqual(mtoon.shadingShiftFactor, c.expected, accuracy: 1e-5,
                "\(c.fixture): expected shadingShiftFactor=\(c.expected), got \(mtoon.shadingShiftFactor)")
        }
    }

    func testShadingToonyFactorIsParsed() async throws {
        let cases: [(fixture: String, expected: Float)] = [
            ("mtoon_default",        0.9),
            ("mtoon_shadingToony_0", 0.0),
            ("mtoon_shadingToony_1", 1.0)
        ]
        for c in cases {
            let model = try await loadConformanceFixture(named: c.fixture)
            let mtoon = try XCTUnwrap(model.materials.first?.mtoon)
            XCTAssertEqual(mtoon.shadingToonyFactor, c.expected, accuracy: 1e-5,
                "\(c.fixture): expected shadingToonyFactor=\(c.expected), got \(mtoon.shadingToonyFactor)")
        }
    }

    func testRimLightingMixFactorIsParsed() async throws {
        let cases: [(fixture: String, expected: Float)] = [
            ("mtoon_rimLightingMix_0",   0.0),
            ("mtoon_rimLightingMix_0p5", 0.5),
            ("mtoon_rimLightingMix_1",   1.0)
        ]
        for c in cases {
            let model = try await loadConformanceFixture(named: c.fixture)
            let mtoon = try XCTUnwrap(model.materials.first?.mtoon)
            XCTAssertEqual(mtoon.rimLightingMixFactor, c.expected, accuracy: 1e-5,
                "\(c.fixture): expected rimLightingMixFactor=\(c.expected), got \(mtoon.rimLightingMixFactor)")
        }
    }

    // MARK: - Helpers

    /// Loads a `.vrm` from `Tests/VRMMetalKitTests/TestData/Conformance/`.
    /// Returns the constructed ``VRMModel`` for material inspection.
    private func loadConformanceFixture(named name: String) async throws -> VRMModel {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "vrm",
            subdirectory: "TestData/Conformance"
        ) else {
            throw XCTSkip("\(name).vrm not bundled in Tests/VRMMetalKitTests/TestData/Conformance/")
        }
        return try await VRMModel.load(from: url, device: device)
    }
}
