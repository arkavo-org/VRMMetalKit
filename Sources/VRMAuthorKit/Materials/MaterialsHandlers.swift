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

/// Handlers for `material shading`, `style attach` and `style lint`.
public enum MaterialsHandlers {
    public static let install: RegistryInstaller = { registry in
        registry.mustInstall(materialShading, for: "material shading")
        registry.mustInstall(styleAttach, for: "style attach")
        registry.mustInstall(styleLint, for: "style lint")
    }

    public static let names = ["style attach", "style lint", "material shading"]

    static func project(_ context: OperationContext, _ request: JSONValue) throws -> ProjectStore {
        let url = context.projectPath ?? request["project"]?.string.map { URL(fileURLWithPath: $0, relativeTo: context.cwd).standardizedFileURL }
        guard let url else { throw AuthorError(code: .projectNotFound, path: "/project", message: "project is required.", suggestedCommands: ["project init"]) }
        return try ProjectStore.open(at: url)
    }

    static func requestId(_ request: JSONValue) -> String {
        request["requestId"]?.string ?? UUID().uuidString.lowercased()
    }

    static func resolvePath(_ path: String, context: OperationContext) -> URL {
        URL(fileURLWithPath: path, relativeTo: context.cwd).standardizedFileURL
    }

    // MARK: material shading

    static func materialShading(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        guard let materialId = request["material"]?.string, let shadowEnd = request["shadowEnd"]?.number, let width = request["terminatorWidth"]?.number else {
            throw AuthorError.invalidRequest("material, shadowEnd and terminatorWidth are required.", path: "/")
        }
        let solution = try MaterialShading.solve(shadowEnd: shadowEnd, terminatorWidth: width)
        let store = try project(context, request)
        return try store.mutate(requestId: requestId(request), payload: request, expectedRevision: request["expectedRevision"]?.int,
                                dryRun: request["dryRun"]?.bool ?? false, expectedPlanHash: request["expectedPlanHash"]?.string, operation: "material shading") { tx in
            let object = try tx.object(id: materialId)
            guard object.kind == .material else {
                throw AuthorError(code: .invalidRequest, objectId: materialId, path: "/material", observed: .string(object.kind.rawValue), required: "material",
                                  message: "Object '\(materialId)' is a \(object.kind.rawValue), not a material.", suggestedCommands: ["object list"])
            }
            let validator: MutationTransaction.FieldValidator = { object, pointer, value in
                var fields = JSONValue.object(object.fields)
                try pointer.set(in: &fields, to: value)
                let violations = MaterialSchemas.mtoon.validate(fields["mtoon"] ?? .object([:]), pointer: "/mtoon")
                if let first = violations.first {
                    var error = first.authorError
                    error.objectId = object.id
                    throw error
                }
            }
            try tx.set(objectId: materialId, pointer: JSONPointer(tokens: ["mtoon", "shadingToonyFactor"]), value: .number(solution.shadingToonyFactor), validator: validator)
            try tx.set(objectId: materialId, pointer: JSONPointer(tokens: ["mtoon", "shadingShiftFactor"]), value: .number(solution.shadingShiftFactor), validator: validator)
            tx.invalidate("material:\(materialId)")
            tx.invalidate("build")
            tx.invalidate("qa")
            return solution.json
        }
    }

    // MARK: style attach

    public struct ProfileSummary: Sendable {
        public var id: String
        public var version: String
        public var title: String?
        public var roles: [String]
        public var ruleCount: Int
    }

    public static func summarizeProfile(_ json: JSONValue, path: String) throws -> ProfileSummary {
        guard let id = json["id"]?.string, let version = json["version"]?.string, let rules = json["rules"]?.array,
              let roles = json["material_roles"]?["roles"]?.array?.compactMap({ $0.string }), !roles.isEmpty else {
            throw AuthorError(code: .validationFailed, path: path, message: "Style profile must be a JSON object with id, version, rules[] and material_roles.roles[].",
                              suggestedCommands: ["style attach"])
        }
        return ProfileSummary(id: id, version: version, title: json["title"]?.string, roles: roles, ruleCount: rules.count)
    }

