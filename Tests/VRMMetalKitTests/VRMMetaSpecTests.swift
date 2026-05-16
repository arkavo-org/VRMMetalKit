//
// Copyright 2025 Arkavo
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

import XCTest
@testable import VRMMetalKit

/// Tests for VRM 1.0 meta-field spec compliance (J1–J5, O3, O4).
final class VRMMetaSpecTests: XCTestCase {

    private var parser: VRMExtensionParser!

    override func setUp() {
        super.setUp()
        parser = VRMExtensionParser()
    }

    override func tearDown() {
        parser = nil
        super.tearDown()
    }

    // MARK: - Shared helpers

    /// Minimal set of humanoid bones accepted by VRMHumanoid.validate().
    private var minimalHumanBones: [String: Any] {
        [
            "hips": ["node": 0],
            "spine": ["node": 1],
            "head": ["node": 2],
            "leftUpperArm": ["node": 3],
            "leftLowerArm": ["node": 4],
            "leftHand": ["node": 5],
            "rightUpperArm": ["node": 6],
            "rightLowerArm": ["node": 7],
            "rightHand": ["node": 8],
            "leftUpperLeg": ["node": 9],
            "leftLowerLeg": ["node": 10],
            "leftFoot": ["node": 11],
            "rightUpperLeg": ["node": 12],
            "rightLowerLeg": ["node": 13],
            "rightFoot": ["node": 14],
        ]
    }

