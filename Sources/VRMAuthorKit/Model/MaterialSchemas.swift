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

/// Leaf schemas for `Material.gltf` (glTF 2.0 metallic-roughness plus
/// KHR_materials_emissive_strength) and `Material.mtoon` (VRMC_materials_mtoon
/// 1.0). Texture slots reference images by stable ID and declare UV set,
/// sampler and KHR_texture_transform explicitly. Every property is a leaf the
/// coverage test enumerates; ranges and defaults follow the pinned schemas.
public enum MaterialSchemas {
    public static let mtoonSpecVersion = "1.0"
    public static let emissiveStrengthExtension = "KHR_materials_emissive_strength"

    // MARK: Texture references

    /// glTF sampler enums: magFilter NEAREST|LINEAR; minFilter adds the four
    /// mipmap modes; wrap CLAMP_TO_EDGE|MIRRORED_REPEAT|REPEAT.
    public static let magFilters: [Int] = [9728, 9729]
    public static let minFilters: [Int] = [9728, 9729, 9984, 9985, 9986, 9987]
    public static let wrapModes: [Int] = [33071, 33648, 10497]

    static func integerEnumeration(_ values: [Int], default def: Int, description: String) -> JSONSchema {
        JSONSchema.integer().with("enum", .array(values.map { .number(Double($0)) })).defaulting(to: .number(Double(def))).described(description)
    }

    public static var sampler: JSONSchema {
        JSONSchema.object(properties: [
            "magFilter": integerEnumeration(magFilters, default: 9729, description: "glTF magnification filter"),
            "minFilter": integerEnumeration(minFilters, default: 9987, description: "glTF minification filter"),
            "wrapS": integerEnumeration(wrapModes, default: 10497, description: "glTF S wrap mode"),
            "wrapT": integerEnumeration(wrapModes, default: 10497, description: "glTF T wrap mode"),
        ], required: [], description: "glTF sampler")
    }

    public static var textureTransform: JSONSchema {
        JSONSchema.object(properties: [
            "offset": .vector(2).unit("uv").defaulting(to: [0, 0]),
            "rotation": .number().unit("radians").defaulting(to: 0),
            "scale": .vector(2).unit("ratio").defaulting(to: [1, 1]),
            "texCoord": .integer(minimum: 0).described("Overrides the slot texCoord when present"),
        ], required: [], description: "KHR_texture_transform")
    }

    static func textureReference(_ extra: [String: JSONSchema] = [:], description: String) -> JSONSchema {
        var props: [String: JSONSchema] = [
            "imageId": .id.described("Stable image ID replacing the export texture index"),
            "texCoord": .integer(minimum: 0).defaulting(to: 0).described("UV set"),
            "sampler": sampler,
            "transform": textureTransform,
        ]
        for (k, v) in extra { props[k] = v }
        return JSONSchema.object(properties: props, required: ["imageId"], description: description)
    }

    public static var textureInfo: JSONSchema { textureReference(description: "Texture slot") }

    static func colour3(default def: [Double], description: String) -> JSONSchema {
        JSONSchema.vector(3, minimum: 0, maximum: 1).unit("linear").defaulting(to: JSONValue(def)).described(description)
    }

    // MARK: glTF 2.0 material

    public static let alphaModes = ["OPAQUE", "MASK", "BLEND"]

    public static var gltf: JSONSchema {
        let pbr = JSONSchema.object(properties: [
            "baseColorFactor": JSONSchema.vector(4, minimum: 0, maximum: 1).unit("linear").defaulting(to: [1, 1, 1, 1]).described("Linear RGBA base colour multiplier"),
            "baseColorTexture": textureReference(description: "sRGB base colour texture"),
            "metallicFactor": JSONSchema.number(minimum: 0, maximum: 1).defaulting(to: 1).described("Metalness"),
            "roughnessFactor": JSONSchema.number(minimum: 0, maximum: 1).defaulting(to: 1).described("Roughness"),
            "metallicRoughnessTexture": textureReference(description: "Metallic (B) / roughness (G) texture"),
        ], required: [], description: "glTF pbrMetallicRoughness")
        let emissiveStrength = JSONSchema.object(properties: [
            "emissiveStrength": JSONSchema.number(minimum: 0).defaulting(to: 1).described("Emissive multiplier"),
        ], required: [], description: "KHR_materials_emissive_strength")
        return JSONSchema.object(properties: [
            "pbrMetallicRoughness": pbr,
            "normalTexture": textureReference(["scale": JSONSchema.number().defaulting(to: 1).described("Normal scale")], description: "Tangent-space normal texture"),
            "occlusionTexture": textureReference(["strength": JSONSchema.number(minimum: 0, maximum: 1).defaulting(to: 1).described("Occlusion strength")], description: "Occlusion (R) texture"),
            "emissiveTexture": textureReference(description: "sRGB emissive texture"),
            "emissiveFactor": colour3(default: [0, 0, 0], description: "Linear emissive colour"),
            "alphaMode": JSONSchema.enumeration(alphaModes).defaulting(to: "OPAQUE"),
            "alphaCutoff": JSONSchema.number(minimum: 0).defaulting(to: 0.5).described("MASK threshold"),
            "doubleSided": JSONSchema.boolean().defaulting(to: false),
            "extensions": JSONSchema.object(properties: [emissiveStrengthExtension: emissiveStrength], required: [], description: "Supported glTF material extensions; any other extension is rejected"),
        ], required: [], description: "glTF 2.0 material fields (pbrMetallicRoughness, normal/emissive/occlusion textures, alphaMode/alphaCutoff/doubleSided, KHR_materials_emissive_strength)")
    }

