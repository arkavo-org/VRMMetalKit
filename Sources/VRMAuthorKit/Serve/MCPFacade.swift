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

/// One MCP tool composed over registry operations.
public struct MCPFacadeTool: Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var operations: [String]
    public var inputSchema: JSONSchema
    public var readOnly: Bool
    public var idempotent: Bool
}

enum InvokeOutcome {
    case envelope(JSONValue)
    case refused(JSONValue)
}

/// The MCP surface: six tools over the same handlers the CLI and JSON-RPC
/// use. A tool is listed when any operation it maps to is admitted (or the
/// session is a harness); an action whose operation is not admitted returns a
/// MISSING_CAPABILITY envelope instead of hiding the whole tool.
public enum MCPFacade {
    static let projectField = JSONSchema.path.described("Project directory; defaults to the session project")

    public static let tools: [MCPFacadeTool] = [
        MCPFacadeTool(name: "vrm_discover", title: "Discover", description: "Template packs, avatar control ranges, hair/outfit/accessory presets, renderers, starter resource URIs and admitted operations. Pass project to include current control values.",
                      operations: ["capabilities", "template list", "recipe export"],
                      inputSchema: .object(properties: ["project": projectField], required: [], description: "vrm_discover arguments"), readOnly: true, idempotent: true),
        MCPFacadeTool(name: "vrm_project", title: "Project", description: "init: create a project from a template pack and seed. inspect: revision, dependency state and status.",
                      operations: ["project init", "project inspect"],
                      inputSchema: .object(properties: [
                          "action": .enumeration(["init", "inspect"]), "dir": .path.described("init: project directory to create"),
                          "template": .id.described("init: template pack id; defaults to native-anime-v1"), "seed": .integer(minimum: 0, maximum: Int(Recipe.maxSeed)).defaulting(to: 0),
                          "name": .string(minLength: 1), "project": projectField,
                      ], required: ["action"], description: "vrm_project arguments"), readOnly: false, idempotent: false),
        MCPFacadeTool(name: "vrm_recipe", title: "Recipe", description: "export: the complete Recipe document. apply: replace it (edit the export in place, e.g. /body/body.heightM); requires expectedRevision.",
                      operations: ["recipe export", "recipe apply"],
                      inputSchema: .object(properties: [
                          "action": .enumeration(["export", "apply"]), "project": projectField, "recipe": Recipe.schema,
                          "expectedRevision": .integer(minimum: 0), "requestId": .string(minLength: 1), "dryRun": .boolean(),
                      ], required: ["action"], description: "vrm_recipe arguments"), readOnly: false, idempotent: true),
        MCPFacadeTool(name: "vrm_build", title: "Build", description: "Deterministic compile to an unsigned draft VRM. out defaults to <project>/draft.vrm.",
                      operations: ["build"],
                      inputSchema: .object(properties: ["project": projectField, "out": .path, "replace": .boolean()], required: [], description: "vrm_build arguments"), readOnly: false, idempotent: true),
        MCPFacadeTool(name: "vrm_qa", title: "QA", description: "Run the QA suite on a build (default: the newest build, suite authoring-v1) and return checks plus preview images. images: key (front + happy), all (six views), paths (none).",
                      operations: ["qa run"],
                      inputSchema: .object(properties: [
                          "project": projectField, "file": .path, "suite": .enumeration(["spec+style", "authoring-v1"]), "out": .path,
                          "images": .enumeration(["key", "all", "paths"]).defaulting(to: "key"), "previewSize": .integer(minimum: 128, maximum: 1024).defaulting(to: 512),
                      ], required: [], description: "vrm_qa arguments"), readOnly: false, idempotent: false),
        MCPFacadeTool(name: "vrm_export", title: "Export", description: "Final unsigned VRM bytes with loss and metadata report.",
                      operations: ["export vrm"],
                      inputSchema: .object(properties: ["project": projectField, "out": .path, "replace": .boolean()], required: ["out"], description: "vrm_export arguments"), readOnly: false, idempotent: false),
    ]

    public static func tool(named name: String) -> MCPFacadeTool? { tools.first { $0.name == name } }

    public static func eligible(_ operationName: String, session: ServeSession) -> Bool {
        guard let op = session.context.registry.operation(named: operationName), op.isRunnable else { return false }
        if session.harness { return true }
        return session.context.evidenceRegistry.capability(for: op, toolInfo: session.context.toolInfo, policy: session.policy).productionEligible
    }

    public static func listed(session: ServeSession) -> [MCPFacadeTool] {
        tools.filter { tool in tool.operations.contains { eligible($0, session: session) } }
    }

    public static func descriptor(_ tool: MCPFacadeTool) -> JSONValue {
        [
            "name": .string(tool.name), "title": .string(tool.title), "description": .string(tool.description), "inputSchema": tool.inputSchema.json,
            "annotations": ["title": .string(tool.title), "readOnlyHint": .bool(tool.readOnly), "destructiveHint": false, "idempotentHint": .bool(tool.idempotent), "openWorldHint": false],
        ]
    }

    // MARK: Composition helpers

