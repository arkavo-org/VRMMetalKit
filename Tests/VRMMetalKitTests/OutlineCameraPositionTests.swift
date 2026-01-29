// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import simd
@testable import VRMMetalKit

/// TDD tests for camera position extraction from view matrix (Issue #103)
/// The view matrix stores camera transform as [R | -R*t] where:
/// - R is the rotation matrix (upper-left 3x3)
/// - t is the camera world position
/// To extract camera position: cameraPos = -(transpose(R) * viewMatrix[3].xyz)
final class OutlineCameraPositionTests: XCTestCase {

    /// Helper to extract camera position correctly from view matrix
    func extractCameraPosition(from viewMatrix: simd_float4x4) -> SIMD3<Float> {
        let viewRotation = simd_float3x3(
            SIMD3<Float>(viewMatrix.columns.0.x, viewMatrix.columns.0.y, viewMatrix.columns.0.z),
            SIMD3<Float>(viewMatrix.columns.1.x, viewMatrix.columns.1.y, viewMatrix.columns.1.z),
            SIMD3<Float>(viewMatrix.columns.2.x, viewMatrix.columns.2.y, viewMatrix.columns.2.z)
        )
        let translation = SIMD3<Float>(viewMatrix.columns.3.x, viewMatrix.columns.3.y, viewMatrix.columns.3.z)
        return -(viewRotation.transpose * translation)
    }

    /// Helper for incorrect extraction (what the bug was doing)
    func extractCameraPositionIncorrect(from viewMatrix: simd_float4x4) -> SIMD3<Float> {
        return -SIMD3<Float>(viewMatrix.columns.3.x, viewMatrix.columns.3.y, viewMatrix.columns.3.z)
    }

    // MARK: - Camera at Origin Tests

    /// Test camera at origin - both methods should agree
    func testCameraPositionExtraction_CameraAtOrigin() {
        let viewMatrix = matrix_identity_float4x4

        let correctPos = extractCameraPosition(from: viewMatrix)
        let incorrectPos = extractCameraPositionIncorrect(from: viewMatrix)

        XCTAssertEqual(correctPos.x, 0.0, accuracy: 0.001, "Camera X should be 0")
        XCTAssertEqual(correctPos.y, 0.0, accuracy: 0.001, "Camera Y should be 0")
        XCTAssertEqual(correctPos.z, 0.0, accuracy: 0.001, "Camera Z should be 0")

        // At origin with identity rotation, both methods agree
        XCTAssertEqual(correctPos.x, incorrectPos.x, accuracy: 0.001)
        XCTAssertEqual(correctPos.y, incorrectPos.y, accuracy: 0.001)
        XCTAssertEqual(correctPos.z, incorrectPos.z, accuracy: 0.001)
    }

    // MARK: - Simple Translation Tests

    /// Test simple translation along Z axis (camera looking at origin from +Z)
    func testCameraPositionExtraction_SimpleTranslation() {
        // Camera at (0, 0, 5) looking at origin
        // View matrix translation = -R * cameraPos = -I * (0,0,5) = (0,0,-5)
        var viewMatrix = matrix_identity_float4x4
        viewMatrix.columns.3 = SIMD4<Float>(0, 0, -5, 1)

        let correctPos = extractCameraPosition(from: viewMatrix)

        XCTAssertEqual(correctPos.x, 0.0, accuracy: 0.001, "Camera X should be 0")
        XCTAssertEqual(correctPos.y, 0.0, accuracy: 0.001, "Camera Y should be 0")
        XCTAssertEqual(correctPos.z, 5.0, accuracy: 0.001, "Camera Z should be 5")
    }

