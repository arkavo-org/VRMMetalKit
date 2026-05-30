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
import simd
@testable import VRMMetalKit

/// Pure-math TDD guard for the SkinReferenceOracle signed-distance helpers (#309).
///
/// No GPU and no model are required: these tests pin the geometry of the oracle
/// so later collision-conformance tests can trust the penetration numbers they
/// build on.
final class OracleDistanceMathTests: XCTestCase {
    private let eps: Float = 1e-5

    // MARK: - Sphere

    func testSphereSignedDistance() {
        let center = SIMD3<Float>(1, 2, 3)
        let radius: Float = 0.5
        let sphere = OracleWorldShape.sphere(center: center, radius: radius)

        // At the center: fully inside, signed distance = -radius.
        XCTAssertEqual(sphere.signedDistance(to: center), -radius, accuracy: eps)

        // On the surface: ~0.
        let onSurface = center + SIMD3<Float>(radius, 0, 0)
        XCTAssertEqual(sphere.signedDistance(to: onSurface), 0, accuracy: eps)

        // 2*radius away from center => +radius outside.
        let outside = center + SIMD3<Float>(0, 2 * radius, 0)
        XCTAssertEqual(sphere.signedDistance(to: outside), radius, accuracy: eps)
    }

    // MARK: - Capsule

    func testCapsuleSignedDistance() {
        // Capsule from (0,0,0) -> (1,0,0), radius 0.1.
        let capsule = OracleWorldShape.capsule(
            p0: SIMD3<Float>(0, 0, 0),
            p1: SIMD3<Float>(1, 0, 0),
            radius: 0.1)

        // On the axis at the midpoint: distance to segment 0 => -radius inside.
        let onAxis = SIMD3<Float>(0.5, 0, 0)
        XCTAssertEqual(capsule.signedDistance(to: onAxis), -0.1, accuracy: eps)

        // 0.3 perpendicular from the axis => 0.3 - 0.1 = 0.2 outside.
        let perpendicular = SIMD3<Float>(0.5, 0.3, 0)
        XCTAssertEqual(capsule.signedDistance(to: perpendicular), 0.2, accuracy: eps)

        // Beyond the far cap at (2,0,0): closest point clamps to the (1,0,0)
        // endpoint, so distance = |(2,0,0) - (1,0,0)| - radius = 1 - 0.1 = 0.9.
        let beyondCap = SIMD3<Float>(2, 0, 0)
        XCTAssertEqual(capsule.signedDistance(to: beyondCap), 0.9, accuracy: eps)
    }

    func testCapsuleDegenerateBehavesLikeSphere() {
        // Zero-length segment: every query clamps to p0, i.e. a sphere.
        let p = SIMD3<Float>(5, 5, 5)
        let capsule = OracleWorldShape.capsule(p0: p, p1: p, radius: 0.2)
        XCTAssertEqual(capsule.signedDistance(to: p), -0.2, accuracy: eps)
        XCTAssertEqual(
            capsule.signedDistance(to: p + SIMD3<Float>(0.2, 0, 0)), 0, accuracy: eps)
    }

    // MARK: - worstPenetration

    func testWorstPenetrationPicksDeepest() {
        let shapes: [OracleWorldShape] = [
            .sphere(center: SIMD3<Float>(0, 0, 0), radius: 0.1),
            .capsule(p0: SIMD3<Float>(0, 0, 0), p1: SIMD3<Float>(0, 1, 0), radius: 0.3),
        ]
        // The query sits at the origin: inside the sphere by 0.1, inside the
        // capsule by 0.3. worstPenetration returns the deepest (0.3).
        let pen = SkinReferenceOracle.worstPenetration(
            of: SIMD3<Float>(0, 0, 0), shapes: shapes)
        XCTAssertEqual(pen, 0.3, accuracy: eps)
    }

    func testWorstPenetrationIsZeroWhenOutsideAll() {
        let shapes: [OracleWorldShape] = [
            .sphere(center: SIMD3<Float>(0, 0, 0), radius: 0.1),
            .capsule(p0: SIMD3<Float>(1, 0, 0), p1: SIMD3<Float>(2, 0, 0), radius: 0.1),
        ]
        let pen = SkinReferenceOracle.worstPenetration(
            of: SIMD3<Float>(0, 10, 0), shapes: shapes)
        XCTAssertEqual(pen, 0, accuracy: eps)
    }

    func testWorstPenetrationEmptyShapesIsZero() {
        let pen = SkinReferenceOracle.worstPenetration(
            of: SIMD3<Float>(0, 0, 0), shapes: [])
        XCTAssertEqual(pen, 0, accuracy: eps)
    }

    // MARK: - Bundle / decode

    /// Confirms the oracle JSON is bundled and decodes through the rawValue-based
    /// bone decoder. Skips (not fails) if the resource is stripped from the build.
    func testOracleJSONLoadsAndDecodes() throws {
        let oracle = try SkinReferenceOracle.load(named: "avatar_a_skin_reference")
        XCTAssertEqual(oracle.colliders.count, 10, "Expected 10 oracle colliders")

        let bones = Set(oracle.colliders.map { $0.bone })
        XCTAssertTrue(bones.contains(.head))
        XCTAssertTrue(bones.contains(.leftUpperArm))
        XCTAssertTrue(bones.contains(.rightLowerLeg))

        // Every capsule with no explicit tail must resolve its far end via a
        // tailBone, and every shape must carry a positive radius.
        for c in oracle.colliders {
            XCTAssertGreaterThan(c.radius, 0, "\(c.bone) radius must be positive")
            if c.kind == "capsule" {
                XCTAssertTrue(c.tail != nil || c.tailBone != nil,
                              "capsule on \(c.bone) needs tail or tailBone")
            }
        }

        // The head sphere must decode as a sphere with a tail-free shape.
        let headSphere = oracle.colliders.first { $0.bone == .head && $0.kind == "sphere" }
        XCTAssertNotNil(headSphere)
        XCTAssertNil(headSphere?.tailBone)
    }
}
