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

    // MARK: vrm_discover

    func testDiscoverWithoutProjectWritesNothingAndListsPackData() throws {
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"])
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let result = try call(&server, id: 1, "vrm_discover", [:])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), before)
        XCTAssertEqual(result["result"]?["isError"], false)
        let s = try XCTUnwrap(result["result"]?["structuredContent"])
        XCTAssertEqual(s["templates"]?[0]?["id"], "native-anime-v1")
        XCTAssertEqual(s["templates"]?[0]?["sha256"], .string(TemplateRegistry.standard().templateHashes()["native-anime-v1"]!))
        let controls = try XCTUnwrap(s["controls"]?.array)
        XCTAssertEqual(controls.count, 44)
        XCTAssertEqual(controls.first { $0["key"] == "body.heightM" }?["validRange"], [1.2, 2.0])
        XCTAssertNil(controls.first { $0["key"] == "body.heightM" }?["value"])
        XCTAssertEqual(s["presets"]?["hair"]?.array?.compactMap { $0["id"]?.string }, ["bob-v1", "long-v1", "ponytail-v1"])
        XCTAssertEqual(s["presets"]?["outfit"]?.array?.count, 4)
        XCTAssertEqual(s["presets"]?["accessory"]?.array?.count, 3)
        XCTAssertEqual(s["starters"], ["recipe://native-anime-v1/female", "recipe://native-anime-v1/male"])
        XCTAssertEqual(s["evidence"]?["admitted"], [])
        XCTAssertNotNil(s["renderers"]?.array)
        XCTAssertEqual(s["revision"], .null)
    }

    func testDiscoverWithProjectCarriesCurrentValuesAndAdmittedOperations() throws {
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"], evidence: evidence(admitting: ["template list"]))
        let dir = root.appendingPathComponent("d.vrmauthor")
        _ = try call(&server, id: 1, "vrm_project", ["action": "init", "dir": .string(dir.path), "seed": 42])
        let s = try XCTUnwrap(try call(&server, id: 2, "vrm_discover", ["project": .string(dir.path)])["result"]?["structuredContent"])
        XCTAssertEqual(s["controls"]?.array?.first { $0["key"] == "body.heightM" }?["value"], 1.65)
        XCTAssertEqual(s["evidence"]?["admitted"], ["template list"])
        XCTAssertEqual(s["revision"], 0)
    }

    // MARK: vrm_recipe

    func testRecipeExportApplyRoundTripAndRevisionRules() throws {
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"])
        let dir = root.appendingPathComponent("r.vrmauthor")
        _ = try call(&server, id: 1, "vrm_project", ["action": "init", "dir": .string(dir.path), "seed": 42])
        let exported = try call(&server, id: 2, "vrm_recipe", ["action": "export", "project": .string(dir.path)])
        XCTAssertEqual(exported["result"]?["isError"], false)
        XCTAssertEqual(exported["result"]?["structuredContent"]?["revision"], 0)
        var recipe = try XCTUnwrap(exported["result"]?["structuredContent"]?["result"]?["recipe"])
        try JSONPointer("/body/body.heightM").set(in: &recipe, to: 1.5)

        let missing = try call(&server, id: 3, "vrm_recipe", ["action": "apply", "project": .string(dir.path), "recipe": recipe])
        XCTAssertEqual(missing["error"]?["code"], -32602, "expectedRevision is never auto-filled")

        let applied = try call(&server, id: 4, "vrm_recipe", ["action": "apply", "project": .string(dir.path), "recipe": recipe, "expectedRevision": 0, "requestId": "apply-1"])
        XCTAssertNil(applied["error"])
        XCTAssertEqual(applied["result"]?["isError"], false)
        XCTAssertEqual(applied["result"]?["structuredContent"]?["revision"], 1)
        let appliedText = try XCTUnwrap(applied["result"]?["content"]?[0]?["text"]?.string)
        XCTAssertTrue(appliedText.hasPrefix("vrm_recipe apply succeeded; revision 1"))
        XCTAssertThrowsError(try JSONValue.parse(appliedText))

        let stale = try call(&server, id: 5, "vrm_recipe", ["action": "apply", "project": .string(dir.path), "recipe": recipe, "expectedRevision": 0, "requestId": "apply-2"])
        XCTAssertNil(stale["error"])
        XCTAssertEqual(stale["result"]?["isError"], true, "a domain failure that changed nothing is a tool error")
        XCTAssertEqual(stale["result"]?["structuredContent"]?["errors"]?[0]?["code"], "REVISION_CONFLICT")

        let again = try call(&server, id: 6, "vrm_recipe", ["action": "export", "project": .string(dir.path)])
        XCTAssertEqual(again["result"]?["structuredContent"]?["result"]?["recipe"]?["body"]?["body.heightM"], 1.5)
        XCTAssertEqual(again["result"]?["structuredContent"]?["revision"], 1)
    }
}