    static func loadBlob(_ raw: JSONValue?, pointer: String, context: OperationContext) throws -> (blob: Blob, url: URL, data: Data, sha256: String) {
        guard let raw else { throw AuthorError.invalidRequest("profile is required.", path: pointer) }
        let blob = try Blob.decode(raw)
        let url = resolvePath(blob.path, context: context)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AuthorError(code: .missingInput, path: pointer + "/path", observed: .string(blob.path), message: "File not found: \(url.path)", suggestedCommands: ["style attach"])
        }
        let data = try Data(contentsOf: url)
        let hash = SHA256Hex.hex(data)
        guard hash == blob.sha256 else {
            throw AuthorError(code: .invalidRequest, path: pointer + "/sha256", observed: .string(hash), required: .string(blob.sha256),
                              message: "\(url.path) does not match the declared sha256.", suggestedCommands: ["style attach"])
        }
        return (blob, url, data, hash)
    }

    static func styleAttach(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        let loaded = try loadBlob(request["profile"], pointer: "/profile", context: context)
        let json: JSONValue
        do { json = try JSONValue.parse(loaded.data) } catch {
            throw AuthorError(code: .validationFailed, path: "/profile/path", observed: .string(loaded.blob.path), message: "Style profile is not valid JSON: \(error)", suggestedCommands: ["style attach"])
        }
        let summary = try summarizeProfile(json, path: "/profile/path")
        let store = try project(context, request)
        let dryRun = request["dryRun"]?.bool ?? false
        return try store.mutate(requestId: requestId(request), payload: request, expectedRevision: request["expectedRevision"]?.int,
                                dryRun: dryRun, expectedPlanHash: request["expectedPlanHash"]?.string, operation: "style attach") { tx in
            if !dryRun { _ = try store.storeAsset(loaded.data) }
            let missingRoles = MaterialRole.allCases.map(\.rawValue).filter { !summary.roles.contains($0) }
            for role in missingRoles {
                tx.warnings.append(AuthorWarning(code: "ROLE_NOT_IN_PROFILE", message: "Material role '\(role)' is not in the profile vocabulary; its style checks report incomplete.", path: "/profile"))
            }
            let materialRoles = tx.state.objectIds.compactMap { id -> JSONValue? in
                guard let object = tx.state.object(id: id), object.kind == .material, let role = object.fields["role"]?.string else { return nil }
                return ["id": .string(id), "role": .string(role)]
            }
            tx.setStyle([
                "profile": [
                    "path": .string(loaded.blob.path),
                    "sha256": .string(loaded.sha256),
                    "asset": .string("assets/sha256/\(loaded.sha256)"),
                    "id": .string(summary.id),
                    "version": .string(summary.version),
                    "title": summary.title.map { .string($0) } ?? .null,
                    "ruleCount": .number(Double(summary.ruleCount)),
                    "pinned": .bool(loaded.sha256 == StyleToolchain.pinnedProfileSHA256),
                ],
                "roles": JSONValue(summary.roles),
                "materialRoles": .array(materialRoles),
            ])
            tx.invalidate("qa")
            return ["invalidations": JSONValue(tx.invalidations)]
        }
    }

    // MARK: style lint

    public struct LintOutcome: Sendable {
        public var report: JSONValue
        public var verdict: String
        public var oracleHashes: [String: String]
        public var mustFailures: [JSONValue]
        public var shouldFailures: [JSONValue]
    }

    /// Runs the pinned linter on `file` and parses its JSON report.
    public static func lint(file: URL, profileOverride: (url: URL, sha256: String)?, context: OperationContext) throws -> LintOutcome {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw AuthorError(code: .missingInput, path: "/file", observed: .string(file.path), message: "File not found: \(file.path)", suggestedCommands: ["build"])
        }
        let verified = try StyleToolchain.locate(context: context).verified(profileOverride: profileOverride)
        let run = try StyleToolchain.runLinter(python: verified.python, linter: verified.linter, profile: verified.profile, file: file, cwd: context.cwd, env: context.env)
        let parsed: JSONValue
        do { parsed = try JSONValue.parse(run.stdout) } catch {
            let tail = run.stderr.split(separator: "\n").suffix(3).joined(separator: " | ")
            throw AuthorError(code: .validationFailed, path: "/file", observed: .string(file.path), required: "GLB with VRMC_vrm or VRM extension",
                              message: "The style linter could not measure \(file.lastPathComponent) (exit \(run.exitStatus)): \(tail)", suggestedCommands: ["export verify", "doctor"])
        }
        guard let report = parsed.array?.first, let verdict = report["verdict"]?.string, let results = report["results"]?.array else {
            throw AuthorError(code: .internalError, path: "/file", message: "The style linter returned an unexpected JSON shape.", suggestedCommands: ["doctor"])
        }
        let must = results.filter { $0["severity"] == "must" && $0["status"] == "fail" }
        let should = results.filter { $0["severity"] == "should" && $0["status"] == "fail" }
        return LintOutcome(report: report, verdict: verdict, oracleHashes: verified.oracleHashes, mustFailures: must, shouldFailures: should)
    }

    static func styleLint(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        let requestId = request["requestId"]?.string
        guard let path = request["file"]?.string else { throw AuthorError.invalidRequest("file is required.", path: "/file") }
        let file = resolvePath(path, context: context)
        var warnings: [AuthorWarning] = []
        var override: (url: URL, sha256: String)?
        if let raw = request["profile"] {
            let loaded = try loadBlob(raw, pointer: "/profile", context: context)
            _ = try summarizeProfile(try JSONValue.parse(loaded.data), path: "/profile/path")
            override = (loaded.url, loaded.sha256)
            if loaded.sha256 != StyleToolchain.pinnedProfileSHA256 {
                warnings.append(AuthorWarning(code: "PROFILE_NOT_PINNED", message: "The supplied profile is not the pinned oracle; corpus evidence does not cover it.", path: "/profile/sha256"))
            }
        }
        let outcome = try lint(file: file, profileOverride: override, context: context)
        var result: [String: JSONValue] = [
            "report": outcome.report,
            "verdict": .string(outcome.verdict),
            "oracleHashes": .object(outcome.oracleHashes.mapValues { .string($0) }),
        ]
        var artifacts: [ArtifactRef] = []
        if request["project"]?.string != nil || context.projectPath != nil {
            let store = try project(context, request)
            let reportData = try CanonicalJSON.data(.object(result))
            let fileHash = try SHA256Hex.hex(fileAt: file)
            let url = store.reportsDirectory.appendingPathComponent("style-lint").appendingPathComponent(fileHash + ".json")
            try store.atomicWrite(reportData, to: url)
            artifacts.append(ArtifactRef(path: url.path, sha256: SHA256Hex.hex(reportData), mediaType: "application/json", sizeBytes: reportData.count, role: "style-lint-report"))
        }
        if !outcome.shouldFailures.isEmpty {
            let ids = outcome.shouldFailures.compactMap { $0["id"]?.string }
            warnings.append(AuthorWarning(code: "STYLE_SHOULD_FAILED", message: "should rules failed: \(ids.joined(separator: ", "))", path: "/report/results"))
        }
        var envelope: ResultEnvelope
        if outcome.mustFailures.isEmpty {
            envelope = .succeeded(requestId: requestId, result: .object(result))
        } else {
            let errors = outcome.mustFailures.map { rule -> AuthorError in
                let id = rule["id"]?.string ?? "?"
                let reason = rule["reason"]?.string ?? rule["subjects"]?.array?.first?["reason"]?.string ?? ""
                return AuthorError(code: .gateFailed, path: "/report/results/\(id)", observed: rule["observed"] ?? rule["subjects"], required: rule["check"],
                                   message: "must rule \(id) failed\(reason.isEmpty ? "" : ": \(reason)") (\(rule["title"]?.string ?? "")).",
                                   suggestedCommands: ["material shading", "object set", "control set"])
            }
            envelope = .failed(requestId: requestId, revision: nil, errors: errors, result: .object(result))
        }
        envelope.warnings = warnings
        envelope.artifacts = artifacts
        return envelope
    }
}
