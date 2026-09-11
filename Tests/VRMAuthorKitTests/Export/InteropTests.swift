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
import Metal
import VRMMetalKit
import XCTest
@testable import VRMAuthorKit

/// The independent consumer for the authoring-v1 `vrmmetalkit` pin: loads the
/// exported bytes with VRMMetalKit's loader.
struct VRMMetalKitConsumer: ConsumerImporter {
    var id: String { QAPins.consumerVRMMetalKit }
    var version: String { "in-tree" }

    func importVRM(_ data: Data) throws -> ConsumerImportReport {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.set(.success(try await VRMModel.load(from: data, filePath: "export.vrm", device: nil))) } catch { box.set(.failure(error)) }
            semaphore.signal()
        }
        semaphore.wait()
        let model = try box.take().get()
        return VRMMetalKitConsumer.report(model, version: version)
    }

    static func report(_ model: VRMModel, version: String) -> ConsumerImportReport {
        ConsumerImportReport(consumer: QAPins.consumerVRMMetalKit, version: version,
                             humanoidBones: model.humanoid?.humanBones.count ?? 0,
                             expressions: (model.expressions?.preset.count ?? 0) + (model.expressions?.custom.count ?? 0),
                             springs: model.springBone?.springs.count ?? 0, colliders: model.springBone?.colliders.count ?? 0,
                             colliderGroups: model.springBone?.colliderGroups.count ?? 0, meshes: model.meshes.count, materials: model.materials.count)
    }

    private final class ResultBox: @unchecked Sendable {
        private var result: Result<VRMModel, Error>?
        private let lock = NSLock()
        func set(_ value: Result<VRMModel, Error>) { lock.lock(); result = value; lock.unlock() }
        func take() -> Result<VRMModel, Error> { lock.lock(); defer { lock.unlock() }; return result ?? .failure(AuthorError(code: .internalError, message: "no result")) }
    }
}

final class InteropTests: XCTestCase {
    func testVRMMetalKitLoadsExportedFactoryAvatar() async throws {
        let avatar = TestAvatarFactory.make()
        let export = try GLBWriter.write(avatar)
        let model: VRMModel
        do {
            model = try await VRMModel.load(from: export.data, filePath: "factory.vrm", device: nil)
        } catch {
            guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("VRMMetalKit needs a Metal device here and none is available: \(error)") }
            model = try await VRMModel.load(from: export.data, filePath: "factory.vrm", device: device)
        }
        XCTAssertFalse(model.isVRM0)
        XCTAssertEqual(model.humanoid?.humanBones.count, avatar.humanoid.count)
        XCTAssertEqual(model.humanoid?.getBoneNode(.head), export.idMap.nodes["node:head"])
        XCTAssertNoThrow(try model.humanoid?.validate())
        XCTAssertEqual(model.expressions?.preset.count, avatar.expressions.filter { $0.preset != nil }.count)
        XCTAssertEqual(model.expressions?.custom.count, avatar.expressions.filter { $0.name != nil }.count)
        XCTAssertEqual(model.springBone?.springs.count, avatar.springs.count)
        XCTAssertEqual(model.springBone?.colliders.count, avatar.colliders.count)
        XCTAssertEqual(model.springBone?.colliderGroups.count, avatar.colliderGroups.count)
        XCTAssertEqual(model.springBone?.springs.first?.joints.count, avatar.springs[0].joints.count)
        XCTAssertEqual(model.meshes.count, avatar.meshes.count)
        XCTAssertEqual(model.materials.count, avatar.materials.count)
        XCTAssertEqual(model.meta.name, avatar.meta.name)
        let report = VRMMetalKitConsumer.report(model, version: "in-tree")
        XCTAssertEqual(report.humanoidBones, 17)
        XCTAssertEqual(report.expressions, 4)
    }

    func testVRMMetalKitConsumerSatisfiesAuthoringPinInQARun() throws {
        guard MTLCreateSystemDefaultDevice() != nil || ProcessInfo.processInfo.environment["CI"] == nil else { throw XCTSkip("No Metal device on CI") }
        let project = try TestProject.make(registry: TestProject.registry(consumer: VRMMetalKitConsumer()))
        defer { project.cleanup() }
        try project.applyDefaultRecipe()
        let build = project.invoke("build", ["out": .string(project.path("draft.vrm"))])
        XCTAssertEqual(build.exitCode, .success)
        let run = project.invoke("qa run", ["request": ["file": .string(project.path("draft.vrm")), "suite": "authoring-v1"], "out": .string(project.path("qa"))])
        XCTAssertEqual(run.status, .incomplete)
        let consumer = run.result?["checks"]?.array?.first { $0["id"] == "consumer.vrmmetalkit.import" }
        XCTAssertEqual(consumer?["status"], "pass", "\(String(describing: consumer))")
        let report = try QAReport.load(URL(fileURLWithPath: project.path("qa/findings.json")))
        XCTAssertEqual(report.consumers.first?.consumer, "vrmmetalkit")
        XCTAssertEqual(report.consumers.first?.humanoidBones, 17)
    }
}
