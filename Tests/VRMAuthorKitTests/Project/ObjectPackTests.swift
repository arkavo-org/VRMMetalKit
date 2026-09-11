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

/// Acceptance pack for object list/get/set.
final class ObjectPackTests: XCTestCase {
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

    private func set(_ id: String, _ values: [String: JSONValue], requestId: String = UUID().uuidString) -> ResultEnvelope {
        invoke("object set", ["requestId": .string(requestId), "edit": ["id": .string(id), "values": .object(values)]])
    }

    func testListReturnsSummariesSortedWithKindFilter() throws {
        let all = invoke("object list")
        XCTAssertEqual(all.exitCode, .success)
        let objects = try XCTUnwrap(all.result?["objects"]?.array)
        XCTAssertEqual(objects.count, 12)
        let ids = objects.compactMap { $0["id"]?.string }
        XCTAssertEqual(ids, ids.sorted { CompiledAvatar.precedes($0, $1) })
        for o in objects {
            XCTAssertNotNil(ObjectKind(rawValue: o["kind"]?.string ?? ""))
            XCTAssertEqual(o["revision"], 0)
            XCTAssertNotNil(o["writablePointers"]?.array)
        }
        let materials = invoke("object list", ["kind": "material"])
        XCTAssertEqual(materials.result?["objects"]?.array?.compactMap { $0["id"]?.string }, ["material:cloth", "material:hair"])
        XCTAssertEqual(materials.result?["objects"]?[0]?["writablePointers"], ["/role", "/gltf", "/mtoon"])
        XCTAssertEqual(invoke("object list", ["kind": "mesh"]).result?["objects"], [])
        XCTAssertEqual(invoke("object list", ["kind": "wig"]).exitCode, .invalidRequest)
    }

    func testGetReturnsTypedObjectProvenanceAndWritablePointers() throws {
        let hair = invoke("object get", ["id": "hair:bob"])
        XCTAssertEqual(hair.exitCode, .success)
        XCTAssertEqual(hair.result?["object"]?["id"], "hair:bob")
        XCTAssertEqual(hair.result?["object"]?["kind"], "hair")
        XCTAssertEqual(hair.result?["object"]?["preset"], "bob-v1")
        XCTAssertEqual(hair.result?["object"]?["controls"]?["lengthM"], 0.18)
        XCTAssertEqual(hair.result?["provenance"]?["source"], "template")
        XCTAssertEqual(hair.result?["provenance"]?["preset"], "bob-v1")
        XCTAssertEqual(hair.result?["writablePointers"], ["/controls", "/texture"])
        let spring = invoke("object get", ["id": "spring:hair"])
        let pointers = try XCTUnwrap(spring.result?["writablePointers"]?.array?.compactMap(\.string))
        XCTAssertTrue(pointers.contains("/joints/1/hitRadius"))
        XCTAssertFalse(pointers.contains("/joints/1/node"))
        XCTAssertFalse(pointers.contains("/joints"))
        let avatar = invoke("object get", ["id": "avatar:main"])
        XCTAssertEqual(avatar.result?["object"]?["rights"]?["declarant"], "tester")
        XCTAssertEqual(avatar.result?["writablePointers"], ["/name", "/body", "/face"])
        let missing = invoke("object get", ["id": "hair:nope"])
        XCTAssertEqual(missing.exitCode, .invalidRequest)
        XCTAssertEqual(missing.errors.first?.code, .objectNotFound)
    }

    func testSetWritesWritablePointersAtomicallyAndReportsInvalidations() throws {
        let envelope = set("hair:bob", ["/controls/lengthM": 0.25, "/texture/tipColour/rgba": [1, 0, 0, 1]], requestId: "hair-1")
        XCTAssertEqual(envelope.exitCode, .success, "\(envelope.errors)")
        XCTAssertEqual(envelope.revisionBefore, 0)
        XCTAssertEqual(envelope.revisionAfter, 1)
        let plan = try XCTUnwrap(envelope.plan)
        XCTAssertEqual(plan.edits.map(\.pointer).prefix(2), ["/controls/lengthM", "/texture/tipColour/rgba"])
        XCTAssertEqual(plan.edits[0].before, 0.18)
        XCTAssertEqual(plan.edits[0].after, 0.25)
        XCTAssertEqual(envelope.result?["invalidations"], ["hair:bob/geometry", "hair:bob/rig", "hair:bob/texture", "qa"])
        XCTAssertEqual(envelope.result?["plan"]?["planHash"], .string(plan.planHash))
        let state = try ProjectStore.open(at: dir).state()
        let hair = try XCTUnwrap(state.object(id: "hair:bob"))
        XCTAssertEqual(hair.revision, 1)
        XCTAssertEqual(hair.fields["controls"]?["lengthM"], 0.25)
        XCTAssertEqual(hair.fields["texture"]?["tipColour"]?["rgba"], [1, 0, 0, 1])
        XCTAssertEqual(state.recipe?["hair"]?[0]?["controls"]?["lengthM"], 0.25, "recipe stays in sync with objects")
        XCTAssertEqual(state.object(id: "material:cloth")?.revision, 0)
        let got = invoke("object get", ["id": "hair:bob"])
        XCTAssertEqual(got.result?["object"]?["revision"], 1)
    }

