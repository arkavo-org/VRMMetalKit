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

public enum AvatarPermission: String, Codable, Hashable, Sendable, CaseIterable { case onlyAuthor, onlySeparatelyLicensedPerson, everyone }
public enum CommercialUsage: String, Codable, Hashable, Sendable, CaseIterable { case personalNonProfit, personalProfit, corporation }
public enum CreditNotation: String, Codable, Hashable, Sendable, CaseIterable { case required, unnecessary }
public enum ModificationPermission: String, Codable, Hashable, Sendable, CaseIterable { case prohibited, allowModification, allowModificationRedistribution }

/// All VRMC_vrm 1.0 meta fields; `thumbnailImage` is an image ID.
public struct VRMMeta: AuthorModel {
    public var name: String
    public var version: String?
    public var authors: [String]
    public var copyrightInformation: String?
    public var contactInformation: String?
    public var references: [String]?
    public var thirdPartyLicenses: String?
    public var thumbnailImage: String?
    public var licenseUrl: String
    public var avatarPermission: AvatarPermission
    public var allowExcessivelyViolentUsage: Bool
    public var allowExcessivelySexualUsage: Bool
    public var commercialUsage: CommercialUsage
    public var allowPoliticalOrReligiousUsage: Bool
    public var allowAntisocialOrHateUsage: Bool
    public var creditNotation: CreditNotation
    public var allowRedistribution: Bool
    public var modification: ModificationPermission
    public var otherLicenseUrl: String?

    public static let vrm10LicenseUrl = "https://vrm.dev/licenses/1.0/"

    public init(name: String, version: String? = nil, authors: [String], copyrightInformation: String? = nil, contactInformation: String? = nil,
                references: [String]? = nil, thirdPartyLicenses: String? = nil, thumbnailImage: String? = nil, licenseUrl: String = VRMMeta.vrm10LicenseUrl,
                avatarPermission: AvatarPermission = .onlyAuthor, allowExcessivelyViolentUsage: Bool = false, allowExcessivelySexualUsage: Bool = false,
                commercialUsage: CommercialUsage = .personalNonProfit, allowPoliticalOrReligiousUsage: Bool = false, allowAntisocialOrHateUsage: Bool = false,
                creditNotation: CreditNotation = .required, allowRedistribution: Bool = false, modification: ModificationPermission = .prohibited,
                otherLicenseUrl: String? = nil) {
        self.name = name
        self.version = version
        self.authors = authors
        self.copyrightInformation = copyrightInformation
        self.contactInformation = contactInformation
        self.references = references
        self.thirdPartyLicenses = thirdPartyLicenses
        self.thumbnailImage = thumbnailImage
        self.licenseUrl = licenseUrl
        self.avatarPermission = avatarPermission
        self.allowExcessivelyViolentUsage = allowExcessivelyViolentUsage
        self.allowExcessivelySexualUsage = allowExcessivelySexualUsage
        self.commercialUsage = commercialUsage
        self.allowPoliticalOrReligiousUsage = allowPoliticalOrReligiousUsage
        self.allowAntisocialOrHateUsage = allowAntisocialOrHateUsage
        self.creditNotation = creditNotation
        self.allowRedistribution = allowRedistribution
        self.modification = modification
        self.otherLicenseUrl = otherLicenseUrl
    }

    public static let modelName = "VRMMeta"
    public static let schema = JSONSchema.object(properties: [
        "name": .string(minLength: 1),
        "version": .string(),
        "authors": .array(of: .string(minLength: 1), minItems: 1),
        "copyrightInformation": .string(),
        "contactInformation": .string(),
        "references": .array(of: .string()),
        "thirdPartyLicenses": .string(),
        "thumbnailImage": .id.described("Image ID; exported as an image index"),
        "licenseUrl": .string(minLength: 1).defaulting(to: .string(VRMMeta.vrm10LicenseUrl)),
        "avatarPermission": .enumeration(AvatarPermission.allCases.map(\.rawValue)).defaulting(to: "onlyAuthor"),
        "allowExcessivelyViolentUsage": .boolean().defaulting(to: false),
        "allowExcessivelySexualUsage": .boolean().defaulting(to: false),
        "commercialUsage": .enumeration(CommercialUsage.allCases.map(\.rawValue)).defaulting(to: "personalNonProfit"),
        "allowPoliticalOrReligiousUsage": .boolean().defaulting(to: false),
        "allowAntisocialOrHateUsage": .boolean().defaulting(to: false),
        "creditNotation": .enumeration(CreditNotation.allCases.map(\.rawValue)).defaulting(to: "required"),
        "allowRedistribution": .boolean().defaulting(to: false),
        "modification": .enumeration(ModificationPermission.allCases.map(\.rawValue)).defaulting(to: "prohibited"),
        "otherLicenseUrl": .string(),
    ], required: ["name", "authors"], description: "VRMC_vrm 1.0 meta; licenseUrl defaults to the VRM 1.0 license")

    public func validate() throws {
        guard !authors.isEmpty else { throw AuthorError.invalidRequest("meta.authors must not be empty.", path: "/authors") }
        guard !licenseUrl.isEmpty else { throw AuthorError.invalidRequest("meta.licenseUrl must not be empty.", path: "/licenseUrl") }
    }
}

public enum TrainingUse: String, Codable, Hashable, Sendable, CaseIterable { case allowed, notAllowed, constrained }

public struct TrainingClaim: AuthorModel {
    public var use: TrainingUse
    public var constraintInfo: String?

    public init(use: TrainingUse, constraintInfo: String? = nil) {
        self.use = use
        self.constraintInfo = constraintInfo
    }

    enum CodingKeys: String, CodingKey {
        case use
        case constraintInfo = "constraint_info"
    }

