//
//  RendererLightingCorrectnessTests.swift
//  VRMMetalKit
//
//  TDD tests for GitHub Issues #145, #146, #147.
//

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Tests for renderer lighting correctness bugs.
///
/// Issue #147 — Default lighting too dim (VRMRenderer.init does not call setup3PointLighting)
/// Issue #146 — emissiveFactor force-zeroed in VRMRenderer before encoding
/// Issue #145 — giEqualizationFactor parsed but ignored in MToonShader.metal
@MainActor
final class RendererLightingCorrectnessTests: XCTestCase {

    var device: MTLDevice!

    override func setUp() async throws {
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else {
            throw XCTSkip("Metal device not available")
        }
    }

    // MARK: - #147: Default lighting

    /// A freshly-created VRMRenderer should have 3-point lighting configured
    /// so that hands-off consumers get a usable image immediately.
    func testDefaultLightingHasThreePointSetup() {
        let renderer = VRMRenderer(device: device)

        // Fill light (light 1) should be non-zero when 3-point lighting is active
        XCTAssertNotEqual(
            renderer.uniforms.light1Color,
            SIMD3<Float>(0, 0, 0),
            "Fill light should be configured by default (#147)"
        )

        // Rim light (light 2) should also be non-zero
        XCTAssertNotEqual(
            renderer.uniforms.light2Color,
            SIMD3<Float>(0, 0, 0),
            "Rim light should be configured by default (#147)"
        )
    }

    /// Consumers that explicitly call setup3PointLighting() after init should
    /// still work (second call overwrites the first).
    func testExplicitLightingSetupOverridesDefault() {
        let renderer = VRMRenderer(device: device)

        // Override with custom values
        renderer.setup3PointLighting(keyIntensity: 2.0, fillIntensity: 1.0, rimIntensity: 0.5)

        let expected = SIMD3<Float>(1.0, 0.98, 0.95) * 2.0
        XCTAssertEqual(renderer.uniforms.lightColor.x, expected.x, accuracy: 0.001)
        XCTAssertEqual(renderer.uniforms.lightColor.y, expected.y, accuracy: 0.001)
        XCTAssertEqual(renderer.uniforms.lightColor.z, expected.z, accuracy: 0.001,
            "Explicit setup3PointLighting should override defaults")
    }

    // MARK: - #146: Emissive factor preserved

    /// The shader should add emissiveFactor on top of lit color. When all lights
    /// and ambient are zero, only emissive should contribute.
    func testEmissiveFactorContributesWithNoLights() async throws {
        let renderer = try LightingTestRenderer(device: device, width: 128, height: 128)

        var material = MToonMaterialUniforms()
        material.baseColorFactor = SIMD4<Float>(0, 0, 0, 1)   // Black base
        material.emissiveFactor = SIMD3<Float>(0.8, 0.6, 0.4) // Non-zero emissive
        material.shadeColorFactor = SIMD3<Float>(0, 0, 0)
        material.shadingToonyFactor = 0.9
        material.vrmVersion = 1

        let frameData = try renderer.render(
            material: material,
            lightDir: SIMD3<Float>(0, 0, 1),
            lightColor: SIMD3<Float>(0, 0, 0),
            ambientColor: SIMD3<Float>(0, 0, 0)
        )
        let centerRGB = sampleRGB(frameData, x: 64, y: 64, width: 128)

        // With everything else black, emissive should dominate
        XCTAssertGreaterThan(
            centerRGB.x, 0.1,
            "Emissive R should be visible with lights off (#146). Got \(centerRGB)"
        )
        XCTAssertGreaterThan(
            centerRGB.y, 0.05,
            "Emissive G should be visible with lights off (#146). Got \(centerRGB)"
        )
        XCTAssertGreaterThan(
            centerRGB.z, 0.02,
            "Emissive B should be visible with lights off (#146). Got \(centerRGB)"
        )
    }

