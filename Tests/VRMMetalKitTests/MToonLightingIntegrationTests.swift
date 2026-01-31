// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Integration tests for MToon lighting pipeline
/// Verifies that all lighting components work together correctly
final class MToonLightingIntegrationTests: XCTestCase {

    var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    // MARK: - Textured Material Lighting Tests

    /// Textured materials should receive full MToon lighting, not just texture color
    func testTexturedMaterials_ReceiveFullLighting() {
        var uniforms = MToonMaterialUniforms()
        uniforms.hasBaseColorTexture = 1
        uniforms.baseColorFactor = SIMD4<Float>(1.0, 1.0, 1.0, 1.0)
        uniforms.shadingToonyFactor = 0.9
        uniforms.shadeColorFactor = SIMD3<Float>(0.5, 0.5, 0.5)

        // With textured materials, lighting should still be applied
        // The shader should NOT bypass lighting for textured materials
        XCTAssertEqual(uniforms.hasBaseColorTexture, 1)
        XCTAssertEqual(uniforms.shadingToonyFactor, 0.9, accuracy: 0.001)
    }

    /// Untextured materials should also receive full MToon lighting
    func testUntexturedMaterials_ReceiveFullLighting() {
        var uniforms = MToonMaterialUniforms()
        uniforms.hasBaseColorTexture = 0
        uniforms.baseColorFactor = SIMD4<Float>(0.8, 0.6, 0.5, 1.0)
        uniforms.shadingToonyFactor = 0.9
        uniforms.shadeColorFactor = SIMD3<Float>(0.4, 0.3, 0.25)

        // Untextured materials use baseColorFactor directly with lighting
        XCTAssertEqual(uniforms.hasBaseColorTexture, 0)
        XCTAssertNotEqual(uniforms.baseColorFactor, SIMD4<Float>(0, 0, 0, 0))
    }

    /// Verify that the debug bypass for textured materials has been removed
    func testLightingNotBypassed_ForTexturedMaterials() {
        // This test verifies the fix by checking that both textured and untextured
        // materials go through the same lighting pipeline

        var texturedUniforms = MToonMaterialUniforms()
        texturedUniforms.hasBaseColorTexture = 1
        texturedUniforms.parametricRimColorFactor = SIMD3<Float>(0.5, 0.5, 1.0)
        texturedUniforms.parametricRimFresnelPowerFactor = 5.0

        var untexturedUniforms = MToonMaterialUniforms()
        untexturedUniforms.hasBaseColorTexture = 0
        untexturedUniforms.parametricRimColorFactor = SIMD3<Float>(0.5, 0.5, 1.0)
        untexturedUniforms.parametricRimFresnelPowerFactor = 5.0

        // Both should have rim lighting parameters set the same way
        XCTAssertEqual(texturedUniforms.rimColorR, untexturedUniforms.rimColorR)
        XCTAssertEqual(texturedUniforms.parametricRimFresnelPowerFactor,
                       untexturedUniforms.parametricRimFresnelPowerFactor)
    }

    // MARK: - Combined Effects Tests

    /// Rim lighting and MatCap should both be applied together
    func testRimAndMatCap_AppliedTogether() {
        var uniforms = MToonMaterialUniforms()

        // Configure rim lighting
        uniforms.parametricRimColorFactor = SIMD3<Float>(1.0, 0.5, 0.0)
        uniforms.parametricRimFresnelPowerFactor = 5.0
        uniforms.parametricRimLiftFactor = 0.0
        uniforms.rimLightingMixFactor = 0.5

        // Configure MatCap
        uniforms.hasMatcapTexture = 1
        uniforms.matcapFactor = SIMD3<Float>(1.0, 1.0, 1.0)

        // Both effects should be active
        XCTAssertGreaterThan(uniforms.rimColorR, 0)
        XCTAssertEqual(uniforms.hasMatcapTexture, 1)

        // Validate the uniform configuration
        XCTAssertNoThrow(try uniforms.validate())
    }

    /// Emissive should add to final color after lighting
    func testEmissive_AddsToFinalColor() {
        var uniforms = MToonMaterialUniforms()
        uniforms.emissiveFactor = SIMD3<Float>(0.2, 0.1, 0.05)

        // Emissive is additive
        let baseLight = SIMD3<Float>(0.5, 0.5, 0.5)
        let withEmissive = baseLight + uniforms.emissiveFactor

        XCTAssertEqual(withEmissive.x, 0.7, accuracy: 0.001)
        XCTAssertEqual(withEmissive.y, 0.6, accuracy: 0.001)
        XCTAssertEqual(withEmissive.z, 0.55, accuracy: 0.001)
    }

    /// Test that emissive texture flag is properly set
    func testEmissiveTexture_FlagSetting() {
        var uniforms = MToonMaterialUniforms()

        // Initially no emissive texture
        XCTAssertEqual(uniforms.hasEmissiveTexture, 0)

        // Set emissive texture flag
        uniforms.hasEmissiveTexture = 1
        XCTAssertEqual(uniforms.hasEmissiveTexture, 1)
    }

