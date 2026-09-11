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

/// Writes one deterministic PNG-shaped artifact per scenario.
struct StubRenderer: RenderAdapter {
    var identity: String { "stub-renderer/1" }
    var scenarios: Set<String>? = nil

    func render(scenario: RenderScenario, file: URL, data: Data, outputDirectory: URL, context: OperationContext) throws -> [ArtifactRef]? {
        if let scenarios, !scenarios.contains(scenario.id) { return nil }
        var bytes = TestAvatarFactory.png2x2
        bytes.append(Data(scenario.id.utf8))
        bytes.append(Data(SHA256Hex.hex(data).utf8))
        let url = outputDirectory.appendingPathComponent("\(scenario.id).png")
        try ProjectStore.atomicWrite(bytes, to: url)
        return [ArtifactRef(path: url.path, sha256: SHA256Hex.hex(bytes), mediaType: "image/png", sizeBytes: bytes.count, role: "render")]
    }
}

/// Re-parses like the kit but carries the pinned consumer id.
struct StubVRMMetalKitConsumer: ConsumerImporter {
    var id: String { QAPins.consumerVRMMetalKit }
    var version: String { "stub" }
    func importVRM(_ data: Data) throws -> ConsumerImportReport {
        var report = try SelfReimportConsumer().importVRM(data)
        report.consumer = id
        return report
    }
}

enum StubStyleLint {
    static func installer(verdict: String) -> RegistryInstaller {
        { registry in
            registry.mustInstall({ _, request in
                let result: JSONValue = ["report": ["asset": request["file"] ?? .null, "verdict": .string(verdict)], "verdict": .string(verdict)]
                return .succeeded(requestId: request["requestId"]?.string, result: result)
            }, for: "style lint")
        }
    }
}

final class QAPackTests: XCTestCase {
    private var project: TestProject!

    override func setUpWithError() throws {
        project = try TestProject.make()
        try project.applyDefaultRecipe()
        XCTAssertEqual(project.invoke("build", ["out": .string(project.path("draft.vrm"))]).exitCode, .success)
    }

    override func tearDownWithError() throws { project.cleanup() }

    private func assertResultSchema(_ envelope: ResultEnvelope, _ name: String, in registry: Registry? = nil, file: StaticString = #filePath, line: UInt = #line) {
        guard let result = envelope.result, let op = (registry ?? project.registry).operation(named: name) else { XCTFail("no result for \(name)", file: file, line: line); return }
        let violations = op.resultSchema.validate(result)
        XCTAssertTrue(violations.isEmpty, "\(name) result violates its schema: \(violations.map(\.message))", file: file, line: line)
    }

    private func draft() throws -> Data { try Data(contentsOf: URL(fileURLWithPath: project.path("draft.vrm"))) }

    // MARK: qa plan