    /// Zero emissive should render as black when lights are off.
    func testZeroEmissiveRendersBlackWithNoLights() async throws {
        let renderer = try LightingTestRenderer(device: device, width: 128, height: 128)

        var material = MToonMaterialUniforms()
        material.baseColorFactor = SIMD4<Float>(0, 0, 0, 1)
        material.emissiveFactor = SIMD3<Float>(0, 0, 0) // Zero emissive
        material.shadeColorFactor = SIMD3<Float>(0, 0, 0)
        material.shadingToonyFactor = 0.9
        material.vrmVersion = 1

        let frameData = try renderer.render(
            material: material,
            lightDir: SIMD3<Float>(0, 0, 1),
            lightColor: SIMD3<Float>(0, 0, 0),
            ambientColor: SIMD3<Float>(0, 0, 0)
        )
        let centerRGB = sampleRGB(frameData, x: 64, y: 64, width: 128)

        XCTAssertLessThan(centerRGB.x, 0.05, "Zero emissive should be nearly black")
        XCTAssertLessThan(centerRGB.y, 0.05, "Zero emissive should be nearly black")
        XCTAssertLessThan(centerRGB.z, 0.05, "Zero emissive should be nearly black")
    }

    // MARK: - #145: GI equalization factor (MToon 1.0 spec)

    /// giEqualizationFactor=0 → indirect diffuse fully follows shadeColor.
    /// With white base + black shade, indirect collapses to 0.
    func testGIEqualizationFactorZeroFollowsShade() async throws {
        let renderer = try LightingTestRenderer(device: device, width: 128, height: 128)

        var material = MToonMaterialUniforms()
        material.baseColorFactor = SIMD4<Float>(1, 1, 1, 1) // White base
        material.giEqualizationFactor = 0.0                     // Disabled GI
        material.shadeColorFactor = SIMD3<Float>(0, 0, 0)
        material.shadingToonyFactor = 0.9
        material.vrmVersion = 1

        let frameData = try renderer.render(
            material: material,
            lightDir: SIMD3<Float>(0, 0, 1),
            lightColor: SIMD3<Float>(0, 0, 0),
            ambientColor: SIMD3<Float>(0.5, 0.5, 0.5)
        )
        let centerRGB = sampleRGB(frameData, x: 64, y: 64, width: 128)

        // With giEqualizationFactor=0, ambient should NOT contribute
        XCTAssertLessThan(
            centerRGB.x, 0.1,
            "giEqualizationFactor=0 should disable indirect diffuse (#145). Got \(centerRGB)"
        )
    }

    /// giEqualizationFactor=1.0 → indirect diffuse fully follows baseColor.
    func testGIEqualizationFactorOneFollowsBase() async throws {
        let renderer = try LightingTestRenderer(device: device, width: 128, height: 128)

        var material = MToonMaterialUniforms()
        material.baseColorFactor = SIMD4<Float>(1, 1, 1, 1) // White base
        material.giEqualizationFactor = 1.0                     // Full GI
        material.shadeColorFactor = SIMD3<Float>(0, 0, 0)
        material.shadingToonyFactor = 0.9
        material.vrmVersion = 1

        let frameData = try renderer.render(
            material: material,
            lightDir: SIMD3<Float>(0, 0, 1),
            lightColor: SIMD3<Float>(0, 0, 0),
            ambientColor: SIMD3<Float>(0.5, 0.5, 0.5)
        )
        let centerRGB = sampleRGB(frameData, x: 64, y: 64, width: 128)

        // With giEqualizationFactor=1.0, ambient should contribute fully
        XCTAssertGreaterThan(
            centerRGB.x, 0.2,
            "giEqualizationFactor=1.0 should enable full indirect diffuse (#145). Got \(centerRGB)"
        )
    }

    /// giEqualizationFactor should mix linearly between shade-side and lit-side.
    func testGIEqualizationFactorScalesLinearly() async throws {
        let renderer = try LightingTestRenderer(device: device, width: 128, height: 128)

        let ambient = SIMD3<Float>(0.5, 0.5, 0.5)

        var material0 = MToonMaterialUniforms()
        material0.baseColorFactor = SIMD4<Float>(1, 1, 1, 1)
        material0.giEqualizationFactor = 0.0
        material0.shadeColorFactor = SIMD3<Float>(0, 0, 0)
        material0.shadingToonyFactor = 0.9
        material0.vrmVersion = 1

        var material1 = MToonMaterialUniforms()
        material1.baseColorFactor = SIMD4<Float>(1, 1, 1, 1)
        material1.giEqualizationFactor = 1.0
        material1.shadeColorFactor = SIMD3<Float>(0, 0, 0)
        material1.shadingToonyFactor = 0.9
        material1.vrmVersion = 1

        let frame0 = try renderer.render(
            material: material0,
            lightDir: SIMD3<Float>(0, 0, 1),
            lightColor: SIMD3<Float>(0, 0, 0),
            ambientColor: ambient
        )
        let center0 = sampleRGB(frame0, x: 64, y: 64, width: 128)

        let frame1 = try renderer.render(
            material: material1,
            lightDir: SIMD3<Float>(0, 0, 1),
            lightColor: SIMD3<Float>(0, 0, 0),
            ambientColor: ambient
        )
        let center1 = sampleRGB(frame1, x: 64, y: 64, width: 128)

        // center1 should be significantly brighter than center0
        XCTAssertGreaterThan(
            center1.x, center0.x + 0.15,
            "giEqualizationFactor=1.0 should be brighter than 0.0 (#145). 0.0=\(center0), 1.0=\(center1)"
        )
    }

