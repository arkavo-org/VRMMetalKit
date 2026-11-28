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
import GLTFCore
@testable import VRMMetalKit

final class VRMAuthorKitAPITests: XCTestCase {

    // MARK: - #7: Direct GLTFDocument Construction & Encoding

    func testGLTFDocumentBuilderPreservesTargetsMaterialsExtensionsAndTransform() throws {
        let transform = GLTFKHRTextureTransform(
            offset: [0.25, 0.5],
            rotation: 0.1,
            scale: [2.0, 2.0]
        )

        let builder = GLTFDocumentBuilder()
            .setAsset(GLTFAsset(version: "2.0", generator: "VRMAuthorKitTests"))
            .setTextures([GLTFTexture(sampler: nil, source: nil, name: "albedo")])
            .setMaterials([GLTFMaterial(
                name: "Hair",
                pbrMetallicRoughness: GLTFPBRMetallicRoughness(
                    baseColorFactor: [0.8, 0.4, 0.2, 1.0],
                    baseColorTexture: GLTFTextureInfo(index: 0, texCoord: 0, khrTextureTransform: transform),
                    metallicFactor: 0.0,
                    roughnessFactor: 0.9
                ),
                alphaMode: "MASK",
                alphaCutoff: 0.4,
                doubleSided: true,
                extensions: [
                    "VRMC_materials_mtoon": [
                        "specVersion": "1.0",
                        "shadeColorFactor": [0.5, 0.2, 0.1],
                        "shadingToonyFactor": 0.85,
                    ]
                ]
            )])

        let target = GLTFMorphTarget(position: 1, normal: 2, tangent: nil)
        let prim = GLTFPrimitive(
            attributes: ["POSITION": 0],
            indices: nil,
            material: 0,
            mode: 4,
            targets: [target]
        )
        let payload = Data([1, 2, 3, 4])
        builder
            .setMeshes([GLTFMesh(
                name: "Head",
                primitives: [prim],
                weights: [0.0],
                extras: GLTFMeshExtras(targetNames: ["smile"])
            )])
            .setNodes([GLTFNode(name: "HeadNode", mesh: 0)])
            .addExtension(name: "VRMC_vrm", data: ["specVersion": "1.0"])
            .setExtras(["author": "VRMAuthorKit"])
            .setBinaryBufferData(payload)

        let doc = try builder.build()
        XCTAssertEqual(doc.meshes?.count, 1)
        XCTAssertEqual(doc.meshes?[0].primitives[0].targets?.count, 1)
        XCTAssertEqual(doc.meshes?[0].primitives[0].targets?[0].position, 1)
        XCTAssertEqual(doc.meshes?[0].extras?.targetNames, ["smile"])
        XCTAssertEqual(doc.materials?.count, 1)
        XCTAssertEqual(doc.materials?[0].pbrMetallicRoughness?.baseColorTexture?.khrTextureTransform, transform)
        XCTAssertEqual(doc.binaryBufferData, payload)
        XCTAssertNotNil(doc.extensions?["VRMC_vrm"])
        XCTAssertEqual(doc.extras?["author"] as? String, "VRMAuthorKit")

        // Round-trip through JSONEncoder -> JSONDecoder to verify extensions & KHR_texture_transform survive
        let encoded = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(GLTFDocument.self, from: encoded)
        XCTAssertEqual(decoded.meshes?[0].primitives[0].targets?[0].position, 1)
        XCTAssertEqual(decoded.meshes?[0].extras?.targetNames, ["smile"])
        XCTAssertEqual(decoded.materials?[0].pbrMetallicRoughness?.baseColorTexture?.khrTextureTransform, transform)
        let mtoonExt = decoded.materials?[0].extensions?["VRMC_materials_mtoon"] as? [String: Any]
        XCTAssertEqual(mtoonExt?["specVersion"] as? String, "1.0")
        XCTAssertNotNil(decoded.extensions?["VRMC_vrm"])
        XCTAssertEqual(decoded.extras?["author"] as? String, "VRMAuthorKit")
    }

