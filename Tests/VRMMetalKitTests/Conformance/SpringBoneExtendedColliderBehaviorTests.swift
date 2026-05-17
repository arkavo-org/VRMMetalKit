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

/// Behavioral regression suite for vrm-conformance issue **VMK#237**:
/// `VRMC_springBone_extended_collider` is parsed but applied inconsistently.
/// The QA team's 18-variant swing sweep collapsed to 7 SHA256 buckets with
/// clusters that **don't track any single swept axis**.
///
/// This file goes after the runtime bug, not the parser. `ExtendedColliderTests`
/// already pins the parser's struct mapping; what's still untested is whether
/// the *simulation* honours the parsed geometry once the chain swings into
/// the collider.
///
/// ## Testing philosophy
///
/// Each test makes **one spec-grounded assertion** about an observable
/// post-swing invariant of the joint trajectory, sourced from the published
/// `VRMC_springBone_extended_collider-1.0` spec:
///
///   * `shape.plane`: "restricts the spring bone to one side of the plane"
///     — every joint must end up on the positive-normal half-space (with
///     `hitRadius` margin).
///   * `shape.sphere.inside = true`: "the collider prevents spring bones
///     from going outside of the sphere" — every joint must end up within
///     the sphere (distance-from-centre ≤ radius − `hitRadius`).
///   * `shape.capsule.inside = true`: same containment rule, distance to
///     the capsule axis.
///   * Pairwise distinctness: variants whose collider geometry differs must
///     drive measurably different chain trajectories under the same
///     animation. Byte-identical trajectories for distinct geometry is the
///     #237 signal.
///
/// ## Coverage limit
///
/// Only 5 of the 18 fixtures from the QA sweep are bundled in-tree right
/// now (`*_pmed` placements for each shape + one `_anglelimit_60`). Tests
/// `XCTSkip` when their fixtures are missing rather than failing — that
/// keeps the suite green on the subset we ship while letting the bundle
/// grow without code changes. The 13 missing fixtures (`*_ptight`,
/// `*_ploose`, `*_anglelimit_30`, `*_anglelimit_90` for each shape) need
/// to be vendored from the vrm-conformance corpus before the sweep tests
/// can run end-to-end.
///
/// ## Status: RED
///
/// These tests are expected to **fail** until #237 is resolved. When they
/// turn green the chaotic clustering has stopped reproducing.
final class SpringBoneExtendedColliderBehaviorTests: XCTestCase {

    /// Same swing parameters as `SpringBoneSwingTrajectoryTests` so the
    /// trajectory comparison matches the conformance harness.
    private let swingTranslationEnd = SIMD3<Float>(0.15, 0, 0)
    private let swingDurationSeconds: Float = 0.25
    private let swingFPS: Int = 60
    private let warmupSteps: Int = 30

    // MARK: - Spec assertion 1: plane half-space

    /// Spec: "Plane collider restricts the spring bone to one side of the
    /// plane" — the side the normal points into. After a swing animation,
    /// every joint must end on that half-space (within a tolerance for
    /// the joint's `hitRadius` and PBD relaxation residual).
    ///
    /// Fixture: `springbone_extended_plane_pmed.vrm` (plane offset
    /// `[0, -0.08, 0]` in head local space, normal `[0, 1, 0]`). The
    /// hair chain hangs below the plane in the bind pose, so the plane
    /// must actively push joints up to satisfy its half-space.
    func testExtendedPlaneColliderEnforcesPositiveNormalHalfSpace() async throws {
        let env = try prepareEnv()
        let bundle = try await simulateSwing(fixture: "springbone_extended_plane_pmed",
                                              env: env)

        // Plane geometry recovered from the loaded collider so we don't
        // duplicate the fixture's authored values here.
        let collider = try XCTUnwrap(bundle.model.springBone?.colliders.first,
            "Fixture must load with one plane collider.")
        guard case let .plane(localOffset, localNormal) = collider.shape else {
            XCTFail("Fixture must load as `.plane`, got \(collider.shape)."); return
        }
        let anchorNode = try XCTUnwrap(bundle.model.nodes[safe: collider.node],
            "Plane collider node \(collider.node) out of range.")
        let planeWorld = anchorNode.worldPosition + localOffset
        let planeNormalWorld = simd_normalize(localNormal)  // identity-rotation rig

        // Spec tolerance: a joint may sit `hitRadius` deep into the plane
        // by definition (hitRadius is the joint's collision radius); PBD
        // relaxation leaves a small additional residual. Bound at
        // `hitRadius + 5 mm`.
        let hitRadius: Float = 0.02
        let tolerance: Float = hitRadius + 0.005

        var worstSignedDistance: Float = .greatestFiniteMagnitude
        var worstJointIdx: Int = -1
        for (i, joint) in bundle.tipPositions.enumerated() {
            let signedDistance = simd_dot(joint - planeWorld, planeNormalWorld)
            if signedDistance < worstSignedDistance {
                worstSignedDistance = signedDistance
                worstJointIdx = i
            }
        }

        XCTExpectFailure("VMK#237: plane collider does not push joints to its positive-normal half-space")
        XCTAssertGreaterThan(worstSignedDistance, -tolerance,
            "Spec: VRMC_springBone_extended_collider.shape.plane restricts " +
            "joints to the positive-normal half-space. After settling, joint " +
            "\(worstJointIdx) is at signed distance \(worstSignedDistance) m " +
            "from the plane (negative = on the wrong side, > \(tolerance) m " +
            "= clearly violating). Plane at world \(planeWorld) with normal " +
            "\(planeNormalWorld). VMK#237: when the plane collider is one of " +
            "the variants that hash-collapses to a no-op bucket, this " +
            "invariant fails because the plane isn't actually pushing joints.")
    }

