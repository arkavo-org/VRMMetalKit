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

/// Handlers for version, describe, capabilities, schema show and doctor.
public enum DiscoveryHandlers {
    public static let install: RegistryInstaller = { registry in
        registry.mustInstall(version, for: "version")
        registry.mustInstall(describe, for: "describe")
        registry.mustInstall(capabilities, for: "capabilities")
        registry.mustInstall(schemaShow, for: "schema show")
        registry.mustInstall(doctor, for: "doctor")
    }

    public static let names = ["version", "describe", "capabilities", "doctor", "schema show"]

    // MARK: version

    static func version(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        var info = try JSONValue.from(context.toolInfo)
        info = info.merging(["platform": .string(platformDescription())])
        return .succeeded(requestId: request["requestId"]?.string, result: info)
    }

    static func platformDescription() -> String {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion) \(arch)"
    }

    // MARK: describe

    public static func prerequisites(for operation: Operation) -> [String] {
        var out: [String] = []
        if operation.kind != .projectFree { out.append("existing project (project init)") }
        switch operation.name {
        case "build", "export vrm": out.append("no stale dependencies (recipe apply / control set)")
        case "qa run", "qa plan", "export verify": out.append("built VRM file")
        case "deliver": out += ["export verify report for the exact file", "inspection records", "configured signer and trust policy"]
        case "style lint": out += ["built VRM file", "python3 and pinned scripts/style_lint.py"]
        default: break
        }
        return out
    }

    public static func describeEntry(_ operation: Operation) -> JSONValue {
        var units: [String: JSONValue] = [:]
        for (pointer, unit) in operation.requestSchema.units() { units[pointer] = .string(unit) }
        return [
            "name": .string(operation.name),
            "rpcMethod": .string(operation.rpcMethod),
            "kind": .string(operation.kind.rawValue),
            "summary": .string(operation.summary),
            "result": .string(operation.resultDescription),
            "requestSchema": operation.requestSchema.json,
            "resultSchema": operation.resultSchema.json,
            "schemaHash": .string(operation.schemaHash),
            "resultSchemaHash": .string(operation.resultSchemaHash),
            "examples": .array(operation.examples),
            "units": .object(units),
            "requiredEvidence": .string(operation.requiredEvidence.rawValue),
            "runnable": .bool(operation.isRunnable),
            "prerequisites": JSONValue(prerequisites(for: operation)),
        ]
    }

    static func describe(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        let requestId = request["requestId"]?.string
        let namespace = request["namespace"]?.string ?? "v1"
        if namespace == "reserved" {
            var envelope = ResultEnvelope.succeeded(requestId: requestId, result: ["namespace": "reserved", "commands": [], "models": []])
            envelope.warnings = [AuthorWarning(code: "RESERVED_NAMESPACE_EMPTY", message: "No reserved-namespace schemas are registered in this build.")]
            return envelope
        }
        if let name = request["command"]?.string {
            guard let op = context.registry.operation(named: name) else {
                throw AuthorError(code: .invalidRequest, path: "/command", observed: .string(name), message: "Unknown command '\(name)'.", suggestedCommands: ["describe"])
            }
            return .succeeded(requestId: requestId, result: ["namespace": "v1", "commands": [describeEntry(op)], "models": JSONValue(ModelSchemas.byName.keys.sorted())])
        }
        let commands = context.registry.ordered.map(describeEntry)
        return .succeeded(requestId: requestId, result: ["namespace": "v1", "commands": .array(commands), "models": JSONValue(ModelSchemas.byName.keys.sorted())])
    }

    // MARK: capabilities

    public static func renderers(context: OperationContext) -> [String] {
        var found: [String] = []
        if let configured = context.env["VRM_AUTHOR_RENDERER"], FileManager.default.isExecutableFile(atPath: configured) { found.append(configured) }
        if let dir = context.executableURL?.deletingLastPathComponent() {
            let candidate = dir.appendingPathComponent("VRMAuthorRender")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { found.append("VRMAuthorRender") }
        }
        return found
    }

    public static func signerAvailable(context: OperationContext) -> Bool { false }

    static func capabilities(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        let requestId = request["requestId"]?.string
        var warnings: [AuthorWarning] = []
        var policy = EvidencePolicy.release
        if let path = request["evidencePolicy"]?.string {
            let url = URL(fileURLWithPath: path, relativeTo: context.cwd)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw AuthorError(code: .missingInput, path: "/evidencePolicy", observed: .string(path), message: "Evidence policy file not found.", suggestedCommands: ["capabilities"])
            }
            let loaded: EvidencePolicy
            do { loaded = try EvidencePolicy.load(url) } catch let error as ModelValidationError { throw error.errors.first ?? AuthorError.invalidRequest("Invalid evidence policy.") }
            if !loaded.requireCurrent {
                warnings.append(AuthorWarning(code: "EVIDENCE_POLICY_NOT_WEAKENED", message: "requireCurrent=false is ignored; caller policies cannot weaken release gates.", path: "/evidencePolicy"))
            }
            policy = EvidencePolicy(minimumLevel: loaded.minimumLevel, requireCurrent: true)
        }
        for warning in context.evidenceRegistry.loadWarnings {
            warnings.append(AuthorWarning(code: "EVIDENCE_LOAD", message: warning))
        }
        let entries = try context.registry.ordered.map { try JSONValue.from(context.evidenceRegistry.capability(for: $0, toolInfo: context.toolInfo, policy: policy)) }
        let importsRunnable = context.registry.operation(named: "asset import")?.isRunnable ?? false
        var result: [String: JSONValue] = [
            "target": .string(request["target"]?.string ?? "portable-vrm1"),
            "entries": .array(entries),
            "targets": ["portable-vrm1"],
            "templateHashes": .object(context.templates.templateHashes().mapValues { .string($0) }),
            "supportedImports": importsRunnable ? JSONValue(AssetKind.allCases.map(\.rawValue)) : [],
            "backends": ["portable-strict/1"],
            "renderers": JSONValue(renderers(context: context)),
            "signerAvailable": .bool(signerAvailable(context: context)),
            "evidencePolicy": try JSONValue.from(policy),
        ]
        if let commit = context.evidenceRegistry.pinnedCommit { result["pinnedCommit"] = .string(commit) }
        var envelope = ResultEnvelope.succeeded(requestId: requestId, result: .object(result))
        envelope.warnings = warnings
        return envelope
    }

    // MARK: schema show

    static func schemaShow(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        let requestId = request["requestId"]?.string
        guard let name = request["name"]?.string else { throw AuthorError.invalidRequest("name is required.", path: "/name") }
        if let op = context.registry.operation(named: name) {
            return .succeeded(requestId: requestId, result: [
                "name": .string(name), "kind": "operation-request", "schema": op.requestSchema.json, "schemaHash": .string(op.schemaHash),
                "leaves": JSONValue(op.requestSchema.leafPointers()), "applicability": JSONValue([op.kind.rawValue, "namespace:v1", "rpc:\(op.rpcMethod)"]),
            ])
        }
        if name.hasSuffix(" result"), let op = context.registry.operation(named: String(name.dropLast(7))) {
            return .succeeded(requestId: requestId, result: [
                "name": .string(name), "kind": "operation-result", "schema": op.resultSchema.json, "schemaHash": .string(op.resultSchemaHash),
                "leaves": JSONValue(op.resultSchema.leafPointers()), "applicability": JSONValue([op.name]),
            ])
        }
        if let schema = ModelSchemas.byName[name] {
            let canonical = try CanonicalJSON.string(schema.json)
            let users = context.registry.ordered.filter { (try? CanonicalJSON.string($0.requestSchema.json).contains(canonical)) ?? false }.map(\.name)
            return .succeeded(requestId: requestId, result: [
                "name": .string(name), "kind": "model", "schema": schema.json, "schemaHash": .string(schema.schemaHash),
                "leaves": JSONValue(schema.leafPointers()), "applicability": JSONValue(users),
            ])
        }
        throw AuthorError(code: .invalidRequest, path: "/name", observed: .string(name), message: "Unknown schema name '\(name)'.",
                          suggestedCommands: ["describe", "schema show Recipe"])
    }

    // MARK: doctor

    static func doctor(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        let requestId = request["requestId"]?.string
        var warnings: [AuthorWarning] = []
        let fm = FileManager.default

        let pythonPath = (context.env["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("python3").path }
            .first { fm.isExecutableFile(atPath: $0) }
        var python: [String: JSONValue] = ["found": .bool(pythonPath != nil)]
        if let pythonPath {
            python["path"] = .string(pythonPath)
            if let version = runCapturing(pythonPath, ["--version"], env: context.env) { python["version"] = .string(version.trimmingCharacters(in: .whitespacesAndNewlines)) }
        } else {
            warnings.append(AuthorWarning(code: "PYTHON3_MISSING", message: "python3 not found on PATH; style lint is unavailable."))
        }

        let repoRoot = context.evidenceRegistry.acceptanceDirectory?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let linterURL = repoRoot?.appendingPathComponent("scripts/style_lint.py")
        let linterFound = linterURL.map { fm.fileExists(atPath: $0.path) } ?? false
        let linterHash = linterFound ? try? SHA256Hex.hex(fileAt: linterURL!) : nil
        let pinned = context.evidenceRegistry.pinnedStyleLinterHash
        let linterMatches = linterHash != nil && pinned != nil && linterHash == pinned
        var linter: [String: JSONValue] = ["found": .bool(linterFound), "matches": .bool(linterMatches)]
        if let linterURL { linter["path"] = .string(linterURL.path) }
        if let linterHash { linter["sha256"] = .string(linterHash) }
        if let pinned { linter["pinnedSha256"] = .string(pinned) }
        if !linterFound { warnings.append(AuthorWarning(code: "STYLE_LINTER_MISSING", message: "scripts/style_lint.py not found relative to the acceptance directory.")) }
        else if !linterMatches { warnings.append(AuthorWarning(code: "STYLE_LINTER_UNPINNED", message: "scripts/style_lint.py does not match the pinned oracle hash.")) }

        let renderers = renderers(context: context)
        if renderers.isEmpty { warnings.append(AuthorWarning(code: "RENDERER_MISSING", message: "VRMAuthorRender not found next to the executable; authoring-v1 visual scenarios report incomplete.")) }
        warnings.append(AuthorWarning(code: "SIGNER_UNAVAILABLE", message: "No signer is configured; deliver returns incomplete."))

        var acceptance: [String: JSONValue] = ["packs": .number(Double(context.evidenceRegistry.packs.count)), "entries": .number(Double(context.evidenceRegistry.entries.count))]
        if let dir = context.evidenceRegistry.acceptanceDirectory { acceptance["directory"] = .string(dir.path) }
        if let commit = context.evidenceRegistry.pinnedCommit { acceptance["pinnedCommit"] = .string(commit) }
        acceptance["warnings"] = JSONValue(context.evidenceRegistry.loadWarnings)

        let result: JSONValue = [
            "python3": .object(python),
            "styleLinter": .object(linter),
            "renderer": ["found": .bool(!renderers.isEmpty), "renderers": JSONValue(renderers)],
            "signer": ["available": .bool(signerAvailable(context: context)), "reason": "no signer credential reference configured"],
            "determinism": ["backend": "portable-strict/1", "mode": "cpu-strict", "fastMath": false, "fmaContraction": false, "threads": 1,
                            "platform": .string(platformDescription()), "crossPlatformVerified": false],
            "acceptance": .object(acceptance),
            "ok": .bool(pythonPath != nil && linterMatches),
        ]
        var envelope = ResultEnvelope.succeeded(requestId: requestId, result: result)
        envelope.warnings = warnings
        return envelope
    }

    static func runCapturing(_ executable: String, _ arguments: [String], env: [String: String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

extension Registry {
    /// Installer helper: a wrong name or a double install is a programming error.
    public mutating func mustInstall(_ handler: @escaping OperationHandler, for name: String) {
        do { try install(handler: handler, for: name) } catch { preconditionFailure("\(error)") }
    }
}
