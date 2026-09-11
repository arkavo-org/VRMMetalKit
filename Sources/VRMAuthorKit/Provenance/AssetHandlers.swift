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

public enum AssetHandlers {
    /// Credential status vocabulary for imported assets.
    public enum CredentialStatus: String, Sendable { case valid, invalid, absent, untrusted }

    static func decodeImport(_ json: JSONValue) throws -> AssetImport {
        let violations = AssetImport.schema.validate(json)
        if !violations.isEmpty { throw ModelValidationError(errors: violations.map { $0.authorError }) }
        let filled = AssetImport.schema.applyingDefaults(to: json)
        let model: AssetImport
        do { model = try filled.decode(AssetImport.self) } catch {
            throw ModelValidationError(errors: [AuthorError.invalidRequest("AssetImport could not be decoded: \(error)", path: "/asset")])
        }
        try model.generation?.validate()
        return model
    }

    // MARK: asset import

    static func importAsset(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        let requestId = ProvenanceHandlers.requestId(request)
        let store = try ProvenanceHandlers.store(context)
        guard let assetJSON = request["asset"] else { throw AuthorError.invalidRequest("asset is required.", path: "/asset") }
        let spec = try decodeImport(assetJSON)
        let (_, data) = try ProvenanceHandlers.readFile(spec.path, field: "/asset/path", in: context)
        let sha = SHA256Hex.hex(data)

        var preservation: PreservationReport?
        var image: ImageFacts?
        switch spec.kind {
        case .vrm, .gltf:
            if spec.kind == .vrm, !GLTFDocument.isGLB(data) {
                throw AuthorError(code: .invalidRequest, path: "/asset/path", observed: .string(spec.path), message: "A vrm import must be a glb container (bytes do not start with 'glTF').",
                                  suggestedCommands: ["asset import --kind gltf"])
            }
            let document = try GLTFDocument(data: data, path: spec.path)
            let report = PreservationReport(document: document)
            if spec.kind == .vrm, !report.rootExtensions.contains("VRMC_vrm") {
                throw AuthorError(code: .validationFailed, path: "/asset/path", observed: JSONValue(report.rootExtensions), required: ["VRMC_vrm"],
                                  message: "A vrm import must carry the VRMC_vrm extension; VRM 0.x files are not supported.", suggestedCommands: ["asset import --kind gltf"])
            }
            preservation = report
        case .png, .jpeg:
            guard let facts = ImageFacts.sniff(data), facts.format == spec.kind.rawValue else {
                throw AuthorError(code: .invalidRequest, path: "/asset/path", observed: .string(spec.path), message: "File bytes are not a \(spec.kind.rawValue) image.",
                                  suggestedCommands: ["asset import"])
            }
            image = facts
        }

        var conflicts: [RightsConflict] = []
        if let declaration = spec.declaration {
            let resolver = RightsResolver(baseURL: context.cwd, knownImageIds: [], ledger: RightsLedger())
            conflicts = try resolver.resolve(declaration).conflicts
        }
        if !conflicts.isEmpty {
            return .failed(requestId: requestId, revision: try store.state().revision, errors: conflicts.map(\.authorError), result: ["conflicts": try JSONValue.from(conflicts)])
        }

        let (credential, manifestData) = try credentialStatus(spec: spec, assetData: data, context: context)
        let dryRun = request["dryRun"]?.bool ?? false
        return try store.mutate(requestId: requestId, payload: request, expectedRevision: request["expectedRevision"]?.int, dryRun: dryRun,
                                expectedPlanHash: request["expectedPlanHash"]?.string, operation: "asset import") { tx in
            var ledger = try RightsLedger.load(store)
            let target = tx.state.revision + 1
            if let existing = ledger.asset(sha256: sha) {
                tx.warnings.append(AuthorWarning(code: "ASSET_ALREADY_IMPORTED", message: "Bytes with sha256 \(sha) were already imported as '\(existing.id)'.", path: "/asset/path"))
                return try importResult(existing, status: existing.credential["status"]?.string ?? CredentialStatus.absent.rawValue)
            }
            let id = ledger.assetId(for: sha)
            let entry = LedgerAsset(id: id, kind: spec.kind, sha256: sha, sizeBytes: data.count, sourceUri: spec.sourceUri, generation: spec.generation,
                                    declaration: spec.declaration, importedAtRevision: target, preservation: preservation, image: image,
                                    credential: credential.report, manifestSha256: manifestData.map { SHA256Hex.hex($0) })
            ledger.upsert(entry)
            let ledgerEntry = try JSONValue.from(entry)
            tx.appendImport(ledgerEntry.merging(["entry": "asset"]))
            tx.artifacts.append(ArtifactRef(path: "assets/sha256/\(sha)", sha256: sha, mediaType: mediaType(spec.kind), sizeBytes: data.count, role: "ingredient"))
            if !dryRun {
                _ = try store.storeAsset(data)
                if let manifestData { _ = try store.storeAsset(manifestData) }
                try ledger.write(store)
            }
            return try importResult(entry, status: credential.status.rawValue)
        }
    }

    static func mediaType(_ kind: AssetKind) -> String {
        switch kind {
        case .vrm: return "model/vrm"
        case .gltf: return "model/gltf-binary"
        case .png: return "image/png"
        case .jpeg: return "image/jpeg"
        }
    }

