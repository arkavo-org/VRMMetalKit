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
import simd
@testable import VRMMetalKit

/// Tests for ARKitBodyDriver coordinate conversion (ARKit to glTF/VRM)
///
/// These tests validate the coordinate system conversion that transforms ARKit's
/// right-handed Y-up (-Z forward) coordinate system to glTF's right-handed Y-up
/// (+Z forward) coordinate system by negating the Z component of quaternions.
///
/// All tests exercise the actual implementation through `driver.update()` or
/// direct access to internal state (arkitParentMap).
final class ARKitBodyDriverCoordinateTests: XCTestCase {

    // MARK: - Parent Hierarchy Validation Tests

    /// Test that parent hierarchy map contains all expected bone relationships
    func testParentHierarchyMapCompleteness() {
        let expectedMappings: [ARKitJoint: ARKitJoint] = [
            .spine: .hips,
            .chest: .spine,
            .upperChest: .chest,
            .neck: .upperChest,
            .head: .neck,
            .leftShoulder: .upperChest,
            .leftUpperArm: .leftShoulder,
            .leftLowerArm: .leftUpperArm,
            .leftHand: .leftLowerArm,
            .rightShoulder: .upperChest,
            .rightUpperArm: .rightShoulder,
            .rightLowerArm: .rightUpperArm,
            .rightHand: .rightLowerArm,
            .leftUpperLeg: .hips,
            .leftLowerLeg: .leftUpperLeg,
            .leftFoot: .leftLowerLeg,
            .leftToes: .leftFoot,
            .rightUpperLeg: .hips,
            .rightLowerLeg: .rightUpperLeg,
            .rightFoot: .rightLowerLeg,
            .rightToes: .rightFoot
        ]

        // Verify each expected mapping exists in the actual parent map
        for (child, expectedParent) in expectedMappings {
            XCTAssertEqual(
                ARKitBodyDriver.arkitParentMap[child],
                expectedParent,
                "Parent of \(child) should be \(expectedParent)"
            )
        }

        // Verify the map has exactly the expected count (no extra entries)
        XCTAssertEqual(ARKitBodyDriver.arkitParentMap.count, expectedMappings.count,
                      "Parent map should have exactly \(expectedMappings.count) entries")
    }

    /// Test that hips (root) has no parent in the map
    func testHipsHasNoParent() {
        XCTAssertNil(ARKitBodyDriver.arkitParentMap[.hips], "Hips should have no parent (it's the root)")
    }

    /// Test that root joint has no parent in the map
    func testRootHasNoParent() {
        XCTAssertNil(ARKitBodyDriver.arkitParentMap[.root], "Root should have no parent")
    }

    // MARK: - Integration Tests: Identity & Basic Rotation

    /// Test that identity transform produces identity rotation
    func testIdentityTransformProducesIdentityRotation() {
        let driver = createDriver()
        let (nodes, humanoid) = createTestHumanoidSetup()

        let skeleton = ARKitBodySkeleton(
            timestamp: Date().timeIntervalSinceReferenceDate,
            joints: [.hips: simd_float4x4(1)],  // Identity transform
            isTracked: true
        )

        driver.update(skeleton: skeleton, nodes: nodes, humanoid: humanoid)

        // Identity input should produce identity output
        XCTAssertEqual(nodes[0].rotation.real, 1.0, accuracy: 0.001, "Real should be 1 (identity)")
        XCTAssertEqual(nodes[0].rotation.imag.x, 0.0, accuracy: 0.001, "X should be 0 (identity)")
        XCTAssertEqual(nodes[0].rotation.imag.y, 0.0, accuracy: 0.001, "Y should be 0 (identity)")
        XCTAssertEqual(nodes[0].rotation.imag.z, 0.0, accuracy: 0.001, "Z should be 0 (identity)")
    }

