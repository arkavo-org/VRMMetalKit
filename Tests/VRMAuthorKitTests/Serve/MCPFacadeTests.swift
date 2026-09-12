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

final class MCPFacadeTests: XCTestCase {
    static let toolNames = ["vrm_discover", "vrm_project", "vrm_recipe", "vrm_build", "vrm_qa", "vrm_export"]
    var root: URL!

    override func setUpWithError() throws { root = try ProjectTestHarness.makeRoot() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// Fixture-tested, current evidence for the named operations.
    func evidence(admitting names: [String]) -> EvidenceRegistry {
        let registry = Registry.v1()
        var evidence = EvidenceRegistry()
        for name in names {
            let op = registry.operation(named: name)!
            let packHash = SHA256Hex.hex("pack-\(name)")
            evidence.packs[name] = AcceptancePackSummary(id: name, operation: name, packHash: packHash, requestSchemaHash: op.schemaHash, resultSchemaHash: op.resultSchemaHash,
                                                         requiredLevel: .fixtureTested, dimensions: ["fixture": "required"], oracleHashes: [:], path: "x")
            evidence.entries.append(EvidenceEntry(operation: name, packHash: packHash, requestSchemaHash: op.schemaHash, evidenceLevel: .fixtureTested, evidenceStatus: .current,
                                                  dimensions: ["fixture": DimensionRecord(status: .pass, reportHash: String(repeating: "1", count: 64))]))
        }
        return evidence
    }

    func session(env: [String: String] = [:], evidence: EvidenceRegistry = EvidenceRegistry(), policy: EvidencePolicy = .release,
                 previewRenderer: (any RenderAdapter)? = nil) -> ServeSession {
        ServeSession(context: ProjectTestHarness.context(cwd: root, env: env, evidence: evidence, templates: TemplateRegistry.standard()), protocol: .mcp,
                     policy: policy, harness: ServeHandlers.isHarness(env: env), previewRenderer: previewRenderer)
    }

    func exchange(_ session: inout ServeSession, _ line: String) throws -> JSONValue {
        let response = try XCTUnwrap(session.handle(line: line), line)
        XCTAssertFalse(response.contains("\n"))
        return try JSONValue.parse(response)
    }

    func call(_ session: inout ServeSession, id: Int, _ tool: String, _ arguments: [String: JSONValue]) throws -> JSONValue {
        let line = try CanonicalJSON.string(["jsonrpc": "2.0", "id": .number(Double(id)), "method": "tools/call", "params": ["name": .string(tool), "arguments": .object(arguments)]])
        return try exchange(&session, line)
    }

    func toolNames(_ session: inout ServeSession) throws -> [String] {
        try XCTUnwrap(try exchange(&session, #"{"jsonrpc":"2.0","id":99,"method":"tools/list"}"#)["result"]?["tools"]?.array).compactMap { $0["name"]?.string }
    }

    // MARK: Listing and gating

    func testHarnessListsExactlyTheSixFacadeTools() throws {
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"])
        XCTAssertEqual(try toolNames(&server), Self.toolNames)
        let tools = try XCTUnwrap(try exchange(&server, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)["result"]?["tools"]?.array)
        let discover = try XCTUnwrap(tools.first { $0["name"] == "vrm_discover" })
        XCTAssertEqual(discover["annotations"]?["readOnlyHint"], true)
        XCTAssertEqual(discover["inputSchema"]?["type"], "object")
        let recipe = try XCTUnwrap(tools.first { $0["name"] == "vrm_recipe" })
        XCTAssertEqual(recipe["annotations"]?["readOnlyHint"], false)
        XCTAssertEqual(recipe["annotations"]?["idempotentHint"], true)
        XCTAssertEqual(recipe["inputSchema"]?["properties"]?["action"]?["enum"], ["export", "apply"])
        for tool in tools { XCTAssertFalse(try XCTUnwrap(tool["name"]?.string).contains("."), "registry rpcMethods are not MCP tools") }
    }

    func testReleaseWithNoEvidenceListsNothingAndRefusesCalls() throws {
        var server = session()
        XCTAssertEqual(try toolNames(&server), [])
        let refused = try call(&server, id: 2, "vrm_discover", [:])
        XCTAssertEqual(refused["error"]?["code"], -32602)
        XCTAssertEqual(refused["error"]?["data"]?["availableTools"], [])
    }

    func testToolAppearsWhenAnyMappedOperationIsAdmittedAndRefusesTheOther() throws {
        var server = session(evidence: evidence(admitting: ["project init"]))
        XCTAssertEqual(try toolNames(&server), ["vrm_project"])
        let dir = root.appendingPathComponent("p.vrmauthor")
        let initialised = try call(&server, id: 1, "vrm_project", ["action": "init", "dir": .string(dir.path), "template": "native-anime-v1", "seed": 3])
        XCTAssertEqual(initialised["result"]?["isError"], false)
        XCTAssertEqual(initialised["result"]?["structuredContent"]?["revision"], 0)
        let inspect = try call(&server, id: 2, "vrm_project", ["action": "inspect", "project": .string(dir.path)])
        XCTAssertNil(inspect["error"])
        XCTAssertEqual(inspect["result"]?["isError"], true)
        let error = try XCTUnwrap(inspect["result"]?["structuredContent"]?["errors"]?[0])
        XCTAssertEqual(error["code"], "MISSING_CAPABILITY")
        XCTAssertEqual(error["path"], "/operation")
        XCTAssertEqual(error["observed"], "project inspect")
        XCTAssertTrue(try XCTUnwrap(inspect["result"]?["content"]?[0]?["text"]?.string).contains("project inspect"))
    }

    func testTightenedPolicyHidesToolsAgain() throws {
        var server = session(evidence: evidence(admitting: ["project init", "build"]), policy: EvidencePolicy(minimumLevel: .visuallyValidated))
        XCTAssertEqual(try toolNames(&server), [])
    }

    func testUnknownMethodsAndBadParams() throws {
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"])
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"control.set","arguments":{}}}"#)["error"]?["code"], -32602)
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"vrm_project","arguments":{"action":"delete"}}}"#)["error"]?["code"], -32602)
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"vrm_build","arguments":[]}}"#)["error"]?["code"], -32602)
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"vrm_discover","arguments":{}}}"#)["error"]?["code"], -32600)
    }
}
