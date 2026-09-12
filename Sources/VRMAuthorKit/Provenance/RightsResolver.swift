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

/// Which source assertion produced one output meta field.
public struct FieldAttribution: Codable, Hashable, Sendable {
    public var field: String
    public var value: JSONValue
    public var source: String
    public var declarant: String
    public var evidence: [String]

    public init(field: String, value: JSONValue, source: String, declarant: String, evidence: [String]) {
        self.field = field
        self.value = value
        self.source = source
        self.declarant = declarant
        self.evidence = evidence
    }
}

public struct RightsConflict: Codable, Hashable, Sendable {
    public var code: String
    public var path: String
    public var message: String
    public var observed: JSONValue?
    public var required: JSONValue?

    public init(code: String, path: String, message: String, observed: JSONValue? = nil, required: JSONValue? = nil) {
        self.code = code
        self.path = path
        self.message = message
        self.observed = observed
        self.required = required
    }

    public var authorError: AuthorError {
        AuthorError(code: .rightsConflict, path: path, observed: observed, required: required, message: "\(code): \(message)",
                    suggestedCommands: ["provenance resolve", "provenance inspect"])
    }
}

public struct RightsResolution: Codable, Hashable, Sendable {
    public var meta: VRMMeta
    public var attributions: [FieldAttribution]
    public var conflicts: [RightsConflict]

    public init(meta: VRMMeta, attributions: [FieldAttribution], conflicts: [RightsConflict]) {
        self.meta = meta
        self.attributions = attributions
        self.conflicts = conflicts
    }

    public var isClean: Bool { conflicts.isEmpty }
}

/// Field-by-field attribution of VRM meta from a rights declaration, with
/// conflict detection against the evidence files and the ingredient ledger.
/// A signing identity is never an author; training claims never set usage rights.
public struct RightsResolver: Sendable {
    public var baseURL: URL
    public var knownImageIds: Set<String>
    public var ledger: RightsLedger

    public init(baseURL: URL, knownImageIds: Set<String> = [], ledger: RightsLedger = RightsLedger()) {
        self.baseURL = baseURL
        self.knownImageIds = knownImageIds
        self.ledger = ledger
    }

    public static let metaFields = [
        "name", "version", "authors", "copyrightInformation", "contactInformation", "references", "thirdPartyLicenses", "thumbnailImage",
        "licenseUrl", "avatarPermission", "allowExcessivelyViolentUsage", "allowExcessivelySexualUsage", "commercialUsage",
        "allowPoliticalOrReligiousUsage", "allowAntisocialOrHateUsage", "creditNotation", "allowRedistribution", "modification", "otherLicenseUrl",
    ]

    /// Schema validation and defaults without the model's `validate()`, so an
    /// authors mismatch surfaces as a conflict instead of a single thrown error.
    public static func decodeDeclaration(_ json: JSONValue) throws -> RightsDeclaration {
        let violations = RightsDeclaration.schema.validate(json)
        if !violations.isEmpty { throw ModelValidationError(errors: violations.map { $0.authorError }) }
        do {
            return try RightsDeclaration.schema.applyingDefaults(to: json).decode(RightsDeclaration.self)
        } catch {
            throw ModelValidationError(errors: [AuthorError.invalidRequest("RightsDeclaration could not be decoded: \(error)", path: "/declaration")])
        }
    }

