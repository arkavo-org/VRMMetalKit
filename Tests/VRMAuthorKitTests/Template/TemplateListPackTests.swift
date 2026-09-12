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

final class TemplateListPackTests: XCTestCase {
    private func context(templates: TemplateRegistry = .standard()) -> OperationContext {
        ProjectTestHarness.context(cwd: URL(fileURLWithPath: NSTemporaryDirectory()), templates: templates)
    }

    func testListsBuiltinPackWithHashAndControls() throws {
        let envelope = ProjectTestHarness.invoke(context(), "template list", [:])
        XCTAssertEqual(envelope.status, .succeeded, "\(envelope.errors)")
        let packs = try XCTUnwrap(envelope.result?["packs"]?.array)
        XCTAssertEqual(packs.map { $0["id"]?.string }, ["native-anime-v1"])
        XCTAssertEqual(packs[0]["sha256"]?.string?.count, 64)
        XCTAssertEqual(packs[0]["sha256"]?.string, NativeAnimeV1Pack().sha256)
        let controls = try XCTUnwrap(packs[0]["controls"]?.array)
        XCTAssertTrue(controls.contains { $0["key"] == "body.heightM" })
        XCTAssertEqual(packs[0]["controlSchema"]?.array?.count, controls.count)
    }

    func testListsWearablePresetsAsItemsWithCategoryFilter() throws {
        let all = ProjectTestHarness.invoke(context(), "template list", [:])
        let items = try XCTUnwrap(all.result?["items"]?.array)
        XCTAssertEqual(Set(items.compactMap { $0["id"]?.string }), ["bob-v1", "long-v1", "top-v1", "bottom-v1", "skirt-v1", "footwear-v1", "glasses-v1", "earring-v1", "cat-ears-v1"])
        XCTAssertTrue(items.allSatisfy { $0["sha256"]?.string?.count == 64 })
        let hair = ProjectTestHarness.invoke(context(), "template list", ["category": "hair"])
        XCTAssertEqual(hair.result?["packs"]?.array?.count, 0)
        XCTAssertEqual(hair.result?["items"]?.array?.map { $0["id"]?.string }, ["bob-v1", "long-v1"])
        let hairControls = try XCTUnwrap(hair.result?["items"]?.array?.first?["controls"]?.array)
        XCTAssertEqual(hairControls.compactMap { $0["key"]?.string }, ["lengthM", "widthScale", "tipBendDeg", "bangClearanceM"])
        let avatar = ProjectTestHarness.invoke(context(), "template list", ["category": "avatar"])
        XCTAssertEqual(avatar.result?["packs"]?.array?.count, 1)
        XCTAssertEqual(avatar.result?["items"]?.array?.count, 0)
    }

    func testRejectsUnknownCategoryAndUnknownField() {
        let bad = ProjectTestHarness.invoke(context(), "template list", ["category": "wig"])
        XCTAssertEqual(bad.exitCode, .invalidRequest)
        let unknown = ProjectTestHarness.invoke(context(), "template list", ["colour": "red"])
        XCTAssertEqual(unknown.exitCode, .invalidRequest)
        XCTAssertTrue(unknown.errors.contains { $0.code == .unknownField })
    }

    func testEmptyRegistryListsNothingAndDeterministicOrder() throws {
        let empty = ProjectTestHarness.invoke(context(templates: TemplateRegistry(packs: [])), "template list", [:])
        XCTAssertEqual(empty.status, .succeeded)
        XCTAssertEqual(empty.result?["packs"], [])
        XCTAssertEqual(empty.result?["items"], [])
        let a = ProjectTestHarness.invoke(context(), "template list", [:])
        let b = ProjectTestHarness.invoke(context(), "template list", [:])
        XCTAssertEqual(try a.canonicalData(), try b.canonicalData())
    }

    func testMissingHandlerIsAnExpectedFailureNotASkip() {
        let registry = ProjectTestHarness.registry(installing: [DiscoveryHandlers.install])
        let ctx = ProjectTestHarness.context(cwd: URL(fileURLWithPath: NSTemporaryDirectory()), registry: registry)
        let envelope = ProjectTestHarness.invoke(ctx, "template list", [:])
        XCTAssertEqual(envelope.exitCode, .missingCapability)
        XCTAssertEqual(envelope.errors.first?.code, .notImplemented)
    }
}
