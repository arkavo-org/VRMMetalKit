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

/// Drives the real `CLIDriver` against a project initialized with the stub
/// template. The driver only knows built-in packs, so `project init` with the
/// stub is exit 3 through the CLI; every other Phase 1A command runs end to end.
final class CLIEndToEndTests: XCTestCase {
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

    private func run(_ arguments: [String], stdin: String = "") throws -> (Int32, JSONValue, String) {
        var out = Data()
        var err = ""
        let code = CLIDriver.run(arguments: arguments, environment: ["PATH": "/usr/bin:/bin"], cwd: root, executableURL: nil,
                                 stdin: { Data(stdin.utf8) }, stdout: { out.append($0) }, stderr: { err += $0 })
        XCTAssertTrue(out.last == 0x0A, "stdout ends with one newline")
        return (code, try JSONValue.parse(out), err)
    }

    func testProjectInitWithUnknownTemplateExitsThree() throws {
        let (code, envelope, err) = try run(["project", "init", "--dir", "x.vrmauthor", "--template", StubTemplatePack.packId])
        XCTAssertEqual(code, 3)
        XCTAssertEqual(envelope["status"], "failed")
        XCTAssertEqual(envelope["errors"]?[0]?["code"], "MISSING_CAPABILITY")
        XCTAssertTrue(err.contains("MISSING_CAPABILITY"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("x.vrmauthor").path))
    }

    func testReadsHistoryAndObjectEditsThroughTheCLI() throws {
        let (inspectCode, inspect, inspectErr) = try run(["project", "inspect", "--project", "avatar.vrmauthor"])
        XCTAssertEqual(inspectCode, 0, inspectErr)
        XCTAssertEqual(inspect["protocol"], "vrmauthor/1")
        XCTAssertEqual(inspect["revisionBefore"], 0)
        XCTAssertEqual(inspect["result"]?["revision"], 0)
        XCTAssertEqual(inspect["result"]?["status"], "draft")

        let (listCode, list, _) = try run(["object", "list", "--project", "avatar.vrmauthor", "--kind", "hair"])
        XCTAssertEqual(listCode, 0)
        XCTAssertEqual(list["result"]?["objects"]?[0]?["id"], "hair:bob")

        let (setCode, set, _) = try run(["object", "set", "--project", "avatar.vrmauthor", "--request-id", "cli-1", "--expected-revision", "0",
                                         "--edit", #"{"id":"hair:bob","values":{"/controls/lengthM":0.2}}"#])
        XCTAssertEqual(setCode, 0)
        XCTAssertEqual(set["revisionAfter"], 1)
        XCTAssertEqual(set["result"]?["invalidations"]?[0], "hair:bob/geometry")

        let (stdinCode, viaStdin, _) = try run(["object", "get", "--project", "avatar.vrmauthor", "--request", "-"], stdin: #"{"id":"hair:bob"}"#)
        XCTAssertEqual(stdinCode, 0)
        XCTAssertEqual(viaStdin["result"]?["object"]?["controls"]?["lengthM"], 0.2)
        XCTAssertEqual(viaStdin["result"]?["object"]?["revision"], 1)

        let (staleCode, stale, _) = try run(["object", "set", "--project", "avatar.vrmauthor", "--expected-revision", "0", "--edit", #"{"id":"hair:bob","values":{"/controls/lengthM":0.21}}"#])
        XCTAssertEqual(staleCode, 4)
        XCTAssertEqual(stale["errors"]?[0]?["code"], "REVISION_CONFLICT")

        let (replayCode, replay, _) = try run(["object", "set", "--project", "avatar.vrmauthor", "--request-id", "cli-1", "--expected-revision", "0",
                                               "--edit", #"{"id":"hair:bob","values":{"/controls/lengthM":0.2}}"#])
        XCTAssertEqual(replayCode, 0)
        XCTAssertEqual(replay, set)

        let (historyCode, history, _) = try run(["history", "list", "--project", "avatar.vrmauthor", "--limit", "5"])
        XCTAssertEqual(historyCode, 0)
        XCTAssertEqual(history["result"]?["revisions"]?.array?.count, 2)
        XCTAssertEqual(history["result"]?["receipts"]?[0]?["requestId"], "cli-1")

        let (restoreCode, restore, _) = try run(["history", "restore", "--project", "avatar.vrmauthor", "--revision", "0"])
        XCTAssertEqual(restoreCode, 0)
        XCTAssertEqual(restore["revisionAfter"], 2)

        let (controlCode, control, _) = try run(["control", "list", "--project", "avatar.vrmauthor"])
        XCTAssertEqual(controlCode, 3, "control commands need the installed pack, which the CLI cannot see for the stub")
        XCTAssertEqual(control["errors"]?[0]?["code"], "MISSING_CAPABILITY")

        let (unknownCode, unknown, _) = try run(["object", "list", "--project", "avatar.vrmauthor", "--kind", "wig"])
        XCTAssertEqual(unknownCode, 2)
        XCTAssertEqual(unknown["status"], "failed")
    }

    func testDescribeReportsPhaseOneAHandlersRunnable() throws {
        let (code, describe, _) = try run(["describe"])
        XCTAssertEqual(code, 0)
        let commands = try XCTUnwrap(describe["result"]?["commands"]?.array)
        let runnable = commands.filter { $0["runnable"] == true }.compactMap { $0["name"]?.string }
        for name in ProjectHandlers.names { XCTAssertTrue(runnable.contains(name), name) }
        XCTAssertFalse(runnable.contains("build"))
    }
}
