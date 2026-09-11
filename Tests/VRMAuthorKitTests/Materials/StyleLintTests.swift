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

/// `style lint` against the pinned oracle: the git-tracked U fixture, style
/// mutants of it, the acceptance-pack negative/degenerate fixtures, and the
/// toolchain gates (oracle hash mismatch, missing python3).
final class StyleLintTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try MaterialsTestSupport.tempDir()
        if StyleToolchain.python3(env: ProcessInfo.processInfo.environment) == nil { throw XCTSkip("python3 not on PATH") }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func fixture() throws -> URL {
        guard let url = MaterialsTestSupport.fixtureURL else { throw XCTSkip("\(MaterialsTestSupport.fixtureName) not present at the repository root") }
        return url
    }

    private func lint(_ file: URL, extra: [String: JSONValue] = [:], context: OperationContext = MaterialsTestSupport.context()) -> ResultEnvelope {
        MaterialsTestSupport.invoke("style lint", JSONValue.object(["file": .string(file.path)]).merging(extra), context: context)
    }

    func testFixtureConformsAndReportsOracleHashes() throws {
        let envelope = lint(try fixture())
        XCTAssertEqual(envelope.exitCode, .success, "\(envelope.errors)")
        XCTAssertEqual(envelope.status, .succeeded)
        XCTAssertEqual(envelope.result?["verdict"], "conforming")
        XCTAssertEqual(envelope.result?["report"]?["profile"], "vroid-lineage-anime")
        XCTAssertEqual(envelope.result?["report"]?["profile_version"], "0.1.0")
        XCTAssertEqual(envelope.result?["report"]?["summary"]?["must"]?["fail"], 0)
        XCTAssertEqual(envelope.result?["report"]?["summary"]?["should"]?["fail"], 0)
        XCTAssertEqual(envelope.result?["oracleHashes"]?[StyleToolchain.linterRelativePath], .string(StyleToolchain.pinnedLinterSHA256))
        XCTAssertEqual(envelope.result?["oracleHashes"]?[StyleToolchain.profileRelativePath], .string(StyleToolchain.pinnedProfileSHA256))
        XCTAssertEqual(MaterialsTestSupport.ruleStatus(envelope.result?["report"], "outline.surface_present"), "pass")
        XCTAssertTrue(envelope.warnings.isEmpty, "\(envelope.warnings)")
        XCTAssertNil(envelope.revisionBefore)
    }

    func testOutlineMutantFlipsShouldRuleWithoutFailingTheGate() throws {
        let mutant = try XCTUnwrap(try MaterialsTestSupport.mutantFixture(into: root, name: "outlines-removed.vrm") { json in
            MaterialsTestSupport.setMToon(&json, materialNameContains: ["SKIN", "CLOTH"], "outlineWidthMode", "none")
        })
        let envelope = lint(mutant)
        XCTAssertEqual(envelope.exitCode, .success)
        XCTAssertEqual(envelope.result?["verdict"], "conforming-with-warnings")
        XCTAssertEqual(MaterialsTestSupport.ruleStatus(envelope.result?["report"], "outline.surface_present"), "fail")
        XCTAssertEqual(MaterialsTestSupport.ruleStatus(envelope.result?["report"], "shade.face_never_deep_shadowed"), "pass")
        XCTAssertEqual(envelope.result?["report"]?["summary"]?["must"]?["fail"], 0)
        XCTAssertGreaterThan(envelope.result?["report"]?["summary"]?["should"]?["fail"]?.number ?? 0, 0)
        let warning = try XCTUnwrap(envelope.warnings.first { $0.code == "STYLE_SHOULD_FAILED" })
        XCTAssertTrue(warning.message.contains("outline.surface_present"))
    }

    func testToonFaceMutantFlipsFaceRuleOnly() throws {
        let mutant = try XCTUnwrap(try MaterialsTestSupport.mutantFixture(into: root, name: "toon-face.vrm") { json in
            MaterialsTestSupport.setMToon(&json, materialNameContains: ["Face_00_SKIN"], "shadingShiftFactor", -0.05)
            MaterialsTestSupport.setMToon(&json, materialNameContains: ["Face_00_SKIN"], "shadingToonyFactor", 0.95)
        })
        let envelope = lint(mutant)
        XCTAssertEqual(envelope.exitCode, .success)
        XCTAssertEqual(MaterialsTestSupport.ruleStatus(envelope.result?["report"], "shade.face_never_deep_shadowed"), "fail")
        XCTAssertEqual(MaterialsTestSupport.ruleStatus(envelope.result?["report"], "shade.body_two_tone"), "pass")
    }

    func testMustMutantFailsTheGateWithExitOne() throws {
        let mutant = try XCTUnwrap(try MaterialsTestSupport.mutantFixture(into: root, name: "blink-dropped.vrm") { json in
            var root = json.object!
            var extensions = root["extensions"]!.object!
            var vrm = extensions["VRMC_vrm"]!.object!
            var expressions = vrm["expressions"]!.object!
            var preset = expressions["preset"]!.object!
            preset["blink"] = nil
            expressions["preset"] = .object(preset)
            vrm["expressions"] = .object(expressions)
            extensions["VRMC_vrm"] = .object(vrm)
            root["extensions"] = .object(extensions)
            json = .object(root)
        })
        let envelope = lint(mutant)
        XCTAssertEqual(envelope.status, .failed)
        XCTAssertEqual(envelope.exitCode, .gateFailed)
        XCTAssertEqual(envelope.errors.map(\.code), [.gateFailed])
        XCTAssertEqual(envelope.errors.first?.path, "/report/results/expr.core_presets")
        XCTAssertEqual(envelope.result?["verdict"], "nonconforming")
        XCTAssertEqual(MaterialsTestSupport.ruleStatus(envelope.result?["report"], "expr.core_presets"), "fail")
    }

    func testAcceptanceFixtures() throws {
        let degenerate = lint(MaterialsTestSupport.acceptanceFixtures.appendingPathComponent("degenerate-minimal-vrm.bin"))
        XCTAssertEqual(degenerate.exitCode, .gateFailed)
        XCTAssertEqual(degenerate.result?["verdict"], "nonconforming")
        XCTAssertEqual(degenerate.result?["report"]?["summary"]?["must"]?["fail"], 5)
        XCTAssertEqual(degenerate.result?["report"]?["summary"]?["should"]?["fail"], 19)
        XCTAssertEqual(degenerate.errors.count, 5)

        let negative = lint(MaterialsTestSupport.acceptanceFixtures.appendingPathComponent("negative-not-a-glb.bin"))
        XCTAssertEqual(negative.status, .failed)
        XCTAssertEqual(negative.errors.first?.code, .validationFailed)
        XCTAssertEqual(negative.exitCode, .gateFailed)
        XCTAssertNil(negative.result)

        let missing = lint(root.appendingPathComponent("absent.vrm"))
        XCTAssertEqual(missing.errors.first?.code, .missingInput)
        XCTAssertEqual(missing.exitCode, .missingCapability)
    }

    func testOracleHashMismatchIsMissingCapability() throws {
        let tampered = root.appendingPathComponent("style_lint.py")
        var source = try Data(contentsOf: MaterialsTestSupport.repoRoot.appendingPathComponent(StyleToolchain.linterRelativePath))
        source.append(contentsOf: Array("\n# tampered\n".utf8))
        try source.write(to: tampered)
        var env = ProcessInfo.processInfo.environment
        env[StyleToolchain.linterEnvironmentKey] = tampered.path
        let envelope = lint(try fixture(), context: MaterialsTestSupport.context(env: env))
        XCTAssertEqual(envelope.exitCode, .missingCapability)
        XCTAssertEqual(envelope.errors.first?.code, .missingCapability)
        XCTAssertEqual(envelope.errors.first?.observed, .string(SHA256Hex.hex(source)))
        XCTAssertEqual(envelope.errors.first?.required, .string(StyleToolchain.pinnedLinterSHA256))

        let profileCopy = root.appendingPathComponent("profile.json")
        var profile = try Data(contentsOf: MaterialsTestSupport.pinnedProfile)
        profile.append(0x0A)
        try profile.write(to: profileCopy)
        var profileEnv = ProcessInfo.processInfo.environment
        profileEnv[StyleToolchain.profileEnvironmentKey] = profileCopy.path
        let mismatch = lint(try fixture(), context: MaterialsTestSupport.context(env: profileEnv))
        XCTAssertEqual(mismatch.exitCode, .missingCapability)
        XCTAssertEqual(mismatch.errors.first?.required, .string(StyleToolchain.pinnedProfileSHA256))

        let diagnosis = StyleToolchain.diagnose(context: MaterialsTestSupport.context(env: env))
        XCTAssertEqual(diagnosis["styleLinter"]?["matches"], false)
        XCTAssertEqual(diagnosis["ok"], false)
    }

    func testMissingPythonIsMissingCapability() throws {
        let envelope = lint(try fixture(), context: MaterialsTestSupport.context(env: ["PATH": root.path]))
        XCTAssertEqual(envelope.exitCode, .missingCapability)
        XCTAssertEqual(envelope.errors.first?.code, .missingCapability)
        XCTAssertEqual(envelope.errors.first?.path, "python3")
    }

    func testExplicitProfileBlobAndProjectReportArtifact() throws {
        let file = try fixture()
        let pinned = lint(file, extra: ["profile": ["path": .string(MaterialsTestSupport.pinnedProfile.path), "sha256": .string(StyleToolchain.pinnedProfileSHA256)]])
        XCTAssertEqual(pinned.exitCode, .success)
        XCTAssertTrue(pinned.warnings.isEmpty)

        let profileCopy = root.appendingPathComponent("profile-unpinned.json")
        var profile = try Data(contentsOf: MaterialsTestSupport.pinnedProfile)
        profile.append(0x0A)
        try profile.write(to: profileCopy)
        let unpinned = lint(file, extra: ["profile": ["path": .string(profileCopy.path), "sha256": .string(SHA256Hex.hex(profile))]])
        XCTAssertEqual(unpinned.exitCode, .success, "\(unpinned.errors)")
        XCTAssertEqual(unpinned.warnings.map(\.code), ["PROFILE_NOT_PINNED"])
        XCTAssertEqual(unpinned.result?["oracleHashes"]?[profileCopy.path], .string(SHA256Hex.hex(profile)))
        let wrong = lint(file, extra: ["profile": ["path": .string(profileCopy.path), "sha256": .string(StyleToolchain.pinnedProfileSHA256)]])
        XCTAssertEqual(wrong.exitCode, .invalidRequest)

        let projectURL = root.appendingPathComponent("avatar.vrmauthor")
        let store = try MaterialsTestSupport.makeProject(at: projectURL, materials: [])
        let withProject = lint(file, extra: ["project": .string(projectURL.path)], context: MaterialsTestSupport.context(projectPath: projectURL))
        XCTAssertEqual(withProject.exitCode, .success)
        let artifact = try XCTUnwrap(withProject.artifacts.first)
        XCTAssertEqual(artifact.role, "style-lint-report")
        XCTAssertTrue(artifact.path.hasPrefix(store.reportsDirectory.appendingPathComponent("style-lint").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))
        XCTAssertEqual(try SHA256Hex.hex(fileAt: URL(fileURLWithPath: artifact.path)), artifact.sha256)
        XCTAssertEqual(try store.state().revision, 0, "lint is a read; no revision is created")
    }
}
