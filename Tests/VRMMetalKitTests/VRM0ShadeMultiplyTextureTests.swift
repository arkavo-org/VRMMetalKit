// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
@testable import VRMMetalKit

/// VRM 0.x `_ShadeTexture` must be wired to `mtoon.shadeMultiplyTexture`
/// even when it points to the same texture index as `_MainTex`. Unity
/// MToon (and three-vrm's V0CompatPlugin) always multiply `shadeColorFactor`
/// by the shade texture; a converter that silently drops the binding when
/// `_ShadeTexture == _MainTex` leaves the shadow side using only
/// `shadeColorFactor` (typically `[1,1,1]` white), which washes out
/// dark-textured materials like hair.
///
/// AvatarSample_A's hair authors `_ShadeTexture == _MainTex` (index 15
/// in the 0.0 GLB), and three-vrm's converter emits the same texture as
/// `shadeMultiplyTexture` in the matching 1.0 GLB. Mirror that here.
final class VRM0ShadeMultiplyTextureTests: XCTestCase {

    /// AvatarSample_A's hair case: `_ShadeTexture == _MainTex == 15`.
    /// Must round-trip onto `mtoon.shadeMultiplyTexture = 15` — not nil.
    func testShadeMultiplyTextureSetWhenSameAsMainTexture() throws {
        var prop = VRM0MaterialProperty()
        prop.name = "N00_000_Hair_00_HAIR_01 (Instance)"
        prop.shader = "VRM/MToon"
        prop.textureProperties["_MainTex"] = 15
        prop.textureProperties["_ShadeTexture"] = 15

        let mtoon = prop.toMToonMaterial()

        XCTAssertEqual(mtoon.shadeMultiplyTexture, 15,
            "VRM 0.x conversion must bind shadeMultiplyTexture even when " +
            "it equals the main texture index. Skipping it leaves shadeColor " +
            "as the bare factor (white for hair), washing out the shadow side " +
            "and producing the dark-brown→pale-cream gradient seen in " +
            "AvatarSample_A_0.0.png. three-vrm's V0CompatPlugin emits " +
            "shadeMultiplyTexture unconditionally; match that.")
    }

    /// Distinct indices must also be wired through (regression guard for
    /// over-tightening the fix to only the equal-index branch).
    func testShadeMultiplyTextureSetWhenDifferentFromMainTexture() throws {
        var prop = VRM0MaterialProperty()
        prop.name = "test_distinct_shade_tex"
        prop.shader = "VRM/MToon"
        prop.textureProperties["_MainTex"] = 7
        prop.textureProperties["_ShadeTexture"] = 12

        let mtoon = prop.toMToonMaterial()

        XCTAssertEqual(mtoon.shadeMultiplyTexture, 12,
            "VRM 0.x conversion must bind _ShadeTexture index when it " +
            "differs from _MainTex.")
    }

    /// Absent `_ShadeTexture` stays nil — don't fabricate a binding from
    /// `_MainTex`.
    func testShadeMultiplyTextureNilWhenShadeTextureAbsent() throws {
        var prop = VRM0MaterialProperty()
        prop.name = "test_no_shade_tex"
        prop.shader = "VRM/MToon"
        prop.textureProperties["_MainTex"] = 5
        // No _ShadeTexture key.

        let mtoon = prop.toMToonMaterial()

        XCTAssertNil(mtoon.shadeMultiplyTexture,
            "Conversion must not default shadeMultiplyTexture to _MainTex " +
            "when _ShadeTexture is absent; leave nil for the shader's " +
            "factor-only path.")
    }
}
