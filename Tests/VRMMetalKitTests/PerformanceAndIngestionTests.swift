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

import XCTest
import Metal
import simd
@testable import VRMMetalKit

final class PerformanceAndIngestionTests: XCTestCase {

    // MARK: - Helpers

    private func makeMinimalVRMDocument(
        includeTextures: Bool = false,
        sharedColorAndOcclusion: Bool = false
    ) -> GLTFDocument {
        let jsonString: String
        if includeTextures {
            let occlusionField = sharedColorAndOcclusion ? "\"occlusionTexture\": { \"index\": 0 }," : ""
            jsonString = """
            {
              "asset": { "version": "2.0" },
              "nodes": [
                { "name": "Hips" },
                { "name": "Spine" },
                { "name": "Head" },
                { "name": "LeftUpperLeg" },
                { "name": "LeftLowerLeg" },
                { "name": "LeftFoot" },
                { "name": "RightUpperLeg" },
                { "name": "RightLowerLeg" },
                { "name": "RightFoot" },
                { "name": "LeftUpperArm" },
                { "name": "LeftLowerArm" },
                { "name": "LeftHand" },
                { "name": "RightUpperArm" },
                { "name": "RightLowerArm" },
                { "name": "RightHand" }
              ],
              "samplers": [
                { "magFilter": 9729, "minFilter": 9987 },
                { "magFilter": 9729, "minFilter": 9729 }
              ],
              "textures": [
                { "name": "albedo", "sampler": 0 },
                { "name": "normal", "sampler": 1 }
              ],
              "materials": [
                {
                  "name": "BodyMat",
                  "pbrMetallicRoughness": {
                    "baseColorTexture": { "index": 0 }
                  },
                  \(occlusionField)
                  "normalTexture": { "index": 1 }
                }
              ],
              "extensionsUsed": ["VRMC_vrm"],
              "extensions": {
                "VRMC_vrm": {
                  "specVersion": "1.0",
                  "meta": {
                    "name": "DirectIngestionTest",
                    "authors": ["Test"],
                    "licenseUrl": "https://vrm.dev/licenses/1.0/"
                  },
                  "humanoid": {
                    "humanBones": {
                      "hips": { "node": 0 },
                      "spine": { "node": 1 },
                      "head": { "node": 2 },
                      "leftUpperLeg": { "node": 3 },
                      "leftLowerLeg": { "node": 4 },
                      "leftFoot": { "node": 5 },
                      "rightUpperLeg": { "node": 6 },
                      "rightLowerLeg": { "node": 7 },
                      "rightFoot": { "node": 8 },
                      "leftUpperArm": { "node": 9 },
                      "leftLowerArm": { "node": 10 },
                      "leftHand": { "node": 11 },
                      "rightUpperArm": { "node": 12 },
                      "rightLowerArm": { "node": 13 },
                      "rightHand": { "node": 14 }
                    }
                  }
                }
              }
            }
            """
        } else {
            jsonString = """
            {
              "asset": { "version": "2.0" },
              "nodes": [
                { "name": "Hips" },
                { "name": "Spine" },
                { "name": "Head" },
                { "name": "LeftUpperLeg" },
                { "name": "LeftLowerLeg" },
                { "name": "LeftFoot" },
                { "name": "RightUpperLeg" },
                { "name": "RightLowerLeg" },
                { "name": "RightFoot" },
                { "name": "LeftUpperArm" },
                { "name": "LeftLowerArm" },
                { "name": "LeftHand" },
                { "name": "RightUpperArm" },
                { "name": "RightLowerArm" },
                { "name": "RightHand" }
              ],
              "extensionsUsed": ["VRMC_vrm"],
              "extensions": {
                "VRMC_vrm": {
                  "specVersion": "1.0",
                  "meta": {
                    "name": "ConcurrentLoadTest",
                    "authors": ["Test"],
                    "licenseUrl": "https://vrm.dev/licenses/1.0/"
                  },
                  "humanoid": {
                    "humanBones": {
                      "hips": { "node": 0 },
                      "spine": { "node": 1 },
                      "head": { "node": 2 },
                      "leftUpperLeg": { "node": 3 },
                      "leftLowerLeg": { "node": 4 },
                      "leftFoot": { "node": 5 },
                      "rightUpperLeg": { "node": 6 },
                      "rightLowerLeg": { "node": 7 },
                      "rightFoot": { "node": 8 },
                      "leftUpperArm": { "node": 9 },
                      "leftLowerArm": { "node": 10 },
                      "leftHand": { "node": 11 },
                      "rightUpperArm": { "node": 12 },
                      "rightLowerArm": { "node": 13 },
                      "rightHand": { "node": 14 }
                    }
                  }
                }
              }
            }
            """
        }

        let data = Data(jsonString.utf8)
        return try! JSONDecoder().decode(GLTFDocument.self, from: data)
    }

