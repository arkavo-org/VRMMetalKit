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

final class CaptureStepStabilityTests: XCTestCase {
    private let legFrac: Float = 0.16   // swung-leg mass fraction (spec §4.1, Dempster)

    private func balanceFrom(feet: [SIMD3<Float>], com: SIMD3<Float>, footHalf: Float = 0.05) -> BalanceState {
        var cor: [SIMD2<Float>] = []
        for f in feet {
            cor.append(SIMD2<Float>(f.x - footHalf, f.z - footHalf)); cor.append(SIMD2<Float>(f.x + footHalf, f.z - footHalf))
            cor.append(SIMD2<Float>(f.x + footHalf, f.z + footHalf)); cor.append(SIMD2<Float>(f.x - footHalf, f.z + footHalf))
        }
        let poly = BalanceModel.supportPolygon(footCorners: cor)
        let cg = SIMD2<Float>(com.x, com.z)
        let (m, c) = BalanceModel.stabilityMargin(comGround: cg, polygon: poly)
        return BalanceState(centerOfMass: com, comGround: cg, supportPolygon: poly,
                            supportCentroid: c, margin: m, imbalanceDirection: BalanceModel.imbalanceDirection(comGround: cg, centroid: c))
    }

    /// True if a CONTINUOUS-drive run TRACKS (residual bounded); false if it ESCAPES
    /// (residual grows). The CoM advances by drivePerSec every FRAME (so the swing-lag
    /// is live) plus the swung-leg self-feedback (§4.1). committed params.
    private func tracks(drivePerSec: Float, cap: Float = CaptureStepParams.committedCaptureDistanceMax,
                        swing: Float = 0.25, rate: Float = 0.15) -> Bool {
        var p = CaptureStepParams(); p.captureDistance = cap; p.stepDamping = CaptureStepParams.committedStepDampingMin
        p.swingDuration = swing; p.minStepInterval = rate
        let c = CaptureStepController(params: p)
        c.seed(leftAnkle: SIMD3<Float>(-0.1, 0, 0), rightAnkle: SIMD3<Float>(0.1, 0, 0))
        var com = SIMD3<Float>(0, 1, 0); let dt: Float = 1.0 / 60.0
        var res: [Float] = []
        for _ in 0..<300 {
            com.x += drivePerSec * dt
            let before = c.plantedPositions()
            let b = balanceFrom(feet: before, com: com)
            res.append(max(0, -b.margin))
            _ = c.step(balance: b, dt: dt)
            let after = c.plantedPositions()
            if let mv = zip(after, before).first(where: { simd_distance($0.0, $0.1) > 1e-4 }) { com += legFrac * (mv.0 - mv.1) }
        }
        let peak = res.max() ?? 0; let tail = Array(res.suffix(30)).max() ?? 0
        return tail <= peak * 0.5 + 0.02   // bounded/shrinking ⇒ tracks; still-high tail ⇒ escaped
    }

    /// Tracking-capacity gate (spec §4.1): pass/fail is MONOTONE in disturbance rate —
    /// once it escapes as the rate rises it stays escaped (no bounce) — with an
    /// over-capacity counter-case that escapes and a below-capacity rate that tracks.
    func testTrackingCapacity_isMonotoneInDriveRate_withEscapingCounterCase() {
        let rates: [Float] = [0.1, 0.2, 0.3, 0.4, 0.6, 0.9, 1.3]
        let tr = rates.map { tracks(drivePerSec: $0) }
        // Monotone: no "tracks" appears AFTER an "escapes" as the rate rises.
        if let firstEscape = tr.firstIndex(of: false) {
            for i in firstEscape..<tr.count {
                XCTAssertFalse(tr[i], "non-monotone boundary at rate=\(rates[i]): \(Array(zip(rates, tr))) — the model is wrong")
            }
        }
        XCTAssertTrue(tr.contains(false), "an over-capacity rate escapes (counter-case): \(Array(zip(rates, tr)))")
        XCTAssertTrue(tr.contains(true), "a below-capacity rate tracks: \(Array(zip(rates, tr)))")
    }

    /// captureDistance is STABILIZING, not a loop-gain term (spec §4 re-axis): a larger
    /// lead tracks a disturbance that a smaller lead escapes.
    func testLargerCaptureDistance_tracksFasterDisturbance() {
        XCTAssertFalse(tracks(drivePerSec: 0.6, cap: 0.0), "no lead escapes at 0.6 m/s")
        XCTAssertTrue(tracks(drivePerSec: 0.6, cap: 0.5), "a large lead tracks the same 0.6 m/s")
    }
}