    func testQAPlanBindsFileRevisionProfileThresholdsScenariosAndConsumers() throws {
        let out = project.path("plan.json")
        let envelope = project.invoke("qa plan", ["suite": "authoring-v1", "file": .string(project.path("draft.vrm")), "out": .string(out)])
        XCTAssertEqual(envelope.exitCode, .success, "\(envelope.errors)")
        assertResultSchema(envelope, "qa plan")
        let plan = try QAPlan.load(URL(fileURLWithPath: out))
        XCTAssertEqual(plan.file.sha256, SHA256Hex.hex(try draft()))
        XCTAssertEqual(plan.revision, 1)
        XCTAssertEqual(plan.buildHash, try project.store.state().object(id: "avatar:main")?.fields["buildHash"]?.string)
        XCTAssertEqual(plan.profile.sha256, QAPins.defaultProfileSha256)
        XCTAssertEqual(plan.styleLinterSha256, QAPins.styleLinterSha256)
        XCTAssertEqual(plan.thresholdsHash, try CanonicalJSON.sha256(QAPins.thresholds))
        XCTAssertEqual(plan.requiredScenarios, ["spec.structure", "spec.humanoid", "spec.expressions", "spec.springs", "style.lint",
                                                "visual.front", "visual.threeQuarter", "visual.profile", "expression.blink", "expression.aa", "expression.happy", "motion.idle"])
        XCTAssertEqual(plan.consumers, ["vrmmetalkit"])
        XCTAssertEqual(plan.renderScenarios.map(\.id), ["visual.front", "visual.threeQuarter", "visual.profile", "expression.blink", "expression.aa", "expression.happy", "motion.idle"])
        XCTAssertEqual(plan.renderScenarios[0].configuration["camera"]?["position"], [0, 1.3, 2.4])
        XCTAssertEqual(plan.renderScenarios[6].configuration["timestepS"], 0.008333333333333333)
        XCTAssertEqual(plan.renderer["identity"], "none")
        XCTAssertEqual(envelope.result?["planHash"], .string(plan.planHash))
        XCTAssertEqual(SHA256Hex.hex(try Data(contentsOf: URL(fileURLWithPath: out))), envelope.artifacts.first?.sha256)

        let spec = project.invoke("qa plan", ["suite": "spec+style", "file": .string(project.path("draft.vrm")), "out": .string(project.path("spec-plan.json"))])
        XCTAssertEqual(spec.result?["plan"]?["requiredScenarios"], ["spec.structure", "spec.humanoid", "spec.expressions", "spec.springs", "style.lint"])
        XCTAssertEqual(spec.result?["plan"]?["consumers"], [])
        XCTAssertEqual(spec.result?["plan"]?["renderScenarios"], [])
        XCTAssertNotEqual(spec.result?["planHash"], envelope.result?["planHash"])
        XCTAssertEqual(project.invoke("qa plan", ["suite": "spec+style", "file": "missing.vrm", "out": .string(project.path("x.json"))]).errors.first?.code, .missingInput)

        _ = try project.store.mutate(requestId: "style", payload: [:], expectedRevision: 1, dryRun: false, expectedPlanHash: nil) { tx in
            tx.setStyle(["path": "custom.json", "sha256": .string(String(repeating: "b", count: 64))])
            return nil
        }
        let styled = project.invoke("qa plan", ["suite": "spec+style", "file": .string(project.path("draft.vrm")), "out": .string(project.path("styled.json"))])
        XCTAssertEqual(styled.result?["plan"]?["profile"]?["sha256"], .string(String(repeating: "b", count: 64)))
        XCTAssertEqual(styled.result?["plan"]?["revision"], 2)
    }

    // MARK: qa run

    func testQARunSpecStyleIsIncompleteWithoutStyleLintAndNeverPasses() throws {
        let out = project.path("qa")
        let envelope = project.invoke("qa run", ["request": ["file": .string(project.path("draft.vrm")), "suite": "spec+style"], "out": .string(out)])
        XCTAssertEqual(envelope.status, .incomplete)
        XCTAssertEqual(envelope.exitCode, .missingCapability)
        assertResultSchema(envelope, "qa run")
        XCTAssertEqual(envelope.result?["verdict"], "incomplete")
        let checks = try XCTUnwrap(envelope.result?["checks"]?.array)
        XCTAssertEqual(checks.first { $0["id"] == "style.lint.profile" }?["status"], "incomplete")
        XCTAssertEqual(checks.filter { $0["status"] == "fail" }, [])
        for key in checks.flatMap({ $0.object?.keys ?? [:].keys }) { XCTAssertTrue(["id", "status", "message", "reportHash"].contains(key)) }
        XCTAssertEqual(envelope.errors.map(\.path), ["style.lint.profile"])
        let report = try QAReport.load(URL(fileURLWithPath: out + "/findings.json"))
        XCTAssertEqual(report.verdict, .incomplete)
        XCTAssertEqual(report.file.sha256, SHA256Hex.hex(try draft()))
        XCTAssertEqual(report.buildHash, try project.store.state().object(id: "avatar:main")?.fields["buildHash"]?.string)
        XCTAssertEqual(report.revision, 1)
        XCTAssertEqual(report.scenarios.filter(\.required).map { "\($0.id):\($0.status.rawValue)" },
                       ["spec.structure:pass", "spec.humanoid:pass", "spec.expressions:pass", "spec.springs:pass", "style.lint:incomplete"])
        XCTAssertEqual(report.scenarios.first { $0.id == "spec.meta" }?.status, .pass)
        XCTAssertEqual(report.checks.first { $0.id == "spec.identityEdit" }?.status, .notApplicable)
        XCTAssertEqual(envelope.result?["reportHash"], .string(SHA256Hex.hex(try Data(contentsOf: URL(fileURLWithPath: out + "/findings.json")))))
        let evidence = try JSONValue.parse(try Data(contentsOf: URL(fileURLWithPath: out + "/evidence-index.json")))
        XCTAssertEqual(evidence["findings"]?["sha256"], envelope.result?["reportHash"])
        XCTAssertEqual(evidence["file"]?["sha256"], .string(report.file.sha256))
        XCTAssertEqual(envelope.artifacts.map(\.role), ["qa-report", "qa-evidence"])
        XCTAssertEqual(project.invoke("qa run", ["request": ["file": .string(project.path("draft.vrm")), "suite": "spec+style"], "out": .string(out)]).errors.first?.code, .outputExists)
    }

