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

/// VMK#237 phase 1 lock-in: VMK now parses
/// `VRMC_springBone_extended_collider.shape.plane` and routes it through
/// the existing plane-collider kernel. Non-inverted sphere/capsule shapes
/// in the extension also map onto the base sphere/capsule colliders.
/// Inverted (`inside=true`) variants still get a skip-with-warning until
/// the containment-collision kernel ships (phase 2).
final class ExtendedColliderTests: XCTestCase {

    /// A fixture authored with `VRMC_springBone_extended_collider.shape.plane`
    /// (no fallback base `shape`). Pre-PR, parseSpringBone skipped this
    /// collider entirely and the chain saw nothing. Post-PR, the plane is
    /// routed through VMK's existing plane-collider path, so the loaded
    /// model has one collider.
    func testExtendedPlaneColliderLoadsAndRegisters() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }
        guard let url = Bundle.module.url(
            forResource: "springbone_extended_plane_pmed",
            withExtension: "vrm",
            subdirectory: "TestData/Conformance"
        ) else {
            throw XCTSkip("springbone_extended_plane_pmed.vrm not bundled")
        }

        let model = try await VRMModel.load(from: url, device: device)
        let spring = try XCTUnwrap(model.springBone,
            "fixture must load with VRMC_springBone data")

        XCTAssertEqual(spring.colliders.count, 1,
            "Plane extended-collider should load as one VRMCollider; " +
            "got \(spring.colliders.count). Pre-PR #237 phase 1 this was 0 because " +
            "the extension's `shape` wasn't read.")

        let collider = spring.colliders[0]
        switch collider.shape {
        case .plane(_, let normal):
            // Fixture's plane normal is (0, 1, 0) per the extension JSON.
            XCTAssertEqual(normal.y, 1.0, accuracy: 1e-5,
                "Plane normal Y should round-trip from the extension JSON.")
            XCTAssertEqual(normal.x, 0.0, accuracy: 1e-5)
            XCTAssertEqual(normal.z, 0.0, accuracy: 1e-5)
        default:
            XCTFail("Extended plane should map onto VRMColliderShape.plane, got \(collider.shape)")
        }
    }
}