    // MARK: - Spec assertion 2: inside-sphere containment

    /// Spec: `shape.sphere.inside = true` "prevents spring bones from going
    /// outside of the sphere." After the swing animation every joint must
    /// be inside the sphere (distance from centre ≤ radius − `hitRadius`,
    /// with PBD slack).
    ///
    /// Fixture: `springbone_extended_isphere_pmed.vrm`. The hair chain
    /// hangs below the head anchor; the swing translates the root +X,
    /// dragging the chain tips toward the sphere boundary along that axis.
    func testInsideSphereColliderKeepsJointsInsideAfterSwing() async throws {
        let env = try prepareEnv()
        let bundle = try await simulateSwing(fixture: "springbone_extended_isphere_pmed",
                                              env: env)

        let collider = try XCTUnwrap(bundle.model.springBone?.colliders.first)
        guard case let .insideSphere(localOffset, radius) = collider.shape else {
            XCTFail("Fixture must load as `.insideSphere`, got \(collider.shape)."); return
        }
        let anchorNode = try XCTUnwrap(bundle.model.nodes[safe: collider.node])
        let centerWorld = anchorNode.worldPosition + localOffset
        let hitRadius: Float = 0.02
        let tolerance: Float = 0.01    // 1 cm PBD slack

        var worstExcess: Float = -.greatestFiniteMagnitude
        var worstJoint = -1
        for (i, joint) in bundle.tipPositions.enumerated() {
            let dist = simd_distance(joint, centerWorld)
            // excess > 0 means joint escaped the sphere (distance exceeds
            // the safe inner surface radius - hitRadius).
            let excess = dist - (radius - hitRadius)
            if excess > worstExcess {
                worstExcess = excess
                worstJoint = i
            }
        }

        XCTExpectFailure("VMK#237: insideSphere containment lets joints escape")
        XCTAssertLessThan(worstExcess, tolerance,
            "Spec: VRMC_springBone_extended_collider.shape.sphere with " +
            "inside=true keeps joints inside the sphere. After settling, " +
            "joint \(worstJoint) has distance-to-centre exceeding the safe " +
            "inner surface by \(worstExcess) m (tolerance \(tolerance) m). " +
            "Sphere centre world \(centerWorld), radius \(radius). " +
            "VMK#237: this is where containment colliders fail when the " +
            "shader branch on `inside == 1` isn't engaging.")
    }

    // MARK: - Spec assertion 3: inside-capsule containment

