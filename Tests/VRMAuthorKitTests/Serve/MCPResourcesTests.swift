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

import XCTest
@testable import VRMAuthorKit

final class MCPResourcesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try ProjectTestHarness.makeRoot() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func session(env: [String: String] = [:]) -> ServeSession {
        ServeSession(context: ProjectTestHarness.context(cwd: root, env: env, templates: TemplateRegistry.standard()), protocol: .mcp,
                     harness: ServeHandlers.isHarness(env: env))
    }

    private func exchange(_ session: inout ServeSession, _ line: String) throws -> JSONValue {
        try JSONValue.parse(try XCTUnwrap(session.handle(line: line), line))
    }

    func testInitializeDeclaresResources() throws {
        var server = session()
        let initialize = try exchange(&server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}"#)
        XCTAssertEqual(initialize["result"]?["capabilities"]?["resources"], ["subscribe": false, "listChanged": false])
        XCTAssertEqual(initialize["result"]?["capabilities"]?["tools"], ["listChanged": false])
        let instructions = try XCTUnwrap(initialize["result"]?["instructions"]?.string)
        XCTAssertTrue(instructions.contains("recipe://native-anime-v1/female"))
        XCTAssertTrue(instructions.contains("vrm_qa"))
    }

    func testListAndReadInEverySession() throws {
        for env in [[:], ["VRM_AUTHOR_SESSION": "harness"]] {
            var server = session(env: env)
            let list = try exchange(&server, #"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#)
            let resources = try XCTUnwrap(list["result"]?["resources"]?.array)
            XCTAssertEqual(resources.compactMap { $0["uri"]?.string }, ["recipe://native-anime-v1/female", "recipe://native-anime-v1/male"])
            XCTAssertEqual(resources[0]["mimeType"], "application/json")
            XCTAssertEqual(resources[0]["name"], "female")
            XCTAssertNotNil(resources[0]["description"]?.string)

            let read = try exchange(&server, #"{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"recipe://native-anime-v1/male"}}"#)
            let contents = try XCTUnwrap(read["result"]?["contents"]?.array)
            XCTAssertEqual(contents.count, 1)
            XCTAssertEqual(contents[0]["uri"], "recipe://native-anime-v1/male")
            XCTAssertEqual(contents[0]["mimeType"], "application/json")
            let recipe = try Recipe.decode(try JSONValue.parse(try XCTUnwrap(contents[0]["text"]?.string)))
            XCTAssertEqual(recipe.name, "male")
            XCTAssertEqual(recipe.seed, 42)
            XCTAssertEqual(recipe.template.sha256, TemplateRegistry.standard().templateHashes()[NativeAnimeV1Pack.packId])
        }
    }

    func testUnknownResourceIsMinus32002() throws {
        var server = session()
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{"uri":"recipe://native-anime-v1/robot"}}"#)["error"]?["code"], -32002)
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{}}"#)["error"]?["code"], -32602)
        XCTAssertEqual(try exchange(&server, #"{"jsonrpc":"2.0","id":3,"method":"resources/templates/list"}"#)["result"]?["resourceTemplates"], [])
    }
}
