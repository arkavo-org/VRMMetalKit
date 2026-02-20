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

final class IKLayerTests: XCTestCase {

    // MARK: - TwoBoneIKSolver Tests

    func testIKSolver_ReachableTarget() {
        let rootPos = SIMD3<Float>(0, 1, 0)
        let midPos = SIMD3<Float>(0, 0.5, 0)
        let endPos = SIMD3<Float>(0, 0, 0)

        let targetPos = SIMD3<Float>(0, 0, 0.3)

        let result = TwoBoneIKSolver.solve(
            rootPos: rootPos,
            midPos: midPos,
            endPos: endPos,
            targetPos: targetPos,
            poleVector: SIMD3<Float>(0, 0, 1)
        )

        XCTAssertNotNil(result, "IK solver should succeed for reachable target")

        if let result = result {
            XCTAssertFalse(result.rootRotation.real.isNaN, "Root rotation should not contain NaN")
            XCTAssertFalse(result.midRotation.real.isNaN, "Mid rotation should not contain NaN")

            let rootLen = simd_length(result.rootRotation.vector)
            let midLen = simd_length(result.midRotation.vector)
            XCTAssertEqual(rootLen, 1.0, accuracy: 0.001, "Root rotation should be unit quaternion")
            XCTAssertEqual(midLen, 1.0, accuracy: 0.001, "Mid rotation should be unit quaternion")
        }
    }

    func testIKSolver_UnreachableTarget_Clamps() {
        let rootPos = SIMD3<Float>(0, 1, 0)
        let midPos = SIMD3<Float>(0, 0.5, 0)
        let endPos = SIMD3<Float>(0, 0, 0)

        let targetPos = SIMD3<Float>(0, -5, 0)

        let result = TwoBoneIKSolver.solve(
            rootPos: rootPos,
            midPos: midPos,
            endPos: endPos,
            targetPos: targetPos,
            poleVector: SIMD3<Float>(0, 0, 1)
        )

        XCTAssertNotNil(result, "IK solver should handle unreachable targets by clamping")

        if let result = result {
            XCTAssertFalse(result.rootRotation.real.isNaN, "Clamped result should not contain NaN")
            XCTAssertFalse(result.midRotation.real.isNaN, "Clamped result should not contain NaN")
        }
    }

    func testIKSolver_PoleVectorConstraint() {
        let rootPos = SIMD3<Float>(0, 1, 0)
        let midPos = SIMD3<Float>(0, 0.5, 0)
        let endPos = SIMD3<Float>(0, 0, 0)

        let targetPos = SIMD3<Float>(0, 0, 0.3)

        let resultForward = TwoBoneIKSolver.solve(
            rootPos: rootPos,
            midPos: midPos,
            endPos: endPos,
            targetPos: targetPos,
            poleVector: SIMD3<Float>(0, 0, 1)
        )

        let resultBackward = TwoBoneIKSolver.solve(
            rootPos: rootPos,
            midPos: midPos,
            endPos: endPos,
            targetPos: targetPos,
            poleVector: SIMD3<Float>(0, 0, -1)
        )

        XCTAssertNotNil(resultForward, "Forward pole vector should produce valid result")
        XCTAssertNotNil(resultBackward, "Backward pole vector should produce valid result")

        if let fwd = resultForward, let bwd = resultBackward {
            let fwdDot = simd_dot(fwd.rootRotation.vector, bwd.rootRotation.vector)
            XCTAssertLessThan(abs(fwdDot), 0.999,
                "Different pole vectors should produce different rotations")
        }
    }

    func testIKSolver_BoneLength() {
        let from = SIMD3<Float>(0, 1, 0)
        let to = SIMD3<Float>(0, 0.5, 0)

        let length = TwoBoneIKSolver.boneLength(from: from, to: to)

        XCTAssertEqual(length, 0.5, accuracy: 0.0001, "Bone length should be 0.5")
    }

    func testIKSolver_ZeroLengthBones_ReturnsNil() {
        let samePos = SIMD3<Float>(0, 1, 0)

        let result = TwoBoneIKSolver.solve(
            rootPos: samePos,
            midPos: samePos,
            endPos: samePos,
            targetPos: SIMD3<Float>(0, 0, 0),
            poleVector: SIMD3<Float>(0, 0, 1)
        )

        XCTAssertNil(result, "Zero-length bones should return nil")
    }

    // MARK: - FootContactDetector Tests

