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

/// Spec §6.2 — the sphere-at-joint blind spot made into a fixture, plus the
/// anchor-span coverage gap and the small-t interior contact the fix-round
/// review named.
///
/// Case 1 (gap): a collider sits inside the disk swept by a pendulum-like
/// span, at a SMALLER radius from the (fixed) parent than the span's own
/// length — this keeps BOTH joints provably clear (triangle inequality on a
/// hard-length constraint, verified every frame in the flag-off run), while
/// the swept SEGMENT still passes through it. Flag-on arrests the swing near
/// the collider (deflects); flag-off swings straight through to its natural
/// rest (passes through) — flag-off IS the sabotage.
///
/// Responsiveness to `responseScale`: a dedicated test reuses the collider
/// EXACTLY at the span's natural rest point (the construction that used to
/// rely on a ghosted `responseScale = 0` to isolate the segment kernel) to
/// confirm the segment kernels honor `responseScale` the same way the
/// untouched endpoint kernels do (a ghosted collider must push nothing).
///
/// Anchor-span coverage: the first simulated joint's parent is the kinematic
/// root — it never moves and has no span of its own — so a contact near that
/// end must get the FULL correction, not the interior t/s-scaled one (or it
/// is left permanently uncorrected). A 2-bone chain with the collider placed
/// exactly on-axis with the root (t = 0 exactly) asserts this.
///
/// Interior small-t: a 4-bone chain (root/A/B/C, span under test B→C, B's own
/// parent A is a real joint, not the anchor) with the collider near the B end
/// (t ≈ 0.15) asserts a real but bounded, settling deflection — the
/// configuration the review named as untested.
///
/// Case 2 (at-joint): the collider centered on the child (barycentric t≈1,
/// the low-overshoot end) — a regression guard that segment collision
/// doesn't perturb an essentially-already-endpoint contact.
///
/// §6.5 determinism: a small-scene sanity check plus a 257-bone scene built
/// specifically so the tested parent/child pair straddle a threadgroup
/// boundary (width 256) for the live-read sabotage to have a chance to fail.
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

    // MARK: - Fixture: N-joint chain (root anchor + N physics joints)

    private struct JointSpec {
        let localOffset: SIMD3<Float>
        let hitRadius: Float
        let gravityPower: Float
        let drag: Float
        let stiffness: Float
    }

    /// Builds `root -> joint0 -> joint1 -> ...`, all physics-driven except
    /// `root` (bone 0, kinematic/animated — stays fixed since nothing
    /// animates it). Colliders are NOT authored on `model.springBone` — the
    /// caller writes the sphere directly into `buffers.sphereColliders`
    /// afterward (via `writeSphere`) so tests can control `responseScale`,
    /// which the `VRMCollider` authoring path never sets (it always defaults
    /// to 1.0). Bone index `i+1` corresponds to `joints[i]`.
    private func makeChain(rootWorld: SIMD3<Float>, joints: [JointSpec],
                           numSpheres: Int = 1) throws -> VRMModel {
        var names = ["root"]
        var translations = [rootWorld]
        for (i, spec) in joints.enumerated() {
            names.append("joint\(i)")
            translations.append(spec.localOffset)
        }
        let model = try SpringBoneTestFixtures.makeChainModel(
            device: device, names: names, translations: translations)

        var rootJoint = SpringBoneTestFixtures.defaultJoint(node: 0)
        rootJoint.stiffness = 0.0
        rootJoint.gravityPower = 0.0
        var springJoints: [VRMSpringJoint] = [rootJoint]
        for (i, spec) in joints.enumerated() {
            var j = SpringBoneTestFixtures.defaultJoint(node: i + 1)
            j.stiffness = spec.stiffness
            j.gravityPower = spec.gravityPower
            j.dragForce = spec.drag
            j.hitRadius = spec.hitRadius
            springJoints.append(j)
        }

        var spring = VRMSpring(name: "ChainTestSpring")
        spring.joints = springJoints

        var sb = VRMSpringBone()
        sb.springs = [spring]
        model.springBone = sb

        let numBones = joints.count + 1
        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: numBones, numSpheres: numSpheres, numCapsules: 0)
        model.springBoneBuffers = buffers
        model.springBoneGlobalParams = SpringBoneTestFixtures.defaultGlobalParams(
            numBones: numBones, numSpheres: numSpheres
        )
        return model
    }

    /// Writes a single sphere collider directly into `buffers.sphereColliders`
    /// at `index`, bypassing the `VRMCollider` authoring path so
    /// `responseScale` (never settable from authored colliders —
    /// `populateSpringBoneData` always constructs `SphereCollider` with the
    /// 1.0 default) can be controlled.
    private func writeSphere(buffers: SpringBoneBuffers, sphere: SphereCollider, index: Int = 0) {
        guard let buf = buffers.sphereColliders else {
            return XCTFail("sphereColliders buffer not allocated")
        }
        let ptr = buf.contents().bindMemory(to: SphereCollider.self, capacity: index + 1)
        ptr[index] = sphere
    }

    // MARK: - Case 1: gap (sphere inside the swept disk, clear of both joints)

    /// Parent hangs fixed 1 m below root; child starts 60° off vertical and
    /// swings down under gravity + drag toward hanging directly below parent
    /// (its natural, unobstructed rest). The sphere sits at radius
    /// `sphereOrbitRadius` (0.5 m) from the FIXED parent, at 30° — INSIDE the
    /// disk the child's constrained 1 m arc sweeps through, but off the arc
    /// itself. Since the child is always EXACTLY 1 m from parent (hard
    /// distance constraint) and the sphere is always exactly 0.5 m from
    /// parent, the triangle inequality gives
    /// `distance(child, sphere) >= |1 - 0.5| = 0.5` for every possible child
    /// position — provably, not just at the start — while the SEGMENT
    /// (which sweeps the full parent-to-child line at every angle) passes
    /// exactly through the sphere's center when the child's swing angle
    /// crosses 30°. Neither endpoint kernel can ever see this collider;
    /// only the segment kernel can.
    private struct GapScene {
        let model: VRMModel
        let sphereCenter: SIMD3<Float>
        let sphereRadius: Float
        let jointRadius: Float
        let parentWorld: SIMD3<Float>
        let minDistEndpoint: Float
    }

    private func makeGapScene() throws -> GapScene {
        let rootWorld = SIMD3<Float>(0, 3, 0)
        let parentWorld = SIMD3<Float>(0, 2, 0)                    // 1 m below root
        let startAngle: Float = .pi / 3                            // 60° from vertical
        let childOffset = SIMD3<Float>(sin(startAngle), -cos(startAngle), 0)  // unit, 1 m from parent

        let jointRadius: Float = 0.02
        let sphereRadius: Float = 0.15
        let sphereOrbitAngle: Float = .pi / 6                      // 30° from vertical
        let sphereOrbitRadius: Float = 0.5                         // strictly inside the child's 1 m arc
        let sphereCenter = parentWorld +
            sphereOrbitRadius * SIMD3<Float>(sin(sphereOrbitAngle), -cos(sphereOrbitAngle), 0)

        let model = try makeChain(rootWorld: rootWorld, joints: [
            JointSpec(localOffset: parentWorld - rootWorld, hitRadius: jointRadius,
                     gravityPower: 0.0, drag: 0.5, stiffness: 0.0),
            JointSpec(localOffset: childOffset, hitRadius: jointRadius,
                     gravityPower: 1.0, drag: 0.6, stiffness: 0.0)
        ])

        let sphere = SphereCollider(center: sphereCenter, radius: sphereRadius, groupMask: 0xFFFFFFFF)
        guard let buffers = model.springBoneBuffers else { throw XCTSkip("buffers missing") }
        writeSphere(buffers: buffers, sphere: sphere)

        let minDistEndpoint = sphereRadius + jointRadius
        // Fixture-level sanity, provable in closed form (see doc comment):
        // orbit radius (0.5) vs span length (1.0) gives a guaranteed 0.5 m
        // clearance for the child, way above minDistEndpoint.
        XCTAssertGreaterThan(sphereOrbitRadius, minDistEndpoint,
            "fixture bug: parent must be clear of the sphere (it never moves)")
        XCTAssertGreaterThan(abs(1.0 - sphereOrbitRadius), minDistEndpoint,
            "fixture bug: the triangle-inequality clearance bound for the child must exceed minDistEndpoint")

        return GapScene(model: model, sphereCenter: sphereCenter, sphereRadius: sphereRadius,
                        jointRadius: jointRadius, parentWorld: parentWorld, minDistEndpoint: minDistEndpoint)
    }

    /// Runs the gap scene, recording every frame's (parent, child) positions.
    private func runGapSceneTrajectory(segmentCollisionOn: Bool, frames: Int = 150)
        throws -> (scene: GapScene, parentTrajectory: [SIMD3<Float>], childTrajectory: [SIMD3<Float>]) {
        let scene = try makeGapScene()
        let system = try SpringBoneComputeSystem(device: device)
        system.segmentCollisionEnabledForTesting = segmentCollisionOn
        try system.populateSpringBoneData(model: scene.model)

        var parentTraj: [SIMD3<Float>] = []
        var childTraj: [SIMD3<Float>] = []
        for _ in 0..<frames {
            try SpringBoneTestFixtures.runFrame(system: system, model: scene.model, commandQueue: commandQueue)
            parentTraj.append(SpringBoneTestFixtures.readBonePosition(model: scene.model, boneIndex: 1))
            childTraj.append(SpringBoneTestFixtures.readBonePosition(model: scene.model, boneIndex: 2))
        }
        return (scene, parentTraj, childTraj)
    }

    /// Flag ON: the swing is arrested near the collider — the child ends up
    /// CLOSE to the sphere (not penetrating it), unlike flag-off which swings
    /// all the way past it to a distant, unobstructed rest.
    func testGapCase1_flagOn_childDeflects() throws {
        let (scene, _, childTraj) = try runGapSceneTrajectory(segmentCollisionOn: true)
        let childFinal = childTraj.last!
        let dist = simd_distance(childFinal, scene.sphereCenter)
        let required = scene.sphereRadius + scene.jointRadius

        XCTAssertGreaterThanOrEqual(dist, required - 1e-3,
            "flag ON: segment collision must not let the child penetrate the sphere " +
            "(distance \(dist) must be >= sphereRadius(\(scene.sphereRadius)) + " +
            "jointRadius(\(scene.jointRadius)) - 1e-3 = \(required - 1e-3)). " +
            "Final child position=\(childFinal), sphere center=\(scene.sphereCenter).")
        // Deflected means "measurably short of the flag-off swept-past
        // distance" (~0.62 m, see testGapCase1_flagOff_childPassesThrough) —
        // not a tight absolute bound: the interior t-scaling means the
        // arrest is partial, not a hard snap to the collider surface.
        XCTAssertLessThan(dist, 0.6,
            "flag ON: child should be resting measurably short of the flag-off " +
            "unobstructed distance (~0.62 m), not swept all the way past the collider. " +
            "distance=\(dist), childFinal=\(childFinal).")
    }

    /// Flag OFF IS THE SABOTAGE: with no segment collision, nothing resists
    /// the child's swing through the collider's location — it settles at its
    /// natural, unobstructed equilibrium, measurably farther from the sphere
    /// than the flag-on (arrested) case ever gets. Also verifies, PER FRAME,
    /// the geometric clearance claim the scene depends on: neither joint
    /// should ever come within the endpoint kernel's trigger distance of the
    /// sphere (if it did, the untouched per-joint kernel — always active,
    /// independent of this flag — would react, contaminating the isolation).
    func testGapCase1_flagOff_childPassesThrough() throws {
        let (scene, parentTraj, childTraj) = try runGapSceneTrajectory(segmentCollisionOn: false)

        for (i, p) in parentTraj.enumerated() {
            let d = simd_distance(p, scene.sphereCenter)
            XCTAssertGreaterThanOrEqual(d, scene.minDistEndpoint,
                "flag OFF geometry claim violated at frame \(i): parent came within " +
                "\(d) of the sphere (must stay >= minDistEndpoint \(scene.minDistEndpoint)). " +
                "The untouched per-joint kernel would have reacted, contaminating the isolation.")
        }
        for (i, c) in childTraj.enumerated() {
            let d = simd_distance(c, scene.sphereCenter)
            XCTAssertGreaterThanOrEqual(d, scene.minDistEndpoint,
                "flag OFF geometry claim violated at frame \(i): child came within " +
                "\(d) of the sphere (must stay >= minDistEndpoint \(scene.minDistEndpoint)). " +
                "The untouched per-joint kernel would have reacted, contaminating the isolation.")
        }

        let childFinal = childTraj.last!
        let distOff = simd_distance(childFinal, scene.sphereCenter)
        XCTAssertGreaterThan(distOff, 0.5,
            "flag OFF (sabotage): with no segment collision, nothing stops the child's " +
            "swing through the collider's location — it must reach its natural, " +
            "unobstructed rest, well clear of the sphere (distance \(distOff) should be " +
            "> 0.5 m, close to the theoretical unobstructed rest ~0.62 m). " +
            "Final child position=\(childFinal), sphere center=\(scene.sphereCenter).")
    }

    /// Direct comparison, mirroring the codebase's established
    /// "measurably different trajectory" idiom
    /// (`SpringBoneCollisionBehaviorTests.testMaskZeroProducesMeasurablyDifferentTrajectoryFromAllBits`):
    /// flag-on (arrested near the collider) must end up markedly CLOSER to
    /// the sphere than flag-off (swept past it) — the two single-run tests
    /// above are the primary gates; this ties them together in one assertion
    /// that doesn't depend on the exact absolute numbers.
    func testGapCase1_flagOnIsMeasurablyClearerOfPathThanFlagOff() throws {
        let (scene, _, childOnTraj) = try runGapSceneTrajectory(segmentCollisionOn: true)
        let (_, _, childOffTraj) = try runGapSceneTrajectory(segmentCollisionOn: false)
        let distOn = simd_distance(childOnTraj.last!, scene.sphereCenter)
        let distOff = simd_distance(childOffTraj.last!, scene.sphereCenter)

        XCTAssertLessThan(distOn, distOff - 0.05,
            "flag-on must rest measurably CLOSER to the collider (arrested) than flag-off " +
            "(swept past it): distOn=\(distOn), distOff=\(distOff).")
    }

    // MARK: - responseScale honored (the fix-round regression guard)

    /// Reuses the collider positioned EXACTLY at the child's natural
    /// vertical-equilibrium point (the construction the review flagged —
    /// case 1 used to ghost the endpoint kernel with `responseScale = 0` to
    /// isolate the segment kernel; here that same ghosting is the test
    /// subject in its own right). With `responseScale = 0`, the segment
    /// kernel must push NOTHING — same as the untouched endpoint kernel
    /// would. Regression guard for the fix-round CRITICAL finding: the
    /// segment kernels previously ignored `responseScale` entirely.
    func testGhostedResponseScaleAlsoGhostsSegmentCollision() throws {
        let rootWorld = SIMD3<Float>(0, 3, 0)
        let parentWorld = SIMD3<Float>(0, 2, 0)
        let startAngle: Float = .pi / 3
        let childOffset = SIMD3<Float>(sin(startAngle), -cos(startAngle), 0)
        let jointRadius: Float = 0.02

        let model = try makeChain(rootWorld: rootWorld, joints: [
            JointSpec(localOffset: parentWorld - rootWorld, hitRadius: jointRadius,
                     gravityPower: 0.0, drag: 0.5, stiffness: 0.0),
            JointSpec(localOffset: childOffset, hitRadius: jointRadius,
                     gravityPower: 1.0, drag: 0.6, stiffness: 0.0)
        ])

        let sphereCenter = parentWorld + SIMD3<Float>(0, -1, 0)  // child's own vertical equilibrium
        var sphere = SphereCollider(center: sphereCenter, radius: 0.15, groupMask: 0xFFFFFFFF)
        sphere.responseScale = 0
        guard let buffers = model.springBoneBuffers else { throw XCTSkip("buffers missing") }
        writeSphere(buffers: buffers, sphere: sphere)

        let system = try SpringBoneComputeSystem(device: device)
        system.segmentCollisionEnabledForTesting = true
        try system.populateSpringBoneData(model: model)
        try SpringBoneTestFixtures.runFrames(150, system: system, model: model, commandQueue: commandQueue)

        let childFinal = SpringBoneTestFixtures.readBonePosition(model: model, boneIndex: 2)
        let dist = simd_distance(childFinal, sphereCenter)
        XCTAssertLessThan(dist, 0.15,
            "responseScale = 0 must ghost the segment kernel exactly like the untouched " +
            "endpoint kernel — with flag ON but a ghosted collider, nothing should resist " +
            "the child's swing to its natural rest AT the sphere's center (distance \(dist) " +
            "should be well under sphereRadius 0.15). If this fails, the segment kernels are " +
            "ignoring `responseScale`.")
    }

    // MARK: - Anchor-span coverage (first simulated joint; t = 0 exactly)

    /// A 2-bone chain: `root` (kinematic anchor, fixed) -> `child` (physics,
    /// hangs straight down, zero gravity/stiffness so nothing but collision
    /// can move it). The collider sits exactly on-axis with ROOT, offset
    /// purely horizontally — the segment's closest point to it is root
    /// itself, giving barycentric `t = 0` EXACTLY. Root can never move
    /// (kinematic) and has no span of its own (its OWN parent index is the
    /// sentinel), so without the anchor override this contact would be
    /// scaled to ≈0 and left permanently uncorrected — the "Hitarea_Head"
    /// scalp-hair case the fix-round review named. With the fix, spans whose
    /// parent is the kinematic anchor get the FULL push regardless of t.
    func testAnchorSpan_colliderAtRootEnd_childDeflects() throws {
        let rootWorld = SIMD3<Float>(0, 2, 0)
        let childWorld = rootWorld + SIMD3<Float>(0, -1, 0)
        let jointRadius: Float = 0.02
        let sphereRadius: Float = 0.2
        let sphereCenter = rootWorld + SIMD3<Float>(0.15, 0, 0)  // purely horizontal offset from root

        // t = 0 sanity: the closest point on the vertical root->child segment
        // to a purely-horizontal-from-root point is root itself.
        let minDistEndpoint = sphereRadius + jointRadius
        XCTAssertGreaterThan(simd_distance(childWorld, sphereCenter), minDistEndpoint,
            "fixture bug: child must start clear of the sphere (root can never move, so " +
            "if child weren't clear the untouched per-joint kernel would react)")

        func run(segmentCollisionOn: Bool) throws -> SIMD3<Float> {
            let model = try makeChain(rootWorld: rootWorld, joints: [
                JointSpec(localOffset: childWorld - rootWorld, hitRadius: jointRadius,
                         gravityPower: 0.0, drag: 0.5, stiffness: 0.0)
            ])
            let sphere = SphereCollider(center: sphereCenter, radius: sphereRadius, groupMask: 0xFFFFFFFF)
            guard let buffers = model.springBoneBuffers else { throw XCTSkip("buffers missing") }
            writeSphere(buffers: buffers, sphere: sphere)

            let system = try SpringBoneComputeSystem(device: device)
            system.segmentCollisionEnabledForTesting = segmentCollisionOn
            try system.populateSpringBoneData(model: model)
            try SpringBoneTestFixtures.runFrames(90, system: system, model: model, commandQueue: commandQueue)
            return SpringBoneTestFixtures.readBonePosition(model: model, boneIndex: 1)
        }

        let childOff = try run(segmentCollisionOn: false)
        let childOn = try run(segmentCollisionOn: true)

        // Flag off: nothing acts on the child at all (zero gravity/stiffness,
        // and the collider is far enough from the child's own endpoint that
        // the untouched per-joint kernel never engages) — it must stay put.
        XCTAssertLessThan(simd_distance(childOff, childWorld), 1e-4,
            "flag OFF sanity: with no force anywhere, the child must stay at its bind " +
            "position. Got \(childOff), expected \(childWorld).")

        // Flag on: the anchor-span override must give the child a real,
        // measurable deflection (away from the sphere, -x direction) — not
        // the near-zero nudge the plain t≈0 interior scaling would give.
        let delta = simd_distance(childOn, childOff)
        XCTAssertGreaterThan(delta, 0.03,
            "flag ON: the anchor-span override must give the child a FULL correction " +
            "even though barycentric t=0 (contact exactly at the root end) — a plain " +
            "t-scaled correction here would be ≈0 and leave this permanently " +
            "uncorrected (the coverage gap the fix-round review named). " +
            "childOn=\(childOn), childOff=\(childOff), delta=\(delta).")
        XCTAssertLessThan(childOn.x, childOff.x - 0.02,
            "flag ON: the child must move in -x (away from the sphere at +x). " +
            "childOn=\(childOn), childOff=\(childOff).")
    }

    // MARK: - Interior small-t contact (three-joint chain minimum)

    /// A 4-bone chain: `root -> A -> B -> C`. `A` and `B` are held fixed
    /// (zero gravity/stiffness, already at their rest positions); `C` swings
    /// under gravity like the gap scene's child. The span under test is
    /// `B -> C` (thread `id = C`, `parent = B`); `B`'s OWN parent is `A` — a
    /// real joint, NOT the kinematic anchor — so this is a genuinely
    /// INTERIOR span and must use the t-scaled correction, not the
    /// anchor-span override. The collider sits at radius 0.15 from B (span
    /// length 1.0), close enough to B that `t = orbitRadius * cos(angle
    /// difference) ≈ 0.11-0.15` for EVERY angle across C's whole 60°->0°
    /// swing (not just a momentary alignment) — the small-but-nonzero range
    /// the fix-round review found untested. Because the (small, t-scaled)
    /// correction is active from the very first substep and opposes
    /// gravity's initial pull, it pins the pendulum close to its START
    /// angle almost immediately — a REAL, measurable deflection relative to
    /// the flag-off free swing, but a BOUNDED one: the trajectory converges
    /// to a fixed point and stays there (verified below), it does not grow
    /// or oscillate. "Bounded" here means "settles cleanly", not "small in
    /// absolute distance" — a persistent (not momentary) small-t contact
    /// legitimately arrests the swing early.
    func testInteriorSmallT_colliderNearParentEnd_boundedDeflection() throws {
        let rootWorld = SIMD3<Float>(0, 4, 0)
        let aWorld = SIMD3<Float>(0, 3, 0)                 // 1 m below root, fixed
        let bWorld = SIMD3<Float>(0, 2, 0)                 // 1 m below A, fixed
        let startAngle: Float = .pi / 3                    // 60° from vertical
        let cOffset = SIMD3<Float>(sin(startAngle), -cos(startAngle), 0)  // unit, 1 m from B

        let jointRadius: Float = 0.02
        let sphereRadius: Float = 0.05
        let orbitAngle: Float = .pi / 4                    // 45°, inside C's 60°->0° swing
        let orbitRadius: Float = 0.15                       // -> t ≈ 0.15 at alignment
        let sphereCenter = bWorld + orbitRadius * SIMD3<Float>(sin(orbitAngle), -cos(orbitAngle), 0)

        func run(segmentCollisionOn: Bool) throws -> [SIMD3<Float>] {
            let model = try makeChain(rootWorld: rootWorld, joints: [
                JointSpec(localOffset: aWorld - rootWorld, hitRadius: jointRadius,
                         gravityPower: 0.0, drag: 0.5, stiffness: 0.0),
                JointSpec(localOffset: bWorld - aWorld, hitRadius: jointRadius,
                         gravityPower: 0.0, drag: 0.5, stiffness: 0.0),
                JointSpec(localOffset: cOffset, hitRadius: jointRadius,
                         gravityPower: 1.0, drag: 0.6, stiffness: 0.0)
            ])
            let sphere = SphereCollider(center: sphereCenter, radius: sphereRadius, groupMask: 0xFFFFFFFF)
            guard let buffers = model.springBoneBuffers else { throw XCTSkip("buffers missing") }
            writeSphere(buffers: buffers, sphere: sphere)

            let system = try SpringBoneComputeSystem(device: device)
            system.segmentCollisionEnabledForTesting = segmentCollisionOn
            try system.populateSpringBoneData(model: model)
            var traj: [SIMD3<Float>] = []
            for _ in 0..<90 {
                try SpringBoneTestFixtures.runFrame(system: system, model: model, commandQueue: commandQueue)
                traj.append(SpringBoneTestFixtures.readBonePosition(model: model, boneIndex: 3))
            }
            return traj
        }

        // Fixture sanity: B and (by the same triangle-inequality argument as
        // the gap scene) C stay clear of the sphere's endpoint-trigger radius.
        let minDistEndpoint = sphereRadius + jointRadius
        XCTAssertGreaterThan(orbitRadius, minDistEndpoint, "fixture bug: B must be clear of the sphere")
        XCTAssertGreaterThan(abs(1.0 - orbitRadius), minDistEndpoint,
            "fixture bug: triangle-inequality clearance bound for C must exceed minDistEndpoint")

        let offTraj = try run(segmentCollisionOn: false)
        let onTraj = try run(segmentCollisionOn: true)

        let delta = simd_distance(onTraj.last!, offTraj.last!)
        XCTAssertGreaterThan(delta, 0.002,
            "interior small-t contact must produce a REAL, measurable deflection " +
            "(delta=\(delta)) — t≈0.1-0.15 must not be scaled all the way to zero.")
        XCTAssertLessThan(delta, 1.9,
            "interior small-t contact's deflection must stay within the physically " +
            "possible range for a 1 m span (max separation 2 m) — delta=\(delta) would " +
            "suggest an exploded/NaN trajectory, not a legitimate early-arrest deflection.")

        // Settling: no growing oscillation in the flag-on trajectory.
        func maxStep(_ window: ArraySlice<SIMD3<Float>>) -> Float {
            var maxD: Float = 0
            var prev: SIMD3<Float>? = nil
            for p in window {
                if let prev { maxD = max(maxD, simd_distance(p, prev)) }
                prev = p
            }
            return maxD
        }
        let earlyMaxStep = maxStep(onTraj[30..<60])
        let lateMaxStep = maxStep(onTraj[60..<90])
        XCTAssertLessThanOrEqual(lateMaxStep, 2 * earlyMaxStep + 1e-6,
            "interior small-t settling: last-30-frames max step (\(lateMaxStep)) must not " +
            "exceed 2x the frames[30,60) max step (\(earlyMaxStep)) — growing step size " +
            "would indicate the correction is not damping out.")
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
    /// perturb an essentially-already-endpoint contact. (This span's parent,
    /// bone 1, has a real parentIndex of 0 — NOT the anchor sentinel — so it
    /// correctly takes the interior t-scaled path, not the anchor override.)
    private func makeAtJointScene() throws -> (model: VRMModel, sphereCenter: SIMD3<Float>,
                                                sphereRadius: Float, childHitRadius: Float) {
        let sphereCenter = SIMD3<Float>(0.1, 0, 0)
        let sphereRadius: Float = 0.2
        let childHitRadius: Float = 0.0

        let rootWorld = SIMD3<Float>(0, 5, 0)
        let parentWorld = SIMD3<Float>(0, 3, 0)      // far from the sphere, unaffected
        let childWorld = SIMD3<Float>(0, 0, 0)       // 0.1 m inside the sphere

        let model = try makeChain(rootWorld: rootWorld, joints: [
            JointSpec(localOffset: parentWorld - rootWorld, hitRadius: 0.0,
                     gravityPower: 0.0, drag: 0.6, stiffness: 0.0),
            JointSpec(localOffset: childWorld - parentWorld, hitRadius: childHitRadius,
                     gravityPower: 0.0, drag: 0.9, stiffness: 0.0)   // high drag -> quick settling
        ])

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

    // MARK: - §6.5 determinism (small scene, flag-on, two identical runs)

    func testGapScene_flagOn_isBitDeterministicAcrossRuns() throws {
        let (_, _, childA) = try runGapSceneTrajectory(segmentCollisionOn: true, frames: 60)
        let (_, _, childB) = try runGapSceneTrajectory(segmentCollisionOn: true, frames: 60)
        let a = childA.last!
        let b = childB.last!

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

    // MARK: - §6.5 determinism, threadgroup-crossing scene (live-read sabotage target)

    /// A 3-bone scene has all its bones in ONE 256-wide threadgroup —
    /// lockstep SIMD execution means a live cross-thread read of
    /// `bonePosCurr[parent]` cannot actually observe a torn/stale value: the
    /// sabotage is structurally unable to fail there. This scene instead
    /// pads 127 independent, inert 2-bone "filler" springs (254 bones, far
    /// from any collider, zero forces) BEFORE the real 3-bone gap-scene
    /// spring, landing PARENT at bone index 255 (the last thread of
    /// threadgroup 0) and CHILD at bone index 256 (the first thread of
    /// threadgroup 1) — `executeXPBDStep` dispatches with
    /// `threadsPerThreadgroup = 256` (`SpringBoneComputeSystem.swift`), so
    /// this is a provable cross-threadgroup pair, not a guess. Total bone
    /// count 257 (> 256, so the dispatch actually spans two threadgroups).
    private func makeThreadgroupCrossingGapScene() throws -> (model: VRMModel,
                                                               sphereCenter: SIMD3<Float>,
                                                               sphereRadius: Float,
                                                               parentBoneIndex: Int,
                                                               childBoneIndex: Int) {
        let fillerSpringCount = 127   // 254 filler bones
        var names: [String] = []
        var translations: [SIMD3<Float>] = []
        var cursor = SIMD3<Float>(1000, 0, 0)

        names.append("f0root"); translations.append(cursor)
        for i in 0..<fillerSpringCount {
            if i > 0 {
                names.append("f\(i)root"); translations.append(SIMD3<Float>(0, -0.01, 0))
                cursor += SIMD3<Float>(0, -0.01, 0)
            }
            names.append("f\(i)child"); translations.append(SIMD3<Float>(0, -0.01, 0))
            cursor += SIMD3<Float>(0, -0.01, 0)
        }
        // 254 filler nodes now placed (indices 0..253). Append the real
        // 3-bone gap scene, translating back from wherever the filler chain
        // ended up so its WORLD positions match makeGapScene()'s geometry
        // exactly (translations are local/relative in this single linear
        // node chain).
        let realRootWorld = SIMD3<Float>(0, 3, 0)
        names.append("realRoot"); translations.append(realRootWorld - cursor)
        cursor = realRootWorld

        let realParentWorld = SIMD3<Float>(0, 2, 0)
        names.append("realParent"); translations.append(realParentWorld - cursor)
        cursor = realParentWorld

        let startAngle: Float = .pi / 3
        let childOffset = SIMD3<Float>(sin(startAngle), -cos(startAngle), 0)
        names.append("realChild"); translations.append(childOffset)

        let totalBones = names.count
        precondition(totalBones == fillerSpringCount * 2 + 3, "bone count bookkeeping bug")

        let model = try SpringBoneTestFixtures.makeChainModel(
            device: device, names: names, translations: translations)

        var springs: [VRMSpring] = []
        for i in 0..<fillerSpringCount {
            var fillerRoot = SpringBoneTestFixtures.defaultJoint(node: 2 * i)
            fillerRoot.stiffness = 0.0; fillerRoot.gravityPower = 0.0
            var fillerChild = SpringBoneTestFixtures.defaultJoint(node: 2 * i + 1)
            fillerChild.stiffness = 0.0; fillerChild.gravityPower = 0.0; fillerChild.hitRadius = 0.001
            var s = VRMSpring(name: "filler\(i)")
            s.joints = [fillerRoot, fillerChild]
            springs.append(s)
        }

        let realRootNode = fillerSpringCount * 2
        let jointRadius: Float = 0.02
        var realRoot = SpringBoneTestFixtures.defaultJoint(node: realRootNode)
        realRoot.stiffness = 0.0; realRoot.gravityPower = 0.0
        var realParent = SpringBoneTestFixtures.defaultJoint(node: realRootNode + 1)
        realParent.stiffness = 0.0; realParent.gravityPower = 0.0
        realParent.dragForce = 0.5; realParent.hitRadius = jointRadius
        var realChild = SpringBoneTestFixtures.defaultJoint(node: realRootNode + 2)
        realChild.stiffness = 0.0; realChild.gravityPower = 1.0
        realChild.dragForce = 0.6; realChild.hitRadius = jointRadius
        var realSpring = VRMSpring(name: "realGapSpring")
        realSpring.joints = [realRoot, realParent, realChild]
        springs.append(realSpring)

        var sb = VRMSpringBone()
        sb.springs = springs
        model.springBone = sb

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: totalBones, numSpheres: 1, numCapsules: 0)
        model.springBoneBuffers = buffers
        model.springBoneGlobalParams = SpringBoneTestFixtures.defaultGlobalParams(
            numBones: totalBones, numSpheres: 1
        )

        // Same disk-trick sphere as makeGapScene(), same reasoning: clear of
        // both real joints, overlapping only the swept segment.
        let sphereRadius: Float = 0.15
        let orbitAngle: Float = .pi / 6
        let orbitRadius: Float = 0.5
        let sphereCenter = realParentWorld + orbitRadius * SIMD3<Float>(sin(orbitAngle), -cos(orbitAngle), 0)
        let sphere = SphereCollider(center: sphereCenter, radius: sphereRadius, groupMask: 0xFFFFFFFF)
        writeSphere(buffers: buffers, sphere: sphere)

        // bone index == node index here (every node feeds exactly one joint,
        // springs processed in declaration order) — parent = totalBones-2,
        // child = totalBones-1.
        let parentBoneIndex = totalBones - 2
        let childBoneIndex = totalBones - 1
        precondition(parentBoneIndex == 255 && childBoneIndex == 256,
                    "threadgroup-crossing bookkeeping bug: parent=\(parentBoneIndex) child=\(childBoneIndex)")

        return (model, sphereCenter, sphereRadius, parentBoneIndex, childBoneIndex)
    }

    /// The live-read sabotage target (Task 4/5): two identical flag-on runs
    /// of the threadgroup-crossing scene must agree bit-for-bit on the
    /// child's final position. Run normally, this passes — it is the vehicle
    /// the fix-round review's scratch-sabotage (`bonePosSnapshot[parent]` →
    /// `bonePosCurr[parent]`) is exercised against, by hand, outside CI.
    func testThreadgroupCrossingGapScene_flagOn_isBitDeterministicAcrossRuns() throws {
        func run() throws -> SIMD3<Float> {
            let scene = try makeThreadgroupCrossingGapScene()
            let system = try SpringBoneComputeSystem(device: device)
            system.segmentCollisionEnabledForTesting = true
            try system.populateSpringBoneData(model: scene.model)
            try SpringBoneTestFixtures.runFrames(60, system: system, model: scene.model,
                                                 commandQueue: commandQueue)
            return SpringBoneTestFixtures.readBonePosition(model: scene.model, boneIndex: scene.childBoneIndex)
        }

        let a = try run()
        let b = try run()

        XCTAssertEqual(a.x.bitPattern, b.x.bitPattern,
            "Determinism (spec §6.5, threadgroup-crossing scene): two identical flag-on " +
            "runs must agree bit-for-bit on the child's final position (x). Got a=\(a), b=\(b).")
        XCTAssertEqual(a.y.bitPattern, b.y.bitPattern,
            "Determinism (spec §6.5, threadgroup-crossing scene): two identical flag-on " +
            "runs must agree bit-for-bit on the child's final position (y). Got a=\(a), b=\(b).")
        XCTAssertEqual(a.z.bitPattern, b.z.bitPattern,
            "Determinism (spec §6.5, threadgroup-crossing scene): two identical flag-on " +
            "runs must agree bit-for-bit on the child's final position (z). Got a=\(a), b=\(b).")
    }
}
