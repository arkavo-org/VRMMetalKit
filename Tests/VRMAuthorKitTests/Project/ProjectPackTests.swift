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

/// Acceptance pack for project init/inspect and history list/restore,
/// including the revision fixtures shared by every mutation: atomic rollback,
/// crash/restart replay and the concurrent stale writer.
final class ProjectPackTests: XCTestCase {
    private var root: URL!
    private var dir: URL!
    private var ctx: OperationContext!

    override func setUpWithError() throws {
        root = try ProjectTestHarness.makeRoot()
        dir = root.appendingPathComponent("avatar.vrmauthor")
        ctx = ProjectTestHarness.context(cwd: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func invoke(_ name: String, _ fields: [String: JSONValue] = [:]) -> ResultEnvelope {
        ProjectTestHarness.invoke(ctx, name, ProjectTestHarness.request(dir, fields))
    }

    private func controlSet(_ requestId: String, _ value: Double, expectedRevision: Int? = nil, dryRun: Bool = false) -> ResultEnvelope {
        var fields: [String: JSONValue] = ["requestId": .string(requestId), "edit": ["object": "avatar:main", "values": ["body.heightM": .number(value)]], "dryRun": .bool(dryRun)]
        if let expectedRevision { fields["expectedRevision"] = .number(Double(expectedRevision)) }
        return invoke("control set", fields)
    }

    // MARK: project init

    func testInitWritesRevisionZeroLockAndResolvedRecipe() throws {
        let envelope = try ProjectTestHarness.initProject(ctx, dir: dir, seed: 7)
        XCTAssertEqual(envelope.exitCode, .success)
        XCTAssertNil(envelope.revisionBefore)
        XCTAssertEqual(envelope.revisionAfter, 0)
        XCTAssertEqual(envelope.result?["revision"], 0)
        XCTAssertEqual(envelope.result?["project"], .string(dir.standardizedFileURL.path))
        XCTAssertEqual(envelope.result?["template"]?["id"], .string(StubTemplatePack.packId))
        XCTAssertEqual(envelope.result?["template"]?["sha256"], .string(StubTemplatePack().sha256))
        let recipe = try XCTUnwrap(envelope.result?["recipe"])
        XCTAssertEqual(recipe["name"], "avatar")
        XCTAssertEqual(recipe["seed"], 7)
        XCTAssertEqual(recipe["template"]?["id"], .string(StubTemplatePack.packId))
        XCTAssertEqual(recipe["body"]?["body.heightM"], 1.65)
        XCTAssertEqual(recipe["hair"]?.array?.count, 1)
        _ = try Recipe.decode(recipe)

        let store = try ProjectStore.open(at: dir)
        let state = try store.state()
        XCTAssertEqual(state.revision, 0)
        XCTAssertEqual(state.seed, 7)
        XCTAssertEqual(state.recipe, recipe)
        XCTAssertEqual(try store.revisionNumbers(), [0])
        XCTAssertEqual(try store.revision(0).state, state)
        XCTAssertEqual(try store.revision(0).operation, "project init")
        XCTAssertEqual(try store.receipts().count, 0)
        XCTAssertEqual(Set(state.objects.keys), ["avatar:main", "lookat:main", "hair:bob", "garment:top", "layer:skin", "layer:blush", "material:cloth", "material:hair",
                                                 "expression:blink", "spring:hair", "collider:head", "group:head"])
        XCTAssertEqual(state.object(id: "hair:bob")?.kind, .hair)
        XCTAssertEqual(state.object(id: "garment:top")?.kind, .garment)
        XCTAssertEqual(state.object(id: "avatar:main")?.fields["body"]?["body.heightM"], 1.65)
        XCTAssertEqual(state.object(id: "avatar:main")?.provenance["source"], "template")

        let lock = try store.lock()
        XCTAssertEqual(lock["tool"], "vrm-author")
        XCTAssertEqual(lock["seed"], 7)
        XCTAssertEqual(lock["template"]?["sha256"], .string(StubTemplatePack().sha256))
        XCTAssertEqual(lock["schemaHashes"]?.object?.count, 35)
        XCTAssertEqual(lock["schemaHashes"]?["control set"], .string(ctx.registry.operation(named: "control set")!.schemaHash))
        XCTAssertEqual(lock["modelHashes"]?["Recipe"], .string(Recipe.schema.schemaHash))
    }

    func testInitRejectsUnknownTemplateWithExitThreeAndLeavesNoDirectory() throws {
        let envelope = ProjectTestHarness.invoke(ctx, "project init", ["dir": .string(dir.path), "template": "native-anime-v1"])
        XCTAssertEqual(envelope.status, .failed)
        XCTAssertEqual(envelope.exitCode, .missingCapability)
        XCTAssertEqual(envelope.errors.first?.code, .missingCapability)
        XCTAssertEqual(envelope.errors.first?.required, [.string(StubTemplatePack.packId)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testInitTwiceIsAnInvalidRequestAndNameDefaultsFromDirectory() throws {
        try ProjectTestHarness.initProject(ctx, dir: dir)
        let again = ProjectTestHarness.invoke(ctx, "project init", ["dir": .string(dir.path), "template": .string(StubTemplatePack.packId)])
        XCTAssertEqual(again.exitCode, .invalidRequest)
        XCTAssertEqual(try ProjectStore.open(at: dir).state().name, "avatar")
        let named = ProjectTestHarness.invoke(ctx, "project init", ["dir": "other.vrmauthor", "template": .string(StubTemplatePack.packId), "name": "Mika"])
        XCTAssertEqual(named.status, .succeeded)
        XCTAssertEqual(named.result?["recipe"]?["name"], "Mika")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("other.vrmauthor/project.json").path))
        XCTAssertEqual(ProjectTestHarness.invoke(ctx, "project init", ["dir": .string(dir.path)]).exitCode, .invalidRequest)
    }

    // MARK: project inspect

    func testInspectReportsRevisionStaleLockAndDraftStatus() throws {
        try ProjectTestHarness.initProject(ctx, dir: dir)
        let fresh = invoke("project inspect")
        XCTAssertEqual(fresh.exitCode, .success)
        XCTAssertEqual(fresh.revisionBefore, 0)
        XCTAssertEqual(fresh.revisionAfter, 0)
        XCTAssertEqual(fresh.result?["revision"], 0)
        XCTAssertEqual(fresh.result?["name"], "avatar")
        XCTAssertEqual(fresh.result?["objects"], 12)
        XCTAssertEqual(fresh.result?["stale"], ["build"])
        XCTAssertEqual(fresh.result?["status"], "draft")
        XCTAssertEqual(fresh.result?["lock"]?["seed"], 7)
        XCTAssertEqual(fresh.result?["template"]?["id"], .string(StubTemplatePack.packId))

        let store = try ProjectStore.open(at: dir)
        let marker = store.buildsDirectory.appendingPathComponent("abc").appendingPathComponent(ProjectStore.buildMarkerFileName)
        try store.atomicWrite(Data(#"{"revision":0,"buildHash":"abc"}"#.utf8), to: marker)
        let built = invoke("project inspect")
        XCTAssertEqual(built.result?["stale"], [])
        XCTAssertEqual(built.result?["status"], "complete")

        XCTAssertEqual(controlSet("r1", 1.7).status, .succeeded)
        let edited = invoke("project inspect")
        XCTAssertEqual(edited.result?["revision"], 1)
        XCTAssertEqual(edited.result?["status"], "draft")
        let stale = try XCTUnwrap(edited.result?["stale"]?.array?.compactMap(\.string))
        XCTAssertTrue(stale.contains("avatar:main/geometry"))
        XCTAssertTrue(stale.contains("garment:top/fit"))
        XCTAssertTrue(stale.contains("qa"))

        let missing = ProjectTestHarness.invoke(ctx, "project inspect", ["project": .string(root.appendingPathComponent("nope").path)])
        XCTAssertEqual(missing.exitCode, .missingCapability)
        XCTAssertEqual(missing.errors.first?.code, .projectNotFound)
    }

    // MARK: history

    func testHistoryListReturnsRevisionsAndReceiptsNewestFirstWithLimit() throws {
        try ProjectTestHarness.initProject(ctx, dir: dir)
        XCTAssertEqual(controlSet("r1", 1.7).revisionAfter, 1)
        XCTAssertEqual(controlSet("r2", 1.8).revisionAfter, 2)
        let all = invoke("history list")
        XCTAssertEqual(all.exitCode, .success)
        let revisions = try XCTUnwrap(all.result?["revisions"]?.array)
        XCTAssertEqual(revisions.map { $0["revision"] }, [2, 1, 0])
        XCTAssertEqual(revisions[0]["requestId"], "r2")
        XCTAssertEqual(revisions[0]["operation"], "control set")
        XCTAssertEqual(revisions[0]["parent"], 1)
        XCTAssertEqual(revisions[2]["parent"], .null)
        XCTAssertEqual(revisions[2]["operation"], "project init")
        XCTAssertTrue(revisions[0]["invalidations"]!.array!.contains("qa"))
        let receipts = try XCTUnwrap(all.result?["receipts"]?.array)
        XCTAssertEqual(receipts.map { $0["requestId"] }, ["r2", "r1"])
        XCTAssertEqual(receipts[0]["revisionAfter"], 2)
        XCTAssertEqual(receipts[0]["status"], "succeeded")
        let limited = invoke("history list", ["limit": 1])
        XCTAssertEqual(limited.result?["revisions"]?.array?.count, 1)
        XCTAssertEqual(limited.result?["receipts"]?.array?.count, 1)
        XCTAssertEqual(invoke("history list", ["limit": 0]).exitCode, .invalidRequest)
        XCTAssertEqual(invoke("history list", ["limit": 1001]).exitCode, .invalidRequest)
    }

    func testHistoryRestoreCreatesNewRevisionAndKeepsHistory() throws {
        try ProjectTestHarness.initProject(ctx, dir: dir)
        XCTAssertEqual(controlSet("r1", 1.7).revisionAfter, 1)
        XCTAssertEqual(controlSet("r2", 1.8).revisionAfter, 2)
        let restore = invoke("history restore", ["revision": 0, "requestId": "restore-0", "expectedRevision": 2])
        XCTAssertEqual(restore.exitCode, .success, "\(restore.errors)")
        XCTAssertEqual(restore.revisionBefore, 2)
        XCTAssertEqual(restore.revisionAfter, 3)
        XCTAssertEqual(restore.plan?.edits.first?.objectId, "project")
        XCTAssertEqual(restore.result?["plan"]?["baseRevision"], 2)
        let invalidations = try XCTUnwrap(restore.result?["invalidations"]?.array?.compactMap(\.string))
        XCTAssertTrue(invalidations.contains("avatar:main/geometry"))
        XCTAssertTrue(invalidations.contains("qa"))
        let store = try ProjectStore.open(at: dir)
        let state = try store.state()
        XCTAssertEqual(state.revision, 3)
        XCTAssertEqual(state.object(id: "avatar:main")?.fields["body"]?["body.heightM"], 1.65)
        XCTAssertEqual(state.recipe?["body"]?["body.heightM"], 1.65)
        XCTAssertEqual(try store.revisionNumbers(), [0, 1, 2, 3])
        XCTAssertEqual(try store.revision(2).state.object(id: "avatar:main")?.fields["body"]?["body.heightM"], 1.8)
        XCTAssertEqual(try store.receipt(requestId: "restore-0")?.revisionAfter, 3)
        XCTAssertEqual(try store.revision(3).operation, "history restore")
        XCTAssertEqual(invoke("history restore", ["revision": 9, "expectedRevision": 3]).exitCode, .invalidRequest)
        XCTAssertEqual(invoke("history restore", ["revision": -1, "expectedRevision": 3]).exitCode, .invalidRequest)
        let dry = invoke("history restore", ["revision": 2, "dryRun": true])
        XCTAssertEqual(dry.revisionAfter, 3)
        XCTAssertEqual(dry.plan?.baseRevision, 3)
        XCTAssertEqual(try store.state().revision, 3)
    }

    // MARK: revision fixtures

    func testAtomicRollbackOnFailedValidationMidEdit() throws {
        try ProjectTestHarness.initProject(ctx, dir: dir)
        let before = try ProjectStore.open(at: dir).state()
        let envelope = invoke("object set", ["requestId": "bad", "expectedRevision": 0, "edit": [
            "id": "hair:bob", "values": ["/controls/lengthM": 0.2, "/controls/widthScale": 9],
        ]])
        XCTAssertEqual(envelope.status, .failed)
        XCTAssertEqual(envelope.exitCode, .invalidRequest)
        XCTAssertEqual(envelope.requestId, "bad")
        XCTAssertEqual(envelope.revisionBefore, 0)
        XCTAssertEqual(envelope.revisionAfter, 0)
        XCTAssertEqual(envelope.errors.first?.objectId, "hair:bob")
        XCTAssertEqual(envelope.errors.first?.path, "/controls/widthScale")
        let store = try ProjectStore.open(at: dir)
        XCTAssertEqual(try store.state(), before)
        XCTAssertEqual(try store.state().object(id: "hair:bob")?.fields["controls"]?["lengthM"], 0.18)
        XCTAssertEqual(try store.revisionNumbers(), [0])
        XCTAssertNil(try store.receipt(requestId: "bad"))
        XCTAssertEqual(try store.receipts(), [])
    }

    func testCrashRestartReplayReturnsOriginalResult() throws {
        try ProjectTestHarness.initProject(ctx, dir: dir)
        let first = controlSet("retry-1", 1.72, expectedRevision: 0)
        XCTAssertEqual(first.status, .succeeded)
        XCTAssertEqual(first.revisionAfter, 1)
        let reopened = ProjectTestHarness.context(cwd: root)
        let replay = ProjectTestHarness.invoke(reopened, "control set", ProjectTestHarness.request(dir, [
            "requestId": "retry-1", "expectedRevision": 0, "edit": ["object": "avatar:main", "values": ["body.heightM": 1.72]],
        ]))
        XCTAssertEqual(replay, first)
        let store = try ProjectStore.open(at: dir)
        XCTAssertEqual(try store.state().revision, 1)
        XCTAssertEqual(try store.receipts().count, 1)
        let receipt = try XCTUnwrap(try store.receipt(requestId: "retry-1"))
        XCTAssertEqual(receipt.revisionAfter, 1)
        XCTAssertEqual(receipt.result.plan, first.plan)
        XCTAssertEqual(receipt.result.status, .succeeded)
    }

    func testConcurrentStaleWriterGetsRevisionConflict() throws {
        try ProjectTestHarness.initProject(ctx, dir: dir)
        let a = controlSet("writer-a", 1.7, expectedRevision: 0)
        let b = controlSet("writer-b", 1.8, expectedRevision: 0)
        XCTAssertEqual(a.status, .succeeded)
        XCTAssertEqual(b.status, .failed)
        XCTAssertEqual(b.exitCode, .conflict)
        XCTAssertEqual(b.errors.first?.code, .revisionConflict)
        XCTAssertEqual(b.errors.first?.observed, 1)
        XCTAssertEqual(b.errors.first?.required, 0)
        XCTAssertEqual(b.revisionBefore, 1)
        XCTAssertEqual(b.revisionAfter, 1)
        let store = try ProjectStore.open(at: dir)
        XCTAssertEqual(try store.state().object(id: "avatar:main")?.fields["body"]?["body.heightM"], 1.7)
        XCTAssertNil(try store.receipt(requestId: "writer-b"))
        XCTAssertEqual(controlSet("writer-b", 1.8, expectedRevision: 1).revisionAfter, 2)
    }

    func testChangedPayloadUnderSameRequestIdIsReused() throws {
        try ProjectTestHarness.initProject(ctx, dir: dir)
        XCTAssertEqual(controlSet("same", 1.7).status, .succeeded)
        let changed = controlSet("same", 1.75)
        XCTAssertEqual(changed.exitCode, .conflict)
        XCTAssertEqual(changed.errors.first?.code, .requestIdReused)
        XCTAssertEqual(try ProjectStore.open(at: dir).state().revision, 1)
    }

    func testGeneratedRequestIdIsReportedAndPersisted() throws {
        try ProjectTestHarness.initProject(ctx, dir: dir)
        let envelope = invoke("control set", ["edit": ["object": "avatar:main", "values": ["body.heightM": 1.7]]])
        XCTAssertEqual(envelope.status, .succeeded)
        let requestId = try XCTUnwrap(envelope.requestId)
        XCTAssertTrue(requestId.hasPrefix("req-"))
        XCTAssertEqual(try ProjectStore.open(at: dir).receipt(requestId: requestId)?.revisionAfter, 1)
    }

    func testDryRunPlanThenApplyWithExpectedPlanHash() throws {
        try ProjectTestHarness.initProject(ctx, dir: dir)
        let dry = controlSet("plan-1", 1.7, expectedRevision: 0, dryRun: true)
        XCTAssertEqual(dry.status, .succeeded)
        XCTAssertEqual(dry.revisionAfter, 0)
        let plan = try XCTUnwrap(dry.plan)
        XCTAssertEqual(plan.baseRevision, 0)
        XCTAssertEqual(plan.edits.first?.pointer, "/body/body.heightM")
        XCTAssertEqual(plan.edits.first?.before, 1.65)
        XCTAssertEqual(plan.edits.first?.after, 1.7)
        XCTAssertEqual(dry.result?["plan"]?["planHash"], .string(plan.planHash))
        XCTAssertEqual(try ProjectStore.open(at: dir).state().revision, 0)
        let mismatch = invoke("control set", ["requestId": "plan-1", "expectedRevision": 0, "expectedPlanHash": .string(String(repeating: "f", count: 64)),
                                              "edit": ["object": "avatar:main", "values": ["body.heightM": 1.7]]])
        XCTAssertEqual(mismatch.exitCode, .conflict)
        XCTAssertEqual(mismatch.errors.first?.code, .planHashMismatch)
        let applied = invoke("control set", ["requestId": "plan-1", "expectedRevision": 0, "expectedPlanHash": .string(plan.planHash),
                                             "edit": ["object": "avatar:main", "values": ["body.heightM": 1.7]]])
        XCTAssertEqual(applied.revisionAfter, 1)
        XCTAssertEqual(applied.plan?.planHash, plan.planHash)
    }
}