    /// Test that Z-axis rotation has Z component negated after coordinate conversion
    func testZAxisRotationNegatesZComponent() {
        let driver = createDriver()
        let (nodes, humanoid) = createTestHumanoidSetup()

        // 45° rotation around Z axis - this has non-zero Z in quaternion
        let rotZ45 = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 0, 1))
        let transform = simd_float4x4(rotZ45)

        let skeleton = ARKitBodySkeleton(
            timestamp: Date().timeIntervalSinceReferenceDate,
            joints: [.hips: transform],
            isTracked: true
        )

        driver.update(skeleton: skeleton, nodes: nodes, humanoid: humanoid)

        // Z should be negated, X and Y unchanged
        XCTAssertEqual(nodes[0].rotation.imag.z, -rotZ45.imag.z, accuracy: 0.001,
                      "Z component should be negated")
        XCTAssertEqual(nodes[0].rotation.imag.x, rotZ45.imag.x, accuracy: 0.001,
                      "X component should be unchanged")
        XCTAssertEqual(nodes[0].rotation.imag.y, rotZ45.imag.y, accuracy: 0.001,
                      "Y component should be unchanged")
        XCTAssertEqual(nodes[0].rotation.real, rotZ45.real, accuracy: 0.001,
                      "Real component should be unchanged")
    }

    /// Test that Y-axis rotation (which has Z≈0) passes through correctly
    func testYAxisRotationPreserved() {
        let driver = createDriver()
        let (nodes, humanoid) = createTestHumanoidSetup()

        // 90° rotation around Y axis - Z component is 0, so negation has no effect
        let rotY90 = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        let transform = simd_float4x4(rotY90)

        let skeleton = ARKitBodySkeleton(
            timestamp: Date().timeIntervalSinceReferenceDate,
            joints: [.hips: transform],
            isTracked: true
        )

        driver.update(skeleton: skeleton, nodes: nodes, humanoid: humanoid)

        // For pure Y rotation, Z≈0 so output ≈ input
        XCTAssertEqual(nodes[0].rotation.imag.y, rotY90.imag.y, accuracy: 0.001,
                      "Y component should be preserved")
        XCTAssertEqual(nodes[0].rotation.real, rotY90.real, accuracy: 0.001,
                      "Real component should be preserved")
        // Z was 0, negated is still 0
        XCTAssertEqual(nodes[0].rotation.imag.z, 0.0, accuracy: 0.001,
                      "Z should remain near zero")
    }

    /// Test that X-axis rotation has Z component negated
    func testXAxisRotationNegatesZComponent() {
        let driver = createDriver()
        let (nodes, humanoid) = createTestHumanoidSetup()

        // 30° rotation around X axis
        let rotX30 = simd_quatf(angle: .pi / 6, axis: SIMD3<Float>(1, 0, 0))
        let transform = simd_float4x4(rotX30)

        let skeleton = ARKitBodySkeleton(
            timestamp: Date().timeIntervalSinceReferenceDate,
            joints: [.hips: transform],
            isTracked: true
        )

        driver.update(skeleton: skeleton, nodes: nodes, humanoid: humanoid)

        // X rotation quaternion has Z=0, so negation doesn't change it
        XCTAssertEqual(nodes[0].rotation.imag.x, rotX30.imag.x, accuracy: 0.001,
                      "X component should be preserved")
        XCTAssertEqual(nodes[0].rotation.imag.z, -rotX30.imag.z, accuracy: 0.001,
                      "Z component should be negated (but was ~0)")
    }

    /// Test combined rotation with all axes
    func testCombinedRotationNegatesOnlyZ() {
        let driver = createDriver()
        let (nodes, humanoid) = createTestHumanoidSetup()

        // Create rotation with non-zero components in all axes
        // Use a normalized quaternion
        let combined = simd_quatf(ix: 0.5, iy: 0.5, iz: 0.5, r: 0.5)
        let transform = simd_float4x4(combined)

        let skeleton = ARKitBodySkeleton(
            timestamp: Date().timeIntervalSinceReferenceDate,
            joints: [.hips: transform],
            isTracked: true
        )

        driver.update(skeleton: skeleton, nodes: nodes, humanoid: humanoid)

        XCTAssertEqual(nodes[0].rotation.imag.x, 0.5, accuracy: 0.001, "X unchanged")
        XCTAssertEqual(nodes[0].rotation.imag.y, 0.5, accuracy: 0.001, "Y unchanged")
        XCTAssertEqual(nodes[0].rotation.imag.z, -0.5, accuracy: 0.001, "Z negated")
        XCTAssertEqual(nodes[0].rotation.real, 0.5, accuracy: 0.001, "Real unchanged")
    }

    // MARK: - Integration Tests: Translation & Scale Preservation

    /// Test that update applies rotation only, preserving translation and scale
    func testUpdateAppliesRotationOnly() {
        let driver = createDriver()
        let (nodes, humanoid) = createTestHumanoidSetup(
            initialTranslation: [5.0, 5.0, 5.0],
            initialScale: [2.0, 2.0, 2.0]
        )

        // Create skeleton with 45° Y rotation
        let rotation45Y = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0))
        let transform = simd_float4x4(rotation45Y)

        let skeleton = ARKitBodySkeleton(
            timestamp: Date().timeIntervalSinceReferenceDate,
            joints: [.hips: transform],
            isTracked: true
        )

        driver.update(skeleton: skeleton, nodes: nodes, humanoid: humanoid)

        // Rotation SHOULD be updated (not identity anymore)
        XCTAssertNotEqual(nodes[0].rotation.real, 1.0, "Rotation should be changed from identity")

        // Translation should be PRESERVED
        XCTAssertEqual(nodes[0].translation.x, 5.0, accuracy: 0.001, "Translation X preserved")
        XCTAssertEqual(nodes[0].translation.y, 5.0, accuracy: 0.001, "Translation Y preserved")
        XCTAssertEqual(nodes[0].translation.z, 5.0, accuracy: 0.001, "Translation Z preserved")

        // Scale should be PRESERVED
        XCTAssertEqual(nodes[0].scale.x, 2.0, accuracy: 0.001, "Scale X preserved")
        XCTAssertEqual(nodes[0].scale.y, 2.0, accuracy: 0.001, "Scale Y preserved")
        XCTAssertEqual(nodes[0].scale.z, 2.0, accuracy: 0.001, "Scale Z preserved")
    }

    // MARK: - Integration Tests: Local Rotation Computation

    /// Test that child joints compute local rotation relative to parent
    func testChildJointComputesLocalRotation() {
        let driver = createDriver()
        let (nodes, humanoid) = createSpineHierarchySetup()

        // Parent (hips) rotated 45° around Y
        let parentRot = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0))
        // Child (spine) rotated 90° around Y in world space
        let childRot = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))

        let skeleton = ARKitBodySkeleton(
            timestamp: Date().timeIntervalSinceReferenceDate,
            joints: [
                .hips: simd_float4x4(parentRot),
                .spine: simd_float4x4(childRot)
            ],
            isTracked: true
        )

        driver.update(skeleton: skeleton, nodes: nodes, humanoid: humanoid)

        // Spine's LOCAL rotation should be: inverse(parent) * child = 45° around Y
        // Then Z-negated (but Y rotation has Z≈0)
        let expectedLocalAngle: Float = .pi / 4
        let spineNode = nodes[1]  // spine is index 1
        let actualAngle = 2 * acos(min(abs(spineNode.rotation.real), 1.0))

        XCTAssertEqual(actualAngle, expectedLocalAngle, accuracy: 0.02,
                      "Spine local rotation should be ~45° (90° world - 45° parent)")
    }

    /// Test that root joint (hips) uses world rotation directly
    func testRootJointUsesWorldRotation() {
        let driver = createDriver()
        let (nodes, humanoid) = createSpineHierarchySetup()

        // Only provide hips rotation (no parent exists)
        let hipsRot = simd_quatf(angle: .pi / 3, axis: SIMD3<Float>(0, 1, 0))

        let skeleton = ARKitBodySkeleton(
            timestamp: Date().timeIntervalSinceReferenceDate,
            joints: [.hips: simd_float4x4(hipsRot)],
            isTracked: true
        )

        driver.update(skeleton: skeleton, nodes: nodes, humanoid: humanoid)

        // Hips should get world rotation directly (with Z negated, but Z≈0 for Y rotation)
        let hipsNode = nodes[0]
        XCTAssertEqual(hipsNode.rotation.imag.y, hipsRot.imag.y, accuracy: 0.001,
                      "Hips should use world rotation Y component")
        XCTAssertEqual(hipsNode.rotation.real, hipsRot.real, accuracy: 0.001,
                      "Hips should use world rotation real component")
    }

    // MARK: - Integration Tests: Edge Cases

    /// Test that untracked skeleton is skipped
    func testUntrackedSkeletonIsSkipped() {
        let driver = createDriver()
        let (nodes, humanoid) = createTestHumanoidSetup()

        let originalRotation = nodes[0].rotation

        let skeleton = ARKitBodySkeleton(
            timestamp: Date().timeIntervalSinceReferenceDate,
            joints: [.hips: simd_float4x4(simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)))],
            isTracked: false  // Not tracked!
        )

        driver.update(skeleton: skeleton, nodes: nodes, humanoid: humanoid)

        // Rotation should NOT change
        XCTAssertEqual(nodes[0].rotation.real, originalRotation.real, accuracy: 0.0001,
                      "Rotation should not change when skeleton is untracked")
        XCTAssertEqual(nodes[0].rotation.imag.x, originalRotation.imag.x, accuracy: 0.0001)
        XCTAssertEqual(nodes[0].rotation.imag.y, originalRotation.imag.y, accuracy: 0.0001)
        XCTAssertEqual(nodes[0].rotation.imag.z, originalRotation.imag.z, accuracy: 0.0001)
    }

    /// Test that unmapped joints are ignored
    func testUnmappedJointsIgnored() {
        let driver = createDriver()
        let (nodes, humanoid) = createTestHumanoidSetup()

        let originalRotation = nodes[0].rotation

        // Provide only .root which is not in the default mapper's VRM bone mapping
        let skeleton = ARKitBodySkeleton(
            timestamp: Date().timeIntervalSinceReferenceDate,
            joints: [.root: simd_float4x4(simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)))],
            isTracked: true
        )

        driver.update(skeleton: skeleton, nodes: nodes, humanoid: humanoid)

        // Node should not be updated (no hips data, and .root isn't mapped to VRM bones)
        XCTAssertEqual(nodes[0].rotation.real, originalRotation.real, accuracy: 0.0001,
                      "Rotation should not change when joint is not mapped")
    }

    /// Test statistics are updated after successful update
    func testStatisticsUpdatedAfterUpdate() {
        let driver = createDriver()
        let (nodes, humanoid) = createTestHumanoidSetup()

        let initialStats = driver.getStatistics()
        XCTAssertEqual(initialStats.updateCount, 0)

        let skeleton = ARKitBodySkeleton(
            timestamp: Date().timeIntervalSinceReferenceDate,
            joints: [.hips: simd_float4x4(1)],
            isTracked: true
        )

        driver.update(skeleton: skeleton, nodes: nodes, humanoid: humanoid)

        let afterStats = driver.getStatistics()
        XCTAssertEqual(afterStats.updateCount, 1, "Update count should increment")
    }

    /// Test skip count incremented for untracked skeleton
    func testSkipCountIncrementedForUntracked() {
        let driver = createDriver()
        let (nodes, humanoid) = createTestHumanoidSetup()

        let skeleton = ARKitBodySkeleton(
            timestamp: Date().timeIntervalSinceReferenceDate,
            joints: [.hips: simd_float4x4(1)],
            isTracked: false
        )

        driver.update(skeleton: skeleton, nodes: nodes, humanoid: humanoid)

        let stats = driver.getStatistics()
        XCTAssertEqual(stats.skipCount, 1, "Skip count should increment for untracked")
        XCTAssertEqual(stats.updateCount, 0, "Update count should remain 0")
    }

    // MARK: - Regression Tests

    /// Regression test: Child joints with missing parent should be skipped
    ///
    /// Previously, when parent joint data was missing, the implementation incorrectly
    /// used the child's WORLD rotation as its LOCAL rotation, causing incorrect poses.
    ///
    /// Fix: When parent transform is missing, skip the joint update entirely to
    /// preserve the previous correct rotation.
    ///
    /// Scenario:
    /// - Frame 1: Hips rotated 45° Y, Spine rotated 45° Y (local = 0°, same as parent)
    /// - Frame 2: Only spine tracked at 45° Y world, hips missing
    /// - Expected: Spine should retain its previous 0° local rotation (skipped update)
    func testMissingParentSkipsJointUpdate() {
        let driver = createDriver()
        let (nodes, humanoid) = createSpineHierarchySetup()

        // First update: both joints tracked, spine has same world rotation as hips
        // So spine's LOCAL rotation should be identity (0°)
        let worldRot = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0))

        let skeleton1 = ARKitBodySkeleton(
            timestamp: 0.0,
            joints: [
                .hips: simd_float4x4(worldRot),
                .spine: simd_float4x4(worldRot)  // Same world rotation = 0° local
            ],
            isTracked: true
        )

        driver.update(skeleton: skeleton1, nodes: nodes, humanoid: humanoid)

        // Spine should have ~identity local rotation (same as parent world)
        let spineAfterFrame1 = nodes[1].rotation
        let spineAngle1 = 2 * acos(min(abs(spineAfterFrame1.real), 1.0))
        XCTAssertEqual(spineAngle1, 0.0, accuracy: 0.01,
                      "Spine local rotation should be ~0° when matching parent world rotation")

        // Second update: ONLY spine tracked, hips MISSING
        let skeleton2 = ARKitBodySkeleton(
            timestamp: 1.0,
            joints: [
                // .hips is MISSING!
                .spine: simd_float4x4(worldRot)  // Same 45° world rotation
            ],
            isTracked: true
        )

        driver.update(skeleton: skeleton2, nodes: nodes, humanoid: humanoid)

        // With the fix: joint is skipped when parent is missing, preserving previous rotation
        let spineAfterFrame2 = nodes[1].rotation
        let spineAngle2 = 2 * acos(min(abs(spineAfterFrame2.real), 1.0))

        // Spine should retain its previous 0° local rotation since update was skipped
        XCTAssertEqual(spineAngle2, 0.0, accuracy: 0.1,
                      "Spine local rotation should be preserved (~0°) when parent is missing")
    }

    // MARK: - Degenerate Matrix Tests (Vertex Explosion Bug)

    /// Regression test: Degenerate matrix with near-zero scale produces NaN quaternion
    ///
    /// BUG: extractRotation() doesn't handle matrices with near-zero scale:
    /// - If scaleX <= 0.0001, basisX is NOT normalized (keeps garbage values)
    /// - simd_quatf(simd_float3x3) with degenerate matrix produces NaN
    /// - NaN propagates to VRMNode.rotation, causing vertex explosion on GPU
    ///
    /// This test creates a degenerate matrix and verifies the driver produces
    /// a VALID quaternion (not NaN, properly normalized).
    func testDegenerateMatrixWithNearZeroScaleProducesValidQuaternion() {
        let driver = createDriver()
        let (nodes, humanoid) = createTestHumanoidSetup()

        // Create degenerate matrix with near-zero scale columns
        // This simulates corrupted ARKit data or edge cases
        var degenerateMatrix = simd_float4x4(1)  // Start with identity
        // Set columns to near-zero values (below the 0.0001 threshold in extractRotation)
        degenerateMatrix.columns.0 = SIMD4<Float>(0.00001, 0, 0, 0)
        degenerateMatrix.columns.1 = SIMD4<Float>(0, 0.00001, 0, 0)
        degenerateMatrix.columns.2 = SIMD4<Float>(0, 0, 0.00001, 0)

        // Store initial rotation to detect if it was updated
        let initialRotation = nodes[0].rotation

        let skeleton = ARKitBodySkeleton(
            timestamp: Date().timeIntervalSinceReferenceDate,
            joints: [.hips: degenerateMatrix],
            isTracked: true
        )

        driver.update(skeleton: skeleton, nodes: nodes, humanoid: humanoid)

        let rotation = nodes[0].rotation

        // Print actual values for debugging
        print("Initial rotation: w=\(initialRotation.real), x=\(initialRotation.imag.x), y=\(initialRotation.imag.y), z=\(initialRotation.imag.z)")
        print("Final rotation: w=\(rotation.real), x=\(rotation.imag.x), y=\(rotation.imag.y), z=\(rotation.imag.z)")

        // Verify the update actually changed the node (didn't silently skip)
        // If it skipped, initial identity rotation would be preserved
        let wasUpdated = rotation.real != initialRotation.real ||
                        rotation.imag.x != initialRotation.imag.x ||
                        rotation.imag.y != initialRotation.imag.y ||
                        rotation.imag.z != initialRotation.imag.z
        print("Was rotation updated: \(wasUpdated)")

        // CRITICAL: Rotation must NOT be NaN
        XCTAssertFalse(rotation.real.isNaN, "Quaternion real component should not be NaN (got \(rotation.real))")
        XCTAssertFalse(rotation.imag.x.isNaN, "Quaternion X should not be NaN (got \(rotation.imag.x))")
        XCTAssertFalse(rotation.imag.y.isNaN, "Quaternion Y should not be NaN (got \(rotation.imag.y))")
        XCTAssertFalse(rotation.imag.z.isNaN, "Quaternion Z should not be NaN (got \(rotation.imag.z))")

        // Quaternion should be normalized (length ≈ 1)
        let length = sqrt(
            rotation.real * rotation.real +
            rotation.imag.x * rotation.imag.x +
            rotation.imag.y * rotation.imag.y +
            rotation.imag.z * rotation.imag.z
        )
        XCTAssertEqual(length, 1.0, accuracy: 0.001, "Quaternion should be normalized (got length \(length))")
    }

    /// Test: Zero matrix produces valid quaternion (not NaN/Infinity)
    func testZeroMatrixProducesValidQuaternion() {
        let driver = createDriver()
        let (nodes, humanoid) = createTestHumanoidSetup()

        // Completely zero matrix (pathological case)
        let zeroMatrix = simd_float4x4(0)

        let skeleton = ARKitBodySkeleton(
            timestamp: Date().timeIntervalSinceReferenceDate,
            joints: [.hips: zeroMatrix],
            isTracked: true
        )

        driver.update(skeleton: skeleton, nodes: nodes, humanoid: humanoid)

        let rotation = nodes[0].rotation

        // Must not produce NaN or Infinity
        XCTAssertFalse(rotation.real.isNaN, "Real should not be NaN for zero matrix")
        XCTAssertFalse(rotation.real.isInfinite, "Real should not be Infinite")
        XCTAssertFalse(rotation.imag.x.isNaN, "X should not be NaN")
        XCTAssertFalse(rotation.imag.y.isNaN, "Y should not be NaN")
        XCTAssertFalse(rotation.imag.z.isNaN, "Z should not be NaN")
    }

    /// Test: Matrix with non-orthonormal columns produces NORMALIZED quaternion
    ///
    /// When extractRotation normalizes columns, it should produce a proper rotation.
    /// If normalization fails/skips, the resulting quaternion may have length != 1,
    /// which causes scaling artifacts in GPU skinning (vertex explosion).
    func testScaledMatrixProducesNormalizedQuaternion() {
        let driver = createDriver()
        let (nodes, humanoid) = createTestHumanoidSetup()

        // Create a rotation matrix with non-unit scale (scaled by 0.5)
        // This is a valid 45° Y rotation with 0.5 scale
        let angle = Float.pi / 4  // 45 degrees
        let c = cos(angle) * 0.5
        let s = sin(angle) * 0.5

        var scaledMatrix = simd_float4x4(1)
        scaledMatrix.columns.0 = SIMD4<Float>(c, 0, s, 0)   // X column (scaled)
        scaledMatrix.columns.1 = SIMD4<Float>(0, 0.5, 0, 0) // Y column (scaled)
        scaledMatrix.columns.2 = SIMD4<Float>(-s, 0, c, 0)  // Z column (scaled)

        let skeleton = ARKitBodySkeleton(
            timestamp: Date().timeIntervalSinceReferenceDate,
            joints: [.hips: scaledMatrix],
            isTracked: true
        )

        driver.update(skeleton: skeleton, nodes: nodes, humanoid: humanoid)

        let rotation = nodes[0].rotation
        print("Scaled matrix result: w=\(rotation.real), x=\(rotation.imag.x), y=\(rotation.imag.y), z=\(rotation.imag.z)")

        // Quaternion MUST be normalized (this is critical for GPU skinning)
        let length = sqrt(
            rotation.real * rotation.real +
            rotation.imag.x * rotation.imag.x +
            rotation.imag.y * rotation.imag.y +
            rotation.imag.z * rotation.imag.z
        )
        print("Quaternion length: \(length)")
        XCTAssertEqual(length, 1.0, accuracy: 0.001, "Quaternion MUST be normalized to prevent vertex explosion (got \(length))")
    }

    /// Test: Very small scale matrix produces normalized quaternion
    ///
    /// Scale values near zero but above the threshold may not be handled correctly.
    func testVerySmallScaleMatrixProducesNormalizedQuaternion() {
        let driver = createDriver()
        let (nodes, humanoid) = createTestHumanoidSetup()

        // Scale just above the 0.0001 threshold - should trigger normalization
        // but might produce very small normalized values -> degenerate quaternion
        let smallScale: Float = 0.0002

        var smallScaleMatrix = simd_float4x4(1)
        smallScaleMatrix.columns.0 = SIMD4<Float>(smallScale, 0, 0, 0)
        smallScaleMatrix.columns.1 = SIMD4<Float>(0, smallScale, 0, 0)
        smallScaleMatrix.columns.2 = SIMD4<Float>(0, 0, smallScale, 0)

        let skeleton = ARKitBodySkeleton(
            timestamp: Date().timeIntervalSinceReferenceDate,
            joints: [.hips: smallScaleMatrix],
            isTracked: true
        )

        driver.update(skeleton: skeleton, nodes: nodes, humanoid: humanoid)

        let rotation = nodes[0].rotation
        print("Small scale result: w=\(rotation.real), x=\(rotation.imag.x), y=\(rotation.imag.y), z=\(rotation.imag.z)")

        // Check for NaN
        XCTAssertFalse(rotation.real.isNaN, "Quaternion should not be NaN with small scale")
        XCTAssertFalse(rotation.imag.x.isNaN, "X should not be NaN")
        XCTAssertFalse(rotation.imag.y.isNaN, "Y should not be NaN")
        XCTAssertFalse(rotation.imag.z.isNaN, "Z should not be NaN")

        // Check normalized
        let length = sqrt(
            rotation.real * rotation.real +
            rotation.imag.x * rotation.imag.x +
            rotation.imag.y * rotation.imag.y +
            rotation.imag.z * rotation.imag.z
        )
        print("Small scale quaternion length: \(length)")
        XCTAssertEqual(length, 1.0, accuracy: 0.01, "Quaternion must be normalized (got \(length))")
    }

    /// Test: Matrix with mixed valid/invalid columns
    func testPartiallyDegenerateMatrixProducesValidQuaternion() {
        let driver = createDriver()
        let (nodes, humanoid) = createTestHumanoidSetup()

        // Matrix with one zero column (degenerate)
        var partialMatrix = simd_float4x4(1)
        partialMatrix.columns.0 = SIMD4<Float>(0, 0, 0, 0)  // Zero X column

        let skeleton = ARKitBodySkeleton(
            timestamp: Date().timeIntervalSinceReferenceDate,
            joints: [.hips: partialMatrix],
            isTracked: true
        )

        driver.update(skeleton: skeleton, nodes: nodes, humanoid: humanoid)

        let rotation = nodes[0].rotation

        XCTAssertFalse(rotation.real.isNaN, "Real should not be NaN for partial degenerate matrix")
        XCTAssertFalse(rotation.imag.x.isNaN, "X should not be NaN")
        XCTAssertFalse(rotation.imag.y.isNaN, "Y should not be NaN")
        XCTAssertFalse(rotation.imag.z.isNaN, "Z should not be NaN")
    }

    /// Test: EMA smoothing with degenerate input doesn't produce NaN
    ///
    /// simd_slerp with bad quaternion inputs can produce NaN.
    /// This tests the full pipeline with smoothing enabled.
    func testSmoothingWithDegenerateInputProducesValidQuaternion() {
        // Create driver WITH smoothing enabled (real production config)
        let driver = ARKitBodyDriver(
            mapper: .default,
            smoothing: .default  // Uses EMA smoothing
        )
        let (nodes, humanoid) = createTestHumanoidSetup()

        // First frame: valid rotation to initialize smoothing state
        let validRotation = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0))
        let skeleton1 = ARKitBodySkeleton(
            timestamp: 0.0,
            joints: [.hips: simd_float4x4(validRotation)],
            isTracked: true
        )
        driver.update(skeleton: skeleton1, nodes: nodes, humanoid: humanoid)

        let rotation1 = nodes[0].rotation
        print("After valid frame: w=\(rotation1.real), y=\(rotation1.imag.y)")
        XCTAssertFalse(rotation1.real.isNaN, "Rotation should be valid after first frame")

        // Second frame: degenerate matrix
        var degenerateMatrix = simd_float4x4(1)
        degenerateMatrix.columns.0 = SIMD4<Float>(0.00001, 0, 0, 0)
        degenerateMatrix.columns.1 = SIMD4<Float>(0, 0.00001, 0, 0)
        degenerateMatrix.columns.2 = SIMD4<Float>(0, 0, 0.00001, 0)

        let skeleton2 = ARKitBodySkeleton(
            timestamp: 1.0,
            joints: [.hips: degenerateMatrix],
            isTracked: true
        )
        driver.update(skeleton: skeleton2, nodes: nodes, humanoid: humanoid)

        let rotation2 = nodes[0].rotation
        print("After degenerate frame: w=\(rotation2.real), x=\(rotation2.imag.x), y=\(rotation2.imag.y), z=\(rotation2.imag.z)")

        // Smoothing with simd_slerp might produce NaN if input is bad
        XCTAssertFalse(rotation2.real.isNaN, "Rotation should not be NaN after smoothing degenerate input")
        XCTAssertFalse(rotation2.imag.x.isNaN, "X should not be NaN")
        XCTAssertFalse(rotation2.imag.y.isNaN, "Y should not be NaN")
        XCTAssertFalse(rotation2.imag.z.isNaN, "Z should not be NaN")

        // Check normalization
        let length = simd_length(simd_float4(rotation2.imag.x, rotation2.imag.y, rotation2.imag.z, rotation2.real))
        print("Quaternion length after smoothing: \(length)")
        XCTAssertEqual(length, 1.0, accuracy: 0.01, "Quaternion must remain normalized after smoothing")
    }

    /// Test: Very large rotation values (potential overflow)
    func testLargeRotationValuesProduceValidQuaternion() {
        let driver = createDriver()
        let (nodes, humanoid) = createTestHumanoidSetup()

        // Create matrix with very large values (potential overflow in calculations)
        var largeMatrix = simd_float4x4(1)
        let largeValue: Float = 1e6
        largeMatrix.columns.0 = SIMD4<Float>(largeValue, 0, 0, 0)
        largeMatrix.columns.1 = SIMD4<Float>(0, largeValue, 0, 0)
        largeMatrix.columns.2 = SIMD4<Float>(0, 0, largeValue, 0)

        let skeleton = ARKitBodySkeleton(
            timestamp: Date().timeIntervalSinceReferenceDate,
            joints: [.hips: largeMatrix],
            isTracked: true
        )

        driver.update(skeleton: skeleton, nodes: nodes, humanoid: humanoid)

        let rotation = nodes[0].rotation
        print("Large scale result: w=\(rotation.real), xyz=(\(rotation.imag.x), \(rotation.imag.y), \(rotation.imag.z))")

        XCTAssertFalse(rotation.real.isNaN, "Real should not be NaN with large scale")
        XCTAssertFalse(rotation.real.isInfinite, "Real should not be infinite")

        let length = simd_length(simd_float4(rotation.imag.x, rotation.imag.y, rotation.imag.z, rotation.real))
        XCTAssertEqual(length, 1.0, accuracy: 0.01, "Quaternion must be normalized")
    }

    // MARK: - VRMNode Matrix Conversion Tests

    /// BUG TEST: Unnormalized quaternion causes scaling in rotation matrix
    ///
    /// The VRMNode.updateLocalMatrix() manually converts quaternion to matrix.
    /// The formula assumes the quaternion is normalized (x²+y²+z²+w² = 1).
    /// If the quaternion is NOT normalized, the matrix will scale/shear vertices,
    /// causing "vertex explosion" on the GPU.
    ///
    /// This test verifies that after driver.update(), the resulting rotation
    /// matrix has no scaling (diagonal elements should sum to 3 for pure rotation).
    func testRotationMatrixHasNoScaling() {
        let driver = createDriver()
        let (nodes, humanoid) = createTestHumanoidSetup()

        // Apply a valid rotation
        let rotation = simd_quatf(angle: .pi / 3, axis: SIMD3<Float>(0, 1, 0))
        let skeleton = ARKitBodySkeleton(
            timestamp: Date().timeIntervalSinceReferenceDate,
            joints: [.hips: simd_float4x4(rotation)],
            isTracked: true
        )

        driver.update(skeleton: skeleton, nodes: nodes, humanoid: humanoid)

        // Get the local matrix from the node
        let matrix = nodes[0].localMatrix

        // For a pure rotation matrix (no scale), each column should have length 1
        let col0Length = simd_length(SIMD3<Float>(matrix[0][0], matrix[0][1], matrix[0][2]))
        let col1Length = simd_length(SIMD3<Float>(matrix[1][0], matrix[1][1], matrix[1][2]))
        let col2Length = simd_length(SIMD3<Float>(matrix[2][0], matrix[2][1], matrix[2][2]))

        print("Column lengths: \(col0Length), \(col1Length), \(col2Length)")

        XCTAssertEqual(col0Length, 1.0, accuracy: 0.01, "Column 0 should have unit length (no scaling)")
        XCTAssertEqual(col1Length, 1.0, accuracy: 0.01, "Column 1 should have unit length (no scaling)")
        XCTAssertEqual(col2Length, 1.0, accuracy: 0.01, "Column 2 should have unit length (no scaling)")

        // Also verify determinant is 1 (pure rotation, no reflection or scaling)
        let det = simd_determinant(matrix)
        print("Matrix determinant: \(det)")
        XCTAssertEqual(det, 1.0, accuracy: 0.01, "Determinant should be 1 for pure rotation")
    }

    /// DOCUMENTATION TEST: VRMNode.updateLocalMatrix() trusts quaternion is normalized
    ///
    /// VRMNode does NOT normalize quaternions itself - it trusts the caller.
    /// If an unnormalized quaternion is set directly, the rotation matrix will
    /// have scaling artifacts, causing vertex explosion.
    ///
    /// The fix for this is in ARKitBodyDriver, which normalizes before applying.
    /// This test documents the expected VRMNode behavior (not a bug in VRMNode itself).
    func testVRMNodeTrustsNormalizedQuaternion() {
        let (nodes, _) = createTestHumanoidSetup()
        let node = nodes[0]

        // Create an UNNORMALIZED quaternion (length = sqrt(2) ≈ 1.414)
        let unnormalized = simd_quatf(ix: 0.0, iy: 1.0, iz: 0.0, r: 1.0)
        let quatLength = simd_length(simd_float4(unnormalized.imag.x, unnormalized.imag.y, unnormalized.imag.z, unnormalized.real))
        print("Unnormalized quaternion length: \(quatLength)")
        XCTAssertNotEqual(quatLength, 1.0, accuracy: 0.1, "Quaternion should NOT be normalized for this test")

        // Set the unnormalized quaternion directly on the node (bypassing driver)
        node.rotation = unnormalized
        node.updateLocalMatrix()

        // Check matrix column lengths - they will NOT be 1.0
        let matrix = node.localMatrix
        let col0Length = simd_length(SIMD3<Float>(matrix[0][0], matrix[0][1], matrix[0][2]))
        let col2Length = simd_length(SIMD3<Float>(matrix[2][0], matrix[2][1], matrix[2][2]))

        print("Matrix column lengths with unnormalized quat: \(col0Length), _, \(col2Length)")

        // This is EXPECTED behavior - VRMNode trusts caller to normalize
        // Column lengths should be > 1 when quaternion length > 1
        XCTAssertGreaterThan(col0Length, 1.0, "Unnormalized quat should cause scaling")
        XCTAssertGreaterThan(col2Length, 1.0, "Unnormalized quat should cause scaling")

        // Now verify that NORMALIZING the quaternion fixes the issue
        let normalized = simd_normalize(unnormalized)
        node.rotation = normalized
        node.updateLocalMatrix()

        let fixedMatrix = node.localMatrix
        let fixedCol0Length = simd_length(SIMD3<Float>(fixedMatrix[0][0], fixedMatrix[0][1], fixedMatrix[0][2]))
        let fixedCol2Length = simd_length(SIMD3<Float>(fixedMatrix[2][0], fixedMatrix[2][1], fixedMatrix[2][2]))

        XCTAssertEqual(fixedCol0Length, 1.0, accuracy: 0.01, "Normalized quat should produce unit columns")
        XCTAssertEqual(fixedCol2Length, 1.0, accuracy: 0.01, "Normalized quat should produce unit columns")
    }

    // MARK: - Performance Tests

    func testDriverUpdatePerformance() {
        let driver = createDriver()
        let (nodes, humanoid) = createTestHumanoidSetup()

        // Pre-generate skeletons
        let skeletons = (0..<100).map { i in
            ARKitBodySkeleton(
                timestamp: Double(i) / 60.0,
                joints: [.hips: simd_float4x4(simd_quatf(
                    angle: Float(i) * 0.1,
                    axis: SIMD3<Float>(0, 1, 0)
                ))],
                isTracked: true
            )
        }

        measure {
            for skeleton in skeletons {
                driver.update(skeleton: skeleton, nodes: nodes, humanoid: humanoid)
            }
        }
    }

    // MARK: - Test Helpers

    private func createDriver() -> ARKitBodyDriver {
        return ARKitBodyDriver(
            mapper: .default,
            smoothing: SkeletonSmoothingConfig(
                positionFilter: .none,
                rotationFilter: .none,
                scaleFilter: .none
            )
        )
    }

    /// Creates a test humanoid setup with a single hips node
    private func createTestHumanoidSetup(
        initialTranslation: SIMD3<Float> = [0, 0, 0],
        initialScale: SIMD3<Float> = [1, 1, 1]
    ) -> ([VRMNode], VRMHumanoid) {
        let gltfNode = GLTFNode(
            name: "hips",
            children: nil,
            matrix: nil,
            translation: [initialTranslation.x, initialTranslation.y, initialTranslation.z],
            rotation: [0, 0, 0, 1],
            scale: [initialScale.x, initialScale.y, initialScale.z],
            mesh: nil,
            skin: nil,
            weights: nil
        )

        let node = VRMNode(index: 0, gltfNode: gltfNode)
        let nodes = [node]

        let humanoid = VRMHumanoid()
        humanoid.humanBones[.hips] = VRMHumanoid.VRMHumanBone(node: 0)

        return (nodes, humanoid)
    }

    /// Creates a test setup with hips -> spine hierarchy for local rotation testing
    private func createSpineHierarchySetup() -> ([VRMNode], VRMHumanoid) {
        let hipsGltf = GLTFNode(
            name: "hips",
            children: [1],
            matrix: nil,
            translation: [0, 1, 0],
            rotation: [0, 0, 0, 1],
            scale: [1, 1, 1],
            mesh: nil,
            skin: nil,
            weights: nil
        )

        let spineGltf = GLTFNode(
            name: "spine",
            children: nil,
            matrix: nil,
            translation: [0, 0.2, 0],
            rotation: [0, 0, 0, 1],
            scale: [1, 1, 1],
            mesh: nil,
            skin: nil,
            weights: nil
        )

        let hipsNode = VRMNode(index: 0, gltfNode: hipsGltf)
        let spineNode = VRMNode(index: 1, gltfNode: spineGltf)

        // Set up parent-child relationship
        spineNode.parent = hipsNode
        hipsNode.children = [spineNode]

        let nodes = [hipsNode, spineNode]

        let humanoid = VRMHumanoid()
        humanoid.humanBones[.hips] = VRMHumanoid.VRMHumanBone(node: 0)
        humanoid.humanBones[.spine] = VRMHumanoid.VRMHumanBone(node: 1)

        return (nodes, humanoid)
    }
}
