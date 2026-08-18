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

final class BalanceModelTests: XCTestCase {

    // MARK: - Task 1: Center of mass

    func testMassFractionsSumToApproximatelyOne() {
        let total = BalanceModel.massFractions.values.reduce(0, +)
        XCTAssertEqual(total, 1.0, accuracy: 0.02, "segment fractions should sum to ~1.0")
    }

    func testCenterOfMassIsTheWeightedAverage() {
        // Two bones only; parent-folding applies, redistributing missing trunk and
        // limb masses to hips and head. CoM is the weighted average of effective fractions.
        let joints: [VRMHumanoidBone: SIMD3<Float>] = [
            .hips: SIMD3<Float>(0, 1, 0),
            .head: SIMD3<Float>(0, 2, 0),
        ]
        let com = try! XCTUnwrap(BalanceModel.centerOfMass(jointPositions: joints))
        let eff = BalanceModel.effectiveFractions(present: Set(joints.keys))
        let fH = eff[.hips] ?? 0
        let fHead = eff[.head] ?? 0
        let expectedY = (1 * fH + 2 * fHead) / (fH + fHead)
        XCTAssertEqual(com.y, expectedY, accuracy: 1e-5)
        XCTAssertEqual(com.x, 0, accuracy: 1e-6)
    }

    func testCenterOfMassNilWhenHipsMissingOrSingleBone() {
        XCTAssertNil(BalanceModel.centerOfMass(jointPositions: [.head: .zero]),
                     "no hips ⇒ nil")
        XCTAssertNil(BalanceModel.centerOfMass(jointPositions: [.hips: .zero]),
                     "hips-only (bare point) ⇒ nil")
        XCTAssertNil(BalanceModel.centerOfMass(jointPositions: [.hips: .zero, .leftEye: SIMD3<Float>(1, 0, 0)]),
                     "hips + a non-mass bone (leftEye not in massFractions) ⇒ nil, never a bare point")
    }

    /// Parent-fold (design §4.1): dropping a SPLIT trunk bone folds its mass into the
    /// nearest present ancestor in-region, so limb fractions and the trunk total are
    /// invariant to trunk subdivision. A global renormalize would instead inflate the
    /// limbs — this test pins the difference.
    func testEffectiveFractions_upperChestFoldsIntoChest_limbsUnchanged() {
        let all = Set(BalanceModel.massFractions.keys)
        let full = BalanceModel.effectiveFractions(present: all)
        let noUC = BalanceModel.effectiveFractions(present: all.subtracting([.upperChest]))

        // upperChest's mass moved onto chest…
        XCTAssertEqual(noUC[.chest] ?? 0,
                       (full[.chest] ?? 0) + (BalanceModel.massFractions[.upperChest] ?? 0),
                       accuracy: 1e-6)
        // …limbs are untouched (a global renormalize would raise these)…
        XCTAssertEqual(noUC[.leftUpperLeg] ?? 0, full[.leftUpperLeg] ?? 0, accuracy: 1e-6)
        XCTAssertEqual(noUC[.rightUpperArm] ?? 0, full[.rightUpperArm] ?? 0, accuracy: 1e-6)
        // …and the trunk keeps its total.
        let trunk: [VRMHumanoidBone] = [.hips, .spine, .chest, .upperChest]
        let fullTrunk = trunk.reduce(Float(0)) { $0 + (full[$1] ?? 0) }
        let noUCTrunk = trunk.reduce(Float(0)) { $0 + (noUC[$1] ?? 0) }
        XCTAssertEqual(noUCTrunk, fullTrunk, accuracy: 1e-6)
    }

    /// Same property at the CoM level: with all trunk bones coincident at the origin
    /// and limbs offset, subdividing the trunk cannot move the CoM under parent-fold
    /// (it would under a global renormalize, which rescales the limbs).
    func testCenterOfMass_invariantToTrunkSubdivision() {
        var withUC: [VRMHumanoidBone: SIMD3<Float>] = [
            .hips: .zero, .spine: .zero, .chest: .zero, .upperChest: .zero,
            .leftUpperLeg: SIMD3<Float>(1, 0, 0), .rightUpperLeg: SIMD3<Float>(1, 0, 0),
            .leftUpperArm: SIMD3<Float>(1, 0, 0), .rightUpperArm: SIMD3<Float>(1, 0, 0),
            .head: .zero,
        ]
        let comWith = try! XCTUnwrap(BalanceModel.centerOfMass(jointPositions: withUC))
        withUC.removeValue(forKey: .upperChest)
        let comWithout = try! XCTUnwrap(BalanceModel.centerOfMass(jointPositions: withUC))
        XCTAssertEqual(simd_distance(comWith, comWithout), 0, accuracy: 1e-6,
                       "trunk subdivision must not move the CoM (parent-fold)")
    }