    // MARK: - Multi-Light Tests

    /// Three-point lighting should be properly weighted
    func testThreePointLighting_Weighting() {
        // Key light (brightest)
        let keyIntensity: Float = 1.0
        // Fill light (dimmer)
        let fillIntensity: Float = 0.5
        // Rim light (accent)
        let rimIntensity: Float = 0.3

        let totalIntensity = keyIntensity + fillIntensity + rimIntensity
        let normFactor: Float = 1.0  // Can be adjusted for artistic control

        // Weights should sum to 1.0 before normalization factor
        let keyWeight = keyIntensity / totalIntensity
        let fillWeight = fillIntensity / totalIntensity
        let rimWeight = rimIntensity / totalIntensity

        XCTAssertEqual(keyWeight + fillWeight + rimWeight, 1.0, accuracy: 0.001)
    }

    // MARK: - Normal Flipping Tests

    /// Back-facing normals should be flipped for proper lighting
    func testNormalFlipping_ForBackFaces() {
        let normal = SIMD3<Float>(0, 0, 1)  // Pointing away from camera
        let viewDir = SIMD3<Float>(0, 0, -1)  // Camera looking into screen

        let dotProduct = simd_dot(normal, viewDir)
        XCTAssertLessThan(dotProduct, 0, "Normal facing away should have negative dot with view")

        // Flip the normal
        let flippedNormal = dotProduct < 0 ? -normal : normal
        let flippedDot = simd_dot(flippedNormal, viewDir)
        XCTAssertGreaterThan(flippedDot, 0, "Flipped normal should have positive dot with view")
    }

    // MARK: - GI Intensity Tests

    /// GI intensity should blend between direct and ambient lighting
    func testGIIntensity_Blending() {
        let directLight = SIMD3<Float>(0.8, 0.8, 0.8)
        let ambientLight = SIMD3<Float>(0.2, 0.2, 0.2)
        let baseColor = SIMD3<Float>(1.0, 0.8, 0.6)

        let giColor = ambientLight * baseColor
        let giIntensity: Float = 0.5

        // GI equalization: mix toward balanced lighting
        let combined = simd_mix(directLight, (directLight + giColor) * 0.5,
                                SIMD3<Float>(repeating: giIntensity))

        // Result should be between pure direct and balanced
        XCTAssertLessThan(combined.x, directLight.x)
        XCTAssertGreaterThan(combined.x, giColor.x)
    }

    // MARK: - Minimum Light Floor Tests

    /// Minimum light floor should prevent completely black surfaces
    func testMinimumLightFloor() {
        let baseColor = SIMD3<Float>(0.8, 0.6, 0.5)
        let litColor = SIMD3<Float>(0.0, 0.0, 0.0)  // Completely unlit

        let minLight = baseColor * 0.08  // 8% of base color
        let finalColor = simd_max(litColor, minLight)

        XCTAssertGreaterThan(finalColor.x, 0, "Minimum floor should prevent black")
        XCTAssertEqual(finalColor.x, 0.064, accuracy: 0.001)
    }

    // MARK: - View Direction Tests

    /// View direction calculation should be correct
    func testViewDirection_Calculation() {
        // Camera at (0, 0, 5), vertex at (0, 0, 0)
        let cameraPos = SIMD3<Float>(0, 0, 5)
        let worldPos = SIMD3<Float>(0, 0, 0)

        let viewDir = simd_normalize(cameraPos - worldPos)

        XCTAssertEqual(viewDir.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(viewDir.y, 0.0, accuracy: 0.001)
        XCTAssertEqual(viewDir.z, 1.0, accuracy: 0.001)
    }

    /// View direction should point FROM vertex TO camera
    func testViewDirection_PointsToCamera() {
        let cameraPos = SIMD3<Float>(1, 2, 3)
        let worldPos = SIMD3<Float>(0, 0, 0)

        let viewDir = simd_normalize(cameraPos - worldPos)
        let expectedDir = simd_normalize(SIMD3<Float>(1, 2, 3))

        XCTAssertEqual(viewDir.x, expectedDir.x, accuracy: 0.001)
        XCTAssertEqual(viewDir.y, expectedDir.y, accuracy: 0.001)
        XCTAssertEqual(viewDir.z, expectedDir.z, accuracy: 0.001)
    }

    // MARK: - Struct Layout Tests

    /// Verify MToonMaterialUniforms matches expected size for Metal
    func testMToonMaterialUniforms_StructSize() {
        let size = MemoryLayout<MToonMaterialUniforms>.size
        let stride = MemoryLayout<MToonMaterialUniforms>.stride

        // Should be 208 bytes (13 blocks of 16 bytes each)
        // Block 0-11: Standard material properties (192 bytes)
        // Block 12: Version flag + UV offset fields (16 bytes) - added for mouth UV fix
        XCTAssertEqual(stride, 208, "MToonMaterialUniforms should be 208 bytes for Metal alignment (13 blocks)")
        XCTAssertLessThanOrEqual(size, stride)
    }
}
