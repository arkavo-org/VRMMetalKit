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

/// Handlers for qa plan, qa run and export verify.
public struct QAHandlers: Sendable {
    public var runner: QARunner

    public init(render: any RenderAdapter = NoRenderer(), consumer: any ConsumerImporter = SelfReimportConsumer()) {
        self.runner = QARunner(render: render, consumer: consumer)
    }

    public static let names = ["qa plan", "qa run", "export verify"]

    public func install(into registry: inout Registry) {
        let handlers = self
        registry.mustInstall({ context, request in try handlers.qaPlan(context, request) }, for: "qa plan")
        registry.mustInstall({ context, request in try handlers.qaRun(context, request) }, for: "qa run")
        registry.mustInstall({ context, request in try handlers.exportVerify(context, request) }, for: "export verify")
    }

    // MARK: Plan construction

    /// The project's attached style profile (`style attach` records it under
    /// `style.profile`; a bare blob is accepted too), else the pinned default.
    public static func profile(for state: ProjectState?, context: OperationContext) throws -> Blob {
        if let style = state?.style {
            if let blob = try? Blob.decode(style) { return blob }
            if let path = style["profile"]?["path"]?.string, let sha256 = style["profile"]?["sha256"]?.string { return Blob(path: path, sha256: sha256) }
        }
        return Blob(path: QAPins.defaultProfilePath, sha256: QAPins.defaultProfileSha256)
    }

    public static func linterHash(context: OperationContext) -> String {
        context.evidenceRegistry.pinnedStyleLinterHash ?? QAPins.styleLinterSha256
    }

    func makePlan(suite: QASuite, fileURL: URL, data: Data, store: ProjectStore?, context: OperationContext) throws -> QAPlan {
        let state = try store?.state()
        let fileHash = SHA256Hex.hex(data)
        let buildHash = store.flatMap { BuildSupport.build(matching: fileHash, in: $0)?.buildHash }
        return try QAPlan.make(suite: suite, file: Blob(path: fileURL.path, sha256: fileHash), projectId: state?.projectId, revision: state?.revision, buildHash: buildHash,
                               profile: try QAHandlers.profile(for: state, context: context), linterSha256: QAHandlers.linterHash(context: context), renderer: runner.render.identity)
    }

