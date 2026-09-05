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

/// Geometric direction checks for the look-at paths. VRMC_vrm-1.0 lookAt.md:
/// "Yaw: Z-> X direction => Left", "Pitch: Y-> Z direction => Down", and the
/// range-map table assigns `rangeMapHorizontalOuter` to the left eye when
/// looking left (yaw > 0) and to the right eye when looking right (yaw < 0).
/// These tests rotate +Z (the model's forward) by the produced eye rotation
/// and check where it ends up, so a sign error is caught regardless of how the
/// internal angles are labelled.
final class VRMLookAtDirectionTests: XCTestCase {
    private func makeMinimalGLTF() throws -> GLTFDocument {
        let data = try JSONSerialization.data(withJSONObject: ["asset": ["version": "2.0", "generator": "Test"]])
        return try JSONDecoder().decode(GLTFDocument.self, from: data)
    }

    private func makeNode(index: Int, name: String) throws -> VRMNode {
        let data = try JSONSerialization.data(withJSONObject: ["name": name])
        return VRMNode(index: index, gltfNode: try JSONDecoder().decode(GLTFNode.self, from: data))
    }

    /// 1:1 range maps so the produced eye angle equals the input angle.
    private func unitLookAt() -> VRMLookAt {
        let lookAt = VRMLookAt()
        let unit = VRMLookAtRangeMap(inputMaxValue: 90, outputScale: 90)
        lookAt.rangeMapHorizontalInner = unit
        lookAt.rangeMapHorizontalOuter = unit
        lookAt.rangeMapVerticalUp = unit
        lookAt.rangeMapVerticalDown = unit
        return lookAt
    }