    // MARK: VRMC_materials_mtoon 1.0

    public static let outlineWidthModes = ["none", "worldCoordinates", "screenCoordinates"]

    public static var mtoon: JSONSchema {
        JSONSchema.object(properties: [
            "specVersion": JSONSchema.const(.string(mtoonSpecVersion)).defaulting(to: .string(mtoonSpecVersion)),
            "transparentWithZWrite": JSONSchema.boolean().defaulting(to: false).described("Depth write for BLEND materials"),
            "renderQueueOffsetNumber": JSONSchema.integer(minimum: -9, maximum: 9).defaulting(to: 0).described("[-9,0] without z-write, [0,9] with z-write"),
            "shadeColorFactor": colour3(default: [1, 1, 1], description: "Linear shade colour"),
            "shadeMultiplyTexture": textureReference(description: "sRGB shade multiply texture"),
            "shadingShiftFactor": JSONSchema.number(minimum: -1, maximum: 1).unit("normalized").defaulting(to: 0).described("Lighting shift"),
            "shadingShiftTexture": textureReference(["scale": JSONSchema.number().defaulting(to: 1).described("Shading shift texture scale")], description: "Linear shading shift texture (R)"),
            "shadingToonyFactor": JSONSchema.number(minimum: 0, maximum: 1).unit("normalized").defaulting(to: 0.9).described("Terminator sharpness"),
            "giEqualizationFactor": JSONSchema.number(minimum: 0, maximum: 1).unit("normalized").defaulting(to: 0.9).described("Global illumination equalization"),
            "matcapFactor": colour3(default: [1, 1, 1], description: "Linear matcap multiplier"),
            "matcapTexture": textureReference(description: "sRGB matcap texture"),
            "parametricRimColorFactor": colour3(default: [0, 0, 0], description: "Linear parametric rim colour"),
            "rimMultiplyTexture": textureReference(description: "sRGB rim multiply texture"),
            "rimLightingMixFactor": JSONSchema.number(minimum: 0, maximum: 1).unit("normalized").defaulting(to: 1).described("Rim lighting mix"),
            "parametricRimFresnelPowerFactor": JSONSchema.number(minimum: 0).defaulting(to: 5).described("Rim fresnel power"),
            "parametricRimLiftFactor": JSONSchema.number().defaulting(to: 0).described("Rim lift"),
            "outlineWidthMode": JSONSchema.enumeration(outlineWidthModes).defaulting(to: "none"),
            "outlineWidthFactor": JSONSchema.number(minimum: 0).unit("metres").defaulting(to: 0).described("Metres for worldCoordinates; normalized for screenCoordinates"),
            "outlineWidthMultiplyTexture": textureReference(description: "Linear outline width multiply texture (G)"),
            "outlineColorFactor": colour3(default: [0, 0, 0], description: "Linear outline colour"),
            "outlineLightingMixFactor": JSONSchema.number(minimum: 0, maximum: 1).unit("normalized").defaulting(to: 1).described("Outline lighting mix"),
            "uvAnimationMaskTexture": textureReference(description: "Linear UV animation mask (B)"),
            "uvAnimationScrollXSpeedFactor": JSONSchema.number().unit("uv/second").defaulting(to: 0),
            "uvAnimationScrollYSpeedFactor": JSONSchema.number().unit("uv/second").defaulting(to: 0),
            "uvAnimationRotationSpeedFactor": JSONSchema.number().unit("radians/second").defaulting(to: 0),
        ], required: [], description: "VRMC_materials_mtoon 1.0 fields")
    }

    /// Texture slot pointers inside `gltf` and `mtoon`, relative to the material object.
    public static let gltfTextureSlots = ["/gltf/pbrMetallicRoughness/baseColorTexture", "/gltf/pbrMetallicRoughness/metallicRoughnessTexture",
                                          "/gltf/normalTexture", "/gltf/occlusionTexture", "/gltf/emissiveTexture"]
    public static let mtoonTextureSlots = ["/mtoon/shadeMultiplyTexture", "/mtoon/shadingShiftTexture", "/mtoon/matcapTexture", "/mtoon/rimMultiplyTexture",
                                           "/mtoon/outlineWidthMultiplyTexture", "/mtoon/uvAnimationMaskTexture"]
    public static var textureSlots: [String] { gltfTextureSlots + mtoonTextureSlots }
}
