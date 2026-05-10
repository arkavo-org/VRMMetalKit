//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Tests for `SilhouetteRenderConfig` and `VRMRenderer.applySilhouetteMode`.
///
/// Three layers:
///   1. **Predicate** — pure-Swift tests of `defaultIsEyeMaterial` against
///      VRoid English, native VRM Japanese, exclusion edge cases, nil handling.
///   2. **Renderer flag invariants** — `applySilhouetteMode` sets the documented
///      flags, configures the rim light, zeros ambient.
///   3. **Material-mutation invariants** — uses the bundled VRM 1.0 fixture
///      to verify body materials are crushed, eye materials route texture →
///      emissive, outlines are zeroed everywhere.
@MainActor
final class SilhouetteRenderConfigTests: XCTestCase {

    var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    // MARK: - 1. Predicate tests (pure)

    /// VRoid English convention: any name containing `eye / iris / sclera /
    /// pupil / highlight / eyeball` should self-illuminate. Case-insensitive.
    func testDefaultIsEyeMaterial_includesStandardEyeNames() {
        let pred = SilhouetteRenderConfig.defaultIsEyeMaterial
        XCTAssertTrue(pred("EyeIris"), "EyeIris should be eye")
        XCTAssertTrue(pred("eye_iris"), "eye_iris should be eye")
        XCTAssertTrue(pred("EYEBALL"), "EYEBALL (uppercase) should be eye")
        XCTAssertTrue(pred("Sclera"), "Sclera should be eye")
        XCTAssertTrue(pred("EyeWhite"), "EyeWhite should be eye (matches 'eye')")
        XCTAssertTrue(pred("Iris_R"), "Iris_R should be eye")
        XCTAssertTrue(pred("M_Pupil"), "M_Pupil should be eye")
    }

    /// `lash / brow / line` exclusion takes precedence over inclusion. This
    /// catches eyebrows, eyelashes, eyeliner, and any name containing
    /// "outline" — they all need to be part of the body crush.
    func testDefaultIsEyeMaterial_excludesEyebrowsAndEyelashes() {
        let pred = SilhouetteRenderConfig.defaultIsEyeMaterial
        XCTAssertFalse(pred("FaceBrow"), "FaceBrow excluded via 'brow'")
        XCTAssertFalse(pred("Eyelash"), "Eyelash excluded via 'lash'")
        XCTAssertFalse(pred("FaceEyeline"), "FaceEyeline excluded via 'line'")
        XCTAssertFalse(pred("Eyeliner"), "Eyeliner excluded via 'line'")
        XCTAssertFalse(pred("Hairline"), "Hairline excluded via 'line'")
        XCTAssertFalse(pred("Outline"), "Outline excluded via 'line'")
    }

    /// Native VRM models may name materials in Japanese. Match is exact
    /// (case-insensitive doesn't apply to ideographs).
    func testDefaultIsEyeMaterial_includesJapaneseNames() {
        let pred = SilhouetteRenderConfig.defaultIsEyeMaterial
        XCTAssertTrue(pred("瞳"), "瞳 (pupil) should be eye")
        XCTAssertTrue(pred("白目"), "白目 (sclera) should be eye")
        XCTAssertTrue(pred("ハイライト"), "ハイライト (highlight) should be eye")
        XCTAssertTrue(pred("Mat_瞳_R"), "Japanese token in mixed name")
    }

    /// `nil` name (rare but legal in glTF) should not crash and should not
    /// be treated as an eye.
    func testDefaultIsEyeMaterial_handlesNilName() {
        let pred = SilhouetteRenderConfig.defaultIsEyeMaterial
        XCTAssertFalse(pred(nil))
        XCTAssertFalse(pred(""))
    }

    /// Documents (does not change) that a bare "highlight" name without an
    /// eye prefix is currently included. This is intentional for VRoid
    /// exporters that name iris-highlight decals as "Highlight" alone. If a
    /// future model authors a non-eye material named "Highlight", it will
    /// self-illuminate; the workaround is a custom predicate via
    /// `SilhouetteRenderConfig.isEyeMaterial`.
    func testDefaultIsEyeMaterial_includesBareHighlight_byDesign() {
        let pred = SilhouetteRenderConfig.defaultIsEyeMaterial
        XCTAssertTrue(pred("Highlight"))
        XCTAssertTrue(pred("EyeHighlight"))
    }

    /// A custom predicate via `SilhouetteRenderConfig.isEyeMaterial` overrides
    /// the default and is honored by `applySilhouetteMode`. (Predicate-only
    /// test; the integration test below confirms the renderer respects it.)
    func testCustomIsEyeMaterialPredicateIsHonored() {
        var config = SilhouetteRenderConfig()
        config.isEyeMaterial = { name in
            name?.lowercased().contains("custom_marker") ?? false
        }
        XCTAssertTrue(config.isEyeMaterial("MyCustom_Marker_Iris"))
        XCTAssertFalse(config.isEyeMaterial("EyeIris"))
    }

