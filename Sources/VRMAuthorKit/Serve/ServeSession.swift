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

public enum ServeProtocol: String, Codable, Hashable, Sendable, CaseIterable {
    case jsonrpc, mcp
}

/// JSON-RPC 2.0 error object. Protocol and request errors use these; domain
/// failures stay inside the `vrmauthor/1` envelope in `result`.
public struct RPCError: Error, Hashable, Sendable {
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603

    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = ["code": .number(Double(code)), "message": .string(message)]
        if let data { o["data"] = data }
        return .object(o)
    }
}

/// One newline-delimited JSON-RPC 2.0 session over the registry, as a pure
/// function from request lines to response lines. `serve` wires stdin/stdout;
/// tests drive it with in-memory strings. Logging goes through `log` only.
public struct ServeSession: Sendable {
    public static let mcpProtocolVersion = "2025-06-18"
    public static let supportedMCPVersions = ["2025-06-18"]
    public static let mcpInstructions = """
    vrm-author authoring loop. 1) resources/read recipe://native-anime-v1/female or recipe://native-anime-v1/male for a complete starter Recipe. \
    2) vrm_project {action:"init"} to create a project, then edit the Recipe document (for example /body/body.heightM) and vrm_recipe {action:"apply", recipe, expectedRevision}. \
    3) vrm_build, then vrm_qa: read the checks and look at the preview images, patch the Recipe, apply again. 4) vrm_export when the checks pass. \
    vrm_discover lists control ranges and presets. Every result carries revision; mutations require expectedRevision. Preview images are views, not evidence.
    """
    public static let harnessEnvironmentKey = "VRM_AUTHOR_SESSION"
    public static let evidencePolicyEnvironmentKey = "VRM_AUTHOR_EVIDENCE_POLICY"

    public let context: OperationContext
    public let `protocol`: ServeProtocol
    public let policy: EvidencePolicy
    public let harness: Bool
    public let log: @Sendable (String) -> Void
    public private(set) var requestsHandled = 0
    public private(set) var negotiatedVersion: String?

    public init(context: OperationContext, protocol: ServeProtocol, policy: EvidencePolicy = .release, harness: Bool = false, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.context = context
        self.protocol = `protocol`
        self.policy = policy
        self.harness = harness
        self.log = log
    }

    // MARK: Line stream

    /// Response line for one request line; nil when the line was a notification
    /// or a blank line that produces no response.
    public mutating func handle(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let message: JSONValue
        do {
            message = try JSONValue.parse(Data(trimmed.utf8))
        } catch {
            log("parse error: \(error)")
            return serialize(errorResponse(id: .null, RPCError(code: RPCError.parseError, message: "Parse error", data: .string(String(describing: error)))))
        }
        if let batch = message.array {
            guard `protocol` == .jsonrpc else {
                return serialize(errorResponse(id: .null, RPCError(code: RPCError.invalidRequest, message: "Invalid Request: MCP does not support JSON-RPC batches")))
            }
            guard !batch.isEmpty else {
                return serialize(errorResponse(id: .null, RPCError(code: RPCError.invalidRequest, message: "Invalid Request: empty batch")))
            }
            let responses = batch.compactMap { handle(message: $0) }
            return responses.isEmpty ? nil : serialize(.array(responses))
        }
        return handle(message: message).map(serialize)
    }

    public mutating func run<S: Sequence>(lines: S) -> [String] where S.Element == String {
        var out: [String] = []
        for line in lines {
            if let response = handle(line: line) { out.append(response) }
        }
        return out
    }

    public mutating func run(input: String) -> [String] {
        run(lines: input.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
    }

    func serialize(_ value: JSONValue) -> String {
        (try? CanonicalJSON.string(value)) ?? #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error: unserializable response"}}"#
    }

    // MARK: Messages

    func errorResponse(id: JSONValue, _ error: RPCError) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": error.json]
    }

