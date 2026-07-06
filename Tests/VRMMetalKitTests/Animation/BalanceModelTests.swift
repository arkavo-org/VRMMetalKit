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
}
