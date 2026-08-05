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
import Metal
import simd
@testable import VRMMetalKit

/// Applies `IKLayer.solveIKForLeg`'s output to a real rig and checks where the
/// ankle actually lands — the check none of `IKLayerTests`' 24 cases perform
/// (they exercise `TwoBoneIKSolver.solve` on synthetic input, or `IKLayer`'s
/// metadata/mode switching, never solve output applied to a skinned model).
/// That gap is exactly how a 174°-off rotation (fixed alongside this test)
/// stayed green: nothing here pinned the actual geometry `IKLayer` produces.
///
/// `solveIKForLeg` is package-internal (not `public`) specifically so this
/// suite can call it directly with an arbitrary target, bypassing the
/// grounding-mode plumbing (`.idleGrounding`'s hip offset, `.walkCycle`'s
/// contact-detector lock) that would otherwise be the only way to reach it.
final class IKLayerRoundTripTests: XCTestCase {

    private struct Rig {
        let model: VRMModel
        let ik: IKLayer
        let hipIdx: Int
        let kneeIdx: Int
        let ankleIdx: Int
        let hipPos: SIMD3<Float>
        let thighLen: Float
        let shinLen: Float
    }

    @MainActor private func loadRig(_ device: MTLDevice, yawDegrees: Float = 0) async throws -> Rig {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        if yawDegrees != 0 {
            let yaw = simd_quatf(angle: yawDegrees * .pi / 180, axis: SIMD3<Float>(0, 1, 0))
            for root in model.nodes where root.parent == nil {
                root.rotation = yaw
            }
        }
        model.updateNodeTransforms()

        let ik = IKLayer()
        ik.initialize(with: model)

        let humanoid = try XCTUnwrap(model.humanoid)
        let hipIdx = try XCTUnwrap(humanoid.getBoneNode(.leftUpperLeg))
        let kneeIdx = try XCTUnwrap(humanoid.getBoneNode(.leftLowerLeg))
        let ankleIdx = try XCTUnwrap(humanoid.getBoneNode(.leftFoot))
        let hipPos = model.nodes[hipIdx].worldPosition
        let kneePos = model.nodes[kneeIdx].worldPosition
        let anklePos = model.nodes[ankleIdx].worldPosition
        let thighLen = TwoBoneIKSolver.boneLength(from: hipPos, to: kneePos)
        let shinLen = TwoBoneIKSolver.boneLength(from: kneePos, to: anklePos)

        return Rig(model: model, ik: ik, hipIdx: hipIdx, kneeIdx: kneeIdx, ankleIdx: ankleIdx,
                   hipPos: hipPos, thighLen: thighLen, shinLen: shinLen)
    }

    /// Solves for `target`, applies both returned rotations to the rig, and
    /// returns the resulting hip/knee/ankle world positions after FK.
    @MainActor private func solveAndApply(_ rig: Rig, target: SIMD3<Float>) throws
        -> (hip: SIMD3<Float>, knee: SIMD3<Float>, ankle: SIMD3<Float>) {
        let result = try XCTUnwrap(rig.ik.solveIKForLeg(side: .left, targetFootPos: target),
                                    "solve should not fail for a well-posed target")
        func quatNorm(_ q: simd_quatf) -> Float {
            simd_length(q.vector)
        }
        XCTAssertFalse(result.rootRotation.real.isNaN, "root rotation must not be NaN")
        XCTAssertFalse(result.midRotation.real.isNaN, "mid rotation must not be NaN")
        XCTAssertEqual(quatNorm(result.rootRotation), 1, accuracy: 0.001,
                       "root rotation must be a unit quaternion")
        XCTAssertEqual(quatNorm(result.midRotation), 1, accuracy: 0.001,
                       "mid rotation must be a unit quaternion")

        rig.model.nodes[rig.hipIdx].rotation = result.rootRotation
        rig.model.nodes[rig.hipIdx].updateLocalMatrix()
        rig.model.nodes[rig.kneeIdx].rotation = result.midRotation
        rig.model.nodes[rig.kneeIdx].updateLocalMatrix()
        rig.model.updateNodeTransforms()

        return (rig.model.nodes[rig.hipIdx].worldPosition,
                rig.model.nodes[rig.kneeIdx].worldPosition,
                rig.model.nodes[rig.ankleIdx].worldPosition)
    }

    private static let reachTolerance: Float = 0.001

    /// A target well within reach, almost straight down from the hip — near
    /// full leg extension, minimal knee bend.
    @MainActor func testReachableTargetNearlyStraight_ankleLandsOnTarget() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let rig = try await loadRig(device)
        let maxReach = rig.thighLen + rig.shinLen - 0.001
        let target = rig.hipPos + SIMD3<Float>(0, -0.95 * maxReach, 0)

