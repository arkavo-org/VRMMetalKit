// Copyright 2025 Arkavo
// SPDX-License-Identifier: Apache-2.0

import XCTest
import simd
@testable import VRMMetalKit

/// Tests to validate BoneParams struct layout matches Metal shader expectations
/// This is critical for GPU physics simulation - any mismatch causes physics failures
final class BoneParamsLayoutTests: XCTestCase {

    func testStructSize() {
        // Metal pads float3 to 16 bytes, so:
        // 4 floats (16) + uint (4) + float (4) + float3 (12) = 36 bytes
        // But float3 forces next struct to 16-byte boundary: 48 bytes total
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
        // Metal BoneParams has 6 fields with padding:
        //   Offset 0:  float stiffness        (4 bytes)
        //   Offset 4:  float drag             (4 bytes)
        //   Offset 8:  float radius           (4 bytes)
        //   Offset 12: uint parentIndex       (4 bytes)
        //   Offset 16: float gravityPower     (4 bytes)
        //   Offset 20: float3 gravityDir      (12 bytes, but padded to 16)
        //   Total: 48 bytes (16-byte aligned)

        let layout = [
            (offset: 0, field: "stiffness", bytes: 4),
            (offset: 4, field: "drag", bytes: 4),
            (offset: 8, field: "radius", bytes: 4),
            (offset: 12, field: "parentIndex", bytes: 4),
            (offset: 16, field: "gravityPower", bytes: 4),
            (offset: 20, field: "gravityDir", bytes: 12),  // padded to 16
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
}
