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

public enum InspectionVerdict: String, Codable, Hashable, Sendable, CaseIterable { case pass, fail, uncertain }

public struct InspectionScoring: AuthorModel {
    public var inputHashes: [String]
    public var response: Blob
    public var thresholds: Blob

    public init(inputHashes: [String], response: Blob, thresholds: Blob) {
        self.inputHashes = inputHashes
        self.response = response
        self.thresholds = thresholds
    }

    public static let modelName = "InspectionScoring"
    public static let schema = JSONSchema.object(properties: [
        "inputHashes": .array(of: .hash), "response": Blob.schema, "thresholds": Blob.schema,
    ], required: ["inputHashes", "response", "thresholds"])

    public func validate() throws {
        try response.validate()
        try thresholds.validate()
    }
}

public struct Inspection: AuthorModel {
    public var artifactHash: String
    public var buildHash: String
    public var revision: Int
    public var scenarioId: String
    public var actor: String
    public var actorVersion: String
    public var rubricHash: String
    public var timestamp: String
    public var findings: [String]
    public var verdict: InspectionVerdict
    public var scoring: InspectionScoring?

    public init(artifactHash: String, buildHash: String, revision: Int, scenarioId: String, actor: String, actorVersion: String, rubricHash: String,
                timestamp: String, findings: [String], verdict: InspectionVerdict, scoring: InspectionScoring? = nil) {
        self.artifactHash = artifactHash
        self.buildHash = buildHash
        self.revision = revision
        self.scenarioId = scenarioId
        self.actor = actor
        self.actorVersion = actorVersion
        self.rubricHash = rubricHash
        self.timestamp = timestamp
        self.findings = findings
        self.verdict = verdict
        self.scoring = scoring
    }

    public static let modelName = "Inspection"
    public static let schema = JSONSchema.object(properties: [
        "artifactHash": .hash,
        "buildHash": .hash,
        "revision": .integer(minimum: 0),
        "scenarioId": .string(minLength: 1),
        "actor": .string(minLength: 1),
        "actorVersion": .string(minLength: 1),
        "rubricHash": .hash,
        "timestamp": .string(minLength: 1, description: "RFC 3339"),
        "findings": .array(of: .string()),
        "verdict": .enumeration(of: InspectionVerdict.self),
        "scoring": InspectionScoring.schema,
    ], required: ["artifactHash", "buildHash", "revision", "scenarioId", "actor", "actorVersion", "rubricHash", "timestamp", "findings", "verdict"],
       description: "Append-only artifact inspection attestation")

    public func validate() throws { try scoring?.validate() }
}

public enum QASuite: String, Codable, Hashable, Sendable, CaseIterable {
    case specStyle = "spec+style"
    case authoringV1 = "authoring-v1"
}

public struct AcceptanceRequest: AuthorModel {
    public var pack: Blob
    public var candidateBuild: String

    public init(pack: Blob, candidateBuild: String) {
        self.pack = pack
        self.candidateBuild = candidateBuild
    }

    public static let modelName = "AcceptanceRequest"
    public static let schema = JSONSchema.object(properties: ["pack": Blob.schema, "candidateBuild": .hash], required: ["pack", "candidateBuild"])

    public func validate() throws { try pack.validate() }
}

/// Exactly one of file+suite, plan, or acceptance.
public struct QARequest: AuthorModel {
    public var file: String?
    public var suite: QASuite?
    public var plan: Blob?
    public var acceptance: AcceptanceRequest?

    public init(file: String, suite: QASuite) {
        self.file = file
        self.suite = suite
    }

    public init(plan: Blob) { self.plan = plan }
    public init(acceptance: AcceptanceRequest) { self.acceptance = acceptance }

    public static let modelName = "QARequest"
    public static let schema = JSONSchema.oneOf([
        .object(properties: ["file": .path, "suite": .enumeration(of: QASuite.self)], required: ["file", "suite"]),
        .object(properties: ["plan": Blob.schema], required: ["plan"]),
        .object(properties: ["acceptance": AcceptanceRequest.schema], required: ["acceptance"]),
    ], description: "Exactly one of {file,suite}, {plan} or {acceptance}")

    public func validate() throws {
        let forms = [(file != nil && suite != nil), plan != nil, acceptance != nil].filter { $0 }.count
        guard forms == 1, (file == nil) == (suite == nil) else {
            throw AuthorError.invalidRequest("QARequest must be exactly one of {file,suite}, {plan} or {acceptance}.", path: "/")
        }
        try plan?.validate()
        try acceptance?.validate()
    }
}

