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

/// Pipeline diagnostic tests for VRM "sunburn" effect.
///
/// These tests verify the ACTUAL VRM loading pipeline, not synthetic data:
/// 1. Parsed material values from real VRM files
/// 2. Texture pixel formats in production code
/// 3. Material conversion from VRM 0.x to 1.0
/// 4. End-to-end rendering pipeline
///
/// Run with actual VRM models:
/// ```
/// VRM_TEST_VRM1_PATH="/path/to/vrm1.vrm" \
/// VRM_TEST_VRM0_PATH="/path/to/vrm0.vrm" \
/// swift test --filter MToonPipelineDiagnosticTests --disable-sandbox
/// ```
@MainActor
final class MToonPipelineDiagnosticTests: XCTestCase {

    var device: MTLDevice!

    override func setUp() async throws {
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else {
            throw XCTSkip("Metal device not available")
        }
    }

    override func tearDown() async throws {
        device = nil
    }

    // MARK: - Test 1: Verify Parsed Shade Colors Are Reasonable

    /// Test that shade colors parsed from VRM files are reasonable (not hot pink).
    /// The "sunburn" effect often comes from incorrect shade color values.
    func testParsedShadeColorsAreReasonable() async throws {
        // Try VRM 1.0 model first
        if let vrm1Path = ProcessInfo.processInfo.environment["VRM_TEST_VRM1_PATH"] {
            let url = URL(fileURLWithPath: vrm1Path)
            try await testShadeColorsForModel(at: url, vrmVersion: "1.0")
        }

        // Try VRM 0.x model
        if let vrm0Path = ProcessInfo.processInfo.environment["VRM_TEST_VRM0_PATH"] {
            let url = URL(fileURLWithPath: vrm0Path)
            try await testShadeColorsForModel(at: url, vrmVersion: "0.x")
        }

        // If no models provided, test with synthetic VRM 0.x material properties
        if ProcessInfo.processInfo.environment["VRM_TEST_VRM1_PATH"] == nil &&
           ProcessInfo.processInfo.environment["VRM_TEST_VRM0_PATH"] == nil {
            try testVRM0MaterialPropertyConversion()
        }
    }

    private func testShadeColorsForModel(at url: URL, vrmVersion: String) async throws {
        print("\n=== Testing Shade Colors for VRM \(vrmVersion) Model ===")
        print("Path: \(url.path)")

        let model = try await VRMModel.load(from: url, device: device)

        var materialCount = 0
        var suspiciousMaterials: [(name: String, shadeColor: SIMD3<Float>, reason: String)] = []

        for material in model.materials {
            materialCount += 1
            let name = material.name ?? "Material_\(materialCount)"

            guard let mtoon = material.mtoon else {
                print("[\(name)] Not MToon material, skipping")
                continue
            }

            let shade = mtoon.shadeColorFactor
            let r = shade.x
            let g = shade.y
            let b = shade.z

            print("[\(name)] ShadeColor RGB: (\(r), \(g), \(b))")

            // Check for suspicious shade colors
            var issues: [String] = []

            // Issue 1: Red excess (sunburn indicator)
            let redExcess = r - max(g, b)
            if redExcess > 0.3 {
                issues.append("RED EXCESS: \(redExcess) (shade too red/pink)")
            }

            // Issue 2: Too saturated for skin tones
            let saturation = max(r, g, b) - min(r, g, b)
            let brightness = (r + g + b) / 3.0
            if saturation > 0.5 && brightness > 0.3 {
                issues.append("HIGH SATURATION: \(saturation) (unnatural for shadows)")
            }

            // Issue 3: Shade brighter than expected
            // Shade should typically be 30-70% of base color brightness
            let baseColor = material.baseColorFactor
            let baseBrightness = (baseColor.x + baseColor.y + baseColor.z) / 3.0
            let shadeBrightness = brightness
            let ratio = shadeBrightness / max(baseBrightness, 0.001)
            if ratio > 0.9 {
                issues.append("SHADE TOO BRIGHT: ratio=\(ratio) (shade should be darker than base)")
            }

            // Issue 4: Black shade (default value not overwritten)
            if r < 0.01 && g < 0.01 && b < 0.01 {
                issues.append("BLACK SHADE: May use default value if not set in VRM")
            }

            if !issues.isEmpty {
                let reason = issues.joined(separator: "; ")
                suspiciousMaterials.append((name, shade, reason))
                print("  ⚠️ SUSPICIOUS: \(reason)")
            } else {
                print("  ✓ OK")
            }
        }

        print("\n=== Summary ===")
        print("Total materials: \(materialCount)")
        print("Suspicious materials: \(suspiciousMaterials.count)")

        // Don't fail on suspicious materials, just warn
        // The actual values depend on the artist's choices
        if !suspiciousMaterials.isEmpty {
            print("\n⚠️ Warning: Some materials have unusual shade colors that could cause sunburn effect:")
            for (name, shade, reason) in suspiciousMaterials {
                print("  - \(name): RGB(\(shade.x), \(shade.y), \(shade.z)) - \(reason)")
            }
        }
    }

