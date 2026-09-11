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

/// Append-only inspection records under reports/inspections/<artifactHash>/NNNN.json
/// and coverage verification against a QA report. Recording never advances
/// the project revision.
public enum InspectionHandlers {
    public static let names = ["inspection record", "inspection verify"]

    public static func install(into registry: inout Registry) {
        registry.mustInstall(record, for: "inspection record")
        registry.mustInstall(verify, for: "inspection verify")
    }

    public static func inspectionsDirectory(_ store: ProjectStore) -> URL { store.reportsDirectory.appendingPathComponent("inspections") }

    public static func records(for artifactHash: String, in store: ProjectStore) -> [Inspection] {
        let dir = inspectionsDirectory(store).appendingPathComponent(artifactHash)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") && !$0.contains(ProjectStore.tempInfix) }.sorted()
        return names.compactMap { name in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)), let json = try? JSONValue.parse(data) else { return nil }
            return try? Inspection.decode(json)
        }
    }

    // MARK: inspection record

    static func record(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        let requestId = request["requestId"]?.string ?? UUID().uuidString
        let store = try BuildSupport.openProject(context)
        let revision = try store.state().revision
        if let expected = request["expectedRevision"]?.int, expected != revision {
            throw AuthorError(code: .revisionConflict, path: "/expectedRevision", observed: .number(Double(revision)), required: .number(Double(expected)),
                              message: "Project is at revision \(revision), expected \(expected).", suggestedCommands: ["project inspect"])
        }
        guard let inspectionJSON = request["inspection"] else { throw AuthorError.invalidRequest("inspection is required.", path: "/inspection") }
        let inspection = try Inspection.decode(inspectionJSON)
        let recordJSON = try inspection.jsonValue()
        let recordData = try CanonicalJSON.data(recordJSON)
        let recordHash = SHA256Hex.hex(recordData)
        let dir = inspectionsDirectory(store).appendingPathComponent(inspection.artifactHash)
        let existing = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") && !$0.contains(ProjectStore.tempInfix) }.sorted()
        if let duplicate = existing.first(where: { (try? SHA256Hex.hex(fileAt: dir.appendingPathComponent($0))) == recordHash }) {
            let url = dir.appendingPathComponent(duplicate)
            let plan = try Plan.hashed(baseRevision: revision, edits: [], invalidations: [], prerequisites: [], cost: ["cpuSeconds": 0])
            var envelope = ResultEnvelope.succeeded(requestId: requestId, revisionBefore: revision, revisionAfter: revision,
                                                    result: ["recordHash": .string(recordHash), "plan": try JSONValue.from(plan)])
            envelope.plan = plan
            envelope.artifacts = [BuildSupport.artifact(url, data: recordData, mediaType: BuildSupport.mediaTypeJSON, role: "inspection", buildHash: inspection.buildHash)]
            envelope.warnings.append(AuthorWarning(code: "INSPECTION_DUPLICATE", message: "An identical inspection record already exists at \(url.lastPathComponent); nothing was appended.", path: "/inspection"))
            return envelope
        }
        let next = dir.appendingPathComponent(String(format: "%04d.json", existing.count + 1))
        let edit = PlanEdit(objectId: "inspection:\(inspection.artifactHash.prefix(12))", pointer: "/reports/inspections/\(inspection.artifactHash)/\(next.lastPathComponent)", before: nil, after: recordJSON)
        let plan = try Plan.hashed(baseRevision: revision, edits: [edit], invalidations: [], prerequisites: [], cost: ["cpuSeconds": 0])
        if request["expectedPlanHash"]?.string.map({ $0 != plan.planHash }) ?? false {
            throw AuthorError(code: .planHashMismatch, path: "/expectedPlanHash", observed: .string(plan.planHash), required: request["expectedPlanHash"],
                              message: "The plan for this request differs from the inspected plan.", suggestedCommands: ["--dry-run"])
        }
        var envelope = ResultEnvelope.succeeded(requestId: requestId, revisionBefore: revision, revisionAfter: revision,
                                                result: ["recordHash": .string(recordHash), "plan": try JSONValue.from(plan)])
        envelope.plan = plan
        if request["dryRun"]?.bool ?? false { return envelope }
        try store.atomicWrite(recordData, to: next)
        envelope.artifacts = [BuildSupport.artifact(next, data: recordData, mediaType: BuildSupport.mediaTypeJSON, role: "inspection", buildHash: inspection.buildHash)]
        if inspection.verdict == .uncertain {
            envelope.warnings.append(AuthorWarning(code: "INSPECTION_UNCERTAIN", message: "Uncertain verdicts block completion until a pass record for the same artifact exists.", path: "/inspection/verdict"))
        }
        return envelope
    }

    // MARK: coverage

    public struct Coverage: Sendable {
        public var missing: [String] = []
        public var stale: [String] = []
        public var failed: [String] = []
        public var uncertain: [String] = []
        public var covered: [String] = []
        public var problems: [String] = []

        public var verdict: CheckStatus {
            if !problems.isEmpty || !failed.isEmpty || !stale.isEmpty { return .fail }
            if !missing.isEmpty || !uncertain.isEmpty { return .incomplete }
            return .pass
        }

        public var check: QACheck {
            let scenario = "inspection.coverage"
            switch verdict {
            case .pass:
                return QACheck(scenario: scenario, id: "inspection.coverage", status: .pass, message: "\(covered.count) required artifact(s) carry pass inspection records bound to current hashes.")
            case .fail:
                let code = !problems.isEmpty ? AuthorErrorCode.reportBindingMismatch : (!failed.isEmpty ? AuthorErrorCode.inspectionFailed : AuthorErrorCode.inspectionStale)
                return QACheck(scenario: scenario, id: "inspection.coverage", status: .fail, message: (problems + failed.map { "failed: \($0)" } + stale.map { "stale: \($0)" }).joined(separator: " "), code: code.rawValue)
            default:
                let code = !uncertain.isEmpty ? AuthorErrorCode.inspectionUncertain : AuthorErrorCode.inspectionMissing
                return QACheck(scenario: scenario, id: "inspection.coverage", status: .incomplete, message: (missing.map { "missing: \($0)" } + uncertain.map { "uncertain: \($0)" }).joined(separator: " "), code: code.rawValue)
            }
        }
    }

    /// Every required artifact in the report needs a pass record whose artifact
    /// hash matches the artifact and whose build hash matches the report's build.
    public static func coverage(report: QAReport, store: ProjectStore) -> Coverage {
        var coverage = Coverage()
        let currentBuild = report.buildHash ?? BuildSupport.build(matching: report.file.sha256, in: store)?.buildHash
        if report.verdict == .pass, report.checks.contains(where: { $0.status == .fail || $0.status == .incomplete }) {
            coverage.problems.append("Report claims pass but contains failed or incomplete checks.")
        }
        if let fileData = try? Data(contentsOf: URL(fileURLWithPath: report.file.path)) {
            let actual = SHA256Hex.hex(fileData)
            if actual != report.file.sha256 { coverage.problems.append("Report binds file sha256 \(report.file.sha256.prefix(12)) but \(report.file.path) now hashes to \(actual.prefix(12)).") }
        } else {
            coverage.problems.append("Report file \(report.file.path) is not readable; the binding cannot be verified.")
        }
        if let currentBuild, let recorded = report.buildHash, recorded != currentBuild {
            coverage.problems.append("Report build \(recorded.prefix(12)) is not the build for these bytes (\(currentBuild.prefix(12))).")
        }
        for artifact in report.requiredArtifacts {
            let label = artifact.scenarioId
            guard let hash = artifact.sha256 else { coverage.missing.append(label); continue }
            if let path = artifact.path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)), SHA256Hex.hex(data) != hash {
                coverage.stale.append("\(label) artifact bytes changed since the report")
                continue
            }
            let records = records(for: hash, in: store).filter { $0.scenarioId == artifact.scenarioId }
            guard !records.isEmpty else { coverage.missing.append(label); continue }
            let bound = records.filter { $0.buildHash == (currentBuild ?? $0.buildHash) && (report.revision == nil || $0.revision == report.revision) }
            guard !bound.isEmpty else { coverage.stale.append("\(label) records bind a different build or revision"); continue }
            if bound.contains(where: { $0.verdict == .fail }) { coverage.failed.append(label); continue }
            if bound.contains(where: { $0.verdict == .uncertain }), !bound.contains(where: { $0.verdict == .pass }) { coverage.uncertain.append(label); continue }
            if bound.contains(where: { $0.verdict == .pass }) { coverage.covered.append(label) } else { coverage.uncertain.append(label) }
        }
        return coverage
    }

    // MARK: inspection verify

    static func verify(_ context: OperationContext, _ request: JSONValue) throws -> ResultEnvelope {
        let requestId = request["requestId"]?.string
        let store = try BuildSupport.openProject(context)
        let revision = try store.state().revision
        guard let path = request["report"]?.string else { throw AuthorError.invalidRequest("report is required.", path: "/report") }
        let report = try QAReport.load(BuildSupport.resolve(path, in: context))
        let coverage = coverage(report: report, store: store)
        let result: JSONValue = [
            "verdict": .string(coverage.verdict.rawValue), "missing": JSONValue(coverage.missing), "stale": JSONValue(coverage.stale),
            "failed": JSONValue(coverage.failed), "uncertain": JSONValue(coverage.uncertain),
        ]
        switch coverage.verdict {
        case .pass, .notApplicable:
            return .succeeded(requestId: requestId, revisionBefore: revision, revisionAfter: revision, result: result)
        case .fail:
            let check = coverage.check
            return .failed(requestId: requestId, revision: revision, errors: [
                AuthorError(code: AuthorErrorCode(rawValue: check.code ?? AuthorErrorCode.gateFailed.rawValue), path: "/report", message: check.message, suggestedCommands: ["qa run", "inspection record"]),
            ], result: result)
        case .incomplete:
            let check = coverage.check
            return .incomplete(requestId: requestId, revision: revision, errors: [
                AuthorError(code: .missingInput, path: "/report", message: check.message, suggestedCommands: ["inspection record"]),
            ], result: result)
        }
    }
}
