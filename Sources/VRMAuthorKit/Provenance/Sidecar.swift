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

import CryptoKit
import Foundation

/// The detached credential written next to a delivered VRM. This is the
/// "c2pa-lite" sidecar: C2PA-shaped field names over canonical JSON with an
/// Ed25519 signature. It is not a COSE/JUMBF C2PA manifest and must not be
/// presented as one.
public enum Sidecar {
    public static let format = "vrm-author-sidecar/1"
    public static let algorithm = "Ed25519"
    public static let suffix = ".c2pa.json"

    public static func url(for asset: URL) -> URL {
        URL(fileURLWithPath: asset.path + suffix)
    }

    public struct Claim: Codable, Hashable, Sendable {
        public var assetSha256: String
        public var assetSizeBytes: Int
        public var generator: String
        public var createdAtRevision: Int
        public var buildHash: String?
        public var ingredients: [JSONValue]
        public var training: JSONValue?
        public var actions: [JSONValue]

        public init(assetSha256: String, assetSizeBytes: Int, generator: String, createdAtRevision: Int, buildHash: String?, ingredients: [JSONValue],
                    training: JSONValue?, actions: [JSONValue]) {
            self.assetSha256 = assetSha256
            self.assetSizeBytes = assetSizeBytes
            self.generator = generator
            self.createdAtRevision = createdAtRevision
            self.buildHash = buildHash
            self.ingredients = ingredients
            self.training = training
            self.actions = actions
        }

        enum CodingKeys: String, CodingKey { case assetSha256, assetSizeBytes, generator, createdAtRevision, buildHash, ingredients, training, actions }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(assetSha256, forKey: .assetSha256)
            try c.encode(assetSizeBytes, forKey: .assetSizeBytes)
            try c.encode(generator, forKey: .generator)
            try c.encode(createdAtRevision, forKey: .createdAtRevision)
            try c.encode(buildHash, forKey: .buildHash)
            try c.encode(ingredients, forKey: .ingredients)
            try c.encode(training, forKey: .training)
            try c.encode(actions, forKey: .actions)
        }

        public func canonicalData() throws -> Data { try CanonicalJSON.data(try JSONValue.from(self)) }
    }

    public struct Signature: Codable, Hashable, Sendable {
        public var algorithm: String
        public var publicKey: String
        public var signer: String
        public var value: String

        public init(algorithm: String = Sidecar.algorithm, publicKey: String, signer: String, value: String) {
            self.algorithm = algorithm
            self.publicKey = publicKey
            self.signer = signer
            self.value = value
        }
    }

    public struct Document: Codable, Hashable, Sendable {
        public var format: String
        public var claim: Claim
        public var signature: Signature

        public init(claim: Claim, signature: Signature) {
            self.format = Sidecar.format
            self.claim = claim
            self.signature = signature
        }

        public func canonicalData() throws -> Data { try CanonicalJSON.data(try JSONValue.from(self)) }

        public static func parse(_ data: Data, path: String) throws -> Document {
            let json: JSONValue
            do { json = try JSONValue.parse(data) } catch {
                throw AuthorError(code: .validationFailed, path: path, message: "Sidecar is not valid JSON: \(error)", suggestedCommands: ["provenance verify"])
            }
            guard json["format"]?.string == Sidecar.format else {
                throw AuthorError(code: .validationFailed, path: path, observed: json["format"] ?? .null, required: .string(Sidecar.format),
                                  message: "Sidecar format is not \(Sidecar.format); embedded COSE/JUMBF C2PA manifests are not parsed by this tool.", suggestedCommands: ["provenance verify"])
            }
            do { return try json.decode(Document.self) } catch {
                throw AuthorError(code: .validationFailed, path: path, message: "Sidecar claim/signature could not be decoded: \(error)", suggestedCommands: ["provenance verify"])
            }
        }
    }
}

/// Configured signer credentials: names mapped to public keys and optional
/// private key file paths, plus the trusted signer list. Signer references in
/// requests are names, never key material.
public struct TrustPolicy: Sendable {
    public struct Signer: Sendable, Hashable {
        public var name: String
        public var publicKey: String
        public var privateKeyPath: String?
    }

    public var signers: [String: Signer]
    public var trusted: Set<String>
    public var url: URL
    public var sha256: String