    public func resolve(_ declaration: RightsDeclaration) throws -> RightsResolution {
        var conflicts: [RightsConflict] = []
        let metaJSON = try JSONValue.from(declaration.meta)
        var evidenceHashes: [String] = []

        for (index, blob) in declaration.evidence.enumerated() {
            let path = "/evidence/\(index)"
            guard SHA256Hex.isValid(blob.sha256) else {
                conflicts.append(RightsConflict(code: "EVIDENCE_HASH_INVALID", path: "\(path)/sha256", message: "Evidence sha256 must be 64 lowercase hex characters.", observed: .string(blob.sha256)))
                continue
            }
            let url = URL(fileURLWithPath: blob.path, relativeTo: baseURL).standardizedFileURL
            guard let data = try? Data(contentsOf: url) else {
                conflicts.append(RightsConflict(code: "EVIDENCE_MISSING", path: "\(path)/path", message: "Evidence file '\(blob.path)' was not found.", observed: .string(blob.path)))
                continue
            }
            let observed = SHA256Hex.hex(data)
            if observed != blob.sha256 {
                conflicts.append(RightsConflict(code: "EVIDENCE_HASH_MISMATCH", path: "\(path)/sha256", message: "Evidence file '\(blob.path)' does not match its declared sha256.",
                                                observed: .string(observed), required: .string(blob.sha256)))
                continue
            }
            evidenceHashes.append(blob.sha256)
        }

        if declaration.authors != declaration.meta.authors {
            conflicts.append(RightsConflict(code: "AUTHORS_MISMATCH", path: "/authors", message: "Declaration authors must equal meta.authors.",
                                            observed: JSONValue(declaration.authors), required: JSONValue(declaration.meta.authors)))
        }
        if declaration.meta.authors.isEmpty {
            conflicts.append(RightsConflict(code: "AUTHORS_EMPTY", path: "/meta/authors", message: "meta.authors must name at least one author."))
        }
        if declaration.meta.licenseUrl != VRMMeta.vrm10LicenseUrl {
            conflicts.append(RightsConflict(code: "LICENSE_URL_INVALID", path: "/meta/licenseUrl", message: "VRMC_vrm 1.0 meta.licenseUrl must be the VRM 1.0 license URL.",
                                            observed: .string(declaration.meta.licenseUrl), required: .string(VRMMeta.vrm10LicenseUrl)))
        }
        if let thumbnail = declaration.meta.thumbnailImage, !knownImageIds.contains(thumbnail) {
            conflicts.append(RightsConflict(code: "THUMBNAIL_UNKNOWN_IMAGE", path: "/meta/thumbnailImage", message: "thumbnailImage must be a known image ID.",
                                            observed: .string(thumbnail), required: JSONValue(knownImageIds.sorted())))
        }
        for (index, reference) in (declaration.meta.references ?? []).enumerated() where reference.hasPrefix("image:") || reference.hasPrefix("asset:") {
            if !knownImageIds.contains(reference) {
                conflicts.append(RightsConflict(code: "REFERENCE_UNKNOWN_IMAGE", path: "/meta/references/\(index)", message: "Reference names an image ID that is not in the project.",
                                                observed: .string(reference), required: JSONValue(knownImageIds.sorted())))
            }
        }
        if let training = declaration.training {
            for (key, claim) in [("cawg.data_mining", training.dataMining), ("cawg.ai_inference", training.aiInference), ("cawg.ai_training", training.aiTraining), ("cawg.ai_generative_training", training.aiGenerativeTraining)] {
                if let claim, claim.use == .constrained, (claim.constraintInfo ?? "").isEmpty {
                    conflicts.append(RightsConflict(code: "TRAINING_CONSTRAINT_MISSING", path: "/training/\(key)/constraint_info", message: "A constrained training use must state its constraint."))
                }
            }
        }

        conflicts += ledgerConflicts(for: declaration)

        var attributions: [FieldAttribution] = []
        let source = "declaration:\(declaration.id)"
        for field in RightsResolver.metaFields {
            guard let value = metaJSON[field], !value.isNull else { continue }
            attributions.append(FieldAttribution(field: "/meta/\(field)", value: value, source: source, declarant: declaration.declarant,
                                                 evidence: ["authors", "copyrightInformation", "licenseUrl", "thirdPartyLicenses"].contains(field) ? evidenceHashes : []))
        }
        if let training = declaration.training {
            attributions.append(FieldAttribution(field: "/training", value: training.cawgAssertion, source: source, declarant: declaration.declarant, evidence: evidenceHashes))
        }
        return RightsResolution(meta: declaration.meta, attributions: attributions, conflicts: conflicts)
    }

    private static let commercialRank: [CommercialUsage: Int] = [.personalNonProfit: 0, .personalProfit: 1, .corporation: 2]
    private static let permissionRank: [AvatarPermission: Int] = [.onlyAuthor: 0, .onlySeparatelyLicensedPerson: 1, .everyone: 2]

