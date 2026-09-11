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

final class CLIParsingTests: XCTestCase {
    private let registry = Registry.v1()
    private let cwd = URL(fileURLWithPath: NSTemporaryDirectory())

    private func parse(_ args: [String], stdin: String = "") throws -> ParsedInvocation {
        try CommandLineParser.parse(args, registry: registry, stdin: { Data(stdin.utf8) }, cwd: cwd)
    }

    private func code(_ args: [String], stdin: String = "") -> AuthorErrorCode? {
        do { _ = try parse(args, stdin: stdin); return nil } catch let e as AuthorError { return e.code } catch { return nil }
    }

    func testKebabFlagsBecomeCamelCaseKeys() throws {
        XCTAssertEqual(CommandLineParser.camelCase("evidence-policy"), "evidencePolicy")
        XCTAssertEqual(CommandLineParser.camelCase("expected-plan-hash"), "expectedPlanHash")
        XCTAssertEqual(CommandLineParser.kebabCase("expectedPlanHash"), "expected-plan-hash")
        let parsed = try parse(["capabilities", "--evidence-policy", "p.json", "--log-level=debug"])
        XCTAssertEqual(parsed.operation.name, "capabilities")
        XCTAssertEqual(parsed.request["evidencePolicy"], "p.json")
        XCTAssertEqual(parsed.request["logLevel"], "debug")
    }

    func testMultiWordCommandsAndTypedConversion() throws {
        let parsed = try parse(["history", "list", "--project", "avatar.vrmauthor", "--limit", "5", "--threads=2"])
        XCTAssertEqual(parsed.operation.name, "history list")
        XCTAssertEqual(parsed.request["project"], "avatar.vrmauthor")
        XCTAssertEqual(parsed.request["limit"], 5)
        XCTAssertEqual(parsed.request["threads"], 2)
        XCTAssertEqual(code(["history", "list", "--project", "p", "--limit", "five"]), .invalidRequest)
        XCTAssertEqual(code(["history", "list", "--project", "p", "--limit", "1.5"]), .invalidRequest)
    }

    func testBooleanFlagsMayBeBare() throws {
        let bare = try parse(["recipe", "export", "--project", "p", "--out", "r.json", "--resolved"])
        XCTAssertEqual(bare.request["resolved"], true)
        let explicit = try parse(["recipe", "apply", "--project", "p", "--dry-run", "false", "--expected-revision", "3"])
        XCTAssertEqual(explicit.request["dryRun"], false)
        XCTAssertEqual(explicit.request["expectedRevision"], 3)
        let leading = try parse(["recipe", "apply", "--dry-run", "--project", "p"])
        XCTAssertEqual(leading.request["dryRun"], true)
        XCTAssertEqual(leading.request["project"], "p")
        XCTAssertEqual(code(["recipe", "apply", "--project", "p", "--dry-run", "maybe"]), .invalidRequest)
    }

    func testStructuredFlagsParseAsJSON() throws {
        let parsed = try parse(["control", "set", "--project", "p", "--edit", #"{"object":"avatar:main","values":{"body.heightM":1.7}}"#])
        XCTAssertEqual(parsed.request["edit"]?["values"]?["body.heightM"], 1.7)
    }

    func testConflictBetweenRequestJSONAndFlag() throws {
        let file = cwd.appendingPathComponent("req-\(UUID().uuidString).json")
        try Data(#"{"command":"build"}"#.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(code(["describe", "--request", file.path, "--command", "build"]), .conflictingArgument)
        XCTAssertEqual(code(["describe", "--request", file.path, "--command", "version"]), .conflictingArgument)
        let merged = try parse(["describe", "--request", file.path, "--namespace", "v1"])
        XCTAssertEqual(merged.request["command"], "build")
        XCTAssertEqual(merged.request["namespace"], "v1")
    }

    func testRequestFromStdin() throws {
        let parsed = try parse(["schema", "show", "--request", "-"], stdin: #"{"name":"Material"}"#)
        XCTAssertEqual(parsed.request["name"], "Material")
        XCTAssertEqual(code(["schema", "show", "--request", "-"], stdin: "[1]"), .invalidRequest)
        XCTAssertEqual(code(["schema", "show", "--request", "-"], stdin: "{bad"), .invalidRequest)
        XCTAssertEqual(code(["schema", "show", "--request", "/nonexistent/req.json"]), .missingInput)
        XCTAssertEqual(code(["schema", "show", "--request", "-", "--request", "-"], stdin: "{}"), .conflictingArgument)
    }

    func testUnknownFlagsCommandsAndDuplicates() {
        XCTAssertEqual(code(["version", "--bogus", "1"]), .unknownField)
        XCTAssertEqual(code(["bogus"]), .invalidRequest)
        XCTAssertEqual(code(["schema", "bogus"]), .invalidRequest)
        XCTAssertEqual(code(["schema", "show", "extra", "--name", "x"]), .invalidRequest)
        XCTAssertEqual(code([]), .invalidRequest)
        XCTAssertEqual(code(["version", "--log-level", "warn", "--log-level", "debug"]), .conflictingArgument)
        XCTAssertEqual(code(["version", "stray"]), .invalidRequest)
        XCTAssertEqual(code(["version", "--"]), .invalidRequest)
        XCTAssertEqual(code(["schema", "show", "--name"]), .invalidRequest)
    }

    private func run(_ args: [String], stdin: String = "") -> (Int32, JSONValue?, String) {
        var out = Data()
        var err = ""
        let code = CLIDriver.run(arguments: args, environment: ProcessInfo.processInfo.environment, cwd: cwd, executableURL: nil,
                                 stdin: { Data(stdin.utf8) }, stdout: { out.append($0) }, stderr: { err += $0 })
        return (code, try? JSONValue.parse(out), err)
    }

    func testDriverExitCodesAndEnvelopes() {
        let (v, vj, _) = run(["version"])
        XCTAssertEqual(v, 0)
        XCTAssertEqual(vj?["status"], "succeeded")
        XCTAssertEqual(vj?["result"]?["protocol"], "vrmauthor/1")
        let (b, bj, berr) = run(["build"])
        XCTAssertEqual(b, 3)
        XCTAssertEqual(bj?["errors"]?[0]?["code"], "NOT_IMPLEMENTED")
        XCTAssertTrue(berr.contains("NOT_IMPLEMENTED"))
        let (u, uj, _) = run(["bogus"])
        XCTAssertEqual(u, 2)
        XCTAssertEqual(uj?["errors"]?[0]?["code"], "INVALID_REQUEST")
        XCTAssertEqual(run([]).0, 2)
        XCTAssertEqual(run(["--help"]).0, 0)
        XCTAssertEqual(run(["describe", "--command", "nope"]).0, 2)
        XCTAssertEqual(run(["version", "--bogus", "1"]).0, 2)
        let (s, sj, _) = run(["schema", "show", "--request", "-"], stdin: #"{"name":"Recipe"}"#)
        XCTAssertEqual(s, 0)
        XCTAssertEqual(sj?["result"]?["kind"], "model")
    }

    func testDriverOutputIsCompactCanonicalJSONOnStdoutOnly() throws {
        let (_, json, err) = run(["version"])
        var out = Data()
        _ = CLIDriver.run(arguments: ["version"], environment: [:], cwd: cwd, executableURL: nil, stdin: { Data() }, stdout: { out.append($0) }, stderr: { _ in })
        let text = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 1)
        let parsed = try XCTUnwrap(json)
        let canonical = try CanonicalJSON.string(parsed)
        XCTAssertEqual(String(text.dropLast()), canonical)
        XCTAssertFalse(err.contains("{"))
    }
}
