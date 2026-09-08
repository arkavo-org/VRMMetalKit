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

final class ArmIKLayerTests: XCTestCase {
    private let frame = AnimationContext(time: 0, deltaTime: 1.0 / 60.0)

    private func makeScene() throws -> (VRMModel, AnimationLayerCompositor, ArmIKLayer) {
        let model = try SyntheticHumanoidRig.makeTPose()
        let compositor = AnimationLayerCompositor()
        compositor.setup(model: model)
        let layer = ArmIKLayer()
        compositor.addArmIKLayer(layer, for: model)
        return (model, compositor, layer)
    }

    // MARK: - Hand on target

    func testLeftHandReachesReachableTarget() throws {
        let (model, compositor, layer) = try makeScene()
        let target = SIMD3<Float>(0.45, 1.05, 0.2)
        layer.leftHand = ArmIKLayer.HandTarget(position: target)

        compositor.update(deltaTime: frame.deltaTime, context: frame)

        let hand = SyntheticHumanoidRig.worldPosition(.leftHand, in: model)
        XCTAssertLessThan(simd_distance(hand, target), 0.005, "left hand should land on target, got \(hand)")
        XCTAssertEqual(SyntheticHumanoidRig.worldPosition(.rightHand, in: model).x, -0.65, accuracy: 1e-4,
                       "untargeted right arm must stay at rest")
    }

    func testRightHandReachesReachableTarget() throws {
        let (model, compositor, layer) = try makeScene()
        let target = SIMD3<Float>(-0.45, 1.05, 0.2)
        layer.rightHand = ArmIKLayer.HandTarget(position: target)

        compositor.update(deltaTime: frame.deltaTime, context: frame)

        let hand = SyntheticHumanoidRig.worldPosition(.rightHand, in: model)
        XCTAssertLessThan(simd_distance(hand, target), 0.005, "right hand should land on target, got \(hand)")
    }

    func testTargetIsStableAcrossConsecutiveFrames() throws {
        let (model, compositor, layer) = try makeScene()
        let target = SIMD3<Float>(0.45, 1.05, 0.2)
        layer.leftHand = ArmIKLayer.HandTarget(position: target)

        compositor.update(deltaTime: frame.deltaTime, context: frame)
        let first = SyntheticHumanoidRig.worldPosition(.leftHand, in: model)
        compositor.update(deltaTime: frame.deltaTime, context: frame)
        compositor.update(deltaTime: frame.deltaTime, context: frame)
        let third = SyntheticHumanoidRig.worldPosition(.leftHand, in: model)

        XCTAssertLessThan(simd_distance(first, third), 1e-4, "solution must not drift when re-solved from a posed arm")
        XCTAssertLessThan(simd_distance(third, target), 0.005)
    }

    func testMovingTargetThenReturningReproducesPose() throws {
        let (model, compositor, layer) = try makeScene()
        let a = SIMD3<Float>(0.45, 1.05, 0.2)
        let b = SIMD3<Float>(0.3, 1.3, 0.3)
        layer.leftHand = ArmIKLayer.HandTarget(position: a)
        compositor.update(deltaTime: frame.deltaTime, context: frame)
        let handA = SyntheticHumanoidRig.worldPosition(.leftHand, in: model)

        layer.leftHand = ArmIKLayer.HandTarget(position: b)
        compositor.update(deltaTime: frame.deltaTime, context: frame)
        XCTAssertLessThan(simd_distance(SyntheticHumanoidRig.worldPosition(.leftHand, in: model), b), 0.005)

        layer.leftHand = ArmIKLayer.HandTarget(position: a)
        compositor.update(deltaTime: frame.deltaTime, context: frame)
        XCTAssertLessThan(simd_distance(SyntheticHumanoidRig.worldPosition(.leftHand, in: model), handA), 1e-4)
    }

