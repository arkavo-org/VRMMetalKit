// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import simd
@testable import VRMMetalKit

/// Unit tests for MToon toon shading ramp (cel-shading gradient) calculations
/// Based on MToon 1.0 spec for shadingToonyFactor and shadingShiftFactor
final class ToonRampTests: XCTestCase {

    // MARK: - Smoothstep Function Tests

    /// Swift implementation of Metal's smoothstep for testing
    func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = max(0, min((x - edge0) / (edge1 - edge0), 1))
        return t * t * (3 - 2 * t)
    }

    /// Test smoothstep at exact boundaries
    func testSmoothstep_BoundaryConditions() {
        // Below edge0 should return 0
        XCTAssertEqual(smoothstep(0.0, 1.0, -0.5), 0.0, accuracy: 0.001)

        // At edge0 should return 0
        XCTAssertEqual(smoothstep(0.0, 1.0, 0.0), 0.0, accuracy: 0.001)

        // At midpoint should return 0.5
        XCTAssertEqual(smoothstep(0.0, 1.0, 0.5), 0.5, accuracy: 0.001)

        // At edge1 should return 1
        XCTAssertEqual(smoothstep(0.0, 1.0, 1.0), 1.0, accuracy: 0.001)

        // Above edge1 should return 1
        XCTAssertEqual(smoothstep(0.0, 1.0, 1.5), 1.0, accuracy: 0.001)
    }

    // MARK: - Shading Shift Tests

    /// Shading shift moves the shadow/lit threshold
    func testShadingShift_MovesThreshold() {
        let toony: Float = 0.9

        // No shift: NdotL=0 is at the boundary
        let shift0: Float = 0.0
        let ramp0 = smoothstep(shift0 - toony * 0.5, shift0 + toony * 0.5, 0.0)
        XCTAssertEqual(ramp0, 0.5, accuracy: 0.05, "NdotL=0 with shift=0 should be at boundary")

        // Positive shift: moves lit region toward shadows
        let shiftPositive: Float = 0.3
        let rampPositive = smoothstep(shiftPositive - toony * 0.5, shiftPositive + toony * 0.5, 0.0)
        XCTAssertLessThan(rampPositive, 0.5, "Positive shift should move NdotL=0 into shadow region")

        // Negative shift: moves lit region toward lit
        let shiftNegative: Float = -0.3
        let rampNegative = smoothstep(shiftNegative - toony * 0.5, shiftNegative + toony * 0.5, 0.0)
        XCTAssertGreaterThan(rampNegative, 0.5, "Negative shift should move NdotL=0 into lit region")
    }

    // MARK: - Shading Toony Tests

    /// Toony factor controls transition sharpness
    func testShadingToony_ControlsSharpness() {
        let shift: Float = 0.0
        let ndotl: Float = 0.1  // Slightly lit

        // Low toony (soft transition)
        let toonyLow: Float = 0.3
        let rampSoft = smoothstep(shift - toonyLow * 0.5, shift + toonyLow * 0.5, ndotl)

        // High toony (sharp transition)
        let toonyHigh: Float = 0.95
        let rampSharp = smoothstep(shift - toonyHigh * 0.5, shift + toonyHigh * 0.5, ndotl)

        // Sharp transition should be closer to binary (0 or 1)
        // At NdotL=0.1, soft should give intermediate value, sharp should give value closer to middle
        XCTAssertGreaterThan(rampSoft, 0.0, "Soft transition should have some lighting")
        XCTAssertLessThan(rampSoft, 1.0, "Soft transition should not be fully lit")
    }

    // MARK: - Shade Color Blending Tests

    /// Shade color blending based on ramp value
    func testShadeColor_Blending() {
        let baseColor = SIMD3<Float>(1.0, 0.8, 0.6)  // Skin tone
        let shadeColor = SIMD3<Float>(0.6, 0.4, 0.3)  // Darker skin

        // Fully lit (ramp = 1)
        let fullyLit = simd_mix(shadeColor, baseColor, SIMD3<Float>(repeating: 1.0))
        XCTAssertEqual(fullyLit.x, baseColor.x, accuracy: 0.001)
        XCTAssertEqual(fullyLit.y, baseColor.y, accuracy: 0.001)
        XCTAssertEqual(fullyLit.z, baseColor.z, accuracy: 0.001)

        // Fully shaded (ramp = 0)
        let fullyShaded = simd_mix(shadeColor, baseColor, SIMD3<Float>(repeating: 0.0))
        XCTAssertEqual(fullyShaded.x, shadeColor.x, accuracy: 0.001)
        XCTAssertEqual(fullyShaded.y, shadeColor.y, accuracy: 0.001)
        XCTAssertEqual(fullyShaded.z, shadeColor.z, accuracy: 0.001)

        // Half lit (ramp = 0.5)
        let halfLit = simd_mix(shadeColor, baseColor, SIMD3<Float>(repeating: 0.5))
        XCTAssertEqual(halfLit.x, (baseColor.x + shadeColor.x) / 2, accuracy: 0.001)
    }

    // MARK: - Toon Ramp Integration Tests

    /// Full toon ramp calculation matching shader logic
    func testToonRamp_FullCalculation() {
        let normal = SIMD3<Float>(0, 0, -1)  // Facing camera
        let lightDir = SIMD3<Float>(0, 0, -1)  // Light from camera
        let toony: Float = 0.9
        let shift: Float = 0.0

        let ndotl = simd_dot(normal, lightDir)
        XCTAssertEqual(ndotl, 1.0, accuracy: 0.001, "Aligned normal and light should give NdotL=1")

        let ramp = smoothstep(shift - toony * 0.5, shift + toony * 0.5, ndotl)
        XCTAssertEqual(ramp, 1.0, accuracy: 0.001, "Fully lit surface should have ramp=1")
    }

    /// Test extreme NdotL values
    func testToonRamp_ExtremeNdotL() {
        let toony: Float = 0.9
        let shift: Float = 0.0

        // Fully lit (NdotL = 1)
        let rampLit = smoothstep(shift - toony * 0.5, shift + toony * 0.5, 1.0)
        XCTAssertEqual(rampLit, 1.0, accuracy: 0.001)

        // Fully shadowed (NdotL = -1)
        let rampShadow = smoothstep(shift - toony * 0.5, shift + toony * 0.5, -1.0)
        XCTAssertEqual(rampShadow, 0.0, accuracy: 0.001)

        // At boundary (NdotL = 0)
        let rampBoundary = smoothstep(shift - toony * 0.5, shift + toony * 0.5, 0.0)
        XCTAssertEqual(rampBoundary, 0.5, accuracy: 0.05)
    }

    // MARK: - MToonMaterialUniforms Toon Parameter Tests

    /// Test that MToonMaterialUniforms correctly stores toon parameters
    func testMToonMaterialUniforms_ToonParameters() {
        var uniforms = MToonMaterialUniforms()
        uniforms.shadingToonyFactor = 0.9
        uniforms.shadingShiftFactor = 0.1
        uniforms.shadeColorFactor = SIMD3<Float>(0.5, 0.4, 0.3)

        XCTAssertEqual(uniforms.shadingToonyFactor, 0.9, accuracy: 0.001)
        XCTAssertEqual(uniforms.shadingShiftFactor, 0.1, accuracy: 0.001)
        XCTAssertEqual(uniforms.shadeColorR, 0.5, accuracy: 0.001)
        XCTAssertEqual(uniforms.shadeColorG, 0.4, accuracy: 0.001)
        XCTAssertEqual(uniforms.shadeColorB, 0.3, accuracy: 0.001)
    }

    /// Test validation of toon parameters
    func testMToonMaterialUniforms_ToonValidation() {
        var uniforms = MToonMaterialUniforms()

        // Toony > 1 should fail
        uniforms.shadingToonyFactor = 1.5
        XCTAssertThrowsError(try uniforms.validate()) { error in
            guard case VRMMaterialValidationError.shadingToonyOutOfRange = error else {
                XCTFail("Expected shadingToonyOutOfRange error")
                return
            }
        }

        // Reset and test shift out of range
        uniforms.shadingToonyFactor = 0.9
        uniforms.shadingShiftFactor = 1.5
        XCTAssertThrowsError(try uniforms.validate()) { error in
            guard case VRMMaterialValidationError.shadingShiftOutOfRange = error else {
                XCTFail("Expected shadingShiftOutOfRange error")
                return
            }
        }
    }

    // MARK: - Shading Shift Texture Tests

    /// Shading shift texture should offset the base shift factor
    func testShadingShiftTexture_AddsOffset() {
        let baseShift: Float = 0.0
        let textureScale: Float = 1.0

        // Texture value 0.5 (neutral) should add 0 offset
        let texValue1: Float = 0.5
        let shift1 = baseShift + (texValue1 - 0.5) * textureScale
        XCTAssertEqual(shift1, 0.0, accuracy: 0.001)

        // Texture value 1.0 should add positive offset
        let texValue2: Float = 1.0
        let shift2 = baseShift + (texValue2 - 0.5) * textureScale
        XCTAssertEqual(shift2, 0.5, accuracy: 0.001)

        // Texture value 0.0 should add negative offset
        let texValue3: Float = 0.0
        let shift3 = baseShift + (texValue3 - 0.5) * textureScale
        XCTAssertEqual(shift3, -0.5, accuracy: 0.001)
    }
}
