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

final class ProjectStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vrmauthor-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() throws -> ProjectStore {
        try ProjectStore.create(at: root.appendingPathComponent("avatar.vrmauthor"), name: "avatar", template: TemplateRef(id: "native-anime-v1", sha256: String(repeating: "a", count: 64)),
                                seed: 7, lock: ["tool": "vrm-author", "version": "0.1.0"])
    }

    private func hairObject() throws -> ProjectObject {
        try ProjectObject(id: "hair:main", kind: .hair, provenance: ["source": "pack"], writablePointers: ["/controls", "/texture/baseColour"],
                          fields: ["controls": ["lengthM": 0.18], "texture": ["baseColour": ["rgba": [0.1, 0.1, 0.1, 1]]], "bones": ["b0", "b1"]])
    }

    func testCreateWritesLayoutAndRevisionZero() throws {
        let store = try makeStore()
        let fm = FileManager.default
        for rel in ["project.json", "lock.json", "revisions/000000.json", "receipts", "assets/sha256", "builds", "reports"] {
            XCTAssertTrue(fm.fileExists(atPath: store.root.appendingPathComponent(rel).path), rel)
        }
        let state = try store.state()
        XCTAssertEqual(state.revision, 0)
        XCTAssertEqual(state.name, "avatar")
        XCTAssertEqual(state.seed, 7)
        XCTAssertEqual(try store.lock()["tool"], "vrm-author")
        XCTAssertEqual(try store.revisionNumbers(), [0])
        XCTAssertThrowsError(try makeStore())
        XCTAssertEqual((try? ProjectStore.open(at: root.appendingPathComponent("missing"))) == nil, true)
        do { _ = try ProjectStore.open(at: root.appendingPathComponent("missing")); XCTFail() } catch let e as AuthorError { XCTAssertEqual(e.code, .projectNotFound) }
    }

    func testMutationCommitsRevisionReceiptAndPlan() throws {
        let store = try makeStore()
        let object = try hairObject()
        let envelope = try store.mutate(requestId: "r1", payload: ["edit": 1], expectedRevision: 0, dryRun: false, expectedPlanHash: nil, operation: "object set") { tx in
            try tx.insert(object)
            tx.invalidate("hair:main/bones")
            return ["inserted": "hair:main"]
        }
        XCTAssertEqual(envelope.status, .succeeded)
        XCTAssertEqual(envelope.revisionBefore, 0)
        XCTAssertEqual(envelope.revisionAfter, 1)
        XCTAssertEqual(envelope.plan?.baseRevision, 0)
        XCTAssertEqual(envelope.plan?.invalidations, ["hair:main/bones"])
        XCTAssertEqual(envelope.plan?.edits.count, 1)
        XCTAssertEqual(try store.state().revision, 1)
        XCTAssertEqual(try store.state().object(id: "hair:main")?.revision, 1)
        XCTAssertEqual(try store.revisionNumbers(), [0, 1])
        XCTAssertEqual(try store.revision(1).requestId, "r1")
        XCTAssertEqual(try store.revision(1).operation, "object set")
        XCTAssertEqual(try store.receipt(requestId: "r1")?.revisionAfter, 1)
        XCTAssertEqual(try store.receipts().count, 1)
    }

    func testCASConflictLeavesProjectUnchanged() throws {
        let store = try makeStore()
        _ = try store.mutate(requestId: "r1", payload: [:], expectedRevision: 0, dryRun: false, expectedPlanHash: nil) { tx in try tx.insert(try hairObject()); return nil }
        var ran = false
        XCTAssertThrowsError(try store.mutate(requestId: "r2", payload: [:], expectedRevision: 0, dryRun: false, expectedPlanHash: nil) { tx in
            ran = true
            try tx.remove(objectId: "hair:main")
            return nil
        }) { error in
            let e = error as? AuthorError
            XCTAssertEqual(e?.code, .revisionConflict)
            XCTAssertEqual(e?.code.exitCode, .conflict)
            XCTAssertEqual(e?.observed, 1)
            XCTAssertEqual(e?.required, 0)
        }
        XCTAssertFalse(ran)
        XCTAssertEqual(try store.state().revision, 1)
        XCTAssertNotNil(try store.state().object(id: "hair:main"))
        XCTAssertNil(try store.receipt(requestId: "r2"))
    }

    func testIdempotentReplayReturnsOriginalResultWithoutReExecuting() throws {
        let store = try makeStore()
        var executions = 0
        let body: (inout MutationTransaction) throws -> JSONValue? = { tx in
            executions += 1
            try tx.insert(try self.hairObject())
            return ["n": .number(Double(executions))]
        }
        let first = try store.mutate(requestId: "same", payload: ["a": 1, "requestId": "same", "dryRun": false], expectedRevision: 0, dryRun: false, expectedPlanHash: nil, body: body)
        let replay = try store.mutate(requestId: "same", payload: ["a": 1, "requestId": "same", "expectedPlanHash": "ignored"], expectedRevision: nil, dryRun: false, expectedPlanHash: nil, body: body)
        XCTAssertEqual(executions, 1)
        XCTAssertEqual(replay, first)
        XCTAssertEqual(try store.state().revision, 1)
    }

    func testChangedPayloadUnderSameRequestIdIsRejected() throws {
        let store = try makeStore()
        _ = try store.mutate(requestId: "same", payload: ["a": 1], expectedRevision: 0, dryRun: false, expectedPlanHash: nil) { tx in try tx.insert(try hairObject()); return nil }
        XCTAssertThrowsError(try store.mutate(requestId: "same", payload: ["a": 2], expectedRevision: nil, dryRun: false, expectedPlanHash: nil) { _ in nil }) { error in
            XCTAssertEqual((error as? AuthorError)?.code, .requestIdReused)
            XCTAssertEqual((error as? AuthorError)?.code.exitCode, .conflict)
        }
        XCTAssertEqual(try store.state().revision, 1)
    }

    func testDryRunReturnsPlanWithoutConsumingRequestId() throws {
        let store = try makeStore()
        let body: (inout MutationTransaction) throws -> JSONValue? = { tx in
            try tx.insert(try self.hairObject())
            tx.require("template pack native-anime-v1")
            return nil
        }
        let dry = try store.mutate(requestId: "d1", payload: ["x": 1], expectedRevision: 0, dryRun: true, expectedPlanHash: nil, body: body)
        XCTAssertEqual(dry.status, .succeeded)
        XCTAssertEqual(dry.revisionBefore, 0)
        XCTAssertEqual(dry.revisionAfter, 0)
        let plan = try XCTUnwrap(dry.plan)
        XCTAssertEqual(plan.planHash.count, 64)
        XCTAssertEqual(plan.edits.first?.objectId, "hair:main")
        XCTAssertEqual(plan.prerequisites, ["template pack native-anime-v1"])
        XCTAssertEqual(try store.state().revision, 0)
        XCTAssertNil(try store.receipt(requestId: "d1"))
        XCTAssertEqual(try store.revisionNumbers(), [0])

        XCTAssertThrowsError(try store.mutate(requestId: "d1", payload: ["x": 1], expectedRevision: 0, dryRun: false, expectedPlanHash: String(repeating: "f", count: 64), body: body)) { error in
            XCTAssertEqual((error as? AuthorError)?.code, .planHashMismatch)
        }
        XCTAssertEqual(try store.state().revision, 0)
        let applied = try store.mutate(requestId: "d1", payload: ["x": 1], expectedRevision: 0, dryRun: false, expectedPlanHash: plan.planHash, body: body)
        XCTAssertEqual(applied.revisionAfter, 1)
        XCTAssertEqual(applied.plan?.planHash, plan.planHash)
    }

    func testPlanHashIgnoresRequestIdAndDryRunFlags() throws {
        XCTAssertEqual(try ProjectStore.payloadHash(["a": 1, "requestId": "x", "dryRun": true, "expectedPlanHash": "h"]), try ProjectStore.payloadHash(["a": 1]))
        XCTAssertNotEqual(try ProjectStore.payloadHash(["a": 1]), try ProjectStore.payloadHash(["a": 2]))
    }

    func testAtomicWritesIgnoreLeftoverTempFilesAndOrphans() throws {
        let store = try makeStore()
        _ = try store.mutate(requestId: "r1", payload: [:], expectedRevision: 0, dryRun: false, expectedPlanHash: nil) { tx in try tx.insert(try hairObject()); return nil }
        let fm = FileManager.default
        try Data("{garbage".utf8).write(to: store.projectFile.appendingPathExtension("tmp-999-crash"))
        try Data("{garbage".utf8).write(to: store.revisionsDirectory.appendingPathComponent("000002.json.tmp-999-crash"))
        try Data("{garbage".utf8).write(to: store.receiptsDirectory.appendingPathComponent("r9.json.tmp-999-crash"))
        let orphanRevision = RevisionRecord(revision: 5, parent: 4, requestId: "orphan", operation: nil, plan: nil, state: try store.state())
        try store.atomicWrite(try CanonicalJSON.data(try JSONValue.from(orphanRevision)), to: store.revisionsDirectory.appendingPathComponent("000005.json"))
        let orphanReceipt = Receipt(requestId: "orphan", payloadHash: try ProjectStore.payloadHash([:]), revisionBefore: 4, revisionAfter: 5,
                                    result: .succeeded(requestId: "orphan", revisionBefore: 4, revisionAfter: 5, result: nil))
        try store.atomicWrite(try CanonicalJSON.data(try JSONValue.from(orphanReceipt)), to: store.receiptsDirectory.appendingPathComponent("orphan.json"))

        let reopened = try ProjectStore.open(at: store.root)
        XCTAssertEqual(try reopened.state().revision, 1)
        XCTAssertEqual(try reopened.revisionNumbers(), [0, 1])
        XCTAssertNil(try reopened.receipt(requestId: "orphan"))
        XCTAssertEqual(try reopened.receipts().map(\.requestId), ["r1"])
        XCTAssertThrowsError(try reopened.revision(5))
        let orphanReplay = try reopened.mutate(requestId: "orphan", payload: [:], expectedRevision: 1, dryRun: false, expectedPlanHash: nil) { tx in
            try tx.set(objectId: "hair:main", pointer: try JSONPointer("/controls/lengthM"), value: 0.2)
            return nil
        }
        XCTAssertEqual(orphanReplay.revisionAfter, 2)
        XCTAssertTrue(fm.fileExists(atPath: store.projectFile.appendingPathExtension("tmp-999-crash").path))
    }

    func testAtomicWriteLeavesNoTempFileOnSuccess() throws {
        let target = root.appendingPathComponent("nested/dir/file.json")
        try ProjectStore.atomicWrite(Data("{}".utf8), to: target)
        XCTAssertEqual(try Data(contentsOf: target), Data("{}".utf8))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
        XCTAssertEqual(siblings, ["file.json"])
    }

    func testWritablePointersAreEnforced() throws {
        let store = try makeStore()
        _ = try store.mutate(requestId: "r1", payload: [:], expectedRevision: 0, dryRun: false, expectedPlanHash: nil) { tx in try tx.insert(try hairObject()); return nil }
        for pointer in ["/bones/0", "/id", "/revision", "/provenance/source", "/texture/tipColour"] {
            XCTAssertThrowsError(try store.mutate(requestId: "w-\(pointer)", payload: [:], expectedRevision: 1, dryRun: false, expectedPlanHash: nil) { tx in
                try tx.set(objectId: "hair:main", pointer: try JSONPointer(pointer), value: 1)
                return nil
            }, pointer) { error in
                XCTAssertEqual((error as? AuthorError)?.code, .invalidRequest, pointer)
            }
        }
        XCTAssertThrowsError(try store.mutate(requestId: "missing", payload: [:], expectedRevision: 1, dryRun: false, expectedPlanHash: nil) { tx in
            try tx.set(objectId: "hair:nope", pointer: try JSONPointer("/controls"), value: 1)
            return nil
        }) { error in XCTAssertEqual((error as? AuthorError)?.code, .objectNotFound) }
        var validated = false
        let ok = try store.mutate(requestId: "ok", payload: [:], expectedRevision: 1, dryRun: false, expectedPlanHash: nil) { tx in
            try tx.set(objectId: "hair:main", pointer: try JSONPointer("/controls/lengthM"), value: 0.25) { object, pointer, value in
                validated = true
                XCTAssertEqual(object.kind, .hair)
                XCTAssertEqual(pointer.description, "/controls/lengthM")
                guard let n = value.number, n >= 0.12, n <= 0.30 else { throw AuthorError.invalidRequest("out of range") }
            }
            return nil
        }
        XCTAssertTrue(validated)
        XCTAssertEqual(ok.plan?.edits.first?.before, 0.18)
        XCTAssertEqual(ok.plan?.edits.first?.after, 0.25)
        let stored = try XCTUnwrap(try store.state().object(id: "hair:main"))
        XCTAssertEqual(stored.revision, 2)
        XCTAssertEqual(stored.fields["controls"]?["lengthM"], 0.25)
        XCTAssertEqual(stored.fields["bones"]?.array?.count, 2)
        XCTAssertThrowsError(try store.mutate(requestId: "bad", payload: [:], expectedRevision: 2, dryRun: false, expectedPlanHash: nil) { tx in
            try tx.set(objectId: "hair:main", pointer: try JSONPointer("/controls/lengthM"), value: 9) { _, _, _ in throw AuthorError.invalidRequest("out of range") }
            return nil
        })
        XCTAssertEqual(try store.state().revision, 2)
    }

    func testJSONPointerSemantics() throws {
        XCTAssertEqual(try JSONPointer("").tokens, [])
        XCTAssertEqual(try JSONPointer("/a~1b/c~0d/0").tokens, ["a/b", "c~d", "0"])
        XCTAssertEqual(try JSONPointer("/a~1b/c~0d/0").description, "/a~1b/c~0d/0")
        XCTAssertThrowsError(try JSONPointer("a/b"))
        XCTAssertThrowsError(try JSONPointer("/a~2"))
        let doc: JSONValue = ["a": ["b": [1, 2, ["c": true]]], "": 5]
        XCTAssertEqual(try JSONPointer("/a/b/2/c").get(in: doc), true)
        XCTAssertEqual(try JSONPointer("/").get(in: doc), 5)
        XCTAssertNil(try JSONPointer("/a/b/9").get(in: doc))
        XCTAssertNil(try JSONPointer("/a/b/01").get(in: doc))
        var mutable = doc
        try JSONPointer("/a/b/-").set(in: &mutable, to: 3)
        try JSONPointer("/x/y").set(in: &mutable, to: "new")
        XCTAssertEqual(mutable["a"]?["b"]?.array?.count, 4)
        XCTAssertEqual(mutable["x"]?["y"], "new")
        XCTAssertThrowsError(try JSONPointer("/a/b/9").set(in: &mutable, to: 1))
        XCTAssertThrowsError(try JSONPointer("//z").set(in: &mutable, to: 1))
        XCTAssertTrue(try JSONPointer("/controls").covers(try JSONPointer("/controls/lengthM")))
        XCTAssertFalse(try JSONPointer("/controls").covers(try JSONPointer("/control")))
    }

    func testStoreAssetIsContentAddressed() throws {
        let store = try makeStore()
        let hash = try store.storeAsset(Data("abc".utf8))
        XCTAssertEqual(hash, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try store.storeAsset(Data("abc".utf8)), hash)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.assetsDirectory.appendingPathComponent(hash).path))
    }
}
