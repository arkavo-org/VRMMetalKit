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

/// Acceptance pack for control list/describe/set.
final class ControlPackTests: XCTestCase {
    private var root: URL!
    private var dir: URL!
    private var ctx: OperationContext!

    override func setUpWithError() throws {
        root = try ProjectTestHarness.makeRoot()
        dir = root.appendingPathComponent("avatar.vrmauthor")
        ctx = ProjectTestHarness.context(cwd: root)
        try ProjectTestHarness.initProject(ctx, dir: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func invoke(_ name: String, _ fields: [String: JSONValue] = [:]) -> ResultEnvelope {
        ProjectTestHarness.invoke(ctx, name, ProjectTestHarness.request(dir, fields))
    }

    private func set(_ object: String, _ values: [String: JSONValue], requestId: String = UUID().uuidString, dryRun: Bool = false) -> ResultEnvelope {
        invoke("control set", ["requestId": .string(requestId), "dryRun": .bool(dryRun), "edit": ["object": .string(object), "values": .object(values)]])
    }

    func testListReturnsTemplateControlsAndPerObjectControls() throws {
        let template = invoke("control list")
        XCTAssertEqual(template.exitCode, .success)
        let controls = try XCTUnwrap(template.result?["controls"]?.array)
        XCTAssertEqual(controls.map { $0["key"] }, ["body.heightM", "face.eye.left.height"])
        XCTAssertEqual(controls[0]["unit"], "metres")
        XCTAssertEqual(controls[0]["validRange"], [1.2, 2.0])
        XCTAssertEqual(controls[0]["recommendedRange"], [1.4, 1.9])
        XCTAssertEqual(controls[0]["defaultValue"], 1.65)
        XCTAssertEqual(controls[0]["side"], "none")
        XCTAssertEqual(controls[0]["affects"], ["avatar", "garment"])
        XCTAssertEqual(controls[0]["dependencies"], ["body.headCount"])
        XCTAssertEqual(controls[1]["side"], "left")
        XCTAssertEqual(controls[1]["mirrorKey"], "face.eye.right.height")
        XCTAssertEqual(invoke("control list", ["object": "avatar:main"]).result?["controls"]?.array?.count, 2)
        let hair = invoke("control list", ["object": "hair:bob"])
        XCTAssertEqual(hair.result?["controls"]?.array?.map { $0["key"] }, ["lengthM", "widthScale", "tipBendDeg", "bangClearanceM"])
        XCTAssertEqual(hair.result?["controls"]?[0]?["validRange"], [0.12, 0.30])
        XCTAssertEqual(invoke("control list", ["object": "garment:top"]).result?["controls"]?.array?.map { $0["key"] }, ["length", "fit"])
        XCTAssertEqual(invoke("control list", ["object": "material:cloth"]).result?["controls"], [])
        XCTAssertEqual(invoke("control list", ["object": "nope"]).errors.first?.code, .objectNotFound)
    }

    func testListRequiresInstalledTemplatePack() throws {
        let bare = ProjectTestHarness.context(cwd: root, templates: TemplateRegistry(packs: []))
        let envelope = ProjectTestHarness.invoke(bare, "control list", ProjectTestHarness.request(dir, [:]))
        XCTAssertEqual(envelope.exitCode, .missingCapability)
        XCTAssertEqual(envelope.errors.first?.observed, .string(StubTemplatePack.packId))
        XCTAssertEqual(ProjectTestHarness.invoke(bare, "object list", ProjectTestHarness.request(dir, [:])).exitCode, .success, "object reads do not need the pack")
    }

    func testDescribeReturnsFullDescriptorEndpointsAndProvenance() throws {
        let envelope = invoke("control describe", ["key": "body.heightM", "object": "avatar:main"])
        XCTAssertEqual(envelope.exitCode, .success)
        let descriptor = try XCTUnwrap(envelope.result?["descriptor"])
        XCTAssertEqual(descriptor["key"], "body.heightM")
        XCTAssertEqual(descriptor["unit"], "metres")
        XCTAssertEqual(descriptor["dependencies"], ["body.headCount"])
        XCTAssertEqual(descriptor["description"], "Overall stature")
        XCTAssertEqual(envelope.result?["endpoints"]?["min"], 1.2)
        XCTAssertEqual(envelope.result?["endpoints"]?["max"], 2.0)
        XCTAssertEqual(envelope.result?["endpoints"]?["default"], 1.65)
        XCTAssertEqual(envelope.result?["endpoints"]?["current"], 1.65)
        XCTAssertEqual(envelope.result?["endpoints"]?["recommendedMax"], 1.9)
        XCTAssertEqual(envelope.result?["provenance"]?["templateId"], .string(StubTemplatePack.packId))
        let hair = invoke("control describe", ["key": "bangClearanceM", "object": "hair:bob"])
        XCTAssertEqual(hair.result?["descriptor"]?["unit"], "metres")
        XCTAssertEqual(hair.result?["endpoints"]?["current"], 0.005)
        XCTAssertEqual(hair.result?["provenance"]?["preset"], "bob-v1")
        XCTAssertEqual(invoke("control describe", ["key": "body.nope", "object": "avatar:main"]).errors.first?.code, .unknownField)
        XCTAssertEqual(invoke("control describe", ["key": "body.heightM", "object": "hair:bob"]).exitCode, .invalidRequest)
        XCTAssertEqual(invoke("control describe", ["key": "body.heightM"]).exitCode, .invalidRequest)
    }

    func testSetWritesCalibratedValuesAndInvalidatesAffectedKinds() throws {
        let envelope = set("avatar:main", ["body.heightM": 1.8, "face.eye.left.height": 0.25], requestId: "c1")
        XCTAssertEqual(envelope.exitCode, .success, "\(envelope.errors)")
        XCTAssertEqual(envelope.revisionAfter, 1)
        XCTAssertEqual(envelope.warnings, [])
        let plan = try XCTUnwrap(envelope.plan)
        XCTAssertEqual(plan.edits.map(\.pointer).prefix(2), ["/body/body.heightM", "/face/face.eye.left.height"])
        let invalidations = try XCTUnwrap(envelope.result?["invalidations"]?.array?.compactMap(\.string))
        XCTAssertEqual(invalidations.prefix(4), ["avatar:main/geometry", "avatar:main/rig", "avatar:main/morph", "avatar:main/fit"])
        XCTAssertTrue(invalidations.contains("garment:top/fit"))
        XCTAssertTrue(invalidations.contains("expression:blink/morph"))
        XCTAssertFalse(invalidations.contains("hair:bob/geometry"))
        XCTAssertEqual(invalidations.last, "qa")
        let state = try ProjectStore.open(at: dir).state()
        XCTAssertEqual(state.object(id: "avatar:main")?.fields["body"]?["body.heightM"], 1.8)
        XCTAssertEqual(state.object(id: "avatar:main")?.fields["face"]?["face.eye.left.height"], 0.25)
        XCTAssertEqual(state.recipe?["body"]?["body.heightM"], 1.8)
        XCTAssertEqual(state.recipe?["face"]?["face.eye.left.height"], 0.25)
        XCTAssertEqual(invoke("control describe", ["key": "body.heightM", "object": "avatar:main"]).result?["endpoints"]?["current"], 1.8)

        let hair = set("hair:bob", ["lengthM": 0.22])
        XCTAssertEqual(hair.status, .succeeded)
        XCTAssertEqual(hair.plan?.edits.first?.pointer, "/controls/lengthM")
        XCTAssertTrue(hair.result!["invalidations"]!.array!.contains("spring:hair/rig"))
        XCTAssertEqual(try ProjectStore.open(at: dir).state().recipe?["hair"]?[0]?["controls"]?["lengthM"], 0.22)
        let garment = set("garment:top", ["fit": -0.2, "length": 0.1])
        XCTAssertEqual(garment.status, .succeeded)
        XCTAssertEqual(try ProjectStore.open(at: dir).state().object(id: "garment:top")?.fields["controls"]?["fit"], -0.2)
    }

    func testSetRejectsOutOfRangeWithoutClampingAndUnknownKeys() throws {
        let high = set("avatar:main", ["body.heightM": 2.5])
        XCTAssertEqual(high.status, .failed)
        XCTAssertEqual(high.exitCode, .gateFailed)
        XCTAssertEqual(high.errors.first?.code, .validationFailed)
        XCTAssertEqual(high.errors.first?.objectId, "avatar:main")
        XCTAssertEqual(high.errors.first?.path, "/values/body.heightM")
        XCTAssertEqual(high.errors.first?.observed, 2.5)
        XCTAssertEqual(high.errors.first?.required, [1.2, 2.0])
        XCTAssertEqual(set("avatar:main", ["body.heightM": 1.7, "face.eye.left.height": -1.01]).errors.first?.code, .validationFailed)
        XCTAssertEqual(set("hair:bob", ["lengthM": 0.31]).errors.first?.code, .validationFailed)
        XCTAssertEqual(set("avatar:main", ["body.heightM": 2.0]).status, .succeeded, "validity endpoints are inclusive")
        let unknown = set("avatar:main", ["body.nope": 1])
        XCTAssertEqual(unknown.exitCode, .invalidRequest)
        XCTAssertEqual(unknown.errors.first?.code, .unknownField)
        XCTAssertEqual(unknown.errors.first?.required, ["body.heightM", "face.eye.left.height"])
        XCTAssertEqual(set("avatar:main", ["body.heightM": "tall"]).exitCode, .invalidRequest)
        XCTAssertEqual(set("avatar:main", ["face.eye.right.height": 0.1]).errors.first?.code, .unknownField, "mirror keys are not implicit controls")
        XCTAssertEqual(set("material:cloth", ["shadingToonyFactor": 0.5]).exitCode, .invalidRequest)
        XCTAssertEqual(set("avatar:main", [:]).exitCode, .invalidRequest)
        let state = try ProjectStore.open(at: dir).state()
        XCTAssertEqual(state.revision, 1)
        XCTAssertEqual(state.object(id: "avatar:main")?.fields["body"]?["body.heightM"], 2.0)
    }

    func testSetWarnsOutsideRecommendedRangeAndOnNoOp() throws {
        let warned = set("avatar:main", ["body.heightM": 1.95])
        XCTAssertEqual(warned.status, .succeeded)
        XCTAssertEqual(warned.warnings.map(\.code), ["OUTSIDE_RECOMMENDED_RANGE"])
        let noop = set("avatar:main", ["body.heightM": 1.95])
        XCTAssertEqual(noop.status, .succeeded)
        XCTAssertEqual(noop.result?["invalidations"], [])
        XCTAssertTrue(noop.warnings.contains { $0.code == "NO_OP" })
    }

    func testDryRunPlanMatchesAppliedEdit() throws {
        let dry = set("hair:bob", ["tipBendDeg": 20], requestId: "d1", dryRun: true)
        XCTAssertEqual(dry.status, .succeeded)
        XCTAssertEqual(dry.revisionAfter, 0)
        XCTAssertEqual(dry.plan?.edits.first?.before, 12)
        XCTAssertEqual(dry.plan?.edits.first?.after, 20)
        XCTAssertEqual(dry.plan?.invalidations, dry.result?["invalidations"]?.array?.compactMap(\.string))
        XCTAssertEqual(try ProjectStore.open(at: dir).state().revision, 0)
        let applied = set("hair:bob", ["tipBendDeg": 20], requestId: "d1")
        XCTAssertEqual(applied.revisionAfter, 1)
        XCTAssertEqual(applied.plan?.planHash, dry.plan?.planHash)
    }
}
