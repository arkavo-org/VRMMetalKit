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

final class FrozenSnapshotTests: XCTestCase {
    private func capsule(atX x: Float) -> CapsuleCollider {
        CapsuleCollider(p0: SIMD3<Float>(x, 0, 0), p1: SIMD3<Float>(x, 1, 0),
                        radius: 0.2, groupMask: 0xFFFF_FFFF)
    }

    func testNearestPartnerPicksClosestMidpoint() {
        let snap = FrozenSnapshot(
            torsos: [0: capsule(atX: 0), 1: capsule(atX: 5), 2: capsule(atX: 1)],
            indices: [0, 1, 2])
        let nearest = snap.nearestPartnerTorso(of: 0)
        XCTAssertEqual(nearest?.p0.x, 1, "avatar 2 at x=1 is nearer than avatar 1 at x=5")
    }

    func testNearestPartnerExcludesSelf() {
        let snap = FrozenSnapshot(torsos: [0: capsule(atX: 0)], indices: [0])
        XCTAssertNil(snap.nearestPartnerTorso(of: 0), "a lone avatar has no partner")
    }

    func testMissingSelfTorsoYieldsNoPartner() {
        let snap = FrozenSnapshot(torsos: [1: capsule(atX: 5)], indices: [0, 1])
        XCTAssertNil(snap.nearestPartnerTorso(of: 0),
                     "no own capsule ⇒ no midpoint to measure from, matching the pre-refactor guard")
    }

    func testPartnersWithoutTorsosAreSkipped() {
        let snap = FrozenSnapshot(torsos: [0: capsule(atX: 0), 2: capsule(atX: 9)],
                                  indices: [0, 1, 2])
        XCTAssertEqual(snap.nearestPartnerTorso(of: 0)?.p0.x, 9,
                       "index 1 has no capsule and must be skipped, not treated as origin")
    }

    func testTieBreakingIsFirstEncounteredWins() {
        let querier = CapsuleCollider(p0: SIMD3<Float>(0, 0, 0), p1: SIMD3<Float>(0, 1, 0),
                                     radius: 0.2, groupMask: 0xFFFF_FFFF)
        let partner1 = CapsuleCollider(p0: SIMD3<Float>(1, 0, 0), p1: SIMD3<Float>(1, 1, 0),
                                      radius: 0.3, groupMask: 0xFFFF_FFFF)
        let partner2 = CapsuleCollider(p0: SIMD3<Float>(-1, 0, 0), p1: SIMD3<Float>(-1, 1, 0),
                                      radius: 0.5, groupMask: 0xFFFF_FFFF)
        var snap = FrozenSnapshot(torsos: [0: querier, 1: partner1, 2: partner2],
                                 indices: [0, 1, 2])
        var nearest = snap.nearestPartnerTorso(of: 0)
        XCTAssertEqual(nearest?.radius, 0.3,
                       "when two partners are equidistant (symmetric ±1 positions), indices-order wins: partner1 first")
        snap = FrozenSnapshot(torsos: [0: querier, 1: partner1, 2: partner2],
                             indices: [0, 2, 1])
        nearest = snap.nearestPartnerTorso(of: 0)
        XCTAssertEqual(nearest?.radius, 0.5,
                       "reversed indices order makes partner2 first: iteration order is load-bearing")
    }

    func testIterationFollowsIndicesNotDictionary() {
        let querier = CapsuleCollider(p0: SIMD3<Float>(0, 0, 0), p1: SIMD3<Float>(0, 1, 0),
                                     radius: 0.2, groupMask: 0xFFFF_FFFF)
        let inList = CapsuleCollider(p0: SIMD3<Float>(2, 0, 0), p1: SIMD3<Float>(2, 1, 0),
                                    radius: 0.2, groupMask: 0xFFFF_FFFF)
        let omitted = CapsuleCollider(p0: SIMD3<Float>(0.5, 0, 0), p1: SIMD3<Float>(0.5, 1, 0),
                                     radius: 0.2, groupMask: 0xFFFF_FFFF)
        let snap = FrozenSnapshot(torsos: [0: querier, 1: omitted, 2: inList],
                                 indices: [0, 2])
        let nearest = snap.nearestPartnerTorso(of: 0)
        XCTAssertEqual(nearest?.p0.x, 2.0,
                       "avatar 1 (omitted from indices, despite being closer) must not be returned; iteration is indices-driven")
    }
}
