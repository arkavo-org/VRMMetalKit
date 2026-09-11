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

/// The `avatar:main` object: recipe-level fields that are not items. Body and
/// face hold calibrated control values keyed by control key; rights and style
/// are ledger-bound and never writable through `object set`.
public struct AvatarFields: AuthorModel {
    public var name: String
    public var target: String
    public var seed: UInt64
    public var template: TemplateRef
    public var body: ControlValues
    public var face: ControlValues
    public var style: Blob
    public var rights: RightsDeclaration

    public init(name: String, target: String, seed: UInt64, template: TemplateRef, body: ControlValues, face: ControlValues, style: Blob, rights: RightsDeclaration) {
        self.name = name
        self.target = target
        self.seed = seed
        self.template = template
        self.body = body
        self.face = face
        self.style = style
        self.rights = rights
    }

    public init(recipe: Recipe) {
        self.init(name: recipe.name, target: recipe.target, seed: recipe.seed, template: recipe.template, body: recipe.body, face: recipe.face,
                  style: recipe.style, rights: recipe.rights)
    }

    public static let modelName = "Avatar"
    public static var schema: JSONSchema {
        JSONSchema.object(properties: [
            "name": .string(minLength: 1),
            "target": .enumeration([Recipe.portableTarget]),
            "seed": .integer(minimum: 0, maximum: Int(Recipe.maxSeed)),
            "template": TemplateRef.schema,
            "body": .map(of: .number(), description: "body.* control values"),
            "face": .map(of: .number(), description: "face.* control values"),
            "style": Blob.schema,
            "rights": RightsDeclaration.schema,
        ], required: ["name", "target", "seed", "template", "body", "face", "style", "rights"], description: "Avatar-level recipe fields")
    }

    public func validate() throws {
        guard target == Recipe.portableTarget else { throw AuthorError.invalidRequest("Unsupported target.", path: "/target", observed: .string(target)) }
        try template.validate()
        for (k, v) in body { try ModelCheck.finite(v, "/body/\(JSONPointer.escape(k))") }
        for (k, v) in face { try ModelCheck.finite(v, "/face/\(JSONPointer.escape(k))") }
        try style.validate()
        try rights.validate()
    }
}

/// Dependency-graph node names recorded as invalidations and reported by
/// `project inspect` as stale until a build marker covers them.
public enum DependencyNode {
    public static let geometry = "geometry"
    public static let rig = "rig"
    public static let morph = "morph"
    public static let fit = "fit"
    public static let texture = "texture"
    public static let qa = "qa"
    public static let build = "build"

    public static func nodes(for kind: ObjectKind) -> [String] {
        switch kind {
        case .avatar: return [geometry, rig, morph, fit]
        case .mesh, .node, .humanoid: return [geometry, rig]
        case .hair: return [geometry, rig, texture]
        case .garment: return [geometry, fit]
        case .accessory: return [geometry]
        case .image, .textureLayer: return [texture]
        case .material: return [texture]
        case .expression: return [morph]
        case .lookat, .firstperson, .spring, .collider, .colliderGroup: return [rig]
        }
    }

    public static func invalidations(objectId: String, kind: ObjectKind) -> [String] {
        nodes(for: kind).map { "\(objectId)/\($0)" }
    }
}

/// Materializes a resolved recipe into typed project objects and derives the
/// current recipe back from them. Objects are the editable source of truth;
/// `ProjectState.recipe` is kept equal to `current(state:)` after every mutation.
public enum ProjectObjects {
    public static let avatarId = "avatar:main"
    public static let lookAtId = "lookat:main"

    public static func provenance(template: TemplateRef, item: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["source": "template", "templateId": .string(template.id), "templateSha256": .string(template.sha256)]
        if let item { o["preset"] = .string(item) }
        return .object(o)
    }