    func testContactDetection_StationaryFoot_Planted() {
        var config = FootContactDetector.Config()
        config.velocityThreshold = 0.05
        config.heightThreshold = 0.02
        config.minFramesInState = 3
        config.groundY = 0.0

        let detector = FootContactDetector(config: config)

        let stationaryPos = SIMD3<Float>(0, 0.01, 0)

        for _ in 0..<10 {
            detector.update(
                leftFootPos: stationaryPos,
                rightFootPos: stationaryPos,
                deltaTime: 1.0 / 60.0
            )
        }

        XCTAssertTrue(detector.isLeftFootPlanted, "Stationary foot near ground should be planted")
        XCTAssertTrue(detector.isRightFootPlanted, "Stationary foot near ground should be planted")
        XCTAssertNotNil(detector.leftFootPlantedPosition, "Planted foot should have locked position")
    }

    func testContactDetection_MovingFoot_NotPlanted() {
        var config = FootContactDetector.Config()
        config.velocityThreshold = 0.05
        config.heightThreshold = 0.02
        config.minFramesInState = 1
        config.groundY = 0.0

        let detector = FootContactDetector(config: config)

        let deltaTime: Float = 1.0 / 60.0

        for i in 0..<10 {
            let x = Float(i) * 0.1
            let movingPos = SIMD3<Float>(x, 0.5, 0)
            detector.update(
                leftFootPos: movingPos,
                rightFootPos: movingPos,
                deltaTime: deltaTime
            )
        }

        XCTAssertFalse(detector.isLeftFootPlanted, "Fast moving foot should not be planted")
        XCTAssertFalse(detector.isRightFootPlanted, "Fast moving foot should not be planted")
    }

    func testContactDetection_HighFoot_NotPlanted() {
        var config = FootContactDetector.Config()
        config.velocityThreshold = 0.05
        config.heightThreshold = 0.02
        config.minFramesInState = 1
        config.groundY = 0.0

        let detector = FootContactDetector(config: config)

        let highPos = SIMD3<Float>(0, 0.5, 0)

        for _ in 0..<10 {
            detector.update(
                leftFootPos: highPos,
                rightFootPos: highPos,
                deltaTime: 1.0 / 60.0
            )
        }

        XCTAssertFalse(detector.isLeftFootPlanted, "Foot high above ground should not be planted")
    }

    func testContactDetection_Hysteresis() {
        var config = FootContactDetector.Config()
        config.velocityThreshold = 0.05
        config.heightThreshold = 0.02
        config.minFramesInState = 5
        config.groundY = 0.0

        let detector = FootContactDetector(config: config)

        let stationaryPos = SIMD3<Float>(0, 0.01, 0)
        let movingPos = SIMD3<Float>(0.5, 0.01, 0)

        for _ in 0..<10 {
            detector.update(leftFootPos: stationaryPos, rightFootPos: stationaryPos, deltaTime: 1.0 / 60.0)
        }

        let wasPlanted = detector.isLeftFootPlanted

        detector.update(leftFootPos: movingPos, rightFootPos: movingPos, deltaTime: 1.0 / 60.0)

        XCTAssertEqual(detector.isLeftFootPlanted, wasPlanted,
            "Single frame of movement should not immediately unplant due to hysteresis")
    }

    func testContactDetection_Reset() {
        let detector = FootContactDetector()

        let stationaryPos = SIMD3<Float>(0, 0.01, 0)
        for _ in 0..<10 {
            detector.update(leftFootPos: stationaryPos, rightFootPos: stationaryPos, deltaTime: 1.0 / 60.0)
        }

        detector.reset()

        XCTAssertFalse(detector.isLeftFootPlanted, "Reset should clear planted state")
        XCTAssertNil(detector.leftFootPlantedPosition, "Reset should clear planted position")
    }

    // MARK: - IKLayer Tests

    func testIKLayer_Identifier() {
        let layer = IKLayer()
        XCTAssertEqual(layer.identifier, "footIK")
    }

    func testIKLayer_Priority() {
        let layer = IKLayer()
        XCTAssertEqual(layer.priority, 4, "IK layer should have priority 4 (after other layers)")
    }

    func testIKLayer_AffectedBones() {
        let layer = IKLayer()
        let expected: Set<VRMHumanoidBone> = [
            .leftUpperLeg, .leftLowerLeg, .leftFoot,
            .rightUpperLeg, .rightLowerLeg, .rightFoot
        ]
        XCTAssertEqual(layer.affectedBones, expected)
    }

    func testIKLayer_DefaultValues() {
        let layer = IKLayer()
        XCTAssertTrue(layer.isEnabled)
        XCTAssertEqual(layer.strideScale, 1.0)
        XCTAssertEqual(layer.ikBlendWeight, 1.0)
    }

    func testIKLayer_DisabledProducesEmptyOutput() {
        let layer = IKLayer()
        layer.isEnabled = false

        let context = AnimationContext(time: 0, deltaTime: 1.0 / 60.0)
        layer.update(deltaTime: context.deltaTime, context: context)
        let output = layer.evaluate()

        XCTAssertTrue(output.bones.isEmpty, "Disabled layer should produce empty output")
    }