    public static func load(_ url: URL) throws -> TrustPolicy {
        guard let data = try? Data(contentsOf: url) else {
            throw AuthorError(code: .missingInput, path: "/trustPolicy/path", observed: .string(url.path), message: "Trust policy file not found.", suggestedCommands: ["doctor"])
        }
        let json: JSONValue
        do { json = try JSONValue.parse(data) } catch {
            throw AuthorError(code: .validationFailed, path: "/trustPolicy/path", message: "Trust policy is not valid JSON: \(error)")
        }
        var signers: [String: Signer] = [:]
        for (name, entry) in json["signers"]?.object ?? [:] {
            guard let publicKey = entry["publicKey"]?.string else {
                throw AuthorError(code: .validationFailed, path: "/trustPolicy/signers/\(name)/publicKey", message: "Signer '\(name)' has no publicKey.")
            }
            signers[name] = Signer(name: name, publicKey: publicKey, privateKeyPath: entry["privateKeyPath"]?.string)
        }
        let trusted = Set((json["trusted"]?.array ?? []).compactMap(\.string))
        return TrustPolicy(signers: signers, trusted: trusted, url: url, sha256: SHA256Hex.hex(data))
    }

    /// Loads a hash-pinned trust policy Blob relative to `base`.
    public static func load(blob: Blob, relativeTo base: URL) throws -> TrustPolicy {
        let url = URL(fileURLWithPath: blob.path, relativeTo: base).standardizedFileURL
        let policy = try load(url)
        guard policy.sha256 == blob.sha256 else {
            throw AuthorError(code: .validationFailed, path: "/trustPolicy/sha256", observed: .string(policy.sha256), required: .string(blob.sha256),
                              message: "Trust policy bytes do not match the pinned sha256.", suggestedCommands: ["provenance verify"])
        }
        return policy
    }

    public func privateKeyURL(for signer: String) -> URL? {
        guard let path = signers[signer]?.privateKeyPath else { return nil }
        return URL(fileURLWithPath: path, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
    }
}

/// Loads an Ed25519 private key named by a signer string and signs claims.
public struct SidecarSigner: Sendable {
    public var signer: String
    public var privateKey: Curve25519.Signing.PrivateKey

    public var publicKeyBase64: String { privateKey.publicKey.rawRepresentation.base64EncodedString() }

    /// Key file: 32 raw bytes, or base64/hex text of those bytes.
    public static func loadPrivateKey(_ url: URL) throws -> Curve25519.Signing.PrivateKey {
        guard let data = try? Data(contentsOf: url) else {
            throw AuthorError(code: .missingCredential, path: url.path, message: "Signer private key file not found.", suggestedCommands: ["doctor"])
        }
        if data.count == 32, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) { return key }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw = Data(base64Encoded: text), raw.count == 32, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) { return key }
        if text.count == 64, let raw = Data(hex: text), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) { return key }
        throw AuthorError(code: .missingCredential, path: url.path, message: "Signer private key file is not a 32-byte Ed25519 key (raw, base64 or hex).", suggestedCommands: ["doctor"])
    }

    /// Resolves `signer` through the trust policy. Unknown signer or no
    /// private key → MISSING_CREDENTIAL; public key mismatch → VALIDATION_FAILED.
    public init(signer: String, policy: TrustPolicy) throws {
        guard let entry = policy.signers[signer] else {
            throw AuthorError(code: .missingCredential, path: "/signer", observed: .string(signer), required: JSONValue(policy.signers.keys.sorted()),
                              message: "Signer '\(signer)' is not configured in the trust policy.", suggestedCommands: ["doctor"])
        }
        guard let keyURL = policy.privateKeyURL(for: signer) else {
            throw AuthorError(code: .missingCredential, path: "/signer", observed: .string(signer), message: "Signer '\(signer)' has no privateKeyPath configured; signing is unavailable.",
                              suggestedCommands: ["doctor"])
        }
        let key = try SidecarSigner.loadPrivateKey(keyURL)
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        guard publicKey == entry.publicKey else {
            throw AuthorError(code: .validationFailed, path: "/signer", observed: .string(publicKey), required: .string(entry.publicKey),
                              message: "Private key for signer '\(signer)' does not match the trust policy public key.", suggestedCommands: ["doctor"])
        }
        self.signer = signer
        self.privateKey = key
    }

    public init(signer: String, privateKey: Curve25519.Signing.PrivateKey) {
        self.signer = signer
        self.privateKey = privateKey
    }

    public func sign(_ claim: Sidecar.Claim) throws -> Sidecar.Document {
        let signature = try privateKey.signature(for: try claim.canonicalData())
        return Sidecar.Document(claim: claim, signature: Sidecar.Signature(publicKey: publicKeyBase64, signer: signer, value: signature.base64EncodedString()))
    }
}

