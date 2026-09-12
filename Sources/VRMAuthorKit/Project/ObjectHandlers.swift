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

/// Whole-object validation through the model type of each kind, plus the
/// cross-object references v1 can check before geometry exists.
public enum ObjectValidation {
    public static func validate(_ object: ProjectObject, state: ProjectState, context: OperationContext) throws {
        let json = ProjectObjects.modelJSON(object)
        do {
            switch object.kind {
            case .avatar:
                let avatar = try AvatarFields.decode(json)
                let pack = try ProjectAccess.pack(context, template: state.template)
                for (prefix, values) in [("/body", avatar.body), ("/face", avatar.face)] {
                    for (key, value) in values.sorted(by: { $0.key < $1.key }) {
                        try ControlCatalog.check(key: key, value: .number(value), descriptors: pack.controls, objectId: object.id, path: "\(prefix)/\(JSONPointer.escape(key))")
                    }
                }
            case .hair: _ = try HairItem.decode(json)
            case .garment:
                let item = try OutfitItem.decode(json)
                try references(item.materialIds, kind: .material, state: state, objectId: object.id, path: "/materialIds")
            case .accessory:
                let item = try AccessoryItem.decode(json)
                try references(item.materialIds, kind: .material, state: state, objectId: object.id, path: "/materialIds")
            case .textureLayer: _ = try TextureLayer.decode(json)
            case .material: _ = try MaterialObject.decode(json)
            case .expression:
                let item = try ExpressionObject.decode(json)
                try references(item.materialColorBinds.map(\.material) + item.textureTransformBinds.map(\.material), kind: .material, state: state, objectId: object.id, path: "/materialColorBinds")
            case .lookat: _ = try LookAtObject.decode(json)
            case .firstperson: _ = try FirstPersonObject.decode(json)
            case .spring:
                let item = try SpringObject.decode(json)
                try references(item.colliderGroups, kind: .colliderGroup, state: state, objectId: object.id, path: "/colliderGroups")
            case .collider: _ = try ColliderObject.decode(json)
            case .colliderGroup:
                let item = try ColliderGroupObject.decode(json)
                try references(item.colliders, kind: .collider, state: state, objectId: object.id, path: "/colliders")
            case .mesh, .image, .node, .humanoid:
                throw AuthorError(code: .invalidRequest, objectId: object.id, message: "\(object.kind.rawValue) objects are template-derived and read-only in v1.", suggestedCommands: ["object get"])
            }
        } catch let error as ModelValidationError {
            throw ModelValidationError(errors: error.errors.map { e in
                var scoped = e
                scoped.objectId = object.id
                return scoped
            })
        } catch var error as AuthorError {
            if error.objectId == nil { error.objectId = object.id }
            throw error
        }
    }

    static func references(_ ids: [String], kind: ObjectKind, state: ProjectState, objectId: String, path: String) throws {
        for id in ids {
            guard let target = state.object(id: id), target.kind == kind else {
                throw AuthorError(code: .objectNotFound, objectId: objectId, path: path, observed: .string(id), required: .string(kind.rawValue),
                                  message: "'\(id)' is not an existing \(kind.rawValue) object.", suggestedCommands: ["object list --kind \(kind.rawValue)"])
            }
        }
    }
}

/// Handlers for object list/get/set.
public enum ObjectHandlers {
    public static let names = ["object list", "object get", "object set"]

    static func install(_ registry: inout Registry) {
        registry.mustInstall(objectList, for: "object list")
        registry.mustInstall(objectGet, for: "object get")
        registry.mustInstall(objectSet, for: "object set")
    }

    public static func summary(_ object: ProjectObject) -> JSONValue {
        ["id": .string(object.id), "kind": .string(object.kind.rawValue), "revision": .number(Double(object.revision)),
         "writablePointers": JSONValue(object.writablePointers.map(\.description))]
    }

    static func objectList(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        try ProjectAccess.read(context, request) { _, state in
            let kind = try request["kind"]?.string.map { text -> ObjectKind in
                guard let k = ObjectKind(rawValue: text) else { throw AuthorError.invalidRequest("Unknown object kind.", path: "/kind", observed: .string(text)) }
                return k
            }
            let objects = state.objectIds.compactMap { state.object(id: $0) }.filter { kind == nil || $0.kind == kind }
            return ["objects": .array(objects.map(summary))]
        }
    }

    static func objectGet(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        try ProjectAccess.read(context, request) { _, state in
            guard let id = request["id"]?.string else { throw AuthorError.invalidRequest("id is required.", path: "/id") }
            guard let object = state.object(id: id) else {
                throw AuthorError(code: .objectNotFound, objectId: id, message: "No object with id '\(id)'.", suggestedCommands: ["object list"])
            }
            return ["object": ProjectObjects.typedJSON(object), "provenance": object.provenance, "writablePointers": JSONValue(object.writablePointers.map(\.description))]
        }
    }

    static func objectSet(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        ProjectAccess.mutation(context, request, operation: "object set") { _, tx in
            guard let editJSON = request["edit"] else { throw AuthorError.invalidRequest("edit is required.", path: "/edit") }
            let edit = try ObjectEdit.decode(editJSON)
            let before = try tx.object(id: edit.id)
            for (pointerText, value) in edit.values.sorted(by: { $0.key < $1.key }) {
                try tx.set(objectId: edit.id, pointer: try JSONPointer(pointerText), value: value)
            }
            let after = try tx.object(id: edit.id)
            try ObjectValidation.validate(after, state: tx.state, context: context)
            if after.fields != before.fields {
                for node in DependencyNode.invalidations(objectId: edit.id, kind: after.kind) { tx.invalidate(node) }
                tx.invalidate(DependencyNode.qa)
            }
            try ProjectObjects.syncRecipe(&tx)
            return ["invalidations": JSONValue(tx.invalidations)]
        }
    }
}
