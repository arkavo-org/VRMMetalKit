// Copyright 2025 Arkavo
// SPDX-License-Identifier: Apache-2.0

import XCTest
import simd
@testable import VRMMetalKit

/// Tests to validate BoneParams struct layout matches Metal shader expectations
/// This is critical for GPU physics simulation - any mismatch causes physics failures
final class BoneParamsLayoutTests: XCTestCase {

    func testStructSize() {
        // Metal layout with collision group mask:
        // 4 floats (16) + uint (4) + float (4) + uint (4) + float3 (12) = 40 bytes
        // But float3 forces 16-byte alignment: padded to 48 bytes total
        let expectedSize = 48
        let actualSize = MemoryLayout<BoneParams>.size

        XCTAssertEqual(actualSize, expectedSize,
                      "BoneParams size mismatch! Expected \(expectedSize) bytes, got \(actualSize) bytes. " +
                      "This struct must match the Metal shader's memory layout exactly.")
    }

    func testStructStride() {
        // Stride must be 48 bytes (16-byte aligned) to match Metal shader
        let expectedStride = 48
        let actualStride = MemoryLayout<BoneParams>.stride

        XCTAssertEqual(actualStride, expectedStride,
                      "BoneParams stride mismatch! Expected \(expectedStride) bytes, got \(actualStride) bytes. " +
                      "Metal expects 16-byte alignment for buffer arrays.")
    }

    func testStructAlignment() {
        // SIMD3<Float> forces 16-byte alignment
        let expectedAlignment = 16
        let actualAlignment = MemoryLayout<BoneParams>.alignment

        XCTAssertEqual(actualAlignment, expectedAlignment,
                      "BoneParams alignment mismatch! Expected \(expectedAlignment) bytes, got \(actualAlignment) bytes.")
    }

    func testDefaultGravityValues() {
        // Test that default initializer sets correct gravity values
        let params = BoneParams(stiffness: 1.0, drag: 0.4, radius: 0.05, parentIndex: 0)

        XCTAssertEqual(params.gravityPower, 1.0,
                      "Default gravityPower should be 1.0 (full gravity)")
        XCTAssertEqual(params.gravityDir, SIMD3<Float>(0, -1, 0),
                      "Default gravityDir should be [0, -1, 0] (downward)")
    }

    func testDefaultColliderGroupMask() {
        // Test that default collider group mask allows collision with all groups
        let params = BoneParams(stiffness: 1.0, drag: 0.4, radius: 0.05, parentIndex: 0)

        XCTAssertEqual(params.colliderGroupMask, 0xFFFFFFFF,
                      "Default colliderGroupMask should be 0xFFFFFFFF (collide with all groups)")
    }

    func testCustomColliderGroupMask() {
        // Test custom collider group mask for selective collision
        let params = BoneParams(
            stiffness: 1.0,
            drag: 0.4,
            radius: 0.05,
            parentIndex: 0,
            gravityPower: 1.0,
            colliderGroupMask: 0b0011  // Only collide with groups 0 and 1
        )

        XCTAssertEqual(params.colliderGroupMask, 0b0011)
        XCTAssertTrue(params.colliderGroupMask & (1 << 0) != 0, "Should collide with group 0")
        XCTAssertTrue(params.colliderGroupMask & (1 << 1) != 0, "Should collide with group 1")
        XCTAssertFalse(params.colliderGroupMask & (1 << 2) != 0, "Should NOT collide with group 2")
    }

    func testCustomGravityValues() {
        // Test custom gravity parameters for hair/cloth
        let hairParams = BoneParams(
            stiffness: 1.0,
            drag: 0.4,
            radius: 0.05,
            parentIndex: 0,
            gravityPower: 0.3,           // Light gravity for floaty hair
            gravityDir: SIMD3<Float>(0, -1, 0)
        )

        XCTAssertEqual(hairParams.gravityPower, 0.3, accuracy: 0.001)

        let clothParams = BoneParams(
            stiffness: 1.0,
            drag: 0.4,
            radius: 0.05,
            parentIndex: 0,
            gravityPower: 1.5,           // Heavy gravity for coat
            gravityDir: SIMD3<Float>(0, -1, 0)
        )

        XCTAssertEqual(clothParams.gravityPower, 1.5, accuracy: 0.001)
    }

    func testMetalCompatibility() {
        // This test documents the Metal shader struct layout
        // Metal BoneParams has 7 fields with padding:
        //   Offset 0:  float stiffness           (4 bytes)
        //   Offset 4:  float drag                (4 bytes)
        //   Offset 8:  float radius              (4 bytes)
        //   Offset 12: uint parentIndex          (4 bytes)
        //   Offset 16: float gravityPower        (4 bytes)
        //   Offset 20: uint colliderGroupMask    (4 bytes)
        //   Offset 24: (padding for float3)      (8 bytes)
        //   Offset 32: float3 gravityDir         (12 bytes, padded to 16)
        //   Total: 48 bytes (16-byte aligned)

        let layout = [
            (offset: 0, field: "stiffness", bytes: 4),
            (offset: 4, field: "drag", bytes: 4),
            (offset: 8, field: "radius", bytes: 4),
            (offset: 12, field: "parentIndex", bytes: 4),
            (offset: 16, field: "gravityPower", bytes: 4),
            (offset: 20, field: "colliderGroupMask", bytes: 4),
            (offset: 32, field: "gravityDir", bytes: 12),  // padded to 16
        ]

        print("\nMetal Shader Layout:")
        for item in layout {
            print("  Offset \(item.offset): \(item.field) (\(item.bytes) bytes)")
        }
        print("  Total: 48 bytes (16-byte aligned)\n")

        XCTAssertEqual(MemoryLayout<BoneParams>.stride, 48,
                      "BoneParams must be 48 bytes to match Metal shader")
    }

