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

final class ConsumerImportTests: XCTestCase {
    private var project: TestProject!

    override func tearDownWithError() throws { project?.cleanup() }

    private func requireRealConsumer() throws -> (VRMMetalKitSubprocessConsumer, [String: String]) {
        guard let binary = RenderPackTests.rendererBinary else { throw XCTSkip("vrm-author-render is not built next to the test bundle; run `swift build --product vrm-author-render`.") }
        let env = [VRMAuthorRenderLocator.environmentKey: binary.path]
        return (VRMMetalKitSubprocessConsumer(executableURL: nil, environment: env), env)
    }

    private func makeProject(consumer: any ConsumerImporter, env: [String: String] = [:]) throws -> TestProject {
        let project = try TestProject.make(registry: TestProject.registry(consumer: consumer, extra: [StubStyleLint.installer(verdict: "conforming")]), env: env)
        try project.applyDefaultRecipe()
        XCTAssertEqual(project.invoke("build", ["out": .string(project.path("draft.vrm"))]).exitCode, .success)
        return project
    }

    private func consumerCheck(_ project: TestProject, file: String) throws -> (ResultEnvelope, QACheck?) {
        let envelope = project.invoke("qa run", ["request": ["file": .string(project.path(file)), "suite": "authoring-v1"], "out": .string(project.path("qa-\(file)"))])
        let report = try QAReport.load(URL(fileURLWithPath: project.path("qa-\(file)/findings.json")))
        return (envelope, report.checks.first { $0.id == "consumer.vrmmetalkit.import" })
    }

    /// Swaps the VRMC_vrm extension name for a same-length string so the GLB
    /// stays well-formed but VRMMetalKit rejects it as a non-VRM file.
    private static func stripVRMExtension(_ data: Data) throws -> Data {
        let marker = Data("VRMC_vrm".utf8)
        var corrupted = data
        var replaced = false
        while let range = corrupted.range(of: marker) {
            corrupted.replaceSubrange(range, with: Data("VRMC_xxx".utf8))
            replaced = true
        }
        guard replaced else { throw AuthorError(code: .internalError, message: "Export carries no VRMC_vrm marker.") }
        return corrupted
    }

    // MARK: (a) absent binary

    func testAbsentBinaryThrowsMissingCapability() throws {
        let consumer = VRMMetalKitSubprocessConsumer(executableURL: nil, environment: [:])
        XCTAssertEqual(consumer.id, QAPins.consumerVRMMetalKit)
        XCTAssertEqual(consumer.version, VRMMetalKitSubprocessConsumer.unavailableVersion)
        XCTAssertNil(consumer.binary())
        let export = try GLBWriter.write(TestAvatarFactory.make())
        XCTAssertThrowsError(try consumer.importVRM(export.data)) { error in
            XCTAssertEqual((error as? AuthorError)?.code, .missingCapability, "\(error)")
        }
    }

    func testAbsentBinaryLeavesConsumerPinIncompleteNotPass() throws {
        project = try makeProject(consumer: VRMMetalKitSubprocessConsumer(executableURL: nil, environment: [:]))
        let (envelope, check) = try consumerCheck(project, file: "draft.vrm")
        XCTAssertEqual(envelope.status, .incomplete)
        XCTAssertEqual(check?.status, .incomplete, "\(String(describing: check))")
        XCTAssertEqual(check?.code, AuthorErrorCode.missingCapability.rawValue)
        let report = try QAReport.load(URL(fileURLWithPath: project.path("qa-draft.vrm/findings.json")))
        XCTAssertEqual(report.consumers, [])
    }

    // MARK: (b) built binary

    func testBuiltBinaryRoundTripsFactoryAvatar() throws {
        let (consumer, _) = try requireRealConsumer()
        XCTAssertNotNil(consumer.binary())
        XCTAssertNotEqual(consumer.version, VRMMetalKitSubprocessConsumer.unavailableVersion)
        let avatar = TestAvatarFactory.make()
        let export = try GLBWriter.write(avatar)
        let report = try consumer.importVRM(export.data)
        XCTAssertEqual(report.consumer, "vrmmetalkit")
        XCTAssertEqual(report.version, consumer.version)
        XCTAssertEqual(report.humanoidBones, 17)
        XCTAssertEqual(report.humanoidBones, avatar.humanoid.count)
        XCTAssertEqual(report.expressions, 4)
        XCTAssertEqual(report.springs, avatar.springs.count)
        XCTAssertEqual(report.colliders, avatar.colliders.count)
        XCTAssertEqual(report.colliderGroups, avatar.colliderGroups.count)
        XCTAssertEqual(report.meshes, avatar.meshes.count)
        XCTAssertEqual(report.materials, avatar.materials.count)
        XCTAssertEqual(report.warnings, [])
    }

