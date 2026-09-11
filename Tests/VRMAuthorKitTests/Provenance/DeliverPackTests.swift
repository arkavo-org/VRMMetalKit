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

final class DeliverPackTests: XCTestCase {
    private var fx: ProvenanceFixture!
    private var vrmData: Data!
    private var vrmURL: URL!
    private var vrmSha: String!

    override func setUpWithError() throws {
        fx = try ProvenanceFixture()
        vrmData = (ProvenanceFixture.mtoonDefault.flatMap { try? Data(contentsOf: $0) }) ?? Data((0..<8192).map { UInt8(($0 * 7) % 253) })
        vrmURL = try fx.write(vrmData, "export/avatar.vrm")
        vrmSha = SHA256Hex.hex(vrmData)
    }

    override func tearDownWithError() throws { fx.tearDown() }

    private func prepare(resolveRights: Bool = true, inspection: String? = "pass", reportStatus: String = "pass", reportHash: String? = nil) throws -> URL {
        if resolveRights {
            let training: JSONValue = ["cawg.ai_generative_training": ["use": "notAllowed"]]
            let resolved = fx.invoke("provenance resolve", ["declaration": try fx.declaration(training: training)])
            XCTAssertEqual(resolved.exitCode, .success, "\(resolved.errors)")
        }
        if let inspection { try fx.writeInspection(for: vrmSha, verdict: inspection) }
        return try fx.writeReport(for: reportHash ?? vrmSha, status: reportStatus)
    }

    private func deliverRequest(report: URL, signer: String, policy: JSONValue, requestId: String = "delivery-1", out: String = "delivery") -> JSONValue {
        ["requestId": .string(requestId), "file": .string(vrmURL.path), "report": .string(report.path), "signer": .string(signer), "trustPolicy": policy,
         "out": .string(fx.root.appendingPathComponent(out).path)]
    }

