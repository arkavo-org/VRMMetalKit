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

/// buildinfo.json written next to every build artifact.
public struct BuildInfo: Codable, Hashable, Sendable {
    public var buildHash: String
    public var revision: Int
    public var inputsHash: String
    public var controlsHash: String
    public var previousBuildHash: String?
    public var previousControlsHash: String?
    public var target: String
    public var backend: String
    public var artifactSha256: String
    public var generator: String
    public var templateId: String
    public var templateSha256: String
    public var seed: UInt64
}

/// Shared project/build plumbing for the export and QA handlers.
public enum BuildSupport {
    public static let avatarObjectId = "avatar:main"
    public static let mediaTypeVRM = "model/gltf-binary"
    public static let mediaTypeJSON = "application/json"
    public static let target = "portable-vrm1"
    public static let backend = "portable-strict/1"

    // MARK: Project and request helpers

    public static func openProject(_ context: OperationContext) throws -> ProjectStore {
        guard let path = context.projectPath else {
            throw AuthorError(code: .projectNotFound, path: "/project", message: "project is required.", suggestedCommands: ["project init"])
        }
        return try ProjectStore.open(at: path)
    }

    public static func resolve(_ path: String, in context: OperationContext) -> URL {
        URL(fileURLWithPath: path, relativeTo: context.cwd).standardizedFileURL
    }

    public static func outputURL(_ request: JSONValue, context: OperationContext) throws -> URL {
        guard let out = request["out"]?.string, !out.isEmpty else { throw AuthorError.invalidRequest("out is required.", path: "/out") }
        let url = resolve(out, in: context)
        let replace = request["replace"]?.bool ?? false
        if FileManager.default.fileExists(atPath: url.path), !replace {
            throw AuthorError(code: .outputExists, path: "/out", observed: .string(url.path), message: "Output \(url.path) already exists; pass replace=true to overwrite atomically.",
                              suggestedCommands: ["--replace"])
        }
        return url
    }

    public static func artifact(_ url: URL, data: Data, mediaType: String, role: String, buildHash: String? = nil) -> ArtifactRef {
        ArtifactRef(path: url.path, sha256: SHA256Hex.hex(data), mediaType: mediaType, sizeBytes: data.count, role: role, buildHash: buildHash)
    }

    // MARK: Recipe and template

    public static func recipe(from state: ProjectState) throws -> Recipe {
        guard let json = state.recipe else {
            throw AuthorError(code: .missingInput, path: "/recipe", message: "The project has no applied recipe.", suggestedCommands: ["recipe apply"])
        }
        return try Recipe.decode(json)
    }

    public static func pack(for template: TemplateRef, context: OperationContext) throws -> any TemplatePack {
        guard let pack = context.templates.pack(id: template.id) else {
            throw AuthorError(code: .missingCapability, path: "/template/id", observed: .string(template.id), required: JSONValue(context.templates.ids),
                              message: "Template pack '\(template.id)' is not installed.", suggestedCommands: ["template list"])
        }
        guard pack.sha256 == template.sha256 else {
            throw AuthorError(code: .validationFailed, path: "/template/sha256", observed: .string(template.sha256), required: .string(pack.sha256),
                              message: "Template pack '\(template.id)' sha256 does not match the installed pack.", suggestedCommands: ["template list", "recipe export"])
        }
        return pack
    }

    public static func inputsHash(recipe: Recipe, pack: any TemplatePack) throws -> String {
        try CanonicalJSON.sha256(["recipe": try recipe.jsonValue(), "templateSha256": .string(pack.sha256), "seed": .number(Double(recipe.seed)), "generator": .string(GLBWriter.generator)])
    }

    /// Hash of the inputs that drive geometry: body/face controls, hair, outfits, accessories and seed.
    public static func controlsHash(recipe: Recipe) throws -> String {
        try CanonicalJSON.sha256([
            "body": try JSONValue.from(recipe.body), "face": try JSONValue.from(recipe.face), "hair": try JSONValue.from(recipe.hair),
            "outfits": try JSONValue.from(recipe.outfits), "accessories": try JSONValue.from(recipe.accessories), "seed": .number(Double(recipe.seed)),
        ])
    }

    /// Objects whose `stale` field is true; builds reject them.
    public static func staleObjects(_ state: ProjectState) -> [String] {
        state.objectIds.filter { state.object(id: $0)?.fields["stale"] == .bool(true) }
    }

    // MARK: builds/<hash>

    public static func buildDirectory(_ store: ProjectStore, _ hash: String) -> URL { store.buildsDirectory.appendingPathComponent(hash) }
    public static func compiledURL(_ store: ProjectStore, _ hash: String) -> URL { buildDirectory(store, hash).appendingPathComponent("compiled.json") }
    public static func avatarURL(_ store: ProjectStore, _ hash: String) -> URL { buildDirectory(store, hash).appendingPathComponent("avatar.vrm") }
    public static func idMapURL(_ store: ProjectStore, _ hash: String) -> URL { buildDirectory(store, hash).appendingPathComponent("idmap.json") }
    public static func buildInfoURL(_ store: ProjectStore, _ hash: String) -> URL { buildDirectory(store, hash).appendingPathComponent("buildinfo.json") }
    public static func latestURL(_ store: ProjectStore) -> URL { store.buildsDirectory.appendingPathComponent("latest.json") }

