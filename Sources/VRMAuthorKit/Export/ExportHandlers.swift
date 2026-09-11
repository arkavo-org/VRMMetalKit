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

/// Handlers for recipe export, recipe apply, build and export vrm.
public struct ExportHandlers: Sendable {
    public var rights: any RecipeRightsHook

    public init(rights: any RecipeRightsHook = NoRightsHook()) { self.rights = rights }

    public static let names = ["recipe export", "recipe apply", "build", "export vrm"]

    public func install(into registry: inout Registry) {
        let handlers = self
        registry.mustInstall({ context, request in try handlers.recipeExport(context, request) }, for: "recipe export")
        registry.mustInstall({ context, request in try handlers.recipeApply(context, request) }, for: "recipe apply")
        registry.mustInstall({ context, request in try handlers.build(context, request) }, for: "build")
        registry.mustInstall({ context, request in try handlers.exportVRM(context, request) }, for: "export vrm")
    }

    // MARK: recipe export

    /// Project recipe merged over the pack defaults: every top-level recipe
    /// field present in the project wins; body/face control maps merge per key.
    public static func resolved(project: JSONValue, defaults: Recipe) throws -> Recipe {
        var merged = try defaults.jsonValue().object ?? [:]
        for (key, value) in project.object ?? [:] {
            if key == "body" || key == "face", let base = merged[key]?.object, let overlay = value.object {
                var map = base
                for (k, v) in overlay { map[k] = v }
                merged[key] = .object(map)
            } else {
                merged[key] = value
            }
        }
        return try Recipe.decode(.object(merged))
    }

    func recipeExport(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        let requestId = request["requestId"]?.string
        let store = try BuildSupport.openProject(context)
        let state = try store.state()
        let out = try BuildSupport.outputURL(request, context: context)
        guard let projectRecipe = state.recipe else {
            throw AuthorError(code: .missingInput, path: "/recipe", message: "The project has no applied recipe to export.", suggestedCommands: ["recipe apply"])
        }
        let resolved = request["resolved"]?.bool ?? true
        let recipe: Recipe
        if resolved {
            let template = try TemplateRef.decode(projectRecipe["template"] ?? .null)
            let pack = try BuildSupport.pack(for: template, context: context)
            do { try pack.defaults.validate() } catch {
                throw AuthorError(code: .validationFailed, path: "/template/defaults", message: "Template pack '\(pack.id)' defaults are invalid: \(error)", suggestedCommands: ["template list"])
            }
            recipe = try ExportHandlers.resolved(project: projectRecipe, defaults: pack.defaults)
        } else {
            recipe = try Recipe.decode(projectRecipe)
        }
        let json = try recipe.jsonValue()
        let data = try CanonicalJSON.data(json)
        try ProjectStore.atomicWrite(data, to: out)
        let artifact = BuildSupport.artifact(out, data: data, mediaType: BuildSupport.mediaTypeJSON, role: "recipe")
        var envelope = ResultEnvelope.succeeded(requestId: requestId, revisionBefore: state.revision, revisionAfter: state.revision,
                                                result: ["recipe": json, "artifacts": try JSONValue.from([artifact])])
        envelope.artifacts = [artifact]
        return envelope
    }

    // MARK: recipe apply

