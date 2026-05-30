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

/// Loud integrity guard for the hand-authored skin-reference oracle (#309).
///
/// The oracle's collider radii were measured against AvatarSample_A's real mesh.
/// If the fixture is ever re-exported, the oracle silently drifts and the
/// regression tests rot. This test fingerprints the model (vertex count + Y
/// bounding box) and asserts it against the value baked into the oracle JSON, so
/// asset drift FAILS THE BUILD instead of silently passing.
final class SkinReferenceOracleIntegrityTests: XCTestCase {

    @MainActor
    func testAvatarSampleAMatchesOracleIntegrity() async throws {
        let path = getTestVRM10ModelPath()
        try requireFixture(path, hint: testVRM10Filename)

        // Vertex buffers need a Metal device to be resident/readable; match how
        // SkinReferenceMeasureUtil loads the model.
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device")
        }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)

        let oracle = try SkinReferenceOracle.load(named: "avatar_a_skin_reference")
        let measured = SkinReferenceOracle.measureIntegrity(model: model)

        // Guard against a vacuous 0 == 0 pass if vertices were unreadable (device/
        // buffer issue) and the oracle JSON was ever reset to zeros.
        XCTAssertGreaterThan(measured.vertexCount, 0,
            "No vertices read back from AvatarSample_A — Metal buffer/device issue, not asset drift.")
        XCTAssertEqual(measured.vertexCount, oracle.integrity.vertexCount,
            "AvatarSample_A vertex count changed (\(measured.vertexCount) vs oracle \(oracle.integrity.vertexCount)) — the skin-reference oracle is stale. Re-trace it, then update integrity.")
        XCTAssertEqual(measured.bboxMinY, oracle.integrity.bboxMinY, accuracy: 0.001,
            "AvatarSample_A min-Y changed (\(measured.bboxMinY) vs \(oracle.integrity.bboxMinY)) — oracle stale.")
        XCTAssertEqual(measured.bboxMaxY, oracle.integrity.bboxMaxY, accuracy: 0.001,
            "AvatarSample_A max-Y changed (\(measured.bboxMaxY) vs \(oracle.integrity.bboxMaxY)) — oracle stale.")
    }

    @MainActor
    func testAvatarSampleUMatchesOracleIntegrity() async throws {
        let path = getTestModelPath("AvatarSample_U_1.0.vrm.glb")
        try requireFixture(path, hint: "AvatarSample_U_1.0.vrm.glb")

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device")
        }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)

        let oracle = try SkinReferenceOracle.load(named: "avatar_u_skin_reference")
        let measured = SkinReferenceOracle.measureIntegrity(model: model)

        XCTAssertGreaterThan(measured.vertexCount, 0,
            "No vertices read back from AvatarSample_U — Metal buffer/device issue, not asset drift.")
        XCTAssertEqual(measured.vertexCount, oracle.integrity.vertexCount,
            "AvatarSample_U vertex count changed (\(measured.vertexCount) vs oracle \(oracle.integrity.vertexCount)) — the U skin-reference oracle is stale. Re-trace it, then update integrity.")
        XCTAssertEqual(measured.bboxMinY, oracle.integrity.bboxMinY, accuracy: 0.001,
            "AvatarSample_U min-Y changed (\(measured.bboxMinY) vs \(oracle.integrity.bboxMinY)) — U oracle stale.")
        XCTAssertEqual(measured.bboxMaxY, oracle.integrity.bboxMaxY, accuracy: 0.001,
            "AvatarSample_U max-Y changed (\(measured.bboxMaxY) vs \(oracle.integrity.bboxMaxY)) — U oracle stale.")
    }
}