    func testSetCannotTouchIdsHistoryCredentialsOrDerivedFields() throws {
        for (id, pointer, value) in [("hair:bob", "/id", JSONValue.string("hair:other")), ("hair:bob", "/revision", 9), ("hair:bob", "/provenance/source", "me"),
                                     ("hair:bob", "/preset", "bob-v2"), ("hair:bob", "/writablePointers/0", "/x"), ("avatar:main", "/rights/authors/0", "impostor"),
                                     ("avatar:main", "/style/sha256", .string(String(repeating: "a", count: 64))), ("avatar:main", "/template/id", "other"),
                                     ("spring:hair", "/joints/0/node", "node:x"), ("spring:hair", "/joints/-", ["node": "node:new"]), ("lookat:main", "/type", "expression")] {
            let envelope = set(id, [pointer: value])
            XCTAssertEqual(envelope.status, .failed, "\(id) \(pointer)")
            XCTAssertEqual(envelope.exitCode, .invalidRequest, "\(id) \(pointer)")
            XCTAssertEqual(envelope.errors.first?.objectId, id, pointer)
        }
        XCTAssertEqual(try ProjectStore.open(at: dir).state().revision, 0)
    }

    func testSetValidatesWholeObjectThroughItsModelType() throws {
        XCTAssertEqual(set("hair:bob", ["/controls/lengthM": 0.5]).errors.first?.path, "/controls/lengthM")
        XCTAssertEqual(set("hair:bob", ["/controls/bogus": 1]).errors.first?.code, .unknownField)
        XCTAssertEqual(set("hair:bob", ["/texture/tipColour/rgba": [1, 0, 0]]).exitCode, .invalidRequest)
        XCTAssertEqual(set("garment:top", ["/layer": 9]).exitCode, .invalidRequest)
        XCTAssertEqual(set("garment:top", ["/materialIds": ["material:missing"]]).errors.first?.code, .objectNotFound)
        XCTAssertEqual(set("garment:top", ["/materialIds": ["hair:bob"]]).errors.first?.code, .objectNotFound)
        XCTAssertEqual(set("spring:hair", ["/joints/1/dragForce": 1.5]).exitCode, .invalidRequest)
        XCTAssertEqual(set("spring:hair", ["/colliderGroups": ["group:none"]]).errors.first?.code, .objectNotFound)
        XCTAssertEqual(set("collider:head", ["/shape": ["sphere": ["radius": -1]]]).exitCode, .invalidRequest)
        XCTAssertEqual(set("collider:head", ["/shape": ["sphere": ["radius": 0.1], "capsule": ["radius": 0.1, "tail": [0, 1, 0]]]]).exitCode, .invalidRequest)
        XCTAssertEqual(set("expression:blink", ["/preset": "wink"]).exitCode, .invalidRequest)
        XCTAssertEqual(set("expression:blink", ["/name": "custom"]).exitCode, .invalidRequest, "preset and name are exclusive")
        XCTAssertEqual(set("avatar:main", ["/body/body.heightM": 3]).errors.first?.code, .validationFailed, "avatar body values obey control descriptors")
        XCTAssertEqual(set("avatar:main", ["/body/body.unknown": 1]).errors.first?.code, .unknownField)
        XCTAssertEqual(try ProjectStore.open(at: dir).state().revision, 0)

        XCTAssertEqual(set("spring:hair", ["/joints/1/dragForce": 0.9, "/joints/0/stiffness": 4]).status, .succeeded)
        XCTAssertEqual(set("collider:head", ["/shape": ["capsule": ["radius": 0.05, "tail": [0, 0.1, 0]]]]).status, .succeeded)
        XCTAssertEqual(set("expression:blink", ["/isBinary": false, "/overrideMouth": "block"]).status, .succeeded)
        XCTAssertEqual(set("material:cloth", ["/mtoon/shadingToonyFactor": 0.5, "/role": "accessory"]).status, .succeeded)
        XCTAssertEqual(set("lookat:main", ["/rangeMapHorizontalInner/outputScale": 12]).status, .succeeded)
        XCTAssertEqual(set("avatar:main", ["/name": "Renamed", "/body/body.heightM": 1.8]).status, .succeeded)
        XCTAssertEqual(set("layer:blush", ["/enabled": false, "/opacity": 0.5]).status, .succeeded)
        let state = try ProjectStore.open(at: dir).state()
        XCTAssertEqual(state.revision, 7)
        XCTAssertEqual(state.recipe?["name"], "Renamed")
        XCTAssertEqual(state.recipe?["textures"]?.array?.map { $0["id"] }, ["layer:skin", "layer:blush"], "layer order is preserved")
        XCTAssertEqual(state.recipe?["textures"]?[1]?["enabled"], false)
        XCTAssertEqual(state.recipe?["colliders"]?[0]?["shape"]?["capsule"]?["radius"], 0.05)
        _ = try ProjectObjects.currentRecipe(state)
    }

    func testSetRequiresNonEmptyValuesAndValidPointers() throws {
        XCTAssertEqual(set("hair:bob", [:]).exitCode, .invalidRequest)
        XCTAssertEqual(set("hair:bob", ["controls/lengthM": 0.2]).exitCode, .invalidRequest)
        XCTAssertEqual(set("hair:nope", ["/controls/lengthM": 0.2]).errors.first?.code, .objectNotFound)
        XCTAssertEqual(invoke("object set", ["edit": ["id": "hair:bob"]]).exitCode, .invalidRequest)
        XCTAssertEqual(invoke("object set", ["edit": ["id": "hair:bob", "values": ["/controls/lengthM": 0.2], "extra": 1]]).errors.first?.code, .unknownField)
    }

    func testNoOpEditRecordsRevisionWithoutInvalidations() throws {
        let envelope = set("hair:bob", ["/controls/lengthM": 0.18])
        XCTAssertEqual(envelope.status, .succeeded)
        XCTAssertEqual(envelope.result?["invalidations"], [])
        XCTAssertEqual(envelope.revisionAfter, 1)
    }
}