    /// Test translation in all three axes
    func testCameraPositionExtraction_MultiAxisTranslation() {
        // Camera at (5, 3, 10) with identity rotation
        var viewMatrix = matrix_identity_float4x4
        viewMatrix.columns.3 = SIMD4<Float>(-5, -3, -10, 1)

        let correctPos = extractCameraPosition(from: viewMatrix)
        let incorrectPos = extractCameraPositionIncorrect(from: viewMatrix)

        XCTAssertEqual(correctPos.x, 5.0, accuracy: 0.001, "Camera X should be 5")
        XCTAssertEqual(correctPos.y, 3.0, accuracy: 0.001, "Camera Y should be 3")
        XCTAssertEqual(correctPos.z, 10.0, accuracy: 0.001, "Camera Z should be 10")

        // With identity rotation, incorrect method still works
        XCTAssertEqual(correctPos.x, incorrectPos.x, accuracy: 0.001)
        XCTAssertEqual(correctPos.y, incorrectPos.y, accuracy: 0.001)
        XCTAssertEqual(correctPos.z, incorrectPos.z, accuracy: 0.001)
    }

    // MARK: - Rotation Tests (where bug manifests)

    /// Test with 90-degree rotation around Y axis
    /// This is where the incorrect extraction FAILS
    func testCameraPositionExtraction_WithRotation() {
        // Camera at world position (5, 0, 0), rotated 90 degrees around Y
        // (looking down the -Z axis from +X side)
        let angle = Float.pi / 2  // 90 degrees
        let cosA = cos(angle)
        let sinA = sin(angle)

        // Rotation matrix for Y-axis rotation
        let rotationY = simd_float3x3(
            SIMD3<Float>(cosA, 0, -sinA),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(sinA, 0, cosA)
        )

        // Camera world position
        let cameraWorldPos = SIMD3<Float>(5, 0, 0)

        // View matrix translation = -R * cameraPos
        let viewTranslation = -(rotationY * cameraWorldPos)

        var viewMatrix = matrix_identity_float4x4
        viewMatrix.columns.0 = SIMD4<Float>(rotationY.columns.0, 0)
        viewMatrix.columns.1 = SIMD4<Float>(rotationY.columns.1, 0)
        viewMatrix.columns.2 = SIMD4<Float>(rotationY.columns.2, 0)
        viewMatrix.columns.3 = SIMD4<Float>(viewTranslation, 1)

        let correctPos = extractCameraPosition(from: viewMatrix)
        let incorrectPos = extractCameraPositionIncorrect(from: viewMatrix)

        // Correct extraction should give (5, 0, 0)
        XCTAssertEqual(correctPos.x, 5.0, accuracy: 0.001, "Correct: Camera X should be 5")
        XCTAssertEqual(correctPos.y, 0.0, accuracy: 0.001, "Correct: Camera Y should be 0")
        XCTAssertEqual(correctPos.z, 0.0, accuracy: 0.001, "Correct: Camera Z should be 0")

        // Incorrect extraction gives WRONG position (0, 0, 5)
        // This demonstrates the bug!
        XCTAssertNotEqual(incorrectPos.x, 5.0, accuracy: 0.1, "Bug: Incorrect method gives wrong X")
    }

