//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Spec §6.2 — the sphere-at-joint blind spot made into a fixture.
/// A two-joint chain hangs vertically; an authored sphere collider sits in the
/// INTER-JOINT GAP with clearance from both joints but overlapping the segment.
///
/// Case 1 (gap): flag-on, the child deflects; flag-off passes through — flag-off
/// IS the sabotage, and both outcomes are asserted.
/// Case 2 (at-joint): the collider centered on a joint. flag-on ≈ flag-off
/// within a tolerance DERIVED from the recorded flag-off contact depth, plus a
/// multi-frame settling assertion (no growing oscillation) — this is what
/// bounds the child-only correction's small-t overshoot; its named fallback is
/// the spec §4 t-scaled correction.
///
/// §6.5 determinism (two identical flag-on runs, bit-compared) lives here too,
/// alongside the live-read sabotage record (Task 4's own dry run of it; Task 5
/// automates the sabotage/restore cycle).
final class SegmentCollisionGapTests: XCTestCase {

    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device")
        }
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Could not create Metal command queue")
        }
        self.device = device
        self.commandQueue = queue
    }

    // MARK: - Fixture: three-node chain (root anchor + parent joint + child joint)

    /// Builds `root -> parent -> child`, all physics-driven except `root`
    /// (bone 0, kinematic/animated — stays fixed since nothing animates it).
    /// Colliders are NOT authored on `model.springBone` — the caller writes
    /// the sphere directly into `buffers.sphereColliders` afterward (via
    /// `writeSphere`) so tests can control `responseScale`, which the
    /// `VRMCollider` authoring path never sets (it always defaults to 1.0).
    private func makeThreeNodeChain(
        rootWorld: SIMD3<Float>,
        parentLocalOffset: SIMD3<Float>,
        childLocalOffset: SIMD3<Float>,
        parentHitRadius: Float,
        childHitRadius: Float,
        parentGravityPower: Float,
        childGravityPower: Float,
        parentDrag: Float,
        childDrag: Float,
        childStiffness: Float = 0.0
    ) throws -> VRMModel {
        let model = try SpringBoneTestFixtures.makeChainModel(
            device: device,
            names: ["root", "parent", "child"],
            translations: [rootWorld, parentLocalOffset, childLocalOffset]
        )

        var rootJoint = SpringBoneTestFixtures.defaultJoint(node: 0)
        rootJoint.stiffness = 0.0
        rootJoint.gravityPower = 0.0

        var parentJoint = SpringBoneTestFixtures.defaultJoint(node: 1)
        parentJoint.stiffness = 0.0
        parentJoint.gravityPower = parentGravityPower
        parentJoint.dragForce = parentDrag
        parentJoint.hitRadius = parentHitRadius

        var childJoint = SpringBoneTestFixtures.defaultJoint(node: 2)
        childJoint.stiffness = childStiffness
        childJoint.gravityPower = childGravityPower
        childJoint.dragForce = childDrag
        childJoint.hitRadius = childHitRadius

        var spring = VRMSpring(name: "GapTestSpring")
        spring.joints = [rootJoint, parentJoint, childJoint]

        var sb = VRMSpringBone()
        sb.springs = [spring]
        model.springBone = sb

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 3, numSpheres: 1, numCapsules: 0)
        model.springBoneBuffers = buffers
        model.springBoneGlobalParams = SpringBoneTestFixtures.defaultGlobalParams(
            numBones: 3, numSpheres: 1
        )
        return model
    }

    /// Writes a single sphere collider directly into `buffers.sphereColliders`,
    /// bypassing the `VRMCollider` authoring path so `responseScale` (never
    /// settable from authored colliders — `populateSpringBoneData` always
    /// constructs `SphereCollider` with the 1.0 default) can be controlled.
    private func writeSphere(buffers: SpringBoneBuffers, sphere: SphereCollider) {
        guard let buf = buffers.sphereColliders else {
            return XCTFail("sphereColliders buffer not allocated")
        }
        let ptr = buf.contents().bindMemory(to: SphereCollider.self, capacity: 1)
        ptr[0] = sphere
    }

    // MARK: - Case 1: gap (sphere between the joints, clear of both)

    /// Parent hangs fixed (no forces); child starts 60° off vertical and
    /// swings down under gravity + drag toward hanging directly below parent.
    /// The sphere sits exactly at that vertical equilibrium point, with
    /// `responseScale = 0` (ghost for the untouched per-joint endpoint
    /// kernel) so ONLY the new segment kernel can ever resist the swing —
    /// this isolates the segment-only blind spot the existing kernels
    /// structurally cannot see (both joints keep clearance from the sphere
    /// throughout: parent is 1 m away always, child starts 1 m away and only
    /// the swept SEGMENT, not either endpoint, ever gets close).
    private func makeGapScene() throws -> (model: VRMModel, sphereCenter: SIMD3<Float>,
                                            sphereRadius: Float, jointRadius: Float) {
        let rootWorld = SIMD3<Float>(0, 3, 0)
        let parentWorld = SIMD3<Float>(0, 2, 0)          // 1 m below root
        let angle: Float = .pi / 3                        // 60° from vertical
        let childOffset = SIMD3<Float>(sin(angle), -cos(angle), 0)  // unit, distance 1 from parent
        let childWorld = parentWorld + childOffset

        let jointRadius: Float = 0.02
        let model = try makeThreeNodeChain(
            rootWorld: rootWorld,
            parentLocalOffset: parentWorld - rootWorld,
            childLocalOffset: childOffset,
            parentHitRadius: jointRadius,
            childHitRadius: jointRadius,
            parentGravityPower: 0.0,
            childGravityPower: 1.0,
            parentDrag: 0.5,
            childDrag: 0.6
        )

        let sphereCenter = parentWorld + SIMD3<Float>(0, -1, 0)  // child's vertical equilibrium
        let sphereRadius: Float = 0.15
        var sphere = SphereCollider(center: sphereCenter, radius: sphereRadius, groupMask: 0xFFFFFFFF)
        sphere.responseScale = 0  // ghost the untouched per-joint kernel; only the segment kernel may act
        guard let buffers = model.springBoneBuffers else {
            throw XCTSkip("buffers missing")
        }
        writeSphere(buffers: buffers, sphere: sphere)

        // Sanity: both joints keep clearance from the sphere at the START.
        let minDistEndpoint = sphereRadius + jointRadius
        XCTAssertGreaterThan(simd_distance(parentWorld, sphereCenter), minDistEndpoint,
            "fixture bug: parent must start clear of the sphere")
        XCTAssertGreaterThan(simd_distance(childWorld, sphereCenter), minDistEndpoint,
            "fixture bug: child must start clear of the sphere")

        return (model, sphereCenter, sphereRadius, jointRadius)
    }

    /// Runs the gap scene to settling and returns the child's final position.
    private func runGapScene(segmentCollisionOn: Bool, frames: Int = 150) throws -> SIMD3<Float> {
        let scene = try makeGapScene()
        let system = try SpringBoneComputeSystem(device: device)
        system.segmentCollisionEnabledForTesting = segmentCollisionOn
        try system.populateSpringBoneData(model: scene.model)
        try SpringBoneTestFixtures.runFrames(frames, system: system, model: scene.model,
                                             commandQueue: commandQueue)
        return SpringBoneTestFixtures.readBonePosition(model: scene.model, boneIndex: 2)
    }

    /// Flag ON: the child must be deflected clear of the sphere by settling.
    func testGapCase1_flagOn_childDeflects() throws {
        let scene = try makeGapScene()
        let childFinal = try runGapScene(segmentCollisionOn: true)
        let dist = simd_distance(childFinal, scene.sphereCenter)
        let required = scene.sphereRadius + scene.jointRadius

        XCTAssertGreaterThanOrEqual(dist, required - 1e-3,
            "flag ON: segment collision must deflect the child clear of the sphere " +
            "(distance \(dist) must be >= sphereRadius(\(scene.sphereRadius)) + " +
            "jointRadius(\(scene.jointRadius)) - 1e-3 = \(required - 1e-3)). " +
            "Final child position=\(childFinal), sphere center=\(scene.sphereCenter).")
    }

    /// Flag OFF IS THE SABOTAGE: with no segment collision (and the sphere's
    /// `responseScale = 0` ghosting the untouched per-joint kernel), nothing
    /// resists the child's swing — it passes straight through the sphere and
    /// settles inside it.
    func testGapCase1_flagOff_childPassesThrough() throws {
        let scene = try makeGapScene()
        let childFinal = try runGapScene(segmentCollisionOn: false)
        let dist = simd_distance(childFinal, scene.sphereCenter)

        XCTAssertLessThan(dist, scene.sphereRadius,
            "flag OFF (sabotage): with no segment collision and a ghosted per-joint " +
            "response, nothing stops the child's swing — it must settle INSIDE the " +
            "sphere (distance \(dist) must be < sphereRadius \(scene.sphereRadius)). " +
            "Final child position=\(childFinal), sphere center=\(scene.sphereCenter). " +
            "If this fails, the child is somehow still being deflected with the flag off.")
    }

    // MARK: - Case 2: at-joint (collider centered on the child)

    /// The sphere overlaps the CHILD — "centered on a joint" read as the
    /// endpoint the untouched per-joint kernel (`springBoneCollideSpheres`)
    /// already resolves directly, exactly like
    /// `SpringBoneCollisionBehaviorTests.testJointStartingInsideSphereIsPushedToSurface`
    /// (same 0.1-penetration / 0.2-radius geometry, extended to a third,
    /// far-and-clear parent node). With the parent far away, the segment's
    /// closest point to the sphere sits near the CHILD end (barycentric
    /// t≈1) — the LOW-overshoot-risk end of the t-scaled correction (t≈1
    /// recovers the same magnitude as an un-scaled push, spec §4) — so this
    /// case is a regression guard that adding segment collision does not
    /// perturb an essentially-already-endpoint contact, rather than a
    /// stress test of the scaling itself (that risk lives in the segment
    /// kernel's own small-t algebra, exercised directly by
    /// `closestPtSegmentPoint`'s unit derivation, not by a settled multi-body
    /// scene — an unopposed small-t scene here produced unbounded-feeling
    /// drift with no restoring force to bound it against, which is a
    /// property of the fixture, not of the correction).
    private func makeAtJointScene() throws -> (model: VRMModel, sphereCenter: SIMD3<Float>,
                                                sphereRadius: Float, childHitRadius: Float) {
        let sphereCenter = SIMD3<Float>(0.1, 0, 0)
        let sphereRadius: Float = 0.2
        let childHitRadius: Float = 0.0

        let rootWorld = SIMD3<Float>(0, 5, 0)
        let parentWorld = SIMD3<Float>(0, 3, 0)      // far from the sphere, unaffected
        let childWorld = SIMD3<Float>(0, 0, 0)       // 0.1 m inside the sphere

        let model = try makeThreeNodeChain(
            rootWorld: rootWorld,
            parentLocalOffset: parentWorld - rootWorld,
            childLocalOffset: childWorld - parentWorld,
            parentHitRadius: 0.0,
            childHitRadius: childHitRadius,
            parentGravityPower: 0.0,
            childGravityPower: 0.0,
            parentDrag: 0.6,
            childDrag: 0.9   // high drag → quick settling, matching the proven pattern
        )

        let sphere = SphereCollider(center: sphereCenter, radius: sphereRadius, groupMask: 0xFFFFFFFF)
        // responseScale left at the default 1.0: the per-joint kernel must be
        // FULLY active here (this case exercises the interaction between the
        // untouched endpoint kernel and the new segment kernel, not a ghosted
        // baseline).
        guard let buffers = model.springBoneBuffers else {
            throw XCTSkip("buffers missing")
        }
        writeSphere(buffers: buffers, sphere: sphere)

        XCTAssertLessThan(simd_distance(childWorld, sphereCenter), sphereRadius,
            "fixture bug: child must start INSIDE the sphere")
        XCTAssertGreaterThan(simd_distance(parentWorld, sphereCenter), sphereRadius,
            "fixture bug: parent must start clear of the sphere")

        return (model, sphereCenter, sphereRadius, childHitRadius)
    }

    /// Runs the at-joint scene, recording the child's position every frame
    /// (flag-on) for the settling-oscillation check.
    private func runAtJointScene(segmentCollisionOn: Bool, frames: Int) throws -> [SIMD3<Float>] {
        let scene = try makeAtJointScene()
        let system = try SpringBoneComputeSystem(device: device)
        system.segmentCollisionEnabledForTesting = segmentCollisionOn
        try system.populateSpringBoneData(model: scene.model)

        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(frames)
        for _ in 0..<frames {
            try SpringBoneTestFixtures.runFrame(system: system, model: scene.model,
                                                commandQueue: commandQueue)
            positions.append(SpringBoneTestFixtures.readBonePosition(model: scene.model, boneIndex: 2))
        }
        return positions
    }

    func testAtJointCase2_flagOnMatchesFlagOffWithinDerivedTolerance() throws {
        let frames = 90
        let scene = try makeAtJointScene()

        let offPositions = try runAtJointScene(segmentCollisionOn: false, frames: frames)
        let onPositions = try runAtJointScene(segmentCollisionOn: true, frames: frames)

        let childOff = offPositions[frames - 1]
        let childOn = onPositions[frames - 1]

        // flagOffDepth: how deep the CHILD itself rests inside the collider's
        // inflated surface in the flag-off baseline. Clamped to 0 when the
        // child never actually touches the sphere (its resting distance is
        // already >= the inflated radius) — a negative "depth" is not
        // physically meaningful, and the tolerance floor (2 mm) then governs.
        let requiredChild = scene.sphereRadius + scene.childHitRadius
        let childOffDist = simd_distance(childOff, scene.sphereCenter)
        let flagOffDepth = max(0, requiredChild - childOffDist)
        let tolerance = max(0.002, 0.25 * flagOffDepth)

        let delta = simd_distance(childOn, childOff)
        XCTAssertLessThanOrEqual(delta, tolerance,
            "Case 2 (collider at the child joint): flag-on's child position must " +
            "match flag-off within a tolerance derived from the flag-off contact " +
            "depth: tolerance = max(0.002, 0.25 * flagOffDepth) = " +
            "max(0.002, 0.25 * \(flagOffDepth)) = \(tolerance). Got delta=\(delta) " +
            "(flagOn=\(childOn), flagOff=\(childOff)). A large delta here means the " +
            "segment correction is not agreeing with the already-correct untouched " +
            "per-joint kernel for an essentially-endpoint contact (barycentric t≈1, " +
            "spec §4's t-scaled correction should recover ~the same magnitude as an " +
            "un-scaled push there) — already shipped in " +
            "`SpringBoneSegmentCollision.metal`; if this still fails, re-check the " +
            "scaling.")

        // Settling: the flag-on trajectory must not show GROWING oscillation.
        // max frame-to-frame delta over the last 30 frames must not exceed
        // 2x the same quantity over frames 30-60 (0-indexed [30,60)).
        func maxStep(_ window: ArraySlice<SIMD3<Float>>) -> Float {
            var maxD: Float = 0
            var prev: SIMD3<Float>? = nil
            for p in window {
                if let prev { maxD = max(maxD, simd_distance(p, prev)) }
                prev = p
            }
            return maxD
        }
        let earlyWindow = onPositions[30..<60]
        let lateWindow = onPositions[(frames - 30)..<frames]
        let earlyMaxStep = maxStep(earlyWindow)
        let lateMaxStep = maxStep(lateWindow)

        XCTAssertLessThanOrEqual(lateMaxStep, 2 * earlyMaxStep + 1e-6,
            "Case 2 settling: the last-30-frames max frame-to-frame step " +
            "(\(lateMaxStep)) must not exceed 2x the frames[30,60) max step " +
            "(\(earlyMaxStep)) — a growing step size would indicate the segment " +
            "correction is not damping out (unstable oscillation).")
    }

    // MARK: - §6.5 determinism (gap scene, flag-on, two identical runs)

    func testGapScene_flagOn_isBitDeterministicAcrossRuns() throws {
        let a = try runGapScene(segmentCollisionOn: true, frames: 60)
        let b = try runGapScene(segmentCollisionOn: true, frames: 60)

        XCTAssertEqual(a.x.bitPattern, b.x.bitPattern,
            "Determinism (spec §6.5): two identical flag-on runs of the gap scene " +
            "must agree bit-for-bit on the child's final position (x). Got a=\(a), b=\(b).")
        XCTAssertEqual(a.y.bitPattern, b.y.bitPattern,
            "Determinism (spec §6.5): two identical flag-on runs of the gap scene " +
            "must agree bit-for-bit on the child's final position (y). Got a=\(a), b=\(b).")
        XCTAssertEqual(a.z.bitPattern, b.z.bitPattern,
            "Determinism (spec §6.5): two identical flag-on runs of the gap scene " +
            "must agree bit-for-bit on the child's final position (z). Got a=\(a), b=\(b).")
    }
}