    func testQARunPassesWithStyleLintHandlerAndFailDominatesIncomplete() throws {
        let passing = try TestProject.make(registry: TestProject.registry(extra: [StubStyleLint.installer(verdict: "conforming-with-warnings")]))
        defer { passing.cleanup() }
        try passing.applyDefaultRecipe()
        XCTAssertEqual(passing.invoke("build", ["out": .string(passing.path("draft.vrm"))]).exitCode, .success)
        let ok = passing.invoke("qa run", ["request": ["file": .string(passing.path("draft.vrm")), "suite": "spec+style"], "out": .string(passing.path("qa"))])
        XCTAssertEqual(ok.exitCode, .success, "\(ok.errors)")
        XCTAssertEqual(ok.result?["verdict"], "pass")
        XCTAssertNotNil(ok.result?["checks"]?.array?.first { $0["id"] == "style.lint.profile" }?["reportHash"])

        let failing = try TestProject.make(registry: TestProject.registry(extra: [StubStyleLint.installer(verdict: "nonconforming")]))
        defer { failing.cleanup() }
        try failing.applyDefaultRecipe()
        XCTAssertEqual(failing.invoke("build", ["out": .string(failing.path("draft.vrm"))]).exitCode, .success)
        let bad = failing.invoke("qa run", ["request": ["file": .string(failing.path("draft.vrm")), "suite": "authoring-v1"], "out": .string(failing.path("qa"))])
        XCTAssertEqual(bad.status, .failed)
        XCTAssertEqual(bad.exitCode, .gateFailed)
        XCTAssertEqual(bad.result?["verdict"], "fail")
        XCTAssertEqual(bad.errors.first?.code.rawValue, "STYLE_MUST_FAILED")
        XCTAssertTrue(bad.result?["checks"]?.array?.contains { $0["id"] == "visual.front.render" && $0["status"] == "incomplete" } ?? false)
    }

