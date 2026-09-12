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

/// `deliver`: resolves the ledger, requires a passing QA report and inspection
/// coverage for the exact bytes, signs the frozen VRM into a detached sidecar
/// and writes the bundle atomically. The input VRM is never modified.
public enum DeliverHandler {

    public static func deliver(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        let requestId = ProvenanceHandlers.requestId(request)
        let store = try ProvenanceHandlers.store(context)
        let mutex = try ProcessMutex(path: store.root.appendingPathComponent(".mutex").path)
        defer { mutex.release() }

        let payloadHash = try ProjectStore.payloadHash(request)
        if let receipt = try store.receipt(requestId: requestId) {
            guard receipt.payloadHash == payloadHash else {
                throw AuthorError(code: .requestIdReused, path: "/requestId", observed: .string(payloadHash), required: .string(receipt.payloadHash),
                                  message: "requestId '\(requestId)' was already used with a different delivery payload.", suggestedCommands: ["history list"])
            }
            return receipt.result
        }

        let state = try store.state()
        let revision = state.revision
        guard let filePath = request["file"]?.string, let reportPath = request["report"]?.string, let signer = request["signer"]?.string, let outPath = request["out"]?.string else {
            throw AuthorError.invalidRequest("file, report, signer, trustPolicy and out are required.", path: "/")
        }
        let outURL = ProvenanceHandlers.url(outPath, in: context)
        let replace = request["replace"]?.bool ?? false
        if FileManager.default.fileExists(atPath: outURL.path), !replace {
            throw AuthorError(code: .invalidRequest, path: "/out", observed: .string(outPath), message: "Output '\(outPath)' already exists; pass replace=true to replace it atomically.",
                              suggestedCommands: ["deliver --replace true"])
        }

        var errors: [AuthorError] = []
        var incomplete = false
        func fail(_ error: AuthorError) { errors.append(error) }
        func block(_ error: AuthorError) { errors.append(error); incomplete = true }

        let (fileURL, vrmData) = try ProvenanceHandlers.readFile(filePath, field: "/file", in: context)
        let vrmSha = SHA256Hex.hex(vrmData)

        var reportJSON: JSONValue = .null
        var reportData = Data()
        if let (_, data) = try? ProvenanceHandlers.readFile(reportPath, field: "/report", in: context) {
            reportData = data
            do { reportJSON = try JSONValue.parse(data) } catch {
                fail(AuthorError(code: .reportMismatch, path: "/report", message: "QA report is not valid JSON: \(error)", suggestedCommands: ["export verify"]))
            }
            if !reportJSON.isNull {
                let reportHash = reportJSON["fileSha256"]?.string
                if reportHash != vrmSha {
                    fail(AuthorError(code: .reportMismatch, path: "/report", observed: reportHash.map { .string($0) } ?? .null, required: .string(vrmSha),
                                     message: "QA report fileSha256 does not match the file being delivered; re-run export verify on the exact bytes.", suggestedCommands: ["export verify"]))
                }
                if reportJSON["status"]?.string != "pass" {
                    fail(AuthorError(code: .gateFailed, path: "/report", observed: reportJSON["status"] ?? .null, required: "pass",
                                     message: "QA report status must be pass for delivery.", suggestedCommands: ["export verify", "qa run"]))
                }
            }
        } else {
            block(AuthorError(code: .missingInput, path: "/report", observed: .string(reportPath), message: "QA report '\(reportPath)' was not found.", suggestedCommands: ["export verify"]))
        }

        let inspections = try InspectionCoverage.coverage(for: vrmSha, in: store)
        if inspections.passCount == 0 {
            block(AuthorError(code: .inspectionMissing, path: "reports/inspections/\(vrmSha)", observed: inspections.json,
                              message: "No passing inspection record is bound to sha256 \(vrmSha).", suggestedCommands: ["inspection record", "inspection verify"]))
        }
        if inspections.failCount > 0 || inspections.uncertainCount > 0 {
            fail(AuthorError(code: .gateFailed, path: "reports/inspections/\(vrmSha)", observed: inspections.json,
                             message: "Inspection records for these bytes include fail or uncertain verdicts.", suggestedCommands: ["inspection verify"]))
        }

        let ledger = try RightsLedger.load(store)
        guard let active = ledger.active else {
            block(AuthorError(code: .missingInput, path: "assets/\(RightsLedger.fileName)", message: "No resolved rights declaration in the ledger; run provenance resolve first.",
                              suggestedCommands: ["provenance resolve"]))
            return outcome(requestId: requestId, revision: revision, errors: errors, incomplete: incomplete)
        }
        if !active.resolution.isClean { for conflict in active.resolution.conflicts { fail(conflict.authorError) } }

        var policy: TrustPolicy?
        do { policy = try TrustPolicy.load(blob: try ProvenanceHandlers.blob(request, field: "trustPolicy"), relativeTo: context.cwd) } catch let error as AuthorError {
            block(AuthorError(code: .missingCredential, path: error.path, observed: error.observed, required: error.required, message: error.message, suggestedCommands: ["doctor"]))
        }
        var sidecarSigner: SidecarSigner?
        if let policy {
            do { sidecarSigner = try SidecarSigner(signer: signer, policy: policy) } catch let error as AuthorError {
                if error.code == .missingCredential { block(error) } else { fail(error) }
            }
            if sidecarSigner != nil, !policy.trusted.contains(signer) {
                fail(AuthorError(code: .untrustedSigner, path: "/signer", observed: .string(signer), required: JSONValue(policy.trusted.sorted()),
                                 message: "Signer '\(signer)' is configured but not trusted by the policy.", suggestedCommands: ["provenance verify"]))
            }
        }
        guard errors.isEmpty, let policy, let sidecarSigner else {
            return outcome(requestId: requestId, revision: revision, errors: errors, incomplete: incomplete)
        }

        let claim = Sidecar.Claim(assetSha256: vrmSha, assetSizeBytes: vrmData.count, generator: "\(context.toolInfo.tool)/\(context.toolInfo.version)", createdAtRevision: revision,
                                  buildHash: reportJSON["buildHash"]?.string, ingredients: try ledger.ingredientEntries(), training: active.declaration.training?.cawgAssertion,
                                  actions: [["action": "c2pa.created", "softwareAgent": .string("\(context.toolInfo.tool)/\(context.toolInfo.version)")]] + generationActions(ledger))
        let document = try sidecarSigner.sign(claim)
        let sidecarData = try document.canonicalData()
        let verification = SidecarVerification.verify(document: document, assetData: vrmData, policy: policy, manifestPath: "avatar.vrm\(Sidecar.suffix)")
        guard verification.isValid else {
            return .failed(requestId: requestId, revision: revision, errors: verification.errors, result: ["verdict": "failed", "sidecar": .object(verification.resultFields)])
        }

        let bundle = try writeBundle(at: outURL, replace: replace, store: store, vrmData: vrmData, sidecarData: sidecarData, reportData: reportData,
                                     inspections: inspections, vrmSha: vrmSha, verification: verification, ledger: ledger, revision: revision)
        guard SHA256Hex.hex(try Data(contentsOf: fileURL)) == vrmSha else {
            throw AuthorError(code: .internalError, path: filePath, message: "Input VRM changed during delivery.")
        }
        var envelope = ResultEnvelope.succeeded(requestId: requestId, revisionBefore: revision, revisionAfter: revision, result: [
            "verdict": "delivered", "artifacts": try JSONValue.from(bundle), "sidecar": try JSONValue.from(document), "ingredients": .array(claim.ingredients),
        ])
        envelope.artifacts = bundle
        let receipt = Receipt(requestId: requestId, payloadHash: payloadHash, revisionBefore: revision, revisionAfter: revision, result: envelope)
        try store.atomicWrite(try CanonicalJSON.encode(receipt), to: store.receiptsDirectory.appendingPathComponent(ProjectStore.receiptFileName(requestId)))
        return envelope
    }

