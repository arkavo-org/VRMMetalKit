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
import XCTest
@testable import VRMAuthorKit

final class ProvenancePackTests: XCTestCase {
    private var fx: ProvenanceFixture!

    override func setUpWithError() throws { fx = try ProvenanceFixture() }
    override func tearDownWithError() throws { fx.tearDown() }

    // MARK: Registry

    func testHandlersAreInstalled() {
        for name in ProvenanceHandlers.names { XCTAssertTrue(fx.registry.operation(named: name)?.isRunnable ?? false, name) }
    }

    // MARK: Rights resolver

    func testResolveStoresDeclarationWithAttributionAndNewRevision() throws {
        let training: JSONValue = ["cawg.ai_training": ["use": "notAllowed"], "cawg.data_mining": ["use": "constrained", "constraint_info": "research only"]]
        let envelope = fx.invoke("provenance resolve", ["requestId": "rights-1", "declaration": try fx.declaration(training: training, extraMeta: ["copyrightInformation": "(c) 2026 Ada"])])
        XCTAssertEqual(envelope.exitCode, .success, "\(envelope.errors)")
        XCTAssertEqual(envelope.revisionBefore, 0)
        XCTAssertEqual(envelope.revisionAfter, 1)
        XCTAssertEqual(envelope.result?["conflicts"], [])
        XCTAssertEqual(envelope.result?["meta"]?["authors"], ["Ada Author"])
        let attribution = try XCTUnwrap(envelope.result?["attribution"]?.array)
        let byField = Dictionary(uniqueKeysWithValues: attribution.map { ($0["field"]!.string!, $0) })
        XCTAssertEqual(byField["/meta/authors"]?["source"], "declaration:rights:main")
        XCTAssertEqual(byField["/meta/authors"]?["declarant"], "Ada Author")
        XCTAssertEqual(byField["/meta/authors"]?["evidence"]?.array?.count, 1)
        XCTAssertEqual(byField["/meta/copyrightInformation"]?["value"], "(c) 2026 Ada")
        XCTAssertEqual(byField["/meta/licenseUrl"]?["value"], .string(VRMMeta.vrm10LicenseUrl))
        XCTAssertEqual(byField["/meta/avatarPermission"]?["value"], "everyone")
        XCTAssertEqual(byField["/training"]?["value"]?["entries"]?["cawg.ai_training"]?["use"], "notAllowed")
        XCTAssertNil(byField["/meta/thumbnailImage"])
        XCTAssertEqual(envelope.plan?.invalidations, ["meta"])

        let ledger = try RightsLedger.load(fx.store)
        XCTAssertEqual(ledger.activeDeclaration, "rights:main")
        XCTAssertEqual(ledger.active?.resolvedAtRevision, 1)
        XCTAssertEqual(ledger.active?.declaration.training?.aiTraining?.use, .notAllowed)
        XCTAssertEqual(try fx.store.state().revision, 1)
        XCTAssertEqual(try fx.store.state().imports.first?["entry"], "declaration")

        let replay = fx.invoke("provenance resolve", ["requestId": "rights-1", "declaration": try fx.declaration(training: training, extraMeta: ["copyrightInformation": "(c) 2026 Ada"])])
        XCTAssertEqual(replay, envelope)
        XCTAssertEqual(try fx.store.state().revision, 1)
    }