    func testQARunPlanFormVerifiesPlanAndFileBinding() throws {
        let planPath = project.path("plan.json")
        XCTAssertEqual(project.invoke("qa plan", ["suite": "spec+style", "file": .string(project.path("draft.vrm")), "out": .string(planPath)]).exitCode, .success)
        let planData = try Data(contentsOf: URL(fileURLWithPath: planPath))
        let request: JSONValue = ["plan": ["path": .string(planPath), "sha256": .string(SHA256Hex.hex(planData))]]
        let run = project.invoke("qa run", ["request": request, "out": .string(project.path("qa1"))])
        XCTAssertEqual(run.status, .incomplete)
        XCTAssertEqual(run.result?["checks"]?.array?.first { $0["id"] == "spec.structure.binding" }?["status"], "pass")
        XCTAssertEqual(try QAReport.load(URL(fileURLWithPath: project.path("qa1/findings.json"))).planHash, try QAPlan.load(URL(fileURLWithPath: planPath)).planHash)

        let wrongHash = project.invoke("qa run", ["request": ["plan": ["path": .string(planPath), "sha256": .string(String(repeating: "c", count: 64))]], "out": .string(project.path("qa2"))])
        XCTAssertEqual(wrongHash.errors.first?.code, .validationFailed)

        var tampered = try JSONValue.parse(planData).object!
        tampered["requiredScenarios"] = ["spec.structure"]
        let tamperedPath = project.path("tampered.json")
        let tamperedData = try CanonicalJSON.data(.object(tampered))
        try tamperedData.write(to: URL(fileURLWithPath: tamperedPath))
        let refused = project.invoke("qa run", ["request": ["plan": ["path": .string(tamperedPath), "sha256": .string(SHA256Hex.hex(tamperedData))]], "out": .string(project.path("qa3"))])
        XCTAssertEqual(refused.errors.first?.code, .validationFailed)

        try project.applyDefaultRecipe(requestId: "apply-2") { $0.body = ["body.heightM": 1.7] }
        XCTAssertEqual(project.invoke("build", ["out": .string(project.path("draft.vrm")), "replace": true]).exitCode, .success)
        let mismatch = project.invoke("qa run", ["request": request, "out": .string(project.path("qa4"))])
        XCTAssertEqual(mismatch.status, .failed)
        XCTAssertEqual(mismatch.exitCode, .gateFailed)
        XCTAssertEqual(mismatch.errors.first?.code, .reportBindingMismatch)
    }

