//
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
//

import XCTest
import simd
@testable import QuadrupedGait

/// Tests for the pure-math ``QuadrupedGaitEngine``. Metal-free by design —
/// no `MTLDevice` is created anywhere in this target.
final class QuadrupedGaitEngineTests: XCTestCase {

    // MARK: - Test rig

    /// Small symmetric rig: upper 0.55 / lower 0.55 / paw 0.30,
    /// hips at (±0.30, 0.9, ±0.5).
    private static let segments: [LegID: LegSegmentLengths] = [
        .frontLeft: LegSegmentLengths(upper: 0.55, lower: 0.55, paw: 0.30),
        .frontRight: LegSegmentLengths(upper: 0.55, lower: 0.55, paw: 0.30),
        .rearLeft: LegSegmentLengths(upper: 0.55, lower: 0.55, paw: 0.30),
        .rearRight: LegSegmentLengths(upper: 0.55, lower: 0.55, paw: 0.30),
    ]

    private static let hipOffsets: [LegID: SIMD3<Float>] = [
        .frontLeft: SIMD3<Float>(-0.30, 0.9, 0.5),
        .frontRight: SIMD3<Float>(0.30, 0.9, 0.5),
        .rearLeft: SIMD3<Float>(-0.30, 0.9, -0.5),
        .rearRight: SIMD3<Float>(0.30, 0.9, -0.5),
    ]

    /// A non-identity tucked pose so transition blending is observable.
    private static let tucked: [LegID: LegJointPose] = [
        .frontLeft: LegJointPose(hipAngle: -0.6, kneeAngle: 1.0, ankleAngle: -0.4),
        .frontRight: LegJointPose(hipAngle: -0.6, kneeAngle: 1.0, ankleAngle: -0.4),
        .rearLeft: LegJointPose(hipAngle: -0.6, kneeAngle: 1.0, ankleAngle: -0.4),
        .rearRight: LegJointPose(hipAngle: -0.6, kneeAngle: 1.0, ankleAngle: -0.4),
    ]

    private func makeEngine(parameters: GaitParameters = GaitParameters()) -> QuadrupedGaitEngine {
        QuadrupedGaitEngine(
            segments: Self.segments,
            tuckedPose: Self.tucked,
            hipOffsets: Self.hipOffsets,
            parameters: parameters
        )
    }

    // MARK: - FK helpers (duplicates the engine's sagittal FK)

    /// Extracts the X-axis rotation angle from a quaternion built as a
    /// pure local-X rotation.
    private func xAngle(_ q: simd_quatf) -> Float {
        2 * atan2(q.vector.x, q.vector.w)
    }

    /// Sagittal forward kinematics: hip → knee → ankle → paw, matching the
    /// engine's convention (segment direction (z: sin θ, y: -cos θ)).
    private func pawPosition(leg: LegID, pose: LegJointPose) -> (y: Float, z: Float) {
        let seg = Self.segments[leg]!
        let hipOffset = Self.hipOffsets[leg]!
        let hipAngle = xAngle(pose.hip)
        let kneeAngle = hipAngle + xAngle(pose.knee)
        let pawAngle = kneeAngle + xAngle(pose.ankle)
        let kneeY = hipOffset.y - seg.upper * cos(hipAngle)
        let kneeZ = hipOffset.z + seg.upper * sin(hipAngle)
        let ankleY = kneeY - seg.lower * cos(kneeAngle)
        let ankleZ = kneeZ + seg.lower * sin(kneeAngle)
        return (ankleY - seg.paw * cos(pawAngle), ankleZ + seg.paw * sin(pawAngle))
    }

    // MARK: - glTF sagittal mapping

    func testPositiveEngineHipOnGltfDownChainMovesTowardNegativeZ() {
        // Engine FK uses z += L·sin(θ), so a positive hip swings toward +Z.
        // The generated hound (and typical glTF) parents a (0, −L, 0) child
        // through Rx(θ), which yields z' = −L·sin(θ) — toward −Z, the glTF
        // nose. `.absolute` joint space therefore already maps engine-forward
        // onto asset-forward; negating walk angles would send the stride
        // toward the tail.
        let theta: Float = 0.4
        let length: Float = 0.55
        let engineZ = length * sin(theta)
        XCTAssertGreaterThan(engineZ, 0)

        let hip = simd_quatf(angle: theta, axis: SIMD3<Float>(1, 0, 0))
        let child = SIMD4<Float>(0, -length, 0, 1)
        let world = simd_float4x4(hip) * child
        XCTAssertLessThan(world.z, 0)
        XCTAssertEqual(world.z, -engineZ, accuracy: 1e-6)
    }