    public static let modelName = "TrainingClaim"
    public static let schema = JSONSchema.object(properties: [
        "use": .enumeration(TrainingUse.allCases.map(\.rawValue)), "constraint_info": .string(),
    ], required: ["use"])

    public func validate() throws {
        if use == .constrained, constraintInfo == nil {
            throw AuthorError.invalidRequest("constrained use requires constraint_info.", path: "/constraint_info")
        }
    }
}

/// The four CAWG training-and-data-mining entries. Omission is absence, not permission.
public struct TrainingClaims: AuthorModel {
    public var dataMining: TrainingClaim?
    public var aiInference: TrainingClaim?
    public var aiTraining: TrainingClaim?
    public var aiGenerativeTraining: TrainingClaim?

    public init(dataMining: TrainingClaim? = nil, aiInference: TrainingClaim? = nil, aiTraining: TrainingClaim? = nil, aiGenerativeTraining: TrainingClaim? = nil) {
        self.dataMining = dataMining
        self.aiInference = aiInference
        self.aiTraining = aiTraining
        self.aiGenerativeTraining = aiGenerativeTraining
    }

    enum CodingKeys: String, CodingKey {
        case dataMining = "cawg.data_mining"
        case aiInference = "cawg.ai_inference"
        case aiTraining = "cawg.ai_training"
        case aiGenerativeTraining = "cawg.ai_generative_training"
    }

    public static let entryKeys = ["cawg.data_mining", "cawg.ai_inference", "cawg.ai_training", "cawg.ai_generative_training"]
    public static let modelName = "TrainingClaims"
    public static let schema = JSONSchema.object(properties: [
        "cawg.data_mining": TrainingClaim.schema,
        "cawg.ai_inference": TrainingClaim.schema,
        "cawg.ai_training": TrainingClaim.schema,
        "cawg.ai_generative_training": TrainingClaim.schema,
    ], required: [], description: "CAWG training and data mining assertion entries")

    public func validate() throws {
        for c in [dataMining, aiInference, aiTraining, aiGenerativeTraining] { try c?.validate() }
    }
}

public struct RightsDeclaration: AuthorModel {
    public var id: String
    public var declarant: String
    public var evidence: [Blob]
    public var authors: [String]
    public var meta: VRMMeta
    public var training: TrainingClaims?

    public init(id: String, declarant: String, evidence: [Blob], authors: [String], meta: VRMMeta, training: TrainingClaims? = nil) {
        self.id = id
        self.declarant = declarant
        self.evidence = evidence
        self.authors = authors
        self.meta = meta
        self.training = training
    }

    public static let modelName = "RightsDeclaration"
    public static let schema = JSONSchema.object(properties: [
        "id": .string(minLength: 1),
        "declarant": .string(minLength: 1),
        "evidence": .array(of: Blob.schema),
        "authors": .array(of: .string(minLength: 1), minItems: 1),
        "meta": VRMMeta.schema,
        "training": TrainingClaims.schema,
    ], required: ["id", "declarant", "evidence", "authors", "meta"], description: "Rights ledger entry; authors must match meta.authors")

    public func validate() throws {
        for e in evidence { try e.validate() }
        try meta.validate()
        try training?.validate()
        guard authors == meta.authors else {
            throw AuthorError(code: .validationFailed, path: "/authors", observed: JSONValue(authors), required: JSONValue(meta.authors),
                              message: "Declaration authors must match the resolved meta authors.", suggestedCommands: ["provenance resolve"])
        }
    }
}

public struct Generation: AuthorModel {
    public var tool: String
    public var model: String?
    public var version: String
    public var inputHashes: [String]
    public var action: String
    public var digitalSourceType: String?
    public var record: Blob?

    public init(tool: String, model: String? = nil, version: String, inputHashes: [String] = [], action: String, digitalSourceType: String? = nil, record: Blob? = nil) {
        self.tool = tool
        self.model = model
        self.version = version
        self.inputHashes = inputHashes
        self.action = action
        self.digitalSourceType = digitalSourceType
        self.record = record
    }

    public static let modelName = "Generation"
    public static let schema = JSONSchema.object(properties: [
        "tool": .string(minLength: 1),
        "model": .string(),
        "version": .string(minLength: 1),
        "inputHashes": .array(of: .hash).defaulting(to: []),
        "action": .string(minLength: 1),
        "digitalSourceType": .string(),
        "record": Blob.schema,
    ], required: ["tool", "version", "action"], description: "Known generation facts for an imported asset")

    public func validate() throws { try record?.validate() }
}

public enum AssetKind: String, Codable, Hashable, Sendable, CaseIterable { case vrm, gltf, png, jpeg }

public struct AssetImport: AuthorModel {
    public var path: String
    public var kind: AssetKind
    public var manifestPath: String?
    public var sourceUri: String?
    public var generation: Generation?
    public var declaration: RightsDeclaration?

    public init(path: String, kind: AssetKind, manifestPath: String? = nil, sourceUri: String? = nil, generation: Generation? = nil, declaration: RightsDeclaration? = nil) {
        self.path = path
        self.kind = kind
        self.manifestPath = manifestPath
        self.sourceUri = sourceUri
        self.generation = generation
        self.declaration = declaration
    }

    public static let modelName = "AssetImport"
    public static let schema = JSONSchema.object(properties: [
        "path": .path,
        "kind": .enumeration(AssetKind.allCases.map(\.rawValue)),
        "manifestPath": .path,
        "sourceUri": .string(),
        "generation": Generation.schema,
        "declaration": RightsDeclaration.schema,
    ], required: ["path", "kind"], description: "Hashed import of an external asset")

    public func validate() throws {
        try generation?.validate()
        try declaration?.validate()
    }
}