/// Model schemas addressable by `schema show NAME`.
public enum ModelSchemas {
    public static var byName: [String: JSONSchema] {
        [
            "Recipe": Recipe.schema, "TemplateRef": TemplateRef.schema,
            "ControlEdit": ControlEdit.schema, "ObjectEdit": ObjectEdit.schema, "ObjectKind": ObjectKind.schema,
            "Colour": Colour.schema, "Transform": Transform.schema, "Blob": Blob.schema, "Image": ImageSpec.schema,
            "HairItem": HairItem.schema, "HairControls": HairControls.schema, "HairTexture": HairTexture.schema,
            "OutfitItem": OutfitItem.schema, "OutfitControls": OutfitControls.schema, "AccessoryItem": AccessoryItem.schema,
            "Layer": TextureLayer.schema, "TextureLayer": TextureLayer.schema,
            "Material": MaterialObject.schema, "MaterialRole": MaterialRole.schema,
            "Expression": ExpressionObject.schema, "MorphTargetBind": MorphTargetBind.schema, "MaterialColorBind": MaterialColorBind.schema,
            "TextureTransformBind": TextureTransformBind.schema,
            "LookAt": LookAtObject.schema, "LookAtRangeMap": LookAtRangeMap.schema, "FirstPerson": FirstPersonObject.schema, "MeshAnnotation": MeshAnnotation.schema,
            "Spring": SpringObject.schema, "SpringJoint": SpringJoint.schema, "Collider": ColliderObject.schema, "ColliderShape": ColliderShape.schema,
            "ColliderGroup": ColliderGroupObject.schema,
            "RightsDeclaration": RightsDeclaration.schema, "VRMMeta": VRMMeta.schema, "TrainingClaims": TrainingClaims.schema, "TrainingClaim": TrainingClaim.schema,
            "AssetImport": AssetImport.schema, "Generation": Generation.schema,
            "Inspection": Inspection.schema, "InspectionScoring": InspectionScoring.schema, "QARequest": QARequest.schema, "AcceptanceRequest": AcceptanceRequest.schema,
            "Plan": ModelSchemas.plan, "ResultEnvelope": ModelSchemas.envelope, "ArtifactRef": ModelSchemas.artifactRef, "AuthorError": ModelSchemas.authorError,
        ]
    }

    public static let artifactRef = JSONSchema.object(properties: [
        "path": .string(), "sha256": .hash, "mediaType": .string(), "sizeBytes": .integer(minimum: 0), "role": .string(), "buildHash": .hash,
    ], required: ["path", "sha256", "mediaType", "sizeBytes", "role"])

    public static let authorError = JSONSchema.object(properties: [
        "code": .string(minLength: 1), "objectId": .string(), "path": .string(), "observed": .any(), "required": .any(),
        "message": .string(), "suggestedCommands": .array(of: .string()), "artifact": .string(),
    ], required: ["code", "message", "suggestedCommands"])

    public static let warning = JSONSchema.object(properties: ["code": .string(), "message": .string(), "path": .string()], required: ["code", "message"])

    public static let planEdit = JSONSchema.object(properties: [
        "objectId": .id, "pointer": .string(), "before": .any(), "after": .any(),
    ], required: ["objectId", "pointer"])

    public static let plan = JSONSchema.object(properties: [
        "planHash": .hash, "baseRevision": .integer(minimum: 0), "edits": .array(of: planEdit),
        "invalidations": .array(of: .string()), "prerequisites": .array(of: .string()), "cost": .any(),
    ], required: ["planHash", "baseRevision", "edits", "invalidations", "prerequisites", "cost"])

    public static let envelope = JSONSchema.object(properties: [
        "protocol": .const(.string(ResultEnvelope.protocolName)),
        "requestId": .oneOf([.string(), .null]),
        "status": .enumeration(["succeeded", "failed", "incomplete"]),
        "revisionBefore": .oneOf([.integer(minimum: 0), .null]),
        "revisionAfter": .oneOf([.integer(minimum: 0), .null]),
        "artifacts": .array(of: artifactRef),
        "warnings": .array(of: warning),
        "errors": .array(of: authorError),
        "plan": plan,
        "result": .any(),
    ], required: ["protocol", "requestId", "status", "revisionBefore", "revisionAfter", "artifacts", "warnings", "errors"])
}
