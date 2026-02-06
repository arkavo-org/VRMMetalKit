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
@testable import VRMMetalKit

/// VRM 1.0 round-trip tests that run in CI without external model files.
///
/// Uses VRMBuilder to build a VRM 1.0 model, serializes to GLB Data,
/// reloads via VRMModel.load(from:), and validates all VRM 1.0 properties.
final class VRM10CITests: XCTestCase {

    private var originalModel: VRMModel!
    private var glbData: Data!
    private var reloadedModel: VRMModel!

    override func setUp() async throws {
        try await super.setUp()

        originalModel = try VRMBuilder()
            .setSkeleton(.defaultHumanoid)
            .addExpressions([.happy, .sad, .blink, .aa])
            .build()

        glbData = try originalModel.serialize()

        reloadedModel = try await VRMModel.load(from: glbData, device: nil)
    }

    // MARK: - Tests

    func testVRM10SpecVersionDetection() {
        XCTAssertEqual(reloadedModel.specVersion, .v1_0)
        XCTAssertFalse(reloadedModel.isVRM0)
    }

    func testVRM10MetaParsing() {
        XCTAssertNotNil(reloadedModel.meta.name)
        XCTAssertEqual(reloadedModel.meta.name, originalModel.meta.name)
        XCTAssertNotNil(reloadedModel.meta.licenseUrl)
    }

    func testVRM10HumanoidBoneMapping() {
        let humanoid = reloadedModel.humanoid
        XCTAssertNotNil(humanoid)

        let requiredBones: [VRMHumanoidBone] = [
            .hips, .spine, .chest, .head, .neck,
            .leftUpperArm, .leftLowerArm, .leftHand,
            .rightUpperArm, .rightLowerArm, .rightHand,
            .leftUpperLeg, .leftLowerLeg, .leftFoot,
            .rightUpperLeg, .rightLowerLeg, .rightFoot,
        ]

        for bone in requiredBones {
            let nodeIndex = humanoid!.getBoneNode(bone)
            XCTAssertNotNil(nodeIndex, "Missing required bone: \(bone.rawValue)")
            if let idx = nodeIndex {
                XCTAssertLessThan(idx, reloadedModel.nodes.count,
                    "Bone \(bone.rawValue) node index \(idx) out of range")
            }
        }

        XCTAssertGreaterThanOrEqual(humanoid!.humanBones.count, 20)
    }

    func testVRM10MaterialVersionPropagation() {
        XCTAssertFalse(reloadedModel.materials.isEmpty, "Materials should be loaded")
        for material in reloadedModel.materials {
            XCTAssertEqual(material.vrmVersion, .v1_0,
                "Material '\(material.name ?? "unnamed")' should have vrmVersion .v1_0")
        }
    }

    func testVRM10MToonMaterialProperties() {
        XCTAssertFalse(reloadedModel.materials.isEmpty)
        let material = reloadedModel.materials[0]
        XCTAssertEqual(material.alphaMode, "OPAQUE")
        XCTAssertEqual(material.metallicFactor, 0.0, accuracy: 0.001)
        XCTAssertEqual(material.roughnessFactor, 1.0, accuracy: 0.001)
    }

    func testVRM10ExpressionBindings() {
        let expressions = reloadedModel.expressions
        XCTAssertNotNil(expressions)

        let expectedPresets: [VRMExpressionPreset] = [.happy, .sad, .blink, .aa]
        for preset in expectedPresets {
            XCTAssertNotNil(expressions!.preset[preset],
                "Missing expression preset: \(preset.rawValue)")
        }

        XCTAssertGreaterThanOrEqual(expressions!.preset.count, expectedPresets.count)
    }

    func testVRM10GLBRoundTrip() {
        XCTAssertGreaterThanOrEqual(glbData.count, 12, "GLB must have at least a 12-byte header")

        let magic = glbData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        XCTAssertEqual(magic, 0x46546C67, "GLB magic should be 'glTF'")

        let version = glbData.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        XCTAssertEqual(version, 2, "GLB version should be 2")

        let totalLength = glbData.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
        XCTAssertEqual(Int(totalLength), glbData.count, "GLB total length should match data size")

        XCTAssertEqual(reloadedModel.specVersion, originalModel.specVersion)
        XCTAssertEqual(reloadedModel.meta.name, originalModel.meta.name)
        XCTAssertEqual(
            reloadedModel.humanoid?.humanBones.count,
            originalModel.humanoid?.humanBones.count
        )
    }

    func testVRM10NodeHierarchy() {
        XCTAssertFalse(reloadedModel.nodes.isEmpty)
        XCTAssertEqual(reloadedModel.nodes.count, originalModel.nodes.count)

        let roots = reloadedModel.nodes.filter { $0.parent == nil }
        XCTAssertFalse(roots.isEmpty, "Should have at least one root node")

        var hasChild = false
        for node in reloadedModel.nodes {
            if !node.children.isEmpty {
                hasChild = true
                for child in node.children {
                    XCTAssertTrue(child.parent === node,
                        "Child '\(child.name ?? "?")' parent should be '\(node.name ?? "?")'")
                }
            }
        }
        XCTAssertTrue(hasChild, "At least one node should have children")
    }

    func testVRM10NotVRM0() {
        XCTAssertEqual(reloadedModel.specVersion, .v1_0)
        XCTAssertNotEqual(reloadedModel.specVersion, .v0_0)
        XCTAssertFalse(reloadedModel.isVRM0)

        let humanoid = reloadedModel.humanoid!
        for (bone, humanBone) in humanoid.humanBones {
            XCTAssertNotNil(bone.rawValue)
            XCTAssertGreaterThanOrEqual(humanBone.node, 0)
        }
    }

    func testVRM10MeshGeometry() {
        XCTAssertFalse(reloadedModel.meshes.isEmpty, "Model should have meshes after round-trip")
        for mesh in reloadedModel.meshes {
            XCTAssertFalse(mesh.primitives.isEmpty,
                "Mesh '\(mesh.name ?? "unnamed")' should have primitives")
        }

        let gltfMeshes = reloadedModel.gltf.meshes
        XCTAssertNotNil(gltfMeshes)
        XCTAssertFalse(gltfMeshes!.isEmpty)
    }
}
