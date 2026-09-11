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

public enum LayerKind: String, Codable, Hashable, Sendable, CaseIterable { case solid, image }
public enum BlendMode: String, Codable, Hashable, Sendable, CaseIterable { case normal, multiply, screen }

public struct TextureLayer: AuthorModel {
    public var id: String
    public var targetImage: String
    public var kind: LayerKind
    public var colour: Colour?
    public var image: String?
    public var mask: String?
    public var opacity: Double
    public var blend: BlendMode
    public var uvOffset: [Double]
    public var uvScale: [Double]
    public var uvRotationDeg: Double
    public var enabled: Bool

    public init(id: String, targetImage: String, kind: LayerKind, colour: Colour? = nil, image: String? = nil, mask: String? = nil, opacity: Double = 1,
                blend: BlendMode = .normal, uvOffset: [Double] = [0, 0], uvScale: [Double] = [1, 1], uvRotationDeg: Double = 0, enabled: Bool = true) {
        self.id = id
        self.targetImage = targetImage
        self.kind = kind
        self.colour = colour
        self.image = image
        self.mask = mask
        self.opacity = opacity
        self.blend = blend
        self.uvOffset = uvOffset
        self.uvScale = uvScale
        self.uvRotationDeg = uvRotationDeg
        self.enabled = enabled
    }

    public static let modelName = "Layer"
    public static let schema = JSONSchema.object(properties: [
        "id": .id,
        "targetImage": .id,
        "kind": .enumeration(LayerKind.allCases.map(\.rawValue)),
        "colour": Colour.schema,
        "image": .id,
        "mask": .id,
        "opacity": JSONSchema.unit.defaulting(to: 1),
        "blend": .enumeration(BlendMode.allCases.map(\.rawValue)).defaulting(to: "normal"),
        "uvOffset": .vector(2).unit("uv").defaulting(to: [0, 0]),
        "uvScale": .vector(2).unit("ratio").defaulting(to: [1, 1]),
        "uvRotationDeg": .number().unit("degrees").defaulting(to: 0),
        "enabled": .boolean().defaulting(to: true),
    ], required: ["id", "targetImage", "kind"], description: "Texture compositing layer; array order composites")

    public func validate() throws {
        switch kind {
        case .solid where colour == nil: throw AuthorError.invalidRequest("Solid layers require colour.", path: "/colour")
        case .image where image == nil: throw AuthorError.invalidRequest("Image layers require image.", path: "/image")
        default: break
        }
        try colour?.validate()
        try ModelCheck.range(opacity, 0, 1, "/opacity")
        try ModelCheck.count(uvOffset, 2, "/uvOffset")
        try ModelCheck.count(uvScale, 2, "/uvScale")
        try ModelCheck.finite(uvRotationDeg, "/uvRotationDeg")
    }
}

public enum MaterialRole: String, Codable, Hashable, Sendable, CaseIterable {
    case faceSkin = "face_skin"
    case bodySkin = "body_skin"
    case hair, cloth, accessory, iris
    case eyeWhite = "eye_white"
    case eyeHighlight = "eye_highlight"
    case eyeline, eyelash, brow, mouth, other

    public static let schema = JSONSchema.enumeration(MaterialRole.allCases.map(\.rawValue), description: "Style role")
}

public struct MaterialObject: AuthorModel {
    public var id: String
    public var role: MaterialRole
    public var gltf: JSONValue
    public var mtoon: JSONValue

    public init(id: String, role: MaterialRole, gltf: JSONValue, mtoon: JSONValue) {
        self.id = id
        self.role = role
        self.gltf = gltf
        self.mtoon = mtoon
    }

    public static let modelName = "Material"
    public static var schema: JSONSchema {
        JSONSchema.object(properties: [
            "id": .id,
            "role": MaterialRole.schema,
            "gltf": MaterialSchemas.gltf,
            "mtoon": MaterialSchemas.mtoon,
        ], required: ["id", "role", "gltf", "mtoon"], description: "glTF metallic-roughness and VRMC_materials_mtoon 1.0 fields with texture references by image ID")
    }

    public func validate() throws {
        guard gltf.object != nil else { throw AuthorError.invalidRequest("gltf must be an object.", path: "/gltf") }
        guard mtoon.object != nil else { throw AuthorError.invalidRequest("mtoon must be an object.", path: "/mtoon") }
    }
}
