// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// TDD-style tests for SpringBone bugs identified in the physics audit.
/// These tests assert CORRECT behavior and are expected to FAIL (RED phase)
/// until the corresponding production bugs are fixed.
final class SpringBoneBugAuditTDDTests: XCTestCase {

    var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    // MARK: - Helpers

    private func createGLTFNode(name: String, translation: SIMD3<Float>) throws -> GLTFNode {
        let json = """
        {
            "name": "\(name)",
            "translation": [\(translation.x), \(translation.y), \(translation.z)],
            "rotation": [0.0, 0.0, 0.0, 1.0],
            "scale": [1.0, 1.0, 1.0]
        }
        """
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(GLTFNode.self, from: data)
    }

    private func readBonePosition(model: VRMModel, boneIndex: Int) -> SIMD3<Float> {
        guard let buffers = model.springBoneBuffers,
              boneIndex < buffers.numBones else { return .zero }
        let ptr = buffers.bonePosCurr!.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
        return ptr[boneIndex]
    }

    private func readAllBonePositions(model: VRMModel) -> [SIMD3<Float>] {
        guard let buffers = model.springBoneBuffers else { return [] }
        let ptr = buffers.bonePosCurr!.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
        return (0..<buffers.numBones).map { ptr[$0] }
    }

    private func makeGlobalParams(numBones: Int) -> SpringBoneGlobalParams {
        SpringBoneGlobalParams(
            gravity: SIMD3<Float>(0, -9.8, 0),
            dtSub: Float(1.0 / 120.0),
            windAmplitude: 0.0,
            windFrequency: 0.0,
            windPhase: 0.0,
            windDirection: SIMD3<Float>(1, 0, 0),
            substeps: 1,
            numBones: UInt32(numBones),
            numSpheres: 0,
            numCapsules: 0,
            numPlanes: 0,
            settlingFrames: 0
        )
    }

    // MARK: - Bug #1: writeBonesToNodes index desync with nil node

    /// When a spring joint references a missing node, subsequent valid joints
    /// must still map to their correct GPU bone indices. Currently globalBoneIndex
    /// fails to increment for nil nodes, shifting every later joint.
    func testNilNodeDoesNotDesyncSubsequentJointMapping() throws {
        let builder = VRMBuilder()
        let model = try builder.setSkeleton(.defaultHumanoid).build()
        model.nodes.removeAll()

        // Skeleton: A(0)→B(1)→C(2).  Spring chain: A, nil(missing), B, C.
        let nodeA = VRMNode(index: 0, gltfNode: try createGLTFNode(name: "A", translation: SIMD3<Float>(0, 0, 0)))
        let nodeB = VRMNode(index: 1, gltfNode: try createGLTFNode(name: "B", translation: SIMD3<Float>(1, 1, 0)))
        // C's LOCAL translation (relative to its parent B). With B at world (1,1,0)
        // this puts C at world (2, 1, 0) — matching the GPU snapshot we install
        // below so the chain's bind direction B→C equals the physics direction.
        let nodeC = VRMNode(index: 2, gltfNode: try createGLTFNode(name: "C", translation: SIMD3<Float>(1, 0, 0)))
        nodeB.parent = nodeA; nodeA.children.append(nodeB)
        nodeC.parent = nodeB; nodeB.children.append(nodeC)
        model.nodes = [nodeA, nodeB, nodeC]
        for node in model.nodes {
            node.updateWorldTransform()
        }

        var joints: [VRMSpringJoint] = []
        for nodeIdx in [0, 999, 1, 2] {
            var j = VRMSpringJoint(node: nodeIdx)
            j.hitRadius = 0.02
            j.stiffness = 0.0
            j.gravityPower = 0.0
            j.dragForce = 0.0
            joints.append(j)
        }

        var springBone = VRMSpringBone()
        var spring = VRMSpring(name: "Test")
        spring.joints = joints
        springBone.springs = [spring]
        model.springBone = springBone

        model.device = device
        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 4, numSpheres: 0, numCapsules: 0)
        model.springBoneBuffers = buffers
        model.springBoneGlobalParams = makeGlobalParams(numBones: 4)

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Fix GPU state so physics is stable (populate gives restLength=0 for nil joints)
        if let restLengths = buffers.restLengths {
            let r = restLengths.contents().bindMemory(to: Float.self, capacity: 4)
            r[1] = 1.0 // A → nil
            r[2] = 1.0 // nil → B
            r[3] = 1.0 // B → C
        }
        if let curr = buffers.bonePosCurr, let prev = buffers.bonePosPrev {
            let c = curr.contents().bindMemory(to: SIMD3<Float>.self, capacity: 4)
            let p = prev.contents().bindMemory(to: SIMD3<Float>.self, capacity: 4)
            c[0] = SIMD3<Float>(0, 0, 0)
            c[1] = SIMD3<Float>(1, 0, 0) // nil
            c[2] = SIMD3<Float>(1, 1, 0) // B
            c[3] = SIMD3<Float>(2, 1, 0) // C
            for i in 0..<4 { p[i] = c[i] }
        }