    private func makeGLTFDocument(extensionsRequired: [String]? = nil) -> GLTFDocument {
        var json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "Test"],
            "scene": 0,
            "scenes": [["nodes": Array(0..<20)]],
            "nodes": (0..<20).map { i in ["name": "node_\(i)"] },
        ]
        if let req = extensionsRequired {
            json["extensionsRequired"] = req
        }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(GLTFDocument.self, from: data)
    }

    private func makeVRM1Dict(meta: [String: Any], includeHumanoid: Bool = true) -> [String: Any] {
        var dict: [String: Any] = ["specVersion": "1.0", "meta": meta]
        if includeHumanoid {
            dict["humanoid"] = ["humanBones": minimalHumanBones]
        }
        return dict
    }

    private func makeVRM0Dict(meta: [String: Any]) -> [String: Any] {
        [
            "version": "0.0",
            "meta": meta,
            "humanoid": ["humanBones": [
                ["bone": "hips", "node": 0],
                ["bone": "spine", "node": 1],
                ["bone": "head", "node": 2],
                ["bone": "leftUpperArm", "node": 3],
                ["bone": "leftLowerArm", "node": 4],
                ["bone": "leftHand", "node": 5],
                ["bone": "rightUpperArm", "node": 6],
                ["bone": "rightLowerArm", "node": 7],
                ["bone": "rightHand", "node": 8],
                ["bone": "leftUpperLeg", "node": 9],
                ["bone": "leftLowerLeg", "node": 10],
                ["bone": "leftFoot", "node": 11],
                ["bone": "rightUpperLeg", "node": 12],
                ["bone": "rightLowerLeg", "node": 13],
                ["bone": "rightFoot", "node": 14],
            ]],
        ]
    }

    // MARK: - J1: licenseUrl required for VRM 1.0

    func testVRM1_MissingLicenseUrl_Throws() {
        let vrmDict = makeVRM1Dict(meta: ["name": "Test"])
        let document = makeGLTFDocument()

        XCTAssertThrowsError(try parser.parseVRMExtension(vrmDict, document: document)) { error in
            guard case VRMError.invalidMeta = error else {
                XCTFail("Expected invalidMeta, got \(error)")
                return
            }
        }
    }

    func testVRM1_EmptyLicenseUrl_Throws() {
        let vrmDict = makeVRM1Dict(meta: ["name": "Test", "licenseUrl": ""])
        let document = makeGLTFDocument()

        XCTAssertThrowsError(try parser.parseVRMExtension(vrmDict, document: document)) { error in
            guard case VRMError.invalidMeta = error else {
                XCTFail("Expected invalidMeta, got \(error)")
                return
            }
        }
    }

    func testVRM1_ValidLicenseUrl_Succeeds() throws {
        let vrmDict = makeVRM1Dict(meta: [
            "name": "Test",
            "licenseUrl": "https://vrm.dev/licenses/1.0/",
        ])
        let document = makeGLTFDocument()
        let model = try parser.parseVRMExtension(vrmDict, document: document)
        XCTAssertEqual(model.meta.licenseUrl, "https://vrm.dev/licenses/1.0/")
    }

    func testVRM0_MissingLicenseUrl_Tolerant() throws {
        let vrmDict = makeVRM0Dict(meta: ["title": "Test", "author": "Tester"])
        let document = makeGLTFDocument()
        let model = try parser.parseVRMExtension(vrmDict, document: document)
        XCTAssertEqual(model.meta.licenseUrl, "")
    }

    func testVRM0_EmptyLicenseUrl_Tolerant() throws {
        let vrmDict = makeVRM0Dict(meta: [
            "title": "Test",
            "author": "Tester",
            "otherLicenseUrl": "",
        ])
        let document = makeGLTFDocument()
        let model = try parser.parseVRMExtension(vrmDict, document: document)
        XCTAssertEqual(model.meta.licenseUrl, "")
    }

    // MARK: - J2-J5: four usage permission fields

    func testUsagePermissions_AllTrue() throws {
        let vrmDict = makeVRM1Dict(meta: [
            "name": "Test",
            "licenseUrl": "https://vrm.dev/licenses/1.0/",
            "allowExcessivelyViolentUsage": true,
            "allowExcessivelySexualUsage": true,
            "allowPoliticalOrReligiousUsage": true,
            "allowAntisocialOrHateUsage": true,
        ])
        let document = makeGLTFDocument()
        let model = try parser.parseVRMExtension(vrmDict, document: document)

        XCTAssertEqual(model.meta.allowExcessivelyViolentUsage, true)
        XCTAssertEqual(model.meta.allowExcessivelySexualUsage, true)
        XCTAssertEqual(model.meta.allowPoliticalOrReligiousUsage, true)
        XCTAssertEqual(model.meta.allowAntisocialOrHateUsage, true)
    }

    func testUsagePermissions_AllFalse() throws {
        let vrmDict = makeVRM1Dict(meta: [
            "name": "Test",
            "licenseUrl": "https://vrm.dev/licenses/1.0/",
            "allowExcessivelyViolentUsage": false,
            "allowExcessivelySexualUsage": false,
            "allowPoliticalOrReligiousUsage": false,
            "allowAntisocialOrHateUsage": false,
        ])
        let document = makeGLTFDocument()
        let model = try parser.parseVRMExtension(vrmDict, document: document)

        XCTAssertEqual(model.meta.allowExcessivelyViolentUsage, false)
        XCTAssertEqual(model.meta.allowExcessivelySexualUsage, false)
        XCTAssertEqual(model.meta.allowPoliticalOrReligiousUsage, false)
        XCTAssertEqual(model.meta.allowAntisocialOrHateUsage, false)
    }

    func testUsagePermissions_Absent_NilAndDefaultFalse() throws {
        let vrmDict = makeVRM1Dict(meta: [
            "name": "Test",
            "licenseUrl": "https://vrm.dev/licenses/1.0/",
        ])
        let document = makeGLTFDocument()
        let model = try parser.parseVRMExtension(vrmDict, document: document)

        XCTAssertNil(model.meta.allowExcessivelyViolentUsage)
        XCTAssertNil(model.meta.allowExcessivelySexualUsage)
        XCTAssertNil(model.meta.allowPoliticalOrReligiousUsage)
        XCTAssertNil(model.meta.allowAntisocialOrHateUsage)

        XCTAssertFalse(model.meta.allowExcessivelyViolentUsageOrDefault)
        XCTAssertFalse(model.meta.allowExcessivelySexualUsageOrDefault)
        XCTAssertFalse(model.meta.allowPoliticalOrReligiousUsageOrDefault)
        XCTAssertFalse(model.meta.allowAntisocialOrHateUsageOrDefault)
    }

    // MARK: - O3: extensionsRequired validation

    func testExtensionsRequired_Unsupported_Throws() async throws {
        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["name": "root"]],
            "extensionsRequired": ["VRMC_unknown_thing"],
            "extensions": [
                "VRMC_vrm": [
                    "specVersion": "1.0",
                    "meta": ["name": "Test", "licenseUrl": "https://vrm.dev/licenses/1.0/"],
                    "humanoid": ["humanBones": minimalHumanBones],
                ],
            ],
        ]
        let glbData = try makeGLBFromJSON(json)

        do {
            _ = try await VRMModel.load(from: glbData)
            XCTFail("Expected unsupportedRequiredExtension error")
        } catch GLTFError.unsupportedRequiredExtension(let extensions) {
            XCTAssertTrue(extensions.contains("VRMC_unknown_thing"))
        } catch {
            XCTFail("Expected unsupportedRequiredExtension, got \(error)")
        }
    }

    func testExtensionsRequired_SupportedOnly_Succeeds() async throws {
        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "scene": 0,
            "scenes": [["nodes": Array(0..<15)]],
            "nodes": (0..<15).map { ["name": "node_\($0)"] as [String: Any] },
            "extensionsRequired": ["VRMC_vrm"],
            "extensionsUsed": ["VRMC_vrm"],
            "extensions": [
                "VRMC_vrm": [
                    "specVersion": "1.0",
                    "meta": ["name": "Test", "licenseUrl": "https://vrm.dev/licenses/1.0/"],
                    "humanoid": ["humanBones": minimalHumanBones],
                ],
            ],
        ]
        let glbData = try makeGLBFromJSON(json)
        let model = try await VRMModel.load(from: glbData)
        XCTAssertEqual(model.specVersion, .v1_0)
    }

    func testExtensionsRequired_NoEntry_Succeeds() async throws {
        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "scene": 0,
            "scenes": [["nodes": Array(0..<15)]],
            "nodes": (0..<15).map { ["name": "node_\($0)"] as [String: Any] },
            "extensionsUsed": ["VRMC_vrm"],
            "extensions": [
                "VRMC_vrm": [
                    "specVersion": "1.0",
                    "meta": ["name": "Test", "licenseUrl": "https://vrm.dev/licenses/1.0/"],
                    "humanoid": ["humanBones": minimalHumanBones],
                ],
            ],
        ]
        let glbData = try makeGLBFromJSON(json)
        let model = try await VRMModel.load(from: glbData)
        XCTAssertEqual(model.specVersion, .v1_0)
    }

    // MARK: - O4: specVersion warning (best-effort, must not throw)

    func testSpecVersion_Known_NoThrow() throws {
        let vrmDict = makeVRM1Dict(meta: [
            "name": "Test",
            "licenseUrl": "https://vrm.dev/licenses/1.0/",
        ])
        let document = makeGLTFDocument()
        XCTAssertNoThrow(try parser.parseVRMExtension(vrmDict, document: document))
    }

    func testSpecVersion_Unknown_NoThrow() throws {
        let vrmDict: [String: Any] = [
            "specVersion": "99.0",
            "meta": [
                "name": "FutureMod",
                "licenseUrl": "https://vrm.dev/licenses/1.0/",
            ],
            "humanoid": ["humanBones": minimalHumanBones],
        ]
        let document = makeGLTFDocument()
        XCTAssertNoThrow(try parser.parseVRMExtension(vrmDict, document: document))
    }

    // MARK: - GLB builder helper for O3 tests

    private func makeGLBFromJSON(_ json: [String: Any]) throws -> Data {
        let jsonData = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let jsonPadding = (4 - (jsonData.count % 4)) % 4
        var paddedJSON = jsonData
        if jsonPadding > 0 {
            paddedJSON.append(Data(repeating: 0x20, count: jsonPadding))
        }

        let totalLength = 12 + 8 + paddedJSON.count
        var glb = Data()
        glb.append(UInt32(0x46546C67).littleEndian.data)
        glb.append(UInt32(2).littleEndian.data)
        glb.append(UInt32(totalLength).littleEndian.data)
        glb.append(UInt32(paddedJSON.count).littleEndian.data)
        glb.append(UInt32(0x4E4F534A).littleEndian.data)
        glb.append(paddedJSON)
        return glb
    }
}

// MARK: - UInt32 Data helpers

private extension UInt32 {
    var data: Data {
        var value = self
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }
}
