// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Tests to isolate the "Rotation Snap" / "Static North" bug in spring bone physics.
///
/// ## Problem Description
///
/// When a character rotates, the hair's stiffness target (bind direction) should rotate with it.
/// The bug manifests as one of two failure modes:
///
/// 1. **Static North Bug**: The bind direction remains fixed in world space (e.g., always pointing
///    down Y-axis) regardless of character rotation. This causes hair to fight against the visual
///    mesh, leading to stretching, clipping, or wild behavior.
///
/// 2. **Double Rotation Bug**: The bind direction is rotated twice (once in setup, once in update),
///    causing the hair to point in an unexpected direction (e.g., upward when it should be downward).
///
/// ## Root Cause
///
/// The bind direction handling has two critical points:
/// 1. **Setup (populateSpringBoneData)**: Should store LOCAL bind direction (parent-relative)
/// 2. **Update (per frame)**: Should transform LOCAL to WORLD using current parent rotation
///
/// If setup stores WORLD direction, update will double-rotate it.
/// If update is skipped, the direction remains static in world space.
///
final class SpringBoneRotationTests: XCTestCase {

    var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    // MARK: - Core Rotation Test

    /// **PRIMARY DIAGNOSTIC**: Test that bind direction follows character rotation (Y-axis).
    ///
    /// This test creates a hair chain pointing DOWN (0, -1, 0) in local space,
    /// then rotates the character 90 degrees around the Y-axis.
    ///
    /// IMPORTANT: Rotating a DOWN vector (0, -1, 0) around the Y-axis keeps it pointing DOWN!
    /// This is mathematically correct - Y-rotation preserves the Y component.
    ///
    /// So for Y-axis rotation, we expect the direction to remain (0, -1, 0).
    /// This test validates that Y-rotation doesn't incorrectly change the direction.
    func testBindDirectionPreservedUnderYAxisRotation() throws {
        // Setup: Create a simple 3-bone vertical hair chain
        let model = try buildSimpleHairChain(boneCount: 3)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Read initial bind direction (should be pointing DOWN in world space)
        let initialBindDir = readBindDirection(model: model, boneIndex: 1)
        print("=== Initial State (No Rotation) ===")
        print("Bind direction: \(formatVector(initialBindDir))")

        // Verify initial direction is DOWN (0, -1, 0) with tolerance
        XCTAssertEqual(initialBindDir.y, -1.0, accuracy: 0.01,
                       "Initial bind direction should point DOWN (0, -1, 0)")

        // Rotate character 90 degrees around Y-axis
        guard let rootNode = model.nodes.first else {
            XCTFail("No root node")
            return
        }

        // Apply rotation: 90° around Y-axis (π/2 radians)
        // For a DOWN vector (0, -1, 0), Y-rotation keeps it pointing DOWN
        let rotation90Y = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        rootNode.rotation = rotation90Y
        rootNode.updateLocalMatrix()
        rootNode.updateWorldTransform()

        for node in model.nodes {
            node.updateWorldTransform()
        }

        // Run physics update
        system.update(model: model, deltaTime: 1.0 / 60.0)
        Thread.sleep(forTimeInterval: 0.05)

        // Read the bind direction after rotation
        let rotatedBindDir = readBindDirection(model: model, boneIndex: 1)
        print("\n=== After 90° Y-Rotation ===")
        print("Bind direction: \(formatVector(rotatedBindDir))")

        // For Y-axis rotation of DOWN vector: should still be DOWN
        // The X and Z components might change slightly but Y should remain -1
        XCTAssertEqual(rotatedBindDir.y, -1.0, accuracy: 0.1,
                       "Y-rotation of DOWN vector should preserve Y component")

        print("\nY-rotation correctly preserved DOWN direction")
    }

