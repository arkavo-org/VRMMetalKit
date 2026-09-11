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

/// verification.md QA-machinery row: each declared mutant class injected into
/// an otherwise passing export must produce `fail` and exit code 1.
final class QAMutantInjectionTests: XCTestCase {
    private var project: TestProject!

    override func setUpWithError() throws {
        project = try TestProject.make(registry: TestProject.registry(extra: [StubStyleLint.installer(verdict: "conforming")]))
        try project.applyDefaultRecipe()
    }

    override func tearDownWithError() throws { project.cleanup() }

    private func qaRun(_ data: Data, name: String) throws -> ResultEnvelope {
        let path = project.path(name)
        try data.write(to: URL(fileURLWithPath: path))
        return project.invoke("qa run", ["request": ["file": .string(path), "suite": "spec+style"], "out": .string(project.path("qa-\(name)"))])
    }

    private func failedCheckIds(_ envelope: ResultEnvelope) -> [String] {
        envelope.result?["checks"]?.array?.filter { $0["status"] == "fail" }.compactMap { $0["id"]?.string } ?? []
    }

    func testBaselineExportPasses() throws {
        let envelope = try qaRun(try GLBWriter.write(TestAvatarFactory.make()).data, name: "baseline.vrm")
        XCTAssertEqual(envelope.exitCode, .success, "\(envelope.errors)")
        XCTAssertEqual(envelope.result?["verdict"], "pass")
    }

    func testIdentityTransformMutantIsFlaggedNoOpEdit() throws {
        let inert = try TestProject.make(pack: StubTemplatePack(ignoresControls: true), registry: TestProject.registry(extra: [StubStyleLint.installer(verdict: "conforming")]))
        defer { inert.cleanup() }
        try inert.applyDefaultRecipe()
        XCTAssertEqual(inert.invoke("build", ["out": .string(inert.path("b1.vrm"))]).exitCode, .success)
        try inert.applyDefaultRecipe(requestId: "apply-2") { $0.body = ["body.heightM": 1.75] }
        let second = inert.invoke("build", ["out": .string(inert.path("b2.vrm"))])
        XCTAssertEqual(second.exitCode, .success, "\(second.errors)")
        let envelope = inert.invoke("qa run", ["request": ["file": .string(inert.path("b2.vrm")), "suite": "spec+style"], "out": .string(inert.path("qa"))])
        XCTAssertEqual(envelope.exitCode, .gateFailed)
        XCTAssertEqual(envelope.result?["verdict"], "fail")
        XCTAssertEqual(failedCheckIds(envelope), ["spec.identityEdit"])
        XCTAssertEqual(envelope.errors.first?.code, .noOpEdit)

        XCTAssertEqual(project.invoke("build", ["out": .string(project.path("b1.vrm"))]).exitCode, .success)
        try project.applyDefaultRecipe(requestId: "apply-2") { $0.body = ["body.heightM": 1.75] }
        XCTAssertEqual(project.invoke("build", ["out": .string(project.path("b2.vrm"))]).exitCode, .success)
        let real = project.invoke("qa run", ["request": ["file": .string(project.path("b2.vrm")), "suite": "spec+style"], "out": .string(project.path("qa"))])
        XCTAssertEqual(real.exitCode, .success, "\(real.errors)")
        XCTAssertEqual(real.result?["checks"]?.array?.first { $0["id"] == "spec.identityEdit" }?["status"], "pass")

        let baseline = try VRMReader.read(fileAt: URL(fileURLWithPath: project.path("b1.vrm")))
        XCTAssertEqual(GeometryChecks.noOpEdit(baseline: baseline, candidate: baseline, geometryInputsChanged: false).status, .pass)
        XCTAssertEqual(GeometryChecks.noOpEdit(baseline: baseline, candidate: baseline, geometryInputsChanged: true).code, "NO_OP_EDIT")
    }

    func testWrongUnitsMutantFailsScale() throws {
        let centimetres = try GLBWriter.write(TestAvatarFactory.make(height: 160)).data
        let envelope = try qaRun(centimetres, name: "cm.vrm")
        XCTAssertEqual(envelope.exitCode, .gateFailed)
        XCTAssertEqual(envelope.result?["verdict"], "fail")
        XCTAssertEqual(failedCheckIds(envelope), ["spec.scale"])
        XCTAssertEqual(envelope.errors.first?.code.rawValue, "SCALE_INVALID")
        let tiny = SpecValidator.validate(data: try GLBWriter.write(TestAvatarFactory.make(height: 0.2)).data)
        XCTAssertEqual(tiny.first { $0.id == "spec.scale" }?.status, .fail)
    }

