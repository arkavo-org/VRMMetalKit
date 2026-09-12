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

/// Handlers for asset import/inspect, provenance inspect/resolve/verify and deliver.
public enum ProvenanceHandlers {
    public static let install: RegistryInstaller = { registry in
        registry.mustInstall(AssetHandlers.importAsset, for: "asset import")
        registry.mustInstall(AssetHandlers.inspectAsset, for: "asset inspect")
        registry.mustInstall(inspect, for: "provenance inspect")
        registry.mustInstall(resolve, for: "provenance resolve")
        registry.mustInstall(verify, for: "provenance verify")
        registry.mustInstall(DeliverHandler.deliver, for: "deliver")
    }

    public static let names = ["asset import", "asset inspect", "provenance inspect", "provenance resolve", "provenance verify", "deliver"]

    // MARK: Shared helpers

    static func store(_ context: OperationContext) throws -> ProjectStore {
        guard let path = context.projectPath else {
            throw AuthorError(code: .invalidRequest, path: "/project", message: "project is required.", suggestedCommands: ["project init"])
        }
        return try ProjectStore.open(at: path)
    }

    static func url(_ path: String, in context: OperationContext) -> URL {
        URL(fileURLWithPath: path, relativeTo: context.cwd).standardizedFileURL
    }

    static func requestId(_ request: JSONValue) -> String {
        request["requestId"]?.string ?? UUID().uuidString.lowercased()
    }

    static func readFile(_ path: String, field: String, in context: OperationContext) throws -> (URL, Data) {
        let url = url(path, in: context)
        guard let data = try? Data(contentsOf: url) else {
            throw AuthorError(code: .missingInput, path: field, observed: .string(path), message: "File '\(path)' was not found or is unreadable.", suggestedCommands: ["describe"])
        }
        return (url, data)
    }

    static func blob(_ request: JSONValue, field: String) throws -> Blob {
        guard let json = request[field] else { throw AuthorError.invalidRequest("\(field) is required.", path: "/\(field)") }
        return try Blob.decode(json)
    }

    /// Image IDs visible to the rights resolver: image objects in the project,
    /// imported raster assets, plus `packImageIds` (a template pack's own
    /// authored images, known before any build materializes them).
    static func knownImageIds(state: ProjectState, ledger: RightsLedger, packImageIds: Set<String> = []) -> Set<String> {
        var ids = ledger.imageIds
        ids.formUnion(packImageIds)
        for (id, json) in state.objects where json["kind"]?.string == ObjectKind.image.rawValue { ids.insert(id) }
        return ids
    }

    // MARK: provenance resolve

    static func resolve(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        let requestId = requestId(request)
        let store = try store(context)
        guard let declarationJSON = request["declaration"] else { throw AuthorError.invalidRequest("declaration is required.", path: "/declaration") }
        let declaration = try RightsResolver.decodeDeclaration(declarationJSON)
        let state = try store.state()
        let ledger = try RightsLedger.load(store)
        let packImageIds = context.templates.pack(id: state.template?.id ?? "")?.imageIds ?? []
        let resolver = RightsResolver(baseURL: context.cwd, knownImageIds: knownImageIds(state: state, ledger: ledger, packImageIds: packImageIds), ledger: ledger)
        let resolution = try resolver.resolve(declaration)
        let payload: JSONValue = [
            "meta": try JSONValue.from(resolution.meta),
            "attribution": try JSONValue.from(resolution.attributions),
            "conflicts": try JSONValue.from(resolution.conflicts),
        ]
        if !resolution.isClean {
            return .failed(requestId: requestId, revision: state.revision, errors: resolution.conflicts.map(\.authorError), result: payload)
        }
        let dryRun = request["dryRun"]?.bool ?? false
        return try store.mutate(requestId: requestId, payload: request, expectedRevision: request["expectedRevision"]?.int, dryRun: dryRun,
                                expectedPlanHash: request["expectedPlanHash"]?.string, operation: "provenance resolve") { tx in
            let target = tx.state.revision + 1
            var next = ledger
            next.upsert(LedgerDeclaration(declaration: declaration, resolution: resolution, resolvedAtRevision: target))
            tx.appendImport(["entry": "declaration", "id": .string(declaration.id), "declarant": .string(declaration.declarant), "authors": JSONValue(declaration.authors),
                             "metaSha256": .string(try CanonicalJSON.sha256(try JSONValue.from(declaration.meta)))])
            tx.invalidate("meta")
            if !dryRun { try next.write(store) }
            return payload
        }
    }

    // MARK: provenance verify

