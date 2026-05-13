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

/// vrm-conformance issue #206: mutating `node.translation` then calling
/// `updateWorldTransform()` (or `model.updateNodeTransforms()`) leaves
/// `node.worldMatrix` at the pre-mutation value because `updateWorldTransform`
/// composes the parent's `worldMatrix` with the cached `localMatrix`, and
/// `localMatrix` is only rebuilt from T/R/S inside the explicit
/// `updateLocalMatrix()` helper.
///
/// The bug surfaced through `animate_root_transform` in the vrm-conformance
/// adapter: 18 of 18 swing tests were SHA-byte-identical to their no-animation
/// settle pairs because the adapter's `root.translation = … ; root.updateWorldTransform()`
/// pattern never reached `localMatrix`. Internal VMK code (AnimationPlayer,
/// SpringBoneComputeSystem, ProceduralAnimation, VRMSkinning,
/// VRMLookAtController, ConstraintSolver) all call `updateLocalMatrix()`
/// explicitly after mutating T/R/S, which is why VMK's own animation path
/// works — but any external caller hits this foot-gun.
final class VRMNodeTransformPropagationTests: XCTestCase {

    private func makeNode(translation: SIMD3<Float> = .zero) throws -> VRMNode {
        let json = """
        {
            "name": "RootForTest",
            "translation": [\(translation.x), \(translation.y), \(translation.z)],
            "rotation": [0.0, 0.0, 0.0, 1.0],
            "scale": [1.0, 1.0, 1.0]
        }
        """
        let gltfNode = try JSONDecoder().decode(GLTFNode.self, from: json.data(using: .utf8)!)
        return VRMNode(index: 0, gltfNode: gltfNode)
    }

    /// Mutate `translation` then call `updateWorldTransform()` (the documented
    /// public API for refreshing a subtree) and verify the new translation
    /// reaches `worldMatrix`. Pre-fix #206: this fails — `worldMatrix.columns.3`
    /// stays at the init-time translation because `localMatrix` is stale.
    func testTranslationMutationPropagatesToWorldMatrix() throws {
        let node = try makeNode()
        XCTAssertEqual(node.worldMatrix.columns.3.x, 0.0, accuracy: 1e-6)

        node.translation = SIMD3<Float>(0.15, 0, 0)
        node.updateWorldTransform()

        XCTAssertEqual(node.worldMatrix.columns.3.x, 0.15, accuracy: 1e-6,
            "Setting node.translation then calling updateWorldTransform() must " +
            "propagate to worldMatrix. Pre-fix #206 worldMatrix.columns.3.x stayed " +
            "at 0.0 because updateWorldTransform used a cached localMatrix.")
    }

    /// Same as above but covers rotation — the bug class affects every
    /// component of the local transform, not just translation.
    func testRotationMutationPropagatesToWorldMatrix() throws {
        let node = try makeNode()
        node.rotation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        node.updateWorldTransform()

        // 90° rotation around Y: localMatrix maps (1,0,0) -> (0,0,-1).
        let mapped = node.worldMatrix * SIMD4<Float>(1, 0, 0, 1)
        XCTAssertEqual(mapped.x, 0.0, accuracy: 1e-5)
        XCTAssertEqual(mapped.z, -1.0, accuracy: 1e-5,
            "Setting node.rotation then calling updateWorldTransform() must " +
            "propagate to worldMatrix. Pre-fix #206 the rotation never reached " +
            "localMatrix and worldMatrix stayed identity.")
    }

    /// End-to-end repro of vrm-conformance #206: a parent root + a child node
    /// (the spring-bone chain in the actual failure). After mutating root.translation
    /// and calling updateWorldTransform on the root, the CHILD's worldMatrix
    /// must also pick up the parent displacement. Pre-fix the parent's stale
    /// localMatrix means the child sees no parent motion either, which is why
    /// drag/stiffness/gravity all rendered identically across the spring-bone
    /// corpus (no inertia ever entered the chain).
    func testParentTranslationPropagatesThroughHierarchy() throws {
        let parent = try makeNode()
        let child = try makeNode(translation: SIMD3<Float>(0, -0.3, 0))
        parent.children = [child]
        child.parent = parent

        parent.translation = SIMD3<Float>(0.15, 0, 0)
        parent.updateWorldTransform()

        XCTAssertEqual(parent.worldMatrix.columns.3.x, 0.15, accuracy: 1e-6)
        XCTAssertEqual(child.worldMatrix.columns.3.x, 0.15, accuracy: 1e-6,
            "Child's worldMatrix must inherit parent's translation displacement. " +
            "Pre-fix #206 it stayed at 0.0 because the parent's localMatrix never " +
            "saw the translation change — spring-bone chains never received the " +
            "root-animation impulse the conformance corpus depends on.")
        XCTAssertEqual(child.worldMatrix.columns.3.y, -0.3, accuracy: 1e-6,
            "Child's Y must remain at its local bind-pose offset relative to parent.")
    }
}
