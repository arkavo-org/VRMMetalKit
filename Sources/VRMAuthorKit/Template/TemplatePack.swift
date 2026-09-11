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

public enum TemplateCategory: String, Codable, Hashable, Sendable, CaseIterable { case avatar, hair, outfit, accessory }

public enum ControlUnit: String, Codable, Hashable, Sendable, CaseIterable { case metres, degrees, radians, normalized, ratio }

public enum ControlSide: String, Codable, Hashable, Sendable, CaseIterable { case none, left, right }

/// Full descriptor for one control key, returned by `control describe`.
public struct ControlDescriptor: Codable, Hashable, Sendable {
    public var key: String
    public var unit: ControlUnit
    public var validRange: [Double]
    public var recommendedRange: [Double]
    public var defaultValue: Double
    public var side: ControlSide
    public var mirrorKey: String?
    public var affects: [ObjectKind]
    public var dependencies: [String]
    public var description: String

    public init(key: String, unit: ControlUnit, validRange: [Double], recommendedRange: [Double], defaultValue: Double, side: ControlSide = .none,
                mirrorKey: String? = nil, affects: [ObjectKind], dependencies: [String] = [], description: String) {
        self.key = key
        self.unit = unit
        self.validRange = validRange
        self.recommendedRange = recommendedRange
        self.defaultValue = defaultValue
        self.side = side
        self.mirrorKey = mirrorKey
        self.affects = affects
        self.dependencies = dependencies
        self.description = description
    }

    public var schema: JSONSchema {
        JSONSchema.number(minimum: validRange.first, maximum: validRange.last).unit(unit.rawValue).defaulting(to: .number(defaultValue))
            .recommended(minimum: recommendedRange.first ?? validRange.first ?? 0, maximum: recommendedRange.last ?? validRange.last ?? 0)
            .described(description)
    }

    public func accepts(_ value: Double) -> Bool {
        value.isFinite && validRange.count == 2 && value >= validRange[0] && value <= validRange[1]
    }
}

/// An installable item inside a pack (hair preset, outfit preset, accessory preset).
public struct TemplateItem: Codable, Hashable, Sendable {
    public var id: String
    public var category: TemplateCategory
    public var sha256: String
    public var controls: [ControlDescriptor]

    public init(id: String, category: TemplateCategory, sha256: String, controls: [ControlDescriptor]) {
        self.id = id
        self.category = category
        self.sha256 = sha256
        self.controls = controls
    }
}

public protocol TemplatePack: Sendable {
    var id: String { get }
    /// sha256 of the pack manifest.
    var sha256: String { get }
    var category: TemplateCategory { get }
    var controls: [ControlDescriptor] { get }
    var items: [TemplateItem] { get }
    var defaults: Recipe { get }
    func compile(_ recipe: Recipe, seed: UInt64) throws -> CompiledAvatar
}

extension TemplatePack {
    public var category: TemplateCategory { .avatar }
    public var items: [TemplateItem] { [] }
    public func control(_ key: String) -> ControlDescriptor? { controls.first { $0.key == key } }
}

public struct TemplateRegistry: Sendable {
    public private(set) var packs: [String: any TemplatePack]

    public init(packs: [any TemplatePack]) {
        var table: [String: any TemplatePack] = [:]
        for pack in packs { table[pack.id] = pack }
        self.packs = table
    }

    /// All built-in packs; see BuiltinPacks.swift for the registration point.
    public static func standard() -> TemplateRegistry { TemplateRegistry(packs: TemplateRegistry.builtinPacks) }

    public var ids: [String] { packs.keys.sorted() }
    public func pack(id: String) -> (any TemplatePack)? { packs[id] }
    public mutating func register(_ pack: any TemplatePack) throws {
        guard packs[pack.id] == nil else { throw RegistryError(description: "template pack '\(pack.id)' already registered") }
        packs[pack.id] = pack
    }

    public func templateHashes() -> [String: String] {
        var out: [String: String] = [:]
        for (id, pack) in packs { out[id] = pack.sha256 }
        return out
    }
}
