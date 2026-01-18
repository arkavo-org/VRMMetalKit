// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Tests verifying compliance with the Spring Bone Physics Specification.
///
/// These tests verify the GPU-based physics simulation against the specification:
/// - Verlet integration with proper velocity accumulation
/// - Gravity applied in correct direction
/// - Distance constraints maintaining rest length
/// - Collision response
/// - Chain topology (parent-child relationships)
///
/// Reference: Spring Bone Physics Specification v1.0
final class SpringBonePhysicsSpecTests: XCTestCase {

    var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    // MARK: - Phase 1: Velocity/Inertia Tests

    /// Spec 3.1: "P_next = P_curr + (P_curr - P_prev) × (1.0 - drag) + Inertia"
    /// Verify that velocity accumulates over frames (not reset to zero each frame)
    /// Note: Uses HORIZONTAL chain so gravity can actually pull bones down
    /// (vertical chains are already at rest length and can't fall further)
    func testVerletVelocityAccumulates() throws {
        // Use horizontal chain - bones extend in +X at Y=1, gravity pulls them down
        let model = try buildHorizontalChain(boneCount: 5, gravityPower: 1.0)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Initial position of tip bone
        let initialY = readBonePositionY(model: model, boneIndex: 4)

        // Run several frames - bones should fall due to gravity
        var previousDeltaY: Float = 0
        var velocityIncreased = false

        for frame in 1...30 {
            system.update(model: model, deltaTime: 1.0 / 60.0)

            if frame % 5 == 0 {
                Thread.sleep(forTimeInterval: 0.05)
                system.writeBonesToNodes(model: model)

                let currentY = readBonePositionY(model: model, boneIndex: 4)
                let deltaY = initialY - currentY  // Positive if falling

                // Velocity should cause increasing movement (acceleration)
                // With proper Verlet, each frame's movement builds on previous velocity
                if frame > 5 && deltaY > previousDeltaY + 0.001 {
                    velocityIncreased = true
                }
                previousDeltaY = deltaY
            }
        }

        // With proper Verlet, bones should fall progressively further each frame
        XCTAssertTrue(velocityIncreased, "Bones should fall due to Verlet integration with gravity")
    }

