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

/// Pure math for the postural yield (design §3 A/B/C). No Metal, no model.
final class PosturalContactSolverTests: XCTestCase {

    // MARK: - A. Penetration detection

    func testPenetration_pointInsideCapsule_hasPositiveDepthAndOutwardPush() {
        // Capsule along +Y through the origin, radius 0.5. A point 0.2 to the +X
        // side of the axis is 0.3 deep and pushed in +X (away from the axis).
        let (depth, push) = PosturalContactSolver.penetration(
            point: SIMD3<Float>(0.2, 0.5, 0),
            capsuleP0: SIMD3<Float>(0, 0, 0), capsuleP1: SIMD3<Float>(0, 1, 0), radius: 0.5)
        XCTAssertEqual(depth, 0.3, accuracy: 1e-5)
        XCTAssertEqual(push.x, 1, accuracy: 1e-5)
        XCTAssertEqual(push.y, 0, accuracy: 1e-5)
        XCTAssertEqual(push.z, 0, accuracy: 1e-5)
    }

    func testPenetration_pointOutsideCapsule_hasZeroDepth() {
        let (depth, _) = PosturalContactSolver.penetration(
            point: SIMD3<Float>(0.9, 0.5, 0),
            capsuleP0: SIMD3<Float>(0, 0, 0), capsuleP1: SIMD3<Float>(0, 1, 0), radius: 0.5)
        XCTAssertEqual(depth, 0, accuracy: 1e-6)
    }

    // MARK: - B. Target lean rotation

    func testTargetLean_angleClampsAndIsMonotonicInDepth() {
        var params = PosturalContactParams()
        params.kGain = 2.0                 // rad per metre
        params.maxLeanAngle = 0.5          // rad
        let up = SIMD3<Float>(0, 1, 0)
        let push = SIMD3<Float>(1, 0, 0)

        let shallow = PosturalContactSolver.targetLean(depth: 0.10, pushDir: push, spineUp: up, params: params)
        let deeper  = PosturalContactSolver.targetLean(depth: 0.20, pushDir: push, spineUp: up, params: params)
        let clamped = PosturalContactSolver.targetLean(depth: 1.00, pushDir: push, spineUp: up, params: params)

        XCTAssertEqual(shallow.angle, 0.20, accuracy: 1e-5)          // 2.0 * 0.10
        XCTAssertEqual(deeper.angle, 0.40, accuracy: 1e-5)           // 2.0 * 0.20
        XCTAssertGreaterThan(deeper.angle, shallow.angle)            // monotonic
        XCTAssertEqual(clamped.angle, params.maxLeanAngle, accuracy: 1e-5)  // clamps
    }

    func testTargetLean_identityAtZeroDepth() {
        let q = PosturalContactSolver.targetLean(
            depth: 0, pushDir: SIMD3<Float>(1, 0, 0), spineUp: SIMD3<Float>(0, 1, 0),
            params: PosturalContactParams())
        XCTAssertEqual(q.angle, 0, accuracy: 1e-6)
    }

    func testTargetLean_leansTheUpperBodyAwayFromPartner() {
        // spineUp = +Y, partner pushes toward +X. The lean must tip the top of the
        // spine toward +X (away from the partner), so rotating the up-vector by the
        // target quaternion gains +X.
        var params = PosturalContactParams()
        params.kGain = 2.0
        params.maxLeanAngle = 1.0
        let up = SIMD3<Float>(0, 1, 0)
        let push = SIMD3<Float>(1, 0, 0)
        let q = PosturalContactSolver.targetLean(depth: 0.3, pushDir: push, spineUp: up, params: params)
        let tilted = q.act(up)
        XCTAssertGreaterThan(tilted.x, 0.01, "top of spine leans toward +X, away from the partner")
    }

    // MARK: - C. Critically-damped smoothing

    func testSmoothing_easesTowardTargetOverFrames() {
        var params = PosturalContactParams()
        params.kGain = 2.0
        params.maxLeanAngle = 1.0
        params.stiffness = 8.0
        var solver = PosturalContactSolver(params: params)
        let capsule = CapsuleCollider(p0: SIMD3<Float>(0, 0, 0), p1: SIMD3<Float>(0, 1, 0), radius: 0.5)
        let chest = SIMD3<Float>(0.2, 0.5, 0)   // 0.3 deep
        let up = SIMD3<Float>(0, 1, 0)

        let target = PosturalContactSolver.targetLean(depth: 0.3, pushDir: SIMD3<Float>(1, 0, 0),
                                                      spineUp: up, params: params)
        let a1 = solver.update(partnerTorso: capsule, chestWorld: chest, spineUp: up, dt: 1.0 / 60.0).angle
        for _ in 0..<3 { _ = solver.update(partnerTorso: capsule, chestWorld: chest, spineUp: up, dt: 1.0 / 60.0) }
        let a4 = solver.update(partnerTorso: capsule, chestWorld: chest, spineUp: up, dt: 1.0 / 60.0).angle

        XCTAssertGreaterThan(a1, 0, "yield begins on contact")
        XCTAssertGreaterThan(a4, a1, "yield eases in over frames")
        XCTAssertLessThanOrEqual(a4, target.angle + 1e-4, "never overshoots the target (critically damped)")
    }

    func testSmoothing_recoversToIdentityOnSeparation() {
        var params = PosturalContactParams()
        params.kGain = 2.0
        params.maxLeanAngle = 1.0
        params.stiffness = 12.0
        var solver = PosturalContactSolver(params: params)
        let up = SIMD3<Float>(0, 1, 0)
        let contact = CapsuleCollider(p0: SIMD3<Float>(0, 0, 0), p1: SIMD3<Float>(0, 1, 0), radius: 0.5)
        let chest = SIMD3<Float>(0.2, 0.5, 0)
        // Build up a lean.
        for _ in 0..<30 { _ = solver.update(partnerTorso: contact, chestWorld: chest, spineUp: up, dt: 1.0 / 60.0) }
        XCTAssertGreaterThan(solver.lean.angle, 0.05)
        // Partner leaves (chest no longer penetrates): depth 0, recovers to identity.
        let apart = CapsuleCollider(p0: SIMD3<Float>(5, 0, 0), p1: SIMD3<Float>(5, 1, 0), radius: 0.5)
        for _ in 0..<120 { _ = solver.update(partnerTorso: apart, chestWorld: chest, spineUp: up, dt: 1.0 / 60.0) }
        XCTAssertEqual(solver.lean.angle, 0, accuracy: 1e-3, "recovers to identity on separation")
    }
}
