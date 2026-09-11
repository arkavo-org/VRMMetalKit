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

public enum ResultStatus: String, Codable, Hashable, Sendable {
    case succeeded, failed, incomplete
}

public struct ArtifactRef: Codable, Hashable, Sendable {
    public var path: String
    public var sha256: String
    public var mediaType: String
    public var sizeBytes: Int
    public var role: String
    public var buildHash: String?

    public init(path: String, sha256: String, mediaType: String, sizeBytes: Int, role: String, buildHash: String? = nil) {
        self.path = path
        self.sha256 = sha256
        self.mediaType = mediaType
        self.sizeBytes = sizeBytes
        self.role = role
        self.buildHash = buildHash
    }
}

public struct PlanEdit: Codable, Hashable, Sendable {
    public var objectId: String
    public var pointer: String
    public var before: JSONValue?
    public var after: JSONValue?

    public init(objectId: String, pointer: String, before: JSONValue?, after: JSONValue?) {
        self.objectId = objectId
        self.pointer = pointer
        self.before = before
        self.after = after
    }
}

/// Exact dry-run plan. `planHash` is the sha256 of the canonical JSON of the plan
/// with `planHash` set to the empty string.
public struct Plan: Codable, Hashable, Sendable {
    public var planHash: String
    public var baseRevision: Int
    public var edits: [PlanEdit]
    public var invalidations: [String]
    public var prerequisites: [String]
    public var cost: JSONValue

    public init(planHash: String, baseRevision: Int, edits: [PlanEdit], invalidations: [String], prerequisites: [String], cost: JSONValue) {
        self.planHash = planHash
        self.baseRevision = baseRevision
        self.edits = edits
        self.invalidations = invalidations
        self.prerequisites = prerequisites
        self.cost = cost
    }

    public static func hashed(baseRevision: Int, edits: [PlanEdit], invalidations: [String], prerequisites: [String], cost: JSONValue) throws -> Plan {
        var plan = Plan(planHash: "", baseRevision: baseRevision, edits: edits, invalidations: invalidations, prerequisites: prerequisites, cost: cost)
        plan.planHash = try CanonicalJSON.sha256(try JSONValue.from(plan))
        return plan
    }
}

/// The `vrmauthor/1` application result. Reads use the same revision twice;
/// project-free operations use null revisions.
public struct ResultEnvelope: Codable, Hashable, Sendable {
    public static let protocolName = "vrmauthor/1"

    public var `protocol`: String
    public var requestId: String?
    public var status: ResultStatus
    public var revisionBefore: Int?
    public var revisionAfter: Int?
    public var artifacts: [ArtifactRef]
    public var warnings: [AuthorWarning]
    public var errors: [AuthorError]
    public var plan: Plan?
    public var result: JSONValue?

    public init(requestId: String?, status: ResultStatus, revisionBefore: Int?, revisionAfter: Int?, artifacts: [ArtifactRef] = [],
                warnings: [AuthorWarning] = [], errors: [AuthorError] = [], plan: Plan? = nil, result: JSONValue? = nil) {
        self.protocol = ResultEnvelope.protocolName
        self.requestId = requestId
        self.status = status
        self.revisionBefore = revisionBefore
        self.revisionAfter = revisionAfter
        self.artifacts = artifacts
        self.warnings = warnings
        self.errors = errors
        self.plan = plan
        self.result = result
    }

    public static func succeeded(requestId: String?, revisionBefore: Int? = nil, revisionAfter: Int? = nil, result: JSONValue?) -> ResultEnvelope {
        ResultEnvelope(requestId: requestId, status: .succeeded, revisionBefore: revisionBefore, revisionAfter: revisionAfter, result: result)
    }

    public static func failed(requestId: String?, revision: Int?, errors: [AuthorError], result: JSONValue? = nil) -> ResultEnvelope {
        ResultEnvelope(requestId: requestId, status: .failed, revisionBefore: revision, revisionAfter: revision, errors: errors, result: result)
    }

    public static func incomplete(requestId: String?, revision: Int?, errors: [AuthorError], result: JSONValue?) -> ResultEnvelope {
        ResultEnvelope(requestId: requestId, status: .incomplete, revisionBefore: revision, revisionAfter: revision, errors: errors, result: result)
    }

    public var exitCode: ExitCode {
        switch status {
        case .succeeded: return .success
        case .incomplete: return ExitCode.mostSevere(errors.map { $0.code.exitCode } + [.missingCapability])
        case .failed: return errors.isEmpty ? .gateFailed : ExitCode.mostSevere(errors.map { $0.code.exitCode })
        }
    }

    enum CodingKeys: String, CodingKey {
        case `protocol`, requestId, status, revisionBefore, revisionAfter, artifacts, warnings, errors, plan, result
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`protocol`, forKey: .protocol)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(status, forKey: .status)
        try c.encode(revisionBefore, forKey: .revisionBefore)
        try c.encode(revisionAfter, forKey: .revisionAfter)
        try c.encode(artifacts, forKey: .artifacts)
        try c.encode(warnings, forKey: .warnings)
        try c.encode(errors, forKey: .errors)
        try c.encodeIfPresent(plan, forKey: .plan)
        try c.encodeIfPresent(result, forKey: .result)
    }

    public func jsonValue() throws -> JSONValue { try JSONValue.from(self) }
    public func canonicalData() throws -> Data { try CanonicalJSON.data(try jsonValue()) }
}