    // MARK: - Task 2: Support polygon (convex hull)

    func testSupportPolygon_hullOfASquareIsThatSquare() {
        let square: [SIMD2<Float>] = [
            SIMD2<Float>(0, 0), SIMD2<Float>(1, 0),
            SIMD2<Float>(1, 1), SIMD2<Float>(0, 1),
            SIMD2<Float>(0.5, 0.5),   // interior point must be dropped
        ]
        let hull = BalanceModel.supportPolygon(footCorners: square)
        XCTAssertEqual(hull.count, 4, "interior point excluded")
        // Every hull vertex is a corner of the unit square.
        for v in hull {
            XCTAssertTrue((abs(v.x) < 1e-5 || abs(v.x - 1) < 1e-5) &&
                          (abs(v.y) < 1e-5 || abs(v.y - 1) < 1e-5))
        }
    }

    func testSupportPolygon_isCounterClockwise() {
        let hull = BalanceModel.supportPolygon(footCorners: [
            SIMD2<Float>(0, 0), SIMD2<Float>(2, 0), SIMD2<Float>(2, 2), SIMD2<Float>(0, 2),
        ])
        // Signed area of a CCW polygon is positive.
        var area: Float = 0
        for i in 0..<hull.count {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            area += a.x * b.y - b.x * a.y
        }
        XCTAssertGreaterThan(area, 0, "hull wound counter-clockwise")
    }

    func testSupportPolygon_collinearInputDoesNotCrash() {
        let line: [SIMD2<Float>] = [SIMD2<Float>(0, 0), SIMD2<Float>(1, 0), SIMD2<Float>(2, 0)]
        let hull = BalanceModel.supportPolygon(footCorners: line)
        XCTAssertLessThanOrEqual(hull.count, line.count)   // degenerate, but no trap
    }

    // MARK: - Task 3: Stability margin

    private var unitSquare: [SIMD2<Float>] {
        // CCW unit square centered at origin, half-extent 1 (so edges at ±1).
        [SIMD2<Float>(-1, -1), SIMD2<Float>(1, -1), SIMD2<Float>(1, 1), SIMD2<Float>(-1, 1)]
    }

    func testMargin_positiveAtCentroidEqualsHalfExtent() {
        let (margin, centroid) = BalanceModel.stabilityMargin(comGround: .zero, polygon: unitSquare)
        XCTAssertEqual(centroid.x, 0, accuracy: 1e-6)
        XCTAssertEqual(centroid.y, 0, accuracy: 1e-6)
        XCTAssertEqual(margin, 1.0, accuracy: 1e-5, "centroid is 1.0 from every edge")
    }

    func testMargin_decreasesMonotonicallyTowardEdge() {
        let m0 = BalanceModel.stabilityMargin(comGround: SIMD2<Float>(0, 0), polygon: unitSquare).margin
        let m1 = BalanceModel.stabilityMargin(comGround: SIMD2<Float>(0.5, 0), polygon: unitSquare).margin
        let m2 = BalanceModel.stabilityMargin(comGround: SIMD2<Float>(0.9, 0), polygon: unitSquare).margin
        XCTAssertGreaterThan(m0, m1)
        XCTAssertGreaterThan(m1, m2)
        XCTAssertGreaterThan(m2, 0, "still inside")
    }

    func testMargin_negativeOutsideWithCorrectMagnitude() {
        let (margin, _) = BalanceModel.stabilityMargin(comGround: SIMD2<Float>(1.5, 0), polygon: unitSquare)
        XCTAssertEqual(margin, -0.5, accuracy: 1e-5, "0.5 past the +x edge")
    }

    // MARK: - Task 4: Foot ground corners

    @MainActor func testFootGroundCorners_fourCornersSpanningTheFoot() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()