/// Binding, signature and trust are reported separately; the verdict is the
/// conjunction. Trust is `pending` when no policy was supplied.
public struct SidecarVerification: Codable, Hashable, Sendable {
    public var binding: JSONValue
    public var signature: JSONValue
    public var trust: JSONValue
    public var verdict: String
    public var errors: [AuthorError]

    public var isValid: Bool { verdict == "pass" }

    public static func verify(document: Sidecar.Document, assetData: Data, policy: TrustPolicy?, manifestPath: String) -> SidecarVerification {
        var errors: [AuthorError] = []
        let observed = SHA256Hex.hex(assetData)
        let bindingPass = observed == document.claim.assetSha256 && assetData.count == document.claim.assetSizeBytes
        var binding: [String: JSONValue] = [
            "status": bindingPass ? "pass" : "fail", "algorithm": "sha256", "expectedSha256": .string(document.claim.assetSha256), "observedSha256": .string(observed),
            "expectedSizeBytes": .number(Double(document.claim.assetSizeBytes)), "observedSizeBytes": .number(Double(assetData.count)),
        ]
        if !bindingPass {
            let reason = assetData.count == document.claim.assetSizeBytes ? "asset bytes differ from the bound sha256 (tampered file or stale manifest)"
                : "asset size differs from the manifest (stale manifest for different bytes)"
            binding["reason"] = .string(reason)
            errors.append(AuthorError(code: .bindingFailed, path: manifestPath, observed: .string(observed), required: .string(document.claim.assetSha256),
                                      message: "Manifest does not bind these asset bytes: \(reason).", suggestedCommands: ["deliver"], artifact: manifestPath))
        }

        var signature: [String: JSONValue] = ["status": "fail", "algorithm": .string(document.signature.algorithm), "publicKey": .string(document.signature.publicKey), "signer": .string(document.signature.signer)]
        var signaturePass = false
        if document.signature.algorithm != Sidecar.algorithm {
            signature["reason"] = .string("unsupported algorithm")
        } else if let keyData = Data(base64Encoded: document.signature.publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
                  let sig = Data(base64Encoded: document.signature.value), let message = try? document.claim.canonicalData() {
            signaturePass = key.isValidSignature(sig, for: message)
            if !signaturePass { signature["reason"] = .string("signature does not verify over the canonical claim") }
        } else {
            signature["reason"] = .string("public key or signature value is not valid base64 Ed25519 material")
        }
        signature["status"] = signaturePass ? "pass" : "fail"
        if !signaturePass {
            errors.append(AuthorError(code: .signatureInvalid, path: manifestPath, message: "Sidecar signature is invalid: \(signature["reason"]?.string ?? "unknown").",
                                      suggestedCommands: ["deliver"], artifact: manifestPath))
        }

        var trust: [String: JSONValue] = ["signer": .string(document.signature.signer)]
        var trustStatus = "pending"
        if let policy {
            trust["policySha256"] = .string(policy.sha256)
            let configured = policy.signers[document.signature.signer]
            let keyMatches = configured?.publicKey == document.signature.publicKey
            let listed = policy.trusted.contains(document.signature.signer)
            trust["configured"] = .bool(configured != nil)
            trust["publicKeyMatches"] = .bool(keyMatches)
            trust["trusted"] = .bool(listed)
            if configured == nil {
                trustStatus = "fail"
                trust["reason"] = .string("signer is not configured in the trust policy")
            } else if !keyMatches {
                trustStatus = "fail"
                trust["reason"] = .string("sidecar public key differs from the configured key for this signer")
            } else if !listed {
                trustStatus = "fail"
                trust["reason"] = .string("signer is configured but not in the trusted list")
            } else {
                trustStatus = "pass"
            }
            if trustStatus == "fail" {
                errors.append(AuthorError(code: .untrustedSigner, path: "/trustPolicy", observed: .string(document.signature.signer), required: JSONValue(policy.trusted.sorted()),
                                          message: "Signer '\(document.signature.signer)' is untrusted: \(trust["reason"]?.string ?? "").", suggestedCommands: ["provenance verify"], artifact: manifestPath))
            }
        } else {
            trust["reason"] = .string("no trust policy supplied; trust not evaluated")
        }
        trust["status"] = .string(trustStatus)

        let verdict: String
        if !bindingPass || !signaturePass || trustStatus == "fail" { verdict = "fail" } else if trustStatus == "pending" { verdict = "incomplete" } else { verdict = "pass" }
        return SidecarVerification(binding: .object(binding), signature: .object(signature), trust: .object(trust), verdict: verdict, errors: errors)
    }

    public var resultFields: [String: JSONValue] { ["binding": binding, "signature": signature, "trust": trust, "verdict": .string(verdict)] }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        self = out
    }
}
