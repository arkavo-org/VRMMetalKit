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

/// vrm-conformance VMK#240: the stiffness sweep `{0, 0.2, 0.8, 1}` produces
/// 4 distinct images in three-vrm 3.5.0 but only 2 in VMK — 3 of 4 stiffness
/// values collapse to a shared trajectory. Isolates the parse layer: if the
/// loader correctly captures the per-fixture VRMC_springBone joint stiffness,
/// the bug is downstream (settling counter, simulator, or
/// SpringBoneCompute pipeline). If the loader returns the wrong value, the
/// bug is in the parser.
final class SpringBoneParameterFlowTests: XCTestCase {

    func testStiffnessFactorIsParsedFromVRMC1Joints() async throws {
        let cases: [(fixture: String, expected: Float)] = [
            ("swing_springbone_stiffness_0",   0.0),
            ("swing_springbone_stiffness_0p2", 0.2),
            ("swing_springbone_stiffness_0p8", 0.8),
            ("swing_springbone_stiffness_1",   1.0)
        ]
        for c in cases {
            let model = try await loadConformanceFixture(named: c.fixture)
            let spring = try XCTUnwrap(model.springBone,
                "\(c.fixture) loaded without VRMC_springBone — parser regression.")
            let firstSpring = try XCTUnwrap(spring.springs.first,
                "\(c.fixture) has zero springs after load.")
            let joint = try XCTUnwrap(firstSpring.joints.first,
                "\(c.fixture) first spring has zero joints.")
            XCTAssertEqual(joint.stiffness, c.expected, accuracy: 1e-5,
                "\(c.fixture): expected stiffness=\(c.expected), got \(joint.stiffness)")
        }
    }

    // MARK: - Helpers

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
