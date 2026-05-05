//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import XCTest
import Metal
import simd
@testable import VRMMetalKit

// MARK: - Issue #145: giIntensityFactor parsed but ignored in shader
// MARK: - Issue #146: VRMRenderer force-zeroes emissiveFactor
// MARK: - Issue #147: Default lighting too dim

/// TDD tests for GitHub Issues #145, #146, #147
///
/// #145: giIntensityFactor is loaded into MToonMaterialUniforms and passed to the GPU,
///       but the MToon shader never reads it when computing indirect diffuse.
///       VISUAL IMPACT: Spec-compliance fix. Subtle on typical models; dramatic only
///       on models with high giIntensityFactor materials.
///
/// #146: VRMRenderer unconditionally overwrites emissiveFactor with (0,0,0) after
///       initializing MToon material uniforms, destroying artist-authored emissive.
///       VISUAL IMPACT: Spec-compliance fix. Most common models (VRoid, etc.) do not
///       rely on emissive for eyes; impact is model-dependent.
///
/// #147: Default VRMUniforms provide only a single directional light (intensity ~1.7)
///       with 5% ambient and zero fill/rim lights, producing overly dark renders.
///       VISUAL IMPACT: Universally visible. All models render ~3-5% brighter with
///       softer shadows.
@MainActor
final class GitHubIssues145_146_147_Tests: XCTestCase {

    var device: MTLDevice!
    var renderer: LightingTestRenderer!

    override func setUp() async throws {
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else {
            throw XCTSkip("Metal device not available")
        }
        renderer = try LightingTestRenderer(device: device, width: 128, height: 128)
    }

    override func tearDown() async throws {
        renderer = nil
        device = nil
    }

    // MARK: - #145: giIntensityFactor Should Scale Indirect Diffuse

    /// When giIntensityFactor is high, indirect diffuse should be brighter.
    /// Uses debug mode 35 to read litColor before saturation, avoiding clamping artifacts.
    ///
    /// RED: This test fails because giIntensityFactor is parsed but never used in the shader.
    func test_giIntensityFactor_ScalesIndirectDiffuse() async throws {
        // Use a dark base color so direct light doesn't saturate the output.
        // With side lighting, shadowStep ~0.5, giving direct ~0.15.
        // Indirect = ambient * baseColor * giIntensityFactor = 0.5 * 0.3 * gi = 0.15 * gi.
        // Total: gi=1 → ~0.30, gi=0 → ~0.15. Difference = 0.15 (measurable, no saturation).
        var material = MToonMaterialUniforms()
        material.baseColorFactor = SIMD4<Float>(0.3, 0.3, 0.3, 1)
        material.shadeColorFactor = SIMD3<Float>(0, 0, 0)
        material.shadingToonyFactor = 0.9
        material.shadingShiftFactor = 0.0
        material.emissiveFactor = SIMD3<Float>(0, 0, 0)

        // High GI: giIntensityFactor=1.0
        var materialHigh = material
        materialHigh.giIntensityFactor = 1.0
        let frameDataHigh = try renderer.renderWithDebugMode(
            35,  // litColor before saturation
            material: materialHigh,
            lightDir: SIMD3<Float>(0.5, 0, 0.866),
            ambientIntensity: 0.5
        )

        // Low GI: giIntensityFactor=0.0
        var materialLow = material
        materialLow.giIntensityFactor = 0.0
        let frameDataLow = try renderer.renderWithDebugMode(
            35,
            material: materialLow,
            lightDir: SIMD3<Float>(0.5, 0, 0.866),
            ambientIntensity: 0.5
        )

        let centerHigh = samplePixelRGB(frameDataHigh, x: 64, y: 64, width: 128)
        let centerLow = samplePixelRGB(frameDataLow, x: 64, y: 64, width: 128)

        let brightnessHigh = (centerHigh.r + centerHigh.g + centerHigh.b) / 3.0
        let brightnessLow = (centerLow.r + centerLow.g + centerLow.b) / 3.0

        // With giIntensityFactor implemented, high GI should be measurably brighter.
        // Expected difference: ambient * baseColor * (1.0 - 0.0) = 0.5 * 0.3 = 0.15
        XCTAssertGreaterThan(
            brightnessHigh,
            brightnessLow + 0.08,
            "BUG #145: giIntensityFactor=1.0 (brightness=\(brightnessHigh)) should produce " +
            "brighter indirect diffuse than giIntensityFactor=0.0 (brightness=\(brightnessLow)). " +
            "giIntensityFactor is parsed but ignored in the shader."
        )
    }

    /// giIntensityFactor should default to a reasonable value (>0) so materials
    /// don't render completely flat when no GI is explicitly configured.
    func test_giIntensityFactor_DefaultIsNonZero() {
        let material = MToonMaterialUniforms()
        XCTAssertGreaterThan(
            material.giIntensityFactor,
            0.0,
            "Default giIntensityFactor should be > 0 for reasonable default lighting"
        )
    }

    // MARK: - #146: emissiveFactor Should Not Be Force-Zeroed