    func testUnreachableTargetPointsArmTowardTarget() throws {
        let (model, compositor, layer) = try makeScene()
        let target = SIMD3<Float>(0.15, -2.0, 0)
        layer.leftHand = ArmIKLayer.HandTarget(position: target)
        compositor.update(deltaTime: frame.deltaTime, context: frame)

        let shoulder = SyntheticHumanoidRig.worldPosition(.leftUpperArm, in: model)
        let hand = SyntheticHumanoidRig.worldPosition(.leftHand, in: model)
        let dir = simd_normalize(hand - shoulder)
        XCTAssertLessThan(dir.y, -0.99, "arm should hang straight toward the unreachable target")
        XCTAssertEqual(simd_distance(hand, shoulder),
                       SyntheticHumanoidRig.upperArmLength + SyntheticHumanoidRig.forearmLength, accuracy: 0.005)
    }

    func testClearingTargetRestoresRestPose() throws {
        let (model, compositor, layer) = try makeScene()
        layer.leftHand = ArmIKLayer.HandTarget(position: SIMD3<Float>(0.45, 1.05, 0.2))
        compositor.update(deltaTime: frame.deltaTime, context: frame)
        layer.leftHand = nil
        compositor.update(deltaTime: frame.deltaTime, context: frame)

        let hand = SyntheticHumanoidRig.worldPosition(.leftHand, in: model)
        XCTAssertLessThan(simd_distance(hand, SIMD3<Float>(0.65, 1.25, 0)), 1e-4)
    }

    func testTargetWeightBlendsTowardRest() throws {
        let (model, compositor, layer) = try makeScene()
        let target = SIMD3<Float>(0.45, 1.05, 0.2)
        layer.leftHand = ArmIKLayer.HandTarget(position: target, weight: 0.5)
        compositor.update(deltaTime: frame.deltaTime, context: frame)

        let hand = SyntheticHumanoidRig.worldPosition(.leftHand, in: model)
        let rest = SIMD3<Float>(0.65, 1.25, 0)
        XCTAssertGreaterThan(simd_distance(hand, rest), 0.05, "half weight must move the hand off rest")
        XCTAssertGreaterThan(simd_distance(hand, target), 0.05, "half weight must not fully reach the target")
    }

    func testElbowHintChoosesBendPlane() throws {
        let (model, compositor, layer) = try makeScene()
        let target = SIMD3<Float>(0.45, 1.25, 0.1)
        layer.leftHand = ArmIKLayer.HandTarget(position: target, elbowHint: SIMD3<Float>(0, -1, 0))
        compositor.update(deltaTime: frame.deltaTime, context: frame)
        let elbowDown = SyntheticHumanoidRig.worldPosition(.leftLowerArm, in: model)

        layer.leftHand = ArmIKLayer.HandTarget(position: target, elbowHint: SIMD3<Float>(0, 1, 0))
        compositor.update(deltaTime: frame.deltaTime, context: frame)
        let elbowUp = SyntheticHumanoidRig.worldPosition(.leftLowerArm, in: model)

        XCTAssertLessThan(elbowDown.y, 1.25 - 0.02, "elbow should drop below the shoulder line with a downward hint")
        XCTAssertGreaterThan(elbowUp.y, 1.25 + 0.02, "elbow should rise above the shoulder line with an upward hint")
    }

    // MARK: - Fingers

    func testLeftIndexCurlLowersFingertipWithoutMovingHand() throws {
        let (model, compositor, layer) = try makeScene()
        let restTip = SyntheticHumanoidRig.worldPosition(.leftIndexDistal, in: model)
        let restHand = SyntheticHumanoidRig.worldPosition(.leftHand, in: model)

        layer.leftFingers = ArmIKLayer.FingerCurl(index: 1.0)
        compositor.update(deltaTime: frame.deltaTime, context: frame)

        let tip = SyntheticHumanoidRig.worldPosition(.leftIndexDistal, in: model)
        XCTAssertLessThan(tip.y, restTip.y - 0.02, "curled fingertip must drop toward the palm side (-Y)")
        XCTAssertLessThan(tip.x, restTip.x, "curled fingertip must pull back toward the hand")
        XCTAssertLessThan(simd_distance(SyntheticHumanoidRig.worldPosition(.leftHand, in: model), restHand), 1e-5)
        XCTAssertEqual(SyntheticHumanoidRig.worldPosition(.leftMiddleDistal, in: model).y, restTip.y, accuracy: 1e-5,
                       "uncurled fingers stay put")
    }