    // MARK: - Trot phase pairing

    func testTrotDiagonalPairing() {
        // No-clamp parameters: standing height beyond full leg reach (1.40)
        // so the ground clamp never fires and hips stay pure sinusoids.
        var params = GaitParameters()
        params.standingHeight = 1.5
        var engine = makeEngine(parameters: params)

        // Fully transition into walk, then advance into the stride.
        engine.update(deltaTime: 0.4, speed: 2.0, steering: 0, acceleration: 0, mode: .walk)
        engine.update(deltaTime: 0.1, speed: 2.0, steering: 0, acceleration: 0, mode: .walk)
        XCTAssertEqual(engine.transitionBlend, 1)

        let poses = engine.jointPoses()
        let fl = poses[.frontLeft]!
        let rr = poses[.rearRight]!
        let fr = poses[.frontRight]!
        let rl = poses[.rearLeft]!

        // Diagonal pairs share a phase exactly.
        for (a, b) in [(fl, rr), (fr, rl)] {
            XCTAssertEqual(a.hip.vector.x, b.hip.vector.x, accuracy: 1e-6)
            XCTAssertEqual(a.hip.vector.w, b.hip.vector.w, accuracy: 1e-6)
            XCTAssertEqual(a.knee.vector.x, b.knee.vector.x, accuracy: 1e-6)
            XCTAssertEqual(a.ankle.vector.x, b.ankle.vector.x, accuracy: 1e-6)
        }

        // The two pairs are in opposite phase: hip angles are negated, so
        // the X-axis quaternions have negated x and equal w.
        XCTAssertEqual(fl.hip.vector.x, -fr.hip.vector.x, accuracy: 1e-6)
        XCTAssertEqual(fl.hip.vector.w, fr.hip.vector.w, accuracy: 1e-6)
        // And the pairs are actually rotated (non-degenerate sample point).
        XCTAssertGreaterThan(abs(fl.hip.vector.x), 1e-3)
    }

    // MARK: - Mirrored leg chains

    func testMirroredLegsNegateJointAngles() {
        // No-clamp parameters: pure sinusoids, so mirroring is exactly
        // observable as angle negation.
        var params = GaitParameters()
        params.standingHeight = 1.5
        var engine = QuadrupedGaitEngine(
            segments: Self.segments,
            tuckedPose: Self.tucked,
            hipOffsets: Self.hipOffsets,
            parameters: params,
            mirroredLegs: [.rearLeft, .rearRight]
        )
        engine.update(deltaTime: 0.4, speed: 2.0, steering: 0, acceleration: 0, mode: .walk)
        engine.update(deltaTime: 0.1, speed: 2.0, steering: 0, acceleration: 0, mode: .walk)
        XCTAssertEqual(engine.transitionBlend, 1)

        let poses = engine.jointPoses()
        let fl = poses[.frontLeft]!
        let rr = poses[.rearRight]!

        // Same-phase diagonal pair, but RR is mirrored: every joint angle
        // negated (pure X rotations → negated quat x, equal quat w).
        for (a, b) in [(fl.hip, rr.hip), (fl.knee, rr.knee), (fl.ankle, rr.ankle)] {
            XCTAssertEqual(a.vector.x, -b.vector.x, accuracy: 1e-6)
            XCTAssertEqual(a.vector.w, b.vector.w, accuracy: 1e-6)
        }
        XCTAssertGreaterThan(abs(fl.hip.vector.x), 1e-3)
    }

    // MARK: - Foot-fall ground clamp

    func testSwingLiftsPawWhenChainExceedsStandingHeight() {
        // Demo-like geometry: 1.40 m chain vs 0.90 m standing height. The
        // unclamped FK paw sits ~0.5 m below the ground at every phase, so a
        // clamp that only tests pawY < groundY welds every foot to the floor
        // and stepHeight has no effect.
        var params = GaitParameters()
        params.strideLength = 0.8
        params.stepHeight = 0.15
        params.strideFrequency = 1.6
        params.referenceSpeed = 2.0
        params.standingHeight = 0.90
        var engine = makeEngine(parameters: params)

        let speed: Float = 2.0
        engine.update(deltaTime: 0.4, speed: speed, steering: 0, acceleration: 0, mode: .walk)
        XCTAssertEqual(engine.transitionBlend, 1)

        let groundY = Self.hipOffsets[.frontLeft]!.y - params.standingHeight
        let dt: Float = 0.008
        let strideDuration = 1 / (params.strideFrequency * speed / params.referenceSpeed)
        let steps = Int(strideDuration / dt) + 2

        var minY: Float = .greatestFiniteMagnitude
        var maxY: Float = -.greatestFiniteMagnitude
        for _ in 0..<steps {
            engine.update(deltaTime: dt, speed: speed, steering: 0, acceleration: 0, mode: .walk)
            let paw = pawPosition(leg: .frontLeft, pose: engine.jointPoses()[.frontLeft]!)
            minY = min(minY, paw.y)
            maxY = max(maxY, paw.y)
            XCTAssertGreaterThanOrEqual(paw.y, groundY - 1e-3)
        }

        XCTAssertEqual(minY, groundY, accuracy: 0.02, "stance should plant at ground, got minY=\(minY)")
        XCTAssertEqual(maxY, groundY + params.stepHeight, accuracy: 0.03,
                       "swing should lift by stepHeight, got maxY=\(maxY) range=\(maxY - minY)")
    }

