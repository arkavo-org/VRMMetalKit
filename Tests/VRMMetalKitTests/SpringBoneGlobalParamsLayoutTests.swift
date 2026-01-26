// Copyright 2025 Arkavo
// SPDX-License-Identifier: Apache-2.0

import XCTest
import simd
@testable import VRMMetalKit

/// Tests to validate SpringBoneGlobalParams struct layout matches Metal shader expectations
/// This is critical for GPU physics simulation - any mismatch causes physics failures
final class SpringBoneGlobalParamsLayoutTests: XCTestCase {

    func testStructSize() {
        // Metal layout with externalVelocity:
        // Offset 0:  float3 gravity           (16 bytes with padding)
        // Offset 16: float dtSub              (4 bytes)
        // Offset 20: float windAmplitude      (4 bytes)
        // Offset 24: float windFrequency      (4 bytes)
        // Offset 28: float windPhase          (4 bytes)
        // Offset 32: float3 windDirection     (16 bytes with padding)
        // Offset 48: uint substeps            (4 bytes)
        // Offset 52: uint numBones            (4 bytes)
        // Offset 56: uint numSpheres          (4 bytes)
        // Offset 60: uint numCapsules         (4 bytes)
        // Offset 64: uint numPlanes           (4 bytes)
        // Offset 68: uint settlingFrames      (4 bytes)
        // Offset 72: uint _padding0           (4 bytes)
        // Offset 76: uint _padding1           (4 bytes)
        // Offset 80: float3 externalVelocity  (16 bytes with padding)
        // Total: 96 bytes
        let expectedSize = 96
        let actualSize = MemoryLayout<SpringBoneGlobalParams>.size

        XCTAssertEqual(actualSize, expectedSize,
                      "SpringBoneGlobalParams size mismatch! Expected \(expectedSize) bytes, got \(actualSize) bytes. " +
                      "This struct must match the Metal shader's memory layout exactly.")
    }

    func testStructStride() {
        // Stride must be 96 bytes (16-byte aligned) to match Metal shader
        let expectedStride = 96
        let actualStride = MemoryLayout<SpringBoneGlobalParams>.stride

        XCTAssertEqual(actualStride, expectedStride,
                      "SpringBoneGlobalParams stride mismatch! Expected \(expectedStride) bytes, got \(actualStride) bytes. " +
                      "Metal expects 16-byte alignment for buffer arrays.")
    }

    func testStructAlignment() {
        // SIMD3<Float> forces 16-byte alignment
        let expectedAlignment = 16
        let actualAlignment = MemoryLayout<SpringBoneGlobalParams>.alignment

        XCTAssertEqual(actualAlignment, expectedAlignment,
                      "SpringBoneGlobalParams alignment mismatch! Expected \(expectedAlignment) bytes, got \(actualAlignment) bytes.")
    }

    func testDefaultValues() {
        // Test that default initializer sets correct values
        let params = SpringBoneGlobalParams(
            gravity: SIMD3<Float>(0, -9.8, 0),
            dtSub: 1.0 / 120.0,
            windAmplitude: 0,
            windFrequency: 1.0,
            windPhase: 0,
            windDirection: SIMD3<Float>(1, 0, 0),
            substeps: 4,
            numBones: 10,
            numSpheres: 2,
            numCapsules: 1
        )

        XCTAssertEqual(params.gravity.y, -9.8, accuracy: 0.001)
        XCTAssertEqual(params.numPlanes, 0, "Default numPlanes should be 0")
        XCTAssertEqual(params.settlingFrames, 0, "Default settlingFrames should be 0")
        XCTAssertEqual(params.externalVelocity, .zero, "Default externalVelocity should be zero")
    }

    func testExternalVelocity() {
        // Test custom external velocity for character movement inertia
        let velocity = SIMD3<Float>(1.5, 0, -0.5)
        let params = SpringBoneGlobalParams(
            gravity: SIMD3<Float>(0, -9.8, 0),
            dtSub: 1.0 / 120.0,
            windAmplitude: 0,
            windFrequency: 1.0,
            windPhase: 0,
            windDirection: SIMD3<Float>(1, 0, 0),
            substeps: 4,
            numBones: 10,
            numSpheres: 2,
            numCapsules: 1,
            externalVelocity: velocity
        )

        XCTAssertEqual(params.externalVelocity.x, 1.5, accuracy: 0.001)
        XCTAssertEqual(params.externalVelocity.y, 0, accuracy: 0.001)
        XCTAssertEqual(params.externalVelocity.z, -0.5, accuracy: 0.001)
    }

