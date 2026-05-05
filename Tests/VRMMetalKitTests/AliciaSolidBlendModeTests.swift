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
@testable import VRMMetalKit

/// TDD tests for VRM 0.x _BlendMode → alphaMode mapping.
///
/// Corpus scan revealed that `AliciaSolid_vrm-0.51.vrm` uses `_BlendMode = 3`
/// (TransparentWithZWrite) for hair overlays (`Alicia_hair_trans`,
/// `Alicia_hair_trans_zwrite`). The newer `AliciaSolid.vrm` uses `_BlendMode=0`
/// (Opaque) for hair and is NOT affected by this mapping.
///
/// However, many other corpus models (VRoid, PompaGirl, Vita_clothing, Ao_dress,
/// AnnieV0) use `_BlendMode = 1` (Cutout) and `_BlendMode = 2` (Transparent).
/// Without this mapping, all of them default to glTF "OPAQUE" and render
/// incorrectly.
///
/// NOTE: The black bangs on `AliciaSolid_vrm-0.51.vrm` are caused by the OPAQUE
/// base hair (`Alicia_hair`) showing black texture padding, NOT by the
/// `_BlendMode` mapping. The transparent overlays are correctly handled by
/// this fix but cannot mask opaque base geometry.
final class AliciaSolidBlendModeTests: XCTestCase {

    // MARK: - VRM 0.x _BlendMode → alphaMode Mapping

    /// _BlendMode 0 (Opaque) must map to alphaMode "OPAQUE"
    func testBlendMode0_MapsToOpaque() {
        let gltfMat = createGLTFMaterial(alphaMode: "OPAQUE")
        let vrm0Prop = createVRM0Property(blendMode: 0)

        let material = VRMMaterial(
            from: gltfMat,
            textures: [],
            vrm0MaterialProperty: vrm0Prop,
            vrmVersion: .v0_0
        )

        XCTAssertEqual(material.alphaMode.uppercased(), "OPAQUE")
        XCTAssertEqual(material.blendMode, 0)
    }

    /// _BlendMode 1 (Cutout) must map to alphaMode "MASK"
    func testBlendMode1_MapsToMask() {
        let gltfMat = createGLTFMaterial(alphaMode: "OPAQUE")
        let vrm0Prop = createVRM0Property(blendMode: 1)

        let material = VRMMaterial(
            from: gltfMat,
            textures: [],
            vrm0MaterialProperty: vrm0Prop,
            vrmVersion: .v0_0
        )

        XCTAssertEqual(material.alphaMode.uppercased(), "MASK")
        XCTAssertEqual(material.blendMode, 1)
    }

    /// _BlendMode 2 (Transparent) must map to alphaMode "BLEND"
    func testBlendMode2_MapsToBlend() {
        let gltfMat = createGLTFMaterial(alphaMode: "OPAQUE")
        let vrm0Prop = createVRM0Property(blendMode: 2)

        let material = VRMMaterial(
            from: gltfMat,
            textures: [],
            vrm0MaterialProperty: vrm0Prop,
            vrmVersion: .v0_0
        )

        XCTAssertEqual(material.alphaMode.uppercased(), "BLEND")
        XCTAssertEqual(material.blendMode, 2)
    }

    /// _BlendMode 3 (TransparentWithZWrite) must map to alphaMode "BLEND".
    /// Affected model: AliciaSolid_vrm-0.51.vrm (hair_trans, hair_trans_zwrite,
    /// face_mastuge, other_zwrite). Without this mapping, these materials stay
    /// "OPAQUE" and transparent overlays render without blending.
    func testBlendMode3_MapsToBlend() {
        let gltfMat = createGLTFMaterial(alphaMode: "OPAQUE")
        let vrm0Prop = createVRM0Property(blendMode: 3)

        let material = VRMMaterial(
            from: gltfMat,
            textures: [],
            vrm0MaterialProperty: vrm0Prop,
            vrmVersion: .v0_0
        )

        // RED: This assertion fails because alphaMode is never updated from
        // the glTF default when _BlendMode is parsed. The material reports
        // "OPAQUE" even though _BlendMode = 3 means it should use blending.
        XCTAssertEqual(
            material.alphaMode.uppercased(),
            "BLEND",
            "BUG: VRM 0.x _BlendMode=3 (TransparentWithZWrite) must map to alphaMode=BLEND. " +
            "Without this mapping, the renderer assigns the opaque pipeline, " +
            "ignoring alpha and showing black texture padding (AliciaSolid bangs)."
        )
        XCTAssertEqual(material.blendMode, 3)
        XCTAssertTrue(material.isTransparentWithZWrite)
    }

    // MARK: - Helpers

    private func createGLTFMaterial(alphaMode: String) -> GLTFMaterial {
        let json = """
        {
            "name": "TestHair",
            "pbrMetallicRoughness": {
                "baseColorFactor": [1.0, 1.0, 1.0, 1.0],
                "metallicFactor": 0.0,
                "roughnessFactor": 1.0
            },
            "emissiveFactor": [0.0, 0.0, 0.0],
            "alphaMode": "\(alphaMode)",
            "alphaCutoff": 0.5,
            "doubleSided": false
        }
        """

        let data = json.data(using: .utf8)!
        return try! JSONDecoder().decode(GLTFMaterial.self, from: data)
    }

    private func createVRM0Property(blendMode: Int) -> VRM0MaterialProperty {
        var prop = VRM0MaterialProperty()
        prop.floatProperties["_BlendMode"] = Float(blendMode)
        prop.floatProperties["_ZWrite"] = 1.0
        return prop
    }
}
