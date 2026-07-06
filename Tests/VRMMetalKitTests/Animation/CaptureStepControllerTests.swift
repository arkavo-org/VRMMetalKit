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

final class CaptureStepControllerTests: XCTestCase {

    // MARK: - Task 1: params defaults + swing arc

    func testParamsDefaults_followRegime() {
        let p = CaptureStepParams()
        XCTAssertEqual(p.captureDistance, 0, "default is the follow regime")
        XCTAssertEqual(p.stepDamping, 0, "follow uses zero damping (plants exactly at CoM)")
        XCTAssertGreaterThan(p.swingDuration, 0)
        XCTAssertGreaterThan(p.minStepInterval, 0)
    }

    func testSwingArc_endpointsAndLift() {
        let from = SIMD3<Float>(0, 0, 0)
        let to = SIMD3<Float>(1, 0, 0)
        let h: Float = 0.1
        // Endpoints: no lift, exact from/to.
        XCTAssertEqual(CaptureStepMath.swingArc(from: from, to: to, t: 0, stepHeight: h), from)
        XCTAssertEqual(CaptureStepMath.swingArc(from: from, to: to, t: 1, stepHeight: h), to)
        // Midpoint: halfway across (smoothstep(0.5)=0.5) and lifted to the peak.
        let mid = CaptureStepMath.swingArc(from: from, to: to, t: 0.5, stepHeight: h)
        XCTAssertEqual(mid.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(mid.y, h, accuracy: 1e-5, "lift peaks at mid-swing")
    }

    func testSwingArc_phaseMonotonicAcross() {
        let from = SIMD3<Float>(0, 0, 0), to = SIMD3<Float>(1, 0, 0)
        var prevX: Float = -1
        for i in 0...10 {
            let x = CaptureStepMath.swingArc(from: from, to: to, t: Float(i) / 10, stepHeight: 0.1).x
            XCTAssertGreaterThanOrEqual(x, prevX, "horizontal progress is monotonic")
            prevX = x
        }
    }

    // MARK: - Task 2: trailing foot + capture placement

    func testTrailingFoot_isTheOneBehindTheFall() {
        // Fall/imbalance toward +x. Left foot at -x is behind the fall ⇒ trailing.
        let foot = CaptureStepMath.trailingFoot(
            leftPlant: SIMD3<Float>(-0.1, 0, 0), rightPlant: SIMD3<Float>(0.1, 0, 0),
            comGround: SIMD2<Float>(0, 0), imbalanceDirection: SIMD2<Float>(1, 0))
        XCTAssertEqual(foot, .left)
        // Flip the fall ⇒ right becomes trailing.
        let foot2 = CaptureStepMath.trailingFoot(
            leftPlant: SIMD3<Float>(-0.1, 0, 0), rightPlant: SIMD3<Float>(0.1, 0, 0),
            comGround: SIMD2<Float>(0, 0), imbalanceDirection: SIMD2<Float>(-1, 0))
        XCTAssertEqual(foot2, .right)
    }

    func testCaptureTarget_followPlantsExactlyAtCoM() {
        // captureDistance 0, stepDamping 0 ⇒ target == comGround (follow).
        let t = CaptureStepMath.captureTargetXZ(
            comGround: SIMD2<Float>(2, 1), imbalanceDirection: SIMD2<Float>(1, 0),
            supportCentroid: SIMD2<Float>(0, 0), captureDistance: 0, stepDamping: 0)
        XCTAssertEqual(t.x, 2, accuracy: 1e-5)
        XCTAssertEqual(t.y, 1, accuracy: 1e-5)
    }

    func testCaptureTarget_arrestReachesBeyondCoM_thenDamps() {
        let com = SIMD2<Float>(1, 0)
        let dir = SIMD2<Float>(1, 0)
        let centroid = SIMD2<Float>(0, 0)
        // Undamped arrest: full reach to com + dir*0.3 = (1.3, 0).
        let raw = CaptureStepMath.captureTargetXZ(comGround: com, imbalanceDirection: dir,
                                                  supportCentroid: centroid, captureDistance: 0.3, stepDamping: 0)
        XCTAssertEqual(raw.x, 1.3, accuracy: 1e-5)
        // 50% damping halves the step from the centroid: (0 + 0.5*1.3) = 0.65.
        let damped = CaptureStepMath.captureTargetXZ(comGround: com, imbalanceDirection: dir,
                                                     supportCentroid: centroid, captureDistance: 0.3, stepDamping: 0.5)
        XCTAssertEqual(damped.x, 0.65, accuracy: 1e-5, "damping scales the step from the centroid")
    }

    // MARK: - Task 3: controller state machine

    /// Build a BalanceState by hand from two foot positions + a CoM (rig-free), using
    /// BalanceModel's pure statics — the same closed-loop the convergence gate uses.
    private func balanceFrom(feet: [SIMD3<Float>], com: SIMD3<Float>, footHalf: Float = 0.05) -> BalanceState {
        var corners: [SIMD2<Float>] = []
        for f in feet {
            corners.append(SIMD2<Float>(f.x - footHalf, f.z - footHalf))
            corners.append(SIMD2<Float>(f.x + footHalf, f.z - footHalf))
            corners.append(SIMD2<Float>(f.x + footHalf, f.z + footHalf))
            corners.append(SIMD2<Float>(f.x - footHalf, f.z + footHalf))
        }
        let poly = BalanceModel.supportPolygon(footCorners: corners)
        let comGround = SIMD2<Float>(com.x, com.z)
        let (margin, centroid) = BalanceModel.stabilityMargin(comGround: comGround, polygon: poly)
        let imbalance = BalanceModel.imbalanceDirection(comGround: comGround, centroid: centroid)
        return BalanceState(centerOfMass: com, comGround: comGround, supportPolygon: poly,
                            supportCentroid: centroid, margin: margin, imbalanceDirection: imbalance)
    }

    func testStep_noStepWhenBalanced() {
        let c = CaptureStepController()
        c.seed(leftAnkle: SIMD3<Float>(-0.1, 0, 0), rightAnkle: SIMD3<Float>(0.1, 0, 0))
        // CoM centered ⇒ margin large positive ⇒ no step; feet stay planted where seeded.
        let b = balanceFrom(feet: [SIMD3<Float>(-0.1, 0, 0), SIMD3<Float>(0.1, 0, 0)], com: SIMD3<Float>(0, 1, 0))
        for _ in 0..<10 { _ = c.step(balance: b, dt: 1.0 / 60.0) }
        XCTAssertEqual(c.plantedFeet, [.left, .right])
        XCTAssertEqual(c.target(.left), SIMD3<Float>(-0.1, 0, 0))
        XCTAssertEqual(c.target(.right), SIMD3<Float>(0.1, 0, 0))
    }

    func testStep_imbalanceStartsASingleSwing_keepsOneFootPlanted() {
        var p = CaptureStepParams(); p.minStepInterval = 0
        let c = CaptureStepController(params: p)
        c.seed(leftAnkle: SIMD3<Float>(-0.1, 0, 0), rightAnkle: SIMD3<Float>(0.1, 0, 0))
        // CoM shoved past the +x edge ⇒ margin < triggerMargin ⇒ a step fires.
        let b = balanceFrom(feet: [SIMD3<Float>(-0.1, 0, 0), SIMD3<Float>(0.1, 0, 0)], com: SIMD3<Float>(0.5, 1, 0))
        _ = c.step(balance: b, dt: 1.0 / 60.0)   // one frame: a swing begins
        XCTAssertEqual(c.plantedFeet.count, 1, "exactly one foot planted during a swing (≥1 invariant)")
    }

    func testStep_swingCompletesToPlantedAtTarget() {
        // Large minStepInterval so exactly ONE step fires; the swing then completes
        // without a second step re-triggering.
        var p = CaptureStepParams(); p.minStepInterval = 10; p.swingDuration = 0.1; p.captureDistance = 0; p.stepDamping = 0
        let c = CaptureStepController(params: p)
        c.seed(leftAnkle: SIMD3<Float>(-0.1, 0, 0), rightAnkle: SIMD3<Float>(0.1, 0, 0))
        let com = SIMD3<Float>(0.5, 1, 0)
        let b = balanceFrom(feet: [SIMD3<Float>(-0.1, 0, 0), SIMD3<Float>(0.1, 0, 0)], com: com)
        _ = c.step(balance: b, dt: 0.02)          // begin the single swing (trailing = left, target ≈ comGround)
        for _ in 0..<10 { _ = c.step(balance: b, dt: 0.02) }   // advance past swingDuration (0.1s)
        XCTAssertEqual(c.plantedFeet.count, 2, "swing completed, both planted again")
        // The swung (left) foot re-planted at the CoM ground projection (follow).
        XCTAssertEqual(c.target(.left).x, com.x, accuracy: 0.05)
    }

    // MARK: - Task 4: fixed-CoM contraction sanity-check (NOT a stability gate)
    //
    // SCOPE — read before trusting this test. This is a contraction SANITY-CHECK /
    // regression-lock on the step logic under a FIXED-CoM model, NOT the stability
    // gate for the §2 limit cycle. The limit cycle is a MOVING-CoM phenomenon (a step
    // over-recovers the margin → the disturbance re-drags the CoM → re-trips); with the
    // CoM frozen there is no re-drag, so no cycle can occur here to catch — under a
    // fixed CoM the two-foot capture recurrence contracts across essentially the whole
    // committed `captureDistance` range (verified: 0.05–0.30 all contract; there is no
    // monotone L=1 boundary for 2a to bracket). The genuine stability gate — a
    // moving-CoM, real-rig test that asserts the response does not limit-cycle across
    // the committed range and is MONOTONE in `captureDistance` — is 2b's, because
    // stability lives in the CoM-response and the CoM-response is 2b's domain.
    // This test only pins that the placement/damping math reduces a static residual
    // and doesn't blow up on the committed params — a floor, not a proof.

    /// Drive the controller one clean TWO-FOOT step per iteration against BalanceModel's
    /// pure statics with a FIXED CoM; return the static residual (CoM distance past the
    /// support edge) measured with both feet planted before each step. The rate limit
    /// (`minStepInterval > swingDuration`) is what makes each iteration a single
    /// two-foot step: after a swing lands, the limit blocks a re-trigger until the next
    /// iteration, so the support is a genuine two-foot base at each measurement.
    private func residualSequence(params pIn: CaptureStepParams, comGround: SIMD2<Float>, steps: Int) -> [Float] {
        var p = pIn
        p.swingDuration = 0.1
        p.minStepInterval = 0.2                          // > swingDuration ⇒ one clean step/iter
        let c = CaptureStepController(params: p)
        c.seed(leftAnkle: SIMD3<Float>(-0.1, 0, 0), rightAnkle: SIMD3<Float>(0.1, 0, 0))
        let com = SIMD3<Float>(comGround.x, 1, comGround.y)
        let framesPerIter = Int(((p.swingDuration + p.minStepInterval + 0.02) * 60).rounded(.up))
        var residuals: [Float] = []
        for _ in 0..<steps {
            let feet = c.plantedPositions()               // both planted at measurement time
            let b = balanceFrom(feet: feet, com: com)
            residuals.append(max(0, -b.margin))           // distance CoM is OUTSIDE support
            if b.margin >= p.triggerMargin { break }      // support caught the CoM
            for _ in 0..<framesPerIter { _ = c.step(balance: b, dt: 1.0 / 60.0) }  // one two-foot step
        }
        return residuals
    }

    /// Regression-lock: the committed default arrest params reduce a static residual to
    /// near zero under the fixed-CoM two-foot model. Guards the placement/damping math
    /// against a future refactor — it is NOT a stability proof (see the scope note above).
    func testStepLogic_contractsAStaticResidual_fixedCoMModel() {
        var p = CaptureStepParams()
        p.captureDistance = CaptureStepParams.committedCaptureDistanceMax
        p.stepDamping = CaptureStepParams.committedStepDampingMin
        let r = residualSequence(params: p, comGround: SIMD2<Float>(0.4, 0), steps: 12)
        for i in 1..<r.count {
            XCTAssertLessThanOrEqual(r[i], r[i - 1] + 1e-4, "static residual did not reduce at step \(i): \(r)")
        }
        XCTAssertLessThan(r.last ?? .greatestFiniteMagnitude, 0.05, "residual reduced to near zero: \(r)")
    }
}