    func testIKLayer_ZeroBlendWeightProducesEmptyOutput() {
        let layer = IKLayer()
        layer.ikBlendWeight = 0

        let context = AnimationContext(time: 0, deltaTime: 1.0 / 60.0)
        layer.update(deltaTime: context.deltaTime, context: context)
        let output = layer.evaluate()

        XCTAssertTrue(output.bones.isEmpty, "Zero blend weight should produce empty output")
    }

    func testIKLayer_Reset() {
        let layer = IKLayer()

        layer.reset()

        let context = AnimationContext(time: 0, deltaTime: 1.0 / 60.0)
        layer.update(deltaTime: context.deltaTime, context: context)
        let output = layer.evaluate()

        XCTAssertTrue(output.bones.isEmpty, "Reset layer with no model should produce empty output")
    }

    func testIKLayer_ContactConfigAccessor() {
        let layer = IKLayer()

        layer.contactConfig.velocityThreshold = 0.1
        layer.contactConfig.heightThreshold = 0.05

        XCTAssertEqual(layer.contactConfig.velocityThreshold, 0.1)
        XCTAssertEqual(layer.contactConfig.heightThreshold, 0.05)
    }

    func testIKLayer_KneeForwardDirection() {
        let layer = IKLayer()

        let defaultDir = layer.kneeForwardDirection
        XCTAssertEqual(defaultDir, SIMD3<Float>(0, 0, 1), "Default knee forward should be +Z")

        layer.kneeForwardDirection = SIMD3<Float>(0, 0, -1)
        XCTAssertEqual(layer.kneeForwardDirection, SIMD3<Float>(0, 0, -1))
    }

    func testIKLayer_DefaultGroundingMode() {
        let layer = IKLayer()
        switch layer.groundingMode {
        case .walkCycle:
            break // expected
        case .idleGrounding:
            XCTFail("Default grounding mode should be .walkCycle")
        }
    }

    func testIKLayer_GroundingModeSettable() {
        let layer = IKLayer()
        layer.groundingMode = .idleGrounding
        switch layer.groundingMode {
        case .idleGrounding:
            break // expected
        case .walkCycle:
            XCTFail("Grounding mode should be .idleGrounding after setting")
        }
    }

    // MARK: - Compositor Bone Accessor Tests

    func testCompositor_GetCompositedBoneRotation_ReturnsNilBeforeUpdate() {
        let compositor = AnimationLayerCompositor()
        XCTAssertNil(compositor.getCompositedBoneRotation(.head),
            "Should return nil when no layers have been evaluated")
    }

    func testCompositor_GetCompositedBoneRotation_ReturnsValueAfterUpdate() {
        let compositor = AnimationLayerCompositor()
        let model = createMinimalModel()
        compositor.setup(model: model)
        let mockLayer = MockBoneLayer(bone: .head, rotation: simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0)))
        compositor.addLayer(mockLayer)

        let context = AnimationContext(time: 0, deltaTime: 1.0 / 60.0)
        compositor.update(deltaTime: context.deltaTime, context: context)

        let result = compositor.getCompositedBoneRotation(.head)
        XCTAssertNotNil(result, "Should return rotation after layer evaluation")
    }

    func testCompositor_GetCompositedBoneRotation_UnaffectedBoneReturnsNil() {
        let compositor = AnimationLayerCompositor()
        let model = createMinimalModel()
        compositor.setup(model: model)
        let mockLayer = MockBoneLayer(bone: .head, rotation: simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0)))
        compositor.addLayer(mockLayer)

        let context = AnimationContext(time: 0, deltaTime: 1.0 / 60.0)
        compositor.update(deltaTime: context.deltaTime, context: context)

        XCTAssertNil(compositor.getCompositedBoneRotation(.hips),
            "Bone not affected by any layer should return nil")
    }

    // MARK: - Helpers

    private func createMinimalModel() -> VRMModel {
        let json = #"{"asset":{"version":"2.0"}}"#
        let gltf = try! JSONDecoder().decode(GLTFDocument.self, from: Data(json.utf8))
        return VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: ""), humanoid: nil, gltf: gltf)
    }
}

// MARK: - Mock Layer for Compositor Tests

private final class MockBoneLayer: AnimationLayer {
    let identifier: String = "mockBone"
    let priority: Int = 1
    var isEnabled: Bool = true
    let affectedBones: Set<VRMHumanoidBone>

    private let bone: VRMHumanoidBone
    private let rotation: simd_quatf

    init(bone: VRMHumanoidBone, rotation: simd_quatf) {
        self.bone = bone
        self.rotation = rotation
        self.affectedBones = [bone]
    }

    func update(deltaTime: Float, context: AnimationContext) {}

    func evaluate() -> LayerOutput {
        LayerOutput(bones: [bone: ProceduralBoneTransform(rotation: rotation)])
    }
}