    // MARK: - #8: Optional VRMModel.gltf, retainGLTFDocument & VRMModel.make

    func testRetainGLTFDocumentDefaultFalseAndOptInTrue() async throws {
        let built = try VRMBuilder().setSkeleton(.defaultHumanoid).build()
        let glbData = try built.serialize()

        let dropped = try await VRMModel.load(from: glbData, device: nil)
        XCTAssertNil(dropped.gltf, "Default load should release GLTFDocument AST to save memory")

        // VRMA rest-transform extraction must still succeed without model.gltf
        let restTransforms = buildModelRestTransforms(model: dropped)
        XCTAssertNotNil(restTransforms[.hips])
        XCTAssertNotNil(restTransforms[.head])

        let retained = try await VRMModel.load(
            from: glbData,
            device: nil,
            options: VRMLoadingOptions(retainGLTFDocument: true)
        )
        XCTAssertNotNil(retained.gltf)
        XCTAssertEqual(retained.gltf?.nodes?.count, retained.nodes.count)
    }

    func testVRMModelMakeZeroGLTFConstruction() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }

        let material = VRMMaterial(name: "DirectMToon")
        material.baseColorFactor = SIMD4<Float>(0.9, 0.7, 0.6, 1.0)
        material.mtoon = VRMMToonMaterial()

        let primitive = VRMPrimitive()
        primitive.materialIndex = 0
        primitive.hasNormals = true
        primitive.uploadVertices([
            VRMVertex(position: [0, 0, 0], normal: [0, 0, 1]),
            VRMVertex(position: [1, 0, 0], normal: [0, 0, 1]),
            VRMVertex(position: [0, 2, 0], normal: [0, 0, 1]),
        ], device: device)
        primitive.uploadIndices([UInt16(0), 1, 2], device: device)
        primitive.localMin = [0, 0, 0]
        primitive.localMax = [1, 2, 0]

        let mesh = VRMMesh(name: "Triangle")
        mesh.primitives = [primitive]

        let root = VRMNode(index: 0, name: "Hips_Root", translation: [0, 1, 0])
        let head = VRMNode(index: 1, name: "Head", translation: [0, 0.5, 0], mesh: 0)
        head.parent = root
        root.children = [head]

        let humanoid = VRMHumanoid()
        humanoid.humanBones[.hips] = VRMHumanoid.VRMHumanBone(node: 0)
        humanoid.humanBones[.head] = VRMHumanoid.VRMHumanBone(node: 1)

        var meta = VRMMeta(licenseUrl: "https://vrm.dev/licenses/1.0/")
        meta.name = "DirectAvatar"

        let model = try VRMModel.make(
            meta: meta,
            humanoid: humanoid,
            nodes: [root, head],
            meshes: [mesh],
            materials: [material],
            device: device
        )

        XCTAssertNil(model.gltf)
        XCTAssertEqual(model.nodes.count, 2)
        XCTAssertEqual(model.findNodeByNormalizedName("hipsroot")?.index, 0)
        XCTAssertEqual(head.worldPosition, SIMD3<Float>(0, 1.5, 0))
        XCTAssertEqual(model.modelLocalBounds.min, SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(model.modelLocalBounds.max, SIMD3<Float>(1, 2, 0))

        // Rest transforms work on directly-built models with gltf == nil
        let rest = buildModelRestTransforms(model: model)
        XCTAssertNotNil(rest[.hips])
        XCTAssertNotNil(rest[.head])
    }

    // MARK: - #9: Live Editing via VRMModelEditor

    func testVRMModelEditorLiveGeometryBindPoseIBMAndSpringBoneEdits() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }

        let primitive = VRMPrimitive()
        primitive.materialIndex = 0
        primitive.hasNormals = true
        primitive.uploadVertices([
            VRMVertex(position: [0, 0, 0], normal: [0, 1, 0]),
            VRMVertex(position: [1, 0, 0], normal: [0, 1, 0]),
            VRMVertex(position: [0, 1, 0], normal: [0, 1, 0]),
        ], device: device)
        primitive.localMin = [0, 0, 0]
        primitive.localMax = [1, 1, 0]
        var morph = VRMMorphTarget(name: "lift")
        morph.positionDeltas = [[0, 0.1, 0], [0, 0.1, 0], [0, 0.1, 0]]
        primitive.morphTargets = [morph]
        primitive.createMorphTargetBuffers(device: device)

        let mesh = VRMMesh(name: "Body")
        mesh.primitives = [primitive]

        let root = VRMNode(index: 0, name: "Hips", translation: [0, 0.9, 0])
        let child = VRMNode(index: 1, name: "Hair_0", translation: [0, 0.2, 0])
        child.parent = root
        root.children = [child]

        let skin = VRMSkin(name: "MainSkin")
        skin.joints = [root, child]
        skin.inverseBindMatrices = [matrix_identity_float4x4, matrix_identity_float4x4]

        let model = try VRMModel.make(
            meta: VRMMeta(licenseUrl: "https://vrm.dev/licenses/1.0/"),
            nodes: [root, child],
            meshes: [mesh],
            materials: [VRMMaterial(name: "Default")],
            skins: [skin],
            device: device
        )

        let initialTopologyRev = model.topologyRevision
        let initialVB = primitive.vertexBuffer

        // 1. In-place position update does NOT reallocate vertexBuffer or bump topologyRevision
        try model.edit { editor in
            try editor.updatePositions(
                [[0, 0, 0], [2, 0, 0], [0, 3, 0]],
                meshIndex: 0,
                primitiveIndex: 0
            )
        }
        XCTAssertTrue(primitive.vertexBuffer === initialVB, "In-place position update should reuse existing MTLBuffer")
        XCTAssertEqual(model.topologyRevision, initialTopologyRev)
        XCTAssertEqual(model.modelLocalBounds.max, SIMD3<Float>(2, 3, 0))
        let basePtr = try XCTUnwrap(primitive.basePositionsBuffer).contents().bindMemory(to: SIMD3<Float>.self, capacity: 3)
        XCTAssertEqual(basePtr[2], SIMD3<Float>(0, 3, 0))

        // 2. Same-count updateVertices reuses buffer; different-count reallocates and bumps topologyRevision
        try model.edit { editor in
            try editor.updateVertices([
                VRMVertex(position: [0, 0, 0], normal: [0, 0, 1]),
                VRMVertex(position: [4, 0, 0], normal: [0, 0, 1]),
                VRMVertex(position: [0, 5, 0], normal: [0, 0, 1]),
                VRMVertex(position: [1, 1, 1], normal: [0, 0, 1]),
            ], meshIndex: 0, primitiveIndex: 0)
        }
        XCTAssertEqual(primitive.vertexCount, 4)
        XCTAssertEqual(model.topologyRevision, initialTopologyRev + 1)
        XCTAssertEqual(model.modelLocalBounds.max, SIMD3<Float>(4, 5, 1))

        // 3. Bind pose + IBM update bumps skinContentRevision without bumping skinLayoutRevision
        let skinLayoutBefore = model.skinLayoutRevision
        let skinContentBefore = model.skinContentRevision
        let newIBM = float4x4(translation: [0, -1.2, 0])
        model.edit { editor in
            editor.updateNodeBindPose(at: 0, translation: [0, 1.2, 0])
            editor.updateSkinInverseBindMatrices([newIBM, matrix_identity_float4x4], skinIndex: 0)
        }
        XCTAssertEqual(model.skinLayoutRevision, skinLayoutBefore)
        XCTAssertEqual(model.skinContentRevision, skinContentBefore + 1)
        XCTAssertEqual(root.initialTranslation, SIMD3<Float>(0, 1.2, 0))
        XCTAssertEqual(child.worldPosition.x, 0, accuracy: 1e-5)
        XCTAssertEqual(child.worldPosition.y, 1.4, accuracy: 1e-5)
        XCTAssertEqual(child.worldPosition.z, 0, accuracy: 1e-5)
        XCTAssertEqual(model.skins[0].inverseBindMatrices[0], newIBM)

        // 4. Replace SpringBone live & add structural elements
        let physBefore = model.physicsRevision
        var sb = VRMSpringBone()
        var spring = VRMSpring(name: "Hair")
        spring.joints = [VRMSpringJoint(node: 0), VRMSpringJoint(node: 1)]
        sb.springs = [spring]
        try model.edit { editor in
            try editor.replaceSpringBone(sb, augmentColliders: false)
            let newMatIdx = editor.addMaterial(VRMMaterial(name: "AddedMat"))
            XCTAssertEqual(newMatIdx, 1)
            let newNodeIdx = editor.addNode(VRMNode(index: 2, name: "Added_Node", translation: [1, 0, 0]), parentIndex: 0)
            XCTAssertEqual(newNodeIdx, 2)
        }
        XCTAssertGreaterThan(model.physicsRevision, physBefore)
        XCTAssertNotNil(model.springBoneBuffers)
        XCTAssertEqual(model.materials.count, 2)
        XCTAssertEqual(model.nodes.count, 3)
        XCTAssertEqual(model.findNodeByNormalizedName("addednode")?.index, 2)
    }

    // MARK: - #10: Non-Blocking VRMTextureLayerStack & Raw RGBA8 Layer Upload

    func testTextureLayerStackRawRGBA8EncodeApplyAndApplyAsync() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = MetalQueueFactory.makeCommandQueue(device: device) else {
            throw XCTSkip("Metal device unavailable")
        }

        let stack = try VRMTextureLayerStack(device: device)
        let width = 8
        let height = 8
        // Solid bright green straight-alpha RGBA8 layer
        var rgba = Data(count: width * height * 4)
        rgba.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<(width * height) {
                bytes[i * 4 + 0] = 0
                bytes[i * 4 + 1] = 255
                bytes[i * 4 + 2] = 0
                bytes[i * 4 + 3] = 255
            }
        }

        let layerTex = try VRMTextureLayerStack.makeTexture(
            rgba8Data: rgba,
            width: width,
            height: height,
            device: device,
            sRGB: true,
            label: "GreenRGBA8"
        )
        XCTAssertEqual(layerTex.width, width)
        XCTAssertEqual(layerTex.height, height)

        stack.layers = [VRMTextureLayer(name: "Green", texture: layerTex)]
        let material = VRMMaterial(name: "Face")

        // Non-blocking encodeApply onto caller-owned commandBuffer
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let encoded = try stack.encodeApply(
            to: material,
            slot: .baseColor,
            width: width,
            height: height,
            commandBuffer: cb
        )
        XCTAssertTrue(material.baseColorTexture?.mtlTexture === encoded.color)
        cb.commit()
        await cb.completed()
        XCTAssertNil(cb.error)

        var pixel = [UInt8](repeating: 0, count: 4)
        encoded.color.getBytes(&pixel, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        XCTAssertEqual(pixel[0], 0)
        XCTAssertGreaterThanOrEqual(pixel[1], 250)
        XCTAssertEqual(pixel[2], 0)
        XCTAssertEqual(pixel[3], 255)

        // Non-blocking async applyAsync
        let asyncResult = try await stack.applyAsync(
            to: material,
            slot: .baseColor,
            width: width,
            height: height,
            commandQueue: queue
        )
        XCTAssertTrue(material.baseColorTexture?.mtlTexture === asyncResult.color)
        asyncResult.color.getBytes(&pixel, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        XCTAssertGreaterThanOrEqual(pixel[1], 250)
    }
}
