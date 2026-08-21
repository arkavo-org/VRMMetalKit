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
import Metal
import simd
@testable import VRMMetalKit

/// Group 2: cheaper affine normal matrices, and skin palettes that rebuild
/// only when a joint's world transform actually changed.
final class Group2TransformSkinningTests: XCTestCase {

    private var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        self.device = device
    }

    // MARK: - Affine normal matrix

    func testAffineNormalMatrixMatchesUpper3x3OfInverseTranspose() {
        let node = try! makeNode()
        node.translation = SIMD3<Float>(0.2, -0.1, 0.4)
        node.rotation = simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3<Float>(0.2, 0.8, 0.1)))
        node.scale = SIMD3<Float>(1.5, 1.5, 1.5)
        node.updateLocalMatrix()
        let world = node.localMatrix

        let cheap = AffineNormalMatrix.inverseTranspose(of: world)
        let reference = simd_transpose(simd_inverse(world))

        assertUpper3x3Equal(cheap, reference, accuracy: 1e-5)
        // Homogeneous w-row stays identity so `normalMatrix * float4(N, 0)` is unchanged.
        XCTAssertEqual(cheap.columns.0.w, 0, accuracy: 1e-6)
        XCTAssertEqual(cheap.columns.1.w, 0, accuracy: 1e-6)
        XCTAssertEqual(cheap.columns.2.w, 0, accuracy: 1e-6)
        XCTAssertEqual(cheap.columns.3.w, 1, accuracy: 1e-6)
    }

    func testUpdateWorldTransformWritesAffineNormalMatrix() throws {
        let node = try makeNode()
        node.translation = SIMD3<Float>(1, 2, 3)
        node.scale = SIMD3<Float>(2, 2, 2)
        node.updateWorldTransform()

        let expected = AffineNormalMatrix.inverseTranspose(of: node.worldMatrix)
        assertUpper3x3Equal(node.normalMatrix, expected, accuracy: 1e-5)
        assertUpper3x3Equal(node.normalMatrix, simd_transpose(simd_inverse(node.worldMatrix)), accuracy: 1e-5)
    }

    // MARK: - World generation

    func testWorldGenerationIncrementsOnlyWhenWorldMatrixChanges() throws {
        let node = try makeNode()
        XCTAssertEqual(node.worldGeneration, 0)

        node.updateWorldTransform()
        let afterFirst = node.worldGeneration
        XCTAssertGreaterThan(afterFirst, 0, "first walk must publish a world matrix")

        node.updateWorldTransform()
        XCTAssertEqual(node.worldGeneration, afterFirst,
                       "unchanged TRS must not bump worldGeneration")

        node.translation = SIMD3<Float>(0.25, 0, 0)
        node.updateWorldTransform()
        XCTAssertGreaterThan(node.worldGeneration, afterFirst,
                             "TRS mutation must bump worldGeneration")
    }

    func testChildWorldGenerationTracksParentMotion() throws {
        let parent = try makeNode()
        let child = try makeNode(translation: SIMD3<Float>(0, -0.3, 0))
        parent.children = [child]
        child.parent = parent
        parent.updateWorldTransform()
        let childGen = child.worldGeneration

        parent.translation = SIMD3<Float>(0.15, 0, 0)
        parent.updateWorldTransform()
        XCTAssertGreaterThan(child.worldGeneration, childGen)
    }

    // MARK: - Skin dirty-if-moved

    func testUnchangedJointsDoNotMarkSkinDirty() throws {
        let joint = try makeNode()
        joint.updateWorldTransform()
        let skin = makeSkin(joints: [joint])
        let system = VRMSkinningSystem(device: device)
        system.setupForSkins([skin])
        system.markSkinsDirtyIfJointsMoved([skin])
        system.clearSkinDirty(skinIndex: 0)

        system.markSkinsDirtyIfJointsMoved([skin])
        XCTAssertFalse(system.isSkinDirty(skinIndex: 0),
                       "static joints must not force a palette rebuild")
    }

    func testMovedJointMarksOnlyThatSkinDirty() throws {
        let jointA = try makeNode()
        let jointB = try makeNode(translation: SIMD3<Float>(1, 0, 0))
        jointA.updateWorldTransform()
        jointB.updateWorldTransform()

        let skinA = makeSkin(joints: [jointA])
        let skinB = makeSkin(joints: [jointB])
        let system = VRMSkinningSystem(device: device)
        system.setupForSkins([skinA, skinB])
        system.markSkinsDirtyIfJointsMoved([skinA, skinB])
        system.clearSkinDirty(skinIndex: 0)
        system.clearSkinDirty(skinIndex: 1)

        jointA.translation = SIMD3<Float>(0.4, 0, 0)
        jointA.updateWorldTransform()

        system.markSkinsDirtyIfJointsMoved([skinA, skinB])
        XCTAssertTrue(system.isSkinDirty(skinIndex: 0),
                      "the skin whose joint moved must rebuild")
        XCTAssertFalse(system.isSkinDirty(skinIndex: 1),
                       "an unrelated skin must stay clean")
    }

    func testSecondPaletteUpdateIsSkippedWhenJointsAreStatic() throws {
        let joint = try makeNode()
        joint.updateWorldTransform()
        let skin = makeSkin(joints: [joint])
        let system = VRMSkinningSystem(device: device)
        system.setupForSkins([skin])

        system.markSkinsDirtyIfJointsMoved([skin])
        system.updateJointMatrices(for: skin, skinIndex: 0)

        guard let buffer = system.getJointMatricesBuffer() else {
            return XCTFail("expected joint buffer")
        }
        let pointer = buffer.contents().bindMemory(to: float4x4.self, capacity: 1)
        var sentinel = float4x4(diagonal: SIMD4<Float>(9, 9, 9, 9))
        pointer[0] = sentinel

        system.markSkinsDirtyIfJointsMoved([skin])
        system.updateJointMatrices(for: skin, skinIndex: 0)

        XCTAssertEqual(pointer[0].columns.0.x, 9, accuracy: 1e-6,
                       "static joints must not rewrite the palette")
    }

    // MARK: - Fixtures

    private func makeNode(translation: SIMD3<Float> = .zero) throws -> VRMNode {
        let json = """
        {
            "name": "Group2Node",
            "translation": [\(translation.x), \(translation.y), \(translation.z)],
            "rotation": [0.0, 0.0, 0.0, 1.0],
            "scale": [1.0, 1.0, 1.0]
        }
        """
        let gltfNode = try JSONDecoder().decode(GLTFNode.self, from: json.data(using: .utf8)!)
        return VRMNode(index: 0, gltfNode: gltfNode)
    }

    private func makeSkin(joints: [VRMNode]) -> VRMSkin {
        let skin = VRMSkin()
        skin.joints = joints
        skin.inverseBindMatrices = Array(repeating: matrix_identity_float4x4, count: joints.count)
        return skin
    }

    private func assertUpper3x3Equal(_ a: float4x4, _ b: float4x4, accuracy: Float) {
        for col in 0..<3 {
            XCTAssertEqual(a[col][0], b[col][0], accuracy: accuracy)
            XCTAssertEqual(a[col][1], b[col][1], accuracy: accuracy)
            XCTAssertEqual(a[col][2], b[col][2], accuracy: accuracy)
        }
    }
}