    public static func storeCompiled(_ store: ProjectStore, _ avatar: CompiledAvatar) throws -> String {
        let hash = try avatar.buildHash()
        let url = compiledURL(store, hash)
        if !FileManager.default.fileExists(atPath: url.path) {
            try store.atomicWrite(try CanonicalJSON.data(try JSONValue.from(avatar)), to: url)
        }
        return hash
    }

    public static func loadCompiled(_ store: ProjectStore, _ hash: String) throws -> CompiledAvatar? {
        let url = compiledURL(store, hash)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONValue.parse(try Data(contentsOf: url)).decode(CompiledAvatar.self)
    }

    public static func buildInfo(_ store: ProjectStore, _ hash: String) throws -> BuildInfo? {
        let url = buildInfoURL(store, hash)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONValue.parse(try Data(contentsOf: url)).decode(BuildInfo.self)
    }

    public static func latestBuildHash(_ store: ProjectStore) -> String? {
        guard let data = try? Data(contentsOf: latestURL(store)), let json = try? JSONValue.parse(data) else { return nil }
        return json["buildHash"]?.string
    }

    /// The build whose avatar.vrm has exactly these bytes, when one exists.
    public static func build(matching sha256: String, in store: ProjectStore) -> BuildInfo? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: store.buildsDirectory.path)) ?? []
        for name in names.sorted() where SHA256Hex.isValid(name) {
            if let info = try? buildInfo(store, name), info.artifactSha256 == sha256 { return info }
        }
        return nil
    }

    public struct Compilation: Sendable {
        public var avatar: CompiledAvatar
        public var recipe: Recipe
        public var buildHash: String
        public var inputsHash: String
        public var controlsHash: String
        public var pack: any TemplatePack
        public var reused: Bool
    }

    /// Compiles the project's current recipe or reuses builds/<hash>/compiled.json
    /// when the avatar object records the same inputs hash.
    public static func compileOrReuse(store: ProjectStore, state: ProjectState, context: OperationContext) throws -> Compilation {
        let recipe = try recipe(from: state)
        let pack = try pack(for: recipe.template, context: context)
        let inputs = try inputsHash(recipe: recipe, pack: pack)
        let controls = try controlsHash(recipe: recipe)
        if let avatarObject = state.object(id: avatarObjectId), avatarObject.fields["inputsHash"]?.string == inputs,
           let hash = avatarObject.fields["buildHash"]?.string, let compiled = try loadCompiled(store, hash) {
            return Compilation(avatar: compiled, recipe: recipe, buildHash: hash, inputsHash: inputs, controlsHash: controls, pack: pack, reused: true)
        }
        let compiled = try pack.compile(recipe, seed: recipe.seed).sorted()
        let hash = try storeCompiled(store, compiled)
        return Compilation(avatar: compiled, recipe: recipe, buildHash: hash, inputsHash: inputs, controlsHash: controls, pack: pack, reused: false)
    }

    public static func requireNoStale(_ state: ProjectState) throws {
        let stale = staleObjects(state)
        guard stale.isEmpty else {
            throw AuthorError(code: .staleDependency, path: "/objects", observed: JSONValue(stale), message: "Stale dependencies block the build: \(stale.joined(separator: ", ")).",
                              suggestedCommands: ["recipe apply", "control set", "project inspect"])
        }
    }

    /// Writes builds/<hash>/{avatar.vrm, idmap.json, buildinfo.json} and builds/latest.json.
    @discardableResult
    public static func recordBuild(store: ProjectStore, compilation: Compilation, export: GLBExport, revision: Int) throws -> BuildInfo {
        let previous = latestBuildHash(store)
        let previousInfo = try previous.flatMap { try buildInfo(store, $0) }
        var previousBuildHash = previous
        var previousControlsHash = previousInfo?.controlsHash
        if previous == compilation.buildHash, previousInfo?.controlsHash == compilation.controlsHash {
            previousBuildHash = previousInfo?.previousBuildHash
            previousControlsHash = previousInfo?.previousControlsHash
        }
        let info = BuildInfo(buildHash: compilation.buildHash, revision: revision, inputsHash: compilation.inputsHash, controlsHash: compilation.controlsHash,
                             previousBuildHash: previousBuildHash, previousControlsHash: previousControlsHash, target: target, backend: backend, artifactSha256: export.sha256, generator: GLBWriter.generator,
                             templateId: compilation.recipe.template.id, templateSha256: compilation.recipe.template.sha256, seed: compilation.recipe.seed)
        try store.atomicWrite(export.data, to: avatarURL(store, compilation.buildHash))
        try store.atomicWrite(try CanonicalJSON.data(try JSONValue.from(export.idMap)), to: idMapURL(store, compilation.buildHash))
        try store.atomicWrite(try CanonicalJSON.data(try JSONValue.from(info)), to: buildInfoURL(store, compilation.buildHash))
        try store.atomicWrite(try CanonicalJSON.data(["buildHash": .string(compilation.buildHash), "revision": .number(Double(revision))]), to: latestURL(store))
        return info
    }

    /// Mandatory VRMC_vrm meta fields that are unresolved on this meta.
    public static func missingMandatoryMeta(_ meta: VRMMeta) -> [String] {
        let json = (try? JSONValue.from(meta))?.object ?? [:]
        return SpecValidator.mandatoryMetaFields.filter { field in
            guard let value = json[field] else { return true }
            if let s = value.string { return s.isEmpty }
            if let a = value.array { return a.isEmpty || a.contains { ($0.string ?? "").isEmpty } }
            return false
        }
    }
}