    func testGroundClampKeepsPawsAboveGround() {
        struct Variant {
            var strideLength: Float
            var stepHeight: Float
            var frequency: Float
            var speed: Float
            var referenceSpeed: Float
            var standingHeight: Float
        }
        let variants: [Variant] = [
            Variant(strideLength: 0.8, stepHeight: 0.15, frequency: 1.6, speed: 2.0, referenceSpeed: 2.0, standingHeight: 0.90),
            Variant(strideLength: 1.2, stepHeight: 0.25, frequency: 2.0, speed: 2.0, referenceSpeed: 2.0, standingHeight: 0.85),
            Variant(strideLength: 0.5, stepHeight: 0.10, frequency: 1.2, speed: 1.0, referenceSpeed: 2.0, standingHeight: 0.90),
        ]

        for variant in variants {
            var params = GaitParameters()
            params.strideLength = variant.strideLength
            params.stepHeight = variant.stepHeight
            params.strideFrequency = variant.frequency
            params.referenceSpeed = variant.referenceSpeed
            params.standingHeight = variant.standingHeight
            var engine = makeEngine(parameters: params)

            let dt: Float = 0.008
            let strideDuration = 1 / (variant.frequency * variant.speed / variant.referenceSpeed)
            let steps = Int((params.transitionDuration + strideDuration) / dt) + 2

            var checked = 0
            for _ in 0..<steps {
                engine.update(deltaTime: dt, speed: variant.speed, steering: 0, acceleration: 0, mode: .walk)
                // Only assert once fully deployed — mid-transition poses are
                // blended with the tucked pose and needn't satisfy the clamp.
                guard engine.transitionBlend >= 1 else { continue }
                let poses = engine.jointPoses()
                for leg in LegID.allCases {
                    let paw = pawPosition(leg: leg, pose: poses[leg]!)
                    let groundY = Self.hipOffsets[leg]!.y - variant.standingHeight
                    XCTAssertGreaterThanOrEqual(
                        paw.y, groundY - 1e-3,
                        "leg \(leg) paw at y=\(paw.y) below ground \(groundY) (variant \(variant))"
                    )
                    checked += 1
                }
            }
            XCTAssertGreaterThan(checked, 0, "no fully-deployed steps checked for \(variant)")
        }
    }

    // MARK: - Mode transitions

    func testTransitionBlendEndpointsAndMidpoint() {
        var engine = makeEngine()

        // Fresh engine: exactly drive.
        XCTAssertEqual(engine.transitionBlend, 0)

        // Blend 0 → joint poses equal the tucked pose exactly.
        let initial = engine.jointPoses()
        for leg in LegID.allCases {
            XCTAssertEqual(initial[leg], Self.tucked[leg])
        }

        // Full transition into walk lands exactly at 1.
        engine.update(deltaTime: 0.4, speed: 2.0, steering: 0, acceleration: 0, mode: .walk)
        XCTAssertEqual(engine.transitionBlend, 1)

        // Back to drive lands exactly at 0 and restores the tucked pose.
        engine.update(deltaTime: 0.4, speed: 2.0, steering: 0, acceleration: 0, mode: .drive)
        XCTAssertEqual(engine.transitionBlend, 0)
        let restored = engine.jointPoses()
        for leg in LegID.allCases {
            XCTAssertEqual(restored[leg]?.hip, Self.tucked[leg]?.hip)
            XCTAssertEqual(restored[leg]?.knee, Self.tucked[leg]?.knee)
            XCTAssertEqual(restored[leg]?.ankle, Self.tucked[leg]?.ankle)
        }

        // Half the duration → blend 0.5; smoothstep(0.5) == 0.5 exactly.
        // Use speed 0 so the walk pose is static (phase never advances) and
        // the same engine's fully-deployed pose is an exact slerp target.
        var midway = makeEngine()
        midway.update(deltaTime: 0.2, speed: 0, steering: 0, acceleration: 0, mode: .walk)
        XCTAssertEqual(midway.transitionBlend, 0.5, accuracy: 1e-6)
        let midPose = midway.jointPoses()[.frontLeft]!
        midway.update(deltaTime: 0.2, speed: 0, steering: 0, acceleration: 0, mode: .walk)
        XCTAssertEqual(midway.transitionBlend, 1)
        let deployedPose = midway.jointPoses()[.frontLeft]!

        let expected = simd_slerp(Self.tucked[.frontLeft]!.hip, deployedPose.hip, 0.5)
        XCTAssertEqual(midPose.hip.vector.x, expected.vector.x, accuracy: 1e-5)
        XCTAssertEqual(midPose.hip.vector.y, expected.vector.y, accuracy: 1e-5)
        XCTAssertEqual(midPose.hip.vector.z, expected.vector.z, accuracy: 1e-5)
        XCTAssertEqual(midPose.hip.vector.w, expected.vector.w, accuracy: 1e-5)
    }

