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

/// Executes a QA plan over exact file bytes and writes findings.json plus
/// evidence-index.json under an output directory.
public struct QARunner: Sendable {
    public var render: any RenderAdapter
    public var consumer: any ConsumerImporter

    public init(render: any RenderAdapter = NoRenderer(), consumer: any ConsumerImporter = SelfReimportConsumer()) {
        self.render = render
        self.consumer = consumer
    }

    public struct Outcome: Sendable {
        public var report: QAReport
        public var reportData: Data
        public var reportURL: URL
        public var evidenceURL: URL
        public var artifacts: [ArtifactRef]
        public var reportHash: String { SHA256Hex.hex(reportData) }
    }

    public func run(plan: QAPlan, operation: String, fileURL: URL, data: Data, store: ProjectStore?, outputDirectory: URL, context: OperationContext) throws -> Outcome {
        let fileHash = SHA256Hex.hex(data)
        var checks: [QACheck] = []
        var evidence: [ArtifactRef] = []
        var required: [QARequiredArtifact] = []
        var consumers: [ConsumerImportReport] = []

        if fileHash != plan.file.sha256 {
            checks.append(QACheck(scenario: SpecValidator.scenarioStructure, id: "spec.structure.binding", status: .fail,
                                  message: "File sha256 \(fileHash.prefix(12)) does not match the plan binding \(plan.file.sha256.prefix(12)).", code: AuthorErrorCode.reportBindingMismatch.rawValue))
        } else {
            checks.append(QACheck(scenario: SpecValidator.scenarioStructure, id: "spec.structure.binding", status: .pass, message: "File bytes match the plan binding."))
        }
        checks += SpecValidator.validate(data: data)
        checks.append(identityEditCheck(data: data, fileHash: fileHash, store: store))
        checks.append(styleLint(fileURL: fileURL, plan: plan, store: store, context: context))

        if plan.suite == .authoringV1 {
            for scenario in plan.renderScenarios {
                let scenarioDirectory = outputDirectory.appendingPathComponent(scenario.id)
                do {
                    if let artifacts = try render.render(scenario: scenario, file: fileURL, data: data, outputDirectory: scenarioDirectory, context: context), !artifacts.isEmpty {
                        evidence += artifacts
                        for artifact in artifacts { required.append(QARequiredArtifact(scenarioId: scenario.id, path: artifact.path, sha256: artifact.sha256, mediaType: artifact.mediaType)) }
                        checks.append(QACheck(scenario: scenario.id, id: "\(scenario.id).render", status: .pass,
                                              message: "\(artifacts.count) artifact(s) rendered by \(render.identity); inspection records are required for completion.", reportHash: artifacts[0].sha256))
                    } else {
                        required.append(QARequiredArtifact(scenarioId: scenario.id))
                        checks.append(QACheck(scenario: scenario.id, id: "\(scenario.id).render", status: .incomplete,
                                              message: "No renderer produced evidence for \(scenario.id) (renderer: \(render.identity)).", code: AuthorErrorCode.missingCapability.rawValue))
                    }
                } catch {
                    required.append(QARequiredArtifact(scenarioId: scenario.id))
                    checks.append(QACheck(scenario: scenario.id, id: "\(scenario.id).render", status: .incomplete, message: "Renderer failed: \(error)", code: AuthorErrorCode.missingCapability.rawValue))
                }
            }
            for pinned in plan.consumers {
                let scenario = "consumer.\(pinned)"
                guard consumer.id == pinned else {
                    checks.append(QACheck(scenario: scenario, id: "\(scenario).import", status: .incomplete,
                                          message: "Consumer '\(pinned)' is not available in this session (installed: \(consumer.id)).", code: AuthorErrorCode.missingCapability.rawValue))
                    continue
                }
                do {
                    let report = try consumer.importVRM(data, context: context)
                    consumers.append(report)
                    let summary = "\(report.consumer) \(report.version) read \(report.humanoidBones) humanoid bones, \(report.expressions) expressions, \(report.springs) springs, \(report.colliders) colliders."
                    let problems = consumerProblems(report, data: data)
                    checks.append(problems.isEmpty
                        ? QACheck(scenario: scenario, id: "\(scenario).import", status: .pass, message: summary)
                        : QACheck(scenario: scenario, id: "\(scenario).import", status: .fail, message: summary + " " + problems.joined(separator: " "), code: "CONSUMER_MISMATCH"))
                } catch let error as AuthorError where error.code == .missingCapability {
                    checks.append(QACheck(scenario: scenario, id: "\(scenario).import", status: .incomplete,
                                          message: "Consumer '\(pinned)' could not run: \(error.message)", code: AuthorErrorCode.missingCapability.rawValue))
                } catch {
                    checks.append(QACheck(scenario: scenario, id: "\(scenario).import", status: .fail, message: "Consumer '\(pinned)' rejected the file: \(error)", code: "CONSUMER_REJECTED"))
                }
            }
        }

        let scenarios = QARunner.scenarioResults(plan: plan, checks: checks)
        let verdict = QARunner.verdict(scenarios: scenarios, checks: checks)
        var report = QAReport(reportVersion: 1, suite: plan.suite, operation: operation, file: Blob(path: fileURL.path, sha256: fileHash), planHash: plan.planHash,
                              projectId: plan.projectId, revision: plan.revision, buildHash: plan.buildHash, verdict: verdict, scenarios: scenarios, checks: checks,
                              requiredArtifacts: required, evidence: evidence, consumers: consumers, generator: GLBWriter.generator)
        report.evidence = evidence
        let reportData = try CanonicalJSON.data(try JSONValue.from(report))
        let reportURL = outputDirectory.appendingPathComponent("findings.json")
        try ProjectStore.atomicWrite(reportData, to: reportURL)
        let reportRef = BuildSupport.artifact(reportURL, data: reportData, mediaType: BuildSupport.mediaTypeJSON, role: "qa-report", buildHash: plan.buildHash)
        let evidenceIndex: JSONValue = [
            "reportVersion": 1, "planHash": .string(plan.planHash), "file": try JSONValue.from(report.file),
            "findings": ["path": .string(reportURL.path), "sha256": .string(reportRef.sha256)],
            "artifacts": try JSONValue.from(evidence.map { ["path": $0.path, "sha256": $0.sha256] as [String: String] }),
        ]
        let evidenceURL = outputDirectory.appendingPathComponent("evidence-index.json")
        let evidenceData = try CanonicalJSON.data(evidenceIndex)
        try ProjectStore.atomicWrite(evidenceData, to: evidenceURL)
        let artifacts = [reportRef, BuildSupport.artifact(evidenceURL, data: evidenceData, mediaType: BuildSupport.mediaTypeJSON, role: "qa-evidence", buildHash: plan.buildHash)] + evidence
        return Outcome(report: report, reportData: reportData, reportURL: reportURL, evidenceURL: evidenceURL, artifacts: artifacts)
    }

