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

import CoreGraphics
import Foundation
import ImageIO
import Metal
import XCTest
@testable import VRMAuthorKit

final class RenderPackTests: XCTestCase {
    private var project: TestProject!

    override func tearDownWithError() throws { project?.cleanup() }

    /// The `vrm-author-render` product built alongside the test bundle.
    static var rendererBinary: URL? {
        let directory = Bundle(for: RenderPackTests.self).bundleURL.deletingLastPathComponent()
        for name in VRMAuthorRenderLocator.binaryNames {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func makeProject(render: any RenderAdapter, env: [String: String] = [:], extra: [RegistryInstaller] = [], consumer: any ConsumerImporter = SelfReimportConsumer()) throws -> TestProject {
        let project = try TestProject.make(registry: TestProject.registry(render: render, consumer: consumer, extra: extra), env: env)
        try project.applyDefaultRecipe()
        XCTAssertEqual(project.invoke("build", ["out": .string(project.path("draft.vrm"))]).exitCode, .success)
        return project
    }

    private func scenario(_ id: String) throws -> RenderScenario {
        try XCTUnwrap(QAPins.renderScenarios().first { $0.id == id })
    }

    private func requireRealRenderer() throws -> (URL, VRMAuthorRenderAdapter, [String: String]) {
        guard let binary = RenderPackTests.rendererBinary else { throw XCTSkip("vrm-author-render is not built next to the test bundle; run `swift build --product vrm-author-render`.") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device is available on this host.") }
        let env = [VRMAuthorRenderLocator.environmentKey: binary.path]
        return (binary, VRMAuthorRenderAdapter(executableURL: nil, environment: env), env)
    }

    // MARK: PNG helpers

    static func pngSize(_ data: Data) -> (width: Int, height: Int)? {
        guard data.count >= 24, Array(data.prefix(8)) == PNGEncoder.signature else { return nil }
        func be32(_ offset: Int) -> Int { data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) } }
        return (be32(16), be32(20))
    }

    static func rgbaPixels(_ data: Data) throws -> (width: Int, height: Int, rgba: [UInt8]) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AuthorError(code: .validationFailed, message: "PNG did not decode.")
        }
        let width = image.width, height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        try rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: info) else {
                throw AuthorError(code: .validationFailed, message: "Could not create a bitmap context.")
            }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (width, height, rgba)
    }

    /// Fraction of pixels whose RGB differs from the canonical 50% grey background.
    static func coverage(_ data: Data) throws -> Double {
        let (width, height, rgba) = try rgbaPixels(data)
        var covered = 0
        for index in stride(from: 0, to: rgba.count, by: 4) {
            let isBackground = (0..<3).allSatisfy { abs(Int(rgba[index + $0]) - 128) <= 2 }
            if !isBackground { covered += 1 }
        }
        return Double(covered) / Double(width * height)
    }

    // MARK: (a) absent renderer

    func testAdapterReturnsNilWithoutBinaryAndAuthoringV1StaysIncomplete() throws {
        let adapter = VRMAuthorRenderAdapter(executableURL: nil, environment: [:])
        XCTAssertEqual(adapter.identity, VRMAuthorRenderAdapter.unavailableIdentity)
        project = try makeProject(render: adapter)
        let front = try scenario("visual.front")
        let data = try Data(contentsOf: URL(fileURLWithPath: project.path("draft.vrm")))
        XCTAssertNil(try adapter.render(scenario: front, file: URL(fileURLWithPath: project.path("draft.vrm")), data: data,
                                        outputDirectory: URL(fileURLWithPath: project.path("direct")), context: project.context))

        let plan = project.invoke("qa plan", ["suite": "authoring-v1", "file": .string(project.path("draft.vrm")), "out": .string(project.path("plan.json"))])
        XCTAssertEqual(plan.result?["plan"]?["renderer"]?["identity"]?.string, VRMAuthorRenderAdapter.unavailableIdentity)

        let envelope = project.invoke("qa run", ["request": ["file": .string(project.path("draft.vrm")), "suite": "authoring-v1"], "out": .string(project.path("qa"))])
        XCTAssertEqual(envelope.status, .incomplete)
        XCTAssertEqual(envelope.exitCode, .missingCapability)
        let report = try QAReport.load(URL(fileURLWithPath: project.path("qa/findings.json")))
        XCTAssertEqual(report.verdict, .incomplete)
        for id in ["visual.front", "visual.threeQuarter", "visual.profile", "expression.blink", "expression.aa", "expression.happy", "motion.idle"] {
            XCTAssertEqual(report.checks.first { $0.id == "\(id).render" }?.status, .incomplete, id)
        }
        XCTAssertTrue(report.requiredArtifacts.allSatisfy { $0.sha256 == nil })
        XCTAssertEqual(report.evidence, [])
    }

    func testDiscoveryReportsVrmmetalkitOnlyWhenRendererIsPresent() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vrmauthor-g-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = root.appendingPathComponent("vrm-author-render")
        try Data("#!/bin/sh\nexit 3\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        XCTAssertEqual(VRMAuthorRenderLocator.renderers(executableURL: nil, env: [:]), [])
        XCTAssertEqual(VRMAuthorRenderLocator.renderers(executableURL: root.appendingPathComponent("vrm-author"), env: [:]), [VRMAuthorRenderLocator.rendererId])
        XCTAssertEqual(VRMAuthorRenderLocator.renderers(executableURL: nil, env: [VRMAuthorRenderLocator.environmentKey: fake.path]), [VRMAuthorRenderLocator.rendererId])
        XCTAssertEqual(VRMAuthorRenderLocator.renderers(executableURL: nil, env: [VRMAuthorRenderLocator.environmentKey: root.appendingPathComponent("missing").path]), [])

        var registry = Registry.v1SchemaOnly()
        DiscoveryHandlers.install(&registry)
        let present = OperationContext(cwd: root, env: [VRMAuthorRenderLocator.environmentKey: fake.path], registry: registry)
        let capabilities = registry.invoke("capabilities", request: [:], context: present)
        XCTAssertEqual(capabilities.status, .succeeded, "\(capabilities.errors)")
        XCTAssertEqual(capabilities.result?["renderers"], [.string(VRMAuthorRenderLocator.rendererId)])
        let doctor = registry.invoke("doctor", request: [:], context: present)
        XCTAssertEqual(doctor.result?["renderer"]?["found"], true)
        XCTAssertEqual(doctor.result?["renderer"]?["renderers"], [.string(VRMAuthorRenderLocator.rendererId)])
        XCTAssertFalse(doctor.warnings.contains { $0.code == "RENDERER_MISSING" })
        let absent = OperationContext(cwd: root, env: [:], registry: registry)
        XCTAssertEqual(registry.invoke("capabilities", request: [:], context: absent).result?["renderers"], [])
        XCTAssertTrue(registry.invoke("doctor", request: [:], context: absent).warnings.contains { $0.code == "RENDERER_MISSING" })

        let adapter = VRMAuthorRenderAdapter(executableURL: nil, environment: [VRMAuthorRenderLocator.environmentKey: fake.path])
        XCTAssertEqual(adapter.identity, VRMAuthorRenderAdapter.unavailableIdentity, "a renderer that reports no device is unavailable")
        XCTAssertNil(try adapter.render(scenario: try scenario("visual.front"), file: fake, data: Data(), outputDirectory: root.appendingPathComponent("out"), context: present))
    }

    // MARK: (b) real renderer

    func testRealRendererProducesFrontViewPNGWithVerifiedHash() throws {
        let (_, adapter, env) = try requireRealRenderer()
        project = try makeProject(render: adapter, env: env)
        XCTAssertTrue(adapter.identity.hasPrefix("\(VRMAuthorRenderAdapter.rendererId)/"), adapter.identity)
        XCTAssertTrue(adapter.identity.contains("@"), adapter.identity)
        XCTAssertNotEqual(adapter.identity, VRMAuthorRenderAdapter.unavailableIdentity)

        let fileURL = URL(fileURLWithPath: project.path("draft.vrm"))
        let data = try Data(contentsOf: fileURL)
        let out = URL(fileURLWithPath: project.path("front"))
        let artifacts = try XCTUnwrap(try adapter.render(scenario: try scenario("visual.front"), file: fileURL, data: data, outputDirectory: out, context: project.context))
        XCTAssertEqual(artifacts.count, 1)
        let artifact = try XCTUnwrap(artifacts.first)
        XCTAssertEqual(artifact.path, out.appendingPathComponent("visual.front.png").path)
        XCTAssertEqual(artifact.mediaType, "image/png")
        XCTAssertEqual(artifact.role, "render:visual.front")
        let png = try Data(contentsOf: URL(fileURLWithPath: artifact.path))
        XCTAssertEqual(SHA256Hex.hex(png), artifact.sha256)
        XCTAssertEqual(artifact.sizeBytes, png.count)
        let size = try XCTUnwrap(RenderPackTests.pngSize(png))
        XCTAssertEqual(size.width, 1024)
        XCTAssertEqual(size.height, 1024)

        let manifest = try JSONValue.parse(try Data(contentsOf: out.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest["renderer"]?["id"]?.string, VRMAuthorRenderAdapter.rendererId)
        XCTAssertEqual(manifest["renderer"]?["backend"]?.string, "metal")
        XCTAssertEqual(manifest["artifacts"]?[0]?["sha256"]?.string, artifact.sha256)
        XCTAssertEqual(manifest["file"]?["sha256"]?.string, SHA256Hex.hex(data))

        let coverage = try RenderPackTests.coverage(png)
        XCTAssertGreaterThan(coverage, 0.05, "front view must show the avatar against the grey background (coverage \(coverage))")
        XCTAssertLessThan(coverage, 0.98, "front view must keep some background visible (coverage \(coverage))")
    }

    func testAdapterRejectsTamperedArtifactHash() throws {
        let (_, adapter, env) = try requireRealRenderer()
        project = try makeProject(render: adapter, env: env)
        let fileURL = URL(fileURLWithPath: project.path("draft.vrm"))
        let out = URL(fileURLWithPath: project.path("tamper"))
        let artifacts = try XCTUnwrap(try adapter.render(scenario: try scenario("visual.front"), file: fileURL, data: try Data(contentsOf: fileURL), outputDirectory: out, context: project.context))
        var manifest = try JSONValue.parse(try Data(contentsOf: out.appendingPathComponent("manifest.json")))
        var entries = manifest["artifacts"]?.array ?? []
        entries[0] = entries[0].merging(["sha256": .string(String(repeating: "0", count: 64))])
        manifest = manifest.merging(["artifacts": .array(entries)])
        XCTAssertThrowsError(try VRMAuthorRenderAdapter.artifacts(from: manifest, scenario: try scenario("visual.front"), binary: fileURL)) { error in
            XCTAssertEqual((error as? AuthorError)?.code, .validationFailed)
        }
        XCTAssertEqual(artifacts.count, 1)
    }

    // MARK: (c) determinism

    func testRepeatedFrontRenderIsByteIdentical() throws {
        let (_, adapter, env) = try requireRealRenderer()
        project = try makeProject(render: adapter, env: env)
        let fileURL = URL(fileURLWithPath: project.path("draft.vrm"))
        let data = try Data(contentsOf: fileURL)
        var hashes: [String] = []
        var pngs: [Data] = []
        for pass in 0..<2 {
            let out = URL(fileURLWithPath: project.path("pass\(pass)"))
            let artifacts = try XCTUnwrap(try adapter.render(scenario: try scenario("visual.front"), file: fileURL, data: data, outputDirectory: out, context: project.context))
            hashes.append(artifacts[0].sha256)
            pngs.append(try Data(contentsOf: URL(fileURLWithPath: artifacts[0].path)))
        }
        if hashes[0] != hashes[1] {
            let a = try RenderPackTests.rgbaPixels(pngs[0]), b = try RenderPackTests.rgbaPixels(pngs[1])
            var identical = 0
            let total = a.width * a.height
            for pixel in 0..<total where a.rgba[pixel * 4..<pixel * 4 + 4].elementsEqual(b.rgba[pixel * 4..<pixel * 4 + 4]) { identical += 1 }
            XCTFail("Two renders of visual.front differ (\(Double(identical) / Double(total) * 100)% identical pixels); PNG evidence must be reproducible.")
        }
        XCTAssertEqual(hashes[0], hashes[1])
    }

    // MARK: full suite

    func testQARunAuthoringV1RendersEveryScenarioWithRealRenderer() throws {
        let (_, adapter, env) = try requireRealRenderer()
        project = try makeProject(render: adapter, env: env, extra: [StubStyleLint.installer(verdict: "conforming")], consumer: StubVRMMetalKitConsumer())
        let envelope = project.invoke("qa run", ["request": ["file": .string(project.path("draft.vrm")), "suite": "authoring-v1"], "out": .string(project.path("qa"))])
        XCTAssertEqual(envelope.status, .succeeded, "\(envelope.errors)")
        let report = try QAReport.load(URL(fileURLWithPath: project.path("qa/findings.json")))
        XCTAssertEqual(report.verdict, .pass)
        for id in ["visual.front", "visual.threeQuarter", "visual.profile", "expression.blink", "expression.aa", "expression.happy", "motion.idle"] {
            XCTAssertEqual(report.checks.first { $0.id == "\(id).render" }?.status, .pass, id)
            XCTAssertEqual(report.scenarios.first { $0.id == id }?.status, .pass, id)
        }
        XCTAssertTrue(report.checks.first { $0.id == "visual.front.render" }?.message.contains(adapter.identity) ?? false)

        let stills = report.evidence.filter { $0.mediaType == "image/png" && !$0.role.hasPrefix("render:motion") }
        XCTAssertEqual(stills.count, 6)
        for still in stills {
            let png = try Data(contentsOf: URL(fileURLWithPath: still.path))
            XCTAssertEqual(SHA256Hex.hex(png), still.sha256, still.path)
            XCTAssertEqual(RenderPackTests.pngSize(png)?.width, 1024, still.path)
            XCTAssertGreaterThan(try RenderPackTests.coverage(png), 0.01, still.path)
        }
        let motionFrames = report.evidence.filter { $0.role == "render:motion.idle" }
        XCTAssertEqual(motionFrames.count, 5, "motion.idle captures every whole second from 0 to 4")
        let trace = try XCTUnwrap(report.evidence.first { $0.role == "trace:motion.idle" })
        let traceJSON = try JSONValue.parse(try Data(contentsOf: URL(fileURLWithPath: trace.path)))
        XCTAssertEqual(traceJSON["steps"]?.int, 480)
        XCTAssertEqual(traceJSON["frames"]?.array?.count, 481)
        XCTAssertEqual(traceJSON["springs"]?.array?.count, 1)
        let summary = try XCTUnwrap(traceJSON["summary"])
        XCTAssertNotNil(summary["maxTipPenetrationM"]?.number)
        XCTAssertNotNil(summary["maxJointVelocityMps"]?.number)
        XCTAssertTrue(report.requiredArtifacts.allSatisfy { $0.sha256 != nil })
        XCTAssertEqual(report.requiredArtifacts.count, report.evidence.count)

        let blink = try XCTUnwrap(stills.first { $0.role == "render:expression.blink" })
        let front = try XCTUnwrap(stills.first { $0.role == "render:visual.front" })
        XCTAssertNotEqual(blink.sha256, front.sha256, "expression and view scenarios must not render the same frame")
    }
}
