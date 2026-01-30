// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import simd
@testable import VRMMetalKit

/// Unit tests for MToon rim lighting (Fresnel) calculations
/// Based on MToon 1.0 spec: https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_materials_mtoon-1.0/README.md
final class RimLightingTests: XCTestCase {

    // MARK: - Fresnel Rim Calculation Tests

    /// Fresnel rim at grazing angle (view perpendicular to normal) should be maximum
    func testFresnelRimCalculation_GrazingAngle_ReturnsMaximumRim() {
        // Normal pointing right, view direction from camera looking down -Z
        let normal = SIMD3<Float>(1, 0, 0)  // Right
        let viewDir = SIMD3<Float>(0, 0, -1)  // Looking into screen

        let NdotV = simd_dot(normal, viewDir)
        XCTAssertEqual(NdotV, 0.0, accuracy: 0.001, "NdotV should be 0 at grazing angle")

        let vf = 1.0 - max(0, NdotV)  // Fresnel factor
        XCTAssertEqual(vf, 1.0, accuracy: 0.001, "Fresnel factor should be 1.0 at grazing angle")
    }

    /// Fresnel rim when viewing head-on (view aligned with normal) should be zero
    func testFresnelRimCalculation_HeadOnView_ReturnsZeroRim() {
        // Normal pointing toward camera, view from camera
        let normal = SIMD3<Float>(0, 0, -1)  // Toward camera
        let viewDir = SIMD3<Float>(0, 0, -1)  // Camera looking into screen

        let NdotV = simd_dot(normal, viewDir)
        XCTAssertEqual(NdotV, 1.0, accuracy: 0.001, "NdotV should be 1.0 when viewing head-on")

        let vf = 1.0 - max(0, NdotV)
        XCTAssertEqual(vf, 0.0, accuracy: 0.001, "Fresnel factor should be 0.0 when viewing head-on")
    }

    /// Power factor controls the falloff sharpness of the rim effect
    func testFresnelPowerFactor_ControlsFalloff() {
        let vf: Float = 0.5  // 45-degree angle gives 0.707, 1-0.707 ≈ 0.293

        // Lower power = broader rim
        let rimLowPower = pow(vf, 1.0)
        XCTAssertEqual(rimLowPower, 0.5, accuracy: 0.001)

        // Higher power = sharper rim
        let rimHighPower = pow(vf, 5.0)
        XCTAssertEqual(rimHighPower, 0.03125, accuracy: 0.001)

        XCTAssertGreaterThan(rimLowPower, rimHighPower, "Higher power should produce smaller rim values")
    }

    /// Lift factor adds a constant offset to the rim effect
    func testRimLiftFactor_AddsConstantOffset() {
        let vf: Float = 0.3
        let power: Float = 5.0
        let lift: Float = 0.2

        let rimWithoutLift = pow(vf, power)
        let rimWithLift = min(1.0, rimWithoutLift + lift)

        XCTAssertGreaterThan(rimWithLift, rimWithoutLift, "Lift should increase rim value")
        XCTAssertEqual(rimWithLift, rimWithoutLift + lift, accuracy: 0.001)
    }

    /// Rim lighting should be additive to final color per MToon spec
    func testRimApplication_IsAdditive() {
        let baseColor = SIMD3<Float>(0.5, 0.5, 0.5)
        let rimColor = SIMD3<Float>(0.2, 0.1, 0.0)

        let finalColor = baseColor + rimColor
        XCTAssertEqual(finalColor.x, 0.7, accuracy: 0.001)
        XCTAssertEqual(finalColor.y, 0.6, accuracy: 0.001)
        XCTAssertEqual(finalColor.z, 0.5, accuracy: 0.001)
    }

    // MARK: - Rim Lighting Mix Tests