    // MARK: - 2. Renderer flag invariants

    /// `applySilhouetteMode` must set exactly the documented renderer flags.
    func testApplySilhouetteMode_setsRendererFlags() async throws {
        try requireFixture(vrm10Path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: vrm10Path), device: device)
        let renderer = VRMRenderer(device: device)

        XCTAssertFalse(renderer.disableAutoMaterialOverrides, "default off")
        XCTAssertFalse(renderer.additiveDirectionalRimEnabled, "default off")

        var config = SilhouetteRenderConfig()
        config.rimFresnelPower = 9.5
        renderer.applySilhouetteMode(model: model, config: config)

        XCTAssertTrue(renderer.disableAutoMaterialOverrides)
        XCTAssertTrue(renderer.additiveDirectionalRimEnabled)
        XCTAssertEqual(renderer.additiveDirectionalRimPower, 9.5, accuracy: 0.0001)
    }

    /// Light 0 and Light 2 must be disabled (zero color). Light 1 must be
    /// configured to the rim params from the config. Ambient must be zero.
    func testApplySilhouetteMode_clearsAmbientAndConfiguresRimLight() async throws {
        try requireFixture(vrm10Path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: vrm10Path), device: device)
        let renderer = VRMRenderer(device: device)

        var config = SilhouetteRenderConfig()
        config.rimLightDirection = SIMD3<Float>(-1, 0, 0)
        config.rimLightColor = SIMD3<Float>(0.9, 0.5, 0.3)
        config.rimLightIntensity = 0.8
        renderer.applySilhouetteMode(model: model, config: config)

        XCTAssertEqual(renderer.uniforms.ambientColor, SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(renderer.uniforms.lightColor, SIMD3<Float>(0, 0, 0),
                       "Light 0 disabled by silhouette mode")
        XCTAssertEqual(renderer.uniforms.light2Color, SIMD3<Float>(0, 0, 0),
                       "Light 2 disabled by silhouette mode")
        // Light 1 = rim. setLight() multiplies color by intensity.
        let expectedLight1Color = SIMD3<Float>(0.9, 0.5, 0.3) * 0.8
        XCTAssertEqual(renderer.uniforms.light1Color.x, expectedLight1Color.x, accuracy: 0.001)
        XCTAssertEqual(renderer.uniforms.light1Color.y, expectedLight1Color.y, accuracy: 0.001)
        XCTAssertEqual(renderer.uniforms.light1Color.z, expectedLight1Color.z, accuracy: 0.001)
    }

    // MARK: - 3. Material-mutation invariants (real fixture)

    private var vrm10Path: String { getTestVRM10ModelPath() }

    /// Every material's MToon outline must be zeroed after silhouette apply —
    /// the inverted-hull outline is albedo-independent and would otherwise pop
    /// as a bright artifact on the crushed body.
    func testApplySilhouetteMode_zerosOutlinesOnAllMaterials() async throws {
        try requireFixture(vrm10Path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: vrm10Path), device: device)
        let renderer = VRMRenderer(device: device)
        renderer.applySilhouetteMode(model: model, config: SilhouetteRenderConfig())

        for material in model.materials {
            guard let mtoon = material.mtoon else { continue }
            XCTAssertEqual(mtoon.outlineWidthFactor, 0,
                           "outlineWidthFactor on '\(material.name ?? "?")' should be zeroed")
            XCTAssertEqual(mtoon.outlineColorFactor, SIMD3<Float>(0, 0, 0),
                           "outlineColorFactor on '\(material.name ?? "?")' should be zeroed")
        }
    }

    /// Body materials (not matched by the eye predicate) must collapse to
    /// pure black on every contributing channel.
    func testApplySilhouetteMode_crushesBodyMaterials() async throws {
        try requireFixture(vrm10Path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: vrm10Path), device: device)
        let renderer = VRMRenderer(device: device)
        let config = SilhouetteRenderConfig()
        renderer.applySilhouetteMode(model: model, config: config)

        for material in model.materials where !config.isEyeMaterial(material.name) {
            let rgb = SIMD3<Float>(material.baseColorFactor.x,
                                   material.baseColorFactor.y,
                                   material.baseColorFactor.z)
            XCTAssertEqual(rgb, SIMD3<Float>(0, 0, 0),
                           "Body '\(material.name ?? "?")' baseColorFactor.rgb should be zero")
            XCTAssertEqual(material.emissiveFactor, SIMD3<Float>(0, 0, 0),
                           "Body '\(material.name ?? "?")' emissiveFactor should be zero")
            if let mtoon = material.mtoon {
                XCTAssertEqual(mtoon.shadeColorFactor, SIMD3<Float>(0, 0, 0),
                               "Body '\(material.name ?? "?")' shadeColorFactor should be zero")
                XCTAssertEqual(mtoon.matcapFactor, SIMD3<Float>(0, 0, 0),
                               "Body '\(material.name ?? "?")' matcapFactor should be zero")
                XCTAssertEqual(mtoon.parametricRimColorFactor, SIMD3<Float>(0, 0, 0),
                               "Body '\(material.name ?? "?")' parametric rim should be zero")
                XCTAssertEqual(mtoon.giEqualizationFactor, 0,
                               "Body '\(material.name ?? "?")' giEqualizationFactor should be zero")
            }
        }
    }

    /// Eye materials with a `baseColorTexture` must route it through
    /// `emissiveTexture`, scaled by `eyeEmissiveScale`. Their `baseColorFactor`
    /// rgb still collapses to black so only the emissive lights up.
    func testApplySilhouetteMode_routesEyeBaseTextureToEmissive() async throws {
        try requireFixture(vrm10Path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: vrm10Path), device: device)
        let renderer = VRMRenderer(device: device)

        // Pre-snapshot: capture each eye's original baseColorTexture pointer.
        var preSnapshots: [(name: String?, baseTex: VRMTexture?, baseFactor: SIMD4<Float>)] = []
        for material in model.materials where SilhouetteRenderConfig.defaultIsEyeMaterial(material.name) {
            preSnapshots.append((material.name, material.baseColorTexture, material.baseColorFactor))
        }
        XCTAssertGreaterThan(preSnapshots.count, 0,
                             "Fixture should contain at least one eye material")

        var config = SilhouetteRenderConfig()
        config.eyeEmissiveScale = 2.5
        renderer.applySilhouetteMode(model: model, config: config)

        for snapshot in preSnapshots {
            let material = model.materials.first(where: { $0.name == snapshot.name })!
            // Emissive routing: texture variant
            if snapshot.baseTex != nil {
                XCTAssertNotNil(material.emissiveTexture,
                                "Eye '\(snapshot.name ?? "?")' should have emissive texture after apply")
                XCTAssertEqual(material.emissiveTexture === snapshot.baseTex, true,
                               "Eye '\(snapshot.name ?? "?")' emissiveTexture should == original baseColorTexture")
                XCTAssertEqual(material.emissiveFactor.x, 2.5, accuracy: 0.0001,
                               "Eye '\(snapshot.name ?? "?")' emissiveFactor should equal eyeEmissiveScale")
            } else {
                // Textureless variant: emissive should be the original albedo * scale.
                let rgb = SIMD3<Float>(snapshot.baseFactor.x, snapshot.baseFactor.y, snapshot.baseFactor.z) * 2.5
                XCTAssertEqual(material.emissiveFactor.x, rgb.x, accuracy: 0.001)
                XCTAssertEqual(material.emissiveFactor.y, rgb.y, accuracy: 0.001)
                XCTAssertEqual(material.emissiveFactor.z, rgb.z, accuracy: 0.001)
            }
            // baseColorFactor.rgb collapsed to zero (alpha preserved).
            let baseRGB = SIMD3<Float>(material.baseColorFactor.x,
                                       material.baseColorFactor.y,
                                       material.baseColorFactor.z)
            XCTAssertEqual(baseRGB, SIMD3<Float>(0, 0, 0),
                           "Eye '\(snapshot.name ?? "?")' baseColorFactor.rgb should be zero")
            XCTAssertEqual(material.baseColorFactor.w, snapshot.baseFactor.w, accuracy: 0.0001,
                           "Eye '\(snapshot.name ?? "?")' baseColorFactor.w (alpha) should be preserved")
        }
    }

    /// Custom eye predicate routes a non-default material name into the eye
    /// path. End-to-end check that `config.isEyeMaterial` is the only contract.
    func testApplySilhouetteMode_honorsCustomEyePredicate() async throws {
        try requireFixture(vrm10Path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: vrm10Path), device: device)
        let renderer = VRMRenderer(device: device)

        // Pick a body material to forcibly classify as "eye".
        guard let target = model.materials.first(where: { name in
            !SilhouetteRenderConfig.defaultIsEyeMaterial(name.name) && name.baseColorTexture != nil
        }) else {
            throw XCTSkip("No suitable body material with texture in fixture")
        }
        let targetName = target.name
        let originalTex = target.baseColorTexture

        var config = SilhouetteRenderConfig()
        config.isEyeMaterial = { name in name == targetName }
        renderer.applySilhouetteMode(model: model, config: config)

        XCTAssertTrue(target.emissiveTexture === originalTex,
                      "Custom predicate target should have emissive routed from base texture")
    }
}