    static func verify(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        let requestId = request["requestId"]?.string
        guard let filePath = request["file"]?.string else { throw AuthorError.invalidRequest("file is required.", path: "/file") }
        guard let manifestPath = request["manifest"]?.string else { throw AuthorError.invalidRequest("manifest is required.", path: "/manifest") }
        let policy = try TrustPolicy.load(blob: try blob(request, field: "trustPolicy"), relativeTo: context.cwd)
        let (_, assetData) = try readFile(filePath, field: "/file", in: context)
        let manifestURL = url(manifestPath, in: context)
        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            return .failed(requestId: requestId, revision: nil, errors: [
                AuthorError(code: .missingInput, path: "/manifest", observed: .string(manifestPath), message: "Sidecar manifest '\(manifestPath)' was not found; the delivery bundle must ship the VRM with its \(Sidecar.suffix) sidecar.",
                            suggestedCommands: ["deliver"]),
            ], result: ["binding": ["status": "incomplete"], "signature": ["status": "incomplete"], "trust": ["status": "incomplete"], "verdict": "incomplete"])
        }
        let document: Sidecar.Document
        do { document = try Sidecar.Document.parse(manifestData, path: manifestPath) } catch let error as AuthorError {
            return .failed(requestId: requestId, revision: nil, errors: [error], result: ["binding": ["status": "incomplete"], "signature": ["status": "fail"], "trust": ["status": "incomplete"], "verdict": "fail"])
        }
        let verification = SidecarVerification.verify(document: document, assetData: assetData, policy: policy, manifestPath: manifestPath)
        let result = JSONValue.object(verification.resultFields)
        if verification.isValid { return .succeeded(requestId: requestId, result: result) }
        return .failed(requestId: requestId, revision: nil, errors: verification.errors, result: result)
    }

    // MARK: provenance inspect

    static func inspect(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        let requestId = request["requestId"]?.string
        let store = try store(context)
        let state = try store.state()
        let ledger = try RightsLedger.load(store)
        let assetId = request["asset"]?.string
        let filePath = request["file"]?.string
        if assetId != nil, filePath != nil {
            throw AuthorError(code: .conflictingArgument, path: "/asset", message: "provenance inspect takes exactly one of asset/file, or neither for the project ledger.", suggestedCommands: ["provenance inspect"])
        }
        let envPolicy = SignerAvailability.environmentPolicy(env: context.env, cwd: context.cwd)

        if let assetId {
            guard let asset = ledger.asset(id: assetId) else {
                throw AuthorError(code: .objectNotFound, objectId: assetId, path: "/asset", message: "No imported asset '\(assetId)'.", suggestedCommands: ["asset import", "provenance inspect"])
            }
            var ingredients = try ledger.ingredientEntries().filter { $0["id"]?.string == assetId }
            if let generation = asset.generation {
                for hash in generation.inputHashes { ingredients.append(["kind": "input", "sha256": .string(hash), "source": "generation.inputHashes"]) }
            }
            var result: [String: JSONValue] = ["ingredients": .array(ingredients), "binding": asset.credential["binding"] ?? ["status": "absent"],
                                               "signature": asset.credential["signature"] ?? ["status": "absent"], "trust": asset.credential["trust"] ?? ["status": "absent"]]
            if let declaration = asset.declaration { result["ingredients"] = .array(ingredients + [["kind": "declaration", "id": .string(declaration.id), "declarant": .string(declaration.declarant), "authors": JSONValue(declaration.authors)]]) }
            return .succeeded(requestId: requestId, revisionBefore: state.revision, revisionAfter: state.revision, result: .object(result))
        }

        if let filePath {
            let (fileURL, data) = try readFile(filePath, field: "/file", in: context)
            let sha = SHA256Hex.hex(data)
            var ingredients: [JSONValue] = [["kind": "file", "path": .string(filePath), "sha256": .string(sha), "sizeBytes": .number(Double(data.count))]]
            if let known = ledger.asset(sha256: sha) { ingredients.append(["kind": "asset", "id": .string(known.id), "sha256": .string(known.sha256), "importedAtRevision": .number(Double(known.importedAtRevision))]) }
            var binding: JSONValue = ["status": "absent", "reason": .string("no \(Sidecar.suffix) sidecar next to the file")]
            var signature: JSONValue = ["status": "absent"]
            var trust: JSONValue = ["status": "absent"]
            let sidecarURL = Sidecar.url(for: fileURL)
            if let sidecarData = try? Data(contentsOf: sidecarURL) {
                do {
                    let document = try Sidecar.Document.parse(sidecarData, path: sidecarURL.path)
                    let verification = SidecarVerification.verify(document: document, assetData: data, policy: envPolicy, manifestPath: sidecarURL.path)
                    binding = verification.binding
                    signature = verification.signature
                    trust = verification.trust
                    ingredients += document.claim.ingredients.map { $0.merging(["source": .string("sidecar")]) }
                } catch let error as AuthorError {
                    binding = ["status": "fail", "reason": .string(error.message)]
                    signature = ["status": "fail", "reason": .string(error.message)]
                    trust = ["status": "incomplete"]
                }
            }
            return .succeeded(requestId: requestId, revisionBefore: state.revision, revisionAfter: state.revision,
                              result: ["ingredients": .array(ingredients), "binding": binding, "signature": signature, "trust": trust])
        }

        var ingredients = try ledger.ingredientEntries()
        if let template = state.template { ingredients.append(["kind": "template", "id": .string(template.id), "sha256": .string(template.sha256)]) }
        if let style = state.style, let path = style["path"]?.string, let sha = style["sha256"]?.string { ingredients.append(["kind": "profile", "path": .string(path), "sha256": .string(sha)]) }
        for id in state.objectIds {
            guard let object = state.objects[id], object["kind"]?.string == ObjectKind.image.rawValue else { continue }
            var entry: [String: JSONValue] = ["kind": "image", "id": .string(id)]
            if let sha = object["sha256"]?.string ?? object["hash"]?.string ?? object["source"]?["sha256"]?.string { entry["sha256"] = .string(sha) }
            ingredients.append(.object(entry))
        }
        for entry in ledger.declarations {
            ingredients.append(["kind": "declaration", "id": .string(entry.declaration.id), "declarant": .string(entry.declaration.declarant), "authors": JSONValue(entry.declaration.authors),
                                "resolvedAtRevision": .number(Double(entry.resolvedAtRevision)), "conflicts": .number(Double(entry.resolution.conflicts.count)),
                                "active": .bool(ledger.activeDeclaration == entry.declaration.id)])
        }
        return .succeeded(requestId: requestId, revisionBefore: state.revision, revisionAfter: state.revision,
                          result: ["ingredients": .array(ingredients), "binding": ["status": "notApplicable"], "signature": ["status": "notApplicable"], "trust": ["status": "notApplicable"]])
    }
}
