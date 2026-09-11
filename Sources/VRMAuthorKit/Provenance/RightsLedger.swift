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

extension AuthorErrorCode {
    public static let rightsConflict: AuthorErrorCode = "RIGHTS_CONFLICT"
    public static let bindingFailed: AuthorErrorCode = "BINDING_FAILED"
    public static let signatureInvalid: AuthorErrorCode = "SIGNATURE_INVALID"
    public static let untrustedSigner: AuthorErrorCode = "UNTRUSTED_SIGNER"
    public static let reportMismatch: AuthorErrorCode = "REPORT_MISMATCH"
}

/// One imported asset in the ingredient ledger.
public struct LedgerAsset: Codable, Hashable, Sendable {
    public var id: String
    public var kind: AssetKind
    public var sha256: String
    public var sizeBytes: Int
    public var sourceUri: String?
    public var generation: Generation?
    public var declaration: RightsDeclaration?
    public var importedAtRevision: Int
    public var preservation: PreservationReport?
    public var image: ImageFacts?
    public var credential: JSONValue
    public var manifestSha256: String?

    public static let idPrefixLength = 12
}

/// A stored rights declaration with the resolution it produced.
public struct LedgerDeclaration: Codable, Hashable, Sendable {
    public var declaration: RightsDeclaration
    public var resolution: RightsResolution
    public var resolvedAtRevision: Int
}

/// assets/ledger.json: content-addressed ingredient entries plus rights
/// declarations. Entries carry the revision that committed them so a ledger
/// written ahead of a revision that never committed is ignored on read.
public struct RightsLedger: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var assets: [LedgerAsset]
    public var declarations: [LedgerDeclaration]
    public var activeDeclaration: String?

    public init() {
        schemaVersion = 1
        assets = []
        declarations = []
        activeDeclaration = nil
    }

    public static let fileName = "ledger.json"

    public static func url(in store: ProjectStore) -> URL {
        store.root.appendingPathComponent("assets").appendingPathComponent(fileName)
    }

    public static func load(_ store: ProjectStore) throws -> RightsLedger {
        let url = url(in: store)
        guard FileManager.default.fileExists(atPath: url.path) else { return RightsLedger() }
        var ledger = try JSONValue.parse(try Data(contentsOf: url)).decode(RightsLedger.self)
        let current = try store.state().revision
        ledger.assets.removeAll { $0.importedAtRevision > current }
        ledger.declarations.removeAll { $0.resolvedAtRevision > current }
        if let active = ledger.activeDeclaration, !ledger.declarations.contains(where: { $0.declaration.id == active }) {
            ledger.activeDeclaration = ledger.declarations.last?.declaration.id
        }
        return ledger
    }

    public func write(_ store: ProjectStore) throws {
        try store.atomicWrite(try CanonicalJSON.data(try JSONValue.from(self)), to: RightsLedger.url(in: store))
    }

    public func asset(id: String) -> LedgerAsset? { assets.first { $0.id == id } }
    public func asset(sha256: String) -> LedgerAsset? { assets.first { $0.sha256 == sha256 } }
    public func declaration(id: String) -> LedgerDeclaration? { declarations.first { $0.declaration.id == id } }
    public var active: LedgerDeclaration? { activeDeclaration.flatMap { declaration(id: $0) } }

    /// Image IDs known to the ledger: imported raster assets.
    public var imageIds: Set<String> { Set(assets.filter { $0.kind == .png || $0.kind == .jpeg }.map(\.id)) }

    public mutating func upsert(_ asset: LedgerAsset) {
        assets.removeAll { $0.id == asset.id }
        assets.append(asset)
        assets.sort { CompiledAvatar.precedes($0.id, $1.id) }
    }

    public mutating func upsert(_ entry: LedgerDeclaration) {
        declarations.removeAll { $0.declaration.id == entry.declaration.id }
        declarations.append(entry)
        activeDeclaration = entry.declaration.id
    }

    /// A unique `asset:<sha256 prefix>` id; the prefix grows only on a prefix collision with different bytes.
    public func assetId(for sha256: String) -> String {
        var length = LedgerAsset.idPrefixLength
        while length <= sha256.count {
            let candidate = "asset:" + sha256.prefix(length)
            if let existing = asset(id: candidate), existing.sha256 != sha256 { length += 4; continue }
            return candidate
        }
        return "asset:" + sha256
    }

    /// Pointers that object editing must refuse: VRM meta, rights and training
    /// claims are only edited through `provenance resolve` or the Recipe.
    public static func isRightsPointer(_ pointer: JSONPointer) -> Bool {
        guard let first = pointer.tokens.first else { return false }
        return ["meta", "rights", "training"].contains(first)
    }

    public static func isRightsPointer(_ pointer: String) -> Bool {
        guard let parsed = try? JSONPointer(pointer) else { return false }
        return isRightsPointer(parsed)
    }

    /// Ingredient graph entries for `provenance inspect` and the sidecar claim.
    public func ingredientEntries() throws -> [JSONValue] {
        try assets.map { asset in
            var entry: [String: JSONValue] = [
                "id": .string(asset.id), "kind": .string(asset.kind.rawValue), "sha256": .string(asset.sha256),
                "sizeBytes": .number(Double(asset.sizeBytes)), "importedAtRevision": .number(Double(asset.importedAtRevision)),
                "credential": asset.credential,
            ]
            if let uri = asset.sourceUri { entry["sourceUri"] = .string(uri) }
            if let generation = asset.generation { entry["generation"] = try JSONValue.from(generation) }
            if let declaration = asset.declaration { entry["declaration"] = ["id": .string(declaration.id), "declarant": .string(declaration.declarant), "authors": JSONValue(declaration.authors)] }
            if let manifest = asset.manifestSha256 { entry["manifestSha256"] = .string(manifest) }
            return .object(entry)
        }
    }
}
