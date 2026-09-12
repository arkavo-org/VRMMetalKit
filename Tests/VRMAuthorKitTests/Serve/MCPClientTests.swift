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

    /// A registry with current fixture-tested evidence for `template list` and
    /// `project inspect`, so production sessions have something to expose.
    private func qualifiedEvidence() -> EvidenceRegistry {
        let registry = Registry.v1()
        var evidence = EvidenceRegistry()
        for name in ["template list", "project inspect"] {
            let op = registry.operation(named: name)!
            let packHash = SHA256Hex.hex("pack-\(name)")
            evidence.packs[name] = AcceptancePackSummary(id: name, operation: name, packHash: packHash, requestSchemaHash: op.schemaHash, resultSchemaHash: op.resultSchemaHash,
                                                         requiredLevel: .fixtureTested, dimensions: ["fixture": "required"], oracleHashes: [:], path: "x")
            evidence.entries.append(EvidenceEntry(operation: name, packHash: packHash, requestSchemaHash: op.schemaHash, evidenceLevel: .fixtureTested, evidenceStatus: .current,
                                                  dimensions: ["fixture": DimensionRecord(status: .pass, reportHash: String(repeating: "1", count: 64))]))
        }
        return evidence
    }

    private func session(env: [String: String] = [:], evidence: EvidenceRegistry = EvidenceRegistry(), policy: EvidencePolicy = .release,
                         registry: Registry = Registry.v1()) -> ServeSession {
        ServeSession(context: ProjectTestHarness.context(cwd: root, env: env, evidence: evidence, registry: registry), protocol: .mcp, policy: policy,
                     harness: ServeHandlers.isHarness(env: env))
    }

    /// Discovery and project handlers only, so `build` is handler-less by construction.
    private var withoutBuild: Registry { ProjectTestHarness.registry(installing: [DiscoveryHandlers.install, ProjectHandlers.install]) }

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
        XCTAssertEqual(initialize["result"]?["capabilities"], ["tools": ["listChanged": false], "resources": ["subscribe": false, "listChanged": false]])
        XCTAssertEqual(initialize["result"]?["serverInfo"]?["name"], "vrm-author")
        XCTAssertEqual(initialize["result"]?["serverInfo"]?["version"], .string(ToolInfo.current.version))
        XCTAssertNotNil(initialize["result"]?["instructions"]?.string)
        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))

        let list = try exchange(&server, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        XCTAssertEqual(list["id"], 2)
        let tools = try XCTUnwrap(list["result"]?["tools"]?.array)
        XCTAssertNil(list["result"]?["nextCursor"])
        XCTAssertEqual(tools.compactMap { $0["name"]?.string }, ["vrm_discover", "vrm_project", "vrm_recipe", "vrm_build", "vrm_qa", "vrm_export"])
        for tool in tools {
            XCTAssertEqual(tool["inputSchema"]?["type"], "object")
            XCTAssertNotNil(tool["description"]?.string)
            XCTAssertNotNil(tool["annotations"]?["readOnlyHint"]?.bool)
        }
        var reduced = session(env: ["VRM_AUTHOR_SESSION": "harness"], registry: withoutBuild)
        let reducedNames = try XCTUnwrap(try exchange(&reduced, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)["result"]?["tools"]?.array).compactMap { $0["name"]?.string }
        XCTAssertTrue(reducedNames.contains("vrm_project"))
        XCTAssertFalse(reducedNames.contains("vrm_build"), "a tool whose only operation has no handler is not listed")

        let ping = try exchange(&server, #"{"jsonrpc":"2.0","id":4,"method":"ping"}"#)
        XCTAssertEqual(ping["result"], [:])
    }

    func testToolCallMutationsFailuresAndUnknownTools() throws {
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"], registry: withoutBuild)
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"control.set","arguments":{}}}"#)["error"]?["code"], -32602, "registry methods are not MCP tools")
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"vrm_build","arguments":{}}}"#)["error"]?["code"], -32602, "handler-less operations stay hidden")
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"arguments":{}}}"#)["error"]?["code"], -32602)
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"vrm_project","arguments":[]}}"#)["error"]?["code"], -32602)
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","id":5,"method":"resources/list"}"#)["result"]?["resources"]?.array?.count, 2)
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","id":6,"method":"project.inspect","params":{}}"#)["error"]?["code"], -32601, "operations are not bare methods in MCP mode")
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"vrm_discover","arguments":{}}}"#)["error"]?["code"], -32600, "tools/call cannot be a notification")
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
        XCTAssertEqual(some["result"]?["tools"]?.array?.compactMap { $0["name"]?.string }, ["vrm_discover", "vrm_project"])
        let inspect = try CanonicalJSON.string(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "vrm_project", "arguments": ["action": "inspect", "project": .string(dir.path)]]])
        XCTAssertEqual(try exchange(&qualified, inspect)["result"]?["structuredContent"]?["revision"], 0)

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
        XCTAssertEqual(try exchange(&harness, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)["result"]!["tools"]!.array!.count, 6, "harness sessions expose every facade tool")
    }
}