    func testGravityDirectionNormalization() {
        // Test that non-normalized directions can be handled
        // (Normalization happens in SpringBoneComputeSystem, not in the struct)

        let unnormalized = SIMD3<Float>(0, -2, 0)
        let normalized = simd_length(unnormalized) > 0.001
            ? simd_normalize(unnormalized)
            : SIMD3<Float>(0, -1, 0)

        XCTAssertEqual(normalized, SIMD3<Float>(0, -1, 0),
                      "Direction [0, -2, 0] should normalize to [0, -1, 0]")

        let diagonal = SIMD3<Float>(1, -1, 0)
        let normalizedDiagonal = simd_normalize(diagonal)

        XCTAssertEqual(normalizedDiagonal.x, 0.707, accuracy: 0.01)
        XCTAssertEqual(normalizedDiagonal.y, -0.707, accuracy: 0.01)
        XCTAssertEqual(normalizedDiagonal.z, 0.0, accuracy: 0.01)
    }

    func testZeroGravityDirection() {
        // Test that zero vector defaults to downward
        let zero = SIMD3<Float>(0, 0, 0)
        let defaultDir = simd_length(zero) > 0.001
            ? simd_normalize(zero)
            : SIMD3<Float>(0, -1, 0)  // Default downward

        XCTAssertEqual(defaultDir, SIMD3<Float>(0, -1, 0),
                      "Zero gravity direction should default to [0, -1, 0]")
    }

    // MARK: - Collider Struct Layout Tests

    func testSphereColliderLayout() {
        // SphereCollider: center (float3, 16 bytes with padding) + radius (4) + groupIndex (4) + padding (8)
        // Total: 32 bytes (16-byte aligned)
        let expectedStride = 32
        let actualStride = MemoryLayout<SphereCollider>.stride

        XCTAssertEqual(actualStride, expectedStride,
                      "SphereCollider stride mismatch! Expected \(expectedStride), got \(actualStride)")
    }

    func testSphereColliderGroupIndex() {
        let collider = SphereCollider(center: SIMD3<Float>(0, 1, 0), radius: 0.1, groupIndex: 5)
        XCTAssertEqual(collider.groupIndex, 5)
        XCTAssertEqual(collider.center, SIMD3<Float>(0, 1, 0))
        XCTAssertEqual(collider.radius, 0.1, accuracy: 0.001)
    }

    func testCapsuleColliderLayout() {
        // CapsuleCollider: p0 (float3, 16) + p1 (float3, 16) + radius (4) + groupIndex (4) + padding (8)
        // Total: 48 bytes (16-byte aligned)
        let expectedStride = 48
        let actualStride = MemoryLayout<CapsuleCollider>.stride

        XCTAssertEqual(actualStride, expectedStride,
                      "CapsuleCollider stride mismatch! Expected \(expectedStride), got \(actualStride)")
    }