    /// Head at the origin with identity-rest eyes, bone mode, instant smoothing.
    private func makeBoneRig(lookAt: VRMLookAt? = nil) throws
        -> (model: VRMModel, controller: VRMLookAtController, leftEye: VRMNode, rightEye: VRMNode) {
        let lookAt = lookAt ?? unitLookAt()
        let head = try makeNode(index: 0, name: "head")
        let leftEye = try makeNode(index: 1, name: "leftEye")
        let rightEye = try makeNode(index: 2, name: "rightEye")
        let humanoid = VRMHumanoid()
        humanoid.humanBones[.head] = VRMHumanoid.VRMHumanBone(node: 0)
        humanoid.humanBones[.leftEye] = VRMHumanoid.VRMHumanBone(node: 1)
        humanoid.humanBones[.rightEye] = VRMHumanoid.VRMHumanBone(node: 2)
        let model = VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: ""), humanoid: humanoid, gltf: try makeMinimalGLTF())
        model.nodes = [head, leftEye, rightEye]
        lookAt.type = .bone
        model.lookAt = lookAt

        let controller = VRMLookAtController()
        controller.smoothing = 0
        controller.saccadeEnabled = false
        controller.setup(model: model)
        controller.mode = .bone
        // The controller only holds the model weakly; callers keep it alive.
        return (model, controller, leftEye, rightEye)
    }

    private func gaze(_ node: VRMNode) -> SIMD3<Float> {
        node.rotation.act(SIMD3<Float>(0, 0, 1))
    }

    private func yawDegrees(_ node: VRMNode) -> Float {
        let g = gaze(node)
        return atan2(g.x, g.z) * 180 / .pi
    }

    // MARK: Bone mode

    func testBoneModeTargetAboveHeadPitchesEyesUp() throws {
        let rig = try makeBoneRig()
        rig.controller.target = .point(SIMD3<Float>(0, 1, 1))
        rig.controller.update(deltaTime: 1.0 / 60.0)

        XCTAssertGreaterThan(gaze(rig.leftEye).y, 0.3, "left eye should look up, gaze \(gaze(rig.leftEye))")
        XCTAssertGreaterThan(gaze(rig.rightEye).y, 0.3, "right eye should look up, gaze \(gaze(rig.rightEye))")
    }

    func testBoneModeTargetBelowHeadPitchesEyesDown() throws {
        let rig = try makeBoneRig()
        rig.controller.target = .point(SIMD3<Float>(0, -1, 1))
        rig.controller.update(deltaTime: 1.0 / 60.0)

        XCTAssertLessThan(gaze(rig.leftEye).y, -0.3, "left eye should look down, gaze \(gaze(rig.leftEye))")
        XCTAssertLessThan(gaze(rig.rightEye).y, -0.3, "right eye should look down, gaze \(gaze(rig.rightEye))")
    }

    func testBoneModeTargetOnModelLeftTurnsEyesTowardPositiveX() throws {
        let rig = try makeBoneRig()
        rig.controller.target = .point(SIMD3<Float>(1, 0, 1))
        rig.controller.update(deltaTime: 1.0 / 60.0)

        XCTAssertGreaterThan(gaze(rig.leftEye).x, 0.3, "left eye should turn toward +X, gaze \(gaze(rig.leftEye))")
        XCTAssertGreaterThan(gaze(rig.rightEye).x, 0.3, "right eye should turn toward +X, gaze \(gaze(rig.rightEye))")
    }

    func testThinkingStateBiasesGazeUpward() throws {
        let rig = try makeBoneRig()
        rig.controller.target = .point(SIMD3<Float>(0, 0, 1))
        rig.controller.state = .thinking
        rig.controller.update(deltaTime: 1.0 / 60.0)

        XCTAssertGreaterThan(gaze(rig.leftEye).y, 0.05, "thinking should look up and away, gaze \(gaze(rig.leftEye))")
    }

    /// Looking left: the left eye swings outward (outer map), the right eye
    /// inward (inner map). Looking right mirrors that. Distinct output scales
    /// make the selected map observable.
    func testHorizontalRangeMapSelectionPerEye() throws {
        func makeLookAt() -> VRMLookAt {
            let lookAt = VRMLookAt()
            lookAt.rangeMapHorizontalInner = VRMLookAtRangeMap(inputMaxValue: 90, outputScale: 5)
            lookAt.rangeMapHorizontalOuter = VRMLookAtRangeMap(inputMaxValue: 90, outputScale: 15)
            return lookAt
        }

        let left = try makeBoneRig(lookAt: makeLookAt())
        left.controller.target = .point(SIMD3<Float>(1, 0, 0))
        left.controller.update(deltaTime: 1.0 / 60.0)
        XCTAssertEqual(yawDegrees(left.leftEye), 15, accuracy: 0.1, "looking left: left eye uses the outer map")
        XCTAssertEqual(yawDegrees(left.rightEye), 5, accuracy: 0.1, "looking left: right eye uses the inner map")

        let right = try makeBoneRig(lookAt: makeLookAt())
        right.controller.target = .point(SIMD3<Float>(-1, 0, 0))
        right.controller.update(deltaTime: 1.0 / 60.0)
        XCTAssertEqual(yawDegrees(right.leftEye), -5, accuracy: 0.1, "looking right: left eye uses the inner map")
        XCTAssertEqual(yawDegrees(right.rightEye), -15, accuracy: 0.1, "looking right: right eye uses the outer map")
    }

    // MARK: AR look-at layer

    func testARLookAtLayerCameraAboveTiltsHeadUp() {
        let layer = ARLookAtLayer()
        layer.saccadeEnabled = false
        layer.smoothingFactor = 1
        let context = AnimationContext(cameraPosition: layer.headOffset + SIMD3<Float>(0, 1, 1))
        layer.update(deltaTime: 1.0 / 60.0, context: context)

        let head = layer.evaluate().bones[.head]!.rotation.act(SIMD3<Float>(0, 0, 1))
        XCTAssertGreaterThan(head.y, 0.1, "camera above the head should tilt the head up, forward \(head)")
    }

    func testARLookAtLayerCameraOnModelLeftTurnsHeadTowardPositiveX() {
        let layer = ARLookAtLayer()
        layer.saccadeEnabled = false
        layer.smoothingFactor = 1
        let context = AnimationContext(cameraPosition: layer.headOffset + SIMD3<Float>(1, 0, 1))
        layer.update(deltaTime: 1.0 / 60.0, context: context)

        let head = layer.evaluate().bones[.head]!.rotation.act(SIMD3<Float>(0, 0, 1))
        XCTAssertGreaterThan(head.x, 0.1, "camera on the model's left should turn the head toward +X, forward \(head)")
    }
}
