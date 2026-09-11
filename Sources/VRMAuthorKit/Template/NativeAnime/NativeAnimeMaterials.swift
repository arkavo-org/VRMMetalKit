//
// Copyright 2026 Arkavo
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

import Foundation

/// The template's default MToon materials: the materials area's calibrated
/// role defaults (procedural textures, style-profile factor sets) under stable
/// ids, each carrying a VRoid-style glTF name so the style linter's role
/// heuristic classifies every one of them.
public enum NativeAnimeMaterials {
    public static let faceSkin = "mat.face_skin"
    public static let bodySkin = "mat.body_skin"
    public static let iris = "mat.iris"
    public static let eyeWhite = "mat.eye_white"
    public static let eyeHighlight = "mat.eye_highlight"
    public static let eyeline = "mat.eyeline"
    public static let eyelash = "mat.eyelash"
    public static let brow = "mat.brow"
    public static let mouth = "mat.mouth"
    public static let hair = "mat.hair"
    public static let clothTop = "mat.cloth_top"
    public static let clothBottom = "mat.cloth_bottom"
    public static let clothFootwear = "mat.cloth_footwear"

    /// Image the hair material samples; authored from the recipe's `HairTexture`
    /// rather than the hair role default.
    public static let hairImageId = "image:hair.main"
    /// Image the face material samples: the face-skin role raster with a
    /// hair-coloured scalp underlay.
    public static let faceImageId = "image:face.main"
    /// Image `meta.thumbnailImage` points at.
    public static let thumbnailImageId = "image:thumbnail"

    /// Roles the template's own primitives reference.
    public static let templateIds = [faceSkin, bodySkin, iris, eyeWhite, eyeHighlight, eyeline, eyelash, brow, mouth]

    /// glTF material names in the VRoid naming convention the linter's
    /// `ROLE_PATTERNS` recognise (`docs/style/README.md`).
    public static let names: [String: String] = [
        faceSkin: "Face_00_SKIN", bodySkin: "Body_00_SKIN", iris: "EyeIris_00", eyeWhite: "EyeWhite_00", eyeHighlight: "EyeHighlight_00",
        eyeline: "Eyeline_00", eyelash: "Eyelash_00", brow: "FaceBrow_00", mouth: "FaceMouth_00", hair: "Hair_00",
        clothTop: "Tops_01_CLOTH", clothBottom: "Bottoms_01_CLOTH", clothFootwear: "Shoes_01_CLOTH",
    ]

    static let roles: [(id: String, role: MaterialRole)] = [
        (faceSkin, .faceSkin), (bodySkin, .bodySkin), (iris, .iris), (eyeWhite, .eyeWhite), (eyeHighlight, .eyeHighlight), (eyeline, .eyeline),
        (eyelash, .eyelash), (brow, .brow), (mouth, .mouth), (hair, .hair), (clothTop, .cloth), (clothBottom, .cloth), (clothFootwear, .cloth),
    ]

    /// Role default for `role` under `id`, named, textures pointed at the
    /// template-authored image where one exists.
    static func material(id: String, role: MaterialRole) -> MaterialObject {
        var m = MaterialRoleDefaults.material(id: id, role: role)
        var gltf = m.gltf.object ?? [:]
        gltf["name"] = .string(names[id] ?? id)
        if let image = [hair: hairImageId, faceSkin: faceImageId][id] {
            var pbr = gltf["pbrMetallicRoughness"]?.object ?? [:]
            pbr["baseColorTexture"] = ["imageId": .string(image), "texCoord": 0]
            gltf["pbrMetallicRoughness"] = .object(pbr)
            m.mtoon = m.mtoon.merging(["shadeMultiplyTexture": ["imageId": .string(image), "texCoord": 0]])
        }
        m.gltf = .object(gltf)
        return m
    }

    public static var placeholders: [MaterialObject] { roles.map { material(id: $0.id, role: $0.role) } }
}

/// Default VRM 1.0 preset expressions bound to the head morphs.
public enum NativeAnimeExpressions {
    public static let headMesh = "mesh.head"

    public static func expressionId(_ preset: ExpressionPreset) -> String { "expr." + preset.rawValue }

    public static var defaults: [ExpressionObject] {
        var out: [ExpressionObject] = []
        let bound: [ExpressionPreset] = [.blink, .blinkLeft, .blinkRight, .aa, .ih, .ou, .ee, .oh, .happy, .angry, .sad, .relaxed, .surprised]
        for preset in bound {
            out.append(ExpressionObject(id: expressionId(preset), preset: preset, isBinary: false, overrideBlink: .none, overrideLookAt: .none,
                                        overrideMouth: .none, morphTargetBinds: [MorphTargetBind(mesh: headMesh, target: preset.rawValue, weight: 1)]))
        }
        out.append(ExpressionObject(id: expressionId(.neutral), preset: .neutral))
        return out
    }
}
