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

public enum ExpressionPreset: String, Codable, Hashable, Sendable, CaseIterable {
    case happy, angry, sad, relaxed, surprised, aa, ih, ou, ee, oh, blink, blinkLeft, blinkRight, lookUp, lookDown, lookLeft, lookRight, neutral
}

public enum ExpressionOverride: String, Codable, Hashable, Sendable, CaseIterable { case none, block, blend }

public enum MaterialColorType: String, Codable, Hashable, Sendable, CaseIterable {
    case color, emissionColor, shadeColor, matcapColor, rimColor, outlineColor
}

public struct MorphTargetBind: AuthorModel {
    public var mesh: String
    public var target: String
    public var weight: Double

    public init(mesh: String, target: String, weight: Double) {
        self.mesh = mesh
        self.target = target
        self.weight = weight
    }

    public static let modelName = "MorphTargetBind"
    public static let schema = JSONSchema.object(properties: [
        "mesh": .id, "target": .string(minLength: 1, description: "Morph target name"), "weight": JSONSchema.unit,
    ], required: ["mesh", "target", "weight"])

    public func validate() throws { try ModelCheck.range(weight, 0, 1, "/weight") }
}

public struct MaterialColorBind: AuthorModel {
    public var material: String
    public var type: MaterialColorType
    public var targetValue: [Double]

    public init(material: String, type: MaterialColorType, targetValue: [Double]) {
        self.material = material
        self.type = type
        self.targetValue = targetValue
    }

    public static let modelName = "MaterialColorBind"
    public static let schema = JSONSchema.object(properties: [
        "material": .id, "type": .enumeration(of: MaterialColorType.self), "targetValue": .vector(4, minimum: 0, maximum: 1),
    ], required: ["material", "type", "targetValue"])

    public func validate() throws { try ModelCheck.count(targetValue, 4, "/targetValue") }
}

public struct TextureTransformBind: AuthorModel {
    public var material: String
    public var scale: [Double]
    public var offset: [Double]

    public init(material: String, scale: [Double] = [1, 1], offset: [Double] = [0, 0]) {
        self.material = material
        self.scale = scale
        self.offset = offset
    }

    public static let modelName = "TextureTransformBind"
    public static let schema = JSONSchema.object(properties: [
        "material": .id, "scale": .vector(2).defaulting(to: [1, 1]), "offset": .vector(2).defaulting(to: [0, 0]),
    ], required: ["material"])

    public func validate() throws {
        try ModelCheck.count(scale, 2, "/scale")
        try ModelCheck.count(offset, 2, "/offset")
    }
}

public struct ExpressionObject: AuthorModel {
    public var id: String
    public var preset: ExpressionPreset?
    public var name: String?
    public var isBinary: Bool
    public var overrideBlink: ExpressionOverride
    public var overrideLookAt: ExpressionOverride
    public var overrideMouth: ExpressionOverride
    public var morphTargetBinds: [MorphTargetBind]
    public var materialColorBinds: [MaterialColorBind]
    public var textureTransformBinds: [TextureTransformBind]

    public init(id: String, preset: ExpressionPreset? = nil, name: String? = nil, isBinary: Bool = false, overrideBlink: ExpressionOverride = .none,
                overrideLookAt: ExpressionOverride = .none, overrideMouth: ExpressionOverride = .none, morphTargetBinds: [MorphTargetBind] = [],
                materialColorBinds: [MaterialColorBind] = [], textureTransformBinds: [TextureTransformBind] = []) {
        self.id = id
        self.preset = preset
        self.name = name
        self.isBinary = isBinary
        self.overrideBlink = overrideBlink
        self.overrideLookAt = overrideLookAt
        self.overrideMouth = overrideMouth
        self.morphTargetBinds = morphTargetBinds
        self.materialColorBinds = materialColorBinds
        self.textureTransformBinds = textureTransformBinds
    }

    public static let modelName = "Expression"
    public static let schema = JSONSchema.object(properties: [
        "id": .id,
        "preset": .enumeration(of: ExpressionPreset.self).described("VRM 1.0 preset name; exclusive with name"),
        "name": .string(minLength: 1, description: "Custom expression name; exclusive with preset"),
        "isBinary": .boolean().defaulting(to: false),
        "overrideBlink": .enumeration(of: ExpressionOverride.self).defaulting(to: "none"),
        "overrideLookAt": .enumeration(of: ExpressionOverride.self).defaulting(to: "none"),
        "overrideMouth": .enumeration(of: ExpressionOverride.self).defaulting(to: "none"),
        "morphTargetBinds": .array(of: MorphTargetBind.schema).defaulting(to: []),
        "materialColorBinds": .array(of: MaterialColorBind.schema).defaulting(to: []),
        "textureTransformBinds": .array(of: TextureTransformBind.schema).defaulting(to: []),
    ], required: ["id"], description: "VRMC_vrm expression with binds referencing stable IDs")

