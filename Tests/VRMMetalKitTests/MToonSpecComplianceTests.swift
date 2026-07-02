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

/// Tests for MToon 1.0 / VRM 1.0 spec compliance fixes.
///
/// Covers deviations: A1, A2, A3, A4, K2, K3, L1, L2, L3, M7, M8
final class MToonSpecComplianceTests: XCTestCase {

    // MARK: - A1: rimLightingMixFactor default 0.0 → 1.0

    func testA1_RimLightingMixFactorDefaultIsOne() {
        let uniforms = MToonMaterialUniforms()
        XCTAssertEqual(uniforms.rimLightingMixFactor, 1.0, accuracy: 0.0001,
            "MToon 1.0 spec: rimLightingMixFactor default must be 1.0, not 0.0")
    }

    func testA1_VRMMToonMaterialDefaultRimLightingMixFactorIsOne() {
        let mtoon = VRMMToonMaterial()
        XCTAssertEqual(mtoon.rimLightingMixFactor, 1.0, accuracy: 0.0001,
            "VRMMToonMaterial: rimLightingMixFactor default must be 1.0 per MToon spec")
    }

    // MARK: - A3: shadeColorFactor uniform default [0,0,0]

    func testA3_ShadeColorUniformDefaultIsBlack() {
        let uniforms = MToonMaterialUniforms()
        XCTAssertEqual(uniforms.shadeColorR, 0.0, accuracy: 0.0001,
            "MToon 1.0 spec: shadeColorFactor default must be [0,0,0]")
        XCTAssertEqual(uniforms.shadeColorG, 0.0, accuracy: 0.0001,
            "MToon 1.0 spec: shadeColorFactor default must be [0,0,0]")
        XCTAssertEqual(uniforms.shadeColorB, 0.0, accuracy: 0.0001,
            "MToon 1.0 spec: shadeColorFactor default must be [0,0,0]")
    }

    // MARK: - A4: outlineColorFactor uniform default [0,0,0]

    func testA4_OutlineColorUniformDefaultIsBlack() {
        let uniforms = MToonMaterialUniforms()
        XCTAssertEqual(uniforms.outlineColorR, 0.0, accuracy: 0.0001,
            "MToon 1.0 spec: outlineColorFactor default must be [0,0,0]")
        XCTAssertEqual(uniforms.outlineColorG, 0.0, accuracy: 0.0001,
            "MToon 1.0 spec: outlineColorFactor default must be [0,0,0]")
        XCTAssertEqual(uniforms.outlineColorB, 0.0, accuracy: 0.0001,
            "MToon 1.0 spec: outlineColorFactor default must be [0,0,0]")
    }

    // MARK: - A2: renderQueueOffsetNumber range validation

    func testA2_OpaqueWithNonZeroOffsetClampsToZero() async throws {
        let glbData = try Self.buildGLBWithRenderQueueOffset(
            alphaMode: "OPAQUE",
            transparentWithZWrite: false,
            renderQueueOffsetNumber: 5
        )
        let model = try await VRMModel.load(from: glbData, device: nil)
        let mat = model.materials.first { $0.name == "TestMat" }
        XCTAssertNotNil(mat, "Material 'TestMat' must be present")
        XCTAssertEqual(mat!.renderQueueOffset, 0,
            "OPAQUE alphaMode: renderQueueOffsetNumber must be clamped to 0")
    }

    func testA2_MaskWithNonZeroOffsetClampsToZero() async throws {
        let glbData = try Self.buildGLBWithRenderQueueOffset(
            alphaMode: "MASK",
            transparentWithZWrite: false,
            renderQueueOffsetNumber: -3
        )
        let model = try await VRMModel.load(from: glbData, device: nil)
        let mat = model.materials.first { $0.name == "TestMat" }
        XCTAssertNotNil(mat)
        XCTAssertEqual(mat!.renderQueueOffset, 0,
            "MASK alphaMode: renderQueueOffsetNumber must be clamped to 0")
    }

    func testA2_BlendZWriteTrueNegativeOffsetClampsToZero() async throws {
        let glbData = try Self.buildGLBWithRenderQueueOffset(
            alphaMode: "BLEND",
            transparentWithZWrite: true,
            renderQueueOffsetNumber: -3
        )
        let model = try await VRMModel.load(from: glbData, device: nil)
        let mat = model.materials.first { $0.name == "TestMat" }
        XCTAssertNotNil(mat)
        XCTAssertEqual(mat!.renderQueueOffset, 0,
            "BLEND+zWrite=true: negative renderQueueOffsetNumber must be clamped to 0")
    }