        // One frame with no forces should preserve positions
        system.update(model: model, deltaTime: 1.0 / 60.0)
        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        // With correct mapping, B should see target direction (1,0,0) which aligns
        // with its bind direction (1,0,0) → near-identity rotation.
        // With the bug, B is mapped to bone index 1 and sees target (0,1,0) while
        // using bind direction (0.707,0.707,0) → ~45° rotation.
        let bRotation = nodeB.localRotation
        let angle = 2.0 * acos(min(abs(bRotation.real), 1.0))
        XCTAssertLessThan(angle, 0.2,
            "Node B rotation should be near identity (bind pose aligned with target). " +
            "Actual angle: \(angle * 180 / Float.pi)°. Bug: nil node desynced mapping.")
    }

    // MARK: - Bug #2: Distance constraint uses wrong bind direction index

    /// When a bone collapses onto its parent, the distance-constraint fallback
    /// must use bindDirections[parentIndex], not bindDirections[id].
    func testDistanceConstraintRecoversCollapsedBoneUsingParentDirection() throws {
        let builder = VRMBuilder()
        let model = try builder.setSkeleton(.defaultHumanoid).build()
        model.nodes.removeAll()

        let nodeA = VRMNode(index: 0, gltfNode: try createGLTFNode(name: "A", translation: SIMD3<Float>(0, 0, 0)))
        let nodeB = VRMNode(index: 1, gltfNode: try createGLTFNode(name: "B", translation: SIMD3<Float>(1, 0, 0)))
        nodeB.parent = nodeA; nodeA.children.append(nodeB)
        model.nodes = [nodeA, nodeB]
        for node in model.nodes {
            node.updateWorldTransform()
        }

        var joints: [VRMSpringJoint] = []
        for i in 0..<2 {
            var j = VRMSpringJoint(node: i)
            j.hitRadius = 0.02
            j.stiffness = 0.0
            j.gravityPower = 0.0
            j.dragForce = 0.0
            joints.append(j)
        }

        var springBone = VRMSpringBone()
        var spring = VRMSpring(name: "Test")
        spring.joints = joints
        springBone.springs = [spring]
        model.springBone = springBone

        model.device = device
        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 2, numSpheres: 0, numCapsules: 0)
        model.springBoneBuffers = buffers
        model.springBoneGlobalParams = makeGlobalParams(numBones: 2)

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Collapse B onto A and set restLength > 0 to trigger fallback
        if let curr = buffers.bonePosCurr, let prev = buffers.bonePosPrev,
           let rest = buffers.restLengths {
            let c = curr.contents().bindMemory(to: SIMD3<Float>.self, capacity: 2)
            let p = prev.contents().bindMemory(to: SIMD3<Float>.self, capacity: 2)
            let r = rest.contents().bindMemory(to: Float.self, capacity: 2)
            c[1] = c[0]          // collapse
            p[1] = c[1]
            r[1] = 1.0           // trigger fallback
        }

        system.update(model: model, deltaTime: 1.0 / 60.0)
        Thread.sleep(forTimeInterval: 0.2)

        let bPos = readBonePosition(model: model, boneIndex: 1)
        // Correct: pushed along bindDirections[0] = (1,0,0) → x should be ~1.0
        // Bug: pushed along bindDirections[1] = (0,1,0) → x stays ~0.0, y rises
        XCTAssertGreaterThan(bPos.x, 0.5,
            "Collapsed bone should recover along parent's bind direction (+X). " +
            "Got \(bPos). Bug: distance.metal uses bindDirections[id] instead of bindDirections[parentIndex].")
        XCTAssertLessThan(abs(bPos.y), 0.5,
            "Collapsed bone should not recover along bone's own fallback direction. Got \(bPos).")
    }

    // MARK: - Bug #3+4: Collision kernels affect root bones

    /// Root bones are kinematic and must not be pushed by colliders.
    func testRootBonePositionUnchangedAfterCollision() throws {
        let builder = VRMBuilder()
        let model = try builder.setSkeleton(.defaultHumanoid).build()
        model.nodes.removeAll()

        let nodeA = VRMNode(index: 0, gltfNode: try createGLTFNode(name: "A", translation: SIMD3<Float>(0, 0, 0)))
        let nodeB = VRMNode(index: 1, gltfNode: try createGLTFNode(name: "B", translation: SIMD3<Float>(0, 1, 0)))
        nodeB.parent = nodeA; nodeA.children.append(nodeB)
        model.nodes = [nodeA, nodeB]
        for node in model.nodes {
            node.updateWorldTransform()
        }

        var joints: [VRMSpringJoint] = []
        for i in 0..<2 {
            var j = VRMSpringJoint(node: i)
            j.hitRadius = 0.1 // large so root intersects collider
            j.stiffness = 0.0
            j.gravityPower = 0.0
            j.dragForce = 0.0
            joints.append(j)
        }

        var springBone = VRMSpringBone()
        var spring = VRMSpring(name: "Test")
        spring.joints = joints
        spring.colliderGroups = [0]
        springBone.springs = [spring]

        // Sphere collider offset so penetration has a defined normal
        let collider = VRMCollider(node: 0, shape: .sphere(offset: SIMD3<Float>(0.1, 0, 0), radius: 0.2))
        springBone.colliders = [collider]
        let group = VRMColliderGroup(name: "Body", colliders: [0])
        springBone.colliderGroups = [group]
        model.springBone = springBone

        model.device = device
        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 2, numSpheres: 1, numCapsules: 0)
        model.springBoneBuffers = buffers

        var globalParams = makeGlobalParams(numBones: 2)
        globalParams.numSpheres = 1 // CRITICAL: enable sphere collision kernel
        model.springBoneGlobalParams = globalParams

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Fix rest length so child doesn't collapse
        if let rest = buffers.restLengths {
            let r = rest.contents().bindMemory(to: Float.self, capacity: 2)
            r[1] = 1.0
        }

        // Root animated position
        nodeA.translation = SIMD3<Float>(0, 0, 0)
        nodeA.updateLocalMatrix()
        nodeA.updateWorldTransform()

        system.update(model: model, deltaTime: 1.0 / 60.0)
        Thread.sleep(forTimeInterval: 0.2)

        let rootPos = readBonePosition(model: model, boneIndex: 0)
        XCTAssertEqual(rootPos.x, 0.0, accuracy: 0.001,
            "Root bone should remain at animated position (0,0,0) despite collider intersection. " +
            "Got \(rootPos). Bug: collision kernels do not skip root bones.")
    }

    // MARK: - Bug #5: Bind-direction count mismatch leaves buffer uninitialized

    /// If a joint references a missing node, populateSpringBoneData must still
    /// produce exactly numBones entries for the bindDirections buffer.
    func testBindDirectionsBufferInitializedDespiteNilNode() throws {
        let builder = VRMBuilder()
        let model = try builder.setSkeleton(.defaultHumanoid).build()
        model.nodes.removeAll()

        let nodeA = VRMNode(index: 0, gltfNode: try createGLTFNode(name: "A", translation: SIMD3<Float>(0, 0, 0)))
        let nodeB = VRMNode(index: 1, gltfNode: try createGLTFNode(name: "B", translation: SIMD3<Float>(0, 1, 0)))
        nodeB.parent = nodeA; nodeA.children.append(nodeB)
        model.nodes = [nodeA, nodeB]
        for node in model.nodes {
            node.updateWorldTransform()
        }

        var joints: [VRMSpringJoint] = []
        for nodeIdx in [0, 999, 1] {
            var j = VRMSpringJoint(node: nodeIdx)
            j.hitRadius = 0.02
            j.stiffness = 1.0 // stiffness requires bind directions
            j.gravityPower = 0.0
            j.dragForce = 0.0
            joints.append(j)
        }

        var springBone = VRMSpringBone()
        var spring = VRMSpring(name: "Test")
        spring.joints = joints
        springBone.springs = [spring]
        model.springBone = springBone

        model.device = device
        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 3, numSpheres: 0, numCapsules: 0)
        model.springBoneBuffers = buffers
        model.springBoneGlobalParams = makeGlobalParams(numBones: 3)

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // The bindDirections buffer must have been updated for all 3 bones.
        // With the bug, initialWorldBindDirections has < 3 entries and
        // updateBindDirections returns early, leaving uninitialized (zero) memory.
        guard let bindBuf = buffers.bindDirections else {
            XCTFail("bindDirections buffer missing")
            return
        }
        let ptr = bindBuf.contents().bindMemory(to: SIMD3<Float>.self, capacity: 3)
        for i in 0..<3 {
            let dir = ptr[i]
            let len = simd_length(dir)
            XCTAssertGreaterThan(len, 0.001,
                "Bind direction [\(i)] has zero length — buffer was not initialized. " +
                "Bug: nil node causes count mismatch in updateBindDirections.")
            XCTAssertFalse(dir.x.isNaN || dir.y.isNaN || dir.z.isNaN,
                "Bind direction [\(i)] contains NaN.")
        }
    }

    // MARK: - Horizontal chain helper (copied from SpringBonePhysicsSpecTests)

    private func buildHorizontalChain(boneCount: Int, gravityPower: Float, drag: Float = 0.4) throws -> VRMModel {
        let builder = VRMBuilder()
        let model = try builder.setSkeleton(.defaultHumanoid).build()
        model.nodes.removeAll()

        let boneLength: Float = 0.1
        var previousNode: VRMNode? = nil
        for i in 0..<boneCount {
            let localX: Float = (i == 0) ? 0 : boneLength
            let localY: Float = (i == 0) ? 1.0 : 0
            let gltfNode = try createGLTFNode(
                name: "spring_bone_\(i)",
                translation: SIMD3<Float>(localX, localY, 0)
            )
            let node = VRMNode(index: i, gltfNode: gltfNode)
            if let parent = previousNode {
                node.parent = parent
                parent.children.append(node)
            }
            model.nodes.append(node)
            previousNode = node
        }
        for node in model.nodes {
            node.updateWorldTransform()
        }

        var joints: [VRMSpringJoint] = []
        for i in 0..<boneCount {
            var joint = VRMSpringJoint(node: i)
            joint.hitRadius = 0.02
            joint.stiffness = 0.0
            joint.gravityPower = gravityPower
            joint.gravityDir = SIMD3<Float>(0, -1, 0)
            joint.dragForce = drag
            joints.append(joint)
        }

        var springBone = VRMSpringBone()
        var spring = VRMSpring(name: "HorizontalChain")
        spring.joints = joints
        springBone.springs = [spring]
        model.springBone = springBone

        model.device = device
        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: boneCount, numSpheres: 0, numCapsules: 0)
        model.springBoneBuffers = buffers

        model.springBoneGlobalParams = SpringBoneGlobalParams(
            gravity: SIMD3<Float>(0, -9.8, 0),
            dtSub: Float(1.0 / 120.0),
            windAmplitude: 0.0,
            windFrequency: 0.0,
            windPhase: 0.0,
            windDirection: SIMD3<Float>(1, 0, 0),
            substeps: 1,
            numBones: UInt32(boneCount),
            numSpheres: 0,
            numCapsules: 0,
            numPlanes: 0,
            settlingFrames: 0
        )
        return model
    }
}
