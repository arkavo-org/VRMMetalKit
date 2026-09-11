//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

import XCTest
import simd
@testable import VRMMetalKit

/// Guards the `localMatrixDirty` skip in `VRMNode.updateWorldTransform()`:
/// a node whose T/R/S did not change must not rebuild its `localMatrix`
/// on the next walk, and a node whose T/R/S did change must rebuild exactly once.
/// `localMatrixRebuildCount` is the only observable that separates
/// "rebuilt to an identical value" from "reused".
final class VRMNodeLocalMatrixDirtyTests: XCTestCase {

    private func makeNode(name: String, translation: SIMD3<Float> = .zero) throws -> VRMNode {
        let json = """
        {
            "name": "\(name)",
            "translation": [\(translation.x), \(translation.y), \(translation.z)],
            "rotation": [0.0, 0.0, 0.0, 1.0],
            "scale": [1.0, 1.0, 1.0]
        }
        """
        let gltfNode = try JSONDecoder().decode(GLTFNode.self, from: json.data(using: .utf8)!)
        return VRMNode(index: 0, gltfNode: gltfNode)
    }

    private func makeParentChild() throws -> (parent: VRMNode, child: VRMNode) {
        let parent = try makeNode(name: "Parent", translation: SIMD3<Float>(1, 0, 0))
        let child = try makeNode(name: "Child", translation: SIMD3<Float>(0, 2, 0))
        parent.children.append(child)
        child.parent = parent
        parent.updateWorldTransform()
        return (parent, child)
    }

    func testUntouchedChildReusesLocalMatrixWhenParentMoves() throws {
        let (parent, child) = try makeParentChild()
        let parentBefore = parent.localMatrixRebuildCount
        let childBefore = child.localMatrixRebuildCount

        parent.translation = SIMD3<Float>(5, 0, 0)
        parent.updateWorldTransform()

        XCTAssertEqual(parent.localMatrixRebuildCount, parentBefore + 1,
            "Parent translation changed, so its localMatrix must be rebuilt exactly once")
        XCTAssertEqual(child.localMatrixRebuildCount, childBefore,
            "Child T/R/S did not change, so the walk must reuse its cached localMatrix")
        XCTAssertEqual(child.worldMatrix.columns.3.x, 5, accuracy: 1e-6)
        XCTAssertEqual(child.worldMatrix.columns.3.y, 2, accuracy: 1e-6)
        XCTAssertEqual(child.worldMatrix.columns.3.z, 0, accuracy: 1e-6)
    }

    func testIdleWalkRebuildsNothing() throws {
        let (parent, child) = try makeParentChild()
        let parentBefore = parent.localMatrixRebuildCount
        let childBefore = child.localMatrixRebuildCount

        parent.updateWorldTransform()
        parent.updateWorldTransform()

        XCTAssertEqual(parent.localMatrixRebuildCount, parentBefore)
        XCTAssertEqual(child.localMatrixRebuildCount, childBefore)
    }

    func testTranslationWriteRebuildsExactlyOnce() throws {
        let node = try makeNode(name: "N")
        node.updateWorldTransform()
        let before = node.localMatrixRebuildCount

        node.translation = SIMD3<Float>(0.25, 0, 0)
        node.updateWorldTransform()

        XCTAssertEqual(node.localMatrixRebuildCount, before + 1)
        XCTAssertEqual(node.worldMatrix.columns.3.x, 0.25, accuracy: 1e-6)
    }

    func testRotationWriteRebuildsExactlyOnce() throws {
        let node = try makeNode(name: "N")
        node.updateWorldTransform()
        let before = node.localMatrixRebuildCount

        node.rotation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
        node.updateWorldTransform()

        XCTAssertEqual(node.localMatrixRebuildCount, before + 1)
        XCTAssertEqual(node.worldMatrix.columns.0.y, 1, accuracy: 1e-6)
    }

    func testScaleWriteRebuildsExactlyOnce() throws {
        let node = try makeNode(name: "N")
        node.updateWorldTransform()
        let before = node.localMatrixRebuildCount

        node.scale = SIMD3<Float>(3, 1, 1)
        node.updateWorldTransform()

        XCTAssertEqual(node.localMatrixRebuildCount, before + 1)
        XCTAssertEqual(node.worldMatrix.columns.0.x, 3, accuracy: 1e-6)
    }

    func testMultipleWritesBeforeOneWalkCoalesceIntoOneRebuild() throws {
        let node = try makeNode(name: "N")
        node.updateWorldTransform()
        let before = node.localMatrixRebuildCount

        node.translation = SIMD3<Float>(0, 0, 4)
        node.rotation = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        node.scale = SIMD3<Float>(2, 2, 2)
        node.updateWorldTransform()

        XCTAssertEqual(node.localMatrixRebuildCount, before + 1)
        XCTAssertEqual(node.worldMatrix.columns.3.z, 4, accuracy: 1e-6)
        XCTAssertEqual(node.worldMatrix.columns.0.x, -2, accuracy: 1e-6)
    }

    func testResetToBindPoseLeavesNodeCleanAndAtBind() throws {
        let node = try makeNode(name: "N", translation: SIMD3<Float>(0, 1, 0))
        node.translation = SIMD3<Float>(7, 7, 7)
        node.rotation = simd_quatf(angle: .pi / 3, axis: SIMD3<Float>(1, 0, 0))
        node.scale = SIMD3<Float>(0.5, 0.5, 0.5)
        node.updateWorldTransform()

        node.resetToBindPose()
        let afterReset = node.localMatrixRebuildCount

        node.updateWorldTransform()

        XCTAssertEqual(node.localMatrixRebuildCount, afterReset,
            "resetToBindPose() already rebuilt localMatrix, so the following walk must not rebuild again")
        let bind = float4x4(translation: node.initialTranslation)
        XCTAssertEqual(node.worldMatrix, bind)
    }
}
