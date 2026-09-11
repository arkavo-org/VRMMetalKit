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

/// Placeholder MToon materials keyed by style role. Colour-only (no textures);
/// the materials area replaces leaves and textures through the recipe.
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

    /// Roles the template's own primitives reference.
    public static let templateIds = [faceSkin, bodySkin, iris, eyeWhite, eyeHighlight, eyeline, eyelash, brow, mouth]

    /// Strips texture-slot leaves (`*Texture`) so colour-only placeholders never
    /// reference images the template does not compile.
    static func withoutTextures(_ value: JSONValue) -> JSONValue {
        guard let o = value.object else { return value }
        var out: [String: JSONValue] = [:]
        for (k, v) in o where !k.hasSuffix("Texture") { out[k] = withoutTextures(v) }
        return .object(out)
    }

    /// The materials area's calibrated factors for `role`, textures removed,
    /// base/shade colours overridden and schema defaults applied so the result
    /// is a fixed point of `MaterialObject.decode`.
    static func material(id: String, role: MaterialRole, base: [Double], shade: [Double], outline: Bool, emissive: [Double] = [0, 0, 0]) -> MaterialObject {
        var gltf = withoutTextures(MaterialRoleDefaults.gltf(for: role)).object ?? [:]
        var pbr = gltf["pbrMetallicRoughness"]?.object ?? [:]
        pbr["baseColorFactor"] = JSONValue(base + [1])
        gltf["pbrMetallicRoughness"] = .object(pbr)
        gltf["emissiveFactor"] = JSONValue(emissive)
        var mtoon = withoutTextures(MaterialRoleDefaults.mtoon(for: role)).object ?? [:]
        mtoon["shadeColorFactor"] = JSONValue(shade)
        if !outline {
            mtoon["outlineWidthMode"] = "none"
            mtoon["outlineWidthFactor"] = 0
        }
        return MaterialObject(id: id, role: role, gltf: MaterialSchemas.gltf.applyingDefaults(to: .object(gltf)),
                              mtoon: MaterialSchemas.mtoon.applyingDefaults(to: .object(mtoon)))
    }

    public static var placeholders: [MaterialObject] {
        [
            material(id: faceSkin, role: .faceSkin, base: [1.0, 0.75, 0.62], shade: [0.85, 0.52, 0.45], outline: true),
            material(id: bodySkin, role: .bodySkin, base: [1.0, 0.75, 0.62], shade: [0.85, 0.52, 0.45], outline: true),
            material(id: iris, role: .iris, base: [0.20, 0.35, 0.60], shade: [0.10, 0.18, 0.35], outline: false),
            material(id: eyeWhite, role: .eyeWhite, base: [1, 1, 1], shade: [0.75, 0.75, 0.80], outline: false),
            material(id: eyeHighlight, role: .eyeHighlight, base: [1, 1, 1], shade: [1, 1, 1], outline: false, emissive: [1, 1, 1]),
            material(id: eyeline, role: .eyeline, base: [0.15, 0.08, 0.08], shade: [0.10, 0.05, 0.05], outline: false),
            material(id: eyelash, role: .eyelash, base: [0.12, 0.06, 0.06], shade: [0.08, 0.04, 0.04], outline: false),
            material(id: brow, role: .brow, base: [0.30, 0.18, 0.12], shade: [0.20, 0.12, 0.08], outline: false),
            material(id: mouth, role: .mouth, base: [0.55, 0.18, 0.20], shade: [0.35, 0.10, 0.12], outline: false),
            material(id: hair, role: .hair, base: [0.35, 0.22, 0.15], shade: [0.22, 0.13, 0.09], outline: true),
            material(id: clothTop, role: .cloth, base: [0.85, 0.85, 0.90], shade: [0.55, 0.55, 0.62], outline: true),
            material(id: clothBottom, role: .cloth, base: [0.20, 0.25, 0.40], shade: [0.12, 0.15, 0.25], outline: true),
            material(id: clothFootwear, role: .cloth, base: [0.15, 0.12, 0.12], shade: [0.08, 0.06, 0.06], outline: true),
        ]
    }
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
