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

/// Tests for VRM 1.0 per-material VRMC_materials_mtoon extension parsing.
///
/// Uses in-memory GLB data with embedded MToon extensions so tests run in CI
/// without external model files.
///
/// Related GitHub Issues: #98, #104, #105
///
final class VRM1_0MaterialExtensionTests: XCTestCase {

    private var model: VRMModel!

    override func setUp() async throws {
        try await super.setUp()
        let glbData = try Self.buildGLBWithMToon()
        model = try await VRMModel.load(from: glbData, device: nil)
    }

    // MARK: - VRM 1.0 MToon Extension Tests

    func testVRM1_0HasMToonMaterial() {
        let hasMToon = model.materials.contains { $0.mtoon != nil }
        XCTAssertTrue(hasMToon, "VRM 1.0 model should have MToon materials parsed from extensions")
    }

    func testVRM1_0ShadeColorParsed() {
        let mtoonMaterials = model.materials.filter { $0.mtoon != nil }
        XCTAssertFalse(mtoonMaterials.isEmpty)

        let skin = mtoonMaterials.first { $0.name == "Skin" }
        XCTAssertNotNil(skin)
        let shadeColor = skin!.mtoon!.shadeColorFactor
        XCTAssertEqual(shadeColor.x, 0.6, accuracy: 0.01)
        XCTAssertEqual(shadeColor.y, 0.4, accuracy: 0.01)
        XCTAssertEqual(shadeColor.z, 0.3, accuracy: 0.01)
    }

    func testVRM1_0AlphaModeParsed() {
        let opaqueCount = model.materials.filter { $0.alphaMode == "OPAQUE" }.count
        let blendCount = model.materials.filter { $0.alphaMode == "BLEND" }.count
        XCTAssertGreaterThan(opaqueCount, 0, "Should have OPAQUE materials")
        XCTAssertGreaterThan(blendCount, 0, "Should have BLEND materials")
    }

    func testVRM1_0ToonyFactorParsed() {
        let skin = model.materials.first { $0.name == "Skin" }
        XCTAssertNotNil(skin?.mtoon)
        XCTAssertEqual(skin!.mtoon!.shadingToonyFactor, 0.7, accuracy: 0.01)
    }

    func testVRM1_0OutlinePropertiesParsed() {
        let skin = model.materials.first { $0.name == "Skin" }
        XCTAssertNotNil(skin?.mtoon)
        XCTAssertEqual(skin!.mtoon!.outlineWidthMode, .worldCoordinates)
        XCTAssertEqual(skin!.mtoon!.outlineWidthFactor, 0.005, accuracy: 0.0001)
        XCTAssertEqual(skin!.mtoon!.outlineColorFactor.x, 0.0, accuracy: 0.01)
    }

    func testVRM1_0MaterialVersionIsV1() {
        for material in model.materials {
            XCTAssertEqual(material.vrmVersion, .v1_0,
                "Material '\(material.name ?? "unnamed")' should have vrmVersion .v1_0")
        }
    }

    func testExtensionsFieldDecoded() {
        XCTAssertFalse(model.isVRM0)
        let vrm1HasMToon = model.materials.contains { $0.mtoon != nil }
        XCTAssertTrue(vrm1HasMToon,
            "VRM 1.0 model should have MToon from per-material VRMC_materials_mtoon extension")
    }

    // MARK: - GLB Builder Helper

    private static func buildGLBWithMToon() throws -> Data {
        let vrm = try VRMBuilder()
            .setSkeleton(.defaultHumanoid)
            .build()

        let vrmJSON = try buildVRMJSONWithMToon(vrm)
        let binaryData = vrm.gltf.binaryBufferData ?? Data()
        return try createGLB(json: vrmJSON, binaryData: binaryData)
    }

