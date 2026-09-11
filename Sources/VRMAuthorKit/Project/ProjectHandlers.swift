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

/// Handlers for project init/inspect and history list/restore; the installer
/// also wires the object, control and serve handlers of the same area.
public enum ProjectHandlers {
    public static let install: RegistryInstaller = { registry in
        registry.mustInstall(projectInit, for: "project init")
        registry.mustInstall(projectInspect, for: "project inspect")
        registry.mustInstall(historyList, for: "history list")
        registry.mustInstall(historyRestore, for: "history restore")
        ObjectHandlers.install(&registry)
        ControlHandlers.install(&registry)
        ServeHandlers.install(&registry)
    }

    public static let names = ["project init", "project inspect", "history list", "history restore"] + ObjectHandlers.names + ControlHandlers.names + ServeHandlers.names

    // MARK: project init

    public static func lock(context: OperationContext, template: TemplateRef, seed: UInt64) throws -> JSONValue {
        var schemaHashes: [String: JSONValue] = [:]
        for op in context.registry.ordered { schemaHashes[op.name] = .string(op.schemaHash) }
        return [
            "tool": .string(context.toolInfo.tool),
            "version": .string(context.toolInfo.version),
            "protocol": .string(context.toolInfo.protocol),
            "abi": .string(context.toolInfo.abi),
            "seed": .number(Double(seed)),
            "target": .string(Recipe.portableTarget),
            "template": try template.jsonValue(),
            "schemaHashes": .object(schemaHashes),
            "modelHashes": ["Recipe": .string(Recipe.schema.schemaHash)],
        ]
    }

    static func projectInit(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        let requestId = request["requestId"]?.string
        guard let dirText = request["dir"]?.string, let templateId = request["template"]?.string else {
            throw AuthorError.invalidRequest("dir and template are required.", path: "/dir")
        }
        let seed = UInt64(request["seed"]?.int ?? 0)
        let dir = ProjectAccess.resolve(dirText, cwd: context.cwd)
        var name = request["name"]?.string ?? dir.lastPathComponent
        if request["name"] == nil, name.hasSuffix("." + ProjectStore.directoryExtension) { name = String(name.dropLast(ProjectStore.directoryExtension.count + 1)) }
        guard !name.isEmpty else { throw AuthorError.invalidRequest("Project name must not be empty.", path: "/name") }
        guard let pack = context.templates.pack(id: templateId) else {
            throw AuthorError(code: .missingCapability, path: "/template", observed: .string(templateId), required: JSONValue(context.templates.ids),
                              message: "Template pack '\(templateId)' is not installed in this build.", suggestedCommands: ["template list"])
        }
        let template = TemplateRef(id: pack.id, sha256: pack.sha256)
        var recipe = pack.defaults
        recipe.name = name
        recipe.seed = seed
        recipe.template = template
        let objects: [ProjectObject]
        do {
            try recipe.validate()
            objects = try ProjectObjects.materialize(recipe)
        } catch let error as AuthorError {
            throw AuthorError(code: .missingCapability, path: error.path, observed: error.observed, required: error.required,
                              message: "Template pack '\(pack.id)' defaults are rejected: \(error.message)", suggestedCommands: ["template list"])
        }
        let existed = FileManager.default.fileExists(atPath: dir.path)
        let store = try ProjectStore.create(at: dir, name: name, template: template, seed: seed, lock: try lock(context: context, template: template, seed: seed))
        do {
            var state = try store.state()
            state.recipe = try recipe.jsonValue()
            for object in objects { state.objects[object.id] = object.json }
            try store.seedRevisionZero(state, operation: "project init")
        } catch {
            if !existed { try? FileManager.default.removeItem(at: dir) }
            throw error
        }
        let state = try store.state()
        return ResultEnvelope(requestId: requestId, status: .succeeded, revisionBefore: nil, revisionAfter: 0, result: [
            "project": .string(store.root.path),
            "projectId": .string(state.projectId),
            "revision": 0,
            "template": try template.jsonValue(),
            "recipe": try recipe.jsonValue(),
        ])
    }

    // MARK: project inspect

    static func projectInspect(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        try ProjectAccess.read(context, request) { store, state in
            let stale = try store.staleNodes()
            var result: [String: JSONValue] = [
                "projectId": .string(state.projectId),
                "name": .string(state.name),
                "revision": .number(Double(state.revision)),
                "lock": try store.lock(),
                "objects": .number(Double(state.objects.count)),
                "stale": JSONValue(stale),
                "status": stale.isEmpty ? "complete" : "draft",
            ]
            if let template = state.template { result["template"] = try template.jsonValue() }
            return .object(result)
        }
    }

    // MARK: history list

    static func historyList(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        try ProjectAccess.read(context, request) { store, state in
            let limit = request["limit"]?.int ?? 100
            let numbers = Array(try store.revisionNumbers().reversed().prefix(limit))
            let revisions: [JSONValue] = try numbers.map { n in
                let record = try store.revision(n)
                var o: [String: JSONValue] = ["revision": .number(Double(record.revision)), "objects": .number(Double(record.state.objects.count))]
                o["parent"] = record.parent.map { .number(Double($0)) } ?? .null
                o["requestId"] = record.requestId.map { .string($0) } ?? .null
                o["operation"] = record.operation.map { .string($0) } ?? .null
                o["invalidations"] = JSONValue(record.plan?.invalidations ?? [])
                o["edits"] = .number(Double(record.plan?.edits.count ?? 0))
                return .object(o)
            }
            let receipts: [JSONValue] = try store.receipts().reversed().prefix(limit).map { r in
                [
                    "requestId": .string(r.requestId), "payloadHash": .string(r.payloadHash), "revisionBefore": .number(Double(r.revisionBefore)),
                    "revisionAfter": .number(Double(r.revisionAfter)), "status": .string(r.result.status.rawValue),
                    "operation": try store.revision(r.revisionAfter).operation.map { .string($0) } ?? .null,
                ]
            }
            return ["revisions": .array(revisions), "receipts": .array(receipts)]
        }
    }

    // MARK: history restore

    static func historyRestore(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        ProjectAccess.mutation(context, request, operation: "history restore") { store, tx in
            guard let target = request["revision"]?.int else { throw AuthorError.invalidRequest("revision is required.", path: "/revision") }
            let snapshot = try store.revision(target).state
            let current = tx.state
            for id in Set(current.objects.keys).union(snapshot.objects.keys).sorted(by: CompiledAvatar.precedes) where current.objects[id] != snapshot.objects[id] {
                if let kind = (current.object(id: id) ?? snapshot.object(id: id))?.kind {
                    for node in DependencyNode.invalidations(objectId: id, kind: kind) { tx.invalidate(node) }
                }
            }
            if current.recipe != snapshot.recipe || current.style != snapshot.style || !tx.invalidations.isEmpty { tx.invalidate(DependencyNode.qa) }
            tx.restore(snapshot)
            return ["invalidations": JSONValue(tx.invalidations)]
        }
    }
}