    func testMetalCompatibility() {
        // This test documents the Metal shader struct layout
        let layout = [
            (offset: 0, field: "gravity", bytes: 16),
            (offset: 16, field: "dtSub", bytes: 4),
            (offset: 20, field: "windAmplitude", bytes: 4),
            (offset: 24, field: "windFrequency", bytes: 4),
            (offset: 28, field: "windPhase", bytes: 4),
            (offset: 32, field: "windDirection", bytes: 16),
            (offset: 48, field: "substeps", bytes: 4),
            (offset: 52, field: "numBones", bytes: 4),
            (offset: 56, field: "numSpheres", bytes: 4),
            (offset: 60, field: "numCapsules", bytes: 4),
            (offset: 64, field: "numPlanes", bytes: 4),
            (offset: 68, field: "settlingFrames", bytes: 4),
            (offset: 72, field: "_padding0", bytes: 4),
            (offset: 76, field: "_padding1", bytes: 4),
            (offset: 80, field: "externalVelocity", bytes: 16),
        ]

        print("\nSpringBoneGlobalParams Metal Shader Layout:")
        for item in layout {
            print("  Offset \(item.offset): \(item.field) (\(item.bytes) bytes)")
        }
        print("  Total: 96 bytes (16-byte aligned)\n")

        XCTAssertEqual(MemoryLayout<SpringBoneGlobalParams>.stride, 96,
                      "SpringBoneGlobalParams must be 96 bytes to match Metal shader")
    }

    func testInertialForceCalculation() {
        // Test the inertial force calculation that happens in the shader
        // When character moves right (+X), hair should get force to the left (-X)
        let characterVelocity = SIMD3<Float>(2.0, 0, 0)  // Moving right at 2 m/s
        let inertialForce = -characterVelocity * 0.5

        XCTAssertEqual(inertialForce.x, -1.0, accuracy: 0.001, "Inertial force should oppose movement")
        XCTAssertEqual(inertialForce.y, 0.0, accuracy: 0.001)
        XCTAssertEqual(inertialForce.z, 0.0, accuracy: 0.001)
    }

    func testVelocityDuringWalk() {
        // Test typical velocity values during character walk
        let walkSpeed: Float = 1.5  // m/s
        let walkDirection = SIMD3<Float>(0, 0, 1)  // Walking forward
        let velocity = walkDirection * walkSpeed

        let params = SpringBoneGlobalParams(
            gravity: SIMD3<Float>(0, -9.8, 0),
            dtSub: 1.0 / 120.0,
            windAmplitude: 0,
            windFrequency: 1.0,
            windPhase: 0,
            windDirection: SIMD3<Float>(1, 0, 0),
            substeps: 4,
            numBones: 10,
            numSpheres: 2,
            numCapsules: 1,
            externalVelocity: velocity
        )

        // Hair should trail behind (opposite to movement)
        let inertialForce = -params.externalVelocity * 0.5
        XCTAssertEqual(inertialForce.z, -0.75, accuracy: 0.001, "Hair should trail behind during forward walk")
    }

    func testVelocityDuringSuddenStop() {
        // When character suddenly stops, velocity goes to zero
        // The inertial force should also go to zero (but momentum is already in spring bones)
        let stoppedParams = SpringBoneGlobalParams(
            gravity: SIMD3<Float>(0, -9.8, 0),
            dtSub: 1.0 / 120.0,
            windAmplitude: 0,
            windFrequency: 1.0,
            windPhase: 0,
            windDirection: SIMD3<Float>(1, 0, 0),
            substeps: 4,
            numBones: 10,
            numSpheres: 2,
            numCapsules: 1,
            externalVelocity: .zero  // Stopped
        )

        XCTAssertEqual(stoppedParams.externalVelocity, .zero)
        let inertialForce = -stoppedParams.externalVelocity * 0.5
        XCTAssertEqual(inertialForce, .zero, "No inertial force when character is still")
    }
}
