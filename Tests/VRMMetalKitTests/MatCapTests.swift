// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import simd
@testable import VRMMetalKit

/// Unit tests for MToon MatCap (sphere mapping) calculations
/// MatCap maps view-space normals to UV coordinates for texture sampling
final class MatCapTests: XCTestCase {

    // MARK: - MatCap UV Calculation Tests

    /// Helper function matching the shader's calculateMatCapUV
    func calculateMatCapUV(_ viewNormal: SIMD3<Float>) -> SIMD2<Float> {
        return SIMD2<Float>(viewNormal.x, viewNormal.y) * 0.5 + 0.5
    }

    /// Center normal (pointing at camera) should map to center UV
    func testMatCapUV_CenterNormal_ReturnsCenterUV() {
        let viewNormal = SIMD3<Float>(0, 0, -1)  // Pointing at camera
        let uv = calculateMatCapUV(viewNormal)

        XCTAssertEqual(uv.x, 0.5, accuracy: 0.001, "Center normal X should map to UV 0.5")
        XCTAssertEqual(uv.y, 0.5, accuracy: 0.001, "Center normal Y should map to UV 0.5")
    }

    /// Right-pointing normal should map to right edge
    func testMatCapUV_RightNormal_ReturnsRightEdge() {
        let viewNormal = SIMD3<Float>(1, 0, 0)  // Pointing right
        let uv = calculateMatCapUV(viewNormal)

        XCTAssertEqual(uv.x, 1.0, accuracy: 0.001, "Right normal should map to UV.x = 1.0")
        XCTAssertEqual(uv.y, 0.5, accuracy: 0.001, "Right normal should map to UV.y = 0.5")
    }

    /// Left-pointing normal should map to left edge
    func testMatCapUV_LeftNormal_ReturnsLeftEdge() {
        let viewNormal = SIMD3<Float>(-1, 0, 0)  // Pointing left
        let uv = calculateMatCapUV(viewNormal)

        XCTAssertEqual(uv.x, 0.0, accuracy: 0.001, "Left normal should map to UV.x = 0.0")
        XCTAssertEqual(uv.y, 0.5, accuracy: 0.001, "Left normal should map to UV.y = 0.5")
    }

    /// Up-pointing normal should map to top edge
    func testMatCapUV_TopNormal_ReturnsTopEdge() {
        let viewNormal = SIMD3<Float>(0, 1, 0)  // Pointing up
        let uv = calculateMatCapUV(viewNormal)

        XCTAssertEqual(uv.x, 0.5, accuracy: 0.001, "Top normal should map to UV.x = 0.5")
        XCTAssertEqual(uv.y, 1.0, accuracy: 0.001, "Top normal should map to UV.y = 1.0")
    }

    /// Down-pointing normal should map to bottom edge
    func testMatCapUV_BottomNormal_ReturnsBottomEdge() {
        let viewNormal = SIMD3<Float>(0, -1, 0)  // Pointing down
        let uv = calculateMatCapUV(viewNormal)

        XCTAssertEqual(uv.x, 0.5, accuracy: 0.001, "Bottom normal should map to UV.x = 0.5")
        XCTAssertEqual(uv.y, 0.0, accuracy: 0.001, "Bottom normal should map to UV.y = 0.0")
    }

    /// Diagonal normals should map correctly
    func testMatCapUV_DiagonalNormal() {
        // Normalized (1, 1, 0) = (0.707, 0.707, 0)
        let viewNormal = simd_normalize(SIMD3<Float>(1, 1, 0))
        let uv = calculateMatCapUV(viewNormal)

        let expected: Float = 0.707 * 0.5 + 0.5  // ≈ 0.854
        XCTAssertEqual(uv.x, expected, accuracy: 0.01)
        XCTAssertEqual(uv.y, expected, accuracy: 0.01)
    }

    // MARK: - MatCap Factor Tests

    /// MatCap factor should multiply the sampled color
    func testMatCapFactor_Multiplication() {
        let sampledColor = SIMD3<Float>(1.0, 0.8, 0.6)
        let matcapFactor = SIMD3<Float>(0.5, 0.5, 0.5)

        let result = sampledColor * matcapFactor
        XCTAssertEqual(result.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(result.y, 0.4, accuracy: 0.001)
        XCTAssertEqual(result.z, 0.3, accuracy: 0.001)
    }

    /// MatCap should be additive to final lit color
    func testMatCapApplication_IsAdditive() {
        let litColor = SIMD3<Float>(0.5, 0.5, 0.5)
        let matcapColor = SIMD3<Float>(0.3, 0.2, 0.1)
        let matcapFactor = SIMD3<Float>(1.0, 1.0, 1.0)

        let finalColor = litColor + matcapColor * matcapFactor
        XCTAssertEqual(finalColor.x, 0.8, accuracy: 0.001)
        XCTAssertEqual(finalColor.y, 0.7, accuracy: 0.001)
        XCTAssertEqual(finalColor.z, 0.6, accuracy: 0.001)
    }

    // MARK: - MToonMaterialUniforms MatCap Parameter Tests

    /// Test that MToonMaterialUniforms correctly stores MatCap parameters
    func testMToonMaterialUniforms_MatCapParameters() {
        var uniforms = MToonMaterialUniforms()
        uniforms.matcapFactor = SIMD3<Float>(0.8, 0.9, 1.0)
        uniforms.hasMatcapTexture = 1

        XCTAssertEqual(uniforms.matcapR, 0.8, accuracy: 0.001)
        XCTAssertEqual(uniforms.matcapG, 0.9, accuracy: 0.001)
        XCTAssertEqual(uniforms.matcapB, 1.0, accuracy: 0.001)
        XCTAssertEqual(uniforms.hasMatcapTexture, 1)
    }

    /// Test validation of MatCap factor range
    func testMToonMaterialUniforms_MatCapValidation() {
        var uniforms = MToonMaterialUniforms()

        // MatCap factor above 4 should fail (spec allows 0-4 for HDR)
        uniforms.matcapFactor = SIMD3<Float>(5.0, 0.0, 0.0)
        XCTAssertThrowsError(try uniforms.validate()) { error in
            guard case VRMMaterialValidationError.matcapFactorOutOfRange = error else {
                XCTFail("Expected matcapFactorOutOfRange error")
                return
            }
        }

        // Negative should also fail
        uniforms.matcapFactor = SIMD3<Float>(-0.1, 0.0, 0.0)
        XCTAssertThrowsError(try uniforms.validate()) { error in
            guard case VRMMaterialValidationError.matcapFactorOutOfRange = error else {
                XCTFail("Expected matcapFactorOutOfRange error")
                return
            }
        }
    }

    // MARK: - View Normal Transformation Tests

    /// View normal should be computed correctly from world normal and view matrix
    func testViewNormalTransformation() {
        // World normal pointing up
        let worldNormal = SIMD4<Float>(0, 1, 0, 0)

        // Identity view matrix (camera at origin looking down -Z)
        let viewMatrix = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )

        let normalMatrix = viewMatrix  // For identity, normalMatrix = viewMatrix

        let viewNormal = simd_normalize((viewMatrix * normalMatrix * worldNormal).xyz)

        XCTAssertEqual(viewNormal.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(viewNormal.y, 1.0, accuracy: 0.001)
        XCTAssertEqual(viewNormal.z, 0.0, accuracy: 0.001)
    }
}

// MARK: - SIMD4 Extension for xyz
extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> {
        return SIMD3<Float>(x, y, z)
    }
}