    func testDiscardedMorphsMutantFailsExpressionBinds() throws {
        var avatar = TestAvatarFactory.make()
        avatar.expressions[0].morphTargetBinds[0].target = "smile"
        XCTAssertThrowsError(try GLBWriter.write(avatar))

        var glb = try GLBFile.parse(try GLBWriter.write(TestAvatarFactory.make()).data)
        var json = glb.json.object!
        var mesh = json["meshes"]![0]!.object!
        mesh["primitives"] = .array(mesh["primitives"]!.array!.map { primitive in
            var p = primitive.object!
            p["targets"] = nil
            return .object(p)
        })
        mesh["extras"] = nil
        json["meshes"] = [.object(mesh)]
        glb.json = .object(json)
        let envelope = try qaRun(try glb.serialize(), name: "nomorphs.vrm")
        XCTAssertEqual(envelope.exitCode, .gateFailed)
        XCTAssertEqual(envelope.result?["verdict"], "fail")
        XCTAssertEqual(Set(failedCheckIds(envelope)), ["spec.expressions.binds", "expression.blinkInert"])
    }

    func testBrokenEyelidsMutantFailsBlinkInert() throws {
        let envelope = try qaRun(try GLBWriter.write(TestAvatarFactory.make(blinkDelta: 0)).data, name: "inert.vrm")
        XCTAssertEqual(envelope.exitCode, .gateFailed)
        XCTAssertEqual(envelope.result?["verdict"], "fail")
        XCTAssertEqual(failedCheckIds(envelope), ["expression.blinkInert"])
        XCTAssertEqual(envelope.errors.first?.code.rawValue, "EXPRESSION_INERT")

        let inert = try TestProject.make(pack: StubTemplatePack(blinkDelta: 0), registry: TestProject.registry(extra: [StubStyleLint.installer(verdict: "conforming")]))
        defer { inert.cleanup() }
        try inert.applyDefaultRecipe()
        XCTAssertEqual(inert.invoke("build", ["out": .string(inert.path("draft.vrm"))]).exitCode, .success)
        let built = inert.invoke("qa run", ["request": ["file": .string(inert.path("draft.vrm")), "suite": "spec+style"], "out": .string(inert.path("qa"))])
        XCTAssertEqual(built.exitCode, .gateFailed)
    }

    func testFabricatedReportFailsInspectionVerify() throws {
        XCTAssertEqual(project.invoke("build", ["out": .string(project.path("draft.vrm"))]).exitCode, .success)
        let honest = project.invoke("qa run", ["request": ["file": .string(project.path("draft.vrm")), "suite": "authoring-v1"], "out": .string(project.path("qa"))])
        XCTAssertEqual(honest.status, .incomplete)
        var report = try QAReport.load(URL(fileURLWithPath: project.path("qa/findings.json")))
        report.verdict = .pass
        report.file.sha256 = String(repeating: "f", count: 64)
        report.checks = report.checks.map { check in
            var c = check
            c.status = .pass
            return c
        }
        report.scenarios = report.scenarios.map { scenario in
            var s = scenario
            s.status = .pass
            return s
        }
        report.requiredArtifacts = report.requiredArtifacts.map { QARequiredArtifact(scenarioId: $0.scenarioId, path: nil, sha256: String(repeating: "f", count: 64), mediaType: "image/png") }
        let fabricated = project.path("fabricated.json")
        try CanonicalJSON.data(try JSONValue.from(report)).write(to: URL(fileURLWithPath: fabricated))
        let envelope = project.invoke("inspection verify", ["report": .string(fabricated)])
        XCTAssertEqual(envelope.exitCode, .gateFailed)
        XCTAssertEqual(envelope.result?["verdict"], "fail")
        XCTAssertEqual(envelope.errors.first?.code, .reportBindingMismatch)

        var claimed = try QAReport.load(URL(fileURLWithPath: project.path("qa/findings.json")))
        claimed.verdict = .pass
        try CanonicalJSON.data(try JSONValue.from(claimed)).write(to: URL(fileURLWithPath: project.path("claimed.json")))
        let inconsistent = project.invoke("inspection verify", ["report": .string(project.path("claimed.json"))])
        XCTAssertEqual(inconsistent.exitCode, .gateFailed)
        XCTAssertTrue(inconsistent.errors.first?.message.contains("claims pass") ?? false)
    }
}