    func consumerProblems(_ report: ConsumerImportReport, data: Data) -> [String] {
        guard let document = try? VRMReader.read(data) else { return [] }
        var problems: [String] = []
        let bones = document.vrm?["humanoid"]?["humanBones"]?.object?.count ?? 0
        let expressions = (document.vrm?["expressions"]?["preset"]?.object?.count ?? 0) + (document.vrm?["expressions"]?["custom"]?.object?.count ?? 0)
        let springs = document.springBone?["springs"]?.array?.count ?? 0
        let colliders = document.springBone?["colliders"]?.array?.count ?? 0
        if report.humanoidBones != bones { problems.append("Consumer read \(report.humanoidBones) humanoid bones; file declares \(bones).") }
        if report.expressions != expressions { problems.append("Consumer read \(report.expressions) expressions; file declares \(expressions).") }
        if report.springs != springs { problems.append("Consumer read \(report.springs) springs; file declares \(springs).") }
        if report.colliders != colliders { problems.append("Consumer read \(report.colliders) colliders; file declares \(colliders).") }
        return problems
    }

    /// Compares the file with the build it supersedes when both are project builds.
    func identityEditCheck(data: Data, fileHash: String, store: ProjectStore?) -> QACheck {
        guard let store, let info = BuildSupport.build(matching: fileHash, in: store) else {
            return QACheck(scenario: SpecValidator.scenarioStructure, id: "spec.identityEdit", status: .notApplicable, message: "File is not a recorded project build; no baseline to compare.")
        }
        guard let previous = info.previousBuildHash, let previousControls = info.previousControlsHash else {
            return QACheck(scenario: SpecValidator.scenarioStructure, id: "spec.identityEdit", status: .notApplicable, message: "First build of this project; no baseline to compare.")
        }
        let inputsChanged = previousControls != info.controlsHash
        if previous == info.buildHash {
            return inputsChanged
                ? QACheck(scenario: SpecValidator.scenarioStructure, id: "spec.identityEdit", status: .fail,
                          message: "Geometry inputs changed since the previous build but the compiled avatar is byte-identical (build \(info.buildHash.prefix(12))).", code: AuthorErrorCode.noOpEdit.rawValue)
                : QACheck(scenario: SpecValidator.scenarioStructure, id: "spec.identityEdit", status: .pass, message: "Rebuild with unchanged inputs.")
        }
        guard let baselineData = try? Data(contentsOf: BuildSupport.avatarURL(store, previous)),
              let baseline = try? VRMReader.read(baselineData), let candidate = try? VRMReader.read(data) else {
            return QACheck(scenario: SpecValidator.scenarioStructure, id: "spec.identityEdit", status: .incomplete, message: "Baseline build \(previous.prefix(12)) is missing from builds/.", code: AuthorErrorCode.missingInput.rawValue)
        }
        return GeometryChecks.noOpEdit(baseline: baseline, candidate: candidate, geometryInputsChanged: inputsChanged)
    }

