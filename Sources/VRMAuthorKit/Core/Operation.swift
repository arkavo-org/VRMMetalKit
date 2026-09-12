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

/// Evidence levels from verification.md §3, ordered by strength.
public enum EvidenceLevel: String, Codable, Hashable, Sendable, CaseIterable, Comparable {
    case schemaOnly = "schema-only"
    case fixtureTested = "fixture-tested"
    case corpusValidated = "corpus-validated"
    case visuallyValidated = "visually-validated"

    public var rank: Int {
        switch self {
        case .schemaOnly: return 0
        case .fixtureTested: return 1
        case .corpusValidated: return 2
        case .visuallyValidated: return 3
        }
    }

    public static func < (lhs: EvidenceLevel, rhs: EvidenceLevel) -> Bool { lhs.rank < rhs.rank }
}

public enum OperationKind: String, Codable, Hashable, Sendable {
    case read
    case mutation
    case projectFree
}

public typealias OperationHandler = @Sendable (OperationContext, JSONValue) throws -> ResultEnvelope

/// Supplies stdin lazily so `--request -` never touches the real stream in tests.
public typealias StandardInputProvider = @Sendable () -> Data

/// Everything a handler may observe about its environment. Handlers never read
/// process globals directly.
public struct OperationContext: Sendable {
    public var projectPath: URL?
    public var cwd: URL
    public var env: [String: String]
    public var stdin: StandardInputProvider
    public var evidenceRegistry: EvidenceRegistry
    public var registry: Registry
    public var templates: TemplateRegistry
    public var executableURL: URL?
    public var toolInfo: ToolInfo

    public init(projectPath: URL? = nil, cwd: URL, env: [String: String] = [:], stdin: @escaping StandardInputProvider = { Data() },
                evidenceRegistry: EvidenceRegistry = EvidenceRegistry(), registry: Registry, templates: TemplateRegistry = .standard(),
                executableURL: URL? = nil, toolInfo: ToolInfo = .current) {
        self.projectPath = projectPath
        self.cwd = cwd
        self.env = env
        self.stdin = stdin
        self.evidenceRegistry = evidenceRegistry
        self.registry = registry
        self.templates = templates
        self.executableURL = executableURL
        self.toolInfo = toolInfo
    }
}

public struct ToolInfo: Codable, Hashable, Sendable {
    public var tool: String
    public var version: String
    public var `protocol`: String
    public var abi: String

    public init(tool: String, version: String, protocol: String, abi: String) {
        self.tool = tool
        self.version = version
        self.protocol = `protocol`
        self.abi = abi
    }

    public static let current = ToolInfo(tool: "vrm-author", version: "0.1.0", protocol: ResultEnvelope.protocolName, abi: "vrmauthor-abi/1")
}

/// One registered command. `handler == nil` means the operation is schema-only.
public struct Operation: Sendable {
    public var name: String
    public var kind: OperationKind
    public var summary: String
    public var resultDescription: String
    public var requestSchema: JSONSchema
    public var resultSchema: JSONSchema
    public var requiredEvidence: EvidenceLevel
    public var examples: [JSONValue]
    public var handler: OperationHandler?

    public init(name: String, kind: OperationKind, summary: String, resultDescription: String, requestSchema: JSONSchema, resultSchema: JSONSchema,
                requiredEvidence: EvidenceLevel, examples: [JSONValue] = [], handler: OperationHandler? = nil) {
        self.name = name
        self.kind = kind
        self.summary = summary
        self.resultDescription = resultDescription
        self.requestSchema = requestSchema
        self.resultSchema = resultSchema
        self.requiredEvidence = requiredEvidence
        self.examples = examples
        self.handler = handler
    }

    /// "project init" → "project.init"
    public var rpcMethod: String { name.split(separator: " ").joined(separator: ".") }
    public var words: [String] { name.split(separator: " ").map(String.init) }
    public var isRunnable: Bool { handler != nil }
    public var schemaHash: String { requestSchema.schemaHash }
    public var resultSchemaHash: String { resultSchema.schemaHash }
}