        let result = try solveAndApply(rig, target: target)

        XCTAssertLessThan(simd_length(result.ankle - target), Self.reachTolerance,
                          "ankle should land within ~1mm of a reachable, nearly-straight target")
    }

    /// A closer target offset well forward of the hip — well inside max reach,
    /// forcing a substantial (~100°) knee bend to hit it.
    @MainActor func testReachableTargetRequiringKneeBend_ankleLandsOnTarget() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let rig = try await loadRig(device)
        let target = rig.hipPos + SIMD3<Float>(0, -0.3, 0.4)
        let rawReach = simd_length(target - rig.hipPos)
        let maxReach = rig.thighLen + rig.shinLen - 0.001
        let minReach = abs(rig.thighLen - rig.shinLen) + 0.001
        XCTAssertTrue((minReach...maxReach).contains(rawReach),
                      "test target must be genuinely reachable, not clamped, to exercise the bend")

        let result = try solveAndApply(rig, target: target)

        XCTAssertLessThan(simd_length(result.ankle - target), Self.reachTolerance,
                          "ankle should land within ~1mm of a reachable, bent-knee target")

        // Sanity: the knee angle really did bend (not a coincidental near-straight
        // solve) — hip-knee-ankle angle well short of a straight leg (π).
        let toKnee = simd_normalize(result.knee - result.hip)
        let toAnkleFromKnee = simd_normalize(result.ankle - result.knee)
        let kneeStraightness = simd_dot(toKnee, toAnkleFromKnee)
        XCTAssertLessThan(kneeStraightness, 0.9, "target was chosen to require a visible knee bend")
    }

    /// A target far beyond the summed leg length: the solve must clamp to max
    /// reach (not stretch toward the unreachable point), stay finite, and keep
    /// the leg nearly straight rather than folding the knee the wrong way.
    @MainActor func testUnreachableTarget_clampsToMaxReachWithoutNaNOrFlippedKnee() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let rig = try await loadRig(device)
        let maxReach = rig.thighLen + rig.shinLen - 0.001
        let farDir = simd_normalize(SIMD3<Float>(0, -1, 0.3))
        let target = rig.hipPos + farDir * (maxReach * 4)

        let result = try solveAndApply(rig, target: target)

        XCTAssertFalse(result.ankle.x.isNaN, "clamped ankle position must be finite")
        XCTAssertFalse(result.ankle.y.isNaN, "clamped ankle position must be finite")
        XCTAssertFalse(result.ankle.z.isNaN, "clamped ankle position must be finite")

        let achievedReach = simd_length(result.ankle - rig.hipPos)
        XCTAssertEqual(achievedReach, maxReach, accuracy: Self.reachTolerance,
                       "an unreachable target must clamp the ankle to max leg extension")

        // A fully extended leg is nearly straight at the knee (angle ≈ π), not
        // folded back on itself (a "flipped" or reverse knee).
        let toKnee = simd_normalize(result.knee - result.hip)
        let toAnkleFromKnee = simd_normalize(result.ankle - result.knee)
        let kneeStraightness = simd_dot(toKnee, toAnkleFromKnee)
        XCTAssertGreaterThan(kneeStraightness, 0.99,
                             "a max-reach leg should be nearly straight, not reverse-bent")
    }

    /// The knee-bend gate for a yawed avatar (every crowd member): the
    /// lateral-preserving pole flip must keep the knee on the SAME side of the
    /// leg it already occupied before the solve, not cross to the opposite
    /// side just because the world-space `kneeForwardDirection` hint no longer
    /// matches the avatar's rotated facing.
    @MainActor func testYawedAvatarKneeBendStaysOnItsOriginalSide() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let rig = try await loadRig(device, yawDegrees: 90)

        let preSolveKnee = rig.model.nodes[rig.kneeIdx].worldPosition
        // Chosen so the un-flipped `kneeForwardDirection` (world +Z) pole
        // disagrees with the side the knee already occupies post-yaw
        // (verified empirically: at 90° yaw this target drives
        // `dot(lateral, pole) < 0`, the exact condition the flip corrects).
        let target = rig.hipPos + SIMD3<Float>(0, -0.3, 0.4)

        let result = try solveAndApply(rig, target: target)

        let targetDir = simd_normalize(target - rig.hipPos)
        func lateralSide(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let v = p - rig.hipPos
            return v - targetDir * simd_dot(v, targetDir)
        }
        let preSide = lateralSide(preSolveKnee)
        let postSide = lateralSide(result.knee)
        XCTAssertGreaterThan(simd_dot(simd_normalize(preSide), simd_normalize(postSide)), 0,
                             "solved knee crossed to the opposite side of the leg plane under yaw")
    }
}