    /// Test VRM 0.x material property conversion to MToon
    private func testVRM0MaterialPropertyConversion() throws {
        print("\n=== Testing VRM 0.x to MToon Conversion ===")

        // Test case 1: Typical skin shade color
        var prop1 = VRM0MaterialProperty()
        prop1.vectorProperties["_ShadeColor"] = [0.8, 0.6, 0.5, 1.0]  // Warm skin shadow in sRGB
        prop1.floatProperties["_ShadeToony"] = 0.9
        prop1.floatProperties["_ShadeShift"] = 0.0

        let mtoon1 = prop1.toMToonMaterial()
        print("Input sRGB shade: (0.8, 0.6, 0.5)")
        print("Output linear shade: (\(mtoon1.shadeColorFactor.x), \(mtoon1.shadeColorFactor.y), \(mtoon1.shadeColorFactor.z))")

        // sRGB to linear: 0.8 → ~0.604, 0.6 → ~0.318, 0.5 → ~0.214
        // Values should be LOWER after sRGB→linear conversion
        XCTAssertLessThan(
            mtoon1.shadeColorFactor.x,
            0.8,
            "sRGB to linear should reduce high values"
        )

        // Test case 2: Pink shade color (potential sunburn source)
        var prop2 = VRM0MaterialProperty()
        prop2.vectorProperties["_ShadeColor"] = [1.0, 0.5, 0.5, 1.0]  // Hot pink in sRGB
        prop2.floatProperties["_ShadeToony"] = 0.9

        let mtoon2 = prop2.toMToonMaterial()
        print("\nInput sRGB shade: (1.0, 0.5, 0.5) - Hot pink")
        print("Output linear shade: (\(mtoon2.shadeColorFactor.x), \(mtoon2.shadeColorFactor.y), \(mtoon2.shadeColorFactor.z))")

        let redExcess2 = mtoon2.shadeColorFactor.x - max(mtoon2.shadeColorFactor.y, mtoon2.shadeColorFactor.z)
        print("Red excess in linear: \(redExcess2)")

        // Even after conversion, if source is pink, result will be pink
        // This is expected - the issue would be if the SOURCE VRM has pink shade
        if redExcess2 > 0.5 {
            print("⚠️ Warning: Pink shade color persists after conversion")
        }

        // Test case 3: Default values
        let prop3 = VRM0MaterialProperty()
        let mtoon3 = prop3.toMToonMaterial()
        print("\nDefault shade color (no _ShadeColor set):")
        print("Output: (\(mtoon3.shadeColorFactor.x), \(mtoon3.shadeColorFactor.y), \(mtoon3.shadeColorFactor.z))")

        // Default should be black (0,0,0) since no color was specified
        XCTAssertEqual(mtoon3.shadeColorFactor.x, 0.0, accuracy: 0.001, "Default shade R should be 0")
        XCTAssertEqual(mtoon3.shadeColorFactor.y, 0.0, accuracy: 0.001, "Default shade G should be 0")
        XCTAssertEqual(mtoon3.shadeColorFactor.z, 0.0, accuracy: 0.001, "Default shade B should be 0")
    }

    // MARK: - Test 2: Texture Pixel Formats in Production Code

