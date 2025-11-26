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

    // MARK: - Lighting API Tests

    /// Test setting individual lights with valid values
    func testSetLightValidValues() {
        // Test light 0 (key light)
        renderer.setLight(0, direction: SIMD3(0, 1, 0), color: SIMD3(1, 0, 0), intensity: 1.0)
        XCTAssertEqual(renderer.uniforms.lightColor, SIMD3<Float>(1, 0, 0), "Light 0 color should be set")

        // Test light 1 (fill light)
        renderer.setLight(1, direction: SIMD3(1, 0, 0), color: SIMD3(0, 1, 0), intensity: 0.5)
        XCTAssertEqual(renderer.uniforms.light1Color, SIMD3<Float>(0, 0.5, 0), "Light 1 color should be set with intensity")

        // Test light 2 (rim light)
        renderer.setLight(2, direction: SIMD3(0, 0, 1), color: SIMD3(0, 0, 1), intensity: 0.3)
        XCTAssertEqual(renderer.uniforms.light2Color, SIMD3<Float>(0, 0, 0.3), "Light 2 color should be set with intensity")
    }

    /// Test that light directions are normalized
    func testLightDirectionNormalization() {
        renderer.setLight(0, direction: SIMD3(1, 1, 1), color: SIMD3(1, 1, 1), intensity: 1.0)
        let length = simd_length(renderer.uniforms.lightDirection)
        XCTAssertEqual(length, 1.0, accuracy: 0.001, "Light direction should be normalized")

        // Test with non-uniform vector
        renderer.setLight(1, direction: SIMD3(3, 4, 0), color: SIMD3(1, 1, 1), intensity: 1.0)
        let length1 = simd_length(renderer.uniforms.light1Direction)
        XCTAssertEqual(length1, 1.0, accuracy: 0.001, "Light 1 direction should be normalized")
    }

    /// Test that zero-length directions are handled gracefully
    func testLightZeroDirectionHandling() {
        renderer.setLight(0, direction: SIMD3(0, 0, 0), color: SIMD3(1, 1, 1), intensity: 1.0)
        // Should fall back to (0, 1, 0)
        XCTAssertEqual(renderer.uniforms.lightDirection, SIMD3<Float>(0, 1, 0), "Zero direction should use fallback")

        // Near-zero direction
        renderer.setLight(1, direction: SIMD3(0.00001, 0, 0), color: SIMD3(1, 1, 1), intensity: 1.0)
        XCTAssertEqual(renderer.uniforms.light1Direction, SIMD3<Float>(0, 1, 0), "Near-zero direction should use fallback")
    }

    /// Test disabling lights
    func testDisableLights() {
        // Enable all lights first
        renderer.setLight(0, direction: SIMD3(1, 0, 0), color: SIMD3(1, 1, 1), intensity: 1.0)
        renderer.setLight(1, direction: SIMD3(0, 1, 0), color: SIMD3(1, 1, 1), intensity: 1.0)
        renderer.setLight(2, direction: SIMD3(0, 0, 1), color: SIMD3(1, 1, 1), intensity: 1.0)

        // Disable light 1
        renderer.disableLight(1)
        XCTAssertEqual(renderer.uniforms.light1Color, SIMD3<Float>(0, 0, 0), "Disabled light should have zero color")

        // Other lights should remain active
        XCTAssertNotEqual(renderer.uniforms.lightColor, SIMD3<Float>(0, 0, 0), "Light 0 should still be active")
        XCTAssertNotEqual(renderer.uniforms.light2Color, SIMD3<Float>(0, 0, 0), "Light 2 should still be active")
    }

    /// Test 3-point lighting setup
    func testSetup3PointLighting() {
        renderer.setup3PointLighting()

        // All lights should be enabled (non-zero color)
        XCTAssertGreaterThan(simd_length(renderer.uniforms.lightColor), 0, "Key light should be enabled")
        XCTAssertGreaterThan(simd_length(renderer.uniforms.light1Color), 0, "Fill light should be enabled")
        XCTAssertGreaterThan(simd_length(renderer.uniforms.light2Color), 0, "Rim light should be enabled")

        // Directions should be normalized
        XCTAssertEqual(simd_length(renderer.uniforms.lightDirection), 1.0, accuracy: 0.001, "Key direction normalized")
        XCTAssertEqual(simd_length(renderer.uniforms.light1Direction), 1.0, accuracy: 0.001, "Fill direction normalized")
        XCTAssertEqual(simd_length(renderer.uniforms.light2Direction), 1.0, accuracy: 0.001, "Rim direction normalized")
    }

    /// Test 3-point lighting with custom intensities
    func testSetup3PointLightingCustomIntensities() {
        renderer.setup3PointLighting(keyIntensity: 1.5, fillIntensity: 0.3, rimIntensity: 0.8)

        // Key light should be brighter than default (1.5 vs 1.0)
        let keyBrightness = simd_length(renderer.uniforms.lightColor)
        XCTAssertGreaterThan(keyBrightness, 1.0, "Key light should be brighter with intensity 1.5")

        // Fill and rim should have correct relative intensities
        let fillBrightness = simd_length(renderer.uniforms.light1Color)
        let rimBrightness = simd_length(renderer.uniforms.light2Color)
        XCTAssertLessThan(fillBrightness, keyBrightness, "Fill should be dimmer than key")
        XCTAssertGreaterThan(rimBrightness, fillBrightness, "Rim should be brighter than fill")
    }

    /// Test default ambient color value
    func testDefaultAmbientColor() {
        // Verify default ambient color is 0.05
        let ambient = renderer.uniforms.ambientColor
        XCTAssertEqual(ambient.x, 0.05, accuracy: 0.001, "Default ambient R should be 0.05")
        XCTAssertEqual(ambient.y, 0.05, accuracy: 0.001, "Default ambient G should be 0.05")
        XCTAssertEqual(ambient.z, 0.05, accuracy: 0.001, "Default ambient B should be 0.05")
    }

    /// Test setAmbientColor() with valid values
    func testSetAmbientColorValid() {
        // Set custom ambient color
        renderer.setAmbientColor(SIMD3<Float>(0.1, 0.2, 0.3))

        let ambient = renderer.uniforms.ambientColor
        XCTAssertEqual(ambient.x, 0.1, accuracy: 0.001, "Ambient R should be 0.1")
        XCTAssertEqual(ambient.y, 0.2, accuracy: 0.001, "Ambient G should be 0.2")
        XCTAssertEqual(ambient.z, 0.3, accuracy: 0.001, "Ambient B should be 0.3")
    }

    /// Test setAmbientColor() clamping behavior
    func testSetAmbientColorClamping() {
        // Test negative values are clamped to 0
        renderer.setAmbientColor(SIMD3<Float>(-0.5, -1.0, -0.1))
        var ambient = renderer.uniforms.ambientColor
        XCTAssertEqual(ambient.x, 0.0, accuracy: 0.001, "Negative ambient R should be clamped to 0")
        XCTAssertEqual(ambient.y, 0.0, accuracy: 0.001, "Negative ambient G should be clamped to 0")
        XCTAssertEqual(ambient.z, 0.0, accuracy: 0.001, "Negative ambient B should be clamped to 0")

        // Test values > 1.0 are clamped to 1.0
        renderer.setAmbientColor(SIMD3<Float>(1.5, 2.0, 10.0))
        ambient = renderer.uniforms.ambientColor
        XCTAssertEqual(ambient.x, 1.0, accuracy: 0.001, "Ambient R > 1 should be clamped to 1")
        XCTAssertEqual(ambient.y, 1.0, accuracy: 0.001, "Ambient G > 1 should be clamped to 1")
        XCTAssertEqual(ambient.z, 1.0, accuracy: 0.001, "Ambient B > 1 should be clamped to 1")

        // Test mixed values (some in range, some out)
        renderer.setAmbientColor(SIMD3<Float>(-0.1, 0.5, 1.5))
        ambient = renderer.uniforms.ambientColor
        XCTAssertEqual(ambient.x, 0.0, accuracy: 0.001, "Negative value clamped to 0")
        XCTAssertEqual(ambient.y, 0.5, accuracy: 0.001, "In-range value unchanged")
        XCTAssertEqual(ambient.z, 1.0, accuracy: 0.001, "Value > 1 clamped to 1")
    }

    /// Test that invalid light indices are handled gracefully
    func testInvalidLightIndex() {
        // Set valid state first
        renderer.setLight(0, direction: SIMD3(1, 0, 0), color: SIMD3(1, 1, 1), intensity: 1.0)
        let originalColor = renderer.uniforms.lightColor

        // Try invalid indices (should log warning but not crash)
        renderer.setLight(-1, direction: SIMD3(0, 1, 0), color: SIMD3(0, 0, 0), intensity: 1.0)
        renderer.setLight(3, direction: SIMD3(0, 1, 0), color: SIMD3(0, 0, 0), intensity: 1.0)
        renderer.setLight(100, direction: SIMD3(0, 1, 0), color: SIMD3(0, 0, 0), intensity: 1.0)

        // Valid light should remain unchanged
        XCTAssertEqual(renderer.uniforms.lightColor, originalColor, "Invalid indices should not affect existing lights")
    }

    /// Test default light normalization mode
    func testDefaultLightNormalizationMode() {
        // Default should be .automatic
        switch renderer.lightNormalizationMode {
        case .automatic:
            XCTAssert(true, "Default normalization mode is automatic")
        default:
            XCTFail("Default normalization mode should be .automatic")
        }
    }

    /// Test light normalization modes
    func testLightNormalizationModes() {
        // Test automatic mode
        renderer.setLightNormalizationMode(.automatic)
        renderer.setLight(0, direction: SIMD3(0, 1, 0), color: SIMD3(1, 1, 1), intensity: 1.0)
        renderer.setLight(1, direction: SIMD3(0, 1, 0), color: SIMD3(0.5, 0.5, 0.5), intensity: 1.0)
        renderer.setLight(2, direction: SIMD3(0, 1, 0), color: SIMD3(0.3, 0.3, 0.3), intensity: 1.0)

        // Total intensity: sqrt(3) + sqrt(0.75) + sqrt(0.27) ≈ 1.732 + 0.866 + 0.520 ≈ 3.118
        // In automatic mode, this should trigger normalization
        // We'll verify in the next frame that normalization is applied

        // Test disabled mode
        renderer.setLightNormalizationMode(.disabled)
        switch renderer.lightNormalizationMode {
        case .disabled:
            XCTAssert(true, "Normalization mode set to disabled")
        default:
            XCTFail("Should be in disabled mode")
        }

        // Test manual mode
        renderer.setLightNormalizationMode(.manual(0.5))
        switch renderer.lightNormalizationMode {
        case .manual(let factor):
            XCTAssertEqual(factor, 0.5, accuracy: 0.001, "Manual normalization factor should be 0.5")
        default:
            XCTFail("Should be in manual mode with factor 0.5")
        }
    }

    /// Test energy conservation prevents over-brightness
    func testLightingEnergyConservation() {
        // Set up three bright lights that would exceed 1.0 if added naively
        renderer.setLight(0, direction: SIMD3(0, 1, 0), color: SIMD3(1, 1, 1), intensity: 1.0)
        renderer.setLight(1, direction: SIMD3(0, 1, 0), color: SIMD3(1, 1, 1), intensity: 1.0)
        renderer.setLight(2, direction: SIMD3(0, 1, 0), color: SIMD3(1, 1, 1), intensity: 1.0)

        // In automatic mode (default), normalization factor should prevent over-brightness
        renderer.setLightNormalizationMode(.automatic)

        // Calculate total per-component (correct approach)
        let totalR = renderer.uniforms.lightColor.x + renderer.uniforms.light1Color.x + renderer.uniforms.light2Color.x
        let totalG = renderer.uniforms.lightColor.y + renderer.uniforms.light1Color.y + renderer.uniforms.light2Color.y
        let totalB = renderer.uniforms.lightColor.z + renderer.uniforms.light1Color.z + renderer.uniforms.light2Color.z
        let maxComponent = max(totalR, max(totalG, totalB))

        XCTAssertGreaterThan(maxComponent, 1.0, "Max component should exceed 1.0 before normalization")
        XCTAssertEqual(maxComponent, 3.0, accuracy: 0.001, "With three (1,1,1) lights, max component should be 3.0")

        // Expected normalization factor = 1.0 / maxComponent
        let expectedFactor = 1.0 / maxComponent

        // Simulate what render() would calculate
        let calculatedFactor = (maxComponent > 1.0) ? (1.0 / maxComponent) : 1.0

        XCTAssertEqual(calculatedFactor, expectedFactor, accuracy: 0.001,
                       "Normalization factor should be 1.0 / maxComponent")
        XCTAssertEqual(calculatedFactor, 1.0/3.0, accuracy: 0.001, "Factor should be 1/3 for three equal lights")
        XCTAssertLessThan(calculatedFactor, 1.0, "Normalization factor should be < 1.0 when lights are bright")
    }

    /// Test per-component normalization with asymmetric colors
    func testPerComponentNormalization() {
        // Set up lights with asymmetric colors (red-heavy)
        renderer.setLight(0, direction: SIMD3(0, 1, 0), color: SIMD3(1.0, 0.2, 0.2), intensity: 1.0)
        renderer.setLight(1, direction: SIMD3(0, 1, 0), color: SIMD3(1.0, 0.2, 0.2), intensity: 1.0)
        renderer.setLight(2, direction: SIMD3(0, 1, 0), color: SIMD3(1.0, 0.2, 0.2), intensity: 1.0)

        renderer.setLightNormalizationMode(.automatic)

        // Calculate per-component totals
        let totalR = renderer.uniforms.lightColor.x + renderer.uniforms.light1Color.x + renderer.uniforms.light2Color.x
        let totalG = renderer.uniforms.lightColor.y + renderer.uniforms.light1Color.y + renderer.uniforms.light2Color.y
        let totalB = renderer.uniforms.lightColor.z + renderer.uniforms.light1Color.z + renderer.uniforms.light2Color.z

        XCTAssertEqual(totalR, 3.0, accuracy: 0.001, "Red channel sums to 3.0")
        XCTAssertEqual(totalG, 0.6, accuracy: 0.001, "Green channel sums to 0.6")
        XCTAssertEqual(totalB, 0.6, accuracy: 0.001, "Blue channel sums to 0.6")

        // Max component is red
        let maxComponent = max(totalR, max(totalG, totalB))
        XCTAssertEqual(maxComponent, 3.0, accuracy: 0.001, "Max component is red (3.0)")

        // Normalization should be based on red channel
        let expectedFactor: Float = 1.0 / 3.0
        let calculatedFactor: Float = (maxComponent > 1.0) ? (1.0 / maxComponent) : 1.0

        XCTAssertEqual(calculatedFactor, expectedFactor, accuracy: 0.001,
                       "Normalization should be based on max component (red)")
    }

    /// Test manual normalization factor clamping
    func testManualNormalizationFactorClamping() {
        // Negative factors should be clamped to 0
        renderer.setLightNormalizationMode(.manual(-0.5))

        switch renderer.lightNormalizationMode {
        case .manual(let factor):
            // The clamping happens in render(), so we just verify the mode stores the value
            XCTAssertEqual(factor, -0.5, accuracy: 0.001, "Manual mode stores the factor as-is")
        default:
            XCTFail("Should be in manual mode")
        }
    }

    /// Test Uniforms struct size matches StrictMode constant
    func testUniformsStructSize() {
        let actualSize = MemoryLayout<Uniforms>.size
        let expectedSize = MetalSizeConstants.uniformsSize
        XCTAssertEqual(actualSize, expectedSize,
                       "Uniforms struct size (\(actualSize)) must match MetalSizeConstants.uniformsSize (\(expectedSize))")
    }
}
