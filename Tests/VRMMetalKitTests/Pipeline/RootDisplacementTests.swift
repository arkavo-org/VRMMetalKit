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

final class RootDisplacementTests: XCTestCase {
    func testNoRequestsLeavesBaseUntouched() {
        let d = RootDisplacement()
        XCTAssertEqual(d.resolve(base: SIMD3<Float>(1, 2, 3)), SIMD3<Float>(1, 2, 3))
    }

    func testAbsoluteReplacesBase() {
        var d = RootDisplacement()
        d.setAbsolute(SIMD3<Float>(10, 0, 0))
        XCTAssertEqual(d.resolve(base: SIMD3<Float>(1, 2, 3)), SIMD3<Float>(10, 0, 0))
    }

    func testDeltasAccumulateOnTopOfAbsolute() {
        var d = RootDisplacement()
        d.setAbsolute(SIMD3<Float>(10, 0, 0))
        d.addDelta(SIMD3<Float>(0.5, 0, 0.25))
        XCTAssertEqual(d.resolve(base: .zero), SIMD3<Float>(10.5, 0, 0.25))
    }

    func testDeltasApplyToBaseWhenNoAbsoluteRequested() {
        var d = RootDisplacement()
        d.addDelta(SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(d.resolve(base: SIMD3<Float>(0, 0, 2)), SIMD3<Float>(0, 0, 3))
    }

    func testDeltaOrderIsInsertionOrder() {
        var d1 = RootDisplacement()
        d1.addDelta(SIMD3<Float>(1e7, 0, 0))
        d1.addDelta(SIMD3<Float>(1, 0, 0))
        var d2 = RootDisplacement()
        d2.addDelta(SIMD3<Float>(1, 0, 0))
        d2.addDelta(SIMD3<Float>(1e7, 0, 0))
        XCTAssertEqual(d1.resolve(base: .zero).x, Float(1e7) + Float(1))
        XCTAssertEqual(d2.resolve(base: .zero).x, Float(1) + Float(1e7))
    }

    func testHasAbsoluteReportsRequestState() {
        var d = RootDisplacement()
        XCTAssertFalse(d.hasAbsolute)
        d.setAbsolute(.zero)
        XCTAssertTrue(d.hasAbsolute)
    }

    func testBitIdentityWithExpressionForm() {
        let base = SIMD3<Float>(0.37, 1.11, -0.29)
        let placement = SIMD3<Float>(0.813, 0, -0.447)
        let shove = SIMD2<Float>(0.0231, -0.0177)

        var literal = base + placement
        literal.x += shove.x
        literal.z += shove.y

        var d = RootDisplacement()
        d.setAbsolute(base + placement)
        d.addDelta(SIMD3<Float>(shove.x, 0, shove.y))
        let result = d.resolve(base: base)

        XCTAssertEqual(result.x.bitPattern, literal.x.bitPattern)
        XCTAssertEqual(result.y.bitPattern, literal.y.bitPattern)
        XCTAssertEqual(result.z.bitPattern, literal.z.bitPattern)
    }
}
