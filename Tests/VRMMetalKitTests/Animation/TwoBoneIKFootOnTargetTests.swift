// Copyright 2026 Arkavo
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

import XCTest
import simd
@testable import VRMMetalKit

/// The solver's output is consumed by `AnimationLayerCompositor.applyToModel`
/// as `node.rotation = base * delta`, so these tests compose the result the
/// same way and check where the foot actually lands.
final class TwoBoneIKFootOnTargetTests: XCTestCase {
    private let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    /// Forward kinematics for hip → knee → foot with local child offsets.
    private func footPosition(hipWorldPos: SIMD3<Float>, hipWorldRot: simd_quatf, kneeLocalRot: simd_quatf,
                              kneeOffset: SIMD3<Float>, footOffset: SIMD3<Float>) -> (knee: SIMD3<Float>, foot: SIMD3<Float>) {
        let knee = hipWorldPos + hipWorldRot.act(kneeOffset)
        let kneeWorldRot = hipWorldRot * kneeLocalRot
        return (knee, knee + kneeWorldRot.act(footOffset))
    }

    private func assertClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, tolerance: Float = 1e-3, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_length(a - b), tolerance, "\(message): got \(a), expected \(b)", file: file, line: line)
    }

    /// VRM leg hanging along -Y from the hip, knee forward (+Z).
    func testFootLandsOnTargetForVRMLegHangingDown() {
        let hip = SIMD3<Float>(0, 0.9, 0)
        let kneeOffset = SIMD3<Float>(0, -0.4, 0)
        let footOffset = SIMD3<Float>(0, -0.4, 0)
        let knee = hip + kneeOffset
        let foot = knee + footOffset

        for target in [SIMD3<Float>(0, 0.3, 0.5), SIMD3<Float>(0.3, 0.3, 0.4), SIMD3<Float>(0, 0.2, 0), SIMD3<Float>(-0.2, 0.4, -0.3)] {
            let result = TwoBoneIKSolver.solve(rootPos: hip, midPos: knee, endPos: foot, targetPos: target,
                                               poleVector: SIMD3<Float>(0, 0, 1))!
            let fk = footPosition(hipWorldPos: hip, hipWorldRot: identity * result.rootRotation,
                                  kneeLocalRot: identity * result.midRotation,
                                  kneeOffset: kneeOffset, footOffset: footOffset)
            assertClose(fk.foot, target, "foot must land on \(target)")
            XCTAssertGreaterThan(fk.knee.z, hip.z + 0.01, "knee should bend toward the +Z pole for \(target), knee \(fk.knee)")
        }
    }

    /// The same leg under a hips node yawed 180° with a non-identity thigh
    /// base rotation: the returned deltas are local, so they must be
    /// conjugated into each bone's frame.
    func testFootLandsOnTargetWithRotatedParentAndBase() {
        let hipsYaw = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        let thighBase = simd_quatf(angle: 15 * .pi / 180, axis: SIMD3<Float>(0, 0, 1))
        let kneeBase = simd_quatf(angle: 2.6 * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
        let hip = SIMD3<Float>(0.1, 0.9, 0)
        let kneeOffset = SIMD3<Float>(0, -0.4, 0)
        let footOffset = SIMD3<Float>(0, -0.4, 0)

        let thighWorld = hipsYaw * thighBase
        let rest = footPosition(hipWorldPos: hip, hipWorldRot: thighWorld, kneeLocalRot: kneeBase,
                                kneeOffset: kneeOffset, footOffset: footOffset)
        let target = SIMD3<Float>(0.3, 0.35, -0.4)

        let result = TwoBoneIKSolver.solve(rootPos: hip, midPos: rest.knee, endPos: rest.foot, targetPos: target,
                                           poleVector: SIMD3<Float>(0, 0, -1),
                                           rootWorldRotation: thighWorld,
                                           midWorldRotation: thighWorld * kneeBase)!

        // Compose exactly as the compositor does: local = base * delta.
        let thighLocal = thighBase * result.rootRotation
        let kneeLocal = kneeBase * result.midRotation
        let fk = footPosition(hipWorldPos: hip, hipWorldRot: hipsYaw * thighLocal, kneeLocalRot: kneeLocal,
                              kneeOffset: kneeOffset, footOffset: footOffset)
        assertClose(fk.foot, target, "foot must land on target under a rotated parent")
        XCTAssertLessThan(fk.knee.z, hip.z - 0.01, "knee should bend toward the -Z pole, knee \(fk.knee)")
    }

    func testUnreachableTargetExtendsLegTowardTarget() {
        let hip = SIMD3<Float>(0, 0.9, 0)
        let kneeOffset = SIMD3<Float>(0, -0.4, 0)
        let footOffset = SIMD3<Float>(0, -0.4, 0)
        let knee = hip + kneeOffset
        let foot = knee + footOffset
        let target = SIMD3<Float>(0, 0.9, 2)

        let result = TwoBoneIKSolver.solve(rootPos: hip, midPos: knee, endPos: foot, targetPos: target,
                                           poleVector: SIMD3<Float>(0, 0, 1))!
        let fk = footPosition(hipWorldPos: hip, hipWorldRot: result.rootRotation, kneeLocalRot: result.midRotation,
                              kneeOffset: kneeOffset, footOffset: footOffset)
        assertClose(fk.foot, SIMD3<Float>(0, 0.9, 0.8), tolerance: 0.01, "leg should extend straight toward the target")
    }
}
