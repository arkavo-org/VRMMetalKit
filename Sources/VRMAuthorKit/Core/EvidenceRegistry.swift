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

public enum EvidenceStatus: String, Codable, Hashable, Sendable, CaseIterable { case current, stale, failed, pending }

public enum DimensionStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case notApplicable, pass, fail, pending
}

public struct DimensionRecord: Codable, Hashable, Sendable {
    public var status: DimensionStatus
    public var reportHash: String?

    public init(status: DimensionStatus, reportHash: String? = nil) {
        self.status = status
        self.reportHash = reportHash
    }
}

public let evidenceDimensions = ["fixture", "corpus", "visual", "interoperability", "provenance"]

/// One admitted evaluator receipt in acceptance/evidence.json `entries[]`.
public struct EvidenceEntry: Codable, Hashable, Sendable {
    public var operation: String
    public var packHash: String
    public var requestSchemaHash: String?
    public var buildHash: String?
    public var resultHash: String?
    public var evidenceLevel: EvidenceLevel
    public var evidenceStatus: EvidenceStatus
    public var dimensions: [String: DimensionRecord]
    public var scope: JSONValue?
    public var evaluators: [JSONValue]
    public var evaluationPolicyHash: String?
    public var artifactRefs: [String]
    public var pinnedCommit: String?

    public init(operation: String, packHash: String, requestSchemaHash: String? = nil, buildHash: String? = nil, resultHash: String? = nil,
                evidenceLevel: EvidenceLevel, evidenceStatus: EvidenceStatus, dimensions: [String: DimensionRecord] = [:], scope: JSONValue? = nil,
                evaluators: [JSONValue] = [], evaluationPolicyHash: String? = nil, artifactRefs: [String] = [], pinnedCommit: String? = nil) {
        self.operation = operation
        self.packHash = packHash
        self.requestSchemaHash = requestSchemaHash
        self.buildHash = buildHash
        self.resultHash = resultHash
        self.evidenceLevel = evidenceLevel
        self.evidenceStatus = evidenceStatus
        self.dimensions = dimensions
        self.scope = scope
        self.evaluators = evaluators
        self.evaluationPolicyHash = evaluationPolicyHash
        self.artifactRefs = artifactRefs
        self.pinnedCommit = pinnedCommit
    }
}

/// The subset of an acceptance pack the registry needs.
public struct AcceptancePackSummary: Codable, Hashable, Sendable {
    public var id: String
    public var operation: String
    public var packHash: String
    public var requestSchemaHash: String
    public var resultSchemaHash: String
    public var requiredLevel: EvidenceLevel
    public var dimensions: [String: String]
    public var oracleHashes: [String: String]
    public var runnerKind: String
    public var entryPoint: String
    public var path: String

    public init(id: String, operation: String, packHash: String, requestSchemaHash: String, resultSchemaHash: String, requiredLevel: EvidenceLevel,
                dimensions: [String: String], oracleHashes: [String: String], runnerKind: String, entryPoint: String, path: String) {
        self.id = id
        self.operation = operation
        self.packHash = packHash
        self.requestSchemaHash = requestSchemaHash
        self.resultSchemaHash = resultSchemaHash
        self.requiredLevel = requiredLevel
        self.dimensions = dimensions
        self.oracleHashes = oracleHashes
        self.runnerKind = runnerKind
        self.entryPoint = entryPoint
        self.path = path
    }

    public static func parse(_ json: JSONValue, path: String) throws -> AcceptancePackSummary {
        guard let id = json["id"]?.string, let operation = json["operation"]?.string, let packHash = json["packHash"]?.string,
              let policy = json["evidencePolicy"], let levelText = policy["requiredLevel"]?.string, let level = EvidenceLevel(rawValue: levelText),
              let runner = json["runner"], let kind = runner["kind"]?.string, let entry = runner["entryPoint"]?.string else {
            throw AuthorError(code: .validationFailed, path: path, message: "Acceptance pack is missing id/operation/packHash/evidencePolicy/runner.")
        }
        let dims = (policy["dimensions"]?.object ?? [:]).compactMapValues { $0.string }
        let oracles = (runner["environment"]?["oracleHashes"]?.object ?? [:]).compactMapValues { $0.string }
        return AcceptancePackSummary(id: id, operation: operation, packHash: packHash, requestSchemaHash: json["requestSchemaHash"]?.string ?? "",
                                     resultSchemaHash: json["resultSchemaHash"]?.string ?? "", requiredLevel: level, dimensions: dims,
                                     oracleHashes: oracles, runnerKind: kind, entryPoint: entry, path: path)
    }
}

