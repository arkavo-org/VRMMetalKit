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

final class CrowdMotionDriverTests: XCTestCase {
    private func driver() -> CrowdMotionDriver {
        // start 1.0m half-sep (2m apart), hold 0.15m half-sep (0.3m apart).
        CrowdMotionDriver(startSep: 1.0, holdSep: 0.15,
                          approachStart: 0.1, approachEnd: 0.4, holdEnd: 0.7, partEnd: 0.95)
    }

    func testHoldsAtStartBeforeApproach() {
        XCTAssertEqual(driver().halfSeparation(at: 0.0), 1.0, accuracy: 1e-5)
        XCTAssertEqual(driver().halfSeparation(at: 0.1), 1.0, accuracy: 1e-5)
    }

    func testReachesHoldSeparationDuringHold() {
        XCTAssertEqual(driver().halfSeparation(at: 0.4), 0.15, accuracy: 1e-5)
        XCTAssertEqual(driver().halfSeparation(at: 0.55), 0.15, accuracy: 1e-5)
        XCTAssertEqual(driver().halfSeparation(at: 0.7), 0.15, accuracy: 1e-5)
    }

    func testApproachIsMonotonicInward() {
        let d = driver()
        var prev = d.halfSeparation(at: 0.1)
        for step in stride(from: Float(0.1), through: 0.4, by: 0.02) {
            let cur = d.halfSeparation(at: step)
            XCTAssertLessThanOrEqual(cur, prev + 1e-5, "approach must not move outward")
            prev = cur
        }
    }

    func testPartsBackOutward() {
        let d = driver()
        XCTAssertGreaterThan(d.halfSeparation(at: 0.9), d.halfSeparation(at: 0.7),
                             "part window moves back outward")
    }
}