    /// The only pointers `object set` accepts. VRM meta, rights and training
    /// claims are absent by design: they are edited through `provenance resolve`
    /// or the Recipe, never through a field write.
    public static func writablePointers(kind: ObjectKind, fields: [String: JSONValue]) -> [String] {
        switch kind {
        case .avatar: return ["/name", "/body", "/face"]
        case .hair: return ["/controls", "/texture"]
        case .garment: return ["/enabled", "/layer", "/controls", "/materialIds"]
        case .accessory: return ["/attachment", "/transform", "/materialIds", "/enabled"]
        case .textureLayer: return ["/targetImage", "/layerKind", "/colour", "/image", "/mask", "/opacity", "/blend", "/uvOffset", "/uvScale", "/uvRotationDeg", "/enabled"]
        case .material: return ["/role", "/gltf", "/mtoon"]
        case .expression: return ["/preset", "/name", "/isBinary", "/overrideBlink", "/overrideLookAt", "/overrideMouth", "/morphTargetBinds", "/materialColorBinds", "/textureTransformBinds"]
        case .lookat: return ["/offsetFromHeadBone", "/rangeMapHorizontalInner", "/rangeMapHorizontalOuter", "/rangeMapVerticalDown", "/rangeMapVerticalUp"]
        case .firstperson: return ["/meshAnnotations"]
        case .spring:
            let joints = fields["joints"]?.array?.count ?? 0
            return ["/name", "/colliderGroups"] + (0..<joints).flatMap { i in ["hitRadius", "stiffness", "gravityPower", "gravityDir", "dragForce"].map { "/joints/\(i)/\($0)" } }
        case .collider: return ["/node", "/shape"]
        case .colliderGroup: return ["/name", "/colliders"]
        case .mesh, .image, .node, .humanoid: return []
        }
    }

    /// `TextureLayer.kind` is stored as `layerKind` because `kind` is the
    /// object-kind key reserved by `ProjectObject`.
    public static let layerKindField = "layerKind"

    static func object<T: AuthorModel>(_ model: T, id: String, kind: ObjectKind, template: TemplateRef, item: String? = nil) throws -> ProjectObject {
        var fields = try model.jsonValue().object ?? [:]
        fields["id"] = nil
        if kind == .textureLayer, let layerKind = fields["kind"] {
            fields["kind"] = nil
            fields[layerKindField] = layerKind
        }
        return try ProjectObject(id: id, kind: kind, provenance: provenance(template: template, item: item),
                                 writablePointers: writablePointers(kind: kind, fields: fields), fields: fields)
    }

    /// Every object a resolved recipe carries. Nodes, meshes, images, humanoid
    /// and first-person data are template-derived by `compile` and absent here.
    public static func materialize(_ recipe: Recipe) throws -> [ProjectObject] {
        let template = recipe.template
        var out: [ProjectObject] = []
        out.append(try object(AvatarFields(recipe: recipe), id: avatarId, kind: .avatar, template: template))
        out.append(try object(recipe.lookAt, id: lookAtId, kind: .lookat, template: template))
        for h in recipe.hair { out.append(try object(h, id: h.id, kind: .hair, template: template, item: h.preset)) }
        for o in recipe.outfits { out.append(try object(o, id: o.id, kind: .garment, template: template, item: o.preset)) }
        for a in recipe.accessories { out.append(try object(a, id: a.id, kind: .accessory, template: template, item: a.preset.rawValue)) }
        for t in recipe.textures { out.append(try object(t, id: t.id, kind: .textureLayer, template: template)) }
        for m in recipe.materials { out.append(try object(m, id: m.id, kind: .material, template: template)) }
        for e in recipe.expressions { out.append(try object(e, id: e.id, kind: .expression, template: template)) }
        for s in recipe.springs { out.append(try object(s, id: s.id, kind: .spring, template: template)) }
        for c in recipe.colliders { out.append(try object(c, id: c.id, kind: .collider, template: template)) }
        for g in recipe.colliderGroups { out.append(try object(g, id: g.id, kind: .colliderGroup, template: template)) }
        var seen = Set<String>()
        for o in out {
            guard seen.insert(o.id).inserted else {
                throw AuthorError(code: .validationFailed, objectId: o.id, message: "Recipe item id '\(o.id)' collides with another project object.", suggestedCommands: ["object list"])
            }
        }
        return out
    }

    /// The object's fields plus its identity, as the typed model sees it.
    public static func typedJSON(_ object: ProjectObject) -> JSONValue {
        var o = object.fields
        o["id"] = .string(object.id)
        o["kind"] = .string(object.kind.rawValue)
        o["revision"] = .number(Double(object.revision))
        return .object(o)
    }