    static func generationActions(_ ledger: RightsLedger) -> [JSONValue] {
        ledger.assets.compactMap { asset -> JSONValue? in
            guard let generation = asset.generation else { return nil }
            var action: [String: JSONValue] = ["action": .string(generation.action), "ingredient": .string(asset.id), "softwareAgent": .string("\(generation.tool)/\(generation.version)")]
            if let type = generation.digitalSourceType { action["digitalSourceType"] = .string(type) }
            if let model = generation.model { action["model"] = .string(model) }
            return .object(action)
        }
    }

    static func outcome(requestId: String, revision: Int, errors: [AuthorError], incomplete: Bool) -> ResultEnvelope {
        let result: JSONValue = ["verdict": incomplete ? "incomplete" : "failed", "artifacts": [], "ingredients": []]
        return incomplete ? .incomplete(requestId: requestId, revision: revision, errors: errors, result: result) : .failed(requestId: requestId, revision: revision, errors: errors, result: result)
    }

    /// Builds the bundle in a sibling temp directory and renames it into place.
    static func writeBundle(at outURL: URL, replace: Bool, store: ProjectStore, vrmData: Data, sidecarData: Data, reportData: Data, inspections: InspectionCoverageReport,
                            vrmSha: String, verification: SidecarVerification, ledger: RightsLedger, revision: Int) throws -> [ArtifactRef] {
        let fm = FileManager.default
        let parent = outURL.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let temp = parent.appendingPathComponent(outURL.lastPathComponent + ProjectStore.tempInfix + "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        var artifacts: [ArtifactRef] = []
        func put(_ data: Data, _ relative: String, _ mediaType: String, _ role: String) throws {
            let url = temp.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [])
            artifacts.append(ArtifactRef(path: outURL.appendingPathComponent(relative).path, sha256: SHA256Hex.hex(data), mediaType: mediaType, sizeBytes: data.count, role: role))
        }
        do {
            try put(vrmData, "avatar.vrm", "model/vrm", "avatar")
            try put(sidecarData, "avatar.vrm\(Sidecar.suffix)", "application/json", "credential")
            let lock = try Data(contentsOf: store.lockFile)
            try put(lock, "lock.json", "application/json", "lock")
            try put(try Data(contentsOf: store.projectFile), "project/project.json", "application/json", "project")
            try put(lock, "project/lock.json", "application/json", "project")
            try put(try CanonicalJSON.encode(ledger), "project/\(RightsLedger.fileName)", "application/json", "ledger")
            for number in try store.revisionNumbers() {
                let name = ProjectStore.revisionFileName(number)
                try put(try Data(contentsOf: store.revisionsDirectory.appendingPathComponent(name)), "project/revisions/\(name)", "application/json", "revision")
            }
            try put(reportData, "qa/report.json", "application/json", "qa-report")
            let inspectionDir = InspectionCoverage.directory(for: vrmSha, in: store)
            for name in inspections.records {
                try put(try Data(contentsOf: inspectionDir.appendingPathComponent(name)), "inspections/\(vrmSha)/\(name)", "application/json", "inspection")
            }
            let manifest: JSONValue = [
                "format": "vrm-author-delivery/1", "assetSha256": .string(vrmSha), "revision": .number(Double(revision)), "trust": verification.trust,
                "binding": verification.binding, "signature": verification.signature, "artifacts": try JSONValue.from(artifacts),
                "note": "avatar.vrm.c2pa.json is a detached Ed25519-signed sidecar with C2PA-shaped fields, not a COSE/JUMBF C2PA manifest.",
            ]
            try put(try CanonicalJSON.data(manifest), "delivery.json", "application/json", "delivery-manifest")
            if fm.fileExists(atPath: outURL.path) {
                let aside = parent.appendingPathComponent(outURL.lastPathComponent + ProjectStore.tempInfix + "replaced-\(UUID().uuidString)")
                guard rename(outURL.path, aside.path) == 0 else { throw AuthorError(code: .ioError, path: outURL.path, message: "cannot move existing output aside: \(String(cString: strerror(errno)))") }
                try? fm.removeItem(at: aside)
            }
            guard rename(temp.path, outURL.path) == 0 else { throw AuthorError(code: .ioError, path: outURL.path, message: "rename failed: \(String(cString: strerror(errno)))") }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        return artifacts
    }
}
