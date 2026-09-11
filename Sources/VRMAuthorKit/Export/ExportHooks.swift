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

/// Outcome of resolving a recipe's rights declaration into VRM metadata.
public struct RightsResolution: Codable, Hashable, Sendable {
    public var meta: VRMMeta
    public var attribution: JSONValue
    public var conflicts: [AuthorError]

    public init(meta: VRMMeta, attribution: JSONValue = [:], conflicts: [AuthorError] = []) {
        self.meta = meta
        self.attribution = attribution
        self.conflicts = conflicts
    }
}

/// The rights resolver `recipe apply` invokes before materializing; the
/// provenance area supplies the real implementation and the integrator wires it
/// through `ExportQAInstaller.installer(rights:render:consumer:)`.
public protocol RecipeRightsHook: Sendable {
    func resolve(declaration: RightsDeclaration, recipe: Recipe, context: OperationContext) throws -> RightsResolution
}

/// Default: the declaration's own meta, no attribution, no conflicts.
public struct NoRightsHook: RecipeRightsHook {
    public init() {}

    public func resolve(declaration: RightsDeclaration, recipe: Recipe, context: OperationContext) throws -> RightsResolution {
        RightsResolution(meta: declaration.meta)
    }
}

/// One canonical scenario a renderer must produce evidence for.
public struct RenderScenario: Codable, Hashable, Sendable {
    public var id: String
    public var kind: String
    public var configuration: JSONValue

    public init(id: String, kind: String, configuration: JSONValue) {
        self.id = id
        self.kind = kind
        self.configuration = configuration
    }
}

/// Renders authoring-v1 visual/expression/motion scenarios. Returning nil means
/// the renderer is unavailable and the scenario reports `incomplete`.
public protocol RenderAdapter: Sendable {
    var identity: String { get }
    func render(scenario: RenderScenario, file: URL, data: Data, outputDirectory: URL, context: OperationContext) throws -> [ArtifactRef]?
}

/// Default: no renderer; every render scenario is incomplete.
public struct NoRenderer: RenderAdapter {
    public init() {}
    public var identity: String { "none" }

    public func render(scenario: RenderScenario, file: URL, data: Data, outputDirectory: URL, context: OperationContext) throws -> [ArtifactRef]? { nil }
}

/// What an independent consumer read back from exported bytes.
public struct ConsumerImportReport: Codable, Hashable, Sendable {
    public var consumer: String
    public var version: String
    public var humanoidBones: Int
    public var expressions: Int
    public var springs: Int
    public var colliders: Int
    public var colliderGroups: Int
    public var meshes: Int
    public var materials: Int
    public var warnings: [String]

    public init(consumer: String, version: String, humanoidBones: Int, expressions: Int, springs: Int, colliders: Int, colliderGroups: Int,
                meshes: Int, materials: Int, warnings: [String] = []) {
        self.consumer = consumer
        self.version = version
        self.humanoidBones = humanoidBones
        self.expressions = expressions
        self.springs = springs
        self.colliders = colliders
        self.colliderGroups = colliderGroups
        self.meshes = meshes
        self.materials = materials
        self.warnings = warnings
    }
}

/// Loads exported bytes through a consumer implementation. The pinned consumer
/// id for authoring-v1 is `vrmmetalkit`; `SelfReimportConsumer` is the in-kit
/// fallback and does not satisfy that pin.
public protocol ConsumerImporter: Sendable {
    var id: String { get }
    var version: String { get }
    func importVRM(_ data: Data) throws -> ConsumerImportReport
}