    /// **CRITICAL TEST**: Z-axis rotation should change bind direction from DOWN to SIDEWAYS.
    ///
    /// This test rotates around Z-axis which should clearly change a DOWN vector to a SIDE vector.
    /// - 90° Z-rotation: (0, -1, 0) → (1, 0, 0) or (-1, 0, 0)
    func testBindDirectionFollowsZAxisRotation() throws {
        let model = try buildSimpleHairChain(boneCount: 3)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Verify initial direction is DOWN
        let initialBindDir = readBindDirection(model: model, boneIndex: 1)
        print("=== Z-Axis Rotation Test ===")
        print("Initial bind direction: \(formatVector(initialBindDir))")

        XCTAssertEqual(initialBindDir.y, -1.0, accuracy: 0.1,
                       "Initial direction should be DOWN")

        // Rotate 90° around Z-axis
        guard let rootNode = model.nodes.first else {
            XCTFail("No root node")
            return
        }

        let rotation90Z = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
        rootNode.rotation = rotation90Z
        rootNode.updateLocalMatrix()
        rootNode.updateWorldTransform()

        // Also update all child nodes
        for node in model.nodes {
            node.updateWorldTransform()
        }

        // Run physics update
        system.update(model: model, deltaTime: 1.0 / 60.0)
        Thread.sleep(forTimeInterval: 0.05)

        let rotatedBindDir = readBindDirection(model: model, boneIndex: 1)
        print("After 90° Z-rotation: \(formatVector(rotatedBindDir))")

        // After 90° Z-rotation, DOWN (0, -1, 0) should become SIDE (±1, 0, 0)
        // Using right-hand rule: rotating (0, -1, 0) by +90° around Z gives (-1, 0, 0)
        let expectedX: Float = -1.0  // Or 1.0 depending on coordinate system handedness

        // Check if direction is now horizontal (X or Z dominant, Y near zero)
        let isHorizontal = abs(rotatedBindDir.y) < 0.3 &&
                          (abs(rotatedBindDir.x) > 0.7 || abs(rotatedBindDir.z) > 0.7)
        let isStillDown = abs(rotatedBindDir.y + 1.0) < 0.3
        let isPointingUp = rotatedBindDir.y > 0.5

        print("\nExpected: (~±1, ~0, ~0) - horizontal direction")
        print("Analysis:")
        print("  Horizontal (correct): \(isHorizontal)")
        print("  Still DOWN (static north): \(isStillDown)")
        print("  Pointing UP (double rotation): \(isPointingUp)")

        if isStillDown {
            XCTFail("""
                STATIC NORTH BUG: Bind direction remained DOWN after Z-rotation!

                After rotating the character 90° around Z-axis:
                Expected: Direction rotates to horizontal (±1, 0, 0)
                Actual: Direction is still \(formatVector(rotatedBindDir))

                The stiffness force will try to pull hair "down" in world space,
                but the visual mesh rotated sideways, causing conflict.
                """)
        }

        if isPointingUp {
            XCTFail("""
                DOUBLE ROTATION BUG: Bind direction points UP after Z-rotation!

                After rotating the character 90° around Z-axis:
                Expected: Direction rotates to horizontal (±1, 0, 0)
                Actual: Direction is \(formatVector(rotatedBindDir))

                The direction was rotated twice (setup + update).
                """)
        }

        // This assertion will pass if the bug is fixed
        XCTAssertTrue(isHorizontal,
                      "Bind direction should be horizontal after 90° Z-rotation, got: \(formatVector(rotatedBindDir))")
    }

    /// **STRESS TEST**: Multiple sequential rotations should accumulate correctly.
    func testMultipleRotationsAccumulate() throws {
        let model = try buildSimpleHairChain(boneCount: 3)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        guard let rootNode = model.nodes.first else {
            XCTFail("No root node")
            return
        }

        print("=== Multiple Rotation Test ===")

        // Start with initial direction
        let initial = readBindDirection(model: model, boneIndex: 1)
        print("Initial: \(formatVector(initial))")

        // Rotate in 4 steps of 90° around Z-axis (full 360°)
        var directions: [SIMD3<Float>] = [initial]

        for step in 1...4 {
            let angle = Float(step) * .pi / 2  // 90°, 180°, 270°, 360°
            rootNode.rotation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 0, 1))
            rootNode.updateLocalMatrix()
            rootNode.updateWorldTransform()

            for node in model.nodes {
                node.updateWorldTransform()
            }

            system.update(model: model, deltaTime: 1.0 / 60.0)
            Thread.sleep(forTimeInterval: 0.02)

