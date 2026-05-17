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
        case .plane(let offset, let normal):
            // Fixture authored offset = [0.0, -0.08, 0.0], normal = [0, 1, 0].
            XCTAssertEqual(normal.x, 0.0, accuracy: 1e-5)
            XCTAssertEqual(normal.y, 1.0, accuracy: 1e-5,
                "Plane normal Y should round-trip from the extension JSON.")
            XCTAssertEqual(normal.z, 0.0, accuracy: 1e-5)
            XCTAssertEqual(offset.x, 0.0, accuracy: 1e-5)
            XCTAssertEqual(offset.y, -0.08, accuracy: 1e-4,
                "Plane offset Y should round-trip from the extension JSON " +
                "(authored value `-0.07999999821186066`, single-precision rounded).")
            XCTAssertEqual(offset.z, 0.0, accuracy: 1e-5)
        default:
            XCTFail("Extended plane should map onto VRMColliderShape.plane, got \(collider.shape)")
        }
    }

    /// Spec precedence: when both a base `shape` and a
    /// `VRMC_springBone_extended_collider.shape` are present, the
    /// **extension wins**. The base `shape` is documented as a deliberately
    /// degraded fallback for legacy loaders (the spec's own examples use
    /// `radius: 1000` spheres approximating planes, and `radius: 0` spheres
    /// at `[0, -10000, 0]` as inert filler under inverted shapes).
    ///
    /// This fixture (`*_with_base_sphere.vrm`) is the plane fixture from
    /// the previous test with an inert `radius: 0` sphere injected at
    /// `[0, -10000, 0]` as the base `shape`. If a spec-aware loader had
    /// the precedence inverted, it'd pick the sphere and the collider
    /// would land 10,000 m below the model with zero radius — visibly
    /// wrong. The assertion proves we picked the plane.
    func testBaseShapeIsFallbackWhenExtensionPresent() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }
        guard let url = Bundle.module.url(
            forResource: "springbone_extended_plane_with_base_sphere",
            withExtension: "vrm",
            subdirectory: "TestData/Conformance"
        ) else {
            throw XCTSkip("base+extension fixture not bundled")
        }

        let model = try await VRMModel.load(from: url, device: device)
        let spring = try XCTUnwrap(model.springBone)
        XCTAssertEqual(spring.colliders.count, 1)

        switch spring.colliders[0].shape {
        case .plane(_, let normal):
            XCTAssertEqual(normal.y, 1.0, accuracy: 1e-5,
                "Extension's plane normal must survive. Picking the base sphere instead means precedence is inverted (per VRMC_springBone_extended_collider 1.0 spec, extension wins).")
        case .sphere(let offset, let radius):
            XCTFail("Base sphere shape was picked over the extension's plane — precedence is inverted. " +
                    "Got sphere(offset: \(offset), radius: \(radius)) which is the degraded legacy fallback.")
        default:
            XCTFail("Unexpected shape: \(spring.colliders[0].shape)")
        }
    }

    /// Phase 2: `inside: true` sphere is now a first-class shape that maps
    /// to `.insideSphere`. The GPU collision kernel branches on
    /// `SphereCollider.inside` to use containment math (push joint *toward*
    /// the centre when it tries to escape the radius) rather than the
    /// default outside-collision (push away from the centre when it
    /// penetrates).
    func testInsideSphereColliderLoadsAsInvertedShape() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }
        guard let url = Bundle.module.url(
            forResource: "springbone_extended_isphere_pmed",
            withExtension: "vrm",
            subdirectory: "TestData/Conformance"
        ) else {
            throw XCTSkip("springbone_extended_isphere_pmed.vrm not bundled")
        }

        let model = try await VRMModel.load(from: url, device: device)
        let spring = try XCTUnwrap(model.springBone)
        XCTAssertEqual(spring.colliders.count, 1)

        switch spring.colliders[0].shape {
        case .insideSphere(_, let radius):
            XCTAssertEqual(radius, 0.2, accuracy: 1e-5,
                "Fixture sphere radius is `0.2`; must round-trip through the extension parser.")
        default:
            XCTFail("Inverted sphere should map to .insideSphere, got \(spring.colliders[0].shape)")
        }
    }

    /// Phase 2: `inside: true` capsule maps to `.insideCapsule`.
    func testInsideCapsuleColliderLoadsAsInvertedShape() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }
        guard let url = Bundle.module.url(
            forResource: "springbone_extended_icaps_pmed",
            withExtension: "vrm",
            subdirectory: "TestData/Conformance"
        ) else {
            throw XCTSkip("springbone_extended_icaps_pmed.vrm not bundled")
        }

        let model = try await VRMModel.load(from: url, device: device)
        let spring = try XCTUnwrap(model.springBone)
        XCTAssertEqual(spring.colliders.count, 1)

        switch spring.colliders[0].shape {
        case .insideCapsule(_, let radius, _):
            XCTAssertEqual(radius, 0.2, accuracy: 1e-5,
                "Fixture capsule radius is `0.2`.")
        default:
            XCTFail("Inverted capsule should map to .insideCapsule, got \(spring.colliders[0].shape)")
        }
    }

    /// Phase 3: per-joint `angleLimit` from the extension is parsed onto
    /// each `VRMSpringJoint` as **radians**. The fixture authors `60` (in
    /// degrees, per conformance-suite convention) and the loader converts
    /// to radians (~1.0472) at the parser boundary so the GPU kernel in
    /// `SpringBonePredict.metal` can `cos()` it directly.
    ///
    /// Pinning the unit contract: if a reader instead treats the file
    /// value as radians, `cos(60 rad) ≈ -0.95` and the cone is
    /// effectively unbounded — the regression sweeps would silently lose
    /// the angleLimit signal.
    func testPerJointAngleLimitParsesAsRadiansFromDegreesInFile() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }
        guard let url = Bundle.module.url(
            forResource: "springbone_extended_isphere_anglelimit_60",
            withExtension: "vrm",
            subdirectory: "TestData/Conformance"
        ) else {
            throw XCTSkip("springbone_extended_isphere_anglelimit_60.vrm not bundled")
        }

        let model = try await VRMModel.load(from: url, device: device)
        let spring = try XCTUnwrap(model.springBone)
        let firstSpring = try XCTUnwrap(spring.springs.first)
        XCTAssertGreaterThan(firstSpring.joints.count, 0)

        // Fixture authors `angleLimit: 60` (degrees). Internal contract is
        // radians, so the parsed value must equal 60 * π/180.
        let expectedRadians: Float = 60.0 * .pi / 180.0
        for (idx, joint) in firstSpring.joints.enumerated() {
            XCTAssertEqual(joint.angleLimit, expectedRadians, accuracy: 1e-4,
                "Joint \(idx) angleLimit must be parsed as radians (~1.0472). " +
                "Got \(joint.angleLimit); if this equals 60.0 the parser is " +
                "skipping the deg→rad conversion and the cone-clamp signal is lost.")
        }
    }
}