    /// Locates the plan's profile bytes the way `style lint` does: the path as
    /// given (absolute or cwd-relative), the project's attached style asset,
    /// then the toolchain's pinned copy (env override or repository root, found
    /// from cwd, the executable or the sources). Nil when nothing matches the
    /// plan's sha256, so the lint reports the missing file.
    public static func resolveProfile(_ profile: Blob, store: ProjectStore?, context: OperationContext) -> URL? {
        let fm = FileManager.default
        func matches(_ url: URL?) -> URL? {
            guard let url, fm.fileExists(atPath: url.path), let hash = try? SHA256Hex.hex(fileAt: url), hash == profile.sha256 else { return nil }
            return url
        }
        if let url = matches(URL(fileURLWithPath: profile.path, relativeTo: context.cwd).standardizedFileURL) { return url }
        if let store, let url = matches(store.assetsDirectory.appendingPathComponent(profile.sha256)) { return url }
        if let url = matches(StyleToolchain.locate(context: context).profile) { return url }
        return nil
    }

    func styleLint(fileURL: URL, plan: QAPlan, store: ProjectStore?, context: OperationContext) -> QACheck {
        guard let operation = context.registry.operation(named: "style lint"), operation.isRunnable else {
            return QACheck(scenario: "style.lint", id: "style.lint.profile", status: .incomplete, message: "style lint handler is not installed in this build.", code: AuthorErrorCode.missingCapability.rawValue)
        }
        let profilePath = QARunner.resolveProfile(plan.profile, store: store, context: context)?.path ?? plan.profile.path
        var request: JSONValue = ["file": .string(fileURL.path), "profile": ["path": .string(profilePath), "sha256": .string(plan.profile.sha256)]]
        if let project = context.projectPath { request = request.merging(["project": .string(project.path)]) }
        let envelope = context.registry.invoke("style lint", request: request, context: context)
        let reportHash = (try? envelope.result?["report"].map { try CanonicalJSON.sha256($0) }) ?? nil
        switch envelope.status {
        case .succeeded:
            let verdict = envelope.result?["verdict"]?.string ?? "conforming"
            return verdict == "nonconforming"
                ? QACheck(scenario: "style.lint", id: "style.lint.profile", status: .fail, message: "Style lint verdict: \(verdict).", code: "STYLE_MUST_FAILED", reportHash: reportHash)
                : QACheck(scenario: "style.lint", id: "style.lint.profile", status: .pass, message: "Style lint verdict: \(verdict).", reportHash: reportHash)
        case .failed:
            if envelope.errors.allSatisfy({ $0.code.exitCode == .gateFailed }) {
                return QACheck(scenario: "style.lint", id: "style.lint.profile", status: .fail, message: envelope.errors.map(\.message).joined(separator: " "), code: "STYLE_MUST_FAILED", reportHash: reportHash)
            }
            return QACheck(scenario: "style.lint", id: "style.lint.profile", status: .incomplete, message: envelope.errors.map(\.message).joined(separator: " "), code: envelope.errors.first?.code.rawValue)
        case .incomplete:
            return QACheck(scenario: "style.lint", id: "style.lint.profile", status: .incomplete, message: envelope.errors.map(\.message).joined(separator: " "), code: envelope.errors.first?.code.rawValue)
        }
    }

    public static func scenarioResults(plan: QAPlan, checks: [QACheck]) -> [QAScenarioResult] {
        var ids: [String] = plan.requiredScenarios
        for check in checks where !ids.contains(check.scenario) { ids.append(check.scenario) }
        return ids.map { id in
            let own = checks.filter { $0.scenario == id }
            let status: CheckStatus
            if own.contains(where: { $0.status == .fail }) { status = .fail }
            else if own.contains(where: { $0.status == .incomplete }) || own.isEmpty { status = .incomplete }
            else if own.allSatisfy({ $0.status == .notApplicable }) { status = .notApplicable }
            else { status = .pass }
            return QAScenarioResult(id: id, required: plan.requiredScenarios.contains(id), status: status, checks: own.map(\.id))
        }
    }

    /// Fail dominates incomplete; a required scenario that could not run is
    /// incomplete, never a pass.
    public static func verdict(scenarios: [QAScenarioResult], checks: [QACheck]) -> CheckStatus {
        if checks.contains(where: { $0.status == .fail }) { return .fail }
        if scenarios.contains(where: { $0.required && $0.status == .incomplete }) { return .incomplete }
        if checks.contains(where: { $0.status == .incomplete }) { return .incomplete }
        return .pass
    }
}