    func testCapsuleColliderGroupIndex() {
        let collider = CapsuleCollider(
            p0: SIMD3<Float>(0, 0, 0),
            p1: SIMD3<Float>(0, 1, 0),
            radius: 0.05,
            groupIndex: 3
        )
        XCTAssertEqual(collider.groupIndex, 3)
        XCTAssertEqual(collider.p0, SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(collider.p1, SIMD3<Float>(0, 1, 0))
    }

    func testPlaneColliderLayout() {
        // PlaneCollider: point (float3, 16) + normal (float3, 16) + groupIndex (4) + padding (12)
        // Total: 48 bytes (16-byte aligned)
        let expectedStride = 48
        let actualStride = MemoryLayout<PlaneCollider>.stride

        XCTAssertEqual(actualStride, expectedStride,
                      "PlaneCollider stride mismatch! Expected \(expectedStride), got \(actualStride)")
    }

    func testPlaneColliderGroupIndex() {
        let collider = PlaneCollider(
            point: SIMD3<Float>(0, 0, 0),
            normal: SIMD3<Float>(0, 1, 0),
            groupIndex: 2
        )
        XCTAssertEqual(collider.groupIndex, 2)
        XCTAssertEqual(collider.point, SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(collider.normal, SIMD3<Float>(0, 1, 0))
    }

    // MARK: - Collision Group Mask Tests

    func testCollisionGroupMaskBitOperations() {
        // Simulate GPU collision group filtering logic
        let boneMask: UInt32 = 0b0101  // Groups 0 and 2
        let colliderGroup0: UInt32 = 0
        let colliderGroup1: UInt32 = 1
        let colliderGroup2: UInt32 = 2

        // Test mask check: boneMask & (1 << groupIndex)
        XCTAssertTrue(boneMask & (1 << colliderGroup0) != 0, "Should collide with group 0")
        XCTAssertFalse(boneMask & (1 << colliderGroup1) != 0, "Should NOT collide with group 1")
        XCTAssertTrue(boneMask & (1 << colliderGroup2) != 0, "Should collide with group 2")
    }

    func testAllGroupsMaskCollision() {
        // 0xFFFFFFFF should collide with all groups (backward compatibility)
        let allGroupsMask: UInt32 = 0xFFFFFFFF

        for group in 0..<32 {
            XCTAssertTrue(allGroupsMask & (1 << UInt32(group)) != 0,
                         "All groups mask should collide with group \(group)")
        }
    }

    func testNoGroupsMaskCollision() {
        // Empty mask (0) should collide with nothing
        let noGroupsMask: UInt32 = 0

        for group in 0..<32 {
            XCTAssertFalse(noGroupsMask & (1 << UInt32(group)) != 0,
                          "Empty mask should not collide with group \(group)")
        }
    }

    // MARK: - ARKit Floor Plane Helper Tests

    func testPlaneColliderFloorYInitializer() {
        // Test simple floor plane at a given Y height
        let floor = PlaneCollider(floorY: 0.5)

        XCTAssertEqual(floor.point.y, 0.5, accuracy: 0.001, "Floor Y should be 0.5")
        XCTAssertEqual(floor.point.x, 0.0, accuracy: 0.001, "Floor X should be 0")
        XCTAssertEqual(floor.point.z, 0.0, accuracy: 0.001, "Floor Z should be 0")
        XCTAssertEqual(floor.normal, SIMD3<Float>(0, 1, 0), "Normal should point up")
        XCTAssertEqual(floor.groupIndex, 0, "Default group should be 0")
    }

    func testPlaneColliderFloorYWithGroup() {
        // Test floor plane with custom collision group
        let floor = PlaneCollider(floorY: -1.0, groupIndex: 5)

        XCTAssertEqual(floor.point.y, -1.0, accuracy: 0.001)
        XCTAssertEqual(floor.normal, SIMD3<Float>(0, 1, 0))
        XCTAssertEqual(floor.groupIndex, 5)
    }

    func testPlaneColliderARKitTransformHorizontal() {
        // Simulate ARKit horizontal plane transform
        // ARKit horizontal planes have Y-axis as the normal (pointing up)
        var transform = simd_float4x4(1)  // Identity
        transform.columns.3 = SIMD4<Float>(1.0, 0.25, 2.0, 1.0)  // Position at (1, 0.25, 2)

        let floor = PlaneCollider(arkitTransform: transform)

        XCTAssertEqual(floor.point.x, 1.0, accuracy: 0.001, "X position from transform")
        XCTAssertEqual(floor.point.y, 0.25, accuracy: 0.001, "Y position from transform")
        XCTAssertEqual(floor.point.z, 2.0, accuracy: 0.001, "Z position from transform")

        // Identity matrix has Y-axis = (0, 1, 0)
        XCTAssertEqual(floor.normal.x, 0.0, accuracy: 0.001, "Normal X")
        XCTAssertEqual(floor.normal.y, 1.0, accuracy: 0.001, "Normal Y (up)")
        XCTAssertEqual(floor.normal.z, 0.0, accuracy: 0.001, "Normal Z")
    }

    func testPlaneColliderARKitTransformTilted() {
        // Simulate a slightly tilted plane (rotated 30 degrees around Z)
        let angle: Float = .pi / 6  // 30 degrees
        var transform = simd_float4x4(1)

        // Rotate Y-axis (the normal) around Z-axis
        transform.columns.1 = SIMD4<Float>(-sin(angle), cos(angle), 0, 0)
        transform.columns.3 = SIMD4<Float>(0, 1.0, 0, 1.0)

        let plane = PlaneCollider(arkitTransform: transform)

        XCTAssertEqual(plane.point.y, 1.0, accuracy: 0.001)

        // Normal should be tilted
        XCTAssertEqual(plane.normal.x, -0.5, accuracy: 0.01, "Normal X tilted")
        XCTAssertEqual(plane.normal.y, 0.866, accuracy: 0.01, "Normal Y (cos 30)")
        XCTAssertEqual(plane.normal.z, 0.0, accuracy: 0.01, "Normal Z")

        // Verify normal is normalized
        let length = simd_length(plane.normal)
        XCTAssertEqual(length, 1.0, accuracy: 0.001, "Normal should be normalized")
    }

    func testPlaneColliderARKitTransformWithGroupIndex() {
        var transform = simd_float4x4(1)
        transform.columns.3 = SIMD4<Float>(0, 0.5, 0, 1.0)

        let floor = PlaneCollider(arkitTransform: transform, groupIndex: 3)

        XCTAssertEqual(floor.groupIndex, 3, "Should use provided group index")
    }
}
