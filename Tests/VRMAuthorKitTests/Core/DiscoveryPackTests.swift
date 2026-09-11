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

final class DiscoveryPackTests: XCTestCase {
    private static let acceptanceDirectory: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            let candidate = url.appendingPathComponent(EvidenceRegistry.relativePath)
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("evidence.json").path) { return candidate }
        }
        return url
    }()

    private func context(env: [String: String] = [:]) throws -> OperationContext {
        let evidence = try EvidenceRegistry.load(acceptanceDirectory: DiscoveryPackTests.acceptanceDirectory)
        return OperationContext(cwd: URL(fileURLWithPath: NSTemporaryDirectory()), env: env.isEmpty ? ProcessInfo.processInfo.environment : env,
                                evidenceRegistry: evidence, registry: Registry.v1())
    }

    private func invoke(_ name: String, _ request: JSONValue = [:], env: [String: String] = [:]) throws -> ResultEnvelope {
        let ctx = try context(env: env)
        return ctx.registry.invoke(name, request: request, context: ctx)
    }

    func testVersion() throws {
        let envelope = try invoke("version")
        XCTAssertEqual(envelope.exitCode, .success)
        XCTAssertEqual(envelope.result?["tool"], "vrm-author")
        XCTAssertEqual(envelope.result?["protocol"], "vrmauthor/1")
        XCTAssertEqual(envelope.result?["abi"], "vrmauthor-abi/1")
        XCTAssertEqual(envelope.result?["version"], .string(ToolInfo.current.version))
        XCTAssertEqual(envelope.revisionBefore, nil)
    }

    func testDescribeListsThirtyFiveCommandsWithSchemasUnitsAndEvidence() throws {
        let envelope = try invoke("describe")
        XCTAssertEqual(envelope.exitCode, .success)
        let commands = try XCTUnwrap(envelope.result?["commands"]?.array)
        XCTAssertEqual(commands.count, 35)
        XCTAssertEqual(commands.map { $0["name"]?.string ?? "" }, Registry.v1Names)
        let runnable = commands.filter { $0["runnable"] == true }.map { $0["name"]!.string! }
        let implemented = Registry.v1().ordered.filter(\.isRunnable).map(\.name)
        XCTAssertEqual(runnable, Registry.v1Names.filter { implemented.contains($0) })
        for c in commands {
            XCTAssertNotNil(c["requestSchema"]?["properties"], c["name"]?.string ?? "")
            XCTAssertNotNil(c["resultSchema"], c["name"]?.string ?? "")
            XCTAssertEqual(c["schemaHash"]?.string?.count, 64)
            XCTAssertNotNil(EvidenceLevel(rawValue: c["requiredEvidence"]?.string ?? ""))
            XCTAssertFalse(c["examples"]?.array?.isEmpty ?? true, c["name"]?.string ?? "")
            XCTAssertNil(c["evidenceStatus"], "describe must not report evidence status")
        }
        let shading = commands.first { $0["name"] == "material shading" }!
        XCTAssertEqual(shading["units"]?["/shadowEnd"], "normalized")
        XCTAssertEqual(shading["requiredEvidence"], "visually-validated")
        XCTAssertEqual(shading["rpcMethod"], "material.shading")
        XCTAssertEqual(shading["kind"], "mutation")
        let single = try invoke("describe", ["command": "recipe apply"])
        XCTAssertEqual(single.result?["commands"]?.array?.count, 1)
        XCTAssertEqual(single.result?["commands"]?[0]?["requestSchema"]?["properties"]?["recipe"]?["properties"]?["hair"]?["type"], "array")
        XCTAssertEqual(try invoke("describe", ["command": "nope"]).exitCode, .invalidRequest)
        let reserved = try invoke("describe", ["namespace": "reserved"])
        XCTAssertEqual(reserved.result?["commands"], [])
        XCTAssertEqual(reserved.warnings.first?.code, "RESERVED_NAMESPACE_EMPTY")
    }

    func testCapabilitiesAreSchemaOnlyPendingExceptDiscoveryHandlers() throws {
        let envelope = try invoke("capabilities")
        XCTAssertEqual(envelope.exitCode, .success)
        let r = try XCTUnwrap(envelope.result)
        let entries = try XCTUnwrap(r["entries"]?.array)
        XCTAssertEqual(entries.count, 35)
        let implemented = Registry.v1().ordered.filter(\.isRunnable).map(\.name)
        for e in entries {
            let name = e["operation"]!.string!
            XCTAssertEqual(e["evidenceLevel"], "schema-only", name)
            XCTAssertEqual(e["evidenceStatus"], "pending", name)
            XCTAssertEqual(e["productionEligible"], false, name)
            XCTAssertEqual(e["runnable"]?.bool, implemented.contains(name), name)
            XCTAssertEqual(e["availability"], implemented.contains(name) ? "implemented" : "schema-only", name)
            XCTAssertEqual(e["implementationHash"] == nil, !implemented.contains(name), name)
            XCTAssertEqual(e["schemaHash"]?.string?.count, 64)
            XCTAssertEqual(e["backendHash"]?.string?.count, 64)
            XCTAssertEqual(Set(e["dimensions"]!.object!.keys), Set(evidenceDimensions))
            XCTAssertFalse(e["blockers"]!.array!.isEmpty, name)
            XCTAssertNotNil(e["scope"]?["targets"])
            XCTAssertNotNil(e["evaluationPolicyHash"])
            XCTAssertEqual(e["evaluators"], [])
            XCTAssertEqual(e["artifactRefs"], [])
        }
        let lint = entries.first { $0["operation"] == "style lint" }!
        XCTAssertEqual(lint["acceptancePackHash"]?.string?.count, 64)
        XCTAssertEqual(lint["dimensions"]?["visual"]?["status"], "notApplicable")
        XCTAssertEqual(lint["dimensions"]?["corpus"]?["status"], "pending")
        XCTAssertFalse(lint["blockers"]!.array!.isEmpty)
        let build = entries.first { $0["operation"] == "build" }!
        XCTAssertTrue(build["blockers"]!.array!.contains("visual gate pending"))
        XCTAssertNil(build["acceptancePackHash"])
        XCTAssertEqual(r["targets"], ["portable-vrm1"])
        XCTAssertEqual(r["backends"], ["portable-strict/1"])
        XCTAssertEqual(r["templateHashes"]?.object?.keys.sorted(), ["native-anime-v1"])
        XCTAssertEqual(r["templateHashes"]?["native-anime-v1"]?.string?.count, 64)
        XCTAssertNotNil(r["supportedImports"]?.array)
        XCTAssertEqual(r["signerAvailable"], false)
        XCTAssertNotNil(r["renderers"]?.array)
        XCTAssertEqual(r["pinnedCommit"]?.string?.count, 40)
    }

    func testEvidencePolicyCanOnlyTighten() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let strict = dir.appendingPathComponent("strict.json")
        try Data(#"{"minimumLevel":"visually-validated","requireCurrent":false}"#.utf8).write(to: strict)
        let envelope = try invoke("capabilities", ["evidencePolicy": .string(strict.path)])
        XCTAssertEqual(envelope.exitCode, .success)
        XCTAssertEqual(envelope.warnings.first?.code, "EVIDENCE_POLICY_NOT_WEAKENED")
        XCTAssertEqual(envelope.result?["evidencePolicy"]?["requireCurrent"], true)
        let version = envelope.result!["entries"]!.array!.first { $0["operation"] == "version" }!
        XCTAssertTrue(version["blockers"]!.array!.contains("evidence level schema-only below required visually-validated"))
        let bad = dir.appendingPathComponent("bad.json")
        try Data(#"{"minimumLevel":"hand-wavy"}"#.utf8).write(to: bad)
        XCTAssertEqual(try invoke("capabilities", ["evidencePolicy": .string(bad.path)]).exitCode, .invalidRequest)
        XCTAssertEqual(try invoke("capabilities", ["evidencePolicy": "/nonexistent.json"]).exitCode, .missingCapability)
    }

    func testEvidenceEntriesDriveStatusAndStaleness() throws {
        let op = Registry.v1SchemaOnly().operation(named: "style lint")!
        let base = try EvidenceRegistry.load(acceptanceDirectory: DiscoveryPackTests.acceptanceDirectory)
        let pack = try XCTUnwrap(base.packs["style lint"])
        var registry = base
        registry.entries = [EvidenceEntry(operation: "style lint", packHash: pack.packHash, requestSchemaHash: op.schemaHash, evidenceLevel: .corpusValidated, evidenceStatus: .current,
                                          dimensions: ["fixture": DimensionRecord(status: .pass, reportHash: String(repeating: "1", count: 64)), "corpus": DimensionRecord(status: .pass), "provenance": DimensionRecord(status: .pass)])]
        let current = registry.capability(for: op, toolInfo: .current)
        XCTAssertEqual(current.evidenceStatus, .current)
        XCTAssertEqual(current.evidenceLevel, .corpusValidated)
        XCTAssertEqual(current.dimensions["fixture"]?.reportHash, String(repeating: "1", count: 64))
        XCTAssertEqual(current.blockers, ["handler not implemented"])
        XCTAssertFalse(current.productionEligible)
        var runnable = op
        runnable.handler = { _, _ in .succeeded(requestId: nil, result: nil) }
        XCTAssertTrue(registry.capability(for: runnable, toolInfo: .current).productionEligible)
        registry.entries[0].packHash = String(repeating: "0", count: 64)
        let stale = registry.capability(for: runnable, toolInfo: .current)
        XCTAssertEqual(stale.evidenceStatus, .stale)
        XCTAssertFalse(stale.productionEligible)
        XCTAssertTrue(stale.blockers.contains { $0.hasPrefix("evidence stale") })
        registry.entries[0].packHash = pack.packHash
        registry.entries[0].requestSchemaHash = String(repeating: "0", count: 64)
        XCTAssertEqual(registry.capability(for: runnable, toolInfo: .current).evidenceStatus, .stale)
        registry.entries[0].requestSchemaHash = op.schemaHash
        registry.entries[0].evidenceStatus = .failed
        XCTAssertTrue(registry.capability(for: runnable, toolInfo: .current).blockers.contains("evidence failed"))
        XCTAssertFalse(registry.capability(for: runnable, toolInfo: .current, policy: EvidencePolicy(minimumLevel: .visuallyValidated)).productionEligible)
    }

    func testSchemaShowEnumeratesLeavesAndRejectsUnknownNames() throws {
        let material = try invoke("schema show", ["name": "Material"])
        XCTAssertEqual(material.exitCode, .success)
        XCTAssertEqual(material.result?["kind"], "model")
        let leaves = try XCTUnwrap(material.result?["leaves"]?.array?.compactMap { $0.string })
        for key in ["/id", "/role", "/gltf", "/mtoon"] { XCTAssertTrue(leaves.contains { $0.hasPrefix(key) }, key) }
        XCTAssertEqual(material.result?["applicability"], ["recipe apply"])
        XCTAssertEqual(material.result?["schemaHash"], .string(MaterialObject.schema.schemaHash))

        let recipe = try invoke("schema show", ["name": "Recipe"])
        let recipeLeaves = try XCTUnwrap(recipe.result?["leaves"]?.array?.compactMap { $0.string })
        XCTAssertTrue(recipeLeaves.contains("/lookAt/rangeMapHorizontalInner/inputMaxValue"))
        XCTAssertTrue(recipeLeaves.contains("/rights/meta/avatarPermission"))
        XCTAssertTrue(recipeLeaves.contains("/template/sha256"))
        XCTAssertTrue(recipeLeaves.contains("/hair"))

        let op = try invoke("schema show", ["name": "recipe apply"])
        XCTAssertEqual(op.result?["kind"], "operation-request")
        XCTAssertEqual(op.result?["schemaHash"], .string(Registry.v1().operation(named: "recipe apply")!.schemaHash))
        XCTAssertEqual(try invoke("schema show", ["name": "recipe apply result"]).result?["kind"], "operation-result")
        XCTAssertEqual(try invoke("schema show", ["name": "Nope"]).exitCode, .invalidRequest)
        XCTAssertEqual(try invoke("schema show", [:]).exitCode, .invalidRequest)
    }

    func testDoctorReportsEnvironment() throws {
        let envelope = try invoke("doctor")
        XCTAssertEqual(envelope.exitCode, .success)
        let r = try XCTUnwrap(envelope.result)
        for key in ["python3", "styleLinter", "renderer", "signer", "determinism", "acceptance", "ok"] { XCTAssertNotNil(r[key], key) }
        XCTAssertEqual(r["signer"]?["available"], false)
        XCTAssertEqual(r["determinism"]?["backend"], "portable-strict/1")
        XCTAssertEqual(r["determinism"]?["threads"], 1)
        XCTAssertEqual(r["styleLinter"]?["found"], true)
        XCTAssertEqual(r["styleLinter"]?["pinnedSha256"]?.string?.count, 64)
        XCTAssertEqual(r["acceptance"]?["packs"], 1)
        XCTAssertTrue(envelope.warnings.contains { $0.code == "SIGNER_UNAVAILABLE" })
        let noPython = try invoke("doctor", env: ["PATH": "/nonexistent"])
        XCTAssertEqual(noPython.result?["python3"]?["found"], false)
        XCTAssertEqual(noPython.result?["ok"], false)
        XCTAssertTrue(noPython.warnings.contains { $0.code == "PYTHON3_MISSING" })
    }

    func testEvidenceRegistryLocatorAndDefaults() throws {
        let cwd = DiscoveryPackTests.acceptanceDirectory.deletingLastPathComponent()
        XCTAssertEqual(EvidenceRegistry.locate(cwd: cwd, executableURL: nil, env: [:])?.path, DiscoveryPackTests.acceptanceDirectory.path)
        XCTAssertNil(EvidenceRegistry.locate(cwd: URL(fileURLWithPath: "/"), executableURL: nil, env: [:]))
        XCTAssertEqual(EvidenceRegistry.locate(cwd: URL(fileURLWithPath: "/"), executableURL: nil, env: [EvidenceRegistry.environmentKey: DiscoveryPackTests.acceptanceDirectory.path])?.path,
                       DiscoveryPackTests.acceptanceDirectory.path)
        let empty = EvidenceRegistry()
        let entry = empty.capability(for: Registry.v1().operation(named: "version")!, toolInfo: .current)
        XCTAssertEqual(entry.evidenceLevel, .schemaOnly)
        XCTAssertEqual(entry.evidenceStatus, .pending)
        XCTAssertTrue(entry.blockers.contains("no acceptance pack registered"))
        XCTAssertEqual(entry.dimensions.values.map(\.status), Array(repeating: .pending, count: 5))
    }
}