    func recipeApply(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        let requestId = request["requestId"]?.string ?? UUID().uuidString
        let store = try BuildSupport.openProject(context)
        guard let recipeJSON = request["recipe"] else { throw AuthorError.invalidRequest("recipe is required.", path: "/recipe") }
        var recipe = try Recipe.decode(recipeJSON)
        let pack = try BuildSupport.pack(for: recipe.template, context: context)
        let resolution = try rights.resolve(declaration: recipe.rights, recipe: recipe, context: context)
        if !resolution.conflicts.isEmpty {
            throw ModelValidationError(errors: resolution.conflicts.map { conflict in
                var error = conflict
                if error.code == .invalidRequest { error.code = .validationFailed }
                if error.suggestedCommands.isEmpty { error.suggestedCommands = ["provenance resolve"] }
                return error
            })
        }
        recipe.rights.meta = resolution.meta
        recipe.rights.authors = resolution.meta.authors
        try recipe.validate()
        let compiled = try pack.compile(recipe, seed: recipe.seed).sorted()
        let dryRun = request["dryRun"]?.bool ?? false
        let buildHash = dryRun ? try compiled.buildHash() : try BuildSupport.storeCompiled(store, compiled)
        let inputsHash = try BuildSupport.inputsHash(recipe: recipe, pack: pack)
        let controlsHash = try BuildSupport.controlsHash(recipe: recipe)
        let recipeValue = try recipe.jsonValue()
        var previousRecipe: Recipe?
        if let previousJSON = try store.state().recipe { previousRecipe = try? Recipe.decode(previousJSON) }

        return try store.mutate(requestId: requestId, payload: request, expectedRevision: request["expectedRevision"]?.int, dryRun: dryRun,
                                expectedPlanHash: request["expectedPlanHash"]?.string, operation: "recipe apply") { tx in
            let provenance: JSONValue = ["source": "recipe apply", "template": .string(pack.id), "templateSha256": .string(pack.sha256), "buildHash": .string(buildHash)]
            tx.setRecipe(recipeValue)
            try ExportHandlers.materialize(&tx, recipe: recipe, avatar: compiled, buildHash: buildHash, inputsHash: inputsHash, controlsHash: controlsHash, provenance: provenance)
            for node in ExportHandlers.invalidations(previous: previousRecipe, next: recipe) { tx.invalidate(node) }
            tx.require("template pack \(pack.id)@\(pack.sha256.prefix(12))")
            tx.cost = ["cpuSeconds": 0, "nodes": .number(Double(compiled.nodes.count)), "vertices": .number(Double(compiled.meshes.flatMap(\.primitives).reduce(0) { $0 + $1.positions.count }))]
            if !dryRun {
                tx.artifacts = [BuildSupport.artifact(BuildSupport.compiledURL(store, buildHash), data: try Data(contentsOf: BuildSupport.compiledURL(store, buildHash)),
                                                      mediaType: BuildSupport.mediaTypeJSON, role: "compiled", buildHash: buildHash)]
            }
            let plan = try Plan.hashed(baseRevision: tx.state.revision, edits: tx.edits, invalidations: tx.invalidations, prerequisites: tx.prerequisites, cost: tx.cost)
            return ["plan": try JSONValue.from(plan), "invalidations": JSONValue(tx.invalidations)]
        }
    }