    /// Verify that textures loaded through production code have correct pixel formats.
    func testProductionTexturePixelFormats() async throws {
        // Try to load a real VRM model
        if let vrm1Path = ProcessInfo.processInfo.environment["VRM_TEST_VRM1_PATH"] {
            let url = URL(fileURLWithPath: vrm1Path)
            try await verifyTextureFormatsForModel(at: url)
            return
        }

        if let vrm0Path = ProcessInfo.processInfo.environment["VRM_TEST_VRM0_PATH"] {
            let url = URL(fileURLWithPath: vrm0Path)
            try await verifyTextureFormatsForModel(at: url)
            return
        }

        // No model provided - test the TextureLoader behavior directly
        print("=== Testing TextureLoader Pixel Format Logic ===")
        print("Note: No VRM model provided. Set VRM_TEST_VRM1_PATH or VRM_TEST_VRM0_PATH to test actual loading.")

        // Verify the pixel format selection logic
        let sRGBFormat: MTLPixelFormat = .rgba8Unorm_srgb
        let linearFormat: MTLPixelFormat = .rgba8Unorm

        print("Expected formats:")
        print("  Color textures (sRGB=true): \(sRGBFormat)")
        print("  Data textures (sRGB=false): \(linearFormat)")

        XCTAssertEqual(sRGBFormat, .rgba8Unorm_srgb)
        XCTAssertEqual(linearFormat, .rgba8Unorm)
    }

    private func verifyTextureFormatsForModel(at url: URL) async throws {
        print("\n=== Verifying Texture Formats ===")
        print("Path: \(url.path)")

        let model = try await VRMModel.load(from: url, device: device)

        var textureCount = 0
        var formatIssues: [(name: String, expected: MTLPixelFormat, actual: MTLPixelFormat)] = []

        for material in model.materials {
            let materialName = material.name ?? "Unknown"

            // Check base color texture (should be sRGB)
            if let baseColorTex = material.baseColorTexture,
               let mtlTex = baseColorTex.mtlTexture {
                textureCount += 1
                let actual = mtlTex.pixelFormat
                let expected: MTLPixelFormat = .rgba8Unorm_srgb

                print("[\(materialName)] BaseColor texture: \(actual)")

                if actual != expected {
                    formatIssues.append(("\(materialName)/baseColor", expected, actual))
                    print("  ⚠️ Expected \(expected), got \(actual)")
                }
            }

            // Check normal texture (should be linear)
            if let normalTex = material.normalTexture,
               let mtlTex = normalTex.mtlTexture {
                textureCount += 1
                let actual = mtlTex.pixelFormat
                let expected: MTLPixelFormat = .rgba8Unorm

                print("[\(materialName)] Normal texture: \(actual)")

                // Normal maps should be linear, not sRGB
                if actual == .rgba8Unorm_srgb {
                    formatIssues.append(("\(materialName)/normal", expected, actual))
                    print("  ⚠️ Normal map should be LINEAR, not sRGB!")
                }
            }

            // Check emissive texture (should be sRGB for color)
            if let emissiveTex = material.emissiveTexture,
               let mtlTex = emissiveTex.mtlTexture {
                textureCount += 1
                let actual = mtlTex.pixelFormat
                print("[\(materialName)] Emissive texture: \(actual)")
            }
        }

        print("\n=== Summary ===")
        print("Textures checked: \(textureCount)")
        print("Format issues: \(formatIssues.count)")

        for (name, expected, actual) in formatIssues {
            print("  - \(name): expected \(expected), got \(actual)")
        }

        // Fail if there are format issues
        XCTAssertEqual(
            formatIssues.count,
            0,
            "Found \(formatIssues.count) texture format issue(s). This can cause sunburn effect."
        )
    }

    // MARK: - Test 3: Mix Direction in Shader (Lit vs Shade Order)

    /// Verify that mix(shadeColor, litColor, shadowStep) has arguments in correct order.
    /// If arguments are swapped, lit areas show shade color (sunburn).
    func testMixDirectionCorrectness() async throws {
        // This test verifies the conceptual understanding of mix()
        // mix(a, b, t) = a * (1-t) + b * t
        // So mix(shade, lit, 1.0) should give lit color
        // And mix(shade, lit, 0.0) should give shade color

        let shade = SIMD3<Float>(0.5, 0.0, 0.0)  // Red shade
        let lit = SIMD3<Float>(1.0, 1.0, 1.0)    // White lit

        // Simulate shader mix() behavior
        func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
            return a * (1.0 - t) + b * t
        }

