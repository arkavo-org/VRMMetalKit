// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Unit tests for VRMRenderer projection matrix and configuration validation
final class VRMRendererTests: XCTestCase {

    var device: MTLDevice!
    var renderer: VRMRenderer!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
        self.renderer = VRMRenderer(device: device)
    }

    // MARK: - FOV Validation Tests

    /// Test that default FOV is 60 degrees
    func testFOVDefaultValue() {
        XCTAssertEqual(renderer.fovDegrees, 60.0, "Default FOV should be 60 degrees")
    }

    /// Test that valid FOV values are accepted without clamping
    func testFOVValidRange() {
        let validValues: [Float] = [1.0, 30.0, 45.0, 60.0, 90.0, 120.0, 179.0]

        for value in validValues {
            renderer.fovDegrees = value
            XCTAssertEqual(renderer.fovDegrees, value, "Valid FOV \(value) should not be clamped")
        }
    }

    /// Test that negative and zero FOV values are clamped to 1.0
    func testFOVClampingLowerBound() {
        let invalidValues: [Float] = [-100.0, -10.0, -1.0, 0.0]

        for value in invalidValues {
            renderer.fovDegrees = value
            XCTAssertEqual(renderer.fovDegrees, 1.0, "FOV \(value) should be clamped to 1.0")
        }
    }

    /// Test that FOV values >= 180 are clamped to 179.0
    func testFOVClampingUpperBound() {
        let invalidValues: [Float] = [180.0, 181.0, 200.0, 360.0, 1000.0]

        for value in invalidValues {
            renderer.fovDegrees = value
            XCTAssertEqual(renderer.fovDegrees, 179.0, "FOV \(value) should be clamped to 179.0")
        }
    }

    /// Test exact boundary values for FOV
    func testFOVBoundaryValues() {
        // Just below lower bound - should NOT clamp (0.99 > 0)
        renderer.fovDegrees = 0.99
        XCTAssertEqual(renderer.fovDegrees, 0.99, "FOV 0.99 should be accepted (> 0)")

        // Exact lower bound - should accept
        renderer.fovDegrees = 1.0
        XCTAssertEqual(renderer.fovDegrees, 1.0, "FOV 1.0 should be accepted")

        // Exact upper bound - should accept
        renderer.fovDegrees = 179.0
        XCTAssertEqual(renderer.fovDegrees, 179.0, "FOV 179.0 should be accepted")

        // Just above upper bound - should NOT clamp (179.01 < 180)
        renderer.fovDegrees = 179.01
        XCTAssertEqual(renderer.fovDegrees, 179.01, "FOV 179.01 should be accepted (< 180)")

        // Exact boundaries that trigger clamping
        renderer.fovDegrees = 0.0
        XCTAssertEqual(renderer.fovDegrees, 1.0, "FOV 0.0 should be clamped to 1.0")

        renderer.fovDegrees = 180.0
        XCTAssertEqual(renderer.fovDegrees, 179.0, "FOV 180.0 should be clamped to 179.0")
    }

    // MARK: - Orthographic Projection Matrix Tests

    /// Test that orthographic projection produces a valid 4x4 matrix
    func testOrthographicProjectionStructure() {
        renderer.useOrthographic = true
        let matrix = renderer.makeProjectionMatrix(aspectRatio: 1.0)

        // Verify it's a valid matrix (no NaN or infinity)
        for col in 0..<4 {
            for row in 0..<4 {
                let value = matrix[col][row]
                XCTAssertTrue(value.isFinite, "Matrix element [\(col)][\(row)] should be finite, got \(value)")
            }
        }
    }

    /// Test orthographic projection scaling factors
    func testOrthographicScaling() {
        renderer.useOrthographic = true
        renderer.orthoSize = 2.0  // Height in world units
        let aspectRatio: Float = 1.0
        let matrix = renderer.makeProjectionMatrix(aspectRatio: aspectRatio)

        let halfHeight = renderer.orthoSize / 2.0  // 1.0
        let halfWidth = halfHeight * aspectRatio   // 1.0
        let width = halfWidth * 2.0                // 2.0
        let height = halfHeight * 2.0              // 2.0

        // Verify scaling factors
        XCTAssertEqual(matrix.columns.0.x, 2.0 / width, accuracy: 0.001, "X scaling should be 2.0/width")
        XCTAssertEqual(matrix.columns.1.y, 2.0 / height, accuracy: 0.001, "Y scaling should be 2.0/height")
    }

    /// Test orthographic projection depth mapping (Metal reverse-Z)
    func testOrthographicDepthMapping() {
        renderer.useOrthographic = true
        let matrix = renderer.makeProjectionMatrix(aspectRatio: 1.0)

        let nearZ: Float = 0.1
        let farZ: Float = 100.0
        let depth = farZ - nearZ

        // Metal reverse-Z convention: maps nearZ -> 1.0, farZ -> 0.0 in clip space
        XCTAssertEqual(matrix.columns.2.z, -1.0 / depth, accuracy: 0.001, "Z scaling should be -1.0/depth")
        XCTAssertEqual(matrix.columns.3.z, farZ / depth, accuracy: 0.001, "Z offset should be farZ/depth")
    }

    /// Test orthographic projection with different aspect ratios
    func testOrthographicAspectRatio() {
        renderer.useOrthographic = true
        renderer.orthoSize = 2.0

        let aspectRatios: [(Float, String)] = [
            (1.0, "1:1 (square)"),
            (16.0 / 9.0, "16:9 (widescreen)"),
            (4.0 / 3.0, "4:3 (standard)"),
            (9.0 / 16.0, "9:16 (portrait)")
        ]

        for (aspectRatio, description) in aspectRatios {
            let matrix = renderer.makeProjectionMatrix(aspectRatio: aspectRatio)

            let halfHeight = renderer.orthoSize / 2.0
            let halfWidth = halfHeight * aspectRatio
            let width = halfWidth * 2.0
            let height = halfHeight * 2.0

            XCTAssertEqual(matrix.columns.0.x, 2.0 / width, accuracy: 0.001, "X scaling incorrect for \(description)")
            XCTAssertEqual(matrix.columns.1.y, 2.0 / height, accuracy: 0.001, "Y scaling incorrect for \(description)")
        }
    }

    /// Test orthographic projection with different orthoSize values
    func testOrthographicOrthoSize() {
        renderer.useOrthographic = true

        let orthoSizes: [Float] = [0.5, 1.0, 2.0, 5.0, 10.0]

        for size in orthoSizes {
            renderer.orthoSize = size
            let matrix = renderer.makeProjectionMatrix(aspectRatio: 1.0)

            let height = size
            XCTAssertEqual(matrix.columns.1.y, 2.0 / height, accuracy: 0.001, "Y scaling incorrect for orthoSize \(size)")
        }
    }

    // MARK: - Perspective Projection Matrix Tests

    /// Test that perspective projection produces a valid 4x4 matrix
    func testPerspectiveProjectionStructure() {
        renderer.useOrthographic = false
        let matrix = renderer.makeProjectionMatrix(aspectRatio: 1.0)

        // Verify it's a valid matrix (no NaN or infinity)
        for col in 0..<4 {
            for row in 0..<4 {
                let value = matrix[col][row]
                XCTAssertTrue(value.isFinite, "Matrix element [\(col)][\(row)] should be finite, got \(value)")
            }
        }
    }

    /// Test perspective projection FOV conversion and factors
    func testPerspectiveFOVConversion() {
        renderer.useOrthographic = false
        renderer.fovDegrees = 60.0
        let aspectRatio: Float = 1.0
        let matrix = renderer.makeProjectionMatrix(aspectRatio: aspectRatio)

        // Calculate expected values
        let fovRadians = renderer.fovDegrees * Float.pi / 180.0
        let ys = 1.0 / tan(fovRadians * 0.5)
        let xs = ys / aspectRatio

        // Verify projection factors
        XCTAssertEqual(matrix.columns.0.x, xs, accuracy: 0.001, "X projection factor should match xs")
        XCTAssertEqual(matrix.columns.1.y, ys, accuracy: 0.001, "Y projection factor should match ys")
    }

    /// Test perspective projection with different FOV values
    func testPerspectiveWithDifferentFOV() {
        renderer.useOrthographic = false
        let aspectRatio: Float = 1.0

        let fovValues: [(Float, String)] = [
            (45.0, "45° (narrow)"),
            (60.0, "60° (standard)"),
            (90.0, "90° (wide)")
        ]

        for (fov, description) in fovValues {
            renderer.fovDegrees = fov
            let matrix = renderer.makeProjectionMatrix(aspectRatio: aspectRatio)

            let fovRadians = fov * Float.pi / 180.0
            let expectedYs = 1.0 / tan(fovRadians * 0.5)

            XCTAssertEqual(matrix.columns.1.y, expectedYs, accuracy: 0.001, "Y projection incorrect for \(description)")
        }
    }

    /// Test perspective projection with different aspect ratios
    func testPerspectiveAspectRatio() {
        renderer.useOrthographic = false
        renderer.fovDegrees = 60.0

        let aspectRatios: [(Float, String)] = [
            (1.0, "1:1 (square)"),
            (16.0 / 9.0, "16:9 (widescreen)"),
            (4.0 / 3.0, "4:3 (standard)")
        ]

        for (aspectRatio, description) in aspectRatios {
            let matrix = renderer.makeProjectionMatrix(aspectRatio: aspectRatio)

            let fovRadians = renderer.fovDegrees * Float.pi / 180.0
            let ys = 1.0 / tan(fovRadians * 0.5)
            let expectedXs = ys / aspectRatio

            XCTAssertEqual(matrix.columns.0.x, expectedXs, accuracy: 0.001, "X projection incorrect for \(description)")
        }
    }

    // MARK: - Edge Cases and Mode Switching

    /// Test switching between orthographic and perspective projection
    func testProjectionModeSwitching() {
        // Start with perspective
        renderer.useOrthographic = false
        let perspectiveMatrix = renderer.makeProjectionMatrix(aspectRatio: 1.0)

        // Switch to orthographic
        renderer.useOrthographic = true
        let orthographicMatrix = renderer.makeProjectionMatrix(aspectRatio: 1.0)

        // Matrices should be different
        XCTAssertNotEqual(perspectiveMatrix.columns.0.x, orthographicMatrix.columns.0.x,
                          "Perspective and orthographic matrices should differ")

        // Switch back to perspective
        renderer.useOrthographic = false
        let perspectiveMatrix2 = renderer.makeProjectionMatrix(aspectRatio: 1.0)

        // Should match original perspective matrix
        XCTAssertEqual(perspectiveMatrix.columns.0.x, perspectiveMatrix2.columns.0.x, accuracy: 0.001,
                       "Switching back should produce same perspective matrix")
    }

    /// Test orthoSize validation (must be positive)
    func testOrthoSizeValidation() {
        // Valid positive values
        renderer.orthoSize = 1.0
        XCTAssertEqual(renderer.orthoSize, 1.0)

        renderer.orthoSize = 5.0
        XCTAssertEqual(renderer.orthoSize, 5.0)

        // Attempt to set to zero - should be clamped
        renderer.orthoSize = 0.0
        XCTAssertGreaterThan(renderer.orthoSize, 0.0, "orthoSize should not allow zero")

        // Attempt to set to negative - should be clamped
        renderer.orthoSize = -1.0
        XCTAssertGreaterThan(renderer.orthoSize, 0.0, "orthoSize should not allow negative values")
    }

    /// Test that Metal reverse-Z depth values are correctly mapped
    func testMetalReverseZDepthMapping() {
        // Both projection types should use Metal's reverse-Z convention
        renderer.useOrthographic = true
        let orthoMatrix = renderer.makeProjectionMatrix(aspectRatio: 1.0)

        // For orthographic: nearZ (0.1) should map to 1.0, farZ (100.0) should map to 0.0
        let nearZ: Float = 0.1
        let farZ: Float = 100.0
        let depth = farZ - nearZ

        // The Z column should use -1.0/depth for reverse mapping
        XCTAssertEqual(orthoMatrix.columns.2.z, -1.0 / depth, accuracy: 0.001,
                       "Orthographic should use Metal reverse-Z convention")

        // Perspective already uses correct Metal convention (verified by existing code)
        renderer.useOrthographic = false
        let perspMatrix = renderer.makeProjectionMatrix(aspectRatio: 1.0)

        // Perspective uses: zs = farZ / (nearZ - farZ)
        let expectedZs = farZ / (nearZ - farZ)
        XCTAssertEqual(perspMatrix.columns.2.z, expectedZs, accuracy: 0.001,
                       "Perspective should use Metal reverse-Z convention")
    }
}
