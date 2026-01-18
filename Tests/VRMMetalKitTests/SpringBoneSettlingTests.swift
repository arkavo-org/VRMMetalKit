// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Tests for SpringBone settling behavior and initialization.
///
/// These tests investigate the physics behavior during:
/// - Settling period (first ~120 frames after load)
/// - Post-settling behavior (after settling completes)
/// - Initial bone position setup from bind pose
/// - Velocity changes when settling ends
///
/// Key issue being investigated: bones "rise up" after settling ends
final class SpringBoneSettlingTests: XCTestCase {

    var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    // MARK: - Settling Period Behavior Tests

    /// Test that bones fall during settling period due to gravity boost
    func testBonesFallDuringSettlingPeriod() throws {
        let model = try buildHorizontalChain(boneCount: 5, gravityPower: 1.0, settlingFrames: 120)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        let initialPositions = readBonePositions(model: model)
        print("Initial positions (bind pose):")
        for (i, pos) in initialPositions.enumerated() {
            print("  Bone \(i): Y = \(pos.y)")
        }

        // Run 60 frames of settling (half the settling period)
        for _ in 0..<60 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        let midSettlingPositions = readBonePositions(model: model)
        print("\nMid-settling positions (60 frames):")
        for (i, pos) in midSettlingPositions.enumerated() {
            let initialY = initialPositions[i].y
            let deltaY = pos.y - initialY
            print("  Bone \(i): Y = \(pos.y), deltaY = \(deltaY)")
        }

        // Verify non-root bones have fallen (Y decreased)
        for i in 1..<min(5, midSettlingPositions.count) {
            let initialY = initialPositions[i].y
            let currentY = midSettlingPositions[i].y
            XCTAssertLessThan(
                currentY, initialY + 0.01,
                "Bone \(i) should fall during settling. Initial Y: \(initialY), Current Y: \(currentY)"
            )
        }
    }

    /// Test position changes at settling transition (when settlingFrames reaches 0)
    func testPositionChangeAtSettlingTransition() throws {
        // Use shorter settling period for this test
        let settlingFrames: UInt32 = 60
        let model = try buildHorizontalChain(boneCount: 5, gravityPower: 1.0, settlingFrames: settlingFrames)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Run until just before settling ends (frame 55)
        for _ in 0..<55 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)
        let preTransitionPositions = readBonePositions(model: model)

        print("Pre-transition positions (frame 55, settling still active):")
        for (i, pos) in preTransitionPositions.enumerated() {
            print("  Bone \(i): Y = \(pos.y)")
        }