    func testDeliverHappyPathSignsFrozenBytesAndWritesBundle() throws {
        let png = try fx.write(ProvenanceFixture.tinyPNG(), "ref.png")
        XCTAssertEqual(fx.invoke("asset import", ["asset": ["path": .string(png.path), "kind": "png", "generation": ["tool": "painter", "version": "2", "action": "c2pa.created"]]]).exitCode, .success)
        let report = try prepare()
        let signer = try fx.makeSigner("local-author")
        let policy = try fx.trustPolicy(signers: [signer], trusted: ["local-author"])
        let request = deliverRequest(report: report, signer: "local-author", policy: policy)
        let before = try Data(contentsOf: vrmURL)

        let envelope = fx.invoke("deliver", request)
        XCTAssertEqual(envelope.exitCode, .success, "\(envelope.errors)")
        XCTAssertEqual(envelope.status, .succeeded)
        XCTAssertEqual(envelope.result?["verdict"], "delivered")
        XCTAssertEqual(envelope.revisionBefore, 2)
        XCTAssertEqual(envelope.revisionAfter, 2)
        XCTAssertEqual(try Data(contentsOf: vrmURL), before, "signing must never alter the input VRM")
        XCTAssertEqual(SHA256Hex.hex(try Data(contentsOf: vrmURL)), vrmSha)

        let out = fx.root.appendingPathComponent("delivery")
        let fm = FileManager.default
        for rel in ["avatar.vrm", "avatar.vrm.c2pa.json", "lock.json", "delivery.json", "project/project.json", "project/lock.json", "project/ledger.json",
                    "project/revisions/000000.json", "project/revisions/000002.json", "qa/report.json", "inspections/\(vrmSha!)/1.json"] {
            XCTAssertTrue(fm.fileExists(atPath: out.appendingPathComponent(rel).path), rel)
        }
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("avatar.vrm")), vrmData)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("qa/report.json")), try Data(contentsOf: report))
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: fx.root.path).contains { $0.contains(ProjectStore.tempInfix) })
        let roles = Set(envelope.artifacts.map(\.role))
        XCTAssertTrue(roles.isSuperset(of: ["avatar", "credential", "lock", "project", "ledger", "revision", "qa-report", "inspection", "delivery-manifest"]), "\(roles)")
        XCTAssertEqual(envelope.artifacts.first { $0.role == "avatar" }?.sha256, vrmSha)

        let sidecarURL = out.appendingPathComponent("avatar.vrm.c2pa.json")
        let sidecar = try JSONValue.parse(try Data(contentsOf: sidecarURL))
        XCTAssertEqual(sidecar["format"], .string(Sidecar.format))
        XCTAssertEqual(sidecar["claim"]?["assetSha256"], .string(vrmSha))
        XCTAssertEqual(sidecar["claim"]?["assetSizeBytes"]?.int, vrmData.count)
        XCTAssertEqual(sidecar["claim"]?["createdAtRevision"], 2)
        XCTAssertEqual(sidecar["claim"]?["buildHash"], .string(String(repeating: "b", count: 64)))
        XCTAssertEqual(sidecar["claim"]?["training"]?["entries"]?["cawg.ai_generative_training"]?["use"], "notAllowed")
        XCTAssertEqual(sidecar["claim"]?["ingredients"]?.array?.count, 1)
        XCTAssertEqual(sidecar["claim"]?["ingredients"]?[0]?["kind"], "png")
        XCTAssertEqual(sidecar["claim"]?["actions"]?[0]?["action"], "c2pa.created")
        XCTAssertEqual(sidecar["claim"]?["actions"]?[1]?["ingredient"]?.string?.hasPrefix("asset:"), true)
        XCTAssertEqual(sidecar["signature"]?["algorithm"], "Ed25519")
        XCTAssertEqual(sidecar["signature"]?["signer"], "local-author")
        XCTAssertEqual(sidecar["signature"]?["publicKey"], .string(signer.publicKey))
        XCTAssertEqual(envelope.result?["sidecar"], sidecar)

        let verify = fx.invoke("provenance verify", ["file": .string(out.appendingPathComponent("avatar.vrm").path), "manifest": .string(sidecarURL.path), "trustPolicy": policy], project: false)
        XCTAssertEqual(verify.exitCode, .success, "\(verify.errors)")
        XCTAssertEqual(verify.result?["verdict"], "pass")

        let sidecarBytes = try Data(contentsOf: sidecarURL)
        let replay = fx.invoke("deliver", request)
        XCTAssertEqual(replay, envelope)
        XCTAssertEqual(try Data(contentsOf: sidecarURL), sidecarBytes)
        XCTAssertEqual(try fx.store.receipt(requestId: "delivery-1")?.revisionAfter, 2)
        XCTAssertEqual(try fx.store.state().revision, 2)

        let changed = fx.invoke("deliver", deliverRequest(report: report, signer: "local-author", policy: policy, out: "delivery-2"))
        XCTAssertEqual(changed.exitCode, .conflict)
        XCTAssertEqual(changed.errors.first?.code, .requestIdReused)
        XCTAssertFalse(fm.fileExists(atPath: fx.root.appendingPathComponent("delivery-2").path))

        let collide = fx.invoke("deliver", deliverRequest(report: report, signer: "local-author", policy: policy, requestId: "delivery-3"))
        XCTAssertEqual(collide.exitCode, .invalidRequest)
        XCTAssertEqual(collide.errors.first?.path, "/out")
        let replaced = fx.invoke("deliver", deliverRequest(report: report, signer: "local-author", policy: policy, requestId: "delivery-4").merging(["replace": true]))
        XCTAssertEqual(replaced.exitCode, .success, "\(replaced.errors)")
        XCTAssertTrue(fm.fileExists(atPath: sidecarURL.path))
    }

    func testDeliverWithUnknownSignerIsIncompleteWithoutBundle() throws {
        let report = try prepare()
        let signer = try fx.makeSigner("local-author")
        let policy = try fx.trustPolicy(signers: [signer], trusted: ["local-author"])
        let envelope = fx.invoke("deliver", deliverRequest(report: report, signer: "ghost", policy: policy))
        XCTAssertEqual(envelope.status, .incomplete)
        XCTAssertEqual(envelope.exitCode, .missingCapability)
        XCTAssertEqual(envelope.errors.map(\.code), [.missingCredential])
        XCTAssertEqual(envelope.errors.first?.path, "/signer")
        XCTAssertEqual(envelope.result?["verdict"], "incomplete")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.root.appendingPathComponent("delivery").path))
        XCTAssertNil(try fx.store.receipt(requestId: "delivery-1"))
        XCTAssertEqual(SHA256Hex.hex(try Data(contentsOf: vrmURL)), vrmSha)

        let keyless = try fx.makeSigner("keyless", storeKey: false)
        let policy2 = try fx.trustPolicy(signers: [keyless], trusted: ["keyless"], name: "trust2.json")
        let noKey = fx.invoke("deliver", deliverRequest(report: report, signer: "keyless", policy: policy2))
        XCTAssertEqual(noKey.status, .incomplete)
        XCTAssertEqual(noKey.errors.first?.code, .missingCredential)
        let noPolicy = fx.invoke("deliver", deliverRequest(report: report, signer: "local-author", policy: ["path": "/nonexistent/trust.json", "sha256": .string(String(repeating: "0", count: 64))]))
        XCTAssertEqual(noPolicy.status, .incomplete)
        XCTAssertEqual(noPolicy.errors.first?.code, .missingCredential)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.root.appendingPathComponent("delivery").path))
    }

    func testDeliverWithUntrustedSignerFailsWithoutBundle() throws {
        let report = try prepare()
        let signer = try fx.makeSigner("local-author")
        let policy = try fx.trustPolicy(signers: [signer], trusted: [])
        let envelope = fx.invoke("deliver", deliverRequest(report: report, signer: "local-author", policy: policy))
        XCTAssertEqual(envelope.status, .failed)
        XCTAssertEqual(envelope.exitCode, .gateFailed)
        XCTAssertEqual(envelope.errors.map(\.code), [.untrustedSigner])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.root.appendingPathComponent("delivery").path))
    }

    func testDeliverRequiresPassingReportForExactBytes() throws {
        let signer = try fx.makeSigner("local-author")
        let policy = try fx.trustPolicy(signers: [signer], trusted: ["local-author"])

        let stale = try prepare(reportHash: String(repeating: "d", count: 64))
        let staleResult = fx.invoke("deliver", deliverRequest(report: stale, signer: "local-author", policy: policy))
        XCTAssertEqual(staleResult.status, .failed)
        XCTAssertEqual(staleResult.errors.map(\.code), [.reportMismatch])
        XCTAssertEqual(staleResult.errors.first?.required, .string(vrmSha))

        let failing = try fx.writeReport(for: vrmSha, status: "fail")
        let failed = fx.invoke("deliver", deliverRequest(report: failing, signer: "local-author", policy: policy))
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.errors.map(\.code), [.gateFailed])

        let missing = fx.invoke("deliver", deliverRequest(report: fx.root.appendingPathComponent("nope.json"), signer: "local-author", policy: policy))
        XCTAssertEqual(missing.status, .incomplete)
        XCTAssertEqual(missing.errors.first?.code, .missingInput)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.root.appendingPathComponent("delivery").path))
    }

    func testDeliverRequiresInspectionCoverageAndResolvedRights() throws {
        let signer = try fx.makeSigner("local-author")
        let policy = try fx.trustPolicy(signers: [signer], trusted: ["local-author"])

        let report = try prepare(inspection: nil)
        let uninspected = fx.invoke("deliver", deliverRequest(report: report, signer: "local-author", policy: policy))
        XCTAssertEqual(uninspected.status, .incomplete)
        XCTAssertEqual(uninspected.errors.map(\.code), [.inspectionMissing])
        XCTAssertEqual(uninspected.errors.first?.observed?["pass"], 0)

        try fx.writeInspection(for: String(repeating: "e", count: 64), verdict: "pass", index: 1)
        XCTAssertEqual(fx.invoke("deliver", deliverRequest(report: report, signer: "local-author", policy: policy)).errors.map(\.code), [.inspectionMissing])

        try fx.writeInspection(for: vrmSha, verdict: "pass", index: 1)
        try fx.writeInspection(for: vrmSha, verdict: "uncertain", index: 2)
        let uncertain = fx.invoke("deliver", deliverRequest(report: report, signer: "local-author", policy: policy))
        XCTAssertEqual(uncertain.status, .failed)
        XCTAssertEqual(uncertain.errors.map(\.code), [.gateFailed])
        let coverage = try DefaultInspectionCoverage().coverage(for: vrmSha, in: fx.store)
        XCTAssertEqual(coverage.passCount, 1)
        XCTAssertEqual(coverage.uncertainCount, 1)
        XCTAssertFalse(coverage.isCovered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.root.appendingPathComponent("delivery").path))

        let fresh = try ProvenanceFixture()
        defer { fresh.tearDown() }
        let freshVRM = try fresh.write(vrmData, "avatar.vrm")
        try fresh.writeInspection(for: vrmSha, verdict: "pass")
        let freshReport = try fresh.writeReport(for: vrmSha)
        let freshSigner = try fresh.makeSigner("local-author")
        let freshPolicy = try fresh.trustPolicy(signers: [freshSigner], trusted: ["local-author"])
        let unresolved = fresh.invoke("deliver", ["file": .string(freshVRM.path), "report": .string(freshReport.path), "signer": "local-author", "trustPolicy": freshPolicy,
                                                  "out": .string(fresh.root.appendingPathComponent("delivery").path)])
        XCTAssertEqual(unresolved.status, .incomplete)
        XCTAssertEqual(unresolved.errors.first?.code, .missingInput)
        XCTAssertTrue(unresolved.errors.first?.suggestedCommands.contains("provenance resolve") ?? false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.root.appendingPathComponent("delivery").path))
    }

    func testInspectionCoverageIgnoresUnreadableAndForeignRecords() throws {
        let dir = DefaultInspectionCoverage.directory(for: vrmSha, in: fx.store)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("broken.json"))
        try fx.writeInspection(for: vrmSha, verdict: "pass", index: 7)
        let coverage = try DefaultInspectionCoverage().coverage(for: vrmSha, in: fx.store)
        XCTAssertEqual(coverage.records, ["7.json"])
        XCTAssertEqual(coverage.unreadable, ["broken.json"])
        XCTAssertTrue(coverage.isCovered)
        XCTAssertEqual(try DefaultInspectionCoverage().coverage(for: String(repeating: "0", count: 64), in: fx.store).passCount, 0)
    }
}