    func testAcceptanceFormRequiresIsolatedEvaluatorSession() throws {
        let buildHash = try XCTUnwrap(try project.store.state().object(id: "avatar:main")?.fields["buildHash"]?.string)
        let packPath = project.path("pack.json")
        let packData = try CanonicalJSON.data(["id": "export-verify", "operation": "export verify"])
        try packData.write(to: URL(fileURLWithPath: packPath))
        let request: JSONValue = ["acceptance": ["pack": ["path": .string(packPath), "sha256": .string(SHA256Hex.hex(packData))], "candidateBuild": .string(buildHash)]]
        let refused = project.invoke("qa run", ["request": request, "out": .string(project.path("acc")) ])
        XCTAssertEqual(refused.errors.first?.code, .missingCapability)
        XCTAssertEqual(refused.exitCode, .missingCapability)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.path("acc")))

        project.env = ["VRM_AUTHOR_SESSION": "harness"]
        let run = project.invoke("qa run", ["request": request, "out": .string(project.path("acc"))])
        XCTAssertEqual(run.status, .incomplete, "\(run.errors)")
        let report = try QAReport.load(URL(fileURLWithPath: project.path("acc/findings.json")))
        XCTAssertEqual(report.suite, .authoringV1)
        XCTAssertEqual(report.buildHash, buildHash)
        let missingBuild = project.invoke("qa run", ["request": ["acceptance": ["pack": ["path": .string(packPath), "sha256": .string(SHA256Hex.hex(packData))], "candidateBuild": .string(String(repeating: "d", count: 64))]], "out": .string(project.path("acc2"))])
        XCTAssertEqual(missingBuild.errors.first?.code, .missingInput)
    }

    func testAuthoringV1IsIncompleteWithoutRendererAndConsumer() throws {
        let envelope = project.invoke("qa run", ["request": ["file": .string(project.path("draft.vrm")), "suite": "authoring-v1"], "out": .string(project.path("qa"))])
        XCTAssertEqual(envelope.status, .incomplete)
        XCTAssertEqual(envelope.exitCode, .missingCapability)
        let report = try QAReport.load(URL(fileURLWithPath: project.path("qa/findings.json")))
        for scenario in ["visual.front", "visual.threeQuarter", "visual.profile", "expression.blink", "expression.aa", "expression.happy", "motion.idle"] {
            XCTAssertEqual(report.scenarios.first { $0.id == scenario }?.status, .incomplete, scenario)
        }
        XCTAssertEqual(report.checks.first { $0.id == "consumer.vrmmetalkit.import" }?.status, .incomplete)
        XCTAssertEqual(report.requiredArtifacts.count, 7)
        XCTAssertTrue(report.requiredArtifacts.allSatisfy { $0.sha256 == nil })
        XCTAssertEqual(report.evidence, [])
    }

    // MARK: export verify + inspections

    private func verifiedProject() throws -> TestProject {
        let verified = try TestProject.make(registry: TestProject.registry(render: StubRenderer(), consumer: StubVRMMetalKitConsumer(), extra: [StubStyleLint.installer(verdict: "conforming")]))
        try verified.applyDefaultRecipe()
        XCTAssertEqual(verified.invoke("export vrm", ["out": .string(verified.path("final.vrm"))]).exitCode, .success)
        return verified
    }

    private func recordInspections(_ verified: TestProject, report: QAReport, verdict: InspectionVerdict, only: Set<String>? = nil) {
        for artifact in report.requiredArtifacts where only?.contains(artifact.scenarioId) ?? true {
            let inspection: JSONValue = [
                "artifactHash": .string(artifact.sha256!), "buildHash": .string(report.buildHash!), "revision": .number(Double(report.revision!)),
                "scenarioId": .string(artifact.scenarioId), "actor": "test-inspector", "actorVersion": "1", "rubricHash": .string(String(repeating: "e", count: 64)),
                "timestamp": "2026-09-10T00:00:00Z", "findings": ["looks right"], "verdict": .string(verdict.rawValue),
            ]
            let recorded = verified.invoke("inspection record", ["inspection": inspection])
            XCTAssertEqual(recorded.exitCode, .success, "\(recorded.errors)")
        }
    }

    func testExportVerifyRequiresInspectionsThenPasses() throws {
        let verified = try verifiedProject()
        defer { verified.cleanup() }
        let first = verified.invoke("export verify", ["file": .string(verified.path("final.vrm")), "out": .string(verified.path("verify1"))])
        XCTAssertEqual(first.status, .incomplete, "\(first.errors)")
        XCTAssertEqual(first.exitCode, .missingCapability)
        assertResultSchema(first, "export verify", in: verified.registry)
        let report = try QAReport.load(URL(fileURLWithPath: verified.path("verify1/findings.json")))
        XCTAssertEqual(report.operation, "export verify")
        XCTAssertEqual(report.requiredArtifacts.count, 7)
        XCTAssertTrue(report.requiredArtifacts.allSatisfy { $0.sha256 != nil })
        XCTAssertEqual(report.checks.first { $0.id == "inspection.coverage" }?.status, .incomplete)
        XCTAssertEqual(report.checks.first { $0.id == "inspection.coverage" }?.code, "INSPECTION_MISSING")
        XCTAssertEqual(report.checks.first { $0.id == "consumer.vrmmetalkit.import" }?.status, .pass)
        XCTAssertEqual(report.checks.first { $0.id == "visual.front.render" }?.status, .pass)
        XCTAssertEqual(first.artifacts.filter { $0.role == "render" }.count, 7)
        XCTAssertEqual(verified.invoke("inspection verify", ["report": .string(verified.path("verify1/findings.json"))]).status, .incomplete)

        recordInspections(verified, report: report, verdict: .uncertain, only: ["visual.front"])
        recordInspections(verified, report: report, verdict: .pass, only: Set(report.requiredArtifacts.map(\.scenarioId)).subtracting(["visual.front"]))
        let blocked = verified.invoke("inspection verify", ["report": .string(verified.path("verify1/findings.json"))])
        XCTAssertEqual(blocked.status, .incomplete)
        XCTAssertEqual(blocked.result?["uncertain"], ["visual.front"])
        XCTAssertEqual(blocked.result?["missing"], [])
        let stillBlocked = verified.invoke("export verify", ["file": .string(verified.path("final.vrm")), "out": .string(verified.path("verify2"))])
        XCTAssertEqual(stillBlocked.status, .incomplete)
        XCTAssertEqual(stillBlocked.errors.map(\.path), ["inspection.coverage"])

        recordInspections(verified, report: report, verdict: .pass, only: ["visual.front"])
        let passed = verified.invoke("export verify", ["file": .string(verified.path("final.vrm")), "out": .string(verified.path("verify3"))])
        XCTAssertEqual(passed.exitCode, .success, "\(passed.errors)")
        XCTAssertEqual(passed.result?["verdict"], "pass")
        let coverage = verified.invoke("inspection verify", ["report": .string(verified.path("verify3/findings.json"))])
        XCTAssertEqual(coverage.exitCode, .success)
        assertResultSchema(coverage, "inspection verify", in: verified.registry)
        XCTAssertEqual(coverage.result?["verdict"], "pass")

        recordInspections(verified, report: report, verdict: .fail, only: ["motion.idle"])
        let failed = verified.invoke("inspection verify", ["report": .string(verified.path("verify3/findings.json"))])
        XCTAssertEqual(failed.exitCode, .gateFailed)
        XCTAssertEqual(failed.result?["failed"], ["motion.idle"])
        XCTAssertEqual(failed.errors.first?.code, .inspectionFailed)

        try verified.applyDefaultRecipe(requestId: "apply-2") { $0.body = ["body.heightM": 1.75] }
        XCTAssertEqual(verified.invoke("export vrm", ["out": .string(verified.path("final.vrm")), "replace": true]).exitCode, .success)
        let rebuilt = verified.invoke("export verify", ["file": .string(verified.path("final.vrm")), "out": .string(verified.path("verify4"))])
        XCTAssertEqual(rebuilt.status, .incomplete)
        XCTAssertEqual(try QAReport.load(URL(fileURLWithPath: verified.path("verify4/findings.json"))).checks.first { $0.id == "inspection.coverage" }?.code, "INSPECTION_MISSING")
        let staleReport = verified.invoke("inspection verify", ["report": .string(verified.path("verify3/findings.json"))])
        XCTAssertEqual(staleReport.exitCode, .gateFailed)
        XCTAssertEqual(staleReport.errors.first?.code, .reportBindingMismatch)
    }

    func testInspectionRecordIsAppendOnlyAndNeverAdvancesRevision() throws {
        let artifactHash = String(repeating: "a", count: 64)
        let buildHash = try XCTUnwrap(try project.store.state().object(id: "avatar:main")?.fields["buildHash"]?.string)
        let inspection: JSONValue = [
            "artifactHash": .string(artifactHash), "buildHash": .string(buildHash), "revision": 1, "scenarioId": "visual.front", "actor": "claude", "actorVersion": "fable-5.1",
            "rubricHash": .string(String(repeating: "e", count: 64)), "timestamp": "2026-09-10T00:00:00Z", "findings": [], "verdict": "pass",
        ]
        let dry = project.invoke("inspection record", ["inspection": inspection, "dryRun": true])
        XCTAssertEqual(dry.exitCode, .success, "\(dry.errors)")
        XCTAssertEqual(dry.plan?.edits.first?.pointer, "/reports/inspections/\(artifactHash)/0001.json")
        XCTAssertEqual(InspectionHandlers.records(for: artifactHash, in: project.store).count, 0)

        let first = project.invoke("inspection record", ["inspection": inspection, "expectedPlanHash": .string(dry.plan!.planHash)])
        XCTAssertEqual(first.exitCode, .success, "\(first.errors)")
        assertResultSchema(first, "inspection record")
        XCTAssertEqual(first.revisionBefore, 1)
        XCTAssertEqual(first.revisionAfter, 1)
        XCTAssertEqual(try project.store.state().revision, 1)
        XCTAssertEqual(try project.store.revisionNumbers(), [0, 1])
        let recordHash = try XCTUnwrap(first.result?["recordHash"]?.string)
        XCTAssertEqual(recordHash, first.artifacts.first?.sha256)
        let retry = project.invoke("inspection record", ["inspection": inspection, "requestId": "retry"])
        XCTAssertEqual(retry.exitCode, .success)
        XCTAssertEqual(retry.result?["recordHash"], .string(recordHash))
        XCTAssertEqual(retry.warnings.first?.code, "INSPECTION_DUPLICATE")
        XCTAssertEqual(InspectionHandlers.records(for: artifactHash, in: project.store).count, 1)
        let uncertain = project.invoke("inspection record", ["inspection": inspection.merging(["verdict": "uncertain"])])
        XCTAssertEqual(uncertain.warnings.first?.code, "INSPECTION_UNCERTAIN")
        let records = InspectionHandlers.records(for: artifactHash, in: project.store)
        XCTAssertEqual(records.map(\.verdict), [.pass, .uncertain])
        let dir = InspectionHandlers.inspectionsDirectory(project.store).appendingPathComponent(artifactHash)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["0001.json", "0002.json"])
        XCTAssertEqual(SHA256Hex.hex(try Data(contentsOf: dir.appendingPathComponent("0001.json"))), recordHash)
        XCTAssertEqual(project.invoke("inspection record", ["inspection": inspection, "expectedRevision": 7]).exitCode, .conflict)
        XCTAssertEqual(project.invoke("inspection record", ["inspection": inspection.merging(["verdict": "maybe"])]).exitCode, .invalidRequest)
        XCTAssertEqual(project.invoke("inspection record", ["inspection": inspection.merging(["artifactHash": "nope"])]).exitCode, .invalidRequest)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 2)
        XCTAssertEqual(try project.store.state().revision, 1)
    }

    func testInspectionVerifyRejectsMissingStaleFailedAndUncertain() throws {
        let verified = try verifiedProject()
        defer { verified.cleanup() }
        XCTAssertEqual(verified.invoke("export verify", ["file": .string(verified.path("final.vrm")), "out": .string(verified.path("v"))]).status, .incomplete)
        let reportURL = URL(fileURLWithPath: verified.path("v/findings.json"))
        var report = try QAReport.load(reportURL)
        let missing = verified.invoke("inspection verify", ["report": .string(reportURL.path)])
        XCTAssertEqual(missing.status, .incomplete)
        XCTAssertEqual(missing.exitCode, .missingCapability)
        XCTAssertEqual(missing.result?["missing"]?.array?.count, 7)

        recordInspections(verified, report: report, verdict: .pass)
        XCTAssertEqual(verified.invoke("inspection verify", ["report": .string(reportURL.path)]).exitCode, .success)

        let png = URL(fileURLWithPath: report.requiredArtifacts[0].path!)
        var bytes = try Data(contentsOf: png)
        bytes.append(0x00)
        try bytes.write(to: png)
        let stale = verified.invoke("inspection verify", ["report": .string(reportURL.path)])
        XCTAssertEqual(stale.exitCode, .gateFailed)
        XCTAssertEqual(stale.result?["stale"]?.array?.count, 1)
        XCTAssertEqual(stale.errors.first?.code, .inspectionStale)

        report.requiredArtifacts[0] = QARequiredArtifact(scenarioId: "visual.front", path: nil, sha256: String(repeating: "9", count: 64), mediaType: "image/png")
        try CanonicalJSON.data(try JSONValue.from(report)).write(to: reportURL)
        let unbound = verified.invoke("inspection verify", ["report": .string(reportURL.path)])
        XCTAssertEqual(unbound.status, .incomplete)
        XCTAssertEqual(unbound.result?["missing"], ["visual.front"])
        XCTAssertEqual(verified.invoke("inspection verify", ["report": "nope.json"]).errors.first?.code, .missingInput)
    }

    // MARK: Evidence registry

    func testHandlersNeverWriteTheEvidenceRegistry() throws {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { url = url.deletingLastPathComponent() }
        var offenders: [String] = []
        for area in ["Export", "QA"] {
            let dir = url.appendingPathComponent("Sources/VRMAuthorKit/\(area)")
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".swift") {
                let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                if text.contains("evidence.json") || text.contains("acceptanceDirectory") || text.contains("evidenceRegistry.entries") || text.contains("packs/") {
                    offenders.append("\(area)/\(name)")
                }
            }
        }
        XCTAssertEqual(offenders, [])
        let mirror = Mirror(reflecting: EvidenceRegistry())
        XCTAssertFalse(mirror.children.contains { "\($0.label ?? "")".lowercased().contains("write") })
    }

    func testQAErrorCodesMapToContractExitCodes() {
        XCTAssertEqual(AuthorErrorCode.noOpEdit.exitCode, .gateFailed)
        XCTAssertEqual(AuthorErrorCode.reportBindingMismatch.exitCode, .gateFailed)
        XCTAssertEqual(AuthorErrorCode.inspectionFailed.exitCode, .gateFailed)
        XCTAssertEqual(AuthorErrorCode.malformedGLB.exitCode, .gateFailed)
        XCTAssertEqual(AuthorErrorCode.staleDependency.exitCode, .gateFailed)
        XCTAssertEqual(ExportQAInstaller.names.count, 9)
        XCTAssertEqual(Set(Registry.v1().ordered.filter(\.isRunnable).map(\.name)).isSuperset(of: ExportQAInstaller.names), true)
    }
}