    static func invoke(_ operationName: String, params: [String: JSONValue], session: ServeSession, tool: String) throws -> InvokeOutcome {
        guard let op = session.context.registry.operation(named: operationName) else {
            throw RPCError(code: RPCError.internalError, message: "Facade maps to unknown operation '\(operationName)'")
        }
        guard eligible(operationName, session: session) else { return .refused(missingCapability(tool: tool, operation: operationName, session: session)) }
        return .envelope(try session.invokeOperation(op, params: params, isNotification: false))
    }

    static func revision(of envelope: JSONValue) -> JSONValue {
        if let after = envelope["revisionAfter"], !after.isNull { return after }
        if let r = envelope["result"]?["revision"], !r.isNull { return r }
        return .null
    }

    static func toolResult(envelope: JSONValue, revision: JSONValue, isError: Bool, text: String, extra: [String: JSONValue] = [:], images: [JSONValue] = []) -> JSONValue {
        var structured = envelope.object ?? [:]
        structured["revision"] = revision
        for (k, v) in extra { structured[k] = v }
        return ["content": .array([["type": "text", "text": .string(text)]] + images), "structuredContent": .object(structured), "isError": .bool(isError)]
    }

    static func summary(tool: String, envelope: JSONValue) -> String {
        let status = envelope["status"]?.string ?? "unknown"
        var lines = ["\(tool) \(status); revision \(revisionText(envelope))"]
        for error in envelope["errors"]?.array ?? [] {
            lines.append("error \(error["code"]?.string ?? "?") \(error["path"]?.string ?? "") \(error["message"]?.string ?? "")")
        }
        for warning in envelope["warnings"]?.array ?? [] {
            lines.append("warning \(warning["code"]?.string ?? "?") \(warning["message"]?.string ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    static func revisionText(_ envelope: JSONValue) -> String {
        let r = revision(of: envelope)
        return r.int.map(String.init) ?? "n/a"
    }

    static func missingCapability(tool: String, operation: String, session: ServeSession) -> JSONValue {
        let op = session.context.registry.operation(named: operation)
        let error = AuthorError(code: .missingCapability, path: "/operation", observed: .string(operation),
                                required: op.map { .string($0.requiredEvidence.rawValue) },
                                message: "'\(operation)' has no admitted evidence under the session policy; it is not callable through \(tool) in this session.",
                                suggestedCommands: ["capabilities"])
        let envelope = ResultEnvelope.failed(requestId: nil, revision: nil, errors: [error])
        let json = (try? ServeSession.rpcResult(envelope)) ?? .object([:])
        return toolResult(envelope: json, revision: .null, isError: true, text: summary(tool: tool, envelope: json))
    }

    static func projectArgument(_ arguments: [String: JSONValue], session: ServeSession) throws -> String {
        if let p = arguments["project"]?.string { return p }
        if let p = session.context.projectPath { return p.path }
        throw RPCError(code: RPCError.invalidParams, message: "Invalid params: project is required (no session project)", data: ["path": "/project"])
    }

    static func validate(_ tool: MCPFacadeTool, _ arguments: [String: JSONValue]) throws {
        let violations = tool.inputSchema.requestErrors(for: .object(arguments))
        if let first = violations.first {
            throw RPCError(code: RPCError.invalidParams, message: "Invalid params: \(first.message)", data: ["path": .string(first.path ?? "/")])
        }
    }

    // MARK: Dispatch

    public static func call(_ tool: MCPFacadeTool, arguments raw: [String: JSONValue], session: ServeSession) throws -> JSONValue {
        try validate(tool, raw)
        let arguments = tool.inputSchema.applyingDefaults(to: .object(raw)).object ?? raw
        switch tool.name {
        case "vrm_discover": return try discover(arguments, session: session)
        case "vrm_project": return try project(arguments, session: session)
        case "vrm_recipe": return try recipe(arguments, session: session)
        case "vrm_build": return try build(arguments, session: session)
        case "vrm_qa": return try qa(arguments, session: session)
        case "vrm_export": return try export(arguments, session: session)
        default: throw RPCError(code: RPCError.methodNotFound, message: "Unknown tool: \(tool.name)")
        }
    }

    static func discover(_ arguments: [String: JSONValue], session: ServeSession) throws -> JSONValue {
        let capabilities: JSONValue
        switch try invoke("capabilities", params: [:], session: session, tool: "vrm_discover") {
        case .refused(let r): return r
        case .envelope(let e): capabilities = e
        }
        let templates: JSONValue
        switch try invoke("template list", params: [:], session: session, tool: "vrm_discover") {
        case .refused(let r): return r
        case .envelope(let e): templates = e
        }
        var values: [String: JSONValue] = [:]
        var revision: JSONValue = .null
        if let project = arguments["project"]?.string {
            switch try invoke("recipe export", params: ["project": .string(project), "out": .string(project + "/reports/mcp-recipe-export.json"), "replace": true], session: session, tool: "vrm_discover") {
            case .refused(let r): return r
            case .envelope(let e):
                revision = self.revision(of: e)
                for section in ["body", "face"] {
                    for (k, v) in e["result"]?["recipe"]?[section]?.object ?? [:] { values[k] = v }
                }
            }
        }
        let packs = templates["result"]?["packs"]?.array ?? []
        let controls: [JSONValue] = (packs.first?["controls"]?.array ?? []).map { descriptor in
            var d = descriptor.object ?? [:]
            if let key = d["key"]?.string, let v = values[key] { d["value"] = v }
            return .object(d)
        }
        var presets: [String: [JSONValue]] = ["hair": [], "outfit": [], "accessory": []]
        for item in templates["result"]?["items"]?.array ?? [] {
            guard let category = item["category"]?.string else { continue }
            presets[category, default: []].append(["id": item["id"] ?? .null, "controls": item["controls"] ?? []])
        }
        let admitted = (capabilities["result"]?["entries"]?.array ?? []).filter { $0["productionEligible"] == true }.compactMap { $0["operation"]?.string }
        let structured: [String: JSONValue] = [
            "templates": .array(packs.map { ["id": $0["id"] ?? .null, "sha256": $0["sha256"] ?? .null] }),
            "controls": .array(controls),
            "presets": .object(presets.mapValues { .array($0) }),
            "renderers": capabilities["result"]?["renderers"] ?? [],
            "starters": JSONValue(MCPResources.uris),
            "evidence": ["admitted": JSONValue(admitted)],
        ]
        let text = "vrm_discover succeeded; \(controls.count) controls, \(presets.values.map(\.count).reduce(0, +)) presets, \(admitted.count) admitted operations"
        return toolResult(envelope: .object(["protocol": .string(ResultEnvelope.protocolName), "status": "succeeded"]), revision: revision, isError: false, text: text, extra: structured)
    }

    static func recipe(_ arguments: [String: JSONValue], session: ServeSession) throws -> JSONValue {
        let project = try projectArgument(arguments, session: session)
        switch arguments["action"]?.string {
        case "export":
            switch try invoke("recipe export", params: ["project": .string(project), "out": .string(project + "/reports/mcp-recipe-export.json"), "replace": true], session: session, tool: "vrm_recipe") {
            case .refused(let r): return r
            case .envelope(let e): return toolResult(envelope: e, revision: revision(of: e), isError: e["status"] != "succeeded", text: summary(tool: "vrm_recipe export", envelope: e))
            }
        case "apply":
            guard let recipe = arguments["recipe"] else { throw RPCError(code: RPCError.invalidParams, message: "Invalid params: recipe is required for apply", data: ["path": "/recipe"]) }
            var params: [String: JSONValue] = ["project": .string(project), "recipe": recipe]
            for key in ["expectedRevision", "requestId", "dryRun"] { if let v = arguments[key] { params[key] = v } }
            switch try invoke("recipe apply", params: params, session: session, tool: "vrm_recipe") {
            case .refused(let r): return r
            case .envelope(let e): return toolResult(envelope: e, revision: revision(of: e), isError: e["status"] != "succeeded", text: summary(tool: "vrm_recipe apply", envelope: e))
            }
        default:
            throw RPCError(code: RPCError.invalidParams, message: "Invalid params: action must be export or apply", data: ["path": "/action"])
        }
    }

    static func build(_ arguments: [String: JSONValue], session: ServeSession) throws -> JSONValue { throw RPCError(code: RPCError.internalError, message: "not implemented") }
    static func qa(_ arguments: [String: JSONValue], session: ServeSession) throws -> JSONValue { throw RPCError(code: RPCError.internalError, message: "not implemented") }
    static func export(_ arguments: [String: JSONValue], session: ServeSession) throws -> JSONValue { throw RPCError(code: RPCError.internalError, message: "not implemented") }

    static func project(_ arguments: [String: JSONValue], session: ServeSession) throws -> JSONValue {
        switch arguments["action"]?.string {
        case "init":
            var params: [String: JSONValue] = ["template": arguments["template"] ?? .string(NativeAnimeV1Pack.packId)]
            guard let dir = arguments["dir"] else { throw RPCError(code: RPCError.invalidParams, message: "Invalid params: dir is required for init", data: ["path": "/dir"]) }
            params["dir"] = dir
            if let seed = arguments["seed"] { params["seed"] = seed }
            if let name = arguments["name"] { params["name"] = name }
            switch try invoke("project init", params: params, session: session, tool: "vrm_project") {
            case .refused(let r): return r
            case .envelope(let e): return toolResult(envelope: e, revision: revision(of: e), isError: e["status"] != "succeeded", text: summary(tool: "vrm_project init", envelope: e))
            }
        case "inspect":
            let project = try projectArgument(arguments, session: session)
            switch try invoke("project inspect", params: ["project": .string(project)], session: session, tool: "vrm_project") {
            case .refused(let r): return r
            case .envelope(let e):
                let rev = e["result"]?["revision"] ?? revision(of: e)
                return toolResult(envelope: e, revision: rev, isError: e["status"] != "succeeded", text: summary(tool: "vrm_project inspect", envelope: e))
            }
        default:
            throw RPCError(code: RPCError.invalidParams, message: "Invalid params: action must be init or inspect", data: ["path": "/action"])
        }
    }
}