    // MARK: - Drive mode

    func testDriveBodyPoseAndWheelSpin() {
        var params = GaitParameters()
        params.wheelRadius = 0.15
        params.drivePitchPerAccel = 0.02
        params.driveRollPerSteering = 0.1
        var engine = makeEngine(parameters: params)

        let dt: Float = 0.016
        let speed: Float = 3.0
        let steps = 10
        var expected: Float = 0
        for _ in 0..<steps {
            engine.update(deltaTime: dt, speed: speed, steering: 0.5, acceleration: 2.0, mode: .drive)
            expected += speed / params.wheelRadius * dt
        }

        for leg in LegID.allCases {
            XCTAssertEqual(
                engine.jointPoses()[leg]!.wheelSpinAngle, expected, accuracy: 1e-4,
                "wheel spin mismatch for \(leg)"
            )
        }

        let body = engine.bodyPose()
        XCTAssertEqual(body.pitch, -params.drivePitchPerAccel * 2.0, accuracy: 1e-6)
        XCTAssertEqual(body.roll, -params.driveRollPerSteering * 0.5, accuracy: 1e-6)
        XCTAssertEqual(body.bobY, 0, accuracy: 1e-6)
    }

    func testWheelSpinFreezesInWalk() {
        var engine = makeEngine()
        engine.update(deltaTime: 0.1, speed: 3.0, steering: 0, acceleration: 0, mode: .drive)
        let before = engine.jointPoses().mapValues { $0.wheelSpinAngle }
        XCTAssertGreaterThan(before[.frontLeft]!, 0)

        // Several walk updates — wheel angles must not change.
        engine.update(deltaTime: 0.1, speed: 3.0, steering: 0, acceleration: 0, mode: .walk)
        engine.update(deltaTime: 0.1, speed: 3.0, steering: 0, acceleration: 0, mode: .walk)
        let after = engine.jointPoses().mapValues { $0.wheelSpinAngle }
        for leg in LegID.allCases {
            XCTAssertEqual(after[leg], before[leg])
        }
    }

    // MARK: - Degenerate input

    func testDegenerateInputProducesNoNaNs() {
        var engine = makeEngine()
        // Zero deltaTime, zero speed, both modes.
        engine.update(deltaTime: 0, speed: 0, steering: 0, acceleration: 0, mode: .drive)
        engine.update(deltaTime: 0, speed: 0, steering: 0, acceleration: 0, mode: .walk)
        engine.update(deltaTime: 0.016, speed: 0, steering: 0, acceleration: 0, mode: .walk)
        engine.update(deltaTime: 0, speed: 0, steering: 0, acceleration: 0, mode: .walk)

        for (leg, pose) in engine.jointPoses() {
            for q in [pose.hip, pose.knee, pose.ankle] {
                XCTAssertTrue(q.vector.x.isFinite, "\(leg) hip/knee/ankle NaN")
                XCTAssertTrue(q.vector.y.isFinite)
                XCTAssertTrue(q.vector.z.isFinite)
                XCTAssertTrue(q.vector.w.isFinite)
            }
            XCTAssertTrue(pose.wheelSpinAngle.isFinite, "\(leg) wheel NaN")
        }
        let body = engine.bodyPose()
        XCTAssertTrue(body.pitch.isFinite)
        XCTAssertTrue(body.roll.isFinite)
        XCTAssertTrue(body.bobY.isFinite)
    }
}