    /// Spec: `shape.capsule.inside = true` keeps joints inside the
    /// swept-sphere capsule volume. Analogous to the inside-sphere
    /// invariant but the distance is measured to the capsule axis.
    func testInsideCapsuleColliderKeepsJointsInsideAfterSwing() async throws {
        let env = try prepareEnv()
        let bundle = try await simulateSwing(fixture: "springbone_extended_icaps_pmed",
                                              env: env)

        let collider = try XCTUnwrap(bundle.model.springBone?.colliders.first)
        guard case let .insideCapsule(localOffset, radius, tail) = collider.shape else {
            XCTFail("Fixture must load as `.insideCapsule`, got \(collider.shape)."); return
        }
        let anchorNode = try XCTUnwrap(bundle.model.nodes[safe: collider.node])
        let p0World = anchorNode.worldPosition + localOffset
        let p1World = p0World + tail
        let hitRadius: Float = 0.02
        let tolerance: Float = 0.01

        var worstExcess: Float = -.greatestFiniteMagnitude
        var worstJoint = -1
        for (i, joint) in bundle.tipPositions.enumerated() {
            let dist = distanceFromPointToSegment(point: joint, a: p0World, b: p1World)
            let excess = dist - (radius - hitRadius)
            if excess > worstExcess {
                worstExcess = excess
                worstJoint = i
            }
        }

        XCTExpectFailure("VMK#237: insideCapsule containment lets joints escape")
        XCTAssertLessThan(worstExcess, tolerance,
            "Spec: VRMC_springBone_extended_collider.shape.capsule with " +
            "inside=true keeps joints inside the capsule. After settling, " +
            "joint \(worstJoint) has distance-to-axis exceeding the safe " +
            "inner surface by \(worstExcess) m. Capsule p0=\(p0World) " +
            "p1=\(p1World) radius=\(radius). VMK#237.")
    }

    // MARK: - QA-team clustering: shape variants must produce distinct trajectories

    /// QA-team clustering signal: three different shape variants at the
    /// SAME placement must produce **measurably different** chain
    /// trajectories under the same swing animation. Per #237, several of
    /// the 18 swept variants hash-collapse — proving that the simulation
    /// silently treats distinct geometry as equivalent.
    ///
    /// This is the in-process version of the QA hash bucket check. If any
    /// two of the three variants produce identical joint trajectories,
    /// the variant is being treated as if it had no collider OR the same
    /// collider as another variant.
    func testPmedShapeVariantsProduceDistinctTrajectories() async throws {
        let env = try prepareEnv()

        let fixtures = [
            "springbone_extended_plane_pmed",
            "springbone_extended_isphere_pmed",
            "springbone_extended_icaps_pmed"
        ]
        var bundles: [String: SimulationBundle] = [:]
        for f in fixtures {
            bundles[f] = try await simulateSwing(fixture: f, env: env)
        }

        // Threshold matches `SpringBoneSwingTrajectoryTests` (1 mm).
        let threshold: Float = 0.001
        var collisions: [String] = []
        for i in 0..<fixtures.count {
            for j in (i + 1)..<fixtures.count {
                let a = fixtures[i]
                let b = fixtures[j]
                guard let posA = bundles[a]?.tipPositions,
                      let posB = bundles[b]?.tipPositions,
                      posA.count == posB.count else {
                    XCTFail("Joint count mismatch between \(a) and \(b)."); continue
                }
                let maxDelta = zip(posA, posB)
                    .map { simd_distance($0, $1) }
                    .max() ?? 0
                if maxDelta < threshold {
                    collisions.append("\(a) ≡ \(b) (max Δ = \(maxDelta) m)")
                }
            }
        }

        XCTAssertTrue(collisions.isEmpty,
            "VMK#237: distinct shape geometries must drive distinct chain " +
            "trajectories under the same swing. Collisions detected: " +
            "[\(collisions.joined(separator: "; "))]. " +
            "These pairs differ in their `VRMC_springBone_extended_collider` " +
            "shape but produce the same simulated chain pose — the QA team's " +
            "SHA256-bucket signature of the bug.")
    }

