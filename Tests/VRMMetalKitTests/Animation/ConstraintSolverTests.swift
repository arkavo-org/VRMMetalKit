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

/// Tests for the VRM Node Constraint System (Twist Bones)
///
/// These tests verify:
/// 1. Constraint parsing from VRM 1.0 VRMC_node_constraint
/// 2. Constraint synthesis for VRM 0.0 models with twist bones
/// 3. Roll constraint solving (swing-twist decomposition)
/// 4. Integration with AnimationPlayer
final class ConstraintSolverTests: XCTestCase {

    private var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    override func tearDown() {
        device = nil
    }

    // MARK: - Constraint Type Tests

    func testRollConstraintCreation() {
        let constraint = VRMNodeConstraint(
            targetNode: 10,
            constraint: .roll(sourceNode: 5, axis: SIMD3<Float>(1, 0, 0), weight: 0.5)
        )

        XCTAssertEqual(constraint.targetNode, 10)

        if case .roll(let sourceNode, let axis, let weight) = constraint.constraint {
            XCTAssertEqual(sourceNode, 5)
            XCTAssertEqual(axis, SIMD3<Float>(1, 0, 0))
            XCTAssertEqual(weight, 0.5)
        } else {
            XCTFail("Expected roll constraint")
        }
    }

    func testAimConstraintCreation() {
        let constraint = VRMNodeConstraint(
            targetNode: 15,
            constraint: .aim(sourceNode: 10, aimAxis: SIMD3<Float>(0, 0, 1), weight: 1.0)
        )

        XCTAssertEqual(constraint.targetNode, 15)

        if case .aim(let sourceNode, let aimAxis, let weight) = constraint.constraint {
            XCTAssertEqual(sourceNode, 10)
            XCTAssertEqual(aimAxis, SIMD3<Float>(0, 0, 1))
            XCTAssertEqual(weight, 1.0)
        } else {
            XCTFail("Expected aim constraint")
        }
    }

    func testRotationConstraintCreation() {
        let constraint = VRMNodeConstraint(
            targetNode: 20,
            constraint: .rotation(sourceNode: 15, weight: 0.75)
        )

        XCTAssertEqual(constraint.targetNode, 20)

        if case .rotation(let sourceNode, let weight) = constraint.constraint {
            XCTAssertEqual(sourceNode, 15)
            XCTAssertEqual(weight, 0.75)
        } else {
            XCTFail("Expected rotation constraint")
        }
    }

    // MARK: - ConstraintSolver Tests

    func testRollConstraintSolverIdentityInput() throws {
        let solver = ConstraintSolver()

        let sourceNode = try createTestNode(index: 0, name: "source")
        let targetNode = try createTestNode(index: 1, name: "target")
        sourceNode.rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        targetNode.rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

        let constraint = VRMNodeConstraint(
            targetNode: 1,
            constraint: .roll(sourceNode: 0, axis: SIMD3<Float>(1, 0, 0), weight: 0.5)
        )

        solver.solve(constraints: [constraint], nodes: [sourceNode, targetNode])

        XCTAssertEqual(targetNode.rotation.real, 1.0, accuracy: 0.001)
        XCTAssertEqual(simd_length(targetNode.rotation.imag), 0.0, accuracy: 0.001)
    }

    func testRollConstraintSolverTransfersTwist() throws {
        let solver = ConstraintSolver()

        let sourceNode = try createTestNode(index: 0, name: "source")
        let targetNode = try createTestNode(index: 1, name: "target")

        let angle: Float = .pi / 2
        sourceNode.rotation = simd_quatf(angle: angle, axis: SIMD3<Float>(1, 0, 0))
        targetNode.rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

        let constraint = VRMNodeConstraint(
            targetNode: 1,
            constraint: .roll(sourceNode: 0, axis: SIMD3<Float>(1, 0, 0), weight: 0.5)
        )

        solver.solve(constraints: [constraint], nodes: [sourceNode, targetNode])

        let expectedAngle = angle * 0.5
        let axisAngle = 2 * acos(targetNode.rotation.real)

        XCTAssertEqual(axisAngle, expectedAngle, accuracy: 0.01,
                      "Twist should be 50% of source rotation")
    }

