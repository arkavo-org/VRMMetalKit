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
import simd
@testable import VRMMetalKit

final class ArmCounterbalanceSolverTests: XCTestCase {

    func testTargetPose_zeroIntensityIsRest() {
        let p = ArmCounterbalanceSolver.targetPose(
            intensity: 0, localFallXZ: SIMD2(1, 0), params: ArmCounterbalanceParams())
        XCTAssertEqual(p, .zero)
    }

    func testTargetPose_rightFallRaisesRightArmMore() {
        var params = ArmCounterbalanceParams()
        params.maxRaise = 1.0
        params.blendWeight = 1.0
        let p = ArmCounterbalanceSolver.targetPose(
            intensity: 1, localFallXZ: SIMD2(1, 0), params: params)
        XCTAssertGreaterThan(p.rightRaise, p.leftRaise)
        XCTAssertGreaterThan(p.rightRaise, 0.3)
        XCTAssertGreaterThan(p.leftRaise, 0.2, "counterweight arm still rises")
        XCTAssertGreaterThan(p.leftElbow, 0)
        XCTAssertGreaterThan(p.rightElbow, 0)
    }

    func testTargetPose_leftFallRaisesLeftArmMore() {
        let p = ArmCounterbalanceSolver.targetPose(
            intensity: 1, localFallXZ: SIMD2(-1, 0), params: ArmCounterbalanceParams())
        XCTAssertGreaterThan(p.leftRaise, p.rightRaise)
    }

    func testTargetPose_forwardFallRaisesBothEvenly() {
        let p = ArmCounterbalanceSolver.targetPose(
            intensity: 1, localFallXZ: SIMD2(0, 1), params: ArmCounterbalanceParams())
        XCTAssertEqual(p.leftRaise, p.rightRaise, accuracy: 1e-5)
        XCTAssertGreaterThan(p.leftRaise, 0.3)
        // Reach/spread default to 0 — layer uses raise + elbow only.
        XCTAssertEqual(p.leftReach, 0, accuracy: 1e-6)
        XCTAssertEqual(p.leftSpread, 0, accuracy: 1e-6)
    }

    func testUpdate_springsTowardTargetThenDecays() {
        var s = ArmCounterbalanceSolver(params: ArmCounterbalanceParams(stiffness: 20))
        _ = s.update(intensity: 1, localFallXZ: SIMD2(1, 0), dt: 0.1)
        XCTAssertGreaterThan(s.pose.intensity, 0.5)
        XCTAssertGreaterThan(s.pose.rightRaise, 0.2)

        // Decay to rest.
        for _ in 0..<30 {
            _ = s.update(intensity: 0, localFallXZ: .zero, dt: 0.05)
        }
        XCTAssertLessThan(s.pose.intensity, 0.05)
        XCTAssertLessThan(s.pose.rightRaise, 0.05)
    }

    func testUpdate_subFrameDt_stepsPartwayTowardTarget() {
        // stiffness 20, dt 0.01 → blend factor k·dt = 0.2 < 1: the spring is
        // actually exercised (large dt clamps to 1 and jumps straight to target).
        let params = ArmCounterbalanceParams(stiffness: 20)
        var s = ArmCounterbalanceSolver(params: params)
        let target = ArmCounterbalanceSolver.targetPose(
            intensity: 1, localFallXZ: SIMD2(1, 0), params: params)

        _ = s.update(intensity: 1, localFallXZ: SIMD2(1, 0), dt: 0.01)
        XCTAssertGreaterThan(s.pose.rightRaise, 0, "spring leaves rest on impact")
        XCTAssertLessThan(s.pose.rightRaise, target.rightRaise,
                          "one sub-frame step must land strictly short of the target")
        XCTAssertEqual(s.pose.rightRaise, target.rightRaise * 0.2, accuracy: 1e-5,
                       "blend factor is k·dt = 0.2")

        // Further steps keep easing in without overshoot.
        var prev = s.pose.rightRaise
        for _ in 0..<5 {
            _ = s.update(intensity: 1, localFallXZ: SIMD2(1, 0), dt: 0.01)
            XCTAssertGreaterThan(s.pose.rightRaise, prev, "monotonic approach")
            prev = s.pose.rightRaise
        }
        XCTAssertLessThanOrEqual(prev, target.rightRaise + 1e-6,
                                 "never overshoots the target (exponential approach)")
    }

    func testTargetPose_intensityIsMonotonic() {
        let lo = ArmCounterbalanceSolver.targetPose(
            intensity: 0.3, localFallXZ: SIMD2(0, 1), params: ArmCounterbalanceParams())
        let hi = ArmCounterbalanceSolver.targetPose(
            intensity: 0.9, localFallXZ: SIMD2(0, 1), params: ArmCounterbalanceParams())
        XCTAssertGreaterThan(hi.leftRaise, lo.leftRaise)
        XCTAssertGreaterThan(hi.leftElbow, lo.leftElbow)
    }
}