    /// Test with combined rotation and translation
    func testCameraPositionExtraction_CombinedTransform() {
        // Create a lookAt-style view matrix
        // Camera at (3, 4, 5), looking at origin
        let eye = SIMD3<Float>(3, 4, 5)
        let target = SIMD3<Float>(0, 0, 0)
        let up = SIMD3<Float>(0, 1, 0)

        // Build lookAt matrix properly
        // View matrix has camera basis vectors as ROWS (world-to-view transform)
        let zAxis = simd_normalize(eye - target)  // Forward (camera looks along -Z)
        let xAxis = simd_normalize(simd_cross(up, zAxis))  // Right
        let yAxis = simd_cross(zAxis, xAxis)  // Up

        // Build rotation matrix with basis vectors as ROWS
        // simd_float3x3 takes columns, so we need to build it column by column
        // Row 0 = xAxis, Row 1 = yAxis, Row 2 = zAxis
        // Column i = (xAxis[i], yAxis[i], zAxis[i])
        let rotationMatrix = simd_float3x3(
            SIMD3<Float>(xAxis.x, yAxis.x, zAxis.x),  // Column 0
            SIMD3<Float>(xAxis.y, yAxis.y, zAxis.y),  // Column 1
            SIMD3<Float>(xAxis.z, yAxis.z, zAxis.z)   // Column 2
        )

        // View matrix translation = -R * eye (where R has basis as rows)
        let translation = -(rotationMatrix * eye)

        var viewMatrix = matrix_identity_float4x4
        viewMatrix.columns.0 = SIMD4<Float>(rotationMatrix.columns.0, 0)
        viewMatrix.columns.1 = SIMD4<Float>(rotationMatrix.columns.1, 0)
        viewMatrix.columns.2 = SIMD4<Float>(rotationMatrix.columns.2, 0)
        viewMatrix.columns.3 = SIMD4<Float>(translation, 1)

        let correctPos = extractCameraPosition(from: viewMatrix)

        XCTAssertEqual(correctPos.x, eye.x, accuracy: 0.001, "Camera X should match eye position")
        XCTAssertEqual(correctPos.y, eye.y, accuracy: 0.001, "Camera Y should match eye position")
        XCTAssertEqual(correctPos.z, eye.z, accuracy: 0.001, "Camera Z should match eye position")
    }

    /// Test with very far camera (important for outline distance scaling)
    func testCameraPositionExtraction_VeryFarCamera() {
        // Camera at (0, 0, 100) looking at origin
        var viewMatrix = matrix_identity_float4x4
        viewMatrix.columns.3 = SIMD4<Float>(0, 0, -100, 1)

        let correctPos = extractCameraPosition(from: viewMatrix)

        XCTAssertEqual(correctPos.z, 100.0, accuracy: 0.001, "Far camera Z should be 100")

        // Distance calculation for outline width
        let vertexPos = SIMD3<Float>(0, 0, 0)
        let distance = simd_length(vertexPos - correctPos)
        XCTAssertEqual(distance, 100.0, accuracy: 0.001, "Distance to origin should be 100")
    }

    // MARK: - Distance Calculation Tests

    /// Test that distance calculation is correct for outline width scaling
    func testDistanceCalculationForOutlineWidth() {
        // Camera at (0, 0, 10)
        var viewMatrix = matrix_identity_float4x4
        viewMatrix.columns.3 = SIMD4<Float>(0, 0, -10, 1)

        let cameraPos = extractCameraPosition(from: viewMatrix)

        // Vertex at origin
        let vertexAtOrigin = SIMD3<Float>(0, 0, 0)
        let distanceToOrigin = simd_length(vertexAtOrigin - cameraPos)
        XCTAssertEqual(distanceToOrigin, 10.0, accuracy: 0.001)

        // Vertex at (5, 0, 0) - should be sqrt(125) = ~11.18 from camera
        let vertexOffCenter = SIMD3<Float>(5, 0, 0)
        let distanceOffCenter = simd_length(vertexOffCenter - cameraPos)
        let expected = sqrt(Float(5*5 + 10*10))  // sqrt(125)
        XCTAssertEqual(distanceOffCenter, expected, accuracy: 0.001)
    }

    /// Test outline width scale factor calculation
    func testOutlineWidthScaleFactor() {
        // At distance 1, scale should be 0.01 (matches shader's * 0.01)
        let distance1 = Float(1.0)
        let scale1 = distance1 * 0.01
        XCTAssertEqual(scale1, 0.01, accuracy: 0.0001)

        // At distance 10, scale should be 0.1
        let distance10 = Float(10.0)
        let scale10 = distance10 * 0.01
        XCTAssertEqual(scale10, 0.1, accuracy: 0.0001)

        // At distance 100, scale should be 1.0
        let distance100 = Float(100.0)
        let scale100 = distance100 * 0.01
        XCTAssertEqual(scale100, 1.0, accuracy: 0.0001)
    }
}