    /// QA-team clustering signal for angle-limit: a variant with
    /// `angleLimit: 60` must produce a different chain trajectory than the
    /// otherwise-identical variant with no angle limit. The QA sweep
    /// found that angle-limit variants collapsed into the same buckets as
    /// shape variants — implying angleLimit doesn't measurably affect the
    /// settled chain.
    ///
    /// Fixtures: `springbone_extended_isphere_pmed` (no angleLimit) vs
    /// `springbone_extended_isphere_anglelimit_60` (60° cone).
    func testAngleLimitVariantDiffersFromNoLimitBaseline() async throws {
        let env = try prepareEnv()
        let baseline = try await simulateSwing(fixture: "springbone_extended_isphere_pmed",
                                                env: env)
        let limited = try await simulateSwing(fixture: "springbone_extended_isphere_anglelimit_60",
                                               env: env)

        XCTAssertEqual(baseline.tipPositions.count, limited.tipPositions.count,
            "Fixture joint counts must match for trajectory comparison.")

        let maxDelta = zip(baseline.tipPositions, limited.tipPositions)
            .map { simd_distance($0, $1) }
            .max() ?? 0
        let threshold: Float = 0.001

        // Post-VMK#270 (spec-aligned gravity) note: both fixtures settle
        // straight down under gravity in the standard swing scenario,
        // which never approaches the 60° cone — so the cone never bites
        // and `maxDelta` is 0. This is not evidence the angle-limit
        // clamp is broken; it's evidence the swing geometry doesn't
        // exercise it. A dedicated swing or rotation that pushes the
        // chain past 60° is needed; tracked alongside the broader
        // VMK#237 follow-up. Wrap the strict assertion in
        // `XCTExpectFailure` until the test geometry catches up.
        XCTExpectFailure("VMK#237 follow-up: swing geometry doesn't reach the 60° cone after the VMK#270 gravity rebalance — chain settles straight down before the angle limit can engage")
        XCTAssertGreaterThan(maxDelta, threshold,
            "VMK#237: a 60° angle limit must measurably constrain the chain " +
            "swing relative to the no-limit baseline. Got max joint Δ = " +
            "\(maxDelta) m (threshold \(threshold) m). If this is ≈ 0 the " +
            "angle-limit clamp in SpringBonePredict.metal is not engaging " +
            "under this animation, even though the parser correctly reads " +
            "`angleLimit` onto the joints (covered by " +
            "`ExtendedColliderTests.testPerJointAngleLimitParsesAsRadiansFromDegreesInFile`).")
    }

    // MARK: - Full 18-variant sweep (QA reproduction)

    /// Reproduces the vrm-conformance QA team's 18-variant swing sweep
    /// in-process. The QA team observed 7 SHA256 buckets across 18
    /// distinct fixtures via the render-image path; this test runs the
    /// same fixtures through the sim and clusters their joint
    /// trajectories with a 1 mm threshold.
    ///
    /// Spec-correct outcome: **18 distinct buckets** (one per variant).
    /// Each unique (shape, placement, angleLimit) tuple should drive a
    /// distinct chain trajectory under the same swing.
    ///
    /// Observed under VMK#237: significant clustering (≪ 18 buckets).
    /// `XCTExpectFailure` flips this to a regression detector — when the
    /// runtime honours the spec the assertion becomes strict and the
    /// expected-failure annotation can come out.
    ///
    /// Bucket placements (from `vrm-conformance`
    /// `2026-05-15-springbone-phase3-extended-colliders` plan):
    ///
    ///   * plane Y offset:     ptight = −0.04, pmed = −0.08, ploose = −0.15
    ///   * sphere/icaps radius: ptight = 0.10,  pmed = 0.20,  ploose = 0.40
    ///   * capsule tail:       (0, 0.30, 0) always
    ///   * angleLimit (each joint): 30 / 60 / 90 degrees, at medium
    ///     placement (radius 0.20 / plane y −0.08)
    func testFullExtendedColliderSweepProducesDistinctTrajectoryBuckets() async throws {
        let env = try prepareEnv()
        let variants = [
            "springbone_extended_plane_ptight",
            "springbone_extended_plane_pmed",
            "springbone_extended_plane_ploose",
            "springbone_extended_plane_anglelimit_30",
            "springbone_extended_plane_anglelimit_60",
            "springbone_extended_plane_anglelimit_90",
            "springbone_extended_isphere_ptight",
            "springbone_extended_isphere_pmed",
            "springbone_extended_isphere_ploose",
            "springbone_extended_isphere_anglelimit_30",
            "springbone_extended_isphere_anglelimit_60",
            "springbone_extended_isphere_anglelimit_90",
            "springbone_extended_icaps_ptight",
            "springbone_extended_icaps_pmed",
            "springbone_extended_icaps_ploose",
            "springbone_extended_icaps_anglelimit_30",
            "springbone_extended_icaps_anglelimit_60",
            "springbone_extended_icaps_anglelimit_90",
        ]

        var trajectories: [String: [SIMD3<Float>]] = [:]
        for v in variants {
            trajectories[v] = try await simulateSwing(fixture: v, env: env).tipPositions
        }

        // Bucket variants by trajectory similarity (1 mm max-joint-Δ).
        let threshold: Float = 0.001
        var buckets: [[String]] = []
        for v in variants {
            guard let traj = trajectories[v] else { continue }
            var matched = false
            for i in 0..<buckets.count {
                guard let rep = trajectories[buckets[i][0]] else { continue }
                if traj.count == rep.count {
                    let maxDelta = zip(traj, rep).map { simd_distance($0, $1) }.max() ?? 0
                    if maxDelta < threshold {
                        buckets[i].append(v)
                        matched = true
                        break
                    }
                }
            }
            if !matched {
                buckets.append([v])
            }
        }

        let summary = buckets.enumerated().map { (i, bucket) in
            "  bucket \(i + 1) (\(bucket.count)): \(bucket.joined(separator: ", "))"
        }.joined(separator: "\n")

        XCTExpectFailure("VMK#237: 18 extended-collider variants collapse into <18 buckets — same signature the QA team reported as 7 SHA256 buckets")
        XCTAssertEqual(buckets.count, variants.count,
            "VMK#237 full sweep: expected \(variants.count) distinct chain " +
            "trajectories (one per variant), got \(buckets.count) buckets. " +
            "Bucket layout:\n\(summary)\n" +
            "Each bucket holds variants whose post-swing chain pose differs by " +
            "less than \(threshold * 1000) mm at every joint — i.e. the " +
            "extended-collider parameters distinguishing them have no " +
            "observable effect on the simulation.")
    }