        let corners = try XCTUnwrap(BalanceModel.footGroundCorners(model: model, foot: .left))
        XCTAssertEqual(corners.count, 4)
        // The four corners are not degenerate: they span a non-trivial area (a real foot).
        let hull = BalanceModel.supportPolygon(footCorners: corners)
        var area: Float = 0
        for i in 0..<hull.count {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            area += a.x * b.y - b.x * a.y
        }
        XCTAssertGreaterThan(abs(area) * 0.5, 1e-4, "one foot forms a real (non-degenerate) polygon")
    }

    // MARK: - Task 5: evaluate() integration

    @MainActor private func loadRig() async throws -> VRMModel {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()
        return model
    }

    @MainActor func testEvaluate_restPoseIsBalanced() async throws {
        let model = try await loadRig()
        let state = try XCTUnwrap(BalanceModel.evaluate(model: model))
        XCTAssertGreaterThan(state.margin, 0, "standing rest pose ⇒ CoM inside the base of support")
        XCTAssertTrue(state.isBalanced)
    }

    /// The discriminating test (design §5): swinging a LEG moves the CoM toward the
    /// leg's motion. Fails under a torso-only weighting; passes under weighted-segment.
    @MainActor func testEvaluate_comShiftsTowardASwungLeg() async throws {
        let model = try await loadRig()
        let humanoid = try XCTUnwrap(model.humanoid)
        let comBefore = try XCTUnwrap(BalanceModel.evaluate(model: model)).centerOfMass
        let footIdx = try XCTUnwrap(humanoid.getBoneNode(.leftFoot))
        let footBefore = model.nodes[footIdx].worldPosition

        // Swing the left leg out/up by rotating the upper leg, torso untouched.
        let upperLegIdx = try XCTUnwrap(humanoid.getBoneNode(.leftUpperLeg))
        model.nodes[upperLegIdx].rotation =
            simd_quatf(angle: 1.0, axis: SIMD3<Float>(1, 0, 0)) * model.nodes[upperLegIdx].rotation
        model.updateNodeTransforms()

        let comAfter = try XCTUnwrap(BalanceModel.evaluate(model: model)).centerOfMass
        let footAfter = model.nodes[footIdx].worldPosition

        let comMove = SIMD2<Float>(comAfter.x - comBefore.x, comAfter.z - comBefore.z)
        let legMove = SIMD2<Float>(footAfter.x - footBefore.x, footAfter.z - footBefore.z)
        XCTAssertGreaterThan(simd_length(comMove), 1e-4, "CoM tracks the limb (not torso-only)")
        XCTAssertGreaterThan(simd_dot(comMove, legMove), 0, "CoM shifted toward the swung leg")
    }

    @MainActor func testEvaluate_singlePlantedFootShrinksSupport() async throws {
        let model = try await loadRig()
        let both = try XCTUnwrap(BalanceModel.evaluate(model: model, plantedFeet: [.left, .right]))
        let left = try XCTUnwrap(BalanceModel.evaluate(model: model, plantedFeet: [.left]))
        func area(_ poly: [SIMD2<Float>]) -> Float {
            var a: Float = 0
            for i in 0..<poly.count { let p = poly[i], q = poly[(i + 1) % poly.count]; a += p.x * q.y - q.x * p.y }
            return abs(a) * 0.5
        }
        XCTAssertLessThan(area(left.supportPolygon), area(both.supportPolygon),
                          "one-foot base is smaller than two-foot base")
    }

    @MainActor func testEvaluate_isReadOnlyAndDeterministic() async throws {
        let model = try await loadRig()
        let hipsIdx = try XCTUnwrap(model.humanoid?.getBoneNode(.hips))
        let rotBefore = model.nodes[hipsIdx].rotation
        let a = try XCTUnwrap(BalanceModel.evaluate(model: model))
        let b = try XCTUnwrap(BalanceModel.evaluate(model: model))

        // Tolerance, not exact equality. This assertion flaked under `--parallel`
        // (~1 run in 5) with the two results differing in x and z only:
        //   x -2.3213427e-09 vs -1.3928055e-09,  z 8.1586203e-4 vs 8.158621e-4.
        //
        // What is established by measurement:
        //   * `evaluate` is bit-stable on a fixed model — 0 mismatches in 20,000
        //     consecutive call pairs, and 0 in 300 fresh-load-then-evaluate-twice
        //     rounds. `centerOfMass` returns identical bits for the same input
        //     dictionary, and `effectiveFractions` iteration order is stable.
        //   * Loading the SAME file twice in one process can produce node world
        //     transforms differing at ~1e-7 relative (hips-derived CoM y of
        //     0.95468193 vs 0.95468205 across loads in a single process, so not
        //     hash-seed ordering). Timing-dependent, and TSAN-clean over this
        //     suite — benign per-load variance, not a race.
        //   * `centerOfMass.x` is a near-total left/right cancellation landing
        //     around 1e-9, so ~1e-7 input noise rewrites its low bits entirely
        //     while leaving y unchanged — matching the observed failure exactly.
        //
        // What is NOT established: the precise mechanism by which two calls on a
        // SINGLE already-loaded model diverged. This test loads once, and the
        // reproduction attempts above could not make one model disagree with
        // itself. So the loader jitter above explains the magnitude and the
        // affected components, but not yet how it reached these two calls.
        //
        // The tolerance is therefore deliberately robust to both readings rather
        // than tuned to a confirmed cause. 1e-6 sits well above the observed
        // ~1e-7 jitter and far below any real nondeterminism in the weighting or
        // fold logic, which would move the CoM by centimetres. Do not tighten
        // this back to XCTAssertEqual; if you can reproduce a single-model
        // divergence, that is a genuine bug worth filing rather than pinning.
        XCTAssertLessThan(simd_distance(a.centerOfMass, b.centerOfMass), 1e-6,
                          "deterministic: \(a.centerOfMass) vs \(b.centerOfMass)")
        // `margin` derives from `comGround` — the same x/z — so it carries the
        // same exposure and needs the same treatment before it flakes too.
        XCTAssertEqual(a.margin, b.margin, accuracy: 1e-6)
        // Exact: this compares stored values that nothing recomputes, so it is not
        // exposed to the jitter above.
        XCTAssertEqual(model.nodes[hipsIdx].rotation, rotBefore, "evaluate must not mutate the model")
    }

    /// Design §5: pushing the CoM outside the base of support makes the assembled
    /// margin negative and `imbalanceDirection` point toward the shift — the only
    /// integration test covering a negative real-rig margin and the imbalance
    /// DIRECTION (the pure-geometry margin tests use synthetic squares; the other
    /// integration tests only reach the zero/centered direction).
    @MainActor func testEvaluate_comOutsideBaseIsUnbalancedInShiftDirection() async throws {
        let model = try await loadRig()
        let humanoid = try XCTUnwrap(model.humanoid)
        let rest = try XCTUnwrap(BalanceModel.evaluate(model: model))
        XCTAssertGreaterThan(rest.margin, 0, "rest pose is balanced")

        // Shove the whole upper body ~1 m to one side (spine + its children: chest,
        // head, arms) while the feet stay planted — the CoM projects well outside the
        // foot base regardless of the rig's exact proportions.
        let spineIdx = try XCTUnwrap(humanoid.getBoneNode(.spine))
        model.nodes[spineIdx].translation += SIMD3<Float>(1.0, 0, 0)
        model.updateNodeTransforms()

        let shoved = try XCTUnwrap(BalanceModel.evaluate(model: model))
        XCTAssertLessThan(shoved.margin, 0, "CoM outside the base ⇒ falling")
        XCTAssertEqual(simd_length(shoved.imbalanceDirection), 1, accuracy: 1e-3,
                       "imbalanceDirection is a unit vector when imbalanced")
        let comShift = shoved.comGround - rest.comGround
        XCTAssertGreaterThan(simd_dot(shoved.imbalanceDirection, comShift), 0,
                             "imbalance points toward the CoM shift")
    }

    func testImbalanceDirection_zeroWhenCentered_unitWhenOffset() {
        // Centered ⇒ the defined zero vector (increment 2's "no step indicated" contract).
        XCTAssertEqual(BalanceModel.imbalanceDirection(comGround: SIMD2<Float>(1, 1),
                                                       centroid: SIMD2<Float>(1, 1)),
                       SIMD2<Float>(0, 0))
        // Offset ⇒ unit vector from centroid toward the CoM projection.
        let dir = BalanceModel.imbalanceDirection(comGround: SIMD2<Float>(3, 1),
                                                  centroid: SIMD2<Float>(1, 1))
        XCTAssertEqual(simd_length(dir), 1, accuracy: 1e-5)
        XCTAssertEqual(dir.x, 1, accuracy: 1e-5)
        XCTAssertEqual(dir.y, 0, accuracy: 1e-5)
    }
}