/// Caller evidence policy (`--evidence-policy PATH`): may only tighten the release policy.
public struct EvidencePolicy: Codable, Hashable, Sendable {
    public var minimumLevel: EvidenceLevel
    public var requireCurrent: Bool

    public init(minimumLevel: EvidenceLevel = .schemaOnly, requireCurrent: Bool = true) {
        self.minimumLevel = minimumLevel
        self.requireCurrent = requireCurrent
    }

    public static let release = EvidencePolicy()
    public static let schema = JSONSchema.object(properties: [
        "minimumLevel": .enumeration(EvidenceLevel.allCases.map(\.rawValue)).defaulting(to: "schema-only"),
        "requireCurrent": .boolean().defaulting(to: true),
    ], required: [])

    public static func load(_ url: URL) throws -> EvidencePolicy {
        let json = try JSONValue.parse(try Data(contentsOf: url))
        let violations = EvidencePolicy.schema.validate(json)
        if !violations.isEmpty { throw ModelValidationError(errors: violations.map { $0.authorError }) }
        return try EvidencePolicy.schema.applyingDefaults(to: json).decode(EvidencePolicy.self)
    }

    /// Effective requirement for one operation: the stricter of the release policy and the caller's.
    public func effectiveLevel(for operation: Operation) -> EvidenceLevel {
        max(operation.requiredEvidence, minimumLevel)
    }

    public var hash: String {
        (try? CanonicalJSON.sha256(["minimumLevel": .string(minimumLevel.rawValue), "requireCurrent": .bool(requireCurrent)])) ?? ""
    }
}

public struct CapabilityEntry: Codable, Hashable, Sendable {
    public var operation: String
    public var schemaHash: String
    public var implementationHash: String?
    public var backendHash: String
    public var availability: String
    public var evidenceLevel: EvidenceLevel
    public var evidenceStatus: EvidenceStatus
    public var dimensions: [String: DimensionRecord]
    public var scope: JSONValue
    public var acceptancePackHash: String?
    public var evaluationPolicyHash: String
    public var evaluators: [JSONValue]
    public var runnable: Bool
    public var productionEligible: Bool
    public var blockers: [String]
    public var artifactRefs: [String]
    public var requiredEvidence: EvidenceLevel
}

/// Reads acceptance/evidence.json and acceptance/packs/*.json to compute
/// `capabilities` entries. Never writes evidence.
public struct EvidenceRegistry: Sendable {
    public var entries: [EvidenceEntry]
    public var packs: [String: AcceptancePackSummary]
    public var pinnedCommit: String?
    public var acceptanceDirectory: URL?
    public var loadWarnings: [String]

    public init(entries: [EvidenceEntry] = [], packs: [String: AcceptancePackSummary] = [:], pinnedCommit: String? = nil, acceptanceDirectory: URL? = nil, loadWarnings: [String] = []) {
        self.entries = entries
        self.packs = packs
        self.pinnedCommit = pinnedCommit
        self.acceptanceDirectory = acceptanceDirectory
        self.loadWarnings = loadWarnings
    }

    public static let relativePath = "docs/proposals/vrm-author-cli/acceptance"
    public static let environmentKey = "VRM_AUTHOR_ACCEPTANCE_DIR"