    public func validate() throws {
        guard (preset == nil) != (name == nil) else {
            throw AuthorError.invalidRequest("Expression requires exactly one of preset or name.", path: "/preset")
        }
        for b in morphTargetBinds { try b.validate() }
        for b in materialColorBinds { try b.validate() }
        for b in textureTransformBinds { try b.validate() }
    }
}

public enum LookAtType: String, Codable, Hashable, Sendable, CaseIterable { case bone, expression }

public struct LookAtRangeMap: AuthorModel {
    public var inputMaxValue: Double
    public var outputScale: Double

    public init(inputMaxValue: Double = 90, outputScale: Double = 10) {
        self.inputMaxValue = inputMaxValue
        self.outputScale = outputScale
    }

    public static let modelName = "LookAtRangeMap"
    public static let schema = JSONSchema.object(properties: [
        "inputMaxValue": .number(minimum: 0, maximum: 90).unit("degrees").defaulting(to: 90),
        "outputScale": .number(minimum: 0).defaulting(to: 10).described("Degrees for bone type, expression weight for expression type"),
    ], required: [])

    public func validate() throws {
        try ModelCheck.range(inputMaxValue, 0, 90, "/inputMaxValue")
        try ModelCheck.finite(outputScale, "/outputScale")
    }
}

public struct LookAtObject: AuthorModel {
    public var offsetFromHeadBone: [Double]
    public var type: LookAtType
    public var rangeMapHorizontalInner: LookAtRangeMap
    public var rangeMapHorizontalOuter: LookAtRangeMap
    public var rangeMapVerticalDown: LookAtRangeMap
    public var rangeMapVerticalUp: LookAtRangeMap

    public init(offsetFromHeadBone: [Double] = [0, 0, 0], type: LookAtType = .bone, rangeMapHorizontalInner: LookAtRangeMap = LookAtRangeMap(),
                rangeMapHorizontalOuter: LookAtRangeMap = LookAtRangeMap(), rangeMapVerticalDown: LookAtRangeMap = LookAtRangeMap(),
                rangeMapVerticalUp: LookAtRangeMap = LookAtRangeMap()) {
        self.offsetFromHeadBone = offsetFromHeadBone
        self.type = type
        self.rangeMapHorizontalInner = rangeMapHorizontalInner
        self.rangeMapHorizontalOuter = rangeMapHorizontalOuter
        self.rangeMapVerticalDown = rangeMapVerticalDown
        self.rangeMapVerticalUp = rangeMapVerticalUp
    }

    public static let modelName = "LookAt"
    public static let schema = JSONSchema.object(properties: [
        "offsetFromHeadBone": .vector(3).unit("metres").defaulting(to: [0, 0, 0]),
        "type": .enumeration(of: LookAtType.self).defaulting(to: "bone"),
        "rangeMapHorizontalInner": LookAtRangeMap.schema.defaulting(to: ["inputMaxValue": 90, "outputScale": 10]),
        "rangeMapHorizontalOuter": LookAtRangeMap.schema.defaulting(to: ["inputMaxValue": 90, "outputScale": 10]),
        "rangeMapVerticalDown": LookAtRangeMap.schema.defaulting(to: ["inputMaxValue": 90, "outputScale": 10]),
        "rangeMapVerticalUp": LookAtRangeMap.schema.defaulting(to: ["inputMaxValue": 90, "outputScale": 10]),
    ], required: [], description: "VRMC_vrm lookAt")

    public func validate() throws {
        try ModelCheck.count(offsetFromHeadBone, 3, "/offsetFromHeadBone")
        try rangeMapHorizontalInner.validate()
        try rangeMapHorizontalOuter.validate()
        try rangeMapVerticalDown.validate()
        try rangeMapVerticalUp.validate()
    }
}

public enum FirstPersonType: String, Codable, Hashable, Sendable, CaseIterable { case auto, both, thirdPersonOnly, firstPersonOnly }

public struct MeshAnnotation: AuthorModel {
    public var mesh: String
    public var type: FirstPersonType

    public init(mesh: String, type: FirstPersonType) {
        self.mesh = mesh
        self.type = type
    }

    public static let modelName = "MeshAnnotation"
    public static let schema = JSONSchema.object(properties: [
        "mesh": .id, "type": .enumeration(of: FirstPersonType.self),
    ], required: ["mesh", "type"])
}

public struct FirstPersonObject: AuthorModel {
    public var meshAnnotations: [MeshAnnotation]

    public init(meshAnnotations: [MeshAnnotation] = []) { self.meshAnnotations = meshAnnotations }

    public static let modelName = "FirstPerson"
    public static let schema = JSONSchema.object(properties: [
        "meshAnnotations": .array(of: MeshAnnotation.schema).defaulting(to: []),
    ], required: [], description: "VRMC_vrm firstPerson")

    public func validate() throws { try ModelCheck.uniqueIds(meshAnnotations.map(\.mesh), "/meshAnnotations") }
}