    private func makeSolidRGBA8(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8) -> Data {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let base = i * 4
            bytes[base] = r
            bytes[base + 1] = g
            bytes[base + 2] = b
            bytes[base + 3] = a
        }
        return Data(bytes)
    }

    private func readPixel(_ texture: MTLTexture, x: Int = 0, y: Int = 0, mipLevel: Int = 0) -> (UInt8, UInt8, UInt8, UInt8) {
        var pixel = [UInt8](repeating: 0, count: 4)
        texture.getBytes(
            &pixel,
            bytesPerRow: max(1, texture.width >> mipLevel) * 4,
            from: MTLRegionMake2D(x, y, 1, 1),
            mipmapLevel: mipLevel
        )
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }

    // MARK: - Finding 1: @concurrent Load Isolation

    @MainActor
    func testVRMModelLoadFromMainActorCompletesSuccessfully() async throws {
        let document = makeMinimalVRMDocument()
        let model = try await VRMModel.load(document: document, device: MTLCreateSystemDefaultDevice())
        XCTAssertEqual(model.meta.name, "ConcurrentLoadTest")
        XCTAssertEqual(model.nodes.count, 15)
        XCTAssertTrue(Thread.isMainThread, "Caller should resume on @MainActor after awaiting @concurrent load")
    }

    // MARK: - Finding 2: VRMExpressionController Contiguous Storage & Overrides

    func testExpressionControllerContiguousOverridesAndNoOpWrites() {
        let controller = VRMExpressionController()

        var happy = VRMExpression(preset: .happy)
        happy.overrideBlink = .block
        happy.overrideMouth = .blend
        happy.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 0, weight: 1.0)]
        happy.materialColorBinds = [
            VRMMaterialColorBind(material: 0, type: .color, targetValue: SIMD4<Float>(1, 0, 0, 1))
        ]

        var blink = VRMExpression(preset: .blink)
        blink.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 1, weight: 1.0)]

        var aa = VRMExpression(preset: .aa)
        aa.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 2, weight: 1.0)]

        var customWink = VRMExpression(name: "wink")
        customWink.isBinary = true
        customWink.overrideLookAt = .block
        customWink.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 3, weight: 0.8)]

        var lookUp = VRMExpression(preset: .lookUp)
        lookUp.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 4, weight: 1.0)]

        controller.registerExpression(happy, for: .happy)
        controller.registerExpression(blink, for: .blink)
        controller.registerExpression(aa, for: .aa)
        controller.registerExpression(lookUp, for: .lookUp)
        controller.registerCustomExpression(customWink, name: "wink")
        controller.setBaseMaterialColor(materialIndex: 0, type: .color, color: SIMD4<Float>(1, 1, 1, 1))

        controller.setExpressionWeight(.happy, weight: 0.5)
        controller.setExpressionWeight(.blink, weight: 1.0)
        controller.setExpressionWeight(.aa, weight: 0.8)
        controller.setExpressionWeight(.lookUp, weight: 0.9)
        controller.setCustomExpressionWeight("wink", weight: 0.7)

        let weights = controller.weightsForMesh(0, morphCount: 5)
        XCTAssertEqual(weights[0], 0.5, accuracy: 1e-5, "happy weight")
        XCTAssertEqual(weights[1], 0.0, accuracy: 1e-5, "blink blocked by happy")
        XCTAssertEqual(weights[2], 0.4, accuracy: 1e-5, "aa blended by (1 - 0.5)")
        XCTAssertEqual(weights[3], 0.8, accuracy: 1e-5, "binary custom wink quantized to 1.0 * 0.8")
        XCTAssertEqual(weights[4], 0.0, accuracy: 1e-5, "lookUp blocked by custom wink")

        let colorOverride = controller.getMaterialColorOverride(materialIndex: 0, type: .color)
        XCTAssertNotNil(colorOverride)
        XCTAssertEqual(colorOverride?.x ?? 0, 1.0, accuracy: 1e-5)
        XCTAssertEqual(colorOverride?.y ?? 0, 0.5, accuracy: 1e-5)

        let fp1 = controller.morphWeightsFingerprint()
        // Setting identical weights must not alter the fingerprint.
        controller.setExpressionWeight(.happy, weight: 0.5)
        controller.setCustomExpressionWeight("wink", weight: 0.7)
        let fp2 = controller.morphWeightsFingerprint()
        XCTAssertEqual(fp1, fp2)

        // Re-registering a preset updates its binds and overrides cleanly.
        var happyV2 = VRMExpression(preset: .happy)
        happyV2.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 0, weight: 0.5)]
        controller.registerExpression(happyV2, for: .happy)
        let weightsV2 = controller.weightsForMesh(0, morphCount: 5)
        XCTAssertEqual(weightsV2[0], 0.25, accuracy: 1e-5)
        XCTAssertEqual(weightsV2[1], 1.0, accuracy: 1e-5, "blink no longer blocked after happy re-registration")
    }

    // MARK: - Finding 2: VRMNode Fast-Path Visibility & Parent-World Propagation

    func testNodeEffectivelyHiddenFastPathAndDeinitCleanup() {
        let root = VRMNode(index: 0, name: "Root")
        let child = VRMNode(index: 1, name: "Child")
        let grandChild = VRMNode(index: 2, name: "GrandChild")
        child.parent = root
        root.children = [child]
        grandChild.parent = child
        child.children = [grandChild]

        XCTAssertFalse(grandChild.isEffectivelyHidden)

        root.isHidden = true
        XCTAssertTrue(root.isEffectivelyHidden)
        XCTAssertTrue(child.isEffectivelyHidden)
        XCTAssertTrue(grandChild.isEffectivelyHidden)

        root.isHidden = false
        XCTAssertFalse(grandChild.isEffectivelyHidden)

        // Verify deinit of a hidden node does not leak the hidden counter.
        do {
            let ephemeral = VRMNode(index: 99, name: "TempHidden")
            ephemeral.isHidden = true
            XCTAssertTrue(ephemeral.isEffectivelyHidden)
        }
        XCTAssertFalse(grandChild.isEffectivelyHidden)
    }

    func testNodeUpdateWorldTransformPassesParentWorldDownHierarchy() {
        let root = VRMNode(index: 0, name: "Root", translation: SIMD3<Float>(1, 0, 0))
        let child = VRMNode(index: 1, name: "Child", translation: SIMD3<Float>(0, 2, 0))
        let grandChild = VRMNode(index: 2, name: "GrandChild", translation: SIMD3<Float>(0, 0, 3))
        child.parent = root
        root.children = [child]
        grandChild.parent = child
        child.children = [grandChild]

        root.updateWorldTransform()

        XCTAssertEqual(grandChild.worldPosition.x, 1.0, accuracy: 1e-5)
        XCTAssertEqual(grandChild.worldPosition.y, 2.0, accuracy: 1e-5)
        XCTAssertEqual(grandChild.worldPosition.z, 3.0, accuracy: 1e-5)

        let genBefore = grandChild.worldGeneration
        root.translation = SIMD3<Float>(4, 0, 0)
        root.updateWorldTransform()

        XCTAssertEqual(grandChild.worldPosition.x, 4.0, accuracy: 1e-5)
        XCTAssertGreaterThan(grandChild.worldGeneration, genBefore)
    }

    // MARK: - Finding 3: Direct In-Memory Texture & Document Ingestion

    func testVRMTextureMakeRGBA8AndValidation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }

        // Preserve non-zero RGB under alpha=0 (straight alpha, never premultiplied).
        let straightPixels = makeSolidRGBA8(width: 4, height: 4, r: 200, g: 120, b: 40, a: 0)
        let srgbTex = try VRMTexture.makeRGBA8(
            data: straightPixels,
            width: 4,
            height: 4,
            sRGB: true,
            mipmapped: true,
            alphaIsCoverage: false,
            name: "StraightAlbedo",
            device: device
        )
        let mtlTex = try XCTUnwrap(srgbTex.mtlTexture)
        XCTAssertEqual(mtlTex.pixelFormat, .rgba8Unorm_srgb)
        XCTAssertEqual(mtlTex.width, 4)
        XCTAssertEqual(mtlTex.height, 4)
        XCTAssertEqual(mtlTex.mipmapLevelCount, 3)
        let px = readPixel(mtlTex)
        XCTAssertEqual(px.0, 200)
        XCTAssertEqual(px.1, 120)
        XCTAssertEqual(px.2, 40)
        XCTAssertEqual(px.3, 0)

        // UnsafeRawBufferPointer zero-copy path with padded row stride & linear format.
        var padded = [UInt8](repeating: 0, count: 2 * 16)
        padded[0] = 10; padded[1] = 20; padded[2] = 30; padded[3] = 255
        padded[16] = 40; padded[17] = 50; padded[18] = 60; padded[19] = 255
        let linearTex = try padded.withUnsafeBytes { raw in
            try VRMTexture.makeRGBA8(
                bytes: raw,
                width: 2,
                height: 2,
                bytesPerRow: 16,
                sRGB: false,
                mipmapped: false,
                name: "LinearNormal",
                device: device
            )
        }
        let linearMTL = try XCTUnwrap(linearTex.mtlTexture)
        XCTAssertEqual(linearMTL.pixelFormat, .rgba8Unorm)
        XCTAssertEqual(linearMTL.mipmapLevelCount, 1)
        let row1Px = readPixel(linearMTL, x: 0, y: 1)
        XCTAssertEqual(row1Px.0, 40)
        XCTAssertEqual(row1Px.1, 50)
        XCTAssertEqual(row1Px.2, 60)

        // Invalid dimensions / truncated buffer must throw GLTFError.invalidImageData.
        XCTAssertThrowsError(
            try VRMTexture.makeRGBA8(data: Data([1, 2, 3]), width: 2, height: 2, device: device)
        ) { error in
            guard case GLTFError.invalidImageData = error else {
                return XCTFail("Expected GLTFError.invalidImageData, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try VRMTexture.makeRGBA8(data: Data(), width: 0, height: 4, device: device)
        )
    }

    func testDirectInMemoryDocumentLoadWithPreloadedTexturesBypassesImageIO() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }

        let document = makeMinimalVRMDocument(includeTextures: true, sharedColorAndOcclusion: true)
        let albedoBytes = makeSolidRGBA8(width: 4, height: 4, r: 220, g: 180, b: 140, a: 255)

        // Pre-allocate a custom Metal texture for slot 1 (normal map).
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 2,
            height: 2,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        let prebuiltNormal = try XCTUnwrap(device.makeTexture(descriptor: desc))

        let options = VRMLoadingOptions(
            preloadedTextures: [
                0: .rgba8(data: albedoBytes, width: 4, height: 4),
                1: .mtlTexture(prebuiltNormal),
            ]
        )

        let model = try await VRMModel.load(
            document: document,
            device: device,
            options: options
        )

        XCTAssertEqual(model.textures.count, 2)
        let loadedAlbedo = try XCTUnwrap(model.textures[0].mtlTexture)
        XCTAssertEqual(loadedAlbedo.pixelFormat, .rgba8Unorm_srgb)
        XCTAssertEqual(loadedAlbedo.mipmapLevelCount, 3, "Sampler 0 requested mipmaps")
        let albedoPx = readPixel(loadedAlbedo)
        XCTAssertEqual(albedoPx.0, 220)
        XCTAssertEqual(albedoPx.1, 180)
        XCTAssertEqual(albedoPx.2, 140)

        let loadedNormal = try XCTUnwrap(model.textures[1].mtlTexture)
        XCTAssertTrue(loadedNormal === prebuiltNormal, "Prebuilt MTLTexture should be adopted directly")

        // Shared color + occlusion slot must produce a separate linear occlusion texture without ImageIO.
        let bodyMat = try XCTUnwrap(model.materials.first)
        XCTAssertEqual(bodyMat.baseColorTexture?.mtlTexture?.pixelFormat, .rgba8Unorm_srgb)
        XCTAssertEqual(bodyMat.occlusionTexture?.mtlTexture?.pixelFormat, .rgba8Unorm)
        XCTAssertFalse(bodyMat.baseColorTexture === bodyMat.occlusionTexture)
    }

    func testVRMModelEditorReplaceTextureUpdatesInPlaceAndBumpsRevision() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }

        let document = makeMinimalVRMDocument(includeTextures: true)
        let initialBytes = makeSolidRGBA8(width: 2, height: 2, r: 10, g: 20, b: 30, a: 255)
        let initialNormal = makeSolidRGBA8(width: 2, height: 2, r: 128, g: 128, b: 255, a: 255)
        let model = try await VRMModel.load(
            document: document,
            device: device,
            options: VRMLoadingOptions(preloadedTextures: [
                0: .rgba8(data: initialBytes, width: 2, height: 2),
                1: .rgba8(data: initialNormal, width: 2, height: 2),
            ])
        )

        let revBefore = model.materialRevision
        let updatedBytes = makeSolidRGBA8(width: 2, height: 2, r: 240, g: 100, b: 50, a: 255)
        try model.edit { editor in
            try editor.replaceTexture(at: 0, rgba8Data: updatedBytes, width: 2, height: 2, sRGB: true, mipmapped: false)
        }

        XCTAssertEqual(model.materialRevision, revBefore + 1)
        let matTex = try XCTUnwrap(model.materials[0].baseColorTexture?.mtlTexture)
        let px = readPixel(matTex)
        XCTAssertEqual(px.0, 240)
        XCTAssertEqual(px.1, 100)
        XCTAssertEqual(px.2, 50)

        // Direct MTLTexture replacement also updates material reference and bumps revision.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 2,
            height: 2,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        let customMTL = try XCTUnwrap(device.makeTexture(descriptor: desc))
        model.edit { editor in
            editor.replaceTexture(at: 1, mtlTexture: customMTL)
        }
        XCTAssertEqual(model.materialRevision, revBefore + 2)
        XCTAssertTrue(model.materials[0].normalTexture?.mtlTexture === customMTL)

        // Out-of-bounds index throws GLTFError.missingTexture.
        XCTAssertThrowsError(try model.edit { editor in
            try editor.replaceTexture(at: 99, rgba8Data: updatedBytes, width: 2, height: 2)
        }) { error in
            guard case GLTFError.missingTexture = error else {
                return XCTFail("Expected GLTFError.missingTexture, got \(error)")
            }
        }
    }
}