    // MARK: - Defaults & override stacking

    /// MToon 1.0 spec: default `giEqualizationFactor` is 0.9 (matches three-vrm).
    func testDefaultGIEqualizationFactorMatchesSpec() {
        XCTAssertEqual(MToonMaterialUniforms().giEqualizationFactor, 0.9, accuracy: 0.0001)
    }

    /// With non-trivial shade and base, mid-range giEqualizationFactor must
    /// produce a true mix (not just brightness scale). Cyan base + red shade
    /// at factor 0.5 should land between the two channels.
    func testGIEqualizationFactorMixesShadeAndBase() async throws {
        let renderer = try LightingTestRenderer(device: device, width: 128, height: 128)

        var material = MToonMaterialUniforms()
        material.baseColorFactor = SIMD4<Float>(0, 1, 1, 1)   // Cyan base
        material.shadeColorFactor = SIMD3<Float>(1, 0, 0)     // Red shade
        material.giEqualizationFactor = 0.5
        material.shadingToonyFactor = 0.9
        material.vrmVersion = 1

        let frameData = try renderer.render(
            material: material,
            lightDir: SIMD3<Float>(0, 0, 1),
            lightColor: SIMD3<Float>(0, 0, 0),
            ambientColor: SIMD3<Float>(1, 1, 1)
        )
        let centerRGB = sampleRGB(frameData, x: 64, y: 64, width: 128)

        // mix(red, cyan, 0.5) = (0.5, 0.5, 0.5) before ambient. Both R and G/B
        // should land in the mid-band — not red-dominant, not cyan-dominant.
        XCTAssertGreaterThan(centerRGB.x, 0.3, "Red channel from shade should bleed in. Got \(centerRGB)")
        XCTAssertGreaterThan(centerRGB.y, 0.3, "Green channel from base should bleed in. Got \(centerRGB)")
        XCTAssertGreaterThan(centerRGB.z, 0.3, "Blue channel from base should bleed in. Got \(centerRGB)")
    }

    /// `setLight(0, …)` after init overrides only the key light. The auto-configured
    /// fill (1) and rim (2) lights from `setup3PointLighting()` remain in place.
    /// Documents the intended override-stacking semantics introduced in #147.
    func testPartialLightOverrideRetainsAutoFillAndRim() {
        let renderer = VRMRenderer(device: device)

        renderer.setLight(0,
                          direction: SIMD3<Float>(0, -1, 0),
                          color: SIMD3<Float>(0.5, 0.5, 0.5))

        XCTAssertNotEqual(
            renderer.uniforms.light1Color,
            SIMD3<Float>(0, 0, 0),
            "Fill light should remain configured after key-only setLight override"
        )
        XCTAssertNotEqual(
            renderer.uniforms.light2Color,
            SIMD3<Float>(0, 0, 0),
            "Rim light should remain configured after key-only setLight override"
        )
    }
}

// MARK: - Helpers

private func sampleRGB(_ data: Data, x: Int, y: Int, width: Int) -> SIMD3<Float> {
    let bytesPerRow = width * 4
    let offset = y * bytesPerRow + x * 4
    guard offset + 3 < data.count else {
        return SIMD3<Float>(0, 0, 0)
    }
    let b = Float(data[offset])
    let g = Float(data[offset + 1])
    let r = Float(data[offset + 2])
    return SIMD3<Float>(r, g, b) / 255.0
}
