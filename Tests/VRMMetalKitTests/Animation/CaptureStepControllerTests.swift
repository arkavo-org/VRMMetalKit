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
}
