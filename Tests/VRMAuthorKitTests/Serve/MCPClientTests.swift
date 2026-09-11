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
import XCTest
@testable import VRMAuthorKit

/// An independent MCP client: it speaks raw JSON-RPC lines from the MCP
/// 2025-06-18 specification and asserts exact wire shapes; it never uses the
/// adapter's own types.
final class MCPClientTests: XCTestCase {
    private var root: URL!
    private var dir: URL!

    override func setUpWithError() throws {
        root = try ProjectTestHarness.makeRoot()
        dir = root.appendingPathComponent("avatar.vrmauthor")
        try ProjectTestHarness.initProject(ProjectTestHarness.context(cwd: root), dir: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A registry with current fixture-tested evidence for `version` and `object list`,
    /// so production sessions have something to expose.
    private func qualifiedEvidence() -> EvidenceRegistry {
        let registry = Registry.v1()
        var evidence = EvidenceRegistry()
        for name in ["version", "object list"] {
            let op = registry.operation(named: name)!
            let packHash = SHA256Hex.hex("pack-\(name)")
            evidence.packs[name] = AcceptancePackSummary(id: name, operation: name, packHash: packHash, requestSchemaHash: op.schemaHash, resultSchemaHash: op.resultSchemaHash,
                                                         requiredLevel: .fixtureTested, dimensions: ["fixture": "required"], oracleHashes: [:], runnerKind: "swift-test", entryPoint: "x", path: "x")
            evidence.entries.append(EvidenceEntry(operation: name, packHash: packHash, requestSchemaHash: op.schemaHash, evidenceLevel: .fixtureTested, evidenceStatus: .current,
                                                  dimensions: ["fixture": DimensionRecord(status: .pass, reportHash: String(repeating: "1", count: 64))]))
        }
        return evidence
    }

    private func session(env: [String: String] = [:], evidence: EvidenceRegistry = EvidenceRegistry(), policy: EvidencePolicy = .release) -> ServeSession {
        ServeSession(context: ProjectTestHarness.context(cwd: root, env: env, evidence: evidence), protocol: .mcp, policy: policy, harness: ServeHandlers.isHarness(env: env))
    }

    private func exchange(_ session: inout ServeSession, _ line: String) throws -> JSONValue {
        let response = try XCTUnwrap(session.handle(line: line), line)
        XCTAssertFalse(response.contains("\n"))
        return try JSONValue.parse(response)
    }

    func testInitializeListAndCallAsAnIndependentClient() throws {
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"])

        let initialize = try exchange(&server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"roots":{"listChanged":true}},"clientInfo":{"name":"test-client","version":"1.0.0"}}}"#)
        XCTAssertEqual(initialize["jsonrpc"], "2.0")
        XCTAssertEqual(initialize["id"], 1)
        XCTAssertNil(initialize["error"])
        XCTAssertEqual(initialize["result"]?["protocolVersion"], "2025-06-18")
        XCTAssertEqual(initialize["result"]?["capabilities"], ["tools": ["listChanged": false]])
        XCTAssertEqual(initialize["result"]?["serverInfo"]?["name"], "vrm-author")
        XCTAssertEqual(initialize["result"]?["serverInfo"]?["version"], .string(ToolInfo.current.version))
        XCTAssertNotNil(initialize["result"]?["instructions"]?.string)
        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))

        let list = try exchange(&server, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        XCTAssertEqual(list["id"], 2)
        let tools = try XCTUnwrap(list["result"]?["tools"]?.array)
        XCTAssertNil(list["result"]?["nextCursor"])
        let names = tools.compactMap { $0["name"]?.string }
        XCTAssertEqual(names, Registry.v1().ordered.filter { $0.isRunnable && $0.name != "serve" }.map(\.rpcMethod))
        XCTAssertTrue(names.contains("project.init"))
        XCTAssertTrue(names.contains("control.set"))
        XCTAssertFalse(names.contains("build"))
        XCTAssertFalse(names.contains("serve"))
        let control = try XCTUnwrap(tools.first { $0["name"] == "control.set" })
        XCTAssertEqual(control["title"], "control set")
        XCTAssertNotNil(control["description"]?.string)
        XCTAssertEqual(control["inputSchema"], Registry.v1().operation(named: "control set")!.requestSchema.json)
        XCTAssertEqual(control["inputSchema"]?["type"], "object")
        XCTAssertNotNil(control["inputSchema"]?["properties"]?["edit"])
        XCTAssertEqual(control["annotations"]?["readOnlyHint"], false)
        XCTAssertEqual(tools.first { $0["name"] == "version" }?["annotations"]?["readOnlyHint"], true)

        let call = try exchange(&server, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"version","arguments":{}}}"#)
        XCTAssertEqual(call["id"], 3)
        XCTAssertNil(call["error"])
        let result = try XCTUnwrap(call["result"])
        XCTAssertEqual(result["isError"], false)
        let content = try XCTUnwrap(result["content"]?.array)
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"], "text")
        let text = try XCTUnwrap(content[0]["text"]?.string)
        let structured = try XCTUnwrap(result["structuredContent"])
        XCTAssertEqual(try JSONValue.parse(text), structured, "text content is the canonical envelope")
        XCTAssertEqual(text, try CanonicalJSON.string(structured))
        XCTAssertEqual(structured["protocol"], "vrmauthor/1")
        XCTAssertEqual(structured["status"], "succeeded")
        XCTAssertEqual(structured["exitCode"], 0)
        XCTAssertEqual(structured["revisionBefore"], .null)
        XCTAssertEqual(structured["result"]?["tool"], "vrm-author")
        XCTAssertEqual(structured["result"]?["abi"], "vrmauthor-abi/1")
        XCTAssertEqual(Set(structured.object!.keys), ["protocol", "requestId", "status", "revisionBefore", "revisionAfter", "artifacts", "warnings", "errors", "result", "exitCode"])

        let ping = try exchange(&server, #"{"jsonrpc":"2.0","id":4,"method":"ping"}"#)
        XCTAssertEqual(ping["result"], [:])
    }

    func testToolCallMutationsFailuresAndUnknownTools() throws {
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"])
        _ = try exchange(&server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}"#)
        let args: JSONValue = ["project": .string(dir.path), "requestId": "mcp-1", "expectedRevision": 0, "edit": ["object": "avatar:main", "values": ["body.heightM": 1.7]]]
        let call = try CanonicalJSON.string(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "control.set", "arguments": args]])
        let set = try exchange(&server, call)
        XCTAssertEqual(set["result"]?["isError"], false)
        XCTAssertEqual(set["result"]?["structuredContent"]?["revisionAfter"], 1)
        XCTAssertEqual(set["result"]?["structuredContent"]?["requestId"], "mcp-1")
        XCTAssertEqual(try ProjectStore.open(at: dir).state().revision, 1)

        let stale = try exchange(&server, call.replacingOccurrences(of: "\"id\":2", with: "\"id\":3").replacingOccurrences(of: "mcp-1", with: "mcp-2"))
        XCTAssertEqual(stale["result"]?["isError"], true)
        XCTAssertEqual(stale["result"]?["structuredContent"]?["status"], "failed")
        XCTAssertEqual(stale["result"]?["structuredContent"]?["exitCode"], 4)
        XCTAssertEqual(stale["result"]?["structuredContent"]?["errors"]?[0]?["code"], "REVISION_CONFLICT")
        XCTAssertEqual(try JSONValue.parse(stale["result"]!["content"]![0]!["text"]!.string!)["errors"]?[0]?["code"], "REVISION_CONFLICT")

        let replay = try exchange(&server, call.replacingOccurrences(of: "\"id\":2", with: "\"id\":4"))
        XCTAssertEqual(replay["result"]?["structuredContent"], set["result"]?["structuredContent"])

        let missingRevision = try exchange(&server, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"control.set","arguments":{"project":"x","edit":{"object":"avatar:main","values":{}}}}}"#)
        XCTAssertEqual(missingRevision["error"]?["code"], -32602)
        let unknown = try exchange(&server, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"build","arguments":{}}}"#)
        XCTAssertEqual(unknown["error"]?["code"], -32602)
        XCTAssertTrue(unknown["error"]!["message"]!.string!.hasPrefix("Unknown tool"))
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"arguments":{}}}"#)["error"]?["code"], -32602)
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"version","arguments":[]}}"#)["error"]?["code"], -32602)
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","id":9,"method":"resources/list"}"#)["error"]?["code"], -32601)
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","id":10,"method":"project.inspect","params":{}}"#)["error"]?["code"], -32601, "operations are not bare methods in MCP mode")
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"version","arguments":{}}}"#)["error"]?["code"], -32600, "tools/call cannot be a notification")
        XCTAssertEqual(try exchange(&server, #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)["error"]?["code"], -32600, "MCP has no batches")
        XCTAssertEqual(try exchange(&server, "{oops")["error"]?["code"], -32700)
    }

    func testProtocolVersionNegotiation() throws {
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"])
        let older = try exchange(&server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}"#)
        XCTAssertEqual(older["result"]?["protocolVersion"], "2025-06-18")
        var again = session(env: ["VRM_AUTHOR_SESSION": "harness"])
        let missing = try exchange(&again, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}"#)
        XCTAssertEqual(missing["result"]?["protocolVersion"], "2025-06-18")
        XCTAssertEqual(again.negotiatedVersion, "2025-06-18")
    }

    func testToolsListFollowsSessionEvidencePolicy() throws {
        var production = session()
        let none = try exchange(&production, #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#)
        XCTAssertEqual(none["result"]?["tools"], [], "no admitted evidence means no production tools")
        let refused = try exchange(&production, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"version","arguments":{}}}"#)
        XCTAssertEqual(refused["error"]?["code"], -32602)

        var qualified = session(evidence: qualifiedEvidence())
        let some = try exchange(&qualified, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        XCTAssertEqual(some["result"]?["tools"]?.array?.compactMap { $0["name"]?.string }, ["version", "object.list"])
        let objectList = try CanonicalJSON.string(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "object.list", "arguments": ["project": .string(dir.path), "kind": "hair"]]])
        XCTAssertEqual(try exchange(&qualified, objectList)["result"]?["structuredContent"]?["result"]?["objects"]?[0]?["id"], "hair:bob")

        var tightened = session(evidence: qualifiedEvidence(), policy: EvidencePolicy(minimumLevel: .visuallyValidated))
        XCTAssertEqual(try exchange(&tightened, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)["result"]?["tools"], [])

        let policyFile = root.appendingPathComponent("policy.json")
        try Data(#"{"minimumLevel":"corpus-validated","requireCurrent":false}"#.utf8).write(to: policyFile)
        let loaded = try ServeHandlers.sessionPolicy(env: ["VRM_AUTHOR_EVIDENCE_POLICY": policyFile.path], cwd: root)
        XCTAssertEqual(loaded.minimumLevel, .corpusValidated)
        XCTAssertTrue(loaded.requireCurrent, "caller policies cannot weaken release gates")
        var fromFile = session(evidence: qualifiedEvidence(), policy: loaded)
        XCTAssertEqual(try exchange(&fromFile, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)["result"]?["tools"], [])
        XCTAssertThrowsError(try ServeHandlers.sessionPolicy(env: ["VRM_AUTHOR_EVIDENCE_POLICY": "/nonexistent/policy.json"], cwd: root))
        XCTAssertEqual(try ServeHandlers.sessionPolicy(env: [:], cwd: root), .release)

        var harness = session(env: ["VRM_AUTHOR_SESSION": "harness"], evidence: qualifiedEvidence(), policy: EvidencePolicy(minimumLevel: .visuallyValidated))
        XCTAssertTrue(try exchange(&harness, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)["result"]!["tools"]!.array!.count > 2, "harness sessions expose every runnable tool")
    }
}