    /// Dependency-graph nodes invalidated by a recipe change (all on first apply).
    static func invalidations(previous: Recipe?, next: Recipe) -> [String] {
        guard let previous else { return ["geometry", "rig", "morphs", "fit", "textures", "materials", "springs", "qa", "build"] }
        var out: [String] = []
        if previous.body != next.body || previous.face != next.face || previous.seed != next.seed || previous.template != next.template {
            out += ["geometry", "rig", "morphs", "fit", "springs"]
        }
        if previous.hair != next.hair { out += ["geometry", "rig", "springs", "fit"] }
        if previous.outfits != next.outfits || previous.accessories != next.accessories { out += ["geometry", "fit"] }
        if previous.textures != next.textures { out.append("textures") }
        if previous.materials != next.materials { out.append("materials") }
        if previous.expressions != next.expressions { out.append("morphs") }
        if previous.springs != next.springs || previous.colliders != next.colliders || previous.colliderGroups != next.colliderGroups { out.append("springs") }
        if previous.lookAt != next.lookAt || previous.rights != next.rights || previous.style != next.style || previous.name != next.name { out.append("build") }
        if !out.isEmpty { out += ["qa", "build"] }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    static func upsert(_ tx: inout MutationTransaction, _ object: ProjectObject, keep: inout Set<String>) throws {
        keep.insert(object.id)
        if let existing = tx.state.object(id: object.id) {
            if existing.kind == object.kind, existing.fields == object.fields, existing.provenance == object.provenance,
               existing.writablePointers == object.writablePointers { return }
            try tx.replace(object)
        } else {
            try tx.insert(object)
        }
    }

    static func object(_ id: String, _ kind: ObjectKind, _ model: some Encodable, writable: [String], provenance: JSONValue) throws -> ProjectObject {
        try ProjectObject(id: id, kind: kind, provenance: provenance, writablePointers: writable, fields: try JSONValue.from(model).object ?? [:])
    }

    /// Creates or refreshes one ProjectObject per recipe/compiled entity and
    /// removes objects of those kinds that no longer exist.
    static func materialize(_ tx: inout MutationTransaction, recipe: Recipe, avatar: CompiledAvatar, buildHash: String, inputsHash: String, controlsHash: String, provenance: JSONValue) throws {
        var keep = Set<String>()
        let owned: Set<ObjectKind> = [.avatar, .mesh, .material, .image, .textureLayer, .hair, .garment, .accessory, .node, .humanoid, .expression, .lookat, .firstperson, .spring, .collider, .colliderGroup]
        let avatarObject = try ProjectObject(id: BuildSupport.avatarObjectId, kind: .avatar, provenance: provenance, writablePointers: [], fields: [
            "name": .string(recipe.name), "template": try recipe.template.jsonValue(), "seed": .number(Double(recipe.seed)), "buildHash": .string(buildHash),
            "inputsHash": .string(inputsHash), "controlsHash": .string(controlsHash), "target": .string(recipe.target),
        ])
        try upsert(&tx, avatarObject, keep: &keep)
        for item in recipe.hair { try upsert(&tx, try object(item.id, .hair, item, writable: ["/controls", "/texture"], provenance: provenance), keep: &keep) }
        for item in recipe.outfits { try upsert(&tx, try object(item.id, .garment, item, writable: ["/controls", "/enabled", "/layer", "/materialIds"], provenance: provenance), keep: &keep) }
        for item in recipe.accessories { try upsert(&tx, try object(item.id, .accessory, item, writable: ["/transform", "/materialIds", "/enabled"], provenance: provenance), keep: &keep) }
        for layer in recipe.textures { try upsert(&tx, try object(layer.id, .textureLayer, layer, writable: ["/colour", "/image", "/mask", "/opacity", "/blend", "/uvOffset", "/uvScale", "/uvRotationDeg", "/enabled"], provenance: provenance), keep: &keep) }
        for material in avatar.materials { try upsert(&tx, try object(material.id, .material, material, writable: ["/gltf", "/mtoon"], provenance: provenance), keep: &keep) }
        for image in avatar.images {
            let fields: [String: JSONValue] = ["sha256": .string(image.sha256), "colourSpace": .string(image.colourSpace.rawValue), "usage": .string(image.usage.rawValue), "bytes": .number(Double(image.pngData.count))]
            try upsert(&tx, try ProjectObject(id: image.id, kind: .image, provenance: provenance, writablePointers: [], fields: fields), keep: &keep)
        }
        for expression in avatar.expressions {
            try upsert(&tx, try object(expression.id, .expression, expression, writable: ["/isBinary", "/overrideBlink", "/overrideLookAt", "/overrideMouth", "/morphTargetBinds", "/materialColorBinds", "/textureTransformBinds"], provenance: provenance), keep: &keep)
        }
        try upsert(&tx, try object("lookat:main", .lookat, avatar.lookAt, writable: ["/offsetFromHeadBone", "/rangeMapHorizontalInner", "/rangeMapHorizontalOuter", "/rangeMapVerticalDown", "/rangeMapVerticalUp"], provenance: provenance), keep: &keep)
        try upsert(&tx, try object("firstperson:main", .firstperson, avatar.firstPerson, writable: ["/meshAnnotations"], provenance: provenance), keep: &keep)
        for spring in avatar.springs { try upsert(&tx, try object(spring.id, .spring, spring, writable: ["/name", "/joints", "/colliderGroups"], provenance: provenance), keep: &keep) }
        for collider in avatar.colliders { try upsert(&tx, try object(collider.id, .collider, collider, writable: ["/node", "/shape"], provenance: provenance), keep: &keep) }
        for group in avatar.colliderGroups { try upsert(&tx, try object(group.id, .colliderGroup, group, writable: ["/name", "/colliders"], provenance: provenance), keep: &keep) }
        var humanBones: [String: JSONValue] = [:]
        for (bone, nodeId) in avatar.humanoid { humanBones[bone.rawValue] = .string(nodeId) }
        try upsert(&tx, try ProjectObject(id: "humanoid:main", kind: .humanoid, provenance: provenance, writablePointers: [], fields: ["humanBones": .object(humanBones)]), keep: &keep)
        for node in avatar.nodes {
            let fields: [String: JSONValue] = [
                "name": .string(node.name), "parent": node.parentId.map { .string($0) } ?? .null,
                "translation": JSONValue([Double(node.translation.x), Double(node.translation.y), Double(node.translation.z)]),
                "rotation": JSONValue([Double(node.rotation.x), Double(node.rotation.y), Double(node.rotation.z), Double(node.rotation.w)]),
                "scale": JSONValue([Double(node.scale.x), Double(node.scale.y), Double(node.scale.z)]),
                "humanoidBone": node.humanoidBone.map { .string($0.rawValue) } ?? .null,
            ]
            try upsert(&tx, try ProjectObject(id: node.id, kind: .node, provenance: provenance, writablePointers: [], fields: fields), keep: &keep)
        }
        for mesh in avatar.meshes {
            let fields: [String: JSONValue] = [
                "name": .string(mesh.name), "primitives": .number(Double(mesh.primitives.count)),
                "vertices": .number(Double(mesh.primitives.reduce(0) { $0 + $1.positions.count })),
                "triangles": .number(Double(mesh.primitives.reduce(0) { $0 + $1.indices.count / 3 })),
                "morphTargets": JSONValue(mesh.primitives.first?.morphTargets.map(\.name) ?? []),
                "materials": JSONValue(mesh.primitives.map(\.materialId)),
            ]
            try upsert(&tx, try ProjectObject(id: mesh.id, kind: .mesh, provenance: provenance, writablePointers: [], fields: fields), keep: &keep)
        }
        for id in tx.state.objectIds where !keep.contains(id) {
            if let existing = tx.state.object(id: id), owned.contains(existing.kind) { try tx.remove(objectId: id) }
        }
    }

    // MARK: build

    func build(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        let requestId = request["requestId"]?.string
        let store = try BuildSupport.openProject(context)
        let state = try store.state()
        let out = try BuildSupport.outputURL(request, context: context)
        try BuildSupport.requireNoStale(state)
        let compilation = try BuildSupport.compileOrReuse(store: store, state: state, context: context)
        let export = try GLBWriter.write(compilation.avatar, threads: request["threads"]?.int ?? 1)
        let info = try BuildSupport.recordBuild(store: store, compilation: compilation, export: export, revision: state.revision)
        try ProjectStore.atomicWrite(export.data, to: out)
        let artifact = BuildSupport.artifact(out, data: export.data, mediaType: BuildSupport.mediaTypeVRM, role: "draft", buildHash: compilation.buildHash)
        let idMapArtifact = BuildSupport.artifact(BuildSupport.idMapURL(store, compilation.buildHash), data: try CanonicalJSON.data(try JSONValue.from(export.idMap)),
                                                  mediaType: BuildSupport.mediaTypeJSON, role: "idmap", buildHash: compilation.buildHash)
        var envelope = ResultEnvelope.succeeded(requestId: requestId, revisionBefore: state.revision, revisionAfter: state.revision, result: [
            "buildHash": .string(compilation.buildHash), "artifacts": try JSONValue.from([artifact, idMapArtifact]), "idMap": try JSONValue.from(export.idMap), "stale": [],
        ])
        envelope.artifacts = [artifact, idMapArtifact]
        if compilation.reused { envelope.warnings.append(AuthorWarning(code: "BUILD_REUSED", message: "Inputs unchanged; reused compiled avatar \(info.buildHash.prefix(12)).")) }
        return envelope
    }

    // MARK: export vrm

    func exportVRM(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        let requestId = request["requestId"]?.string
        let store = try BuildSupport.openProject(context)
        let state = try store.state()
        let out = try BuildSupport.outputURL(request, context: context)
        try BuildSupport.requireNoStale(state)
        let compilation = try BuildSupport.compileOrReuse(store: store, state: state, context: context)
        let missing = BuildSupport.missingMandatoryMeta(compilation.avatar.meta)
        if !missing.isEmpty {
            return .failed(requestId: requestId, revision: state.revision, errors: missing.map { field in
                AuthorError(code: .validationFailed, path: "/meta/\(field)", message: "Mandatory VRM meta field '\(field)' is unresolved.",
                            suggestedCommands: ["provenance resolve", "recipe apply"])
            })
        }
        let export = try GLBWriter.write(compilation.avatar, threads: request["threads"]?.int ?? 1)
        try BuildSupport.recordBuild(store: store, compilation: compilation, export: export, revision: state.revision)
        try ProjectStore.atomicWrite(export.data, to: out)
        let meta = try JSONValue.from(compilation.avatar.meta)
        let lossReport: JSONValue = [
            "preserved": JSONValue(["meshes", "skins", "morphTargets", "materials", "images", "humanoid", "expressions", "lookAt", "firstPerson", "springBone", "meta"]),
            "lost": [], "converted": [],
        ]
        let report: JSONValue = [
            "reportVersion": 1, "buildHash": .string(compilation.buildHash), "file": ["path": .string(out.path), "sha256": .string(export.sha256), "sizeBytes": .number(Double(export.data.count))],
            "target": .string(BuildSupport.target), "backend": .string(BuildSupport.backend), "generator": .string(GLBWriter.generator), "meta": meta, "lossReport": lossReport,
        ]
        let reportURL = out.deletingPathExtension().appendingPathExtension("export-report.json")
        let reportData = try CanonicalJSON.data(report)
        try ProjectStore.atomicWrite(reportData, to: reportURL)
        let artifacts = [
            BuildSupport.artifact(out, data: export.data, mediaType: BuildSupport.mediaTypeVRM, role: "final", buildHash: compilation.buildHash),
            BuildSupport.artifact(reportURL, data: reportData, mediaType: BuildSupport.mediaTypeJSON, role: "export-report", buildHash: compilation.buildHash),
        ]
        var envelope = ResultEnvelope.succeeded(requestId: requestId, revisionBefore: state.revision, revisionAfter: state.revision, result: [
            "buildHash": .string(compilation.buildHash), "artifacts": try JSONValue.from(artifacts), "lossReport": lossReport, "meta": meta,
        ])
        envelope.artifacts = artifacts
        return envelope
    }
}