    func readFile(_ path: String, context: OperationContext, field: String) throws -> (URL, Data) {
        let url = BuildSupport.resolve(path, in: context)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AuthorError(code: .missingInput, path: field, observed: .string(url.path), message: "File not found: \(url.path).", suggestedCommands: ["build"])
        }
        return (url, try Data(contentsOf: url))
    }

    // MARK: qa plan

    func qaPlan(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        let requestId = request["requestId"]?.string
        let store = try BuildSupport.openProject(context)
        let revision = try store.state().revision
        guard let suiteText = request["suite"]?.string, let suite = QASuite(rawValue: suiteText) else { throw AuthorError.invalidRequest("suite is required.", path: "/suite") }
        guard let path = request["file"]?.string else { throw AuthorError.invalidRequest("file is required.", path: "/file") }
        let out = try BuildSupport.outputURL(request, context: context)
        let (url, data) = try readFile(path, context: context, field: "/file")
        let plan = try makePlan(suite: suite, fileURL: url, data: data, store: store, context: context)
        let planData = try plan.canonicalData()
        try ProjectStore.atomicWrite(planData, to: out)
        let artifact = BuildSupport.artifact(out, data: planData, mediaType: BuildSupport.mediaTypeJSON, role: "qa-plan", buildHash: plan.buildHash)
        var envelope = ResultEnvelope.succeeded(requestId: requestId, revisionBefore: revision, revisionAfter: revision, result: [
            "plan": try JSONValue.from(plan), "planHash": .string(plan.planHash), "artifacts": try JSONValue.from([artifact]),
        ])
        envelope.artifacts = [artifact]
        return envelope
    }

    // MARK: qa run

    func qaRun(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        let requestId = request["requestId"]?.string
        let store = try BuildSupport.openProject(context)
        let revision = try store.state().revision
        guard let requestJSON = request["request"] else { throw AuthorError.invalidRequest("request is required.", path: "/request") }
        let qaRequest = try QARequest.decode(requestJSON)
        let out = try BuildSupport.outputURL(request, context: context)
        let plan: QAPlan
        let fileURL: URL
        let data: Data
        if let file = qaRequest.file, let suite = qaRequest.suite {
            (fileURL, data) = try readFile(file, context: context, field: "/request/file")
            plan = try makePlan(suite: suite, fileURL: fileURL, data: data, store: store, context: context)
        } else if let blob = qaRequest.plan {
            let (planURL, planData) = try readFile(blob.path, context: context, field: "/request/plan/path")
            guard SHA256Hex.hex(planData) == blob.sha256 else {
                throw AuthorError(code: .validationFailed, path: "/request/plan/sha256", observed: .string(SHA256Hex.hex(planData)), required: .string(blob.sha256),
                                  message: "QA plan bytes do not match the request's sha256.", suggestedCommands: ["qa plan"])
            }
            plan = try QAPlan.load(planURL)
            (fileURL, data) = try readFile(plan.file.path, context: context, field: "/request/plan")
        } else if let acceptance = qaRequest.acceptance {
            guard context.env[QAPins.sessionEnvironmentKey] == QAPins.harnessSessionValue else {
                throw AuthorError(code: .missingCapability, path: "/request/acceptance", message: "Acceptance runs are only available in an isolated evaluator session (\(QAPins.sessionEnvironmentKey)=\(QAPins.harnessSessionValue)).",
                                  suggestedCommands: ["qa run --request {\"file\":…,\"suite\":…}"])
            }
            let (_, packData) = try readFile(acceptance.pack.path, context: context, field: "/request/acceptance/pack/path")
            guard SHA256Hex.hex(packData) == acceptance.pack.sha256 else {
                throw AuthorError(code: .validationFailed, path: "/request/acceptance/pack/sha256", message: "Acceptance pack bytes do not match the request's sha256.", suggestedCommands: ["capabilities"])
            }
            let candidate = BuildSupport.avatarURL(store, acceptance.candidateBuild)
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                throw AuthorError(code: .missingInput, path: "/request/acceptance/candidateBuild", observed: .string(acceptance.candidateBuild),
                                  message: "Candidate build is not installed under builds/.", suggestedCommands: ["build"])
            }
            fileURL = candidate
            data = try Data(contentsOf: candidate)
            plan = try makePlan(suite: .authoringV1, fileURL: fileURL, data: data, store: store, context: context)
        } else {
            throw AuthorError.invalidRequest("QARequest must be exactly one of {file,suite}, {plan} or {acceptance}.", path: "/request")
        }
        let outcome = try runner.run(plan: plan, operation: "qa run", fileURL: fileURL, data: data, store: store, outputDirectory: out, context: context)
        return QAHandlers.envelope(requestId: requestId, revision: revision, outcome: outcome)
    }

    static func envelope(requestId: String?, revision: Int, outcome: QARunner.Outcome) -> ResultEnvelope {
        let report = outcome.report
        let result: JSONValue = [
            "verdict": .string(report.verdict.rawValue), "checks": .array(report.checks.map(\.resultJSON)),
            "reportHash": .string(outcome.reportHash), "artifacts": (try? JSONValue.from(outcome.artifacts)) ?? [],
        ]
        var envelope: ResultEnvelope
        switch report.verdict {
        case .pass, .notApplicable:
            envelope = .succeeded(requestId: requestId, revisionBefore: revision, revisionAfter: revision, result: result)
        case .fail:
            envelope = .failed(requestId: requestId, revision: revision, errors: report.checks.filter { $0.status == .fail }.map { check in
                AuthorError(code: AuthorErrorCode(rawValue: check.code ?? AuthorErrorCode.gateFailed.rawValue), path: check.id, message: check.message,
                            suggestedCommands: ["qa run", "recipe apply"], artifact: outcome.reportURL.path)
            }, result: result)
        case .incomplete:
            envelope = .incomplete(requestId: requestId, revision: revision, errors: report.checks.filter { $0.status == .incomplete }.map { check in
                AuthorError(code: .missingCapability, path: check.id, message: check.message, suggestedCommands: ["doctor", "inspection record"], artifact: outcome.reportURL.path)
            }, result: result)
        }
        envelope.artifacts = outcome.artifacts
        return envelope
    }

    // MARK: export verify

    func exportVerify(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        let requestId = request["requestId"]?.string
        let store = try BuildSupport.openProject(context)
        let revision = try store.state().revision
        guard let path = request["file"]?.string else { throw AuthorError.invalidRequest("file is required.", path: "/file") }
        guard (request["suite"]?.string ?? QASuite.authoringV1.rawValue) == QASuite.authoringV1.rawValue else {
            throw AuthorError.invalidRequest("export verify accepts only the authoring-v1 suite.", path: "/suite", observed: request["suite"])
        }
        let out = try BuildSupport.outputURL(request, context: context)
        let (fileURL, data) = try readFile(path, context: context, field: "/file")
        let plan = try makePlan(suite: .authoringV1, fileURL: fileURL, data: data, store: store, context: context)
        var outcome = try runner.run(plan: plan, operation: "export verify", fileURL: fileURL, data: data, store: store, outputDirectory: out, context: context)
        let coverage = InspectionHandlers.coverage(report: outcome.report, store: store)
        outcome.report.checks.append(coverage.check)
        outcome.report.scenarios = QARunner.scenarioResults(plan: plan, checks: outcome.report.checks)
        outcome.report.verdict = QARunner.verdict(scenarios: outcome.report.scenarios, checks: outcome.report.checks)
        outcome.reportData = try CanonicalJSON.encode(outcome.report)
        try ProjectStore.atomicWrite(outcome.reportData, to: outcome.reportURL)
        outcome.artifacts[0] = BuildSupport.artifact(outcome.reportURL, data: outcome.reportData, mediaType: BuildSupport.mediaTypeJSON, role: "verify-report", buildHash: plan.buildHash)
        return QAHandlers.envelope(requestId: requestId, revision: revision, outcome: outcome)
    }
}
