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

@MainActor
final class VRM2FoundationTests: XCTestCase {
    private var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    // MARK: - Helpers

    private func makeSolidTexture(
        r: UInt8,
        g: UInt8,
        b: UInt8,
        a: UInt8 = 255,
        pixelFormat: MTLPixelFormat = .rgba8Unorm_srgb,
        name: String = "solid"
    ) throws -> VRMTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: 2,
            height: 2,
            mipmapped: false
        )
        desc.usage = .shaderRead
        let mtl = try XCTUnwrap(device.makeTexture(descriptor: desc))
        var pixels: [UInt8] = [
            r, g, b, a, r, g, b, a,
            r, g, b, a, r, g, b, a,
        ]
        mtl.replace(
            region: MTLRegionMake2D(0, 0, 2, 2),
            mipmapLevel: 0,
            withBytes: &pixels,
            bytesPerRow: 2 * 4
        )
        return VRMTexture(name: name, mtlTexture: mtl)
    }

    private func makeQuadPrimitive(
        z: Float = 0,
        halfSize: Float = 0.6,
        materialIndex: Int = 0
    ) throws -> VRMPrimitive {
        let verts: [VRMVertex] = [
            VRMVertex(position: [-halfSize, -halfSize, z], normal: [0, 0, 1], texCoord: [0, 1], color: [1, 1, 1, 1]),
            VRMVertex(position: [ halfSize, -halfSize, z], normal: [0, 0, 1], texCoord: [1, 1], color: [1, 1, 1, 1]),
            VRMVertex(position: [ halfSize,  halfSize, z], normal: [0, 0, 1], texCoord: [1, 0], color: [1, 1, 1, 1]),
            VRMVertex(position: [-halfSize,  halfSize, z], normal: [0, 0, 1], texCoord: [0, 0], color: [1, 1, 1, 1]),
        ]
        let indices: [UInt16] = [0, 1, 2, 0, 2, 3]
        let prim = VRMPrimitive()
        prim.materialIndex = materialIndex
        prim.hasNormals = true
        prim.hasTexCoords = true
        prim.hasColors = true
        prim.localMin = [-halfSize, -halfSize, z]
        prim.localMax = [ halfSize,  halfSize, z]
        prim.uploadVertices(verts, device: device)
        prim.indexCount = indices.count
        prim.indexType = .uint16
        prim.indexBuffer = indices.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        return prim
    }

    private func makeMesh(name: String, primitives: [VRMPrimitive]) -> VRMMesh {
        let mesh = VRMMesh(name: name)
        mesh.primitives = primitives
        return mesh
    }

    private func makeMinimalModel(
        materials: [VRMMaterial],
        meshes: [VRMMesh],
        nodes: [VRMNode]
    ) throws -> VRMModel {
        let gltf = try JSONDecoder().decode(
            GLTFDocument.self,
            from: Data(#"{"asset":{"version":"2.0"}}"#.utf8)
        )
        let model = VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: ""), humanoid: nil, gltf: gltf)
        model.device = device
        model.materials = materials
        model.meshes = meshes
        model.nodes = nodes
        for node in nodes where node.parent == nil {
            node.updateWorldTransform()
        }
        model.finalizeModelLocalBounds()
        return model
    }

    private func renderRGBA(
        renderer: VRMRenderer,
        size: Int = 64,
        eye: SIMD3<Float> = [0, 0, 3],
        center: SIMD3<Float> = [0, 0, 0]
    ) throws -> (rgba: [UInt8], depth: [Float]) {
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: size,
            height: size,
            mipmapped: false
        )
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .shared
        let colorTex = try XCTUnwrap(device.makeTexture(descriptor: colorDesc))

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: size,
            height: size,
            mipmapped: false
        )
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private
        let depthTex = try XCTUnwrap(device.makeTexture(descriptor: depthDesc))

        let depthBytesPerRow = size * MemoryLayout<Float>.stride
        let depthByteCount = size * depthBytesPerRow
        let depthReadback = try XCTUnwrap(
            device.makeBuffer(length: depthByteCount, options: .storageModeShared)
        )

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = colorTex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.depthAttachment.texture = depthTex
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.storeAction = .store
        rpd.depthAttachment.clearDepth = 1.0

        renderer.viewMatrix = RenderTestSupport.makeLookAt(eye: eye, center: center, up: [0, 1, 0])
        renderer.projectionMatrix = renderer.makeProjectionMatrix(aspectRatio: 1.0)

        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        renderer.drawOffscreen(to: colorTex, depth: depthTex, commandBuffer: cb, renderPassDescriptor: rpd)
        if let blit = cb.makeBlitCommandEncoder() {
            blit.copy(
                from: depthTex,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: size, height: size, depth: 1),
                to: depthReadback,
                destinationOffset: 0,
                destinationBytesPerRow: depthBytesPerRow,
                destinationBytesPerImage: depthByteCount
            )
            blit.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertNil(cb.error)

        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        colorTex.getBytes(&rgba, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        let depthPtr = depthReadback.contents().bindMemory(to: Float.self, capacity: size * size)
        let depth = Array(UnsafeBufferPointer(start: depthPtr, count: size * size))
        return (rgba, depth)
    }

    private func centerPixel(_ rgba: [UInt8], size: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let i = ((size / 2) * size + (size / 2)) * 4
        return (rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3])
    }

    private func makeMaterial(
        name: String,
        alphaMode: String = "OPAQUE",
        transparentWithZWrite: Bool = false,
        renderQueueOffset: Int = 0,
        doubleSided: Bool = false,
        withMToon: Bool = true
    ) throws -> VRMMaterial {
        let gltfMat = try JSONDecoder().decode(
            GLTFMaterial.self,
            from: JSONSerialization.data(withJSONObject: [
                "name": name,
                "alphaMode": alphaMode,
                "doubleSided": doubleSided,
            ])
        )
        let mat = VRMMaterial(from: gltfMat, textures: [])
        mat.transparentWithZWrite = transparentWithZWrite
        mat.renderQueueOffset = renderQueueOffset
        mat.recomputeRenderQueue()
        if withMToon {
            mat.mtoon = VRMMToonMaterial()
        } else {
            mat.mtoon = nil
        }
        return mat
    }

    // MARK: - 1. Direct VRMTexture? on VRMMToonMaterial & metallicRoughnessTexture

    func testDirectMToonTextureBindsWithoutModelTexturesArray() throws {
        let mat = try makeMaterial(name: "DirectMToon", withMToon: true)
        mat.baseColorFactor = [0, 0, 0, 1]
        mat.mtoon?.shadeColorFactor = [1, 1, 1]
        mat.mtoon?.shadingShiftFactor = -1.0 // force shadow side to sample shadeMultiplyTexture
        mat.mtoon?.shadingToonyFactor = 1.0
        // Intentionally NOT appended to model.textures!
        let greenShade = try makeSolidTexture(r: 0, g: 255, b: 0, name: "orphan_shade")
        mat.mtoon?.shadeMultiplyTexture = greenShade

        let prim = try makeQuadPrimitive(z: 0, materialIndex: 0)
        let mesh = makeMesh(name: "quad", primitives: [prim])
        let node = VRMNode(index: 0, name: "quadNode", mesh: 0)
        let model = try makeMinimalModel(materials: [mat], meshes: [mesh], nodes: [node])
        XCTAssertTrue(model.textures.isEmpty)

        var cfg = RendererConfig()
        cfg.colorPixelFormat = .rgba8Unorm
        let renderer = VRMRenderer(device: device, config: cfg)
        renderer.loadModelWithoutWarmup(model)
        renderer.setLightNormalizationMode(.radiometric)
        renderer.setLight(0, direction: [0, 0, 1], color: [1, 1, 1], intensity: 1.0) // light behind quad -> shade side
        renderer.disableLight(1)
        renderer.disableLight(2)
        renderer.setAmbientColor([1, 1, 1])

        let (rgba, _) = try renderRGBA(renderer: renderer)
        let px = centerPixel(rgba, size: 64)
        XCTAssertGreaterThan(px.g, 150, "Direct shadeMultiplyTexture must render green without living in model.textures")
        XCTAssertLessThan(px.r, 20)
        XCTAssertLessThan(px.b, 20)
    }

    func testMetallicRoughnessTextureParsedAndSetTintAndRecomputeRenderQueue() throws {
        let json: [String: Any] = [
            "name": "MRMat",
            "alphaMode": "BLEND",
            "pbrMetallicRoughness": [
                "metallicRoughnessTexture": [
                    "index": 0,
                    "extensions": ["KHR_texture_transform": ["offset": [0.25, 0.5]]],
                ],
            ],
        ]
        let gltfMat = try JSONDecoder().decode(
            GLTFMaterial.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        let mrTex = try makeSolidTexture(r: 0, g: 128, b: 255, pixelFormat: .rgba8Unorm, name: "mr")
        let mat = VRMMaterial(from: gltfMat, textures: [mrTex])
        XCTAssertTrue(mat.metallicRoughnessTexture === mrTex)
        XCTAssertEqual(mat.metallicRoughnessTextureTransform?.offset.x ?? 0, 0.25, accuracy: 1e-6)
        XCTAssertEqual(mat.renderQueue, 3000)

        mat.transparentWithZWrite = true
        mat.renderQueueOffset = 15 // clamps to 9
        mat.recomputeRenderQueue()
        XCTAssertEqual(mat.renderQueueOffset, 9)
        XCTAssertEqual(mat.renderQueue, 2519)

        mat.mtoon = VRMMToonMaterial()
        mat.setTint(SIMD4<Float>(0.8, 0.4, 0.2, 1.0), updateShadeColor: true, shadeTintMultiplier: 0.5)
        XCTAssertEqual(mat.baseColorFactor, SIMD4<Float>(0.8, 0.4, 0.2, 1.0))
        XCTAssertEqual(mat.mtoon?.shadeColorFactor.x ?? 0, 0.4, accuracy: 1e-5)
        XCTAssertEqual(mat.mtoon?.shadeColorFactor.y ?? 0, 0.2, accuracy: 1e-5)
        XCTAssertEqual(mat.mtoon?.shadeColorFactor.z ?? 0, 0.1, accuracy: 1e-5)
    }

    // MARK: - 2. ObjectIdentifier-keyed VRMSkinningSystem & VRMMorphTargetSystem

    func testSkinningSystemSyncGrowsAndReordersAndHandlesContentRevision() throws {
        let j0 = VRMNode(index: 0, name: "j0", translation: [1, 0, 0])
        let j1 = VRMNode(index: 1, name: "j1", translation: [2, 0, 0])
        j0.updateWorldTransform()
        j1.updateWorldTransform()

        let skinA = VRMSkin(name: "A")
        skinA.joints = [j0]
        skinA.inverseBindMatrices = [matrix_identity_float4x4]

        let skinB = VRMSkin(name: "B")
        skinB.joints = [j0, j1]
        skinB.inverseBindMatrices = [matrix_identity_float4x4, matrix_identity_float4x4]

        let system = VRMSkinningSystem(device: device)
        system.syncForSkins([skinA], layoutRevision: 1, contentRevision: 0)
        let firstBuf = try XCTUnwrap(system.getJointMatricesBuffer())
        system.updateJointMatrices(for: skinA)
        XCTAssertFalse(system.isSkinDirty(for: skinA))

        // Content revision change dirties without reallocating buffer
        system.syncForSkins([skinA], layoutRevision: 1, contentRevision: 1)
        XCTAssertTrue(system.isSkinDirty(for: skinA))
        XCTAssertTrue(system.getJointMatricesBuffer() === firstBuf, "Content revision must not reallocate palette ring")

        // Layout growth allocates larger ring while old buffer stays valid
        system.syncForSkins([skinB, skinA], layoutRevision: 2, contentRevision: 1)
        let grownBuf = try XCTUnwrap(system.getJointMatricesBuffer())
        XCTAssertFalse(grownBuf === firstBuf)
        XCTAssertEqual(system.getBufferOffset(for: skinB), 0)
        XCTAssertEqual(system.getBufferOffset(for: skinA), 2 * MemoryLayout<float4x4>.stride)

        system.updateJointMatrices(for: skinB)
        system.updateJointMatrices(for: skinA)
        let aMat = grownBuf.contents().advanced(by: system.getBufferOffset(for: skinA)).load(as: float4x4.self)
        XCTAssertEqual(aMat.columns.3.x, 1.0, accuracy: 1e-5)

        // Empty skin list preserves clamp-floor buffer without trapping
        system.syncForSkins([], layoutRevision: 3, contentRevision: 1)
        XCTAssertNotNil(system.getJointMatricesBuffer())
        XCTAssertNotNil(system.identityJointMatricesBuffer)
    }

    func testMorphTargetSystemKeyedByObjectIdentifierAndPrunes() throws {
        let morphSystem = try VRMMorphTargetSystem(device: device)
        let p1 = VRMPrimitive()
        let p2 = VRMPrimitive()

        let b1 = try XCTUnwrap(morphSystem.getOrCreateMorphedPositionBuffer(for: p1, vertexCount: 16))
        let b1Same = try XCTUnwrap(morphSystem.getOrCreateMorphedPositionBuffer(for: p1, vertexCount: 16))
        XCTAssertTrue(b1 === b1Same)

        // Growing vertexCount reallocates to satisfy required byte length
        let b1Grown = try XCTUnwrap(morphSystem.getOrCreateMorphedPositionBuffer(for: p1, vertexCount: 128))
        XCTAssertFalse(b1Grown === b1)
        XCTAssertGreaterThanOrEqual(b1Grown.length, 128 * MemoryLayout<SIMD3<Float>>.stride)

        _ = try XCTUnwrap(morphSystem.getOrCreateMorphedPositionBuffer(for: p2, vertexCount: 32))
        XCTAssertEqual(morphSystem.cachedPositionBufferCount, 2)

        morphSystem.evictPrimitive(p1)
        XCTAssertEqual(morphSystem.cachedPositionBufferCount, 1)

        morphSystem.prune(keeping: [])
        XCTAssertEqual(morphSystem.cachedPositionBufferCount, 0)
    }

    // MARK: - 3. Spec-driven rendering default, non-MToon tint & per-view Z-sort

    func testSpecDrivenRenderOrderAndMovingCameraTransparentSort() throws {
        XCTAssertEqual(VRMRenderer.specDrivenRenderOrder(alphaMode: .opaque, transparentWithZWrite: false), 0)
        XCTAssertEqual(VRMRenderer.specDrivenRenderOrder(alphaMode: .mask, transparentWithZWrite: false), 1)
        XCTAssertEqual(VRMRenderer.specDrivenRenderOrder(alphaMode: .blend, transparentWithZWrite: true), 2)
        XCTAssertEqual(VRMRenderer.specDrivenRenderOrder(alphaMode: .blend, transparentWithZWrite: false), 3)

        // Include legacy-triggering names ("FaceSkin_MASK", "Eyeglasses_Near", "Eyeglasses_Far")
        // to prove spec-driven default does not demote MASK or force doubleSided.
        let mOpaque = try makeMaterial(name: "Body_Opaque", alphaMode: "OPAQUE", doubleSided: false)
        let mMaskSkin = try makeMaterial(name: "Body_Skin_MASK", alphaMode: "MASK", doubleSided: false)
        let mBlendZW = try makeMaterial(name: "Lace_BlendZW", alphaMode: "BLEND", transparentWithZWrite: true)
        let mBlendA = try makeMaterial(name: "Glass_A", alphaMode: "BLEND", transparentWithZWrite: false)
        let mBlendB = try makeMaterial(name: "Glass_B", alphaMode: "BLEND", transparentWithZWrite: false)

        let pOpaque = try makeQuadPrimitive(z: 0, materialIndex: 0)
        let pMaskSkin = try makeQuadPrimitive(z: 0, materialIndex: 1)
        let pBlendZW = try makeQuadPrimitive(z: 0, materialIndex: 2)
        let pBlendA = try makeQuadPrimitive(z: -1.0, materialIndex: 3) // at z = -1
        let pBlendB = try makeQuadPrimitive(z:  1.0, materialIndex: 4) // at z = +1

        let meshes = [
            makeMesh(name: "m0", primitives: [pBlendB]),
            makeMesh(name: "m1", primitives: [pBlendA]),
            makeMesh(name: "m2", primitives: [pBlendZW]),
            makeMesh(name: "m3", primitives: [pMaskSkin]),
            makeMesh(name: "m4", primitives: [pOpaque]),
        ]
        let nodes = (0..<5).map { VRMNode(index: $0, name: "FaceNode_\($0)", mesh: $0) }
        let model = try makeMinimalModel(
            materials: [mOpaque, mMaskSkin, mBlendZW, mBlendA, mBlendB],
            meshes: meshes,
            nodes: nodes
        )

        var cfg = RendererConfig()
        cfg.colorPixelFormat = .rgba8Unorm
        let renderer = VRMRenderer(device: device, config: cfg)
        renderer.loadModelWithoutWarmup(model)

        // View 1: camera at +Z (0,0,5) -> Glass_A (z=-1) is farther than Glass_B (z=+1)
        _ = try renderRGBA(renderer: renderer, eye: [0, 0, 5], center: [0, 0, 0])
        let summary1 = renderer.cachedRenderItemSummary
        XCTAssertEqual(summary1.map(\.renderOrder), [0, 1, 2, 3, 3])
        XCTAssertEqual(summary1[1].effectiveAlphaMode, .mask, "Spec-driven default must NOT demote Body_Skin MASK to OPAQUE")
        XCTAssertFalse(summary1[1].effectiveDoubleSided, "Spec-driven default must NOT force doubleSided on FaceNode")
        XCTAssertEqual(summary1[3].materialName, "Glass_A", "From +Z camera, Glass_A (z=-1) is farther and must draw before Glass_B")
        XCTAssertEqual(summary1[4].materialName, "Glass_B")

        // View 2: camera moves to -Z (0,0,-5) WITHOUT invalidating cache -> Glass_B (z=+1) is now farther!
        _ = try renderRGBA(renderer: renderer, eye: [0, 0, -5], center: [0, 0, 0])
        let summary2 = renderer.cachedRenderItemSummary
        XCTAssertEqual(summary2[3].materialName, "Glass_B", "Moving camera must re-sort transparent tail per view on cache hit")
        XCTAssertEqual(summary2[4].materialName, "Glass_A")
    }

    func testNonMToonPBRMaterialPreservesBaseColorFactorTintInSpecDrivenMode() throws {
        // #485 §3: Non-MToon PBR material named "Face_Skin" must keep its authored red tint.
        let mat = try makeMaterial(name: "Face_Skin", alphaMode: "OPAQUE", withMToon: false)
        mat.baseColorFactor = [1.0, 0.0, 0.0, 1.0]

        let prim = try makeQuadPrimitive(z: 0, materialIndex: 0)
        let mesh = makeMesh(name: "Face", primitives: [prim])
        let node = VRMNode(index: 0, name: "Face", mesh: 0)
        let model = try makeMinimalModel(materials: [mat], meshes: [mesh], nodes: [node])

        var cfg = RendererConfig()
        cfg.colorPixelFormat = .rgba8Unorm
        let renderer = VRMRenderer(device: device, config: cfg)
        renderer.loadModelWithoutWarmup(model)
        renderer.setLight(0, direction: [0, 0, -1], color: [1, 1, 1], intensity: 1.0)
        renderer.disableLight(1)
        renderer.disableLight(2)
        renderer.setAmbientColor([0.5, 0.5, 0.5])

        let (rgba, _) = try renderRGBA(renderer: renderer)
        let px = centerPixel(rgba, size: 64)
        XCTAssertGreaterThan(px.r, 150, "Non-MToon Face_Skin must preserve authored red baseColorFactor")
        XCTAssertLessThan(px.g, 20)
        XCTAssertLessThan(px.b, 20)

        // Opt-in legacyMaterialHeuristics restores the v1 white override
        var legacyCfg = RendererConfig(legacyMaterialHeuristics: true)
        legacyCfg.colorPixelFormat = .rgba8Unorm
        let legacyRenderer = VRMRenderer(device: device, config: legacyCfg)
        legacyRenderer.loadModelWithoutWarmup(model)
        legacyRenderer.setLight(0, direction: [0, 0, -1], color: [1, 1, 1], intensity: 1.0)
        legacyRenderer.disableLight(1)
        legacyRenderer.disableLight(2)
        legacyRenderer.setAmbientColor([0.5, 0.5, 0.5])
        let (legacyRGBA, _) = try renderRGBA(renderer: legacyRenderer)
        let legacyPx = centerPixel(legacyRGBA, size: 64)
        XCTAssertGreaterThan(legacyPx.g, 150, "Opt-in legacyMaterialHeuristics must restore v1 white face override")
    }

    // MARK: - 4. Transactional VRMModel.edit, Expression Baseline Sync & liveGPUResources

    func testTransactionalEditSyncsExpressionBaselineAcrossSharedRenderers() throws {
        let mat = try makeMaterial(name: "Lip_00", alphaMode: "OPAQUE", withMToon: true)
        mat.baseColorFactor = [0.2, 0.2, 0.2, 1.0]
        mat.mtoon?.shadeColorFactor = [0.2, 0.2, 0.2]

        let prim = try makeQuadPrimitive(z: 0, materialIndex: 0)
        let mesh = makeMesh(name: "Face", primitives: [prim])
        let node = VRMNode(index: 0, name: "Face", mesh: 0)
        let model = try makeMinimalModel(materials: [mat], meshes: [mesh], nodes: [node])

        var happy = VRMExpression(name: "happy")
        happy.preset = .happy
        happy.materialColorBinds = [
            VRMMaterialColorBind(material: 0, type: .color, targetValue: [1.0, 0.0, 0.0, 1.0]),
        ]
        let exprs = VRMExpressions()
        exprs.preset[.happy] = happy
        model.expressions = exprs

        var cfg = RendererConfig()
        cfg.colorPixelFormat = .rgba8Unorm
        let rendererA = VRMRenderer(device: device, config: cfg)
        let rendererB = VRMRenderer(device: device, config: cfg)
        rendererA.loadModelWithoutWarmup(model)
        rendererB.loadModelWithoutWarmup(model)

        rendererA.setExpression(.happy, weight: 0.5)
        rendererB.setExpression(.happy, weight: 0.5)

        // Mutate tint via model.edit {} (single transaction bumps materialRevision once, not topologyRevision)
        let topoBefore = model.topologyRevision
        let matBefore = model.materialRevision
        model.edit { editor in
            editor.setTint([0.0, 1.0, 0.0, 1.0], forMaterialAt: 0)
        }
        XCTAssertEqual(model.topologyRevision, topoBefore)
        XCTAssertEqual(model.materialRevision, matBefore + 1)

        // Both renderers pick up the new green baseline on their next draw and lerp 0.5 toward red -> (0.5, 0.5, 0)
        _ = try renderRGBA(renderer: rendererA)
        _ = try renderRGBA(renderer: rendererB)
        let overrideA = try XCTUnwrap(rendererA.expressionController?.getMaterialColorOverride(materialIndex: 0, type: .color))
        let overrideB = try XCTUnwrap(rendererB.expressionController?.getMaterialColorOverride(materialIndex: 0, type: .color))
        XCTAssertEqual(overrideA.x, 0.5, accuracy: 1e-4)
        XCTAssertEqual(overrideA.y, 0.5, accuracy: 1e-4)
        XCTAssertEqual(overrideB.x, 0.5, accuracy: 1e-4)
        XCTAssertEqual(overrideB.y, 0.5, accuracy: 1e-4)

        // Remounting onto a third renderer sees the live tinted baseline immediately
        let rendererC = VRMRenderer(device: device, config: cfg)
        rendererC.loadModelWithoutWarmup(model)
        rendererC.setExpression(.happy, weight: 0.5)
        _ = try renderRGBA(renderer: rendererC)
        let overrideC = try XCTUnwrap(rendererC.expressionController?.getMaterialColorOverride(materialIndex: 0, type: .color))
        XCTAssertEqual(overrideC.y, 0.5, accuracy: 1e-4)
    }

    func testLiveGPUResourcesEnumeratesBaseAndSwappedTexturesAndBuffers() throws {
        let mat = try makeMaterial(name: "Mat0", withMToon: true)
        let baseTex = try makeSolidTexture(r: 255, g: 0, b: 0, name: "base")
        let swappedShade = try makeSolidTexture(r: 0, g: 255, b: 0, name: "swapped_shade")
        mat.baseColorTexture = baseTex
        mat.mtoon?.shadeMultiplyTexture = swappedShade

        let prim = try makeQuadPrimitive(z: 0, materialIndex: 0)
        let mesh = makeMesh(name: "quad", primitives: [prim])
        let node = VRMNode(index: 0, name: "quad", mesh: 0)
        let model = try makeMinimalModel(materials: [mat], meshes: [mesh], nodes: [node])
        model.textures = [baseTex]

        let resources = model.liveGPUResources()
        let ids = Set(resources.map { ObjectIdentifier($0 as AnyObject) })
        XCTAssertEqual(resources.count, ids.count, "liveGPUResources must be deduplicated")
        XCTAssertTrue(ids.contains(ObjectIdentifier(try XCTUnwrap(baseTex.mtlTexture) as AnyObject)))
        XCTAssertTrue(ids.contains(ObjectIdentifier(try XCTUnwrap(swappedShade.mtlTexture) as AnyObject)))
        XCTAssertTrue(ids.contains(ObjectIdentifier(try XCTUnwrap(prim.vertexBuffer) as AnyObject)))
        XCTAssertTrue(ids.contains(ObjectIdentifier(try XCTUnwrap(prim.indexBuffer) as AnyObject)))
    }

    // MARK: - 5. Offline Hierarchy Revision Isolation & Live isHidden

    func testOfflineHierarchyBuildDoesNotBumpParentHierarchyRevision() throws {
        let doc = try JSONDecoder().decode(
            GLTFDocument.self,
            from: Data(#"{"asset":{"version":"2.0"},"nodes":[{"name":"root","children":[1]},{"name":"child"}]}"#.utf8)
        )
        let revBefore = VRMNode.parentHierarchyRevision.load(ordering: .relaxed)
        let nodes = VRMResourceLoader.buildNodeHierarchy(document: doc, isVRM0: false, offline: true)
        let revAfter = VRMNode.parentHierarchyRevision.load(ordering: .relaxed)
        XCTAssertEqual(nodes.count, 2)
        XCTAssertTrue(nodes[1].parent === nodes[0])
        XCTAssertEqual(revAfter, revBefore, "Offline hierarchy build must not bump process-global parentHierarchyRevision")
    }

    func testLiveIsHiddenSkipsColorDepthPrepassOutlineAndContactShadow() throws {
        let mat = try makeMaterial(name: "HideMat", alphaMode: "OPAQUE", withMToon: true)
        mat.baseColorFactor = [1, 1, 1, 1]
        mat.mtoon?.shadeColorFactor = [1, 1, 1]
        mat.mtoon?.outlineWidthMode = .worldCoordinates
        mat.mtoon?.outlineWidthFactor = 0.05

        let prim = try makeQuadPrimitive(z: 0, materialIndex: 0)
        let mesh = makeMesh(name: "quad", primitives: [prim])
        let parentNode = VRMNode(index: 0, name: "parent")
        let childNode = VRMNode(index: 1, name: "child", mesh: 0)
        childNode.parent = parentNode
        parentNode.children = [childNode]
        let model = try makeMinimalModel(materials: [mat], meshes: [mesh], nodes: [parentNode, childNode])

        var cfg = RendererConfig()
        cfg.colorPixelFormat = .rgba8Unorm
        cfg.enableDepthPrepass = true
        let renderer = VRMRenderer(device: device, config: cfg)
        renderer.loadModelWithoutWarmup(model)
        renderer.setLight(0, direction: [0, 0, -1], color: [1, 1, 1], intensity: 1.0)
        renderer.disableLight(1)
        renderer.disableLight(2)
        renderer.setAmbientColor([1, 1, 1])

        // Visible baseline
        let (visRGBA, visDepth) = try renderRGBA(renderer: renderer)
        XCTAssertGreaterThan(centerPixel(visRGBA, size: 64).r, 150)
        XCTAssertLessThan(visDepth[32 * 64 + 32], 0.99)
        XCTAssertNotNil(renderer.contactShadowFootprint(model: model))

        // Hide parent node -> child isEffectivelyHidden skips color, depth prepass, outline, and contact shadow
        model.edit { $0.setNodeHidden(true, at: 0) }
        XCTAssertTrue(childNode.isEffectivelyHidden)
        let (hidRGBA, hidDepth) = try renderRGBA(renderer: renderer)
        XCTAssertEqual(centerPixel(hidRGBA, size: 64).r, 0)
        XCTAssertEqual(hidDepth[32 * 64 + 32], 1.0, accuracy: 1e-5)
        XCTAssertNil(renderer.contactShadowFootprint(model: model))

        // Unhide node, hide primitive directly
        model.edit {
            $0.setNodeHidden(false, at: 0)
            $0.setPrimitiveHidden(true, meshIndex: 0, primitiveIndex: 0)
        }
        let (primHidRGBA, primHidDepth) = try renderRGBA(renderer: renderer)
        XCTAssertEqual(centerPixel(primHidRGBA, size: 64).r, 0)
        XCTAssertEqual(primHidDepth[32 * 64 + 32], 1.0, accuracy: 1e-5)
        XCTAssertNil(renderer.contactShadowFootprint(model: model))
    }
}