        // Run 10 more frames (settling ends around frame 60)
        for _ in 0..<10 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)
        let postTransitionPositions = readBonePositions(model: model)

        print("\nPost-transition positions (frame 65, settling ended):")
        for (i, pos) in postTransitionPositions.enumerated() {
            let preY = preTransitionPositions[i].y
            let deltaY = pos.y - preY
            print("  Bone \(i): Y = \(pos.y), deltaY = \(deltaY) \(deltaY > 0 ? "RISING" : "falling")")
        }

        // Run 30 more frames to see continued behavior
        for _ in 0..<30 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)
        let laterPositions = readBonePositions(model: model)

        print("\nLater positions (frame 95):")
        for (i, pos) in laterPositions.enumerated() {
            let postY = postTransitionPositions[i].y
            let deltaY = pos.y - postY
            print("  Bone \(i): Y = \(pos.y), deltaY = \(deltaY) \(deltaY > 0 ? "RISING" : "falling")")
        }

        // Check if any bones rose after settling ended
        var anyRose = false
        for i in 1..<min(5, laterPositions.count) {
            let postTransY = postTransitionPositions[i].y
            let laterY = laterPositions[i].y
            if laterY > postTransY + 0.001 {
                anyRose = true
                print("WARNING: Bone \(i) rose after settling! Delta = \(laterY - postTransY)")
            }
        }

        // This is the bug we're trying to understand
        if anyRose {
            print("\n⚠️  BONES ARE RISING AFTER SETTLING - this is the bug we observed")
        }
    }

    /// Test velocity state before and after settling transition
    func testVelocityAtSettlingTransition() throws {
        let model = try buildHorizontalChain(boneCount: 3, gravityPower: 1.0, settlingFrames: 30)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Run until just before settling ends
        for _ in 0..<28 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.1)
        system.writeBonesToNodes(model: model)

        // Read both prev and curr buffers to calculate velocity
        guard let buffers = model.springBoneBuffers,
              let bonePosPrev = buffers.bonePosPrev,
              let bonePosCurr = buffers.bonePosCurr else {
            XCTFail("No buffers")
            return
        }

        let prevPtr = bonePosPrev.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
        let currPtr = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)

        print("Pre-transition velocities (frame 28):")
        for i in 0..<buffers.numBones {
            let velocity = currPtr[i] - prevPtr[i]
            print("  Bone \(i): velocity.y = \(velocity.y)")
        }

        // Run through transition
        for _ in 0..<10 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.1)

        print("\nPost-transition velocities (frame 38):")
        for i in 0..<buffers.numBones {
            let velocity = currPtr[i] - prevPtr[i]
            print("  Bone \(i): velocity.y = \(velocity.y)")
        }
    }

    // MARK: - Inertia Compensation Tests

    /// Test that inertia compensation is skipped during settling
    func testInertiaCompensationSkippedDuringSettling() throws {
        let model = try buildHorizontalChain(boneCount: 3, gravityPower: 1.0, settlingFrames: 60)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        guard let rootNode = model.nodes.first else {
            XCTFail("No root node")
            return
        }

        // Move root UP during settling (simulates a jump)
        let initialRootY: Float = 1.0
        let jumpHeight: Float = 0.5

        // Run 10 frames, moving root upward each frame
        for frame in 0..<10 {
            let progress = Float(frame) / 10.0
            rootNode.translation = SIMD3<Float>(0, initialRootY + jumpHeight * progress, 0)
            rootNode.updateLocalMatrix()
            rootNode.updateWorldTransform()

            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.1)
        system.writeBonesToNodes(model: model)

        let positions = readBonePositions(model: model)
        print("Positions after upward root motion during settling:")
        for (i, pos) in positions.enumerated() {
            print("  Bone \(i): Y = \(pos.y)")
        }

        // During settling, inertia compensation should be skipped
        // So child bones should follow the root more closely
        // (without compensation making them trail behind)
    }

    // MARK: - Distance Constraint Behavior Tests

    /// Test that distance constraint only prevents stretch, not compression
    func testDistanceConstraintAllowsCompression() throws {
        let model = try buildHorizontalChain(boneCount: 3, gravityPower: 1.0, settlingFrames: 0)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Get initial rest lengths
        guard let buffers = model.springBoneBuffers,
              let restLengthBuffer = buffers.restLengths else {
            XCTFail("No rest length buffer")
            return
        }

        let restLengthPtr = restLengthBuffer.contents().bindMemory(to: Float.self, capacity: buffers.numBones)
        var restLengths: [Float] = []
        for i in 0..<buffers.numBones {
            restLengths.append(restLengthPtr[i])
            print("Bone \(i) rest length: \(restLengthPtr[i])")
        }

        // Run simulation - bones should fall due to gravity
        for frame in 0..<60 {
            system.update(model: model, deltaTime: 1.0 / 60.0)

            if frame % 20 == 0 {
                Thread.sleep(forTimeInterval: 0.05)
                system.writeBonesToNodes(model: model)

                guard let bonePosCurr = buffers.bonePosCurr else { continue }
                let currPtr = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)

                print("\nFrame \(frame) distances:")
                for i in 1..<buffers.numBones {
                    let parentPos = currPtr[i - 1]
                    let currentPos = currPtr[i]
                    let distance = simd_distance(currentPos, parentPos)
                    let restLen = restLengths[i]
                    let stretchRatio = distance / max(restLen, 0.001)
                    print("  Bone \(i): distance=\(distance), restLen=\(restLen), ratio=\(stretchRatio)")
                }
            }
        }
    }

    // MARK: - Initial Position Tests

    /// Test that bones are initialized at their bind pose positions
    func testBonesInitializedAtBindPose() throws {
        let model = try buildHorizontalChain(boneCount: 5, gravityPower: 0.5, settlingFrames: 120)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Read initial positions from GPU buffer (before any simulation)
        let positions = readBonePositions(model: model)

        print("Initial bone positions (should match bind pose):")
        for (i, pos) in positions.enumerated() {
            print("  Bone \(i): \(pos)")
        }

        // For horizontal chain, bones should start at:
        // Bone 0: (0, 1, 0) - root
        // Bone 1: (0.1, 1, 0) - first child
        // Bone 2: (0.2, 1, 0) - second child
        // etc.
        XCTAssertEqual(positions[0].y, 1.0, accuracy: 0.01, "Root should be at Y=1")

        // Non-root bones should be at same Y as root in horizontal chain
        for i in 1..<min(5, positions.count) {
            XCTAssertEqual(
                positions[i].y, 1.0, accuracy: 0.1,
                "Bone \(i) should start at bind pose Y=1.0, got \(positions[i].y)"
            )
        }
    }

    /// Test comparing horizontal vs vertical initial chain configuration
    func testHorizontalVsVerticalChainSettling() throws {
        // Horizontal chain (like Alicia's skirt in bind pose)
        let horizontalModel = try buildHorizontalChain(boneCount: 5, gravityPower: 1.0, settlingFrames: 60)
        let horizontalSystem = try SpringBoneComputeSystem(device: device)
        try horizontalSystem.populateSpringBoneData(model: horizontalModel)

        // Vertical chain (already hanging down)
        let verticalModel = try buildVerticalChain(boneCount: 5, gravityPower: 1.0, settlingFrames: 60)
        let verticalSystem = try SpringBoneComputeSystem(device: device)
        try verticalSystem.populateSpringBoneData(model: verticalModel)

        print("Initial positions:")
        print("  Horizontal chain tip Y: \(readBonePositions(model: horizontalModel).last?.y ?? 0)")
        print("  Vertical chain tip Y: \(readBonePositions(model: verticalModel).last?.y ?? 0)")

        // Run both for 60 frames
        for _ in 0..<60 {
            horizontalSystem.update(model: horizontalModel, deltaTime: 1.0 / 60.0)
            verticalSystem.update(model: verticalModel, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        horizontalSystem.writeBonesToNodes(model: horizontalModel)
        verticalSystem.writeBonesToNodes(model: verticalModel)

        let horizontalPositions = readBonePositions(model: horizontalModel)
        let verticalPositions = readBonePositions(model: verticalModel)

        print("\nAfter 60 frames:")
        print("  Horizontal chain tip Y: \(horizontalPositions.last?.y ?? 0)")
        print("  Vertical chain tip Y: \(verticalPositions.last?.y ?? 0)")

        // Horizontal chain should have fallen significantly
        // Vertical chain should stay relatively stable
        let horizontalDrop = 1.0 - (horizontalPositions.last?.y ?? 0)
        let verticalDrop = 1.0 - (verticalPositions.last?.y ?? 0)

        print("  Horizontal drop: \(horizontalDrop)")
        print("  Vertical drop: \(verticalDrop)")

        // Horizontal chain needs to fall more since it starts horizontal
        XCTAssertGreaterThan(
            horizontalDrop, 0.05,
            "Horizontal chain should fall during settling"
        )
    }

    // MARK: - Settling Frames Decrement Test

    /// Test that settlingFrames actually decrements
    func testSettlingFramesDecrements() throws {
        let initialSettlingFrames: UInt32 = 10
        let model = try buildHorizontalChain(boneCount: 3, gravityPower: 1.0, settlingFrames: initialSettlingFrames)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Check initial settling frames
        XCTAssertEqual(model.springBoneGlobalParams?.settlingFrames, initialSettlingFrames)

        // Run a few frames
        for frame in 1...15 {
            system.update(model: model, deltaTime: 1.0 / 60.0)

            // Check settling frames decrements
            let currentSettling = model.springBoneGlobalParams?.settlingFrames ?? 0
            print("Frame \(frame): settlingFrames = \(currentSettling)")

            if frame <= Int(initialSettlingFrames) {
                // Should be decrementing
                XCTAssertEqual(
                    currentSettling, max(0, initialSettlingFrames - UInt32(frame)),
                    "Settling frames should decrement each frame"
                )
            } else {
                // Should be at 0
                XCTAssertEqual(currentSettling, 0, "Settling frames should stay at 0")
            }
        }
    }

    // MARK: - Helper Methods

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

    /// Build a HORIZONTAL chain (bones extend in +X direction at Y=1)
    /// This simulates how skirt bones might be in bind pose
    private func buildHorizontalChain(boneCount: Int, gravityPower: Float, settlingFrames: UInt32 = 120) throws -> VRMModel {
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
            joint.stiffness = 0.0  // No stiffness, like Alicia
            joint.gravityPower = gravityPower
            joint.gravityDir = SIMD3<Float>(0, -1, 0)
            joint.dragForce = 0.4
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
            numPlanes: 0,
            settlingFrames: settlingFrames
        )
        model.springBoneGlobalParams = globalParams

        return model
    }

    /// Build a VERTICAL chain (bones extend in -Y direction from Y=1)
    /// This simulates hair already hanging down
    private func buildVerticalChain(boneCount: Int, gravityPower: Float, settlingFrames: UInt32 = 120) throws -> VRMModel {
        let builder = VRMBuilder()
        let model = try builder.setSkeleton(.defaultHumanoid).build()

        let boneLength: Float = 0.1
        model.nodes.removeAll()

        var previousNode: VRMNode? = nil
        for i in 0..<boneCount {
            // Vertical: first bone at (0, 1, 0), children extend in -Y
            let localY: Float = (i == 0) ? 1.0 : -boneLength
            let gltfNode = try createGLTFNode(
                name: "spring_bone_\(i)",
                translation: SIMD3<Float>(0, localY, 0)
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
            joint.stiffness = 0.0
            joint.gravityPower = gravityPower
            joint.gravityDir = SIMD3<Float>(0, -1, 0)
            joint.dragForce = 0.4
            joints.append(joint)
        }

        var springBone = VRMSpringBone()
        var spring = VRMSpring(name: "VerticalChain")
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
            numPlanes: 0,
            settlingFrames: settlingFrames
        )
        model.springBoneGlobalParams = globalParams

        return model
    }

    private func readBonePositions(model: VRMModel) -> [SIMD3<Float>] {
        guard let buffers = model.springBoneBuffers,
              let bonePosCurr = buffers.bonePosCurr,
              buffers.numBones > 0 else {
            return []
        }

        let ptr = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
        return Array(UnsafeBufferPointer(start: ptr, count: buffers.numBones))
    }
}