    // MARK: - Harness

    private struct Env {
        let device: MTLDevice
        let commandQueue: MTLCommandQueue
    }

    private struct SimulationBundle {
        let model: VRMModel
        let tipPositions: [SIMD3<Float>]   // bone-buffer positions after swing
    }

    private func prepareEnv() throws -> Env {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Could not create command queue.")
        }
        return Env(device: device, commandQueue: queue)
    }

    /// Load a conformance fixture by name, run the standard swing
    /// animation, and return both the loaded `VRMModel` (so callers can
    /// recover collider geometry without duplicating fixture values) and
    /// the final per-joint world positions read from `bonePosCurr`.
    ///
    /// Uses a host-owned `MTLCommandBuffer` per frame so the readback is
    /// deterministic. Mirrors the harness in
    /// `SpringBoneSwingTrajectoryTests` for parity with the upstream
    /// conformance check.
    private func simulateSwing(fixture: String, env: Env) async throws -> SimulationBundle {
        guard let url = Bundle.module.url(
            forResource: fixture,
            withExtension: "vrm",
            subdirectory: "TestData/Conformance"
        ) else {
            throw XCTSkip("\(fixture).vrm not bundled in TestData/Conformance/. " +
                "The full vrm-conformance #237 sweep needs 18 fixtures; only " +
                "the *_pmed and isphere_anglelimit_60 subset is currently in-tree.")
        }

        let model = try await VRMModel.load(from: url, device: env.device)
        let system = try SpringBoneComputeSystem(device: env.device)
        try system.populateSpringBoneData(model: model)
        system.warmupPhysics(model: model, steps: warmupSteps)

        let rootNodes = model.nodes.filter { $0.parent == nil }
        let originals = rootNodes.map { $0.translation }
        let totalFrames = max(1, Int((swingDurationSeconds * Float(swingFPS)).rounded()))
        for frame in 1...totalFrames {
            let t = Float(frame) / Float(totalFrames)
            let offset = swingTranslationEnd * t
            for (idx, root) in rootNodes.enumerated() {
                root.translation = originals[idx] + offset
                root.updateWorldTransform()
            }
            guard let cb = env.commandQueue.makeCommandBuffer() else {
                throw XCTSkip("Could not create command buffer.")
            }
            system.update(model: model, deltaTime: 1.0 / Double(swingFPS),
                          commandBuffer: cb)
            cb.commit()
            await cb.completed()
        }

        guard let buffers = model.springBoneBuffers,
              let bonePosCurr = buffers.bonePosCurr,
              buffers.numBones > 0 else {
            XCTFail("\(fixture): no spring-bone buffers after simulation.")
            return SimulationBundle(model: model, tipPositions: [])
        }
        let ptr = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self,
                                                    capacity: buffers.numBones)
        let tips = (0..<buffers.numBones).map { ptr[$0] }
        return SimulationBundle(model: model, tipPositions: tips)
    }

    private func distanceFromPointToSegment(
        point: SIMD3<Float>,
        a: SIMD3<Float>,
        b: SIMD3<Float>
    ) -> Float {
        let ab = b - a
        let abLen2 = simd_dot(ab, ab)
        if abLen2 < 1e-6 { return simd_distance(point, a) }
        let t = max(0.0, min(1.0, simd_dot(point - a, ab) / abLen2))
        let closest = a + t * ab
        return simd_distance(point, closest)
    }
}