    func testBuiltBinarySatisfiesConsumerPinInQARun() throws {
        let (consumer, env) = try requireRealConsumer()
        project = try makeProject(consumer: consumer, env: env)
        let (_, check) = try consumerCheck(project, file: "draft.vrm")
        XCTAssertEqual(check?.status, .pass, "\(String(describing: check))")
        XCTAssertNil(check?.code)
        let report = try QAReport.load(URL(fileURLWithPath: project.path("qa-draft.vrm/findings.json")))
        XCTAssertEqual(report.consumers.count, 1)
        XCTAssertEqual(report.consumers.first?.consumer, "vrmmetalkit")
        XCTAssertEqual(report.consumers.first?.humanoidBones, 17)
        XCTAssertEqual(report.consumers.first?.version, consumer.version)
    }

    func testContextEnvironmentLocatesBinaryWhenInitDoesNot() throws {
        let (_, env) = try requireRealConsumer()
        project = try makeProject(consumer: VRMMetalKitSubprocessConsumer(executableURL: nil, environment: [:]), env: env)
        let (_, check) = try consumerCheck(project, file: "draft.vrm")
        XCTAssertEqual(check?.status, .pass, "\(String(describing: check))")
    }

    // MARK: (c) corrupted file

    func testCorruptedFileIsRejectedNotPassed() throws {
        let (consumer, env) = try requireRealConsumer()
        let export = try GLBWriter.write(TestAvatarFactory.make())
        let corrupted = try ConsumerImportTests.stripVRMExtension(export.data)
        XCTAssertThrowsError(try consumer.importVRM(corrupted)) { error in
            XCTAssertNotEqual((error as? AuthorError)?.code, .missingCapability, "\(error)")
            XCTAssertTrue("\(error)".contains("VRMMetalKit"), "\(error)")
        }
        XCTAssertThrowsError(try consumer.importVRM(Data("garbage".utf8)))

        project = try makeProject(consumer: consumer, env: env)
        let draft = try Data(contentsOf: URL(fileURLWithPath: project.path("draft.vrm")))
        try ConsumerImportTests.stripVRMExtension(draft).write(to: URL(fileURLWithPath: project.path("broken.vrm")))
        let (envelope, check) = try consumerCheck(project, file: "broken.vrm")
        XCTAssertEqual(envelope.status, .failed)
        XCTAssertEqual(check?.status, .fail, "\(String(describing: check))")
        XCTAssertEqual(check?.code, "CONSUMER_REJECTED")
        let report = try QAReport.load(URL(fileURLWithPath: project.path("qa-broken.vrm/findings.json")))
        XCTAssertEqual(report.verdict, .fail)
        XCTAssertEqual(report.consumers, [])
    }

    // MARK: report parsing

    func testReportParsingRejectsWrongConsumerAndSurfacesErrors() throws {
        let binary = FileManager.default.temporaryDirectory.appendingPathComponent("false")
        XCTAssertThrowsError(try VRMMetalKitSubprocessConsumer.report(from: ["error": "boom"], binary: binary)) { error in
            XCTAssertEqual((error as? AuthorError)?.message, "boom")
        }
        XCTAssertThrowsError(try VRMMetalKitSubprocessConsumer.report(from: ["consumer": "other", "humanoidBones": 1], binary: binary))
        XCTAssertThrowsError(try VRMMetalKitSubprocessConsumer.report(from: ["consumer": "vrmmetalkit", "humanoidBones": 1], binary: binary))
        let parsed = try VRMMetalKitSubprocessConsumer.report(from: [
            "consumer": "vrmmetalkit", "version": "9.9.9", "humanoidBones": 17, "expressions": 4, "springs": 1, "colliders": 1, "colliderGroups": 1,
            "meshes": 1, "materials": 2, "images": 0, "requiredBonesPresent": false, "warnings": [],
        ], binary: binary)
        XCTAssertEqual(parsed.version, "9.9.9")
        XCTAssertEqual(parsed.materials, 2)
        XCTAssertEqual(parsed.warnings.count, 1)
    }
}
