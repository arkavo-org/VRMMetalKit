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

/// Pure geometry for the contact-aware clamp (Component A, design §2). No model.
final class CrowdContactClampTests: XCTestCase {

    /// Two parallel vertical segments offset by `d` on X are exactly `d` apart.
    func testSegmentDistance_parallelVerticalSegments() {
        let d = CrowdContactClamp.segmentDistance(
            SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(0.7, 0, 0), SIMD3<Float>(0.7, 1, 0))
        XCTAssertEqual(d, 0.7, accuracy: 1e-5)
    }

    /// Overlap = r0 + r1 − segment distance, positive only when surfaces cross.
    func testMaxOverlap_twoOverlappingTorsos() {
        let a = CapsuleCollider(p0: SIMD3<Float>(0, 0, 0), p1: SIMD3<Float>(0, 1, 0), radius: 0.3)
        let b = CapsuleCollider(p0: SIMD3<Float>(0.4, 0, 0), p1: SIMD3<Float>(0.4, 1, 0), radius: 0.3)
        // distance 0.4, radii sum 0.6 → overlap 0.2
        XCTAssertEqual(CrowdContactClamp.maxOverlap(torsos: [a, b]), 0.2, accuracy: 1e-5)
    }

    func testMaxOverlap_separatedTorsos_isZero() {
        let a = CapsuleCollider(p0: SIMD3<Float>(0, 0, 0), p1: SIMD3<Float>(0, 1, 0), radius: 0.3)
        let b = CapsuleCollider(p0: SIMD3<Float>(2, 0, 0), p1: SIMD3<Float>(2, 1, 0), radius: 0.3)
        XCTAssertEqual(CrowdContactClamp.maxOverlap(torsos: [a, b]), 0, accuracy: 1e-6)
    }

    /// Deep overlap past the margin pushes the shared radius out. For N=2 the
    /// chord grows 2× the radius, so the needed radius bump is excess/2.
    func testClamp_deepOverlap_raisesHalfSeparation() {
        let a = CapsuleCollider(p0: SIMD3<Float>(0, 0, 0), p1: SIMD3<Float>(0, 1, 0), radius: 0.3)
        let b = CapsuleCollider(p0: SIMD3<Float>(0.4, 0, 0), p1: SIMD3<Float>(0.4, 1, 0), radius: 0.3)
        // overlap 0.2, margin 0.05 → excess 0.15 → radius bump 0.075.
        let out = CrowdContactClamp.clampedHalfSeparation(
            driverHalfSep: 0.5, lastAppliedHalfSep: 0.5,
            torsos: [a, b], avatarCount: 2, margin: 0.05)
        XCTAssertEqual(out, 0.575, accuracy: 1e-4)
    }

    /// Within the margin (or separated) the driver's value passes through — the
    /// clamp only ever pushes apart, never pulls in.
    func testClamp_withinMargin_passesDriverValueThrough() {
        let a = CapsuleCollider(p0: SIMD3<Float>(0, 0, 0), p1: SIMD3<Float>(0, 1, 0), radius: 0.3)
        let b = CapsuleCollider(p0: SIMD3<Float>(0.58, 0, 0), p1: SIMD3<Float>(0.58, 1, 0), radius: 0.3)
        // overlap 0.02 < margin 0.05 → no push.
        let out = CrowdContactClamp.clampedHalfSeparation(
            driverHalfSep: 0.5, lastAppliedHalfSep: 0.5,
            torsos: [a, b], avatarCount: 2, margin: 0.05)
        XCTAssertEqual(out, 0.5, accuracy: 1e-6)
    }

    /// Feedback bound: applying the clamp repeatedly (snapshot re-measured at the
    /// new radius) holds the overlap at the margin — a period-2 dither around it
    /// in exact arithmetic, bounded, never diverging.
    func testClamp_convergesToMarginOverFrames() {
        let margin: Float = 0.05
        let radiusSum: Float = 0.6   // two 0.3 torsos, parallel vertical
        var h: Float = 0.2           // start deeply overlapped (chord 0.4, overlap 0.2)
        for _ in 0..<8 {
            let a = CapsuleCollider(p0: SIMD3<Float>(-h, 0, 0), p1: SIMD3<Float>(-h, 1, 0), radius: 0.3)
            let b = CapsuleCollider(p0: SIMD3<Float>(h, 0, 0), p1: SIMD3<Float>(h, 1, 0), radius: 0.3)
            h = CrowdContactClamp.clampedHalfSeparation(
                driverHalfSep: 0.0, lastAppliedHalfSep: h,
                torsos: [a, b], avatarCount: 2, margin: margin)
        }
        let finalChord = 2 * h
        let finalOverlap = radiusSum - finalChord
        XCTAssertLessThanOrEqual(finalOverlap, margin + 1e-3, "overlap is bounded at the margin")
        XCTAssertGreaterThan(finalOverlap, -0.05, "does not over-push far past the margin")
    }
}