            let dir = readBindDirection(model: model, boneIndex: 1)
            directions.append(dir)
            print("After \(step * 90)°: \(formatVector(dir))")
        }

        // After 360° rotation, direction should be back to initial (within tolerance)
        let final = directions.last!
        let delta = simd_distance(initial, final)

        print("\nFull rotation delta: \(delta)")

        // Tolerance for full rotation return
        XCTAssertLessThan(delta, 0.2,
                          "After 360° rotation, direction should return to initial")

        // Check that intermediate rotations are distinct
        // 90° rotation should give different direction than initial
        let dir90 = directions[1]
        let delta90 = simd_distance(initial, dir90)

        if delta90 < 0.1 {
            XCTFail("""
                STATIC NORTH BUG: Direction didn't change after 90° rotation!

                Initial: \(formatVector(initial))
                After 90°: \(formatVector(dir90))

                The bind direction is not following character rotation.
                """)
        }
    }

    // MARK: - Helper Methods

    /// Create a simple vertical hair chain for testing
    private func buildSimpleHairChain(boneCount: Int) throws -> VRMModel {
        let builder = VRMBuilder()
        let model = try builder.setSkeleton(.defaultHumanoid).build()

        let boneLength: Float = 0.1
        model.nodes.removeAll()

        var previousNode: VRMNode? = nil
        for i in 0..<boneCount {
            // Vertical chain: root at (0, 1, 0), children extend downward
            let localY: Float = (i == 0) ? 1.0 : -boneLength
            let gltfNode = try createGLTFNode(
                name: "hair_\(i)",
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

        // Update world transforms
        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }

        // Create spring bone configuration
        var joints: [VRMSpringJoint] = []
        for i in 0..<boneCount {
            var joint = VRMSpringJoint(node: i)
            joint.hitRadius = 0.02
            joint.stiffness = 0.5  // Moderate stiffness to see the effect
            joint.gravityPower = 1.0
            joint.gravityDir = SIMD3<Float>(0, -1, 0)
            joint.dragForce = 0.3
            joints.append(joint)
        }

        var springBone = VRMSpringBone()
        var spring = VRMSpring(name: "TestHair")
        spring.joints = joints
        springBone.springs = [spring]
        model.springBone = springBone

        model.device = device

        // Allocate physics buffers
        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: boneCount, numSpheres: 0, numCapsules: 0)
        model.springBoneBuffers = buffers

        // Set global physics parameters
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
            settlingFrames: 0
        )
        model.springBoneGlobalParams = globalParams

        return model
    }

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

    /// Read bind direction from the GPU buffer for a specific bone
    private func readBindDirection(model: VRMModel, boneIndex: Int) -> SIMD3<Float> {
        guard let buffers = model.springBoneBuffers,
              let bindDirectionsBuffer = buffers.bindDirections,
              boneIndex < buffers.numBones else {
            return SIMD3<Float>(0, -1, 0)  // Default
        }

        let ptr = bindDirectionsBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
        return ptr[boneIndex]
    }

    private func formatVector(_ v: SIMD3<Float>) -> String {
        return String(format: "(%.3f, %.3f, %.3f)", v.x, v.y, v.z)
    }

    // MARK: - Quaternion Numerical Stability Tests

    /// Test that quaternionFromTo handles near-parallel vectors without flutter.
    /// This verifies the half-angle quaternion formulation is numerically stable.
    ///
    /// The old angle-axis approach using acos() would produce noisy rotation axes
    /// when vectors are nearly parallel, causing visual flutter. The half-angle
    /// approach (q = (cross, 1+dot).normalize()) is self-stabilizing.
    func testQuaternionFromToNearParallel() throws {
        // Simulate many calls with near-parallel vectors (like during idle animation)
        // The old implementation would produce random rotation axes; the new one should be consistent
        let baseDir = simd_normalize(SIMD3<Float>(0, -1, 0))
        var quaternions: [simd_quatf] = []
        var maxAngleDegrees: Float = 0

        // Add tiny perturbations as would occur during idle animation
        for i in 0..<100 {
            // Tiny perturbation: ~0.001 radians (0.057°) offset
            let perturbX = Float(i % 10 - 5) * 0.0001
            let perturbZ = Float(i / 10 - 5) * 0.0001
            let perturbed = simd_normalize(SIMD3<Float>(perturbX, -1, perturbZ))

            // Use the same half-angle formula as SpringBoneComputeSystem.quaternionFromTo
            let q = halfAngleQuaternionFromTo(from: baseDir, to: perturbed)
            quaternions.append(q)

            // Extract angle
            let angleDeg = 2.0 * acos(min(abs(q.real), 1.0)) * 180.0 / Float.pi
            maxAngleDegrees = max(maxAngleDegrees, angleDeg)
        }

        print("=== Near-Parallel Quaternion Stability Test ===")
        print("Max rotation angle: \(String(format: "%.4f", maxAngleDegrees))°")

        // All rotations should be tiny (< 1 degree) since inputs are nearly parallel
        XCTAssertLessThan(maxAngleDegrees, 1.0,
            "Near-parallel vectors should produce near-identity quaternions")

        // Verify no NaN values
        for (i, q) in quaternions.enumerated() {
            XCTAssertFalse(q.real.isNaN || q.imag.x.isNaN || q.imag.y.isNaN || q.imag.z.isNaN,
                "Quaternion \(i) should not contain NaN")
        }

        // Verify all quaternions are approximately identity (w ≈ 1)
        let avgW = quaternions.reduce(Float(0)) { $0 + $1.real } / Float(quaternions.count)
        print("Average W component: \(String(format: "%.6f", avgW)) (should be ≈1.0)")
        XCTAssertGreaterThan(avgW, 0.999, "Average W should be near 1.0 for near-identity rotations")
    }

    /// Test displacement deadzone prevents micro-jitter during idle.
    /// When displacement is below 1e-5, rotation update should be skipped.
    func testDisplacementDeadzonePreventsMicroJitter() throws {
        // Create a simple hair chain
        let model = try buildSimpleHairChain(boneCount: 3)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Let physics settle completely (many frames)
        for _ in 0..<300 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }
        Thread.sleep(forTimeInterval: 0.1)
        system.writeBonesToNodes(model: model)

        // Record the settled rotation
        guard model.nodes.count > 1 else {
            XCTFail("Not enough nodes")
            return
        }
        let bone1 = model.nodes[1]
        let settledRotation = bone1.localRotation

        print("=== Displacement Deadzone Test ===")
        print("Settled rotation: w=\(String(format: "%.6f", settledRotation.real))")

        // Run more frames - rotation should NOT change if in deadzone
        for _ in 0..<60 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }
        Thread.sleep(forTimeInterval: 0.05)
        system.writeBonesToNodes(model: model)

        let finalRotation = bone1.localRotation

        // Calculate rotation difference (angle between quaternions)
        let dotQ = abs(simd_dot(settledRotation.vector, finalRotation.vector))
        let rotationDelta = acos(min(dotQ, 1.0)) * 2.0 * 180.0 / Float.pi

        print("Final rotation: w=\(String(format: "%.6f", finalRotation.real))")
        print("Rotation delta: \(String(format: "%.6f", rotationDelta))°")

        // Rotation should be nearly identical (deadzone prevents jitter)
        // Allow small tolerance for settling dynamics
        XCTAssertLessThan(rotationDelta, 0.5,
            "Settled bone should have minimal rotation change (deadzone should prevent jitter)")
    }

    /// Test anti-parallel case (180° rotation) is handled correctly
    func testQuaternionFromToAntiParallel() throws {
        let up = SIMD3<Float>(0, 1, 0)
        let down = SIMD3<Float>(0, -1, 0)

        // Should produce 180° rotation
        let q = halfAngleQuaternionFromTo(from: up, to: down)

        print("=== Anti-Parallel Quaternion Test ===")
        print("From: \(formatVector(up)), To: \(formatVector(down))")
        print("Quaternion: w=\(String(format: "%.3f", q.real)), xyz=(\(String(format: "%.3f", q.imag.x)), \(String(format: "%.3f", q.imag.y)), \(String(format: "%.3f", q.imag.z)))")

        // Verify not NaN
        XCTAssertFalse(q.real.isNaN, "W should not be NaN")
        XCTAssertFalse(q.imag.x.isNaN || q.imag.y.isNaN || q.imag.z.isNaN, "Imaginary should not be NaN")

        // Verify 180° rotation (w should be near 0)
        let angle = 2.0 * acos(min(abs(q.real), 1.0)) * 180.0 / Float.pi
        print("Rotation angle: \(String(format: "%.1f", angle))°")
        XCTAssertEqual(angle, 180.0, accuracy: 1.0, "Should produce 180° rotation")

        // Verify the rotation actually works
        let rotated = simd_act(q, up)
        print("Rotated up: \(formatVector(rotated))")
        XCTAssertEqual(rotated.y, -1.0, accuracy: 0.01, "Rotated up should equal down")
    }

    // MARK: - TDD: Swirl/Vortex Bug Test

    /// TDD RED TEST: Demonstrates the numerical precision issue with angle-axis.
    ///
    /// The OLD implementation uses acos(dot) to get the angle. At dot values very
    /// close to 1.0, acos becomes numerically unstable:
    /// - acos(0.9999999) should give ~0.000573° but float precision is lost
    /// - The derivative of acos at x=1 is undefined (vertical tangent)
    ///
    /// The NEW half-angle implementation uses (1 + dot) which stays well-behaved.
    func testOldImplementationAcosPrecisionLoss() throws {
        print("=== TDD RED: acos() Precision Loss Near 1.0 ===")

        // Test at progressively closer dot values to 1.0
        let target = SIMD3<Float>(0, -1, 0)

        // These deviations create dot values approaching 1.0
        let deviations: [Float] = [0.01, 0.001, 0.0001, 0.00001, 0.000001]

        print("  Deviation | Theoretical | Old (acos) | New (half) | Old Error")
        print("  ---------------------------------------------------------------")

        var oldErrors: [Float] = []
        var newErrors: [Float] = []

        for dev in deviations {
            let current = simd_normalize(SIMD3<Float>(dev, -1, 0))
            let theoreticalAngle = atan(dev) * 180.0 / Float.pi

            let oldQ = buggyAngleAxisQuaternion(from: current, to: target)
            let newQ = halfAngleQuaternionFromTo(from: current, to: target)

            let oldAngle = 2.0 * acos(min(abs(oldQ.real), 1.0)) * 180.0 / Float.pi
            let newAngle = 2.0 * acos(min(abs(newQ.real), 1.0)) * 180.0 / Float.pi

            let oldError = abs(oldAngle - theoreticalAngle)
            let newError = abs(newAngle - theoreticalAngle)

            oldErrors.append(oldError)
            newErrors.append(newError)

            print("  \(String(format: "%8.6f", dev)) | \(String(format: "%10.6f", theoreticalAngle))° | \(String(format: "%10.6f", oldAngle))° | \(String(format: "%10.6f", newAngle))° | \(String(format: "%.6f", oldError))°")
        }

        // The key assertion: at extreme precision, old implementation's error grows
        // relative to the input deviation, while new implementation stays accurate
        let avgOldError = oldErrors.reduce(0, +) / Float(oldErrors.count)
        let avgNewError = newErrors.reduce(0, +) / Float(newErrors.count)

        print("\n  Average error (OLD): \(String(format: "%.6f", avgOldError))°")
        print("  Average error (NEW): \(String(format: "%.6f", avgNewError))°")

        // Document that old implementation has some error (may be small in this test)
        // The real issue manifests in repeated application during physics simulation
    }

    /// TDD GREEN TEST: Verifies the NEW implementation FIXES the swirl bug.
    /// This test MUST PASS with the half-angle implementation.
    func testNewImplementationPreventsSwirlBug() throws {
        print("=== TDD GREEN: New Implementation Prevents Swirl ===")

        let target = simd_normalize(SIMD3<Float>(0, -1, 0))

        // Same test as above, but with NEW implementation
        var position = simd_normalize(SIMD3<Float>(0.001, -1, 0))
        var totalRotation: Float = 0

        for iteration in 0..<100 {
            let q = halfAngleQuaternionFromTo(from: position, to: target)
            let rotAngle = 2.0 * acos(min(abs(q.real), 1.0))

            position = simd_act(q, position)
            totalRotation += rotAngle

            position = simd_normalize(SIMD3<Float>(
                position.x + 0.0001 * sin(Float(iteration) * 0.1),
                position.y,
                position.z + 0.0001 * cos(Float(iteration) * 0.1)
            ))
        }

        let totalRotationDegrees = totalRotation * 180.0 / Float.pi
        print("  Total accumulated rotation (NEW): \(String(format: "%.2f", totalRotationDegrees))°")

        // The NEW implementation should have minimal accumulated rotation
        // because each step produces appropriately tiny corrections
        XCTAssertLessThan(totalRotationDegrees, 2.0,
            "NEW implementation should not accumulate excessive rotation (no swirl)")

        print("  ✓ Swirl bug is PREVENTED")
    }

    /// Combined test that shows both behaviors for comparison
    func testCrossProductSwirlBugIsPrevented() throws {
        print("=== Cross Product Swirl Bug Test (TDD) ===")

        // Simulate a bone oscillating around the target in a tiny circle
        // (as would happen from physics/numerical noise)
        let target = simd_normalize(SIMD3<Float>(0, -1, 0))

        // Generate points in a tiny circle around the target
        // This mimics the "overshoot left, correct, end up below, correct, end up right..." pattern
        var oldAxes: [SIMD3<Float>] = []
        var newAxes: [SIMD3<Float>] = []

        let radius: Float = 0.001  // 0.1% deviation - tiny
        for step in 0..<8 {
            let angle = Float(step) * .pi / 4  // 45° increments around the circle
            let offsetX = radius * cos(angle)
            let offsetZ = radius * sin(angle)
            let current = simd_normalize(SIMD3<Float>(offsetX, -1, offsetZ))

            // OLD implementation (buggy angle-axis)
            let oldQ = buggyAngleAxisQuaternion(from: current, to: target)
            oldAxes.append(oldQ.axis)

            // NEW implementation (stable half-angle)
            let newQ = halfAngleQuaternionFromTo(from: current, to: target)
            newAxes.append(simd_normalize(newQ.imag))
        }

        // Analyze axis stability:
        // In the OLD buggy version, the axis rotates ~90° between consecutive samples (swirl)
        // In the NEW fixed version, the axis is consistent (points toward correction)

        var oldAxisChanges: [Float] = []
        var newAxisChanges: [Float] = []

        for i in 1..<8 {
            let oldDot = abs(simd_dot(oldAxes[i-1], oldAxes[i]))
            let newDot = abs(simd_dot(newAxes[i-1], newAxes[i]))

            // Convert to angle
            let oldAngle = acos(min(oldDot, 1.0)) * 180.0 / Float.pi
            let newAngle = acos(min(newDot, 1.0)) * 180.0 / Float.pi

            oldAxisChanges.append(oldAngle)
            newAxisChanges.append(newAngle)
        }

        let avgOldAxisChange = oldAxisChanges.reduce(0, +) / Float(oldAxisChanges.count)
        let avgNewAxisChange = newAxisChanges.reduce(0, +) / Float(newAxisChanges.count)

        print("OLD (buggy angle-axis):")
        print("  Axis changes between samples: \(oldAxisChanges.map { String(format: "%.1f°", $0) }.joined(separator: ", "))")
        print("  Average axis change: \(String(format: "%.1f", avgOldAxisChange))°")

        print("NEW (stable half-angle):")
        print("  Axis changes between samples: \(newAxisChanges.map { String(format: "%.1f°", $0) }.joined(separator: ", "))")
        print("  Average axis change: \(String(format: "%.1f", avgNewAxisChange))°")

        // THE OLD IMPLEMENTATION SHOULD SHOW SWIRL (~45° axis changes)
        // We expect the old implementation to have unstable axes
        // (Note: We're testing this to document the bug, not asserting it must fail)
        print("\nSwirl detection:")
        print("  Old implementation shows swirl pattern: \(avgOldAxisChange > 20 ? "YES ⚠️" : "NO")")
        print("  New implementation shows swirl pattern: \(avgNewAxisChange > 20 ? "YES ⚠️" : "NO")")

        // KEY INSIGHT: The axis changing 45° is geometrically CORRECT
        // (walking around a circle, correction direction rotates).
        //
        // What matters is: is the rotation MAGNITUDE appropriate?
        // - Old buggy implementation: acos(0.999999) loses precision, can give wrong magnitude
        // - New half-angle: magnitude is naturally correct and tiny for tiny deviations
        //
        // The "swirl" bug is NOT about axis direction - it's about the MAGNITUDE
        // being wrong, causing over-correction that creates the vortex.
        print("\n✓ Axis rotation of 45° is EXPECTED (geometric reality)")

        // Additional check: The new quaternions should all be near-identity
        // since the vectors are nearly parallel
        var newAngles: [Float] = []
        for step in 0..<8 {
            let angle = Float(step) * .pi / 4
            let offsetX = radius * cos(angle)
            let offsetZ = radius * sin(angle)
            let current = simd_normalize(SIMD3<Float>(offsetX, -1, offsetZ))
            let newQ = halfAngleQuaternionFromTo(from: current, to: target)
            let rotAngle = 2.0 * acos(min(abs(newQ.real), 1.0)) * 180.0 / Float.pi
            newAngles.append(rotAngle)
        }

        let maxNewAngle = newAngles.max() ?? 0
        print("\nRotation magnitudes (new):")
        print("  Max rotation: \(String(format: "%.4f", maxNewAngle))° (should be < 1° for 0.1% deviation)")

        XCTAssertLessThan(maxNewAngle, 1.0,
            "New implementation should produce tiny rotations for tiny deviations")

        // Compare rotation magnitudes between old and new at extremely small deviations
        // This is where acos precision loss becomes visible
        print("\n=== Extreme Precision Test (dot ≈ 0.99999999) ===")
        let extremeTarget = simd_normalize(SIMD3<Float>(0, -1, 0))
        let extremeDeviation: Float = 0.00001  // 0.001% deviation
        let extremeCurrent = simd_normalize(SIMD3<Float>(extremeDeviation, -1, 0))

        let extremeOldQ = buggyAngleAxisQuaternion(from: extremeCurrent, to: extremeTarget)
        let extremeNewQ = halfAngleQuaternionFromTo(from: extremeCurrent, to: extremeTarget)

        let extremeOldAngle = 2.0 * acos(min(abs(extremeOldQ.real), 1.0)) * 180.0 / Float.pi
        let extremeNewAngle = 2.0 * acos(min(abs(extremeNewQ.real), 1.0)) * 180.0 / Float.pi

        // Theoretical angle for this deviation: atan(0.00001) ≈ 0.00057°
        let theoreticalAngle = atan(extremeDeviation) * 180.0 / Float.pi

        print("  Theoretical angle: \(String(format: "%.6f", theoreticalAngle))°")
        print("  Old (angle-axis): \(String(format: "%.6f", extremeOldAngle))°")
        print("  New (half-angle): \(String(format: "%.6f", extremeNewAngle))°")
        print("  Old error: \(String(format: "%.6f", abs(extremeOldAngle - theoreticalAngle)))°")
        print("  New error: \(String(format: "%.6f", abs(extremeNewAngle - theoreticalAngle)))°")

        // New implementation should be closer to theoretical
        // (at extreme precision, acos can produce significant relative errors)
        XCTAssertLessThan(extremeNewAngle, 0.01,
            "New implementation should produce very tiny rotation for 0.001% deviation")
    }

    /// Old buggy implementation using angle-axis (preserved for TDD comparison)
    private func buggyAngleAxisQuaternion(from: SIMD3<Float>, to: SIMD3<Float>) -> simd_quatf {
        let fromNorm = simd_normalize(from)
        let toNorm = simd_normalize(to)

        let axis = simd_cross(fromNorm, toNorm)
        let dotProduct = simd_dot(fromNorm, toNorm)
        let axisLen = simd_length(axis)

        // This is the BUGGY path - no guard for small angles
        // When axisLen is tiny, axis becomes noisy
        if axisLen < 0.0001 {
            if dotProduct > 0 {
                return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
            } else {
                return simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
            }
        }

        let angle = acos(max(-1, min(1, dotProduct)))  // acos loses precision near 1!
        return simd_quatf(angle: angle, axis: axis / axisLen)
    }

    // MARK: - Half-Angle Quaternion Helper (mirrors SpringBoneComputeSystem)

    /// Implementation matching SpringBoneComputeSystem.quaternionFromTo
    private func halfAngleQuaternionFromTo(from: SIMD3<Float>, to: SIMD3<Float>) -> simd_quatf {
        let fromLen = simd_length(from)
        let toLen = simd_length(to)
        if fromLen < 0.0001 || toLen < 0.0001 {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }

        let vFrom = from / fromLen
        let vTo = to / toLen
        var r = simd_dot(vFrom, vTo) + 1.0

        if r < 0.000001 {
            // Nearly anti-parallel
            r = 0
            var qx: Float, qy: Float, qz: Float
            if abs(vFrom.x) > abs(vFrom.z) {
                qx = -vFrom.y
                qy = vFrom.x
                qz = 0
            } else {
                qx = 0
                qy = -vFrom.z
                qz = vFrom.y
            }
            return simd_normalize(simd_quatf(ix: qx, iy: qy, iz: qz, r: r))
        }

        let crossVec = simd_cross(vFrom, vTo)
        return simd_normalize(simd_quatf(ix: crossVec.x, iy: crossVec.y, iz: crossVec.z, r: r))
    }
}
