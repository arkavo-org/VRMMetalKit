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

final class CrowdPlacementTests: XCTestCase {
    func testTwoAvatarsPlacedOppositeAlongX() {
        let left = CrowdPlacement.rootTranslation(avatarIndex: 0, avatarCount: 2, halfSeparation: 0.9)
        let right = CrowdPlacement.rootTranslation(avatarIndex: 1, avatarCount: 2, halfSeparation: 0.9)
        XCTAssertEqual(left.x, -0.9, accuracy: 1e-5)
        XCTAssertEqual(right.x, 0.9, accuracy: 1e-5)
        XCTAssertEqual(left.y, 0, accuracy: 1e-5)
        XCTAssertEqual(left.z, 0, accuracy: 1e-5)
    }

    func testFacingPointsInwardTowardCenter() {
        // Avatar 0 at -X should face +X (its +Z forward rotated to +X); avatar 1 the reverse.
        let f0 = CrowdPlacement.facing(avatarIndex: 0, avatarCount: 2)
        let f1 = CrowdPlacement.facing(avatarIndex: 1, avatarCount: 2)
        let forward = SIMD3<Float>(0, 0, 1)  // VRM 1.0 faces +Z natively
        let d0 = f0.act(forward)
        let d1 = f1.act(forward)
        XCTAssertGreaterThan(d0.x, 0.9, "avatar 0 faces +X (toward center/partner)")
        XCTAssertLessThan(d1.x, -0.9, "avatar 1 faces -X")
    }
}