    func testA2_BlendZWriteTrueLargeOffsetClampsToNine() async throws {
        let glbData = try Self.buildGLBWithRenderQueueOffset(
            alphaMode: "BLEND",
            transparentWithZWrite: true,
            renderQueueOffsetNumber: 15
        )
        let model = try await VRMModel.load(from: glbData, device: nil)
        let mat = model.materials.first { $0.name == "TestMat" }
        XCTAssertNotNil(mat)
        XCTAssertEqual(mat!.renderQueueOffset, 9,
            "BLEND+zWrite=true: renderQueueOffsetNumber must be clamped to [0,9]")
    }

    func testA2_BlendZWriteFalseLargeNegativeOffsetClampsToNegativeNine() async throws {
        let glbData = try Self.buildGLBWithRenderQueueOffset(
            alphaMode: "BLEND",
            transparentWithZWrite: false,
            renderQueueOffsetNumber: -15
        )
        let model = try await VRMModel.load(from: glbData, device: nil)
        let mat = model.materials.first { $0.name == "TestMat" }
        XCTAssertNotNil(mat)
        XCTAssertEqual(mat!.renderQueueOffset, -9,
            "BLEND+zWrite=false: renderQueueOffsetNumber must be clamped to [-9,9]")
    }

    func testA2_BlendZWriteFalseValidOffsetPreserved() async throws {
        let glbData = try Self.buildGLBWithRenderQueueOffset(
            alphaMode: "BLEND",
            transparentWithZWrite: false,
            renderQueueOffsetNumber: -5
        )
        let model = try await VRMModel.load(from: glbData, device: nil)
        let mat = model.materials.first { $0.name == "TestMat" }
        XCTAssertNotNil(mat)
        XCTAssertEqual(mat!.renderQueueOffset, -5,
            "BLEND+zWrite=false: valid offset -5 should be preserved")
    }

    // MARK: - K2: renderQueue base 2510 for BLEND+zWrite=true

    func testK2_BlendZWriteTrueUsesBase2510() async throws {
        let glbData = try Self.buildGLBWithRenderQueueOffset(
            alphaMode: "BLEND",
            transparentWithZWrite: true,
            renderQueueOffsetNumber: 0
        )
        let model = try await VRMModel.load(from: glbData, device: nil)
        let mat = model.materials.first { $0.name == "TestMat" }
        XCTAssertNotNil(mat)
        XCTAssertEqual(mat!.renderQueue, 2510,
            "BLEND+zWrite=true: renderQueue base must be 2510 per VRM 1.0 spec")
    }

    func testK2_BlendZWriteFalseUsesBase3000() async throws {
        let glbData = try Self.buildGLBWithRenderQueueOffset(
            alphaMode: "BLEND",
            transparentWithZWrite: false,
            renderQueueOffsetNumber: 0
        )
        let model = try await VRMModel.load(from: glbData, device: nil)
        let mat = model.materials.first { $0.name == "TestMat" }
        XCTAssertNotNil(mat)
        XCTAssertEqual(mat!.renderQueue, 3000,
            "BLEND+zWrite=false: renderQueue base must be 3000")
    }

    func testK2_BlendZWriteTrueWithOffsetAdded() async throws {
        let glbData = try Self.buildGLBWithRenderQueueOffset(
            alphaMode: "BLEND",
            transparentWithZWrite: true,
            renderQueueOffsetNumber: 3
        )
        let model = try await VRMModel.load(from: glbData, device: nil)
        let mat = model.materials.first { $0.name == "TestMat" }
        XCTAssertNotNil(mat)
        XCTAssertEqual(mat!.renderQueue, 2513,
            "BLEND+zWrite=true with offset=3: renderQueue must be 2510+3=2513")
    }

    // MARK: - K3: pipeline depthWrite selection function

    func testK3_PipelineCategoryBlendZWriteTrue() {
        let category = VRMMaterial.pipelineCategory(alphaMode: "BLEND", transparentWithZWrite: true)
        XCTAssertEqual(category, .blendZWrite,
            "BLEND+zWrite=true must use blendZWrite pipeline category (depth write enabled)")
    }

    func testK3_PipelineCategoryBlendZWriteFalse() {
        let category = VRMMaterial.pipelineCategory(alphaMode: "BLEND", transparentWithZWrite: false)
        XCTAssertEqual(category, .blend,
            "BLEND+zWrite=false must use blend pipeline category (depth write disabled)")
    }