    func testRollConstraintIgnoresSwing() throws {
        let solver = ConstraintSolver()

        let sourceNode = try createTestNode(index: 0, name: "source")
        let targetNode = try createTestNode(index: 1, name: "target")

        sourceNode.rotation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 1, 0))
        targetNode.rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

        let constraint = VRMNodeConstraint(
            targetNode: 1,
            constraint: .roll(sourceNode: 0, axis: SIMD3<Float>(1, 0, 0), weight: 0.5)
        )

        solver.solve(constraints: [constraint], nodes: [sourceNode, targetNode])

        XCTAssertEqual(targetNode.rotation.real, 1.0, accuracy: 0.01,
                      "Rotation around Y should not affect X-axis roll")
        XCTAssertEqual(simd_length(targetNode.rotation.imag), 0.0, accuracy: 0.01)
    }

    func testRollConstraintCombinedRotation() throws {
        let solver = ConstraintSolver()

        let sourceNode = try createTestNode(index: 0, name: "source")
        let targetNode = try createTestNode(index: 1, name: "target")

        let twistAngle: Float = .pi / 3
        let swingAngle: Float = .pi / 4
        let twistRot = simd_quatf(angle: twistAngle, axis: SIMD3<Float>(1, 0, 0))
        let swingRot = simd_quatf(angle: swingAngle, axis: SIMD3<Float>(0, 1, 0))
        sourceNode.rotation = swingRot * twistRot

        targetNode.rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

        let constraint = VRMNodeConstraint(
            targetNode: 1,
            constraint: .roll(sourceNode: 0, axis: SIMD3<Float>(1, 0, 0), weight: 0.5)
        )

        solver.solve(constraints: [constraint], nodes: [sourceNode, targetNode])

        XCTAssertNotEqual(targetNode.rotation.real, 1.0,
                         "Target should have some rotation from the twist component")

        let targetAxisAngle = 2 * acos(targetNode.rotation.real)
        let expectedAngle = twistAngle * 0.5

        XCTAssertEqual(targetAxisAngle, expectedAngle, accuracy: 0.1,
                      "Should transfer approximately 50% of the twist component")
    }

    // MARK: - Twist Bone Enum Tests

    func testTwistBonesExistInEnum() {
        let twistBones: [VRMHumanoidBone] = [
            .leftUpperArmTwist, .rightUpperArmTwist,
            .leftLowerArmTwist, .rightLowerArmTwist,
            .leftUpperLegTwist, .rightUpperLegTwist,
            .leftLowerLegTwist, .rightLowerLegTwist
        ]

        for bone in twistBones {
            XCTAssertFalse(bone.rawValue.isEmpty, "\(bone) should have a raw value")
            XCTAssertFalse(bone.isRequired, "Twist bones should not be required")
        }
    }

    func testTwistBoneRawValues() {
        XCTAssertEqual(VRMHumanoidBone.leftUpperArmTwist.rawValue, "leftUpperArmTwist")
        XCTAssertEqual(VRMHumanoidBone.rightUpperArmTwist.rawValue, "rightUpperArmTwist")
        XCTAssertEqual(VRMHumanoidBone.leftLowerArmTwist.rawValue, "leftLowerArmTwist")
        XCTAssertEqual(VRMHumanoidBone.rightLowerArmTwist.rawValue, "rightLowerArmTwist")
        XCTAssertEqual(VRMHumanoidBone.leftUpperLegTwist.rawValue, "leftUpperLegTwist")
        XCTAssertEqual(VRMHumanoidBone.rightUpperLegTwist.rawValue, "rightUpperLegTwist")
        XCTAssertEqual(VRMHumanoidBone.leftLowerLegTwist.rawValue, "leftLowerLegTwist")
        XCTAssertEqual(VRMHumanoidBone.rightLowerLegTwist.rawValue, "rightLowerLegTwist")
    }

    // MARK: - Constraint Synthesis Tests

    func testSynthesizeTwistConstraintsForVRM0() throws {
        let parser = VRMExtensionParser()
        let humanoid = VRMHumanoid()

        humanoid.humanBones[.leftUpperArm] = VRMHumanoid.VRMHumanBone(node: 10)
        humanoid.humanBones[.leftUpperArmTwist] = VRMHumanoid.VRMHumanBone(node: 11)
        humanoid.humanBones[.rightUpperArm] = VRMHumanoid.VRMHumanBone(node: 20)
        humanoid.humanBones[.rightUpperArmTwist] = VRMHumanoid.VRMHumanBone(node: 21)

        let gltfDoc = try createMinimalGLTFDocument()

        let constraints = parser.parseOrSynthesizeConstraints(gltf: gltfDoc, humanoid: humanoid, isVRM0: true)

        XCTAssertEqual(constraints.count, 2, "Should synthesize 2 constraints for arm twist bones")

        let leftTwistConstraint = constraints.first { $0.targetNode == 11 }
        XCTAssertNotNil(leftTwistConstraint)

        if case .roll(let sourceNode, let axis, let weight) = leftTwistConstraint?.constraint {
            XCTAssertEqual(sourceNode, 10)
            XCTAssertEqual(axis, SIMD3<Float>(-1, 0, 0),
                           "VRM 0.0 arm twist X axis must be negated (N6: coordinate flip for 180° Y rotation)")
            XCTAssertEqual(weight, 0.5)
        } else {
            XCTFail("Expected roll constraint for left arm twist")
        }
    }

    func testNoConstraintsSynthesizedWithoutTwistBones() throws {
        let parser = VRMExtensionParser()
        let humanoid = VRMHumanoid()

        humanoid.humanBones[.leftUpperArm] = VRMHumanoid.VRMHumanBone(node: 10)
        humanoid.humanBones[.rightUpperArm] = VRMHumanoid.VRMHumanBone(node: 20)

        let gltfDoc = try createMinimalGLTFDocument()

        let constraints = parser.parseOrSynthesizeConstraints(gltf: gltfDoc, humanoid: humanoid, isVRM0: true)

        XCTAssertEqual(constraints.count, 0, "Should not synthesize constraints without twist bones")
    }

    // MARK: - Integration Tests

    func testConstraintsIntegratedInModel() async throws {
        let vrmDocument = try VRMBuilder()
            .setSkeleton(.defaultHumanoid)
            .build()

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("vrm")

        try vrmDocument.serialize(to: tempURL)
        let model = try await VRMModel.load(from: tempURL, device: device)
        try? FileManager.default.removeItem(at: tempURL)

        XCTAssertNotNil(model.nodeConstraints)
    }

    // MARK: - D4: Roll Weight Default

    func testRollConstraintDefaultWeightIsOne() throws {
        let parser = VRMExtensionParser()

        let constraintJSON = """
        {
            "asset": {"version": "2.0", "generator": "Test"},
            "nodes": [
                {
                    "name": "source"
                },
                {
                    "name": "target",
                    "extensions": {
                        "VRMC_node_constraint": {
                            "specVersion": "1.0",
                            "constraint": {
                                "roll": {
                                    "source": 0,
                                    "rollAxis": "X"
                                }
                            }
                        }
                    }
                }
            ]
        }
        """
        let data = constraintJSON.data(using: .utf8)!
        let gltf = try JSONDecoder().decode(GLTFDocument.self, from: data)

        let constraints = parser.parseOrSynthesizeConstraints(gltf: gltf, humanoid: nil, isVRM0: false)
        XCTAssertEqual(constraints.count, 1, "Should parse one roll constraint")

        if case .roll(_, _, let weight) = constraints.first?.constraint {
            XCTAssertEqual(weight, 1.0, accuracy: 0.0001,
                           "Roll constraint weight default must be 1.0 per VRMC_node_constraint-1.0 spec")
        } else {
            XCTFail("Expected a roll constraint")
        }
    }

    // MARK: - D1: Aim Constraint

    func testAimConstraintAlreadyAligned() throws {
        let solver = ConstraintSolver()

        let sourceNode = try createTestNode(index: 0, name: "source")
        let targetNode = try createTestNode(index: 1, name: "target")

        // source at +X from target
        sourceNode.translation = SIMD3<Float>(1, 0, 0)
        sourceNode.updateLocalMatrix()
        sourceNode.updateWorldTransform()
        targetNode.updateLocalMatrix()
        targetNode.updateWorldTransform()

        // aimAxis = +X, source is at +X: already aligned → rotation should be identity
        let constraint = VRMNodeConstraint(
            targetNode: 1,
            constraint: .aim(sourceNode: 0, aimAxis: SIMD3<Float>(1, 0, 0), weight: 1.0)
        )

        solver.solve(constraints: [constraint], nodes: [sourceNode, targetNode])

        XCTAssertEqual(targetNode.rotation.real, 1.0, accuracy: 0.01,
                       "Aim constraint: already aligned → identity rotation")
        XCTAssertEqual(simd_length(targetNode.rotation.imag), 0.0, accuracy: 0.01,
                       "Aim constraint: already aligned → zero imaginary part")
    }

    func testAimConstraintRotatesXtowardY() throws {
        let solver = ConstraintSolver()

        let sourceNode = try createTestNode(index: 0, name: "source")
        let targetNode = try createTestNode(index: 1, name: "target")

        // target at origin, source at +Y
        sourceNode.translation = SIMD3<Float>(0, 1, 0)
        sourceNode.updateLocalMatrix()
        sourceNode.updateWorldTransform()
        targetNode.updateLocalMatrix()
        targetNode.updateWorldTransform()

        // aimAxis = +X; source is at +Y → must rotate X toward Y (90° around +Z)
        let constraint = VRMNodeConstraint(
            targetNode: 1,
            constraint: .aim(sourceNode: 0, aimAxis: SIMD3<Float>(1, 0, 0), weight: 1.0)
        )

        solver.solve(constraints: [constraint], nodes: [sourceNode, targetNode])

        // Expected: ~90° rotation around Z axis
        let angle = 2 * acos(min(abs(targetNode.rotation.real), 1.0))
        XCTAssertEqual(angle, Float.pi / 2, accuracy: 0.05,
                       "Aim constraint: aimAxis +X toward source at +Y should be ~90 degrees")

        // The rotation axis should be approximately +Z (or -Z with negative quaternion)
        let normalizedImag = simd_normalize(targetNode.rotation.imag)
        let zComponent = abs(normalizedImag.z)
        XCTAssertGreaterThan(zComponent, 0.95,
                             "Aim constraint: rotation axis should be approximately ±Z")
    }

    func testAimConstraintWeightBlend() throws {
        let solver = ConstraintSolver()

        let sourceNode = try createTestNode(index: 0, name: "source")
        let targetNode = try createTestNode(index: 1, name: "target")

        sourceNode.translation = SIMD3<Float>(0, 1, 0)
        sourceNode.updateLocalMatrix()
        sourceNode.updateWorldTransform()
        targetNode.updateLocalMatrix()
        targetNode.updateWorldTransform()

        let constraint = VRMNodeConstraint(
            targetNode: 1,
            constraint: .aim(sourceNode: 0, aimAxis: SIMD3<Float>(1, 0, 0), weight: 0.5)
        )

        solver.solve(constraints: [constraint], nodes: [sourceNode, targetNode])

        let angle = 2 * acos(min(abs(targetNode.rotation.real), 1.0))
        XCTAssertEqual(angle, Float.pi / 4, accuracy: 0.05,
                       "Aim constraint with weight=0.5 should produce ~45 degrees")
    }

    // MARK: - D2: Rotation Constraint

    func testRotationConstraintCopiesSourceRotation() throws {
        let solver = ConstraintSolver()

        let sourceNode = try createTestNode(index: 0, name: "source")
        let targetNode = try createTestNode(index: 1, name: "target")

        let sourceRot = simd_quatf(angle: Float.pi / 3, axis: SIMD3<Float>(0, 1, 0))
        sourceNode.rotation = sourceRot

        let constraint = VRMNodeConstraint(
            targetNode: 1,
            constraint: .rotation(sourceNode: 0, weight: 1.0)
        )

        solver.solve(constraints: [constraint], nodes: [sourceNode, targetNode])

        XCTAssertEqual(targetNode.rotation.real, sourceRot.real, accuracy: 0.001,
                       "Rotation constraint with weight=1 must copy source rotation exactly (real)")
        XCTAssertEqual(targetNode.rotation.imag.x, sourceRot.imag.x, accuracy: 0.001,
                       "Rotation constraint: imag.x must match")
        XCTAssertEqual(targetNode.rotation.imag.y, sourceRot.imag.y, accuracy: 0.001,
                       "Rotation constraint: imag.y must match")
        XCTAssertEqual(targetNode.rotation.imag.z, sourceRot.imag.z, accuracy: 0.001,
                       "Rotation constraint: imag.z must match")
    }

    func testRotationConstraintWeightBlend() throws {
        let solver = ConstraintSolver()

        let sourceNode = try createTestNode(index: 0, name: "source")
        let targetNode = try createTestNode(index: 1, name: "target")

        sourceNode.rotation = simd_quatf(angle: Float.pi / 2, axis: SIMD3<Float>(0, 1, 0))

        let constraint = VRMNodeConstraint(
            targetNode: 1,
            constraint: .rotation(sourceNode: 0, weight: 0.5)
        )

        solver.solve(constraints: [constraint], nodes: [sourceNode, targetNode])

        let angle = 2 * acos(min(abs(targetNode.rotation.real), 1.0))
        XCTAssertEqual(angle, Float.pi / 4, accuracy: 0.05,
                       "Rotation constraint with weight=0.5 should produce ~45 degrees")
    }

    // MARK: - D3: Topological Sort + Cycle Detection

    func testConstraintTopologicalOrderReverseDeclaration() throws {
        let solver = ConstraintSolver()

        // Three nodes: 0 (root, no constraint), 1 (constrained to 0), 2 (constrained to 1)
        let node0 = try createTestNode(index: 0, name: "root")
        let node1 = try createTestNode(index: 1, name: "mid")
        let node2 = try createTestNode(index: 2, name: "leaf")

        // Give node0 a rotation, which should propagate through constraints
        node0.rotation = simd_quatf(angle: Float.pi / 2, axis: SIMD3<Float>(0, 1, 0))

        // Declare constraints in reverse dependency order: leaf first, then mid
        // Correct order to solve: constrain node1 from node0 first, then node2 from node1
        let constraintLeaf = VRMNodeConstraint(
            targetNode: 2,
            constraint: .rotation(sourceNode: 1, weight: 1.0)
        )
        let constraintMid = VRMNodeConstraint(
            targetNode: 1,
            constraint: .rotation(sourceNode: 0, weight: 1.0)
        )

        // Declared in wrong order (leaf before mid)
        solver.solve(constraints: [constraintLeaf, constraintMid], nodes: [node0, node1, node2])

        // After topo sort: mid must be solved before leaf
        // node1 should have node0's rotation
        XCTAssertEqual(node1.rotation.real, node0.rotation.real, accuracy: 0.001,
                       "Topo sort: node1 must be solved after node0, copying node0's rotation")
        // node2 should have node1's (now updated) rotation = node0's rotation
        XCTAssertEqual(node2.rotation.real, node0.rotation.real, accuracy: 0.001,
                       "Topo sort: node2 must be solved after node1, propagating node0's rotation")
    }

    func testConstraintCycleDoesNotCrash() throws {
        let solver = ConstraintSolver()

        let node0 = try createTestNode(index: 0, name: "A")
        let node1 = try createTestNode(index: 1, name: "B")

        // Cycle: node0 constrained by node1, node1 constrained by node0
        let constraint0 = VRMNodeConstraint(
            targetNode: 0,
            constraint: .rotation(sourceNode: 1, weight: 1.0)
        )
        let constraint1 = VRMNodeConstraint(
            targetNode: 1,
            constraint: .rotation(sourceNode: 0, weight: 1.0)
        )

        // Must not crash or loop infinitely
        solver.solve(constraints: [constraint0, constraint1], nodes: [node0, node1])

        // Both nodes should have finite, valid quaternions
        XCTAssertFalse(node0.rotation.real.isNaN, "Cycle: node0 rotation must not be NaN")
        XCTAssertFalse(node1.rotation.real.isNaN, "Cycle: node1 rotation must not be NaN")
    }

    // MARK: - Helper Methods

    private func createTestNode(index: Int, name: String) throws -> VRMNode {
        let json = """
        {
            "name": "\(name)",
            "translation": [0.0, 0.0, 0.0],
            "rotation": [0.0, 0.0, 0.0, 1.0],
            "scale": [1.0, 1.0, 1.0]
        }
        """
        let data = json.data(using: .utf8)!
        let gltfNode = try JSONDecoder().decode(GLTFNode.self, from: data)
        return VRMNode(index: index, gltfNode: gltfNode)
    }

    private func createMinimalGLTFDocument() throws -> GLTFDocument {
        let json = """
        {
            "asset": {
                "version": "2.0",
                "generator": "Test"
            }
        }
        """
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(GLTFDocument.self, from: data)
    }
}
