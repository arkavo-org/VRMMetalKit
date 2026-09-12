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

enum MaterialsTestSupport {
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(StyleToolchain.linterRelativePath).path) { return url }
        }
        return url
    }()

    static let fixtureName = "AvatarSample_U_1.0.vrm.glb"
    static var fixtureURL: URL? {
        let url = repoRoot.appendingPathComponent(fixtureName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var acceptanceFixtures: URL { repoRoot.appendingPathComponent("docs/proposals/vrm-author-cli/acceptance/fixtures") }
    static var pinnedProfile: URL { repoRoot.appendingPathComponent(StyleToolchain.profileRelativePath) }

    static func tempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vrmauthor-materials-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func context(projectPath: URL? = nil, cwd: URL = repoRoot, env: [String: String]? = nil) -> OperationContext {
        OperationContext(projectPath: projectPath, cwd: cwd, env: env ?? ProcessInfo.processInfo.environment, registry: Registry.v1())
    }

    static func invoke(_ name: String, _ request: JSONValue, context: OperationContext) -> ResultEnvelope {
        context.registry.invoke(name, request: request, context: context)
    }

    static func makeProject(at root: URL, materials: [MaterialObject]) throws -> ProjectStore {
        let store = try ProjectStore.create(at: root, name: "avatar", template: TemplateRef(id: "native-anime-v1", sha256: String(repeating: "a", count: 64)),
                                            seed: 0, lock: ["tool": "vrm-author"])
        if !materials.isEmpty {
            _ = try store.mutate(requestId: "seed-materials", payload: ["seed": 1], expectedRevision: 0, dryRun: false, expectedPlanHash: nil, operation: "recipe apply") { tx in
                for material in materials { try tx.insert(try MaterialCompiler.projectObject(for: material, provenance: ["source": "test"])) }
                return nil
            }
        }
        return store
    }

    // MARK: GLB

    static func readGLB(_ url: URL) throws -> (json: JSONValue, bin: Data) {
        let data = try Data(contentsOf: url)
        func u32(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24 }
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "glTF")
        var offset = 12
        var json: JSONValue = .null
        var bin = Data()
        while offset + 8 <= data.count {
            let length = u32(offset)
            let type = u32(offset + 4)
            let chunk = data[(offset + 8)..<(offset + 8 + length)]
            if type == 0x4E4F534A { json = try JSONValue.parse(Data(chunk)) } else if type == 0x004E4942 { bin = Data(chunk) }
            offset += 8 + length
        }
        return (json, bin)
    }

    static func writeGLB(json: JSONValue, bin: Data, to url: URL) throws {
        var jsonData = try CanonicalJSON.data(json)
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }
        var binData = bin
        while binData.count % 4 != 0 { binData.append(0) }
        var out = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        out.append(contentsOf: Array("glTF".utf8))
        append(2)
        append(UInt32(12 + 8 + jsonData.count + 8 + binData.count))
        append(UInt32(jsonData.count))
        append(0x4E4F534A)
        out.append(jsonData)
        append(UInt32(binData.count))
        append(0x004E4942)
        out.append(binData)
        try out.write(to: url)
    }

    /// Writes a copy of the U fixture with `mutate` applied to the glTF JSON.
    static func mutantFixture(into dir: URL, name: String, mutate: (inout JSONValue) throws -> Void) throws -> URL? {
        guard let fixtureURL else { return nil }
        var (json, bin) = try readGLB(fixtureURL)
        try mutate(&json)
        let url = dir.appendingPathComponent(name)
        try writeGLB(json: json, bin: bin, to: url)
        return url
    }

    static func setMToon(_ json: inout JSONValue, materialNameContains needles: [String], _ key: String, _ value: JSONValue) {
        guard var materials = json["materials"]?.array else { return }
        for index in materials.indices {
            guard let name = materials[index]["name"]?.string, needles.contains(where: { name.contains($0) }) else { continue }
            var material = materials[index].object ?? [:]
            var extensions = material["extensions"]?.object ?? [:]
            var mtoon = extensions["VRMC_materials_mtoon"]?.object ?? [:]
            mtoon[key] = value
            extensions["VRMC_materials_mtoon"] = .object(mtoon)
            material["extensions"] = .object(extensions)
            materials[index] = .object(material)
        }
        var root = json.object ?? [:]
        root["materials"] = .array(materials)
        json = .object(root)
    }

    static func ruleStatus(_ report: JSONValue?, _ id: String) -> String? {
        report?["results"]?.array?.first { $0["id"] == .string(id) }?["status"]?.string
    }

    static func luminance(_ c: [Double]) -> Double { 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2] }
}