    func testRightIndexCurlLowersFingertip() throws {
        let (model, compositor, layer) = try makeScene()
        let restTip = SyntheticHumanoidRig.worldPosition(.rightIndexDistal, in: model)

        layer.rightFingers = ArmIKLayer.FingerCurl(index: 1.0)
        compositor.update(deltaTime: frame.deltaTime, context: frame)

        let tip = SyntheticHumanoidRig.worldPosition(.rightIndexDistal, in: model)
        XCTAssertLessThan(tip.y, restTip.y - 0.02)
        XCTAssertGreaterThan(tip.x, restTip.x, "right fingertip pulls back toward the hand (toward +X)")
    }

    func testThumbCurlLowersThumbTip() throws {
        let (model, compositor, layer) = try makeScene()
        let restTip = SyntheticHumanoidRig.worldPosition(.leftThumbDistal, in: model)
        layer.leftFingers = ArmIKLayer.FingerCurl(thumb: 1.0)
        compositor.update(deltaTime: frame.deltaTime, context: frame)
        let tip = SyntheticHumanoidRig.worldPosition(.leftThumbDistal, in: model)
        XCTAssertLessThan(tip.y, restTip.y - 0.01)
    }

    func testClearingFingerCurlRestoresFingers() throws {
        let (model, compositor, layer) = try makeScene()
        let restTip = SyntheticHumanoidRig.worldPosition(.leftIndexDistal, in: model)
        layer.leftFingers = .fist
        compositor.update(deltaTime: frame.deltaTime, context: frame)
        layer.leftFingers = nil
        compositor.update(deltaTime: frame.deltaTime, context: frame)
        XCTAssertLessThan(simd_distance(SyntheticHumanoidRig.worldPosition(.leftIndexDistal, in: model), restTip), 1e-5)
    }

    func testFistCurlsEveryFinger() throws {
        let (model, compositor, layer) = try makeScene()
        let bones: [VRMHumanoidBone] = [.leftIndexDistal, .leftMiddleDistal, .leftRingDistal, .leftLittleDistal, .leftThumbDistal]
        let rest = bones.map { SyntheticHumanoidRig.worldPosition($0, in: model) }
        layer.leftFingers = .fist
        compositor.update(deltaTime: frame.deltaTime, context: frame)
        for (bone, restPos) in zip(bones, rest) {
            XCTAssertLessThan(SyntheticHumanoidRig.worldPosition(bone, in: model).y, restPos.y - 0.01, "\(bone) should curl")
        }
    }

    // MARK: - Layer contract

    func testDisabledLayerLeavesRest() throws {
        let (model, compositor, layer) = try makeScene()
        layer.leftHand = ArmIKLayer.HandTarget(position: SIMD3<Float>(0.45, 1.05, 0.2))
        layer.isEnabled = false
        compositor.update(deltaTime: frame.deltaTime, context: frame)
        XCTAssertLessThan(simd_distance(SyntheticHumanoidRig.worldPosition(.leftHand, in: model), SIMD3<Float>(0.65, 1.25, 0)), 1e-4)
    }

    func testAffectedBonesCoverArmsHandsAndFingers() {
        let layer = ArmIKLayer()
        XCTAssertTrue(layer.affectedBones.isSuperset(of: [.leftUpperArm, .leftLowerArm, .rightUpperArm, .rightLowerArm]))
        XCTAssertTrue(layer.affectedBones.contains(.leftIndexProximal))
        XCTAssertTrue(layer.affectedBones.contains(.rightThumbDistal))
        XCTAssertFalse(layer.affectedBones.contains(.hips))
        XCTAssertGreaterThan(layer.priority, ArmCounterbalanceLayer().priority,
                             "hand targets must win over the counterbalance brace")
    }
}
