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

public struct HairControls: AuthorModel {
    public var lengthM: Double
    public var widthScale: Double
    public var tipBendDeg: Double
    public var bangClearanceM: Double

    public init(lengthM: Double = 0.18, widthScale: Double = 1, tipBendDeg: Double = 12, bangClearanceM: Double = 0.005) {
        self.lengthM = lengthM
        self.widthScale = widthScale
        self.tipBendDeg = tipBendDeg
        self.bangClearanceM = bangClearanceM
    }

    public static let modelName = "HairControls"
    public static let schema = JSONSchema.object(properties: [
        "lengthM": .number(minimum: 0.12, maximum: 0.30).unit("metres").defaulting(to: 0.18).described("Calibrated guide extension and regenerated bone positions"),
        "widthScale": .number(minimum: 0.75, maximum: 1.25).unit("ratio").defaulting(to: 1).described("Clump width deformation"),
        "tipBendDeg": .number(minimum: -20, maximum: 30).unit("degrees").defaulting(to: 12).described("Template tip bend"),
        "bangClearanceM": .number(minimum: 0.002, maximum: 0.02).unit("metres").defaulting(to: 0.005).described("Forehead/eye clearance"),
    ], required: [], description: "bob-v1 hair controls")

    public func validate() throws {
        try ModelCheck.range(lengthM, 0.12, 0.30, "/lengthM")
        try ModelCheck.range(widthScale, 0.75, 1.25, "/widthScale")
        try ModelCheck.range(tipBendDeg, -20, 30, "/tipBendDeg")
        try ModelCheck.range(bangClearanceM, 0.002, 0.02, "/bangClearanceM")
    }
}

public struct HairTexture: AuthorModel {
    public var baseColour: Colour
    public var rootColour: Colour
    public var tipColour: Colour
    public var highlightOpacity: Double
    public var highlightWidth: Double

    public init(baseColour: Colour, rootColour: Colour, tipColour: Colour, highlightOpacity: Double = 0.25, highlightWidth: Double = 0.12) {
        self.baseColour = baseColour
        self.rootColour = rootColour
        self.tipColour = tipColour
        self.highlightOpacity = highlightOpacity
        self.highlightWidth = highlightWidth
    }

    public static let modelName = "HairTexture"
    public static let schema = JSONSchema.object(properties: [
        "baseColour": Colour.schema,
        "rootColour": Colour.schema,
        "tipColour": Colour.schema,
        "highlightOpacity": JSONSchema.unit.defaulting(to: 0.25),
        "highlightWidth": JSONSchema.unit.defaulting(to: 0.12),
    ], required: ["baseColour", "rootColour", "tipColour"], description: "Longitudinal hair gradient and highlight")

    public func validate() throws {
        try baseColour.validate()
        try rootColour.validate()
        try tipColour.validate()
        try ModelCheck.range(highlightOpacity, 0, 1, "/highlightOpacity")
        try ModelCheck.range(highlightWidth, 0, 1, "/highlightWidth")
    }
}

public struct HairItem: AuthorModel {
    public var id: String
    public var preset: String
    public var controls: HairControls
    public var texture: HairTexture

    public init(id: String, preset: String = "bob-v1", controls: HairControls, texture: HairTexture) {
        self.id = id
        self.preset = preset
        self.controls = controls
        self.texture = texture
    }

    public static let presets = ["bob-v1"]
    public static let modelName = "HairItem"
    public static let schema = JSONSchema.object(properties: [
        "id": .id,
        "preset": .enumeration(HairItem.presets),
        "controls": HairControls.schema,
        "texture": HairTexture.schema,
    ], required: ["id", "preset", "controls", "texture"], description: "Installed hair preset instance")

    public func validate() throws {
        guard HairItem.presets.contains(preset) else { throw AuthorError.invalidRequest("Unknown hair preset.", path: "/preset", observed: .string(preset)) }
        try controls.validate()
        try texture.validate()
    }
}

public struct OutfitControls: AuthorModel {
    public var length: Double
    public var fit: Double

    public init(length: Double = 0, fit: Double = 0) {
        self.length = length
        self.fit = fit
    }

    public static let modelName = "OutfitControls"
    public static let schema = JSONSchema.object(properties: ["length": .bipolar, "fit": .bipolar], required: [], description: "Garment length and fit blends")

    public func validate() throws {
        try ModelCheck.range(length, -1, 1, "/length")
        try ModelCheck.range(fit, -1, 1, "/fit")
    }
}

public struct OutfitItem: AuthorModel {
    public var id: String
    public var preset: String
    public var enabled: Bool
    public var layer: Int
    public var controls: OutfitControls
    public var materialIds: [String]

    public init(id: String, preset: String, enabled: Bool = true, layer: Int = 0, controls: OutfitControls = OutfitControls(), materialIds: [String]) {
        self.id = id
        self.preset = preset
        self.enabled = enabled
        self.layer = layer
        self.controls = controls
        self.materialIds = materialIds
    }

    public static let modelName = "OutfitItem"
    public static let schema = JSONSchema.object(properties: [
        "id": .id,
        "preset": .id.described("Installed top/bottom/footwear preset"),
        "enabled": .boolean().defaulting(to: true),
        "layer": .integer(minimum: 0, maximum: 8).defaulting(to: 0),
        "controls": OutfitControls.schema,
        "materialIds": .idList,
    ], required: ["id", "preset", "controls", "materialIds"], description: "Installed outfit preset instance")

    public func validate() throws {
        guard (0...8).contains(layer) else { throw AuthorError.invalidRequest("layer must be within [0,8].", path: "/layer", observed: .number(Double(layer))) }
        try controls.validate()
    }
}

public enum AccessoryPreset: String, Codable, Hashable, Sendable, CaseIterable {
    case glassesV1 = "glasses-v1"
    case earringV1 = "earring-v1"
}

public struct AccessoryItem: AuthorModel {
    public var id: String
    public var preset: AccessoryPreset
    public var attachment: String
    public var transform: Transform
    public var materialIds: [String]
    public var enabled: Bool

    public init(id: String, preset: AccessoryPreset, attachment: String, transform: Transform = .identity, materialIds: [String], enabled: Bool = true) {
        self.id = id
        self.preset = preset
        self.attachment = attachment
        self.transform = transform
        self.materialIds = materialIds
        self.enabled = enabled
    }

    public static let modelName = "AccessoryItem"
    public static let schema = JSONSchema.object(properties: [
        "id": .id,
        "preset": .enumeration(of: AccessoryPreset.self),
        "attachment": .id.described("Declared rig node"),
        "transform": Transform.schema.defaulting(to: ["translation": [0, 0, 0], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1]]),
        "materialIds": .idList,
        "enabled": .boolean().defaulting(to: true),
    ], required: ["id", "preset", "attachment", "materialIds"], description: "Installed accessory preset instance")

    public func validate() throws { try transform.validate() }
}