    func testK3_PipelineCategoryOpaque() {
        let category = VRMMaterial.pipelineCategory(alphaMode: "OPAQUE", transparentWithZWrite: false)
        XCTAssertEqual(category, .opaque,
            "OPAQUE must use opaque pipeline category")
    }

    func testK3_PipelineCategoryMask() {
        let category = VRMMaterial.pipelineCategory(alphaMode: "MASK", transparentWithZWrite: false)
        XCTAssertEqual(category, .opaque,
            "MASK must use opaque pipeline category (depth write, no blend)")
    }

    // MARK: - L1: KHR_texture_transform parsing

    func testL1_KHRTextureTransformParsed() async throws {
        let glbData = try Self.buildGLBWithKHRTextureTransform(
            offset: [0.1, 0.2],
            rotation: 0.785,
            scale: [2.0, 3.0]
        )
        let model = try await VRMModel.load(from: glbData, device: nil)
        let mat = model.materials.first { $0.name == "TransformMat" }
        XCTAssertNotNil(mat, "Material 'TransformMat' must be present")
        let transform = mat!.khrTextureTransform
        XCTAssertNotNil(transform, "KHR_texture_transform must be parsed")
        XCTAssertEqual(transform!.offset.x, 0.1, accuracy: 0.001)
        XCTAssertEqual(transform!.offset.y, 0.2, accuracy: 0.001)
        XCTAssertEqual(transform!.rotation, 0.785, accuracy: 0.001)
        XCTAssertEqual(transform!.scale.x, 2.0, accuracy: 0.001)
        XCTAssertEqual(transform!.scale.y, 3.0, accuracy: 0.001)
    }

    func testL1_KHRTextureTransformDefaultsWhenAbsent() {
        let transform = GLTFKHRTextureTransform()
        XCTAssertEqual(transform.offset.x, 0.0, accuracy: 0.0001)
        XCTAssertEqual(transform.offset.y, 0.0, accuracy: 0.0001)
        XCTAssertEqual(transform.rotation, 0.0, accuracy: 0.0001)
        XCTAssertEqual(transform.scale.x, 1.0, accuracy: 0.0001)
        XCTAssertEqual(transform.scale.y, 1.0, accuracy: 0.0001)
    }

    // MARK: - L2: MToonMaterialUniforms texture transform fields

    func testL2_TextureTransformUniformDefaults() {
        let uniforms = MToonMaterialUniforms()
        XCTAssertEqual(uniforms.textureTransformOffsetX, 0.0, accuracy: 0.0001)
        XCTAssertEqual(uniforms.textureTransformOffsetY, 0.0, accuracy: 0.0001)
        XCTAssertEqual(uniforms.textureTransformRotation, 0.0, accuracy: 0.0001)
        XCTAssertEqual(uniforms.textureTransformScaleX, 1.0, accuracy: 0.0001,
            "textureTransformScaleX default must be 1.0 (identity)")
        XCTAssertEqual(uniforms.textureTransformScaleY, 1.0, accuracy: 0.0001,
            "textureTransformScaleY default must be 1.0 (identity)")
    }

    // MARK: - L3: KHR_texture_transform wired into MToonMaterialUniforms

    func testL3_TextureTransformWiredIntoUniforms() async throws {
        let glbData = try Self.buildGLBWithKHRTextureTransform(
            offset: [0.25, 0.5],
            rotation: 0.0,
            scale: [4.0, 2.0]
        )
        let model = try await VRMModel.load(from: glbData, device: nil)
        let mat = model.materials.first { $0.name == "TransformMat" }
        XCTAssertNotNil(mat)
        guard let mtoon = mat!.mtoon else {
            XCTFail("TransformMat must have MToon material")
            return
        }
        let uniforms = MToonMaterialUniforms(from: mtoon)
        XCTAssertEqual(uniforms.textureTransformOffsetX, 0.25, accuracy: 0.001,
            "textureTransformOffsetX must be wired from KHR_texture_transform")
        XCTAssertEqual(uniforms.textureTransformOffsetY, 0.5, accuracy: 0.001)
        XCTAssertEqual(uniforms.textureTransformScaleX, 4.0, accuracy: 0.001)
        XCTAssertEqual(uniforms.textureTransformScaleY, 2.0, accuracy: 0.001)
    }

    // MARK: - M7/M8: linear texture indices

    func testM7M8_OutlineAndUVAnimMaskTextureIndicesCollected() async throws {
        let glbData = try Self.buildGLBWithLinearMaskTextures()
        let model = try await VRMModel.load(from: glbData, device: nil)
        XCTAssertTrue(model.outlineWidthMaskTextureIndices.contains(0),
            "Outline width mask texture index 0 must be in linearTextureIndices (M7)")
        XCTAssertTrue(model.uvAnimationMaskTextureIndices.contains(1),
            "UV animation mask texture index 1 must be in linearTextureIndices (M8)")
    }