    static func importResult(_ entry: LedgerAsset, status: String) throws -> JSONValue {
        var ingredient = try JSONValue.from(entry)
        ingredient = ingredient.merging(["extensionCoverage": extensionCoverage(entry.preservation)])
        return [
            "asset": .string(entry.id), "sha256": .string(entry.sha256), "kind": .string(entry.kind.rawValue),
            "lossReport": entry.preservation?.lossReport ?? ["preserved": ["bytes"], "lost": [], "converted": []],
            "ingredient": ingredient, "credentialStatus": .string(status),
        ]
    }

    static func extensionCoverage(_ report: PreservationReport?) -> JSONValue {
        guard let report else { return ["roundTrip": [], "preservedOpaque": [], "supported": JSONValue(PreservationReport.roundTripExtensions)] }
        return ["roundTrip": JSONValue(report.roundTripExtensions), "preservedOpaque": JSONValue(report.preservedOpaqueExtensions), "supported": JSONValue(PreservationReport.roundTripExtensions)]
    }

    struct Credential {
        var status: CredentialStatus
        var report: JSONValue
    }

    /// Validates an external sidecar named by `manifestPath`. Embedded
    /// credentials are reported absent: there is no interoperable glb
    /// embedding convention to detect.
    static func credentialStatus(spec: AssetImport, assetData: Data, context: OperationContext) throws -> (Credential, Data?) {
        guard let manifestPath = spec.manifestPath else {
            return (Credential(status: .absent, report: ["status": "absent", "embedded": false, "reason": "no manifestPath supplied and no embedded credential detected"]), nil)
        }
        let (_, manifestData) = try ProvenanceHandlers.readFile(manifestPath, field: "/asset/manifestPath", in: context)
        let document: Sidecar.Document
        do { document = try Sidecar.Document.parse(manifestData, path: manifestPath) } catch let error as AuthorError {
            return (Credential(status: .invalid, report: ["status": "invalid", "embedded": false, "reason": .string(error.message)]), manifestData)
        }
        let policy = SignerAvailability.environmentPolicy(env: context.env, cwd: context.cwd)
        let verification = SidecarVerification.verify(document: document, assetData: assetData, policy: policy, manifestPath: manifestPath)
        let status: CredentialStatus
        switch verification.verdict {
        case "pass": status = .valid
        case "incomplete": status = .untrusted
        default: status = verification.trust["status"]?.string == "fail" && verification.binding["status"]?.string == "pass" && verification.signature["status"]?.string == "pass" ? .untrusted : .invalid
        }
        var report = verification.resultFields
        report["status"] = .string(status.rawValue)
        report["embedded"] = false
        report["manifestSha256"] = .string(SHA256Hex.hex(manifestData))
        return (Credential(status: status, report: .object(report)), manifestData)
    }

    // MARK: asset inspect

    static func inspectAsset(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        let requestId = request["requestId"]?.string
        let store = try ProvenanceHandlers.store(context)
        let state = try store.state()
        guard let id = request["id"]?.string else { throw AuthorError.invalidRequest("id is required.", path: "/id") }
        let ledger = try RightsLedger.load(store)
        guard let asset = ledger.asset(id: id) else {
            throw AuthorError(code: .objectNotFound, objectId: id, path: "/id", message: "No imported asset '\(id)'.", suggestedCommands: ["asset import", "provenance inspect"])
        }
        let stored = store.assetsDirectory.appendingPathComponent(asset.sha256)
        var assetJSON = try JSONValue.from(asset)
        assetJSON = assetJSON.merging(["storedPath": .string(stored.path), "storedBytesPresent": .bool(FileManager.default.fileExists(atPath: stored.path)),
                                       "extensionCoverage": extensionCoverage(asset.preservation)])
        var geometry: JSONValue = .null
        var textures: JSONValue = .null
        var extensions: [String] = []
        if let p = asset.preservation {
            geometry = ["nodes": .number(Double(p.nodes)), "meshes": .number(Double(p.meshes)), "primitives": .number(Double(p.primitives)), "triangles": .number(Double(p.triangles)),
                        "degenerateTriangles": .number(Double(p.degenerateTriangles)), "unindexedPrimitives": .number(Double(p.unindexedPrimitives)), "skins": .number(Double(p.skins)),
                        "humanoidPresent": .bool(p.humanoidPresent), "humanBones": .number(Double(p.humanBones)), "expressions": .number(Double(p.expressions)),
                        "springs": .number(Double(p.springs)), "colliders": .number(Double(p.colliders)), "colliderGroups": .number(Double(p.colliderGroups))]
            textures = ["images": JSONValue(p.images), "textures": .number(Double(p.textures)), "materials": .number(Double(p.materials))]
            extensions = p.roundTripExtensions.map { "\($0):round-trip" } + p.preservedOpaqueExtensions.map { "\($0):preserved-opaque" }
        } else if let image = asset.image {
            textures = try JSONValue.from(image)
        }
        return .succeeded(requestId: requestId, revisionBefore: state.revision, revisionAfter: state.revision, result: [
            "asset": assetJSON, "geometry": geometry, "textures": textures, "extensions": JSONValue(extensions),
            "credentialStatus": asset.credential["status"] ?? .string(CredentialStatus.absent.rawValue),
        ])
    }
}