    /// Mix factor of 0 should use fully lit rim (rim affected by light)
    func testRimLightingMix_FullyLit() {
        let rimColor = SIMD3<Float>(1.0, 0.5, 0.0)
        let lightColor = SIMD3<Float>(0.8, 0.8, 0.8)
        let mixFactor: Float = 0.0

        let rimLit = rimColor * lightColor
        let rimUnlit = rimColor
        let finalRim = simd_mix(rimLit, rimUnlit, SIMD3<Float>(repeating: mixFactor))

        XCTAssertEqual(finalRim.x, rimLit.x, accuracy: 0.001, "Mix 0 should return lit rim")
        XCTAssertEqual(finalRim.y, rimLit.y, accuracy: 0.001)
    }

    /// Mix factor of 1 should use fully unlit rim (emissive-like)
    func testRimLightingMix_FullyUnlit() {
        let rimColor = SIMD3<Float>(1.0, 0.5, 0.0)
        let lightColor = SIMD3<Float>(0.8, 0.8, 0.8)
        let mixFactor: Float = 1.0

        let rimLit = rimColor * lightColor
        let rimUnlit = rimColor
        let finalRim = simd_mix(rimLit, rimUnlit, SIMD3<Float>(repeating: mixFactor))

        XCTAssertEqual(finalRim.x, rimUnlit.x, accuracy: 0.001, "Mix 1 should return unlit rim")
        XCTAssertEqual(finalRim.y, rimUnlit.y, accuracy: 0.001)
    }

    /// Rim multiply texture should mask the rim effect
    func testRimMultiplyTexture_MasksEffect() {
        let rimColor = SIMD3<Float>(1.0, 0.5, 0.0)
        let rimMask: Float = 0.5

        let maskedRim = rimColor * rimMask
        XCTAssertEqual(maskedRim.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(maskedRim.y, 0.25, accuracy: 0.001)
        XCTAssertEqual(maskedRim.z, 0.0, accuracy: 0.001)
    }

    // MARK: - MToonMaterialUniforms Rim Parameter Tests

    /// Test that MToonMaterialUniforms correctly stores rim parameters
    func testMToonMaterialUniforms_RimParameters() {
        var uniforms = MToonMaterialUniforms()
        uniforms.parametricRimColorFactor = SIMD3<Float>(1.0, 0.5, 0.25)
        uniforms.parametricRimFresnelPowerFactor = 5.0
        uniforms.parametricRimLiftFactor = 0.1
        uniforms.rimLightingMixFactor = 0.5

        XCTAssertEqual(uniforms.rimColorR, 1.0, accuracy: 0.001)
        XCTAssertEqual(uniforms.rimColorG, 0.5, accuracy: 0.001)
        XCTAssertEqual(uniforms.rimColorB, 0.25, accuracy: 0.001)
        XCTAssertEqual(uniforms.parametricRimFresnelPowerFactor, 5.0, accuracy: 0.001)
        XCTAssertEqual(uniforms.parametricRimLiftFactor, 0.1, accuracy: 0.001)
        XCTAssertEqual(uniforms.rimLightingMixFactor, 0.5, accuracy: 0.001)
    }

    /// Test validation rejects invalid rim parameters
    func testMToonMaterialUniforms_RimValidation() {
        var uniforms = MToonMaterialUniforms()

        // Negative fresnel power should fail
        uniforms.parametricRimFresnelPowerFactor = -1.0
        XCTAssertThrowsError(try uniforms.validate()) { error in
            guard case VRMMaterialValidationError.rimFresnelPowerNegative = error else {
                XCTFail("Expected rimFresnelPowerNegative error")
                return
            }
        }

        // Reset to valid and test rim lighting mix out of range
        uniforms.parametricRimFresnelPowerFactor = 1.0
        uniforms.rimLightingMixFactor = 1.5
        XCTAssertThrowsError(try uniforms.validate()) { error in
            guard case VRMMaterialValidationError.rimLightingMixOutOfRange = error else {
                XCTFail("Expected rimLightingMixOutOfRange error")
                return
            }
        }
    }
}
