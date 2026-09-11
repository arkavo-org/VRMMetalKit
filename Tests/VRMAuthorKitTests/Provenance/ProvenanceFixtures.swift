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
import XCTest
@testable import VRMAuthorKit

/// Shared scaffolding for the provenance and delivery packs: a temp project,
/// an operation context rooted in the temp directory, fixture lookup and a
/// generated Ed25519 trust policy.
struct ProvenanceFixture {
    let root: URL
    let projectURL: URL
    let store: ProjectStore
    let registry: Registry

    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { return url }
        }
        return url
    }()

    static var avatarSampleU: URL? {
        let url = repoRoot.appendingPathComponent("AvatarSample_U_1.0.vrm.glb")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var mtoonDefault: URL? {
        let url = repoRoot.appendingPathComponent("Tests/VRMMetalKitTests/TestData/Conformance/mtoon_default.vrm")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var smokeSpring: URL? {
        let url = repoRoot.appendingPathComponent("Tests/VRMMetalKitTests/TestData/Conformance/smoke_spring.vrm")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vrmauthor-provenance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        projectURL = root.appendingPathComponent("avatar.vrmauthor")
        store = try ProjectStore.create(at: projectURL, name: "avatar", template: TemplateRef(id: "native-anime-v1", sha256: String(repeating: "a", count: 64)),
                                        seed: 1, lock: ["tool": "vrm-author", "version": .string(ToolInfo.current.version)])
        registry = Registry.v1()
    }

    func tearDown() { try? FileManager.default.removeItem(at: root) }

    func context(env: [String: String] = [:], project: Bool = true) -> OperationContext {
        OperationContext(projectPath: project ? projectURL : nil, cwd: root, env: env, registry: registry)
    }

    func invoke(_ name: String, _ request: JSONValue, env: [String: String] = [:], project: Bool = true) -> ResultEnvelope {
        var full = request
        if project, full["project"] == nil { full = full.merging(["project": .string(projectURL.path)]) }
        return registry.invoke(name, request: full, context: context(env: env, project: project))
    }

    func write(_ data: Data, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func write(_ text: String, _ name: String) throws -> URL { try write(Data(text.utf8), name) }

    func writeJSON(_ value: JSONValue, _ name: String) throws -> URL { try write(try CanonicalJSON.data(value), name) }

    func blob(_ url: URL) throws -> JSONValue {
        ["path": .string(url.path), "sha256": .string(try SHA256Hex.hex(fileAt: url))]
    }

    static func meta(name: String = "Test Avatar", authors: [String] = ["Ada Author"], extra: [String: JSONValue] = [:]) -> JSONValue {
        var m: [String: JSONValue] = ["name": .string(name), "authors": JSONValue(authors), "licenseUrl": .string(VRMMeta.vrm10LicenseUrl), "avatarPermission": "everyone",
                                     "commercialUsage": "personalNonProfit", "allowRedistribution": true, "modification": "allowModificationRedistribution"]
        for (k, v) in extra { m[k] = v }
        return .object(m)
    }

    func declaration(id: String = "rights:main", authors: [String] = ["Ada Author"], metaAuthors: [String]? = nil, evidence: [JSONValue]? = nil,
                     training: JSONValue? = nil, extraMeta: [String: JSONValue] = [:]) throws -> JSONValue {
        var evidenceList = evidence
        if evidenceList == nil {
            let statement = try write("I, Ada Author, hold the rights to Test Avatar.\n", "evidence/rights-statement.txt")
            evidenceList = [try blob(statement)]
        }
        var d: [String: JSONValue] = ["id": .string(id), "declarant": "Ada Author", "evidence": .array(evidenceList!), "authors": JSONValue(authors),
                                      "meta": ProvenanceFixture.meta(authors: metaAuthors ?? authors, extra: extraMeta)]
        if let training { d["training"] = training }
        return .object(d)
    }

    // MARK: Signing

    struct Signer {
        let name: String
        let key: Curve25519.Signing.PrivateKey
        let keyURL: URL
        var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }
    }

    func makeSigner(_ name: String, storeKey: Bool = true) throws -> Signer {
        let key = Curve25519.Signing.PrivateKey()
        let url = root.appendingPathComponent("keys/\(name).ed25519")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if storeKey { try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: url) }
        return Signer(name: name, key: key, keyURL: url)
    }

    /// Writes trust.json and returns its Blob. Signers without a stored key omit privateKeyPath.
    func trustPolicy(signers: [Signer], trusted: [String], name: String = "trust.json") throws -> JSONValue {
        var entries: [String: JSONValue] = [:]
        for s in signers {
            var e: [String: JSONValue] = ["publicKey": .string(s.publicKey)]
            if FileManager.default.fileExists(atPath: s.keyURL.path) { e["privateKeyPath"] = .string("keys/\(s.name).ed25519") }
            entries[s.name] = .object(e)
        }
        let url = try writeJSON(["signers": .object(entries), "trusted": JSONValue(trusted)], name)
        return try blob(url)
    }

    func sidecar(for data: Data, signer: Signer, revision: Int = 0, ingredients: [JSONValue] = []) throws -> Sidecar.Document {
        let claim = Sidecar.Claim(assetSha256: SHA256Hex.hex(data), assetSizeBytes: data.count, generator: "test", createdAtRevision: revision, buildHash: nil,
                                  ingredients: ingredients, training: nil, actions: [["action": "c2pa.created"]])
        return try SidecarSigner(signer: signer.name, privateKey: signer.key).sign(claim)
    }

    /// Minimal valid PNG header bytes (signature + IHDR) sufficient for sniffing.
    static func tinyPNG(width: UInt32 = 4, height: UInt32 = 2) -> Data {
        var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])
        d.append(Data("IHDR".utf8))
        for v in [width, height] { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: [8, 6, 0, 0, 0, 0, 0, 0, 0])
        d.append(Data([0, 0, 0, 0]) + Data("IEND".utf8) + Data([0xAE, 0x42, 0x60, 0x82]))
        return d
    }

    func writeInspection(for hash: String, verdict: String, index: Int = 1) throws {
        let dir = DefaultInspectionCoverage.directory(for: hash, in: store)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let record: JSONValue = ["artifactHash": .string(hash), "buildHash": .string(String(repeating: "b", count: 64)), "revision": 0, "scenarioId": "front",
                                 "actor": "test", "actorVersion": "1", "rubricHash": .string(String(repeating: "c", count: 64)), "timestamp": "2026-09-10T00:00:00Z",
                                 "findings": ["eyes open"], "verdict": .string(verdict)]
        try CanonicalJSON.data(record).write(to: dir.appendingPathComponent("\(index).json"))
    }

    func writeReport(for hash: String, status: String = "pass") throws -> URL {
        try writeJSON(["fileSha256": .string(hash), "status": .string(status), "suite": "authoring-v1", "buildHash": .string(String(repeating: "b", count: 64))], "reports/report.json")
    }
}