    // MARK: - GLB Builder Helpers

    private static func buildGLBWithRenderQueueOffset(
        alphaMode: String,
        transparentWithZWrite: Bool,
        renderQueueOffsetNumber: Int
    ) throws -> Data {
        let vrm = try VRMBuilder().setSkeleton(.defaultHumanoid).build()
        let materials: [[String: Any]] = [
            [
                "name": "TestMat",
                "alphaMode": alphaMode,
                "extensions": [
                    "VRMC_materials_mtoon": [
                        "specVersion": "1.0",
                        "transparentWithZWrite": transparentWithZWrite,
                        "renderQueueOffsetNumber": renderQueueOffsetNumber,
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ]
        return try buildGLB(from: vrm, materials: materials, extraExtensions: [])
    }

    private static func buildGLBWithKHRTextureTransform(
        offset: [Double],
        rotation: Double,
        scale: [Double]
    ) throws -> Data {
        let vrm = try VRMBuilder().setSkeleton(.defaultHumanoid).build()
        let materials: [[String: Any]] = [
            [
                "name": "TransformMat",
                "alphaMode": "OPAQUE",
                "pbrMetallicRoughness": [
                    "baseColorTexture": [
                        "index": 0,
                        "extensions": [
                            "KHR_texture_transform": [
                                "offset": offset,
                                "rotation": rotation,
                                "scale": scale,
                            ] as [String: Any],
                        ] as [String: Any],
                    ] as [String: Any],
                ] as [String: Any],
                "extensions": [
                    "VRMC_materials_mtoon": [
                        "specVersion": "1.0",
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ]
        return try buildGLB(from: vrm, materials: materials, extraExtensions: ["KHR_texture_transform"])
    }

    private static func buildGLBWithLinearMaskTextures() throws -> Data {
        let vrm = try VRMBuilder().setSkeleton(.defaultHumanoid).build()
        let materials: [[String: Any]] = [
            [
                "name": "LinearMaskMat",
                "alphaMode": "OPAQUE",
                "extensions": [
                    "VRMC_materials_mtoon": [
                        "specVersion": "1.0",
                        "outlineWidthMultiplyTexture": ["index": 0] as [String: Any],
                        "uvAnimationMaskTexture": ["index": 1] as [String: Any],
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ]
        return try buildGLB(from: vrm, materials: materials, extraExtensions: [])
    }

    private static func buildGLB(
        from vrm: VRMModel,
        materials: [[String: Any]],
        extraExtensions: [String]
    ) throws -> Data {
        let gltfData = try JSONEncoder().encode(vrm.gltf)
        var gltfDict = try JSONSerialization.jsonObject(with: gltfData) as! [String: Any]

        gltfDict["materials"] = materials

        var extensionsUsed = gltfDict["extensionsUsed"] as? [String] ?? []
        for ext in ["VRMC_materials_mtoon"] + extraExtensions {
            if !extensionsUsed.contains(ext) { extensionsUsed.append(ext) }
        }
        gltfDict["extensionsUsed"] = extensionsUsed

        var extensions = gltfDict["extensions"] as? [String: Any] ?? [:]
        var vrmcVrm: [String: Any] = ["specVersion": "1.0"]
        vrmcVrm["meta"] = ["name": "Test", "licenseUrl": "https://vrm.dev/licenses/1.0/"]
        if let humanoid = vrm.humanoid {
            var humanBonesDict: [String: Any] = [:]
            for (bone, humanBone) in humanoid.humanBones {
                humanBonesDict[bone.rawValue] = ["node": humanBone.node]
            }
            vrmcVrm["humanoid"] = ["humanBones": humanBonesDict]
        }
        extensions["VRMC_vrm"] = vrmcVrm
        gltfDict["extensions"] = extensions

        let binaryData = vrm.gltf.binaryBufferData ?? Data()
        return try createGLB(json: gltfDict, binaryData: binaryData)
    }

    private static func createGLB(json: [String: Any], binaryData: Data) throws -> Data {
        let jsonData = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let jsonPadding = (4 - (jsonData.count % 4)) % 4
        var paddedJSON = jsonData
        if jsonPadding > 0 {
            paddedJSON.append(Data(repeating: 0x20, count: jsonPadding))
        }

        let binaryPadding = binaryData.isEmpty ? 0 : (4 - (binaryData.count % 4)) % 4
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