    private static func buildVRMJSONWithMToon(_ vrm: VRMModel) throws -> [String: Any] {
        let gltfData = try JSONEncoder().encode(vrm.gltf)
        var gltfDict = try JSONSerialization.jsonObject(with: gltfData) as! [String: Any]

        // Replace materials with MToon-extended versions
        let materials: [[String: Any]] = [
            [
                "name": "Skin",
                "pbrMetallicRoughness": [
                    "baseColorFactor": [0.8, 0.7, 0.6, 1.0],
                    "metallicFactor": 0.0,
                    "roughnessFactor": 1.0,
                ],
                "alphaMode": "OPAQUE",
                "doubleSided": false,
                "extensions": [
                    "VRMC_materials_mtoon": [
                        "specVersion": "1.0",
                        "shadeColorFactor": [0.6, 0.4, 0.3],
                        "shadingToonyFactor": 0.7,
                        "shadingShiftFactor": -0.1,
                        "giIntensityFactor": 0.1,
                        "outlineWidthMode": "worldCoordinates",
                        "outlineWidthFactor": 0.005,
                        "outlineColorFactor": [0.0, 0.0, 0.0],
                        "outlineLightingMixFactor": 0.5,
                        "parametricRimColorFactor": [1.0, 1.0, 1.0],
                        "parametricRimFresnelPowerFactor": 5.0,
                        "parametricRimLiftFactor": 0.0,
                    ] as [String: Any],
                ] as [String: Any],
            ],
            [
                "name": "Hair",
                "pbrMetallicRoughness": [
                    "baseColorFactor": [0.3, 0.2, 0.1, 0.9],
                    "metallicFactor": 0.0,
                    "roughnessFactor": 1.0,
                ],
                "alphaMode": "BLEND",
                "doubleSided": true,
                "extensions": [
                    "VRMC_materials_mtoon": [
                        "specVersion": "1.0",
                        "shadeColorFactor": [0.15, 0.1, 0.05],
                        "shadingToonyFactor": 0.9,
                        "transparentWithZWrite": true,
                    ] as [String: Any],
                ] as [String: Any],
            ],
        ]
        gltfDict["materials"] = materials

        var extensionsUsed = gltfDict["extensionsUsed"] as? [String] ?? []
        if !extensionsUsed.contains("VRMC_materials_mtoon") {
            extensionsUsed.append("VRMC_materials_mtoon")
        }
        gltfDict["extensionsUsed"] = extensionsUsed

        // Add VRMC_vrm extension
        var extensions = gltfDict["extensions"] as? [String: Any] ?? [:]
        var vrmcVrm: [String: Any] = ["specVersion": "1.0"]
        vrmcVrm["meta"] = [
            "name": "MToon Test Model",
            "licenseUrl": "",
            "authors": ["VRMBuilder"],
        ]
        if let humanoid = vrm.humanoid {
            var humanBonesDict: [String: Any] = [:]
            for (bone, humanBone) in humanoid.humanBones {
                humanBonesDict[bone.rawValue] = ["node": humanBone.node]
            }
            vrmcVrm["humanoid"] = ["humanBones": humanBonesDict]
        }
        extensions["VRMC_vrm"] = vrmcVrm
        gltfDict["extensions"] = extensions

        return gltfDict
    }

    private static func createGLB(json: [String: Any], binaryData: Data) throws -> Data {
        let jsonData = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let jsonPadding = (4 - (jsonData.count % 4)) % 4
        var paddedJSON = jsonData
        if jsonPadding > 0 {
            paddedJSON.append(Data(repeating: 0x20, count: jsonPadding))
        }

        let binaryPadding = (4 - (binaryData.count % 4)) % 4
        var paddedBinary = binaryData
        if binaryPadding > 0 {
            paddedBinary.append(Data(repeating: 0x00, count: binaryPadding))
        }

        let headerLength = 12
        let jsonChunkHeaderLength = 8
        let binaryChunkHeaderLength = binaryData.isEmpty ? 0 : 8
        let totalLength = headerLength + jsonChunkHeaderLength + paddedJSON.count
            + binaryChunkHeaderLength + paddedBinary.count

        var glbData = Data()
        glbData.append(UInt32(0x46546C67).littleEndian.data)
        glbData.append(UInt32(2).littleEndian.data)
        glbData.append(UInt32(totalLength).littleEndian.data)

        glbData.append(UInt32(paddedJSON.count).littleEndian.data)
        glbData.append(UInt32(0x4E4F534A).littleEndian.data)
        glbData.append(paddedJSON)

        if !binaryData.isEmpty {
            glbData.append(UInt32(paddedBinary.count).littleEndian.data)
            glbData.append(UInt32(0x004E4942).littleEndian.data)
            glbData.append(paddedBinary)
        }

        return glbData
    }
}