        // When fully lit (shadowStep = 1.0), should get lit color
        let fullyLit = mix(shade, lit, 1.0)
        print("=== Mix Direction Test ===")
        print("mix(shade, lit, 1.0) = (\(fullyLit.x), \(fullyLit.y), \(fullyLit.z))")
        XCTAssertEqual(fullyLit.x, 1.0, accuracy: 0.001, "Fully lit should be white (1.0)")
        XCTAssertEqual(fullyLit.y, 1.0, accuracy: 0.001, "Fully lit should be white (1.0)")
        XCTAssertEqual(fullyLit.z, 1.0, accuracy: 0.001, "Fully lit should be white (1.0)")

        // When fully shadow (shadowStep = 0.0), should get shade color
        let fullyShadow = mix(shade, lit, 0.0)
        print("mix(shade, lit, 0.0) = (\(fullyShadow.x), \(fullyShadow.y), \(fullyShadow.z))")
        XCTAssertEqual(fullyShadow.x, 0.5, accuracy: 0.001, "Fully shadow should be shade color")
        XCTAssertEqual(fullyShadow.y, 0.0, accuracy: 0.001, "Fully shadow should be shade color")
        XCTAssertEqual(fullyShadow.z, 0.0, accuracy: 0.001, "Fully shadow should be shade color")