    func resultResponse(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    /// Validates the JSON-RPC envelope and dispatches. Returns nil for
    /// notifications that produce no response.
    public mutating func handle(message: JSONValue) -> JSONValue? {
        guard let object = message.object else {
            return errorResponse(id: .null, RPCError(code: RPCError.invalidRequest, message: "Invalid Request: expected an object"))
        }
        let rawId = object["id"]
        let idIsValid = rawId == nil || rawId!.isNull || rawId!.string != nil || rawId!.number != nil
        let id: JSONValue = idIsValid ? (rawId ?? .null) : .null
        guard idIsValid else {
            return errorResponse(id: .null, RPCError(code: RPCError.invalidRequest, message: "Invalid Request: id must be a string, number or null"))
        }
        guard object["jsonrpc"] == "2.0" else {
            return errorResponse(id: id, RPCError(code: RPCError.invalidRequest, message: "Invalid Request: jsonrpc must be \"2.0\""))
        }
        guard let method = object["method"]?.string else {
            return errorResponse(id: id, RPCError(code: RPCError.invalidRequest, message: "Invalid Request: method must be a string"))
        }
        let isNotification = rawId == nil
        let params = object["params"]
        if let params, params.object == nil, params.array == nil {
            return errorResponse(id: id, RPCError(code: RPCError.invalidParams, message: "Invalid params: params must be an object"))
        }
        requestsHandled += 1
        do {
            let result: JSONValue
            switch `protocol` {
            case .jsonrpc: result = try dispatchOperation(method: method, params: params, isNotification: isNotification)
            case .mcp: result = try dispatchMCP(method: method, params: params, isNotification: isNotification)
            }
            if isNotification { return nil }
            return resultResponse(id: id, result)
        } catch let error as RPCError {
            log("rpc error \(error.code) for \(method): \(error.message)")
            return errorResponse(id: id, error)
        } catch {
            log("internal error for \(method): \(error)")
            return errorResponse(id: id, RPCError(code: RPCError.internalError, message: "Internal error", data: .string(String(describing: error))))
        }
    }

    // MARK: Operations

    func paramsObject(_ params: JSONValue?) throws -> [String: JSONValue] {
        guard let params else { return [:] }
        guard let o = params.object else { throw RPCError(code: RPCError.invalidParams, message: "Invalid params: params must be an object") }
        return o
    }

    /// Invokes one registered operation with `params` as the request. Method
    /// names are `rpcMethod`s; `serve` itself is not callable over RPC.
    public func invokeOperation(_ operation: Operation, params: [String: JSONValue], isNotification: Bool) throws -> JSONValue {
        if operation.kind == .mutation {
            guard !isNotification else {
                throw RPCError(code: RPCError.invalidRequest, message: "Invalid Request: mutating method '\(operation.rpcMethod)' cannot be a notification; it must return a revision and receipt")
            }
            guard params["expectedRevision"]?.int != nil else {
                throw RPCError(code: RPCError.invalidParams, message: "Invalid params: expectedRevision is required for RPC mutations", data: ["path": "/expectedRevision"])
            }
        }
        var request = params
        var requestContext = context
        if operation.kind != .projectFree {
            if request["project"] == nil, let path = context.projectPath { request["project"] = .string(path.path) }
            guard let project = request["project"]?.string else {
                throw RPCError(code: RPCError.invalidParams, message: "Invalid params: project is required for '\(operation.rpcMethod)'", data: ["path": "/project"])
            }
            requestContext.projectPath = ProjectAccess.resolve(project, cwd: context.cwd)
        }
        let envelope = context.registry.invoke(operation.name, request: .object(request), context: requestContext)
        return try ServeSession.rpcResult(envelope)
    }

    /// The envelope plus its process exit code, so RPC callers see the same
    /// code the CLI would exit with.
    public static func rpcResult(_ envelope: ResultEnvelope) throws -> JSONValue {
        var o = try envelope.jsonValue().object ?? [:]
        o["exitCode"] = .number(Double(envelope.exitCode.rawValue))
        return .object(o)
    }

    func dispatchOperation(method: String, params: JSONValue?, isNotification: Bool) throws -> JSONValue {
        guard method != "serve", let operation = context.registry.operation(rpcMethod: method) else {
            throw RPCError(code: RPCError.methodNotFound, message: "Method not found: \(method)")
        }
        return try invokeOperation(operation, params: try paramsObject(params), isNotification: isNotification)
    }

    // MARK: MCP adapter

    /// Operations exposed as MCP tools under the session's evidence policy:
    /// runnable and production-eligible, or merely runnable in a harness session.
    public func exposedOperations() -> [Operation] {
        context.registry.ordered.filter { op in
            guard op.isRunnable, op.name != "serve" else { return false }
            if harness { return true }
            return context.evidenceRegistry.capability(for: op, toolInfo: context.toolInfo, policy: policy).productionEligible
        }
    }

    public func toolDescriptor(_ operation: Operation) -> JSONValue {
        [
            "name": .string(operation.rpcMethod),
            "title": .string(operation.name),
            "description": .string("\(operation.summary). Result: \(operation.resultDescription). Required evidence: \(operation.requiredEvidence.rawValue)."),
            "inputSchema": operation.requestSchema.json,
            "annotations": ["title": .string(operation.name), "readOnlyHint": .bool(operation.kind != .mutation), "destructiveHint": false,
                            "idempotentHint": .bool(operation.kind == .mutation), "openWorldHint": false],
        ]
    }

    mutating func dispatchMCP(method: String, params: JSONValue?, isNotification: Bool) throws -> JSONValue {
        switch method {
        case "initialize":
            let p = try paramsObject(params)
            let requested = p["protocolVersion"]?.string
            let version = requested.flatMap { ServeSession.supportedMCPVersions.contains($0) ? $0 : nil } ?? ServeSession.mcpProtocolVersion
            negotiatedVersion = version
            return [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false], "resources": ["subscribe": false, "listChanged": false]],
                "serverInfo": ["name": .string(context.toolInfo.tool), "version": .string(context.toolInfo.version), "title": "vrm-author"],
                "instructions": .string(ServeSession.mcpInstructions),
            ]
        case "notifications/initialized", "notifications/cancelled", "notifications/progress", "notifications/roots/list_changed":
            guard isNotification else { throw RPCError(code: RPCError.invalidRequest, message: "Invalid Request: '\(method)' is a notification") }
            return .null
        case "ping":
            return [:]
        case "tools/list":
            let p = try paramsObject(params)
            if p["cursor"] != nil { throw RPCError(code: RPCError.invalidParams, message: "Invalid params: unknown cursor") }
            return ["tools": .array(exposedOperations().map(toolDescriptor))]
        case "tools/call":
            guard !isNotification else { throw RPCError(code: RPCError.invalidRequest, message: "Invalid Request: tools/call cannot be a notification") }
            let p = try paramsObject(params)
            guard let name = p["name"]?.string else { throw RPCError(code: RPCError.invalidParams, message: "Invalid params: name is required") }
            guard let operation = exposedOperations().first(where: { $0.rpcMethod == name }) else {
                throw RPCError(code: RPCError.invalidParams, message: "Unknown tool: \(name)", data: ["availableTools": JSONValue(exposedOperations().map(\.rpcMethod))])
            }
            let arguments: [String: JSONValue]
            if let raw = p["arguments"] {
                guard let o = raw.object else { throw RPCError(code: RPCError.invalidParams, message: "Invalid params: arguments must be an object") }
                arguments = o
            } else {
                arguments = [:]
            }
            let result = try invokeOperation(operation, params: arguments, isNotification: false)
            let text = try CanonicalJSON.string(result)
            let failed = result["status"] != "succeeded"
            return ["content": [["type": "text", "text": .string(text)]], "structuredContent": result, "isError": .bool(failed)]
        case "resources/list":
            let p = try paramsObject(params)
            if p["cursor"] != nil { throw RPCError(code: RPCError.invalidParams, message: "Invalid params: unknown cursor") }
            return MCPResources.list()
        case "resources/templates/list":
            return ["resourceTemplates": []]
        case "resources/read":
            let p = try paramsObject(params)
            guard let uri = p["uri"]?.string else { throw RPCError(code: RPCError.invalidParams, message: "Invalid params: uri is required") }
            return try MCPResources.read(uri: uri, templates: context.templates)
        default:
            throw RPCError(code: RPCError.methodNotFound, message: "Method not found: \(method)")
        }
    }
}