    /// Fields with `id` re-attached for kinds whose model carries one.
    public static func modelJSON(_ object: ProjectObject) -> JSONValue {
        switch object.kind {
        case .avatar, .lookat, .firstperson, .humanoid: return .object(object.fields)
        default:
            var o = object.fields
            o["id"] = .string(object.id)
            if object.kind == .textureLayer, let layerKind = o[layerKindField] {
                o[layerKindField] = nil
                o["kind"] = layerKind
            }
            return .object(o)
        }
    }

    /// The recipe derived from the current objects, preserving the array order of
    /// the stored recipe (layer order is compositing order).
    public static func currentRecipe(_ state: ProjectState) throws -> Recipe {
        guard var recipe = state.recipe?.object else {
            throw AuthorError(code: .validationFailed, path: "/recipe", message: "Project has no stored recipe.", suggestedCommands: ["project init"])
        }
        if let avatar = state.object(id: avatarId) {
            for key in ["name", "target", "seed", "template", "body", "face", "style", "rights"] { recipe[key] = avatar.fields[key] }
        }
        if let lookAt = state.object(id: lookAtId) { recipe["lookAt"] = .object(lookAt.fields) }
        let arrays: [(String, ObjectKind)] = [("hair", .hair), ("outfits", .garment), ("accessories", .accessory), ("textures", .textureLayer), ("materials", .material),
                                              ("expressions", .expression), ("springs", .spring), ("colliders", .collider), ("colliderGroups", .colliderGroup)]
        for (key, kind) in arrays {
            let storedIds = (recipe[key]?.array ?? []).compactMap { $0["id"]?.string }
            let live = state.objectIds.compactMap { state.object(id: $0) }.filter { $0.kind == kind }
            let ordered = storedIds.compactMap { id in live.first { $0.id == id } } + live.filter { !storedIds.contains($0.id) }
            recipe[key] = .array(ordered.map { modelJSON($0) })
        }
        return try Recipe.decode(.object(recipe))
    }

    /// Re-derives the recipe and records a recipe edit only when it changed.
    public static func syncRecipe(_ tx: inout MutationTransaction) throws {
        let recipe = try currentRecipe(tx.state).jsonValue()
        if recipe != tx.state.recipe { tx.setRecipe(recipe) }
    }
}

extension ProjectStore {
    /// Name of the marker Phase E writes under `builds/<hash>/`; its `revision`
    /// field is the last revision covered by a build.
    public static let buildMarkerFileName = "build.json"

    /// Replaces the empty revision 0 written by `create` with seeded state.
    /// Only valid before any mutation.
    public func seedRevisionZero(_ seeded: ProjectState, operation: String) throws {
        guard try revisionNumbers() == [0], try state().revision == 0 else {
            throw AuthorError(code: .invalidRequest, path: root.path, message: "Revision 0 can only be seeded before the first mutation.", suggestedCommands: ["project inspect"])
        }
        var state = seeded
        state.revision = 0
        let record = RevisionRecord(revision: 0, parent: nil, requestId: nil, operation: operation, plan: nil, state: state)
        try atomicWrite(try CanonicalJSON.data(try JSONValue.from(record)), to: revisionsDirectory.appendingPathComponent(ProjectStore.revisionFileName(0)))
        try atomicWrite(try CanonicalJSON.data(try JSONValue.from(state)), to: projectFile)
    }

    /// Highest build-marker revision not beyond the current revision.
    public func lastBuildRevision() throws -> Int? {
        let current = try state().revision
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(atPath: buildsDirectory.path)) ?? []
        var best: Int?
        for dir in dirs {
            let marker = buildsDirectory.appendingPathComponent(dir).appendingPathComponent(ProjectStore.buildMarkerFileName)
            guard let data = try? Data(contentsOf: marker), let json = try? JSONValue.parse(data), let revision = json["revision"]?.int, revision <= current else { continue }
            best = max(best ?? revision, revision)
        }
        return best
    }

    /// Dependency nodes invalidated since the last build; `build` alone when nothing was ever built.
    public func staleNodes() throws -> [String] {
        guard let built = try lastBuildRevision() else { return [DependencyNode.build] }
        let current = try state().revision
        var stale: [String] = []
        if built < current {
            for n in (built + 1)...current {
                for node in try revision(n).plan?.invalidations ?? [] where !stale.contains(node) { stale.append(node) }
            }
        }
        return stale
    }
}