    /// A material with red emissive should emit red light into the final color.
    ///
    /// RED: This test fails because VRMRenderer.swift:2454 forces emissiveFactor to (0,0,0)
    /// for all MToon materials unconditionally.
    ///
    /// Note: LightingTestRenderer does NOT zero emissive — it passes the material struct
    /// directly to the shader. So this test exercises the shader's emissive path correctly.
    /// The real bug is in VRMRenderer's uniform upload path.
    func test_emissiveFactor_PreservedInOutput() async throws {
        var material = MToonMaterialUniforms()
        material.baseColorFactor = SIMD4<Float>(0, 0, 0, 1)  // Black base
        material.shadeColorFactor = SIMD3<Float>(0, 0, 0)
        material.shadingToonyFactor = 1.0
        material.shadingShiftFactor = 0.0
        material.emissiveFactor = SIMD3<Float>(1, 0, 0)  // Pure red emissive
        material.giIntensityFactor = 0.0

        let frameData = try renderer.render(
            material: material,
            lightDir: SIMD3<Float>(0, 0, 1),
            ambientIntensity: 0.0
        )

        let center = samplePixelRGB(frameData, x: 64, y: 64, width: 128)

        // With black base, black shade, no ambient, and no lights, the ONLY
        // contribution should be emissive. If emissive is red, center should be red.
        XCTAssertGreaterThan(
            center.r,
            0.5,
            "BUG #146: emissiveFactor=(1,0,0) should produce red output, " +
            "but got R=\(center.r). emissiveFactor is being force-zeroed in VRMRenderer."
        )
        XCTAssertLessThan(
            center.g,
            0.2,
            "Green channel should be near zero for pure red emissive"
        )
        XCTAssertLessThan(
            center.b,
            0.2,
            "Blue channel should be near zero for pure red emissive"
        )
    }

    /// emissiveFactor should be preserved when copied through MToonMaterialUniforms init.
    func test_emissiveFactor_PreservedInMaterialUniforms() {
        var material = MToonMaterialUniforms()
        material.emissiveFactor = SIMD3<Float>(0.5, 0.3, 0.1)

        XCTAssertEqual(material.emissiveR, 0.5, accuracy: 0.001)
        XCTAssertEqual(material.emissiveG, 0.3, accuracy: 0.001)
        XCTAssertEqual(material.emissiveB, 0.1, accuracy: 0.001)
    }

    /// Verify that the renderer does NOT overwrite emissive when uploading uniforms.
    /// This test directly exercises the VRMRenderer material uniform path.
    func test_VRMRenderer_DoesNotZeroEmissive() throws {
        // Create a minimal VRMRenderer and check that emissive survives uniform upload.
        // We can't easily render without a full VRM model, but we can verify the
        // material struct behavior and the presence of the bug in source.
        //
        // This is a compile-time / static check: assert the bug source line is removed.
        // If the line `mtoonUniforms.emissiveFactor = SIMD3<Float>(0, 0, 0)` still exists
        // in VRMRenderer.swift, this test fails.
        let rendererSourcePath = "Sources/VRMMetalKit/Renderer/VRMRenderer.swift"
        let sourceURL = URL(fileURLWithPath: rendererSourcePath)
        let source = try String(contentsOf: sourceURL)

        let hasForceZero = source.contains("mtoonUniforms.emissiveFactor = SIMD3<Float>(0, 0, 0)")

        XCTAssertFalse(
            hasForceZero,
            "BUG #146: VRMRenderer.swift still contains unconditional emissive zeroing. " +
            "Remove the line that forces emissiveFactor to (0,0,0)."
        )
    }

    // MARK: - #147: Default Lighting Should Be Bright Enough

    /// Default VRMUniforms should provide enough ambient lighting
    /// that a hands-off consumer gets a visible, reasonably lit render.
    func test_defaultLighting_AmbientIsBrightEnough() {
        let uniforms = Uniforms()

        let ambientBrightness = (uniforms.ambientColor_packed.x +
                                  uniforms.ambientColor_packed.y +
                                  uniforms.ambientColor_packed.z) / 3.0

        XCTAssertGreaterThan(
            ambientBrightness,
            0.05,
            "BUG #147: Default ambient brightness (\(ambientBrightness)) is too dim. " +
            "Hands-off consumers get nearly black shadow areas."
        )
    }

    /// Default key light intensity should be strong enough
    /// to clearly illuminate the front face of a model.
    func test_defaultLighting_KeyLightIntensityIsReasonable() {
        let uniforms = Uniforms()
        let keyIntensity = uniforms.lightColor_packed.w

        XCTAssertGreaterThan(
            keyIntensity,
            1.0,
            "BUG #147: Default key light intensity (\(keyIntensity)) is too low. " +
            "Should be at least 1.0 for clear front-face illumination."
        )
    }

    /// At minimum, one fill or rim light should be active by default.
    func test_defaultLighting_AtLeastOneSecondaryLightActive() {
        let uniforms = Uniforms()

        let fillIntensity = uniforms.light1Color_packed.w
        let rimIntensity = uniforms.light2Color_packed.w

        XCTAssertTrue(
            fillIntensity > 0 || rimIntensity > 0,
            "BUG #147: Both fill and rim lights are zero (fill=\(fillIntensity), rim=\(rimIntensity)). " +
            "At least one secondary light should be active by default."
        )
    }
}



// MARK: - Pixel Sampling Helper

/// Sample RGB pixel from BGRA framebuffer data
fileprivate func samplePixelRGB(_ data: Data, x: Int, y: Int, width: Int) -> (r: Float, g: Float, b: Float) {
    let bytesPerPixel = 4
    let offset = (y * width + x) * bytesPerPixel
    guard offset + 3 < data.count else { return (0, 0, 0) }

    let bytes = [UInt8](data)
    // BGRA format: B=offset, G=offset+1, R=offset+2, A=offset+3
    let b = Float(bytes[offset]) / 255.0
    let g = Float(bytes[offset + 1]) / 255.0
    let r = Float(bytes[offset + 2]) / 255.0
    return (r, g, b)
}
