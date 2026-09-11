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

/// Transport fixtures for `serve --stdio --protocol jsonrpc`: stale writer,
/// replayed receipt, changed-payload request ID, malformed transport lines,
/// mutating notifications and the missing-handler expectation.
final class ServePackTests: XCTestCase {
    private var root: URL!
    private var dir: URL!
    private var ctx: OperationContext!
    private var session: ServeSession!

    override func setUpWithError() throws {
        root = try ProjectTestHarness.makeRoot()
        dir = root.appendingPathComponent("avatar.vrmauthor")
        ctx = ProjectTestHarness.context(cwd: root)
        try ProjectTestHarness.initProject(ctx, dir: dir)
        session = ServeSession(context: ctx, protocol: .jsonrpc)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func send(_ line: String) throws -> JSONValue? {
        guard let response = session.handle(line: line) else { return nil }
        XCTAssertFalse(response.contains("\n"), "responses are single lines")
        return try JSONValue.parse(response)
    }

    private func request(_ id: JSONValue, _ method: String, _ params: [String: JSONValue]) throws -> String {
        var p = params
        if p["project"] == nil { p["project"] = .string(dir.path) }
        return try CanonicalJSON.string(["jsonrpc": "2.0", "id": id, "method": .string(method), "params": .object(p)])
    }

    private func controlSet(id: JSONValue, requestId: String, expectedRevision: Int, value: Double) throws -> String {
        try request(id, "control.set", ["requestId": .string(requestId), "expectedRevision": .number(Double(expectedRevision)),
                                        "edit": ["object": "avatar:main", "values": ["body.heightM": .number(value)]]])
    }

    func testReadAndMutationRoundTripWithIdCorrelation() throws {
        let inspect = try XCTUnwrap(try send(try request("a", "project.inspect", [:])))
        XCTAssertEqual(inspect["jsonrpc"], "2.0")
        XCTAssertEqual(inspect["id"], "a")
        XCTAssertNil(inspect["error"])
        XCTAssertEqual(inspect["result"]?["protocol"], "vrmauthor/1")
        XCTAssertEqual(inspect["result"]?["status"], "succeeded")
        XCTAssertEqual(inspect["result"]?["exitCode"], 0)
        XCTAssertEqual(inspect["result"]?["result"]?["revision"], 0)

        let set = try XCTUnwrap(try send(try controlSet(id: 7, requestId: "m1", expectedRevision: 0, value: 1.7)))
        XCTAssertEqual(set["id"], 7)
        XCTAssertEqual(set["result"]?["status"], "succeeded")
        XCTAssertEqual(set["result"]?["requestId"], "m1")
        XCTAssertEqual(set["result"]?["revisionBefore"], 0)
        XCTAssertEqual(set["result"]?["revisionAfter"], 1)
        XCTAssertEqual(set["result"]?["plan"]?["baseRevision"], 0)
        XCTAssertEqual(try ProjectStore.open(at: dir).state().revision, 1)
        XCTAssertEqual(session.requestsHandled, 2)

        let projectFree = try XCTUnwrap(try send(#"{"jsonrpc":"2.0","id":null,"method":"version"}"#))
        XCTAssertEqual(projectFree["id"], .null)
        XCTAssertEqual(projectFree["result"]?["result"]?["tool"], "vrm-author")
    }

    func testStaleWriterGetsConflictEnvelopeInResult() throws {
        _ = try send(try controlSet(id: 1, requestId: "w1", expectedRevision: 0, value: 1.7))
        let stale = try XCTUnwrap(try send(try controlSet(id: 2, requestId: "w2", expectedRevision: 0, value: 1.8)))
        XCTAssertEqual(stale["id"], 2)
        XCTAssertNil(stale["error"], "domain failures keep the structured application result")
        XCTAssertEqual(stale["result"]?["status"], "failed")
        XCTAssertEqual(stale["result"]?["exitCode"], 4)
        XCTAssertEqual(stale["result"]?["errors"]?[0]?["code"], "REVISION_CONFLICT")
        XCTAssertEqual(stale["result"]?["revisionAfter"], 1)
        XCTAssertEqual(try ProjectStore.open(at: dir).state().object(id: "avatar:main")?.fields["body"]?["body.heightM"], 1.7)
    }

    func testReplayedReceiptReturnsOriginalResult() throws {
        let first = try XCTUnwrap(try send(try controlSet(id: 1, requestId: "same", expectedRevision: 0, value: 1.7)))
        let replay = try XCTUnwrap(try send(try controlSet(id: 2, requestId: "same", expectedRevision: 0, value: 1.7)))
        XCTAssertEqual(replay["id"], 2)
        XCTAssertEqual(replay["result"], first["result"])
        XCTAssertEqual(try ProjectStore.open(at: dir).state().revision, 1)
        var reopened = ServeSession(context: ProjectTestHarness.context(cwd: root), protocol: .jsonrpc)
        let afterRestart = try JSONValue.parse(try XCTUnwrap(reopened.handle(line: try controlSet(id: 3, requestId: "same", expectedRevision: 0, value: 1.7))))
        XCTAssertEqual(afterRestart["result"], first["result"])
    }

    func testChangedPayloadUnderSameRequestIdIsRejected() throws {
        _ = try send(try controlSet(id: 1, requestId: "same", expectedRevision: 0, value: 1.7))
        let changed = try XCTUnwrap(try send(try controlSet(id: 2, requestId: "same", expectedRevision: 1, value: 1.8)))
        XCTAssertEqual(changed["result"]?["status"], "failed")
        XCTAssertEqual(changed["result"]?["errors"]?[0]?["code"], "REQUEST_ID_REUSED")
        XCTAssertEqual(changed["result"]?["exitCode"], 4)
        XCTAssertEqual(try ProjectStore.open(at: dir).state().revision, 1)
    }

    func testMalformedTransportLinesAreParseErrors() throws {
        for line in ["{not json", "\"string\"", "[]", "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"version\"}trailing"] {
            let response = try XCTUnwrap(try send(line), line)
            let expected = line == "\"string\"" || line == "[]" ? RPCError.invalidRequest : RPCError.parseError
            XCTAssertEqual(response["error"]?["code"], .number(Double(expected)), line)
            XCTAssertEqual(response["id"], .null, line)
            XCTAssertNil(response["result"], line)
        }
        XCTAssertNil(try send(""))
        XCTAssertNil(try send("   "))
        XCTAssertEqual(try send(#"{"jsonrpc":"1.0","id":1,"method":"version"}"#)?["error"]?["code"], -32600)
        XCTAssertEqual(try send(#"{"jsonrpc":"2.0","id":1}"#)?["error"]?["code"], -32600)
        XCTAssertEqual(try send(#"{"jsonrpc":"2.0","id":{"a":1},"method":"version"}"#)?["error"]?["code"], -32600)
        XCTAssertEqual(try send(#"{"jsonrpc":"2.0","id":1,"method":"version","params":5}"#)?["error"]?["code"], -32602)
        XCTAssertEqual(try send(#"{"jsonrpc":"2.0","id":1,"method":"nope.method"}"#)?["error"]?["code"], -32601)
        XCTAssertEqual(try send(#"{"jsonrpc":"2.0","id":1,"method":"serve","params":{"stdio":true}}"#)?["error"]?["code"], -32601)
        XCTAssertEqual(try send(#"{"jsonrpc":"2.0","id":1,"method":"project.inspect","params":{}}"#)?["error"]?["code"], -32602, "project is required")
        XCTAssertEqual(try ProjectStore.open(at: dir).state().revision, 0)
    }

    func testMutatingNotificationsAreRejected() throws {
        let line = try CanonicalJSON.string(["jsonrpc": "2.0", "method": "control.set", "params": [
            "project": .string(dir.path), "requestId": "n1", "expectedRevision": 0, "edit": ["object": "avatar:main", "values": ["body.heightM": 1.7]],
        ]])
        let response = try XCTUnwrap(try send(line))
        XCTAssertEqual(response["error"]?["code"], -32600)
        XCTAssertEqual(response["id"], .null)
        XCTAssertEqual(try ProjectStore.open(at: dir).state().revision, 0)
        XCTAssertNil(try ProjectStore.open(at: dir).receipt(requestId: "n1"))
        let readNotification = try CanonicalJSON.string(["jsonrpc": "2.0", "method": "project.inspect", "params": ["project": .string(dir.path)]])
        XCTAssertNil(try send(readNotification), "read notifications produce no response")
    }

    func testMutationWithoutExpectedRevisionIsInvalidParams() throws {
        let line = try request(1, "control.set", ["requestId": "x", "edit": ["object": "avatar:main", "values": ["body.heightM": 1.7]]])
        let response = try XCTUnwrap(try send(line))
        XCTAssertEqual(response["error"]?["code"], -32602)
        XCTAssertEqual(response["error"]?["data"]?["path"], "/expectedRevision")
        XCTAssertEqual(try ProjectStore.open(at: dir).state().revision, 0)
    }

    func testSchemaViolationsAreDomainFailuresNotProtocolErrors() throws {
        let response = try XCTUnwrap(try send(try request(1, "history.list", ["limit": 0])))
        XCTAssertNil(response["error"])
        XCTAssertEqual(response["result"]?["status"], "failed")
        XCTAssertEqual(response["result"]?["exitCode"], 2)
        XCTAssertEqual(response["result"]?["errors"]?[0]?["code"], "INVALID_REQUEST")
    }

    func testMissingHandlerReturnsNotImplementedEnvelopeWithExitThree() throws {
        session = ServeSession(context: ProjectTestHarness.context(cwd: root, registry: Registry.v1SchemaOnly()), protocol: .jsonrpc)
        let response = try XCTUnwrap(try send(try request("b1", "build", ["out": "draft.vrm"])))
        XCTAssertEqual(response["id"], "b1")
        XCTAssertNil(response["error"])
        XCTAssertEqual(response["result"]?["protocol"], "vrmauthor/1")
        XCTAssertEqual(response["result"]?["status"], "failed")
        XCTAssertEqual(response["result"]?["exitCode"], 3)
        XCTAssertEqual(response["result"]?["errors"]?[0]?["code"], "NOT_IMPLEMENTED")
        XCTAssertEqual(response["result"]?["errors"]?[0]?["suggestedCommands"], ["capabilities", "describe build"])
        XCTAssertEqual(session.context.registry.operation(rpcMethod: "build")?.isRunnable, false)
    }

    func testDefaultProjectFromServeInvocationAndBatches() throws {
        var scoped = ServeSession(context: ProjectTestHarness.context(cwd: root, projectPath: dir), protocol: .jsonrpc)
        let single = try JSONValue.parse(try XCTUnwrap(scoped.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"object.list","params":{"kind":"hair"}}"#)))
        XCTAssertEqual(single["result"]?["result"]?["objects"]?[0]?["id"], "hair:bob")
        let batch = try JSONValue.parse(try XCTUnwrap(scoped.handle(line: #"[{"jsonrpc":"2.0","id":1,"method":"version"},{"jsonrpc":"2.0","method":"version"},{"foo":"bar"}]"#)))
        let responses = try XCTUnwrap(batch.array)
        XCTAssertEqual(responses.count, 2)
        XCTAssertEqual(responses[0]["id"], 1)
        XCTAssertEqual(responses[1]["error"]?["code"], -32600)
        XCTAssertEqual(scoped.run(input: "\n{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"version\"}\n").count, 1)
    }

    func testLogsGoOnlyToTheLogSink() throws {
        var lines: [String] = []
        let sink = LogSink()
        var logging = ServeSession(context: ctx, protocol: .jsonrpc, log: { sink.append($0) })
        _ = logging.handle(line: "{bad")
        _ = logging.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"nope"}"#)
        lines = sink.lines
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("parse error"))
        XCTAssertTrue(lines[1].hasPrefix("rpc error -32601"))
    }
}

final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}