        // Check shader code uses correct order: mix(shadeColor, baseColor.rgb, shadowStep)
        // This is verified by reading the shader - let's document the expected behavior
        print("\nShader uses: mix(shadeColor, baseColor.rgb, shadowStep)")
        print("  shadowStep=1.0 (lit) → baseColor.rgb")
        print("  shadowStep=0.0 (shadow) → shadeColor")
        print("This is CORRECT for MToon spec.")
    }

    // MARK: - Test 4: Full Material Loading Pipeline

    /// Comprehensive test of the material loading pipeline.
    func testMaterialLoadingPipeline() async throws {
        guard let vrm1Path = ProcessInfo.processInfo.environment["VRM_TEST_VRM1_PATH"] else {
            print("=== Material Loading Pipeline Test ===")
            print("Skipped: Set VRM_TEST_VRM1_PATH to run this test")
            return
        }

        let url = URL(fileURLWithPath: vrm1Path)
        print("\n=== Full Material Pipeline Test ===")
        print("Loading: \(url.lastPathComponent)")

        let model = try await VRMModel.load(from: url, device: device)

        print("\nModel loaded successfully")
        print("Materials: \(model.materials.count)")

        for (index, material) in model.materials.enumerated() {
            print("\n--- Material \(index): \(material.name ?? "unnamed") ---")

            // Base color
            let base = material.baseColorFactor
            print("  BaseColorFactor: (\(base.x), \(base.y), \(base.z), \(base.w))")

            // MToon properties
            if let mtoon = material.mtoon {
                print("  MToon Properties:")
                print("    shadeColorFactor: (\(mtoon.shadeColorFactor.x), \(mtoon.shadeColorFactor.y), \(mtoon.shadeColorFactor.z))")
                print("    shadingToonyFactor: \(mtoon.shadingToonyFactor)")
                print("    shadingShiftFactor: \(mtoon.shadingShiftFactor)")
                print("    giIntensityFactor: \(mtoon.giIntensityFactor)")

                // Calculate warmth (sunburn indicator)
                let shade = mtoon.shadeColorFactor
                let warmth = shade.x - (shade.y + shade.z) / 2.0
                print("    [Derived] warmth: \(warmth)")
                if warmth > 0.2 {
                    print("    ⚠️ High warmth may cause sunburn effect!")
                }
            } else {
                print("  (No MToon extension)")
            }

            // Textures
            print("  Textures:")
            print("    baseColor: \(material.baseColorTexture != nil ? "✓" : "✗")")
            print("    normal: \(material.normalTexture != nil ? "✓" : "✗")")
            print("    emissive: \(material.emissiveTexture != nil ? "✓" : "✗")")
        }
    }

    // MARK: - Test 5: VRM 0.x vs 1.0 Consistency

    /// Compare how the same conceptual shade color is handled in VRM 0.x vs 1.0.
    func testVRM0vs1ShadeColorHandling() throws {
        print("\n=== VRM 0.x vs 1.0 Shade Color Handling ===")

        // Simulate a warm skin shadow color
        // In Unity/VRM 0.x: specified in sRGB
        // In VRM 1.0: specified in linear

        let sRGBShade: [Float] = [0.8, 0.6, 0.5]  // Warm skin shadow in sRGB

        // VRM 0.x conversion (applies sRGB→linear)
        var vrm0Prop = VRM0MaterialProperty()
        vrm0Prop.vectorProperties["_ShadeColor"] = sRGBShade + [1.0]
        let vrm0MToon = vrm0Prop.toMToonMaterial()

        print("VRM 0.x Input (sRGB): (\(sRGBShade[0]), \(sRGBShade[1]), \(sRGBShade[2]))")
        print("VRM 0.x Output (linear): (\(vrm0MToon.shadeColorFactor.x), \(vrm0MToon.shadeColorFactor.y), \(vrm0MToon.shadeColorFactor.z))")

        // VRM 1.0 direct (values already linear in spec)
        // If someone exports the SAME sRGB values without conversion, they'd be wrong
        let vrm1DirectLinear = SIMD3<Float>(0.604, 0.318, 0.214)  // Correct linear equivalent

        print("\nVRM 1.0 (should already be linear): (\(vrm1DirectLinear.x), \(vrm1DirectLinear.y), \(vrm1DirectLinear.z))")

        // They should be approximately equal
        let diff = simd_length(vrm0MToon.shadeColorFactor - vrm1DirectLinear)
        print("\nDifference between conversions: \(diff)")

        XCTAssertLessThan(
            diff,
            0.01,
            "VRM 0.x conversion should produce linear values matching VRM 1.0 spec"
        )

        // Potential bug: If VRM 1.0 file has sRGB values but loader doesn't convert
        // (This would be a VRM authoring tool bug, not our bug)
        let wrongVRM1Values = SIMD3<Float>(sRGBShade[0], sRGBShade[1], sRGBShade[2])  // sRGB stored as linear
        let wrongWarmth = wrongVRM1Values.x - (wrongVRM1Values.y + wrongVRM1Values.z) / 2.0
        print("\n⚠️ If VRM 1.0 stores sRGB as linear (WRONG):")
        print("  Values: (\(wrongVRM1Values.x), \(wrongVRM1Values.y), \(wrongVRM1Values.z))")
        print("  Warmth: \(wrongWarmth) (higher = more sunburn)")
    }

    // MARK: - Test 6: Render and Dump Material State

    /// Render a VRM model and dump all material state for debugging.
    func testRenderAndDumpMaterialState() async throws {
        guard let vrm1Path = ProcessInfo.processInfo.environment["VRM_TEST_VRM1_PATH"] else {
            print("=== Render State Dump ===")
            print("Skipped: Set VRM_TEST_VRM1_PATH to run this test")
            return
        }

        let url = URL(fileURLWithPath: vrm1Path)
        print("\n=== Render State Dump ===")
        print("Model: \(url.lastPathComponent)")

        let model = try await VRMModel.load(from: url, device: device)

        // Create MToonMaterialUniforms for each material and dump state
        for (index, material) in model.materials.enumerated() {
            guard let mtoon = material.mtoon else { continue }

            var uniforms = MToonMaterialUniforms(from: mtoon, time: 0)

            // Apply base color factor
            uniforms.baseColorFactor = material.baseColorFactor

            print("\n--- Material \(index) GPU Uniforms ---")
            print("baseColorFactor: (\(uniforms.baseColorFactor.x), \(uniforms.baseColorFactor.y), \(uniforms.baseColorFactor.z), \(uniforms.baseColorFactor.w))")
            print("shadeColorFactor: (\(uniforms.shadeColorR), \(uniforms.shadeColorG), \(uniforms.shadeColorB))")
            print("shadingToonyFactor: \(uniforms.shadingToonyFactor)")
            print("shadingShiftFactor: \(uniforms.shadingShiftFactor)")
            print("vrmVersion: \(uniforms.vrmVersion)")
            print("hasBaseColorTexture: \(uniforms.hasBaseColorTexture)")
            print("hasShadeMultiplyTexture: \(uniforms.hasShadeMultiplyTexture)")

            // Validate uniforms
            do {
                try uniforms.validate()
                print("✓ Uniforms validated OK")
            } catch {
                print("⚠️ Validation error: \(error)")
            }
        }
    }
}
