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
        let before = try FileManager.default.subpathsOfDirectory(atPath: dir.path).sorted()
        let s = try XCTUnwrap(try call(&server, id: 2, "vrm_discover", ["project": .string(dir.path)])["result"]?["structuredContent"])
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: dir.path).sorted(), before, "vrm_discover must not write to the project directory")
        XCTAssertEqual(s["controls"]?.array?.first { $0["key"] == "body.heightM" }?["value"], 1.65)
        XCTAssertEqual(s["evidence"]?["admitted"], ["template list"])
        XCTAssertEqual(s["revision"], 0)
    }

    func testDiscoverWithMissingProjectIsAToolError() throws {
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"])
        let dir = root.appendingPathComponent("missing.vrmauthor")
        let result = try call(&server, id: 1, "vrm_discover", ["project": .string(dir.path)])
        XCTAssertEqual(result["result"]?["isError"], true)
        XCTAssertEqual(result["result"]?["structuredContent"]?["errors"]?[0]?["code"], "PROJECT_NOT_FOUND")
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

    // MARK: vrm_build / vrm_export

    func testBuildDefaultsToDraftAtProjectRootAndExportWritesFinal() throws {
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"])
        let dir = root.appendingPathComponent("b.vrmauthor")
        _ = try call(&server, id: 1, "vrm_project", ["action": "init", "dir": .string(dir.path), "seed": 42])
        let built = try call(&server, id: 2, "vrm_build", ["project": .string(dir.path)])
        XCTAssertEqual(built["result"]?["isError"], false)
        let s = try XCTUnwrap(built["result"]?["structuredContent"])
        XCTAssertEqual(s["revision"], 0)
        let hash = try XCTUnwrap(s["result"]?["buildHash"]?.string)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("draft.vrm").path))
        let builds = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("builds").path).sorted()
        XCTAssertEqual(builds, [hash, "latest.json"], "nothing but recordBuild output under builds/")
        XCTAssertEqual(try MCPFacade.latestBuildFile(project: dir.path), dir.appendingPathComponent("builds/\(hash)/avatar.vrm").path)

        let rebuilt = try call(&server, id: 3, "vrm_build", ["project": .string(dir.path)])
        XCTAssertEqual(rebuilt["result"]?["isError"], false, "default replace:true lets the draft be rebuilt")
        XCTAssertEqual(rebuilt["result"]?["structuredContent"]?["result"]?["buildHash"], .string(hash), "same recipe, same bytes")

        var cliContext = server.context
        cliContext.projectPath = dir
        let cli = ProjectTestHarness.invoke(cliContext, "build", ["project": .string(dir.path), "out": .string(dir.appendingPathComponent("cli.vrm").path)])
        XCTAssertEqual(cli.result?["buildHash"], .string(hash), "facade and CLI build the same bytes")

        let exported = try call(&server, id: 4, "vrm_export", ["project": .string(dir.path), "out": .string(root.appendingPathComponent("final.vrm").path)])
        XCTAssertEqual(exported["result"]?["isError"], false)
        XCTAssertNotNil(exported["result"]?["structuredContent"]?["result"]?["lossReport"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("final.vrm").path))
    }

    func testLatestBuildFileFailsBeforeAnyBuild() throws {
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"])
        let dir = root.appendingPathComponent("nb.vrmauthor")
        _ = try call(&server, id: 1, "vrm_project", ["action": "init", "dir": .string(dir.path)])
        XCTAssertThrowsError(try MCPFacade.latestBuildFile(project: dir.path)) { error in
            XCTAssertEqual((error as? AuthorError)?.code, .missingInput)
            XCTAssertEqual((error as? AuthorError)?.suggestedCommands, ["build"])
        }
    }

    // MARK: vrm_qa

    func preparedProject(_ server: inout ServeSession, name: String) throws -> URL {
        let dir = root.appendingPathComponent(name)
        _ = try call(&server, id: 1, "vrm_project", ["action": "init", "dir": .string(dir.path), "seed": 42])
        let built = try call(&server, id: 2, "vrm_build", ["project": .string(dir.path)])
        XCTAssertEqual(built["result"]?["isError"], false)
        return dir
    }

    func testQaWithoutRendererIsIncompleteNotError() throws {
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness", VRMAuthorRenderLocator.environmentKey: "/nonexistent"])
        let dir = try preparedProject(&server, name: "q1.vrmauthor")
        let qa = try call(&server, id: 3, "vrm_qa", ["project": .string(dir.path)])
        XCTAssertNil(qa["error"])
        XCTAssertEqual(qa["result"]?["isError"], false)
        let s = try XCTUnwrap(qa["result"]?["structuredContent"])
        XCTAssertEqual(s["status"], "incomplete")
        XCTAssertEqual(s["result"]?["verdict"], "incomplete")
        XCTAssertEqual(s["previews"], [])
        XCTAssertEqual(s["revision"], 0)
        let content = try XCTUnwrap(qa["result"]?["content"]?.array)
        XCTAssertEqual(content.count, 1)
        let text = try XCTUnwrap(content[0]["text"]?.string)
        XCTAssertTrue(text.contains("spec.structure.glb pass"))
        XCTAssertTrue(text.contains("inspection record"), "the text block says the loop cannot reach complete through MCP")
        XCTAssertTrue(text.contains("renderer"), "names the missing renderer")
    }

    func testQaFileDefaultsToLatestBuildAndSuiteCanBeSpecStyle() throws {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        try XCTSkipIf(StyleToolchain.python3(env: ["PATH": path]) == nil, "python3 not on PATH")
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness", "PATH": path])
        let dir = try preparedProject(&server, name: "q2.vrmauthor")
        let qa = try call(&server, id: 3, "vrm_qa", ["project": .string(dir.path), "suite": "spec+style", "images": "paths"])
        let s = try XCTUnwrap(qa["result"]?["structuredContent"])
        XCTAssertEqual(s["status"], "succeeded")
        XCTAssertEqual(s["result"]?["verdict"], "pass")
        XCTAssertEqual(qa["result"]?["content"]?.array?.count, 1)
        var plainContext = server.context
        plainContext.projectPath = dir
        let plain = ProjectTestHarness.invoke(plainContext, "qa run", ["project": .string(dir.path), "request": ["file": .string(try MCPFacade.latestBuildFile(project: dir.path)), "suite": "spec+style"], "out": .string(root.appendingPathComponent("plain-qa").path)])
        XCTAssertEqual(plain.result?["reportHash"], s["result"]?["reportHash"], "the facade runs the same locked qa run")
    }

    func testQaNoBuildFailsWithBuildSuggestion() throws {
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"])
        let dir = root.appendingPathComponent("q3.vrmauthor")
        _ = try call(&server, id: 1, "vrm_project", ["action": "init", "dir": .string(dir.path)])
        let qa = try call(&server, id: 2, "vrm_qa", ["project": .string(dir.path)])
        XCTAssertEqual(qa["result"]?["isError"], true)
        XCTAssertEqual(qa["result"]?["structuredContent"]?["errors"]?[0]?["suggestedCommands"], ["build"])
        XCTAssertEqual(qa["result"]?["structuredContent"]?["previews"], [])
        XCTAssertTrue(try XCTUnwrap(qa["result"]?["content"]?[0]?["text"]?.string).contains(MCPFacade.inspectionNote))
    }

    func testQaPreviewImagesFollowTheImagesMode() throws {
        let fake = FakeRenderer()
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"], previewRenderer: fake)
        let dir = try preparedProject(&server, name: "q4.vrmauthor")

        let key = try call(&server, id: 3, "vrm_qa", ["project": .string(dir.path), "previewSize": 256])
        let keyContent = try XCTUnwrap(key["result"]?["content"]?.array)
        XCTAssertEqual(keyContent.map { $0["type"]?.string }, ["text", "image", "image"])
        XCTAssertEqual(keyContent[1]["mimeType"], "image/png")
        let png = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(keyContent[1]["data"]?.string)))
        XCTAssertEqual([UInt8](png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let previews = try XCTUnwrap(key["result"]?["structuredContent"]?["previews"]?.array)
        XCTAssertEqual(previews.map { $0["scenarioId"]?.string }, ["visual.front", "expression.happy"])
        XCTAssertEqual(previews[0]["evidence"], false)
        XCTAssertEqual(previews[0]["width"], 256)
        XCTAssertEqual(fake.sizes["visual.front"] as? String, "256x256", "preview pass overrides both scenario dimensions")
        let path = try XCTUnwrap(previews[0]["path"]?.string)
        XCTAssertTrue(path.contains("/preview/visual.front/"))
        XCTAssertEqual(previews[0]["sha256"], .string(SHA256Hex.hex(try Data(contentsOf: URL(fileURLWithPath: path)))))
        XCTAssertNil(fake.sizes["motion.idle"], "motion is never previewed")

        let all = try call(&server, id: 4, "vrm_qa", ["project": .string(dir.path), "images": "all"])
        XCTAssertEqual(all["result"]?["content"]?.array?.count, 7)
        XCTAssertEqual(all["result"]?["structuredContent"]?["previews"]?.array?.compactMap { $0["scenarioId"]?.string },
                       ["visual.front", "visual.threeQuarter", "visual.profile", "expression.blink", "expression.aa", "expression.happy"])

        let paths = try call(&server, id: 5, "vrm_qa", ["project": .string(dir.path), "images": "paths"])
        XCTAssertEqual(paths["result"]?["content"]?.array?.count, 1)
        XCTAssertEqual(paths["result"]?["structuredContent"]?["previews"], [])

        let report = try XCTUnwrap(all["result"]?["structuredContent"]?["result"]?["artifacts"]?.array).compactMap { $0["path"]?.string }
        XCTAssertFalse(report.contains { $0.contains("/preview/") }, "preview files are not QA artifacts")
    }

    func testQaSurvivesAThrowingPreviewRenderer() throws {
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"], previewRenderer: ThrowingRenderer())
        let dir = try preparedProject(&server, name: "q6.vrmauthor")
        let qa = try call(&server, id: 3, "vrm_qa", ["project": .string(dir.path)])
        XCTAssertNil(qa["error"])
        XCTAssertEqual(qa["result"]?["isError"], false, "a preview failure never fails the QA run")
        let s = try XCTUnwrap(qa["result"]?["structuredContent"])
        XCTAssertNotNil(s["result"]?["verdict"])
        XCTAssertEqual(s["previews"], [])
        let content = try XCTUnwrap(qa["result"]?["content"]?.array)
        XCTAssertEqual(content.count, 1)
        XCTAssertTrue(try XCTUnwrap(content[0]["text"]?.string).contains("PREVIEW_FAILED"))
    }

    func testRealPreviewPassMatchesRequestedSize() throws {
        let adapter = VRMAuthorRenderAdapter(executableURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/vrm-author"))
        try XCTSkipIf(adapter.identity == VRMAuthorRenderAdapter.unavailableIdentity, "vrm-author-render or Metal unavailable")
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness"], previewRenderer: adapter)
        let dir = try preparedProject(&server, name: "q5.vrmauthor")
        let qa = try call(&server, id: 3, "vrm_qa", ["project": .string(dir.path), "previewSize": 256])
        let previews = try XCTUnwrap(qa["result"]?["structuredContent"]?["previews"]?.array)
        XCTAssertEqual(previews.count, 2)
        for preview in previews {
            let png = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(preview["path"]?.string)))
            let ihdr = [UInt8](png[16 ..< 24])
            let width = Int(ihdr[0]) << 24 | Int(ihdr[1]) << 16 | Int(ihdr[2]) << 8 | Int(ihdr[3])
            let height = Int(ihdr[4]) << 24 | Int(ihdr[5]) << 16 | Int(ihdr[6]) << 8 | Int(ihdr[7])
            XCTAssertEqual(width, 256)
            XCTAssertEqual(height, 256)
        }
    }

    // MARK: the whole loop

    func testStarterLoopInOneSession() throws {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        var server = session(env: ["VRM_AUTHOR_SESSION": "harness", VRMAuthorRenderLocator.environmentKey: "/nonexistent", "PATH": path])

        let read = try exchange(&server, #"{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{"uri":"recipe://native-anime-v1/female"}}"#)
        let starter = try JSONValue.parse(try XCTUnwrap(read["result"]?["contents"]?[0]?["text"]?.string))

        let dir = root.appendingPathComponent("loop.vrmauthor")
        let initialised = try call(&server, id: 2, "vrm_project", ["action": "init", "dir": .string(dir.path), "seed": 42])
        XCTAssertEqual(initialised["result"]?["isError"], false, "\(initialised)")
        XCTAssertEqual(initialised["result"]?["structuredContent"]?["revision"], 0)

        let applied = try call(&server, id: 3, "vrm_recipe", ["action": "apply", "project": .string(dir.path), "recipe": starter, "expectedRevision": 0, "requestId": "loop-1"])
        XCTAssertEqual(applied["result"]?["isError"], false, "\(applied)")
        XCTAssertEqual(applied["result"]?["structuredContent"]?["revision"], 1)

        let built = try call(&server, id: 4, "vrm_build", ["project": .string(dir.path)])
        XCTAssertEqual(built["result"]?["isError"], false, "\(built)")
        let buildHash = try XCTUnwrap(built["result"]?["structuredContent"]?["result"]?["buildHash"]?.string)
        XCTAssertEqual(BuildSupport.latestBuildHash(try ProjectStore.open(at: dir)), buildHash)

        let qa = try call(&server, id: 5, "vrm_qa", ["project": .string(dir.path), "images": "paths"])
        XCTAssertEqual(qa["result"]?["isError"], false, "\(qa)")
        XCTAssertNotNil(qa["result"]?["structuredContent"]?["result"]?["verdict"]?.string)
        XCTAssertEqual(qa["result"]?["structuredContent"]?["previews"], [])

        let out = root.appendingPathComponent("loop-final.vrm")
        let exported = try call(&server, id: 6, "vrm_export", ["project": .string(dir.path), "out": .string(out.path)])
        XCTAssertEqual(exported["result"]?["isError"], false, "\(exported)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))

        let final = try call(&server, id: 7, "vrm_recipe", ["action": "export", "project": .string(dir.path)])
        let recipe = try XCTUnwrap(final["result"]?["structuredContent"]?["result"]?["recipe"])
        XCTAssertEqual(recipe["body"]?["body.heightM"], 1.60, "the applied starter round-trips")
        XCTAssertEqual(recipe["outfits"]?[1]?["preset"], "skirt-v1")
    }
}

/// Writes a valid, tiny PNG for every scenario so image plumbing is testable
/// without Metal. It records the size each scenario asked for.
final class FakeRenderer: RenderAdapter, @unchecked Sendable {
    var identity: String { "fake/1" }
    let sizes = NSMutableDictionary()

    func render(scenario: RenderScenario, file: URL, data: Data, outputDirectory: URL, context: OperationContext) throws -> [ArtifactRef]? {
        let w = scenario.configuration["width"]?.int ?? 1024
        let h = scenario.configuration["height"]?.int ?? 1024
        sizes[scenario.id] = "\(w)x\(h)"
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let png = try PNGEncoder.encode(width: 2, height: 2, rgba: [UInt8](repeating: 128, count: 16))
        let url = outputDirectory.appendingPathComponent("\(scenario.id).png")
        try png.write(to: url)
        return [BuildSupport.artifact(url, data: png, mediaType: "image/png", role: "render", buildHash: nil)]
    }
}

/// A renderer that fails the way a real one does when its subprocess misbehaves.
struct ThrowingRenderer: RenderAdapter {
    var identity: String { "throwing/1" }

    func render(scenario: RenderScenario, file: URL, data: Data, outputDirectory: URL, context: OperationContext) throws -> [ArtifactRef]? {
        throw AuthorError(code: .internalError, path: scenario.id, message: "Preview renderer exited with status 9.", suggestedCommands: ["doctor"])
    }
}