    /// Contradictory duplicates and incompatible ingredient terms already in the ledger.
    func ledgerConflicts(for declaration: RightsDeclaration) -> [RightsConflict] {
        var conflicts: [RightsConflict] = []
        for asset in ledger.assets {
            guard let ingredient = asset.declaration else { continue }
            let path = "/ledger/\(asset.id)/declaration"
            if ingredient.id == declaration.id, ingredient != declaration {
                conflicts.append(RightsConflict(code: "LEDGER_CONTRADICTION", path: path, message: "Ingredient '\(asset.id)' carries declaration '\(ingredient.id)' with different content.",
                                                observed: JSONValue(ingredient.authors), required: JSONValue(declaration.authors)))
                continue
            }
            let terms = ingredient.meta
            if terms.modification == .prohibited {
                conflicts.append(RightsConflict(code: "INGREDIENT_MODIFICATION_PROHIBITED", path: "\(path)/meta/modification",
                                                message: "Ingredient '\(asset.id)' prohibits modification; it cannot be built into a derivative avatar.", observed: "prohibited"))
            }
            if declaration.meta.allowRedistribution, !terms.allowRedistribution {
                conflicts.append(RightsConflict(code: "INGREDIENT_REDISTRIBUTION", path: "\(path)/meta/allowRedistribution",
                                                message: "Ingredient '\(asset.id)' forbids redistribution but the avatar allows it.", observed: false, required: true))
            }
            if declaration.meta.allowRedistribution, terms.modification != .allowModificationRedistribution {
                conflicts.append(RightsConflict(code: "INGREDIENT_MODIFIED_REDISTRIBUTION", path: "\(path)/meta/modification",
                                                message: "Ingredient '\(asset.id)' does not permit redistributing modifications.", observed: .string(terms.modification.rawValue),
                                                required: .string(ModificationPermission.allowModificationRedistribution.rawValue)))
            }
            if RightsResolver.commercialRank[declaration.meta.commercialUsage]! > RightsResolver.commercialRank[terms.commercialUsage]! {
                conflicts.append(RightsConflict(code: "INGREDIENT_COMMERCIAL_USAGE", path: "\(path)/meta/commercialUsage",
                                                message: "Ingredient '\(asset.id)' permits narrower commercial usage than the avatar declares.",
                                                observed: .string(terms.commercialUsage.rawValue), required: .string(declaration.meta.commercialUsage.rawValue)))
            }
            if RightsResolver.permissionRank[declaration.meta.avatarPermission]! > RightsResolver.permissionRank[terms.avatarPermission]! {
                conflicts.append(RightsConflict(code: "INGREDIENT_AVATAR_PERMISSION", path: "\(path)/meta/avatarPermission",
                                                message: "Ingredient '\(asset.id)' permits narrower avatar use than the avatar declares.",
                                                observed: .string(terms.avatarPermission.rawValue), required: .string(declaration.meta.avatarPermission.rawValue)))
            }
            for (flag, mine, theirs) in [("allowExcessivelyViolentUsage", declaration.meta.allowExcessivelyViolentUsage, terms.allowExcessivelyViolentUsage),
                                         ("allowExcessivelySexualUsage", declaration.meta.allowExcessivelySexualUsage, terms.allowExcessivelySexualUsage),
                                         ("allowPoliticalOrReligiousUsage", declaration.meta.allowPoliticalOrReligiousUsage, terms.allowPoliticalOrReligiousUsage),
                                         ("allowAntisocialOrHateUsage", declaration.meta.allowAntisocialOrHateUsage, terms.allowAntisocialOrHateUsage)] where mine && !theirs {
                conflicts.append(RightsConflict(code: "INGREDIENT_USAGE_FLAG", path: "\(path)/meta/\(flag)", message: "Ingredient '\(asset.id)' does not allow \(flag).", observed: false, required: true))
            }
            if terms.creditNotation == .required, declaration.meta.creditNotation == .unnecessary, !ingredient.authors.allSatisfy({ declaration.meta.authors.contains($0) }) {
                conflicts.append(RightsConflict(code: "INGREDIENT_CREDIT_REQUIRED", path: "\(path)/meta/creditNotation",
                                                message: "Ingredient '\(asset.id)' requires credit; its authors must be credited or the avatar must require credit notation.",
                                                observed: "unnecessary", required: "required"))
            }
        }
        for stored in ledger.declarations where stored.declaration.id != declaration.id {
            let other = stored.declaration
            if other.meta.name == declaration.meta.name, other.meta.version == declaration.meta.version, other != declaration {
                conflicts.append(RightsConflict(code: "LEDGER_CONTRADICTION", path: "/ledger/declarations/\(other.id)",
                                                message: "Declaration '\(other.id)' already describes '\(other.meta.name)' with different terms; update it instead of adding a duplicate.",
                                                observed: JSONValue(other.authors), required: JSONValue(declaration.authors)))
            }
        }
        return conflicts
    }
}

extension TrainingClaims {
    /// The CAWG training-and-data-mining assertion payload: only declared
    /// entries appear, so an omitted entry stays absent rather than "allowed".
    public var cawgAssertion: JSONValue {
        var entries: [String: JSONValue] = [:]
        for (key, claim) in [("cawg.data_mining", dataMining), ("cawg.ai_inference", aiInference), ("cawg.ai_training", aiTraining), ("cawg.ai_generative_training", aiGenerativeTraining)] {
            guard let claim else { continue }
            var entry: [String: JSONValue] = ["use": .string(claim.use.rawValue)]
            if let info = claim.constraintInfo { entry["constraint_info"] = .string(info) }
            entries[key] = .object(entry)
        }
        return ["entries": .object(entries)]
    }
}