final class ExportQACLITests: XCTestCase {
    func testCLIDriverRunsQARunAndInspectionRecordEndToEnd() throws {
        let project = try TestProject.make()
        defer { project.cleanup() }
        let file = project.path("factory.vrm")
        try GLBWriter.write(TestAvatarFactory.make()).data.write(to: URL(fileURLWithPath: file))
        let requestFile = project.path("qa-request.json")
        try CanonicalJSON.data(["request": ["file": .string(file), "suite": "spec+style"]]).write(to: URL(fileURLWithPath: requestFile))
        var out = Data()
        var err = ""
        let code = CLIDriver.run(arguments: ["qa", "run", "--project", project.projectURL.path, "--request", requestFile, "--out", project.path("qa")],
                                 environment: [:], cwd: project.root, executableURL: nil, stdin: { Data() }, stdout: { out.append($0) }, stderr: { err += $0 })
        XCTAssertEqual(code, 3, err)
        let envelope = try JSONValue.parse(out)
        XCTAssertEqual(envelope["status"], "incomplete")
        XCTAssertEqual(envelope["result"]?["verdict"], "incomplete")
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.path("qa/findings.json")))
        XCTAssertEqual(envelope["errors"]?[0]?["code"], "MISSING_CAPABILITY")
        XCTAssertEqual(envelope["errors"]?[0]?["path"], "style.lint.profile")
        XCTAssertTrue(err.contains("MISSING_CAPABILITY"), err)

        let inspection = project.path("inspection.json")
        try CanonicalJSON.data(["inspection": [
            "artifactHash": .string(SHA256Hex.hex(fileAt: URL(fileURLWithPath: file))), "buildHash": .string(String(repeating: "1", count: 64)), "revision": 0,
            "scenarioId": "visual.front", "actor": "cli", "actorVersion": "1", "rubricHash": .string(String(repeating: "2", count: 64)),
            "timestamp": "2026-09-10T00:00:00Z", "findings": [], "verdict": "pass",
        ]]).write(to: URL(fileURLWithPath: inspection))
        out = Data()
        let recorded = CLIDriver.run(arguments: ["inspection", "record", "--project", project.projectURL.path, "--request", inspection, "--request-id", "cli-1"],
                                     environment: [:], cwd: project.root, executableURL: nil, stdin: { Data() }, stdout: { out.append($0) }, stderr: { _ in })
        XCTAssertEqual(recorded, 0)
        let recordedEnvelope = try JSONValue.parse(out)
        XCTAssertEqual(recordedEnvelope["requestId"], "cli-1")
        XCTAssertEqual(recordedEnvelope["revisionAfter"], 0)
        XCTAssertEqual(recordedEnvelope["result"]?["recordHash"]?.string?.count, 64)
        XCTAssertEqual(CLIDriver.run(arguments: ["build", "--project", project.projectURL.path, "--out", project.path("x.vrm")], environment: [:], cwd: project.root,
                                     executableURL: nil, stdin: { Data() }, stdout: { _ in }, stderr: { _ in }), 3)
    }
}
