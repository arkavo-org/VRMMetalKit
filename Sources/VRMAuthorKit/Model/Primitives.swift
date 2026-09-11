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

public enum ColourSpace: String, Codable, Hashable, Sendable, CaseIterable { case linear, srgb }

public struct Colour: AuthorModel {
    public var rgba: [Double]
    public var space: ColourSpace

    public init(rgba: [Double], space: ColourSpace = .linear) {
        self.rgba = rgba
        self.space = space
    }

    public static let modelName = "Colour"
    public static let schema = JSONSchema.object(properties: [
        "rgba": .vector(4, minimum: 0, maximum: 1).unit("normalized"),
        "space": .enumeration(ColourSpace.allCases.map(\.rawValue)).defaulting(to: "linear"),
    ], required: ["rgba"], description: "RGBA colour with components in [0,1]")

    public func validate() throws {
        try ModelCheck.count(rgba, 4, "/rgba")
        for (i, c) in rgba.enumerated() { try ModelCheck.range(c, 0, 1, "/rgba/\(i)") }
    }
}

public struct Transform: AuthorModel {
    public var translation: [Double]
    public var rotation: [Double]
    public var scale: [Double]

    public init(translation: [Double] = [0, 0, 0], rotation: [Double] = [0, 0, 0, 1], scale: [Double] = [1, 1, 1]) {
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
    }

    public static let identity = Transform()
    public static let modelName = "Transform"
    public static let schema = JSONSchema.object(properties: [
        "translation": .vector(3).unit("metres").defaulting(to: [0, 0, 0]),
        "rotation": .vector(4, minimum: -1, maximum: 1).unit("quaternion").defaulting(to: [0, 0, 0, 1]),
        "scale": .vector(3, exclusiveMinimum: 0).unit("ratio").defaulting(to: [1, 1, 1]),
    ], required: [], description: "Translation metres, unit quaternion, positive scale")

    public func validate() throws {
        try ModelCheck.count(translation, 3, "/translation")
        try ModelCheck.count(rotation, 4, "/rotation")
        try ModelCheck.count(scale, 3, "/scale")
        let length = rotation.map { $0 * $0 }.reduce(0, +).squareRoot()
        guard abs(length - 1) <= 1e-6 else {
            throw AuthorError.invalidRequest("Rotation must be a unit quaternion.", path: "/rotation", observed: .number(length), required: 1)
        }
        for (i, s) in scale.enumerated() where s <= 0 {
            throw AuthorError.invalidRequest("Scale components must be positive.", path: "/scale/\(i)", observed: .number(s))
        }
    }
}

extension JSONSchema {
    static func vector(_ count: Int, exclusiveMinimum: Double) -> JSONSchema {
        array(of: .number(exclusiveMinimum: exclusiveMinimum), minItems: count, maxItems: count)
    }
}

public struct Blob: AuthorModel {
    public var path: String
    public var sha256: String

    public init(path: String, sha256: String) {
        self.path = path
        self.sha256 = sha256
    }

    public static let modelName = "Blob"
    public static let schema = JSONSchema.object(properties: ["path": .path, "sha256": .hash], required: ["path", "sha256"], description: "Hash-pinned file reference")

    public func validate() throws {
        guard SHA256Hex.isValid(sha256) else { throw AuthorError.invalidRequest("sha256 must be 64 lowercase hex characters.", path: "/sha256", observed: .string(sha256)) }
    }
}

public enum ObjectKind: String, Codable, Hashable, Sendable, CaseIterable {
    case avatar, mesh, material, image
    case textureLayer = "texture-layer"
    case hair, garment, accessory, node, humanoid, expression, lookat, firstperson, spring, collider
    case colliderGroup = "collider-group"

    public static let schema = JSONSchema.enumeration(ObjectKind.allCases.map(\.rawValue), description: "Project object kind")
}

public struct ControlEdit: AuthorModel {
    public var object: String
    public var values: [String: JSONValue]

    public init(object: String, values: [String: JSONValue]) {
        self.object = object
        self.values = values
    }

    public static let modelName = "ControlEdit"
    public static let schema = JSONSchema.object(properties: [
        "object": .id,
        "values": .map(of: .any(description: "Typed control value"), description: "controlKey → value"),
    ], required: ["object", "values"], description: "Calibrated control edit on one object")

    public func validate() throws {
        guard !values.isEmpty else { throw AuthorError.invalidRequest("ControlEdit.values must not be empty.", path: "/values") }
        for (key, value) in values {
            if let n = value.number, !n.isFinite { throw AuthorError.invalidRequest("Non-finite control value.", path: "/values/\(JSONPointer.escape(key))") }
        }
    }
}

public struct ObjectEdit: AuthorModel {
    public var id: String
    public var values: [String: JSONValue]

    public init(id: String, values: [String: JSONValue]) {
        self.id = id
        self.values = values
    }

    public static let modelName = "ObjectEdit"
    public static let schema = JSONSchema.object(properties: [
        "id": .id,
        "values": .map(of: .any(description: "Typed field value"), description: "RFC 6901 pointer → value"),
    ], required: ["id", "values"], description: "Typed field edits on one existing object")

    public func validate() throws {
        guard !values.isEmpty else { throw AuthorError.invalidRequest("ObjectEdit.values must not be empty.", path: "/values") }
        for key in values.keys { _ = try JSONPointer(key) }
    }
}

public enum ImageUsage: String, Codable, Hashable, Sendable, CaseIterable { case colour, normal, mask }

public struct ImageSpec: AuthorModel {
    public var id: String
    public var width: Int
    public var height: Int
    public var colourSpace: ColourSpace
    public var usage: ImageUsage

    public init(id: String, width: Int, height: Int, colourSpace: ColourSpace, usage: ImageUsage) {
        self.id = id
        self.width = width
        self.height = height
        self.colourSpace = colourSpace
        self.usage = usage
    }

    public static let modelName = "Image"
    public static let schema = JSONSchema.object(properties: [
        "id": .id,
        "width": .integer(minimum: 1, maximum: 4096).unit("pixels"),
        "height": .integer(minimum: 1, maximum: 4096).unit("pixels"),
        "colourSpace": .enumeration(ColourSpace.allCases.map(\.rawValue)),
        "usage": .enumeration(ImageUsage.allCases.map(\.rawValue)),
    ], required: ["id", "width", "height", "colourSpace", "usage"], description: "Composited image target")
}