    /// env override → walk up from cwd → walk up from the executable.
    public static func locate(cwd: URL, executableURL: URL?, env: [String: String]) -> URL? {
        let fm = FileManager.default
        if let override = env[environmentKey], !override.isEmpty {
            let url = URL(fileURLWithPath: override, relativeTo: cwd).standardizedFileURL
            return fm.fileExists(atPath: url.appendingPathComponent("evidence.json").path) ? url : nil
        }
        for start in [cwd, executableURL?.deletingLastPathComponent()].compactMap({ $0 }) {
            var dir = start.standardizedFileURL
            while true {
                let candidate = dir.appendingPathComponent(relativePath)
                if fm.fileExists(atPath: candidate.appendingPathComponent("evidence.json").path) { return candidate }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        return nil
    }

    public static func load(acceptanceDirectory: URL) throws -> EvidenceRegistry {
        var registry = EvidenceRegistry(acceptanceDirectory: acceptanceDirectory)
        let evidence = try JSONValue.parse(try Data(contentsOf: acceptanceDirectory.appendingPathComponent("evidence.json")))
        guard evidence["schemaVersion"]?.int == 1 else {
            throw AuthorError(code: .validationFailed, path: "evidence.json/schemaVersion", message: "Unsupported evidence.json schemaVersion; expected 1.")
        }
        registry.pinnedCommit = evidence["pinnedCommit"]?.string
        for (index, raw) in (evidence["entries"]?.array ?? []).enumerated() {
            do {
                registry.entries.append(try raw.decode(EvidenceEntry.self))
            } catch {
                registry.loadWarnings.append("evidence.json entries[\(index)] ignored: \(error)")
            }
        }
        let packsDir = acceptanceDirectory.appendingPathComponent("packs")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: packsDir.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        for file in files {
            let url = packsDir.appendingPathComponent(file)
            do {
                let summary = try AcceptancePackSummary.parse(try JSONValue.parse(try Data(contentsOf: url)), path: "packs/\(file)")
                registry.packs[summary.operation] = summary
            } catch {
                registry.loadWarnings.append("packs/\(file) ignored: \(error)")
            }
        }
        return registry
    }

    public func latestEntry(for operation: String) -> EvidenceEntry? {
        entries.last { $0.operation == operation }
    }

    /// Pinned sha256 of scripts/style_lint.py from the style-lint pack, when present.
    public var pinnedStyleLinterHash: String? {
        packs["style lint"]?.oracleHashes["scripts/style_lint.py"]
    }

    public static func backendHash(toolInfo: ToolInfo) -> String {
        (try? CanonicalJSON.sha256(["backend": "portable-strict/1", "tool": .string(toolInfo.tool), "version": .string(toolInfo.version)])) ?? ""
    }

    public static func implementationHash(for operation: Operation, toolInfo: ToolInfo) -> String? {
        guard operation.isRunnable else { return nil }
        return SHA256Hex.hex("\(toolInfo.tool)/\(toolInfo.version)/\(operation.name)/\(operation.schemaHash)")
    }

    public func capability(for operation: Operation, toolInfo: ToolInfo, policy: EvidencePolicy = .release) -> CapabilityEntry {
        let pack = packs[operation.name]
        let entry = latestEntry(for: operation.name)
        let requiredLevel = policy.effectiveLevel(for: operation)
        var blockers: [String] = []
        var status: EvidenceStatus = entry?.evidenceStatus ?? .pending
        var level: EvidenceLevel = entry?.evidenceLevel ?? .schemaOnly

        if let entry, status == .current {
            if let pack, pack.packHash != entry.packHash {
                status = .stale
                blockers.append("evidence stale: acceptance pack hash changed")
            }
            if let recorded = entry.requestSchemaHash, recorded != operation.schemaHash {
                status = .stale
                blockers.append("evidence stale: request schema hash changed")
            }
        }
        if !operation.isRunnable { blockers.append("handler not implemented") }
        if pack == nil { blockers.append("no acceptance pack registered") }
        switch status {
        case .pending: blockers.append("no admitted evidence")
        case .failed: blockers.append("evidence failed")
        case .stale, .current: break
        }
        if entry == nil { level = .schemaOnly }
        if level < requiredLevel { blockers.append("evidence level \(level.rawValue) below required \(requiredLevel.rawValue)") }

        var dimensions: [String: DimensionRecord] = [:]
        for name in evidenceDimensions {
            let packSays = pack?.dimensions[name]
            if packSays == "inapplicable" {
                dimensions[name] = DimensionRecord(status: .notApplicable)
            } else if let record = entry?.dimensions[name], status == .current {
                dimensions[name] = record
            } else {
                dimensions[name] = DimensionRecord(status: entry?.dimensions[name]?.status == .fail ? .fail : .pending, reportHash: entry?.dimensions[name]?.reportHash)
            }
        }
        if operation.requiredEvidence == .visuallyValidated, dimensions["visual"]?.status != .pass { blockers.append("visual gate pending") }
        if operation.requiredEvidence >= .corpusValidated, dimensions["corpus"]?.status != .pass, dimensions["corpus"]?.status != .notApplicable {
            blockers.append("corpus dimension pending")
        }

        let eligible = operation.isRunnable && status == .current && level >= requiredLevel && blockers.isEmpty
        return CapabilityEntry(
            operation: operation.name,
            schemaHash: operation.schemaHash,
            implementationHash: EvidenceRegistry.implementationHash(for: operation, toolInfo: toolInfo),
            backendHash: EvidenceRegistry.backendHash(toolInfo: toolInfo),
            availability: operation.isRunnable ? "implemented" : "schema-only",
            evidenceLevel: level,
            evidenceStatus: status,
            dimensions: dimensions,
            scope: entry?.scope ?? ["inputFamilies": [], "controlRanges": [:], "templateVersions": [], "targets": ["portable-vrm1"]],
            acceptancePackHash: pack?.packHash,
            evaluationPolicyHash: policy.hash,
            evaluators: entry?.evaluators ?? [],
            runnable: operation.isRunnable,
            productionEligible: eligible,
            blockers: blockers,
            artifactRefs: entry?.artifactRefs ?? [],
            requiredEvidence: operation.requiredEvidence)
    }
}
