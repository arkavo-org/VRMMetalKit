// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
@testable import VRMMetalKit

/// Tests for VMK#265: VRM 0.x `_BlendMode = 3` (TransparentWithZWrite)
/// must round-trip onto `VRMMaterial.transparentWithZWrite = true`, not
/// rely on the `isTransparentWithZWrite` computed-property fallback.
///
/// Fragility per the issue: any code that reads
/// `material.transparentWithZWrite` directly (without going through the
/// computed property) sees `false` for converted assets, even though the
/// material is semantically TransparentWithZWrite. Dumps and conformance
/// harnesses comparing parsed VRM 1.0 native vs 0.x-converted materials
/// then show divergent values for what is the same material.
final class VRM0BlendModeConversionTests: XCTestCase {

    /// `_BlendMode = 3` is the spec value for "TransparentWithZWrite" —
    /// the VRM 0.x equivalent of VRM 1.0's
    /// `alphaMode: "BLEND" + VRMC_materials_mtoon.transparentWithZWrite: true`.
    /// Conversion must set the explicit field, not just `alphaMode = "BLEND"`.
    func testBlendModeThreeSetsTransparentWithZWriteExplicitly() throws {
        let material = makeConvertedMaterial(blendMode: 3.0)

        XCTAssertEqual(material.alphaMode, "BLEND",
            "VRM 0.x _BlendMode=3 must convert to alphaMode \"BLEND\". " +
            "Got \(material.alphaMode).")
        XCTAssertEqual(material.blendMode, 3,
            "blendMode field must round-trip the source _BlendMode value.")
        XCTAssertTrue(material.transparentWithZWrite,
            "VMK#265: VRM 0.x _BlendMode=3 must explicitly set " +
            "transparentWithZWrite=true on the converted material. The " +
            "isTransparentWithZWrite computed property currently masks the " +
            "missing assignment, but any direct reader of " +
            "transparentWithZWrite sees `false`.")
    }

    /// `_BlendMode = 2` (Transparent, no Z-write) must NOT set
    /// `transparentWithZWrite`. Guards against an over-eager fix that
    /// flips both 2 and 3 to true.
    func testBlendModeTwoDoesNotSetTransparentWithZWrite() throws {
        let material = makeConvertedMaterial(blendMode: 2.0)

        XCTAssertEqual(material.alphaMode, "BLEND")
        XCTAssertEqual(material.blendMode, 2)
        XCTAssertFalse(material.transparentWithZWrite,
            "VRM 0.x _BlendMode=2 is plain Transparent (no Z-write); " +
            "transparentWithZWrite must stay false. Got true — the #265 " +
            "fix has over-applied to blendMode==2.")
    }

    /// `_BlendMode = 0` (Opaque) and `_BlendMode = 1` (Cutout) similarly
    /// must not set `transparentWithZWrite`.
    func testOpaqueAndCutoutBlendModesDoNotSetTransparentWithZWrite() throws {
        let opaque = makeConvertedMaterial(blendMode: 0.0)
        XCTAssertEqual(opaque.alphaMode, "OPAQUE")
        XCTAssertFalse(opaque.transparentWithZWrite,
            "VRM 0.x _BlendMode=0 (Opaque) must not set transparentWithZWrite.")

        let cutout = makeConvertedMaterial(blendMode: 1.0)
        XCTAssertEqual(cutout.alphaMode, "MASK")
        XCTAssertFalse(cutout.transparentWithZWrite,
            "VRM 0.x _BlendMode=1 (Cutout) must not set transparentWithZWrite.")
    }

    // MARK: - Helpers

    private func makeConvertedMaterial(blendMode: Float) -> VRMMaterial {
        let materialJSON = """
        {
          "name": "blendmode_\(blendMode)",
          "pbrMetallicRoughness": {"baseColorFactor": [1.0, 1.0, 1.0, 1.0]}
        }
        """
        let gltfMat = try! JSONDecoder().decode(
            GLTFMaterial.self,
            from: materialJSON.data(using: .utf8)!
        )

        var vrm0Prop = VRM0MaterialProperty()
        vrm0Prop.name = "blendmode_\(blendMode)"
        vrm0Prop.shader = "VRM/MToon"
        vrm0Prop.floatProperties["_BlendMode"] = blendMode

        return VRMMaterial(
            from: gltfMat,
            textures: [],
            vrm0MaterialProperty: vrm0Prop,
            vrmVersion: .v0_0
        )
    }
}
