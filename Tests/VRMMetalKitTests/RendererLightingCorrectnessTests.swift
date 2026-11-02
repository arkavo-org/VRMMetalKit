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

    // MARK: - GI (MToon 1.0 §GI Equalization)

    /// The spec's indirect term is `gi(n) * litColor` with
    /// `gi(n) = lerp(rawGi(n), uniformedGi, giEqualizationFactor)`. VMK's only
    /// global illumination is a uniform ambient colour, so `rawGi(n)` equals
    /// `uniformedGi` and the indirect term is `ambient * baseColor` whatever the
    /// factor is.
    func testIndirectFollowsBaseColorWithZeroEqualization() async throws {
        let renderer = try LightingTestRenderer(device: device, width: 128, height: 128)
        let center = try renderAmbientOnly(renderer, base: [1, 1, 1], shade: [0, 0, 0],
                                           giEqualization: 0.0, ambient: [0.5, 0.5, 0.5])
        XCTAssertGreaterThan(center.x, 0.2,
            "Under uniform ambient, giEqualizationFactor 0 must still light the base colour. Got \(center)")
    }

    func testGIEqualizationFactorHasNoEffectUnderUniformAmbient() async throws {
        let renderer = try LightingTestRenderer(device: device, width: 128, height: 128)
        let zero = try renderAmbientOnly(renderer, base: [1, 1, 1], shade: [0, 0, 0],
                                         giEqualization: 0.0, ambient: [0.5, 0.5, 0.5])
        let one = try renderAmbientOnly(renderer, base: [1, 1, 1], shade: [0, 0, 0],
                                        giEqualization: 1.0, ambient: [0.5, 0.5, 0.5])
        XCTAssertEqual(zero.x, one.x, accuracy: 1.0 / 255.0,
            "Under uniform ambient, giEqualizationFactor must not change the indirect term. 0.0=\(zero), 1.0=\(one)")
    }

    /// Cyan base, red shade: the indirect term carries the base colour only.
    func testIndirectCarriesNoShadeColor() async throws {
        let renderer = try LightingTestRenderer(device: device, width: 128, height: 128)
        let center = try renderAmbientOnly(renderer, base: [0, 1, 1], shade: [1, 0, 0],
                                           giEqualization: 0.5, ambient: [1, 1, 1])
        XCTAssertLessThan(center.x, 0.05, "Shade colour leaked into the indirect term. Got \(center)")
        XCTAssertGreaterThan(center.y, 0.3, "Base colour missing from the indirect term. Got \(center)")
        XCTAssertGreaterThan(center.z, 0.3, "Base colour missing from the indirect term. Got \(center)")
    }

    private func renderAmbientOnly(
        _ renderer: LightingTestRenderer,
        base: SIMD3<Float>,
        shade: SIMD3<Float>,
        giEqualization: Float,
        ambient: SIMD3<Float>
    ) throws -> SIMD3<Float> {
        var material = MToonMaterialUniforms()
        material.baseColorFactor = SIMD4<Float>(base, 1)
        material.shadeColorFactor = shade
        material.giEqualizationFactor = giEqualization
        material.shadingToonyFactor = 0.9
        material.vrmVersion = 1
        let frame = try renderer.render(
            material: material,
            lightDir: SIMD3<Float>(0, 0, 1),
            lightColor: SIMD3<Float>(0, 0, 0),
            ambientColor: ambient
        )
        return sampleRGB(frame, x: 64, y: 64, width: 128)
    }

    // MARK: - Defaults & override stacking

    /// MToon 1.0 spec: default `giEqualizationFactor` is 0.9 (matches three-vrm).
    func testDefaultGIEqualizationFactorMatchesSpec() {
        XCTAssertEqual(MToonMaterialUniforms().giEqualizationFactor, 0.9, accuracy: 0.0001)
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