    func testResolveDryRunLeavesLedgerUntouched() throws {
        let envelope = fx.invoke("provenance resolve", ["requestId": "dry", "dryRun": true, "declaration": try fx.declaration()])
        XCTAssertEqual(envelope.exitCode, .success, "\(envelope.errors)")
        XCTAssertEqual(envelope.revisionAfter, 0)
        XCTAssertNotNil(envelope.plan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: RightsLedger.url(in: fx.store).path))
        XCTAssertNil(try RightsLedger.load(fx.store).active)
    }

    func testConflictingRightsAuthorsMismatchFailsWithoutMutation() throws {
        let envelope = fx.invoke("provenance resolve", ["requestId": "bad", "declaration": try fx.declaration(authors: ["Ada Author"], metaAuthors: ["Someone Else"])])
        XCTAssertEqual(envelope.status, .failed)
        XCTAssertEqual(envelope.exitCode, .gateFailed)
        XCTAssertEqual(envelope.errors.count, 1)
        XCTAssertEqual(envelope.errors.first?.code, .rightsConflict)
        XCTAssertEqual(envelope.errors.first?.path, "/authors")
        XCTAssertEqual(envelope.errors.first?.observed, ["Ada Author"])
        XCTAssertEqual(envelope.errors.first?.required, ["Someone Else"])
        XCTAssertEqual(envelope.result?["conflicts"]?[0]?["code"], "AUTHORS_MISMATCH")
        XCTAssertEqual(envelope.revisionAfter, 0)
        XCTAssertEqual(try fx.store.state().revision, 0)
        XCTAssertNil(try fx.store.receipt(requestId: "bad"))
        XCTAssertNil(try RightsLedger.load(fx.store).active)
    }

    func testEvidenceHashMismatchAndMissingEvidenceAreConflicts() throws {
        let statement = try fx.write("statement", "evidence/s.txt")
        let wrong: JSONValue = ["path": .string(statement.path), "sha256": .string(String(repeating: "0", count: 64))]
        let missing: JSONValue = ["path": .string(fx.root.appendingPathComponent("evidence/nope.txt").path), "sha256": .string(String(repeating: "1", count: 64))]
        let envelope = fx.invoke("provenance resolve", ["declaration": try fx.declaration(evidence: [wrong, missing])])
        XCTAssertEqual(envelope.exitCode, .gateFailed)
        let codes = envelope.result?["conflicts"]?.array?.compactMap { $0["code"]?.string } ?? []
        XCTAssertEqual(codes, ["EVIDENCE_HASH_MISMATCH", "EVIDENCE_MISSING"])
        XCTAssertEqual(envelope.errors.map(\.path), ["/evidence/0/sha256", "/evidence/1/path"])
        XCTAssertEqual(envelope.errors[0].observed, .string(SHA256Hex.hex("statement")))
        XCTAssertEqual(try fx.store.state().revision, 0)
    }

    func testResolverRejectsWrongLicenseUnknownThumbnailAndUnknownImageReference() throws {
        let resolver = RightsResolver(baseURL: fx.root, knownImageIds: ["image:face"])
        var meta = VRMMeta(name: "x", authors: ["A"], references: ["image:missing", "https://example.com/ref"], thumbnailImage: "image:nope", licenseUrl: "https://example.com/mine")
        let declaration = RightsDeclaration(id: "r", declarant: "A", evidence: [], authors: ["A"], meta: meta)
        let resolution = try resolver.resolve(declaration)
        XCTAssertEqual(resolution.conflicts.map(\.code), ["LICENSE_URL_INVALID", "THUMBNAIL_UNKNOWN_IMAGE", "REFERENCE_UNKNOWN_IMAGE"])
        XCTAssertEqual(resolution.conflicts.map(\.path), ["/meta/licenseUrl", "/meta/thumbnailImage", "/meta/references/0"])
        meta.licenseUrl = VRMMeta.vrm10LicenseUrl
        meta.thumbnailImage = "image:face"
        meta.references = ["image:face", "https://example.com/ref"]
        let clean = try resolver.resolve(RightsDeclaration(id: "r", declarant: "A", evidence: [], authors: ["A"], meta: meta))
        XCTAssertTrue(clean.isClean)
        XCTAssertEqual(clean.attributions.first { $0.field == "/meta/thumbnailImage" }?.value, "image:face")
    }

    func testIncompatibleIngredientTermsAndContradictoryDuplicatesConflict() throws {
        var ledger = RightsLedger()
        let ingredientMeta = VRMMeta(name: "hair-pack", authors: ["Pack Artist"], commercialUsage: .personalNonProfit, creditNotation: .required, allowRedistribution: false, modification: .allowModification)
        let ingredient = RightsDeclaration(id: "rights:hair", declarant: "Pack Artist", evidence: [], authors: ["Pack Artist"], meta: ingredientMeta)
        ledger.upsert(LedgerAsset(id: "asset:hair", kind: .gltf, sha256: String(repeating: "h", count: 64), sizeBytes: 1, sourceUri: nil, generation: nil, declaration: ingredient,
                                  importedAtRevision: 1, preservation: nil, image: nil, credential: ["status": "absent"], manifestSha256: nil))
        let resolver = RightsResolver(baseURL: fx.root, ledger: ledger)
        let mine = VRMMeta(name: "avatar", authors: ["Ada"], commercialUsage: .corporation, creditNotation: .unnecessary, allowRedistribution: true, modification: .allowModificationRedistribution)
        let resolution = try resolver.resolve(RightsDeclaration(id: "rights:main", declarant: "Ada", evidence: [], authors: ["Ada"], meta: mine))
        XCTAssertEqual(Set(resolution.conflicts.map(\.code)), ["INGREDIENT_REDISTRIBUTION", "INGREDIENT_MODIFIED_REDISTRIBUTION", "INGREDIENT_COMMERCIAL_USAGE", "INGREDIENT_CREDIT_REQUIRED"])
        XCTAssertTrue(resolution.conflicts.allSatisfy { $0.path.hasPrefix("/ledger/asset:hair/declaration/meta/") })

        var duplicate = ingredient
        duplicate.meta.authors = ["Imposter"]
        duplicate.authors = ["Imposter"]
        let contradiction = try RightsResolver(baseURL: fx.root, ledger: ledger).resolve(duplicate)
        XCTAssertTrue(contradiction.conflicts.contains { $0.code == "LEDGER_CONTRADICTION" && $0.path == "/ledger/asset:hair/declaration" })

        var stored = ledger
        stored.upsert(LedgerDeclaration(declaration: RightsDeclaration(id: "rights:old", declarant: "Ada", evidence: [], authors: ["Ada"], meta: mine), resolution: RightsResolution(meta: mine, attributions: [], conflicts: []), resolvedAtRevision: 1))
        var renamed = mine
        renamed.authors = ["Bob"]
        let second = try RightsResolver(baseURL: fx.root, ledger: stored).resolve(RightsDeclaration(id: "rights:new", declarant: "Bob", evidence: [], authors: ["Bob"], meta: renamed))
        XCTAssertTrue(second.conflicts.contains { $0.code == "LEDGER_CONTRADICTION" && $0.path == "/ledger/declarations/rights:old" })
        let update = try RightsResolver(baseURL: fx.root, ledger: stored).resolve(RightsDeclaration(id: "rights:old", declarant: "Bob", evidence: [], authors: ["Bob"], meta: renamed))
        XCTAssertFalse(update.conflicts.contains { $0.code == "LEDGER_CONTRADICTION" })
    }

    func testRightsPointersAreRecognised() throws {
        XCTAssertTrue(RightsLedger.isRightsPointer("/meta/authors"))
        XCTAssertTrue(RightsLedger.isRightsPointer("/rights"))
        XCTAssertTrue(RightsLedger.isRightsPointer(try JSONPointer("/training/cawg.ai_training")))
        XCTAssertFalse(RightsLedger.isRightsPointer("/mtoon/shadingToonyFactor"))
        XCTAssertFalse(RightsLedger.isRightsPointer(""))
        XCTAssertFalse(RightsLedger.isRightsPointer("no-slash"))
    }

    // MARK: CAWG

    func testCAWGAssertionHasExactShapeAndOmissionStaysAbsent() throws {
        let claims = TrainingClaims(dataMining: TrainingClaim(use: .allowed), aiInference: nil, aiTraining: TrainingClaim(use: .notAllowed),
                                    aiGenerativeTraining: TrainingClaim(use: .constrained, constraintInfo: "non-commercial research"))
        XCTAssertEqual(try CanonicalJSON.string(claims.cawgAssertion),
                       #"{"entries":{"cawg.ai_generative_training":{"constraint_info":"non-commercial research","use":"constrained"},"cawg.ai_training":{"use":"notAllowed"},"cawg.data_mining":{"use":"allowed"}}}"#)
        XCTAssertEqual(try CanonicalJSON.string(TrainingClaims().cawgAssertion), #"{"entries":{}}"#)
        let decoded = try TrainingClaims.decode(JSONValue.parse(#"{"cawg.ai_inference":{"use":"notAllowed"}}"#))
        XCTAssertEqual(try CanonicalJSON.string(decoded.cawgAssertion), #"{"entries":{"cawg.ai_inference":{"use":"notAllowed"}}}"#)
        XCTAssertEqual(Set(decoded.cawgAssertion["entries"]!.object!.keys), ["cawg.ai_inference"])
        XCTAssertEqual(TrainingClaims.entryKeys, ["cawg.data_mining", "cawg.ai_inference", "cawg.ai_training", "cawg.ai_generative_training"])
        XCTAssertThrowsError(try TrainingClaims.decode(JSONValue.parse(#"{"cawg.ai_inference":{"use":"maybe"}}"#)))
    }

    // MARK: provenance verify

    private func signedFixture(trusted: Bool = true) throws -> (data: Data, file: URL, manifest: URL, policy: JSONValue, signer: ProvenanceFixture.Signer) {
        let data = (ProvenanceFixture.mtoonDefault.flatMap { try? Data(contentsOf: $0) }) ?? Data((0..<4096).map { UInt8($0 % 251) })
        let file = try fx.write(data, "out/avatar.vrm")
        let signer = try fx.makeSigner("local-author")
        let document = try fx.sidecar(for: data, signer: signer)
        let manifest = try fx.write(try document.canonicalData(), "out/avatar.vrm\(Sidecar.suffix)")
        let policy = try fx.trustPolicy(signers: [signer], trusted: trusted ? ["local-author"] : [])
        return (data, file, manifest, policy, signer)
    }

    func testVerifyPassesOnValidSidecar() throws {
        let f = try signedFixture()
        let envelope = fx.invoke("provenance verify", ["file": .string(f.file.path), "manifest": .string(f.manifest.path), "trustPolicy": f.policy], project: false)
        XCTAssertEqual(envelope.exitCode, .success, "\(envelope.errors)")
        XCTAssertEqual(envelope.result?["verdict"], "pass")
        XCTAssertEqual(envelope.result?["binding"]?["status"], "pass")
        XCTAssertEqual(envelope.result?["signature"]?["status"], "pass")
        XCTAssertEqual(envelope.result?["trust"]?["status"], "pass")
        XCTAssertEqual(envelope.result?["trust"]?["trusted"], true)
        XCTAssertEqual(envelope.revisionBefore, nil)
    }

    func testVerifyMissingSidecarIsMissingInput() throws {
        let f = try signedFixture()
        try FileManager.default.removeItem(at: f.manifest)
        let envelope = fx.invoke("provenance verify", ["file": .string(f.file.path), "manifest": .string(f.manifest.path), "trustPolicy": f.policy], project: false)
        XCTAssertEqual(envelope.status, .failed)
        XCTAssertEqual(envelope.errors.first?.code, .missingInput)
        XCTAssertEqual(envelope.exitCode, .missingCapability)
        XCTAssertEqual(envelope.result?["verdict"], "incomplete")
    }

    func testVerifyUntrustedSignerSeparatesTrustFromBindingAndSignature() throws {
        let f = try signedFixture(trusted: false)
        let envelope = fx.invoke("provenance verify", ["file": .string(f.file.path), "manifest": .string(f.manifest.path), "trustPolicy": f.policy], project: false)
        XCTAssertEqual(envelope.status, .failed)
        XCTAssertEqual(envelope.exitCode, .gateFailed)
        XCTAssertEqual(envelope.errors.map(\.code), [.untrustedSigner])
        XCTAssertEqual(envelope.result?["binding"]?["status"], "pass")
        XCTAssertEqual(envelope.result?["signature"]?["status"], "pass")
        XCTAssertEqual(envelope.result?["trust"]?["status"], "fail")
        XCTAssertEqual(envelope.result?["trust"]?["trusted"], false)
        XCTAssertEqual(envelope.result?["trust"]?["publicKeyMatches"], true)

        let stranger = try fx.makeSigner("stranger", storeKey: false)
        let unknownPolicy = try fx.trustPolicy(signers: [stranger], trusted: ["stranger"], name: "trust-unknown.json")
        let unknown = fx.invoke("provenance verify", ["file": .string(f.file.path), "manifest": .string(f.manifest.path), "trustPolicy": unknownPolicy], project: false)
        XCTAssertEqual(unknown.result?["trust"]?["configured"], false)
        XCTAssertEqual(unknown.result?["trust"]?["status"], "fail")
        XCTAssertEqual(unknown.result?["signature"]?["status"], "pass")
    }

    func testVerifyTamperedBindingFailsBindingOnly() throws {
        let f = try signedFixture()
        var tampered = f.data
        tampered[tampered.count / 2] ^= 0x01
        try tampered.write(to: f.file)
        let envelope = fx.invoke("provenance verify", ["file": .string(f.file.path), "manifest": .string(f.manifest.path), "trustPolicy": f.policy], project: false)
        XCTAssertEqual(envelope.status, .failed)
        XCTAssertEqual(envelope.exitCode, .gateFailed)
        XCTAssertEqual(envelope.errors.map(\.code), [.bindingFailed])
        XCTAssertEqual(envelope.errors.first?.required, .string(SHA256Hex.hex(f.data)))
        XCTAssertEqual(envelope.errors.first?.observed, .string(SHA256Hex.hex(tampered)))
        XCTAssertEqual(envelope.result?["binding"]?["status"], "fail")
        XCTAssertEqual(envelope.result?["binding"]?["observedSizeBytes"], envelope.result?["binding"]?["expectedSizeBytes"])
        XCTAssertEqual(envelope.result?["signature"]?["status"], "pass")
        XCTAssertEqual(envelope.result?["trust"]?["status"], "pass")
    }

    func testVerifyStaleManifestForReexportedBytesFailsBinding() throws {
        let f = try signedFixture()
        try (f.data + Data("re-exported".utf8)).write(to: f.file)
        let envelope = fx.invoke("provenance verify", ["file": .string(f.file.path), "manifest": .string(f.manifest.path), "trustPolicy": f.policy], project: false)
        XCTAssertEqual(envelope.status, .failed)
        XCTAssertEqual(envelope.errors.map(\.code), [.bindingFailed])
        XCTAssertEqual(envelope.result?["binding"]?["status"], "fail")
        XCTAssertTrue(envelope.result?["binding"]?["reason"]?.string?.contains("stale") ?? false)
        XCTAssertEqual(envelope.result?["signature"]?["status"], "pass")
        XCTAssertEqual(envelope.result?["trust"]?["status"], "pass")
    }

    func testVerifyRejectsForgedClaimAndWrongPolicyHash() throws {
        let f = try signedFixture()
        var forged = try JSONValue.parse(try Data(contentsOf: f.manifest))
        var claim = forged["claim"]!.object!
        claim["createdAtRevision"] = 99
        forged = forged.merging(["claim": .object(claim)])
        try CanonicalJSON.data(forged).write(to: f.manifest)
        let envelope = fx.invoke("provenance verify", ["file": .string(f.file.path), "manifest": .string(f.manifest.path), "trustPolicy": f.policy], project: false)
        XCTAssertEqual(envelope.result?["signature"]?["status"], "fail")
        XCTAssertEqual(envelope.result?["binding"]?["status"], "pass")
        XCTAssertEqual(envelope.errors.map(\.code), [.signatureInvalid])

        let badPolicy = f.policy.merging(["sha256": .string(String(repeating: "0", count: 64))])
        let mismatch = fx.invoke("provenance verify", ["file": .string(f.file.path), "manifest": .string(f.manifest.path), "trustPolicy": badPolicy], project: false)
        XCTAssertEqual(mismatch.errors.first?.code, .validationFailed)
        XCTAssertEqual(mismatch.errors.first?.path, "/trustPolicy/sha256")
    }

    // MARK: asset import / inspect

    func testImportAvatarSampleUProducesPreservationReport() throws {
        guard let sample = ProvenanceFixture.avatarSampleU else { throw XCTSkip("AvatarSample_U_1.0.vrm.glb not present at the repo root") }
        let envelope = fx.invoke("asset import", ["requestId": "import-u", "asset": ["path": .string(sample.path), "kind": "vrm", "sourceUri": "https://vroid.pixiv.help/"]])
        XCTAssertEqual(envelope.exitCode, .success, "\(envelope.errors)")
        XCTAssertEqual(envelope.revisionAfter, 1)
        let sha = try SHA256Hex.hex(fileAt: sample)
        XCTAssertEqual(envelope.result?["sha256"], .string(sha))
        XCTAssertEqual(envelope.result?["asset"], .string("asset:" + sha.prefix(12)))
        XCTAssertEqual(envelope.result?["kind"], "vrm")
        XCTAssertEqual(envelope.result?["credentialStatus"], "absent")
        let ingredient = try XCTUnwrap(envelope.result?["ingredient"])
        let preservation = try XCTUnwrap(ingredient["preservation"])
        XCTAssertEqual(preservation["humanoidPresent"], true)
        XCTAssertGreaterThanOrEqual(preservation["humanBones"]?.int ?? 0, 50)
        XCTAssertGreaterThan(preservation["meshes"]?.int ?? 0, 0)
        XCTAssertGreaterThan(preservation["triangles"]?.int ?? 0, 1000)
        XCTAssertGreaterThan(preservation["expressions"]?.int ?? 0, 10)
        XCTAssertGreaterThan(preservation["springs"]?.int ?? 0, 0)
        let extensions = preservation["extensionsUsed"]?.array?.compactMap(\.string) ?? []
        XCTAssertTrue(extensions.contains("VRMC_vrm"), "\(extensions)")
        XCTAssertTrue(extensions.contains("VRMC_materials_mtoon"))
        XCTAssertTrue(extensions.contains("VRMC_springBone"))
        XCTAssertEqual(Set(preservation["roundTripExtensions"]?.array?.compactMap(\.string) ?? []), ["VRMC_vrm", "VRMC_materials_mtoon", "VRMC_springBone"])
        let lost = envelope.result?["lossReport"]?["lost"]
        XCTAssertEqual(lost, [])
        XCTAssertTrue(envelope.result?["lossReport"]?["preserved"]?.array?.contains("extension:VRMC_vrm") ?? false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fx.store.assetsDirectory.appendingPathComponent(sha).path))
        XCTAssertEqual(try Data(contentsOf: fx.store.assetsDirectory.appendingPathComponent(sha)), try Data(contentsOf: sample))
        XCTAssertEqual(envelope.artifacts.first?.role, "ingredient")

        let inspect = fx.invoke("asset inspect", ["id": envelope.result!["asset"]!])
        XCTAssertEqual(inspect.exitCode, .success, "\(inspect.errors)")
        XCTAssertEqual(inspect.result?["geometry"]?["humanoidPresent"], true)
        XCTAssertEqual(inspect.result?["credentialStatus"], "absent")
        let coverage = inspect.result?["extensions"]?.array?.compactMap(\.string) ?? []
        XCTAssertTrue(coverage.contains("VRMC_vrm:round-trip"), "\(coverage)")
        XCTAssertTrue(coverage.allSatisfy { $0.hasSuffix(":round-trip") || $0.hasSuffix(":preserved-opaque") })
        XCTAssertEqual(inspect.result?["asset"]?["sourceUri"], "https://vroid.pixiv.help/")
        XCTAssertGreaterThan(inspect.result?["textures"]?["images"]?.array?.count ?? 0, 0)

        let replay = fx.invoke("asset import", ["requestId": "import-u", "asset": ["path": .string(sample.path), "kind": "vrm", "sourceUri": "https://vroid.pixiv.help/"]])
        XCTAssertEqual(replay, envelope)
        XCTAssertEqual(try fx.store.state().revision, 1)
    }

    func testImportSmallVRMReportsOpaqueExtensionsAndLedger() throws {
        guard let sample = ProvenanceFixture.smokeSpring ?? ProvenanceFixture.mtoonDefault else { throw XCTSkip("conformance fixtures not present") }
        let generation: JSONValue = ["tool": "vrm-asset-generator", "version": "1.0", "action": "c2pa.created", "digitalSourceType": "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia"]
        let envelope = fx.invoke("asset import", ["asset": ["path": .string(sample.path), "kind": "vrm", "generation": generation]])
        XCTAssertEqual(envelope.exitCode, .success, "\(envelope.errors)")
        let preservation = try XCTUnwrap(envelope.result?["ingredient"]?["preservation"])
        XCTAssertEqual(preservation["humanoidPresent"], true)
        XCTAssertEqual(preservation["preservedOpaqueExtensions"], ["KHR_materials_unlit"])
        XCTAssertEqual(preservation["degenerateTriangles"], 0)
        XCTAssertGreaterThan(preservation["triangles"]?.int ?? 0, 0)
        XCTAssertEqual(preservation["metaAuthors"], ["arkavo-org/vrm-conformance generator"])
        XCTAssertEqual(envelope.result?["ingredient"]?["generation"]?["tool"], "vrm-asset-generator")
        XCTAssertEqual(try fx.store.state().imports.count, 1)
        let ledger = try RightsLedger.load(fx.store)
        XCTAssertEqual(ledger.assets.count, 1)
        XCTAssertEqual(ledger.assets.first?.importedAtRevision, 1)
        XCTAssertEqual(ledger.assets.first?.generation?.digitalSourceType, "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia")
    }

    func testImportNonGLBAsVRMIsRejected() throws {
        let text = try fx.write("{\"asset\":{\"version\":\"2.0\"}}", "not.vrm")
        let envelope = fx.invoke("asset import", ["asset": ["path": .string(text.path), "kind": "vrm"]])
        XCTAssertEqual(envelope.status, .failed)
        XCTAssertEqual(envelope.exitCode, .invalidRequest)
        XCTAssertEqual(envelope.errors.first?.path, "/asset/path")
        XCTAssertEqual(try fx.store.state().revision, 0)
        XCTAssertEqual(try RightsLedger.load(fx.store).assets, [])

        let garbage = try fx.write(Data([1, 2, 3, 4]), "garbage.glb")
        XCTAssertEqual(fx.invoke("asset import", ["asset": ["path": .string(garbage.path), "kind": "gltf"]]).exitCode, .invalidRequest)
        XCTAssertEqual(fx.invoke("asset import", ["asset": ["path": .string(text.path), "kind": "png"]]).exitCode, .invalidRequest)
        XCTAssertEqual(fx.invoke("asset import", ["asset": ["path": "/nonexistent/file.vrm", "kind": "vrm"]]).exitCode, .missingCapability)
        XCTAssertEqual(fx.invoke("asset import", ["asset": ["path": .string(text.path), "kind": "obj"]]).exitCode, .invalidRequest)
    }

    func testImportPNGRecordsImageFactsAndDryRunStoresNothing() throws {
        let png = try fx.write(ProvenanceFixture.tinyPNG(width: 4, height: 2), "ref.png")
        let dry = fx.invoke("asset import", ["dryRun": true, "asset": ["path": .string(png.path), "kind": "png"]])
        XCTAssertEqual(dry.exitCode, .success, "\(dry.errors)")
        XCTAssertEqual(dry.revisionAfter, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: RightsLedger.url(in: fx.store).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.store.assetsDirectory.appendingPathComponent(dry.result!["sha256"]!.string!).path))

        let envelope = fx.invoke("asset import", ["asset": ["path": .string(png.path), "kind": "png"]])
        XCTAssertEqual(envelope.exitCode, .success)
        XCTAssertEqual(envelope.result?["ingredient"]?["image"]?["width"], 4)
        XCTAssertEqual(envelope.result?["ingredient"]?["image"]?["height"], 2)
        XCTAssertEqual(envelope.result?["lossReport"]?["preserved"], ["bytes"])
        let inspect = fx.invoke("asset inspect", ["id": envelope.result!["asset"]!])
        XCTAssertEqual(inspect.result?["textures"]?["format"], "png")
        XCTAssertEqual(inspect.result?["geometry"], .null)
        XCTAssertEqual(inspect.result?["extensions"], [])
        XCTAssertEqual(try RightsLedger.load(fx.store).imageIds, [envelope.result!["asset"]!.string!])
        XCTAssertEqual(fx.invoke("asset inspect", ["id": "asset:nope"]).exitCode, .invalidRequest)
    }

    func testImportWithSidecarReportsCredentialStatus() throws {
        let data = ProvenanceFixture.tinyPNG()
        let png = try fx.write(data, "signed.png")
        let signer = try fx.makeSigner("upstream")
        let document = try fx.sidecar(for: data, signer: signer)
        let manifest = try fx.write(try document.canonicalData(), "signed.png\(Sidecar.suffix)")
        let untrusted = fx.invoke("asset import", ["asset": ["path": .string(png.path), "kind": "png", "manifestPath": .string(manifest.path)]])
        XCTAssertEqual(untrusted.exitCode, .success, "\(untrusted.errors)")
        XCTAssertEqual(untrusted.result?["credentialStatus"], "untrusted")
        XCTAssertEqual(untrusted.result?["ingredient"]?["credential"]?["binding"]?["status"], "pass")
        XCTAssertEqual(untrusted.result?["ingredient"]?["credential"]?["trust"]?["status"], "pending")

        let policy = try fx.trustPolicy(signers: [signer], trusted: ["upstream"], name: "upstream-trust.json")
        let other = try fx.write(data + Data([0]), "signed2.png")
        let env = [SignerAvailability.trustPolicyKey: policy["path"]!.string!]
        let valid = fx.invoke("asset import", ["asset": ["path": .string(png.path), "kind": "png", "manifestPath": .string(manifest.path)]], env: env)
        XCTAssertEqual(valid.result?["credentialStatus"], "untrusted", "same bytes already imported: existing entry is returned")
        XCTAssertEqual(valid.warnings.first?.code, "ASSET_ALREADY_IMPORTED")
        let invalid = fx.invoke("asset import", ["asset": ["path": .string(other.path), "kind": "png", "manifestPath": .string(manifest.path)]], env: env)
        XCTAssertEqual(invalid.exitCode, .success)
        XCTAssertEqual(invalid.result?["credentialStatus"], "invalid")
        XCTAssertEqual(invalid.result?["ingredient"]?["credential"]?["binding"]?["status"], "fail")
        XCTAssertEqual(invalid.result?["ingredient"]?["credential"]?["trust"]?["status"], "pass")
        let junk = try fx.write("{\"format\":\"other\"}", "junk.c2pa.json")
        let third = try fx.write(data + Data([1]), "signed3.png")
        XCTAssertEqual(fx.invoke("asset import", ["asset": ["path": .string(third.path), "kind": "png", "manifestPath": .string(junk.path)]]).result?["credentialStatus"], "invalid")
    }

    func testImportWithConflictingDeclarationFails() throws {
        let png = try fx.write(ProvenanceFixture.tinyPNG(), "ref.png")
        let envelope = fx.invoke("asset import", ["asset": ["path": .string(png.path), "kind": "png", "declaration": try fx.declaration(authors: ["A"], metaAuthors: ["B"])]])
        XCTAssertEqual(envelope.exitCode, .gateFailed)
        XCTAssertEqual(envelope.errors.first?.code, .rightsConflict)
        XCTAssertEqual(try fx.store.state().revision, 0)
    }

    // MARK: provenance inspect

    func testProvenanceInspectLedgerAssetAndFileForms() throws {
        let png = try fx.write(ProvenanceFixture.tinyPNG(), "ref.png")
        let imported = fx.invoke("asset import", ["asset": ["path": .string(png.path), "kind": "png"]])
        let assetId = try XCTUnwrap(imported.result?["asset"]?.string)
        XCTAssertEqual(fx.invoke("provenance resolve", ["declaration": try fx.declaration(extraMeta: ["thumbnailImage": .string(assetId)])]).exitCode, .success)

        let ledger = fx.invoke("provenance inspect", [:])
        XCTAssertEqual(ledger.exitCode, .success, "\(ledger.errors)")
        XCTAssertEqual(ledger.revisionBefore, 2)
        XCTAssertEqual(ledger.revisionAfter, 2)
        let kinds = ledger.result?["ingredients"]?.array?.compactMap { $0["kind"]?.string } ?? []
        XCTAssertEqual(kinds, ["png", "template", "declaration"])
        XCTAssertEqual(ledger.result?["ingredients"]?[2]?["active"], true)
        XCTAssertEqual(ledger.result?["binding"]?["status"], "notApplicable")

        let asset = fx.invoke("provenance inspect", ["asset": .string(assetId)])
        XCTAssertEqual(asset.exitCode, .success)
        XCTAssertEqual(asset.result?["ingredients"]?[0]?["id"], .string(assetId))
        XCTAssertEqual(asset.result?["binding"]?["status"], "absent")
        XCTAssertEqual(fx.invoke("provenance inspect", ["asset": "asset:nope"]).exitCode, .invalidRequest)

        let signer = try fx.makeSigner("local-author")
        let document = try fx.sidecar(for: ProvenanceFixture.tinyPNG(), signer: signer, ingredients: [["id": .string(assetId), "sha256": imported.result!["sha256"]!]])
        _ = try fx.write(try document.canonicalData(), "ref.png\(Sidecar.suffix)")
        let file = fx.invoke("provenance inspect", ["file": .string(png.path)])
        XCTAssertEqual(file.exitCode, .success, "\(file.errors)")
        XCTAssertEqual(file.result?["binding"]?["status"], "pass")
        XCTAssertEqual(file.result?["signature"]?["status"], "pass")
        XCTAssertEqual(file.result?["trust"]?["status"], "pending")
        let fileKinds = file.result?["ingredients"]?.array?.compactMap { $0["kind"]?.string } ?? []
        XCTAssertEqual(fileKinds.prefix(2), ["file", "asset"])
        XCTAssertEqual(file.result?["ingredients"]?[2]?["source"], "sidecar")
        let policy = try fx.trustPolicy(signers: [signer], trusted: ["local-author"])
        let trusted = fx.invoke("provenance inspect", ["file": .string(png.path)], env: [SignerAvailability.trustPolicyKey: policy["path"]!.string!])
        XCTAssertEqual(trusted.result?["trust"]?["status"], "pass")

        let plain = try fx.write("plain", "plain.bin")
        let noSidecar = fx.invoke("provenance inspect", ["file": .string(plain.path)])
        XCTAssertEqual(noSidecar.result?["binding"]?["status"], "absent")
        XCTAssertEqual(fx.invoke("provenance inspect", ["asset": .string(assetId), "file": .string(png.path)]).exitCode, .invalidRequest)
        XCTAssertEqual(fx.invoke("provenance inspect", ["file": "/nonexistent"]).exitCode, .missingCapability)
    }

    // MARK: Signer availability

    func testSignerAvailabilityFollowsEnvironment() throws {
        XCTAssertFalse(SignerAvailability.check(env: [:], cwd: fx.root).available)
        let signer = try fx.makeSigner("local-author")
        let keyless = try fx.makeSigner("keyless", storeKey: false)
        let policy = try fx.trustPolicy(signers: [signer, keyless], trusted: ["local-author"])
        let path = policy["path"]!.string!
        XCTAssertFalse(SignerAvailability.check(env: [SignerAvailability.trustPolicyKey: path], cwd: fx.root).available)
        let ok = SignerAvailability.check(env: [SignerAvailability.trustPolicyKey: path, SignerAvailability.signerKey: "local-author"], cwd: fx.root)
        XCTAssertTrue(ok.available)
        XCTAssertTrue(ok.trusted)
        XCTAssertEqual(ok.json["signer"], "local-author")
        let noKey = SignerAvailability.check(env: [SignerAvailability.trustPolicyKey: path, SignerAvailability.signerKey: "keyless"], cwd: fx.root)
        XCTAssertFalse(noKey.available)
        XCTAssertTrue(noKey.reason.contains("privateKeyPath"))
        XCTAssertFalse(SignerAvailability.check(env: [SignerAvailability.trustPolicyKey: path, SignerAvailability.signerKey: "nobody"], cwd: fx.root).available)
        XCTAssertFalse(SignerAvailability.check(env: [SignerAvailability.trustPolicyKey: "/nonexistent.json", SignerAvailability.signerKey: "local-author"], cwd: fx.root).available)
        XCTAssertEqual(try SidecarSigner.loadPrivateKey(signer.keyURL).publicKey.rawRepresentation, signer.key.publicKey.rawRepresentation)
        let raw = try fx.write(signer.key.rawRepresentation, "keys/raw.bin")
        XCTAssertEqual(try SidecarSigner.loadPrivateKey(raw).publicKey.rawRepresentation, signer.key.publicKey.rawRepresentation)
        let hex = try fx.write(signer.key.rawRepresentation.map { String(format: "%02x", $0) }.joined(), "keys/hex.txt")
        XCTAssertEqual(try SidecarSigner.loadPrivateKey(hex).publicKey.rawRepresentation, signer.key.publicKey.rawRepresentation)
        XCTAssertThrowsError(try SidecarSigner.loadPrivateKey(try fx.write("nope", "keys/bad.txt")))
    }
}
