// Copyright 2026 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import GLTFCore
@testable import VRMMetalKit

/// VRM 0.x stores colour factors in gamma (sRGB) space; VRM 1.0 and the
/// renderer work in linear. `_Color`, `_ShadeColor`, `_RimColor` and
/// `_OutlineColor` are already decoded on load, but emission was read
/// verbatim from the glTF `emissiveFactor` UniVRM writes in gamma space,
/// and `_EmissionColor` was ignored when that glTF field was absent.
/// three-vrm's V0CompatPlugin decodes `_EmissionColor`; match it.
final class VRM0EmissiveLinearizationTests: XCTestCase {

    private func material(json: String) throws -> GLTFMaterial {
        try JSONDecoder().decode(GLTFMaterial.self, from: Data(json.utf8))
    }

    private func srgbToLinear(_ v: Float) -> Float {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// PompaGirl's hair: glTF emissiveFactor and `_EmissionColor` both carry the
    /// gamma-space value (0.8588, 0.6941, 0.6941). The material must end up linear.
    func testVRM0EmissionColorIsDecodedToLinear() throws {
        let gltf = try material(json: #"{"name":"hair","emissiveFactor":[0.858823538,0.694117665,0.694117665]}"#)
        var prop = VRM0MaterialProperty()
        prop.shader = "VRM/MToon"
        prop.vectorProperties["_EmissionColor"] = [0.858823538, 0.694117665, 0.694117665, 1]

        let mat = VRMMaterial(from: gltf, textures: [], vrm0MaterialProperty: prop, vrmVersion: .v0_0)

        XCTAssertEqual(mat.emissiveFactor.x, srgbToLinear(0.858823538), accuracy: 1e-4)
        XCTAssertEqual(mat.emissiveFactor.y, srgbToLinear(0.694117665), accuracy: 1e-4)
        XCTAssertEqual(mat.emissiveFactor.z, srgbToLinear(0.694117665), accuracy: 1e-4)
    }

    /// Some 0.x exporters omit glTF emissiveFactor and carry emission only in
    /// `_EmissionColor` (the Muse validation avatar's hair). It must not be dropped.
    func testVRM0EmissionColorUsedWhenGLTFEmissiveAbsent() throws {
        let gltf = try material(json: #"{"name":"hair"}"#)
        var prop = VRM0MaterialProperty()
        prop.shader = "VRM/MToon"
        prop.vectorProperties["_EmissionColor"] = [1, 1, 1, 1]

        let mat = VRMMaterial(from: gltf, textures: [], vrm0MaterialProperty: prop, vrmVersion: .v0_0)

        XCTAssertEqual(mat.emissiveFactor, SIMD3<Float>(1, 1, 1))
    }

    /// VRM 1.0 emissiveFactor is already linear and must pass through untouched.
    func testVRM1EmissiveFactorPassesThrough() throws {
        let gltf = try material(json: #"{"name":"hair","emissiveFactor":[0.5,0.25,0.125]}"#)

        let mat = VRMMaterial(from: gltf, textures: [], vrm0MaterialProperty: nil, vrmVersion: .v1_0)

        XCTAssertEqual(mat.emissiveFactor, SIMD3<Float>(0.5, 0.25, 0.125))
    }
}