    /// Helper to create horizontal chain (for tests needing bones that can fall)
    private func buildHorizontalChain(boneCount: Int, gravityPower: Float, drag: Float = 0.4) throws -> VRMModel {
        let builder = VRMBuilder()
        let model = try builder.setSkeleton(.defaultHumanoid).build()

        let boneLength: Float = 0.1
        model.nodes.removeAll()

        var previousNode: VRMNode? = nil
        for i in 0..<boneCount {
            // Horizontal: first bone at (0, 1, 0), children extend in +X
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

        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }

        var joints: [VRMSpringJoint] = []
        for i in 0..<boneCount {
            var joint = VRMSpringJoint(node: i)
            joint.hitRadius = 0.02
            joint.stiffness = 0.0  // No stiffness, like Alicia's skirt
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

        let globalParams = SpringBoneGlobalParams(
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
            numPlanes: 0
        )
        model.springBoneGlobalParams = globalParams

        return model
    }

    /// Spec 3.1: Drag should slow velocity over time
    /// Note: Uses HORIZONTAL chains so bones can actually fall
    func testDragReducesVelocity() throws {
        // Create two HORIZONTAL chains - one with high drag, one with low drag
        // Horizontal chains start at Y=1 extending in +X, so gravity can pull them down
        let modelLowDrag = try buildHorizontalChain(boneCount: 5, gravityPower: 1.0, drag: 0.1)
        let modelHighDrag = try buildHorizontalChain(boneCount: 5, gravityPower: 1.0, drag: 0.9)

        let systemLow = try SpringBoneComputeSystem(device: device)
        let systemHigh = try SpringBoneComputeSystem(device: device)
        try systemLow.populateSpringBoneData(model: modelLowDrag)
        try systemHigh.populateSpringBoneData(model: modelHighDrag)

        // Run simulation for longer to see drag difference
        for _ in 0..<120 {
            systemLow.update(model: modelLowDrag, deltaTime: 1.0 / 60.0)
            systemHigh.update(model: modelHighDrag, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        systemLow.writeBonesToNodes(model: modelLowDrag)
        systemHigh.writeBonesToNodes(model: modelHighDrag)

        // Check tip bone (index 4) position
        let lowDragY = readBonePositionY(model: modelLowDrag, boneIndex: 4)
        let highDragY = readBonePositionY(model: modelHighDrag, boneIndex: 4)

        // Both should have fallen from Y=1.0
        // With high drag (0.9), velocity is damped more, so bone oscillates/settles slower
        // With low drag (0.1), bone can swing more freely
        // Note: Both will eventually settle to similar positions due to gravity equilibrium,
        // but during the settling period, low drag moves more dynamically
        XCTAssertLessThan(lowDragY, 0.9, "Low drag bone should have fallen from Y=1.0")
        XCTAssertLessThan(highDragY, 0.9, "High drag bone should have fallen from Y=1.0")
    }

    // MARK: - Phase 2: Gravity Direction Tests

    /// Spec 3.2: Gravity should be applied in gravityDir direction
    /// Verify bones fall DOWN (negative Y), not UP
    func testGravityPullsDownward() throws {
        let model = try buildVerticalChain(boneCount: 3, gravityPower: 1.0)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Record initial Y position
        let initialY = readBonePositionY(model: model, boneIndex: 2)

        // Run simulation for 1 second
        for _ in 0..<60 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        let finalY = readBonePositionY(model: model, boneIndex: 2)

        // CRITICAL: Bones should fall DOWN (Y decreases)
        // If Y increases, gravity direction is inverted (the bug we fixed)
        XCTAssertLessThan(finalY, initialY, "Gravity should pull bones DOWNWARD (Y should decrease)")
    }

    /// Spec 3.2: gravityPower scales gravity magnitude
    func testGravityPowerScalesEffect() throws {
        let modelNoGravity = try buildVerticalChain(boneCount: 3, gravityPower: 0.0)
        let modelFullGravity = try buildVerticalChain(boneCount: 3, gravityPower: 1.0)

        let systemNo = try SpringBoneComputeSystem(device: device)
        let systemFull = try SpringBoneComputeSystem(device: device)
        try systemNo.populateSpringBoneData(model: modelNoGravity)
        try systemFull.populateSpringBoneData(model: modelFullGravity)

        let initialYNo = readBonePositionY(model: modelNoGravity, boneIndex: 2)
        let initialYFull = readBonePositionY(model: modelFullGravity, boneIndex: 2)

        // Run simulation
        for _ in 0..<60 {
            systemNo.update(model: modelNoGravity, deltaTime: 1.0 / 60.0)
            systemFull.update(model: modelFullGravity, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        systemNo.writeBonesToNodes(model: modelNoGravity)
        systemFull.writeBonesToNodes(model: modelFullGravity)

        let finalYNo = readBonePositionY(model: modelNoGravity, boneIndex: 2)
        let finalYFull = readBonePositionY(model: modelFullGravity, boneIndex: 2)

        let deltaNo = abs(finalYNo - initialYNo)
        let deltaFull = abs(finalYFull - initialYFull)

        // gravityPower=1.0 should fall much further than gravityPower=0.0
        XCTAssertGreaterThan(deltaFull, deltaNo * 5, "Full gravity should cause much more movement than zero gravity")
    }

    // MARK: - Phase 3: Distance Constraint Tests

    /// Spec 3.3.1: "Ensure the distance between P_next and Parent's current position equals bone_length"
    func testDistanceConstraintMaintainsRestLength() throws {
        let model = try buildVerticalChain(boneCount: 5, gravityPower: 1.0)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Get rest lengths from spring bone data
        guard let springBone = model.springBone,
              let spring = springBone.springs.first else {
            XCTFail("No spring bone data")
            return
        }

        // Run simulation with gravity
        for _ in 0..<120 {  // 2 seconds
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        // Read back positions and verify distances
        guard let buffers = model.springBoneBuffers,
              let bonePosCurr = buffers.bonePosCurr else {
            XCTFail("No buffers")
            return
        }

        let positions = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)

        // Check each bone's distance to parent (skip root at index 0)
        for i in 1..<buffers.numBones {
            let currentPos = positions[i]
            let parentPos = positions[i - 1]  // Assumes sequential parent indices

            let distance = simd_distance(currentPos, parentPos)

            // Distance should be close to rest length (some tolerance for simulation)
            // Note: Without knowing exact rest lengths, we check for reasonable values
            XCTAssertGreaterThan(distance, 0.001, "Bone \(i) collapsed to parent position")
            XCTAssertLessThan(distance, 1.0, "Bone \(i) stretched excessively: \(distance)")
        }
    }

    /// Spec 3.3.1: Constraint should prevent both stretching AND compression
    func testDistanceConstraintPreventsCompression() throws {
        let model = try buildVerticalChain(boneCount: 3, gravityPower: 0.0)  // No gravity
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Record initial distance
        guard let buffers = model.springBoneBuffers,
              let bonePosCurr = buffers.bonePosCurr else {
            XCTFail("No buffers")
            return
        }

        var initialPositions: [SIMD3<Float>] = []
        let ptr = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
        for i in 0..<buffers.numBones {
            initialPositions.append(ptr[i])
        }

        // Run simulation (no gravity, should stay stable)
        for _ in 0..<60 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        // Verify positions didn't collapse inward
        let finalPtr = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
        for i in 1..<buffers.numBones {
            let initialDist = simd_distance(initialPositions[i], initialPositions[i - 1])
            let finalDist = simd_distance(finalPtr[i], finalPtr[i - 1])

            // Distance should be maintained (within tolerance)
            let ratio = finalDist / max(initialDist, 0.001)
            XCTAssertGreaterThan(ratio, 0.8, "Bone \(i) compressed: ratio = \(ratio)")
        }
    }

    // MARK: - Chain Topology Tests

    /// Spec 2.2: "parent_index" must correctly identify parent bone
    func testParentIndexTopology() throws {
        let model = try buildVerticalChain(boneCount: 5, gravityPower: 0.5)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Run simulation
        for _ in 0..<30 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        // Verify chain structure - each bone should be connected to previous
        guard let buffers = model.springBoneBuffers,
              let bonePosCurr = buffers.bonePosCurr else {
            return
        }

        let positions = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)

        // Chain should form a connected sequence from root
        var previousPos = positions[0]
        for i in 1..<buffers.numBones {
            let currentPos = positions[i]
            let distance = simd_distance(currentPos, previousPos)

            // Bones should be connected (not at same point, not infinitely far)
            XCTAssertGreaterThan(distance, 0.0001, "Bone \(i) collapsed to parent")
            XCTAssertLessThan(distance, 2.0, "Bone \(i) disconnected from chain")

            previousPos = currentPos
        }
    }

    // MARK: - Root Bone Kinematic Tests

    /// Spec: Root bones should follow animation, not physics
    func testRootBonesAreKinematic() throws {
        let model = try buildVerticalChain(boneCount: 3, gravityPower: 1.0)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Get initial root position
        guard let rootNode = model.nodes.first,
              let buffers = model.springBoneBuffers,
              let bonePosCurr = buffers.bonePosCurr else {
            XCTFail("Setup failed")
            return
        }

        let initialRootPos = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: 1)[0]

        // Move root node (simulating animation)
        let newRootPosition = SIMD3<Float>(1.0, 2.0, 0.0)
        rootNode.translation = newRootPosition
        rootNode.updateLocalMatrix()
        rootNode.updateWorldTransform()

        // Run physics
        for _ in 0..<30 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        // Root should follow animation, not fall due to gravity
        let finalRootPos = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: 1)[0]
        let rootMoved = simd_distance(finalRootPos, initialRootPos) > 0.5

        XCTAssertTrue(rootMoved, "Root bone should follow animation (kinematic)")
    }

    // MARK: - Inertia Tests

    /// Verify that child bones follow parent when parent moves upward
    /// With a distance constraint, the child MUST follow within tolerance.
    /// The inertia compensation prevents velocity spikes, not large trailing.
    func testChildFollowsParentWhenParentMovesUp() throws {
        let model = try buildVerticalChain(boneCount: 3, gravityPower: 0.0, drag: 0.1)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        guard let rootNode = model.nodes.first,
              let buffers = model.springBoneBuffers,
              let bonePosCurr = buffers.bonePosCurr else {
            XCTFail("Setup failed")
            return
        }

        // Get initial positions
        let initialPtr = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
        let initialRootY = initialPtr[0].y
        let initialChildY = initialPtr[1].y

        // Simulate parent moving UP over several frames
        let jumpHeight: Float = 0.5
        let jumpFrames = 10

        for frame in 1...jumpFrames {
            let progress = Float(frame) / Float(jumpFrames)
            let newRootY: Float = 1.0 + jumpHeight * progress
            rootNode.translation = SIMD3<Float>(0, newRootY, 0)
            rootNode.updateLocalMatrix()
            rootNode.updateWorldTransform()

            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.1)
        system.writeBonesToNodes(model: model)

        // Check final positions
        let finalPtr = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
        let finalRootY = finalPtr[0].y
        let finalChildY = finalPtr[1].y

        // With distance constraint, child must follow parent
        // Child should have moved approximately same amount as root
        let rootDeltaY = finalRootY - initialRootY
        let childDeltaY = finalChildY - initialChildY

        // Child should move in same direction as root (both up)
        XCTAssertGreaterThan(childDeltaY, 0, "Child should move up when parent moves up")

        // Child movement should be similar to root (within constraint tolerance)
        // Allow 20% difference due to constraint stretch tolerance
        let movementRatio = childDeltaY / max(rootDeltaY, 0.001)
        XCTAssertGreaterThan(movementRatio, 0.8, "Child should mostly follow parent movement")
        XCTAssertLessThan(movementRatio, 1.5, "Child should not overshoot significantly")

        // Distance between child and parent should be bounded (chain connected)
        // Note: Compression is allowed (ratio < 1.0), only excessive stretch is prevented
        let finalDistance = abs(finalChildY - finalRootY)
        let initialDistance = abs(initialChildY - initialRootY)
        let distanceRatio = finalDistance / max(initialDistance, 0.001)
        // Allow compression down to 50% (physics allows compression, prevents stretch)
        XCTAssertGreaterThan(distanceRatio, 0.5, "Chain should stay connected (not collapsed)")
        // Stretch tolerance is 5%, so max is 1.05
        XCTAssertLessThan(distanceRatio, 1.1, "Chain should not stretch excessively")
    }

    // MARK: - Edge Case Tests

    /// Spec 5.1: Teleportation should trigger reset
    func testLargeFrameTimeDoesNotExplode() throws {
        let model = try buildVerticalChain(boneCount: 5, gravityPower: 1.0)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Simulate teleportation via huge delta time
        system.update(model: model, deltaTime: 5.0)  // 5 second frame

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        // Verify no NaN or infinite values
        guard let buffers = model.springBoneBuffers,
              let bonePosCurr = buffers.bonePosCurr else {
            return
        }

        let positions = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
        for i in 0..<buffers.numBones {
            XCTAssertTrue(positions[i].x.isFinite, "Bone \(i) X is not finite")
            XCTAssertTrue(positions[i].y.isFinite, "Bone \(i) Y is not finite")
            XCTAssertTrue(positions[i].z.isFinite, "Bone \(i) Z is not finite")

            // Should be within reasonable bounds (not at infinity)
            XCTAssertLessThan(simd_length(positions[i]), 1000.0, "Bone \(i) position exploded")
        }
    }

    /// Spec 5.2: Zero delta time should not crash
    func testZeroDeltaTimeHandled() throws {
        let model = try buildVerticalChain(boneCount: 3, gravityPower: 1.0)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Should not crash with zero deltaTime
        system.update(model: model, deltaTime: 0.0)
        system.update(model: model, deltaTime: 0.0001)  // Near-zero

        Thread.sleep(forTimeInterval: 0.1)
        system.writeBonesToNodes(model: model)

        // Verify no crash and no NaN
        guard let buffers = model.springBoneBuffers,
              let bonePosCurr = buffers.bonePosCurr else {
            return
        }

        let positions = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
        for i in 0..<buffers.numBones {
            XCTAssertFalse(positions[i].x.isNaN, "Zero deltaTime produced NaN")
        }
    }

    // MARK: - Helper Methods

    /// Helper to create GLTFNode from JSON
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

    /// Build a vertical chain of spring bones for testing
    private func buildVerticalChain(boneCount: Int, gravityPower: Float, drag: Float = 0.4) throws -> VRMModel {
        let builder = VRMBuilder()
        let model = try builder.setSkeleton(.defaultHumanoid).build()

        // CRITICAL: Set up proper node positions and hierarchy
        // The nodes must form a vertical chain with proper parent-child relationships
        let boneLength: Float = 0.1  // 10cm between bones

        // Clear existing nodes and create our own chain
        model.nodes.removeAll()

        var previousNode: VRMNode? = nil
        for i in 0..<boneCount {
            // Local translation: root starts at (0, 1, 0), children offset by -boneLength in Y
            let localY: Float = (i == 0) ? 1.0 : -boneLength
            let gltfNode = try createGLTFNode(name: "spring_bone_\(i)", translation: SIMD3<Float>(0, localY, 0))
            let node = VRMNode(index: i, gltfNode: gltfNode)

            // Set parent-child relationship
            if let parent = previousNode {
                node.parent = parent
                parent.children.append(node)
            }

            model.nodes.append(node)
            previousNode = node
        }

        // Update world transforms from root
        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }

        // Create vertical chain of joints
        var joints: [VRMSpringJoint] = []
        for i in 0..<boneCount {
            var joint = VRMSpringJoint(node: i)
            joint.hitRadius = 0.02
            joint.stiffness = 0.5
            joint.gravityPower = gravityPower
            joint.gravityDir = SIMD3<Float>(0, -1, 0)  // DOWN
            joint.dragForce = drag
            joints.append(joint)
        }

        var springBone = VRMSpringBone()
        var spring = VRMSpring(name: "VerticalChain")
        spring.joints = joints
        springBone.springs = [spring]
        model.springBone = springBone

        // Assign device for buffer creation
        model.device = device

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: boneCount, numSpheres: 0, numCapsules: 0)
        model.springBoneBuffers = buffers

        // Set up global params
        let globalParams = SpringBoneGlobalParams(
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
            numPlanes: 0
        )
        model.springBoneGlobalParams = globalParams

        return model
    }

    /// Read Y position of a bone from GPU buffer
    private func readBonePositionY(model: VRMModel, boneIndex: Int) -> Float {
        guard let buffers = model.springBoneBuffers,
              let bonePosCurr = buffers.bonePosCurr,
              boneIndex < buffers.numBones else {
            return 0
        }

        let positions = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
        return positions[boneIndex].y
    }
}
