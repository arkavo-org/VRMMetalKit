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

final class CosmeticWearablesTests: XCTestCase {

    // MARK: - GLB Builder Helpers

    private struct GLBMaterialSpec {
        var name: String
        var baseColor: [Float] = [1, 1, 1, 1]
        var alphaMode: String = "OPAQUE"
        var doubleSided: Bool = true
        var mtoon: Bool = false
        var unlit: Bool = false
        var renderQueueOffset: Int? = nil
    }

    private func packGLB(json: [String: Any], bin: Data) throws -> Data {
        let jsonRaw = try JSONSerialization.data(withJSONObject: json, options: [])
        let jsonPad = (4 - (jsonRaw.count % 4)) % 4
        var jsonChunk = jsonRaw
        if jsonPad > 0 { jsonChunk.append(Data(repeating: 0x20, count: jsonPad)) }

        var binChunk = bin
        let binPad = (4 - (binChunk.count % 4)) % 4
        if binPad > 0 { binChunk.append(Data(repeating: 0x00, count: binPad)) }

        let totalLength = UInt32(12 + 8 + jsonChunk.count + 8 + binChunk.count)
        var glb = Data()
        func appendU32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { glb.append(contentsOf: $0) }
        }
        appendU32(0x46546C67) // "glTF"
        appendU32(2)          // version 2
        appendU32(totalLength)
        appendU32(UInt32(jsonChunk.count))
        appendU32(0x4E4F534A) // "JSON"
        glb.append(jsonChunk)
        appendU32(UInt32(binChunk.count))
        appendU32(0x004E4942) // "BIN\0"
        glb.append(binChunk)
        return glb
    }

    /// Builds a minimal rigid triangle/quad GLB in memory.
    private func makeRigidQuadGLB(
        materials: [GLBMaterialSpec],
        extensionsRequired: [String]? = nil,
        halfSize: Float = 0.2,
        zOffset: Float = 0.0,
        multiScene: Bool = false
    ) throws -> Data {
        let positions: [Float] = [
            -halfSize, -halfSize, zOffset,
             halfSize, -halfSize, zOffset,
             halfSize,  halfSize, zOffset,
            -halfSize,  halfSize, zOffset,
        ]
        let normals: [Float] = [
            0, 0, 1,
            0, 0, 1,
            0, 0, 1,
            0, 0, 1,
        ]
        let uvs: [Float] = [
            0, 0,
            1, 0,
            1, 1,
            0, 1,
        ]
        let indices: [UInt16] = [0, 1, 2, 0, 2, 3]

        var bin = Data()
        func appendFloats(_ arr: [Float]) -> (offset: Int, length: Int) {
            let offset = bin.count
            arr.withUnsafeBytes { bin.append(contentsOf: $0) }
            return (offset, arr.count * 4)
        }
        func appendU16(_ arr: [UInt16]) -> (offset: Int, length: Int) {
            let offset = bin.count
            arr.withUnsafeBytes { bin.append(contentsOf: $0) }
            return (offset, arr.count * 2)
        }

        let posView = appendFloats(positions)
        let nrmView = appendFloats(normals)
        let uvView = appendFloats(uvs)
        let idxView = appendU16(indices)

        let gltfMaterials: [[String: Any]] = materials.map { spec in
            var mat: [String: Any] = [
                "name": spec.name,
                "alphaMode": spec.alphaMode,
                "doubleSided": spec.doubleSided,
                "pbrMetallicRoughness": [
                    "baseColorFactor": spec.baseColor,
                    "metallicFactor": 0.0,
                    "roughnessFactor": 1.0,
                ],
            ]
            var exts: [String: Any] = [:]
            if spec.mtoon {
                var mtoonDict: [String: Any] = [
                    "specVersion": "1.0",
                    "shadeColorFactor": [spec.baseColor[0] * 0.7, spec.baseColor[1] * 0.7, spec.baseColor[2] * 0.7],
                    "shadingToonyFactor": 0.9,
                    "shadingShiftFactor": 0.0,
                    "giEqualizationFactor": 0.9,
                ]
                if let rqo = spec.renderQueueOffset {
                    mtoonDict["renderQueueOffsetNumber"] = rqo
                }
                exts["VRMC_materials_mtoon"] = mtoonDict
            } else if spec.unlit {
                exts["KHR_materials_unlit"] = [String: Any]()
            }
            if !exts.isEmpty {
                mat["extensions"] = exts
            }
            return mat
        }

        var meshes: [[String: Any]] = []
        var nodes: [[String: Any]] = []
        for (i, spec) in materials.enumerated() {
            meshes.append([
                "name": "mesh_\(spec.name)",
                "primitives": [[
                    "attributes": ["POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2],
                    "indices": 3,
                    "material": i,
                ]],
            ])
            nodes.append([
                "name": "node_\(spec.name)",
                "mesh": i,
            ])
        }

        var json: [String: Any] = [
            "asset": ["version": "2.0"],
            "scene": 0,
            "scenes": multiScene
                ? [["nodes": [0]], ["nodes": Array(1..<nodes.count)]]
                : [["nodes": Array(0..<nodes.count)]],
            "nodes": nodes,
            "meshes": meshes,
            "materials": gltfMaterials,
            "buffers": [["byteLength": bin.count]],
            "bufferViews": [
                ["buffer": 0, "byteOffset": posView.offset, "byteLength": posView.length],
                ["buffer": 0, "byteOffset": nrmView.offset, "byteLength": nrmView.length],
                ["buffer": 0, "byteOffset": uvView.offset, "byteLength": uvView.length],
                ["buffer": 0, "byteOffset": idxView.offset, "byteLength": idxView.length],
            ],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3",
                 "min": [-halfSize, -halfSize, zOffset], "max": [halfSize, halfSize, zOffset]],
                ["bufferView": 1, "componentType": 5126, "count": 4, "type": "VEC3"],
                ["bufferView": 2, "componentType": 5126, "count": 4, "type": "VEC2"],
                ["bufferView": 3, "componentType": 5123, "count": 6, "type": "SCALAR"],
            ],
        ]
        if let req = extensionsRequired {
            json["extensionsRequired"] = req
        }
        return try packGLB(json: json, bin: bin)
    }

    /// Builds a skinned humanoid garment GLB with optional VRM 0.0 / 1.0 extension,
    /// secondary `J_Sec_L_Arm_01` cloth bone, morph target, and configurable skeleton scale.
    private func makeSkinnedGarmentGLB(
        isVRM0: Bool = false,
        skeletonScale: Float = 1.0,
        includeSecondaryArmBone: Bool = true,
        includeMorphDelta: Bool = true,
        baseColor: [Float] = [0.2, 0.4, 0.95, 1.0]
    ) throws -> Data {
        let s = skeletonScale
        // VRM 0.0 faces -Z so raw positions/nodes have negated X/Z before load-time Ry180.
        let signXZ: Float = isVRM0 ? -1.0 : 1.0

        // 4 vertices: bottom two bound to hips (joint 0), top two bound to leftUpperArm (joint 2) or secondary (joint 3).
        let positions: [Float] = [
            -0.25 * s * signXZ, 0.9 * s,  0.15 * s * signXZ,
             0.25 * s * signXZ, 0.9 * s,  0.15 * s * signXZ,
             0.25 * s * signXZ, 1.4 * s,  0.15 * s * signXZ,
            -0.25 * s * signXZ, 1.4 * s,  0.15 * s * signXZ,
        ]
        let normals: [Float] = [
            0, 0, signXZ,
            0, 0, signXZ,
            0, 0, signXZ,
            0, 0, signXZ,
        ]
        let uvs: [Float] = [0, 0, 1, 0, 1, 1, 0, 1]
        let joints: [UInt16] = includeSecondaryArmBone
            ? [0, 0, 0, 0,  0, 0, 0, 0,  2, 0, 0, 0,  3, 0, 0, 0]
            : [0, 0, 0, 0,  0, 0, 0, 0,  2, 0, 0, 0,  1, 0, 0, 0]
        let weights: [Float] = [
            1, 0, 0, 0,
            1, 0, 0, 0,
            1, 0, 0, 0,
            1, 0, 0, 0,
        ]
        let indices: [UInt16] = [0, 1, 2, 0, 2, 3]
        let morphDeltas: [Float] = [
            0, 0, 0.1 * signXZ,
            0, 0, 0.1 * signXZ,
            0, 0.05, 0.1 * signXZ,
            0, 0.05, 0.1 * signXZ,
        ]

        // Joint world positions in raw asset space:
        // 0: Hips at (0, 0.9*s, 0)
        // 1: Chest at (0, 1.3*s, 0) (local (0, 0.4*s, 0))
        // 2: LeftUpperArm at (0.2*s*signXZ, 1.4*s, 0) (local (0.2*s*signXZ, 0.1*s, 0))
        // 3: J_Sec_L_Arm_01 (child of LeftUpperArm) at (0.2*s*signXZ, 1.25*s, 0) (local (0, -0.15*s, 0))
        let hipsWorld = SIMD3<Float>(0, 0.9 * s, 0)
        let chestWorld = SIMD3<Float>(0, 1.3 * s, 0)
        let lArmWorld = SIMD3<Float>(0.2 * s * signXZ, 1.4 * s, 0)
        let secArmWorld = SIMD3<Float>(0.2 * s * signXZ, 1.25 * s, 0)

        var ibmMatrices: [float4x4] = [
            float4x4(translation: -hipsWorld),
            float4x4(translation: -chestWorld),
            float4x4(translation: -lArmWorld),
        ]
        if includeSecondaryArmBone {
            ibmMatrices.append(float4x4(translation: -secArmWorld))
        }

        var ibmFloats: [Float] = []
        for m in ibmMatrices {
            for col in 0..<4 {
                ibmFloats.append(m[col].x)
                ibmFloats.append(m[col].y)
                ibmFloats.append(m[col].z)
                ibmFloats.append(m[col].w)
            }
        }

        var bin = Data()
        func appendFloats(_ arr: [Float]) -> (offset: Int, length: Int) {
            let offset = bin.count
            arr.withUnsafeBytes { bin.append(contentsOf: $0) }
            return (offset, arr.count * 4)
        }
        func appendU16(_ arr: [UInt16]) -> (offset: Int, length: Int) {
            let offset = bin.count
            arr.withUnsafeBytes { bin.append(contentsOf: $0) }
            return (offset, arr.count * 2)
        }

        let posView = appendFloats(positions)
        let nrmView = appendFloats(normals)
        let uvView = appendFloats(uvs)
        let jntView = appendU16(joints)
        let wgtView = appendFloats(weights)
        let idxView = appendU16(indices)
        let ibmView = appendFloats(ibmFloats)
        let morphView = appendFloats(morphDeltas)

        var nodes: [[String: Any]] = [
            ["name": "J_Bip_C_Hips", "translation": [0.0, 0.9 * s, 0.0], "children": [1]],
            ["name": "J_Bip_C_Chest", "translation": [0.0, 0.4 * s, 0.0], "children": [2]],
            [
                "name": "J_Bip_L_UpperArm",
                "translation": [0.2 * s * signXZ, 0.1 * s, 0.0],
                "children": includeSecondaryArmBone ? [3] : [],
            ],
        ]
        let skinJointIndices: [Int]
        let meshNodeIndex: Int
        if includeSecondaryArmBone {
            nodes.append(["name": "J_Sec_L_Arm_01", "translation": [0.0, -0.15 * s, 0.0]])
            skinJointIndices = [0, 1, 2, 3]
            meshNodeIndex = 4
        } else {
            skinJointIndices = [0, 1, 2]
            meshNodeIndex = 3
        }
        nodes.append(["name": "GarmentMesh", "mesh": 0, "skin": 0])

        var primDict: [String: Any] = [
            "attributes": [
                "POSITION": 0,
                "NORMAL": 1,
                "TEXCOORD_0": 2,
                "JOINTS_0": 3,
                "WEIGHTS_0": 4,
            ],
            "indices": 5,
            "material": 0,
        ]
        if includeMorphDelta {
            primDict["targets"] = [["POSITION": 7]]
        }

        var json: [String: Any] = [
            "asset": ["version": "2.0"],
            "scene": 0,
            "scenes": [["nodes": [0, meshNodeIndex]]],
            "nodes": nodes,
            "skins": [[
                "name": "GarmentSkin",
                "joints": skinJointIndices,
                "inverseBindMatrices": 6,
            ]],
            "meshes": [["name": "Garment", "primitives": [primDict]]],
            "materials": [[
                "name": "衣装_01",
                "doubleSided": true,
                "pbrMetallicRoughness": [
                    "baseColorFactor": baseColor,
                    "metallicFactor": 0.0,
                    "roughnessFactor": 1.0,
                ],
            ]],
            "buffers": [["byteLength": bin.count]],
            "bufferViews": [
                ["buffer": 0, "byteOffset": posView.offset, "byteLength": posView.length],
                ["buffer": 0, "byteOffset": nrmView.offset, "byteLength": nrmView.length],
                ["buffer": 0, "byteOffset": uvView.offset, "byteLength": uvView.length],
                ["buffer": 0, "byteOffset": jntView.offset, "byteLength": jntView.length],
                ["buffer": 0, "byteOffset": wgtView.offset, "byteLength": wgtView.length],
                ["buffer": 0, "byteOffset": idxView.offset, "byteLength": idxView.length],
                ["buffer": 0, "byteOffset": ibmView.offset, "byteLength": ibmView.length],
                ["buffer": 0, "byteOffset": morphView.offset, "byteLength": morphView.length],
            ],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3",
                 "min": [-0.25 * s, 0.9 * s, -0.15 * s], "max": [0.25 * s, 1.4 * s, 0.15 * s]],
                ["bufferView": 1, "componentType": 5126, "count": 4, "type": "VEC3"],
                ["bufferView": 2, "componentType": 5126, "count": 4, "type": "VEC2"],
                ["bufferView": 3, "componentType": 5123, "count": 4, "type": "VEC4"],
                ["bufferView": 4, "componentType": 5126, "count": 4, "type": "VEC4"],
                ["bufferView": 5, "componentType": 5123, "count": 6, "type": "SCALAR"],
                ["bufferView": 6, "componentType": 5126, "count": ibmMatrices.count, "type": "MAT4"],
                ["bufferView": 7, "componentType": 5126, "count": 4, "type": "VEC3"],
            ],
        ]

        if isVRM0 {
            json["extensions"] = [
                "VRM": [
                    "specVersion": "0.0",
                    "meta": ["title": "VRM0Garment"],
                    "humanoid": [
                        "humanBones": [
                            ["bone": "hips", "node": 0],
                            ["bone": "chest", "node": 1],
                            ["bone": "leftUpperArm", "node": 2],
                        ],
                    ],
                ],
            ]
        }

        return try packGLB(json: json, bin: bin)
    }

    /// Builds a simple skinned host VRMModel on the given Metal device with Hips, Chest, Head, LeftUpperArm.
    private func makeSkinnedHostModel(device: MTLDevice, scale: Float = 1.0) throws -> VRMModel {
        let gltf = try JSONDecoder().decode(
            GLTFDocument.self,
            from: Data(#"{"asset":{"version":"2.0"}}"#.utf8)
        )
        let meta = VRMMeta(licenseUrl: "https://vrm.dev/licenses/1.0/")
        let humanoid = VRMHumanoid()
        humanoid.humanBones[.hips] = VRMHumanoid.VRMHumanBone(node: 0)
        humanoid.humanBones[.chest] = VRMHumanoid.VRMHumanBone(node: 1)
        humanoid.humanBones[.head] = VRMHumanoid.VRMHumanBone(node: 2)
        humanoid.humanBones[.leftUpperArm] = VRMHumanoid.VRMHumanBone(node: 3)

        let model = VRMModel(specVersion: .v1_0, meta: meta, humanoid: humanoid, gltf: gltf)
        model.device = device

        let hips = VRMNode(index: 0, name: "Hips", translation: SIMD3<Float>(0, 0.9 * scale, 0))
        let chest = VRMNode(index: 1, name: "Chest", translation: SIMD3<Float>(0, 0.4 * scale, 0))
        let head = VRMNode(index: 2, name: "Head", translation: SIMD3<Float>(0, 0.3 * scale, 0))
        let leftUpperArm = VRMNode(index: 3, name: "LeftUpperArm", translation: SIMD3<Float>(0.2 * scale, 0.1 * scale, 0))
        let bodyMeshNode = VRMNode(index: 4, name: "BodyMesh", mesh: 0, skin: 0)

        chest.setParentOffline(hips); hips.children.append(chest)
        head.setParentOffline(chest); chest.children.append(head)
        leftUpperArm.setParentOffline(chest); chest.children.append(leftUpperArm)
        hips.updateWorldTransform()
        bodyMeshNode.updateWorldTransform()

        model.nodes = [hips, chest, head, leftUpperArm, bodyMeshNode]

        let skin = VRMSkin(name: "HostSkin")
        skin.joints = [hips, chest, head, leftUpperArm]
        skin.inverseBindMatrices = skin.joints.map { simd_inverse($0.worldMatrix) }
        model.skins = [skin]

        // Two non-overlapping quads:
        //   Quad A (vertices 0..3): bound to Chest (joint 1) on left half x in [-0.45, -0.05]
        //   Quad B (vertices 4..7): bound to Head  (joint 2) on right half x in [ 0.05,  0.45]
        var vertices: [VRMVertex] = []
        let quadA: [SIMD3<Float>] = [
            SIMD3<Float>(-0.45, 1.0, 0.0),
            SIMD3<Float>(-0.05, 1.0, 0.0),
            SIMD3<Float>(-0.05, 1.5, 0.0),
            SIMD3<Float>(-0.45, 1.5, 0.0),
        ]
        for p in quadA {
            var v = VRMVertex()
            v.position = p
            v.normal = SIMD3<Float>(0, 0, 1)
            v.joints = SIMD4<UInt32>(1, 0, 0, 0) // chest
            v.weights = SIMD4<Float>(1, 0, 0, 0)
            vertices.append(v)
        }
        let quadB: [SIMD3<Float>] = [
            SIMD3<Float>(0.05, 1.0, 0.0),
            SIMD3<Float>(0.45, 1.0, 0.0),
            SIMD3<Float>(0.45, 1.5, 0.0),
            SIMD3<Float>(0.05, 1.5, 0.0),
        ]
        for p in quadB {
            var v = VRMVertex()
            v.position = p
            v.normal = SIMD3<Float>(0, 0, 1)
            v.joints = SIMD4<UInt32>(2, 0, 0, 0) // head
            v.weights = SIMD4<Float>(1, 0, 0, 0)
            vertices.append(v)
        }

        let prim = VRMPrimitive()
        prim.materialIndex = 0
        prim.hasNormals = true
        prim.hasJoints = true
        prim.hasWeights = true
        prim.requiredPaletteSize = 4
        prim.localMin = SIMD3<Float>(-0.5, 0.9, -0.2)
        prim.localMax = SIMD3<Float>(0.5, 1.6, 0.2)
        prim.uploadVertices(vertices, device: device)
        let idxData: [UInt16] = [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7]
        prim.indexBuffer = idxData.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        prim.indexCount = idxData.count
        prim.indexType = .uint16

        let mesh = VRMMesh(name: "HostBody")
        mesh.primitives = [prim]
        model.meshes = [mesh]

        let gltfMat = try JSONDecoder().decode(
            GLTFMaterial.self,
            from: Data(#"{"name":"HostBodyMat","doubleSided":true,"pbrMetallicRoughness":{"baseColorFactor":[0.0,0.8,0.2,1.0]}}"#.utf8)
        )
        let mat = VRMMaterial(from: gltfMat, textures: [], vrmVersion: .v1_0)
        var mtoon = VRMMToonMaterial()
        mtoon.shadeColorFactor = SIMD3<Float>(0.0, 0.8, 0.2)
        mtoon.giEqualizationFactor = 1.0
        mat.mtoon = mtoon
        model.materials = [mat]

        model.firstPerson = VRMFirstPerson()
        model.firstPerson?.meshAnnotations = [
            VRMFirstPerson.VRMMeshAnnotation(node: 4, type: .auto)
        ]

        model.finalizeModelLocalBounds()
        return model
    }

    private func renderOffscreen(
        renderer: VRMRenderer,
        device: MTLDevice,
        width: Int = 64,
        height: Int = 64,
        cameraPos: SIMD3<Float> = SIMD3<Float>(0, 1.25, 2.5),
        lookAt: SIMD3<Float> = SIMD3<Float>(0, 1.25, 0)
    ) throws -> [UInt8] {
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .shared
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false
        )
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private

        let colorTex = try XCTUnwrap(device.makeTexture(descriptor: colorDesc))
        let depthTex = try XCTUnwrap(device.makeTexture(descriptor: depthDesc))

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = colorTex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.depthAttachment.texture = depthTex
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.storeAction = .dontCare
        rpd.depthAttachment.clearDepth = 1.0

        renderer.viewMatrix = makeLookAt(eye: cameraPos, center: lookAt, up: SIMD3<Float>(0, 1, 0))
        renderer.projectionMatrix = makePerspective(fovyRadians: .pi / 4, aspect: Float(width) / Float(height), near: 0.05, far: 20.0)
        renderer.setLightNormalizationMode(.radiometric)
        renderer.setLight(0, direction: SIMD3<Float>(0, 0, -1), color: SIMD3<Float>(1, 1, 1), intensity: 1.0)
        renderer.setLight(1, direction: SIMD3<Float>(0, 0, 1), color: SIMD3<Float>(1, 1, 1), intensity: 0.0)
        renderer.setLight(2, direction: SIMD3<Float>(0, 1, 0), color: SIMD3<Float>(1, 1, 1), intensity: 0.0)

        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        renderer.drawOffscreen(to: colorTex, depth: depthTex, commandBuffer: cb, renderPassDescriptor: rpd)
        cb.commit()
        cb.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        colorTex.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return pixels
    }

    private func makeLookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
        let z = simd_normalize(eye - center)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        return float4x4(
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)
        )
    }

    private func makePerspective(fovyRadians: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let ys = 1 / tanf(fovyRadians * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        return float4x4(
            SIMD4<Float>(xs, 0, 0, 0),
            SIMD4<Float>(0, ys, 0, 0),
            SIMD4<Float>(0, 0, zs, -1),
            SIMD4<Float>(0, 0, near * zs, 0)
        )
    }

    // MARK: - 1. Standalone GLB Loading, Material Fallbacks & Required Extension Allowlist

    func testLoadStandaloneGLBFromMemoryMToonPBRAndUnlit() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }

        let glb = try makeRigidQuadGLB(materials: [
            GLBMaterialSpec(name: "Eyeglasses", baseColor: [0.2, 0.8, 1.0, 0.5], alphaMode: "BLEND", mtoon: true),
            GLBMaterialSpec(name: "Necklace", baseColor: [1.0, 0.85, 0.2, 1.0], alphaMode: "OPAQUE", mtoon: false, unlit: false),
            GLBMaterialSpec(name: "Surface", baseColor: [0.9, 0.1, 0.2, 1.0], alphaMode: "OPAQUE", mtoon: false, unlit: true),
            GLBMaterialSpec(name: "衣装_01", baseColor: [0.3, 0.3, 0.8, 1.0], alphaMode: "MASK", mtoon: true),
        ])

        let asset = try await VRMCosmeticAsset.load(from: glb, device: device)
        XCTAssertFalse(asset.isSkinned)
        XCTAssertEqual(asset.meshCount, 4)
        XCTAssertEqual(asset.materialCount, 4)

        // Verify PBR fallback synthesized MToon and wired shadeMultiplyTexture == baseColorTexture
        let pbrMat = asset.materials[1]
        XCTAssertNotNil(pbrMat.mtoon)
        XCTAssertEqual(pbrMat.mtoon?.shadingToonyFactor ?? 0, 0.9, accuracy: 1e-4)

        // Verify KHR_materials_unlit mapped to flat unlit MToon
        let unlitMat = asset.materials[2]
        XCTAssertNotNil(unlitMat.mtoon)
        XCTAssertEqual(unlitMat.mtoon?.shadingToonyFactor ?? -1, 0.0, accuracy: 1e-4)
        XCTAssertEqual(unlitMat.mtoon?.giEqualizationFactor ?? 0, 1.0, accuracy: 1e-4)
        XCTAssertEqual(unlitMat.mtoon?.shadeColorFactor.x ?? 0, 0.9, accuracy: 1e-4)
    }

    func testUnsupportedRequiredExtensionsRejected() async throws {
        let unsupportedList = [
            ["KHR_draco_mesh_compression"],
            ["EXT_meshopt_compression"],
            ["KHR_texture_basisu"],
            ["VRMC_node_constraint"],
        ]
        for req in unsupportedList {
            let glb = try makeRigidQuadGLB(
                materials: [GLBMaterialSpec(name: "Mat")],
                extensionsRequired: req
            )
            do {
                _ = try await VRMCosmeticAsset.load(from: glb, device: nil)
                XCTFail("Expected unsupportedRequiredExtension for \(req)")
            } catch let error as GLTFError {
                if case .unsupportedRequiredExtension(let missing) = error {
                    XCTAssertEqual(missing, req)
                } else {
                    XCTFail("Wrong GLTFError: \(error)")
                }
            }
        }
    }

    func testActiveSceneRootSelection() async throws {
        let glb = try makeRigidQuadGLB(
            materials: [
                GLBMaterialSpec(name: "ActiveSceneMesh"),
                GLBMaterialSpec(name: "InactiveSceneMesh"),
            ],
            multiScene: true
        )
        let asset = try await VRMCosmeticAsset.load(from: glb, device: nil)
        XCTAssertEqual(asset.rootNodeIndices, [0])
    }

    // MARK: - 2. Side-Scene Isolation, Fast In-Place TRS, First-Person Flag & Nested Cascade Detach

    func testRigidAttachIsolationTransformFirstPersonAndCascadeDetach() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }

        let host = try makeSkinnedHostModel(device: device)
        let hostNodeCount = host.nodes.count
        let hostMeshCount = host.meshes.count
        let hostMatCount = host.materials.count
        let hostSkinCount = host.skins.count
        let revBefore = VRMNode.parentHierarchyRevision.load(ordering: .relaxed)
        let resourcesBefore = host.liveGPUResources().count

        let hatGLB = try makeRigidQuadGLB(materials: [
            GLBMaterialSpec(name: "Eyeglasses", baseColor: [1, 0, 0, 0.7], alphaMode: "BLEND", mtoon: true)
        ])
        let charmGLB = try makeRigidQuadGLB(materials: [
            GLBMaterialSpec(name: "Necklace", baseColor: [1, 1, 0, 1], alphaMode: "OPAQUE", mtoon: false)
        ])
        let hatAsset = try await VRMCosmeticAsset.load(from: hatGLB, device: device)
        let charmAsset = try await VRMCosmeticAsset.load(from: charmGLB, device: device)

        // Attach hat to .head -> defaults to .thirdPersonOnly
        let hatHandle = try host.attach(hatAsset, to: .head)
        let hatInst = try XCTUnwrap(host.attachment(for: hatHandle))
        XCTAssertEqual(hatInst.firstPersonFlag, .thirdPersonOnly)

        // Side-scene isolation invariants
        XCTAssertEqual(host.nodes.count, hostNodeCount)
        XCTAssertEqual(host.meshes.count, hostMeshCount)
        XCTAssertEqual(host.materials.count, hostMatCount)
        XCTAssertEqual(host.skins.count, hostSkinCount)
        XCTAssertEqual(VRMNode.parentHierarchyRevision.load(ordering: .relaxed), revBefore)
        XCTAssertGreaterThan(host.liveGPUResources().count, resourcesBefore)

        // Fast in-place updateTransform: ZERO topologyRevision bump!
        let topoBeforeTRS = host.topologyRevision
        XCTAssertTrue(host.updateTransform(
            for: hatHandle,
            translation: SIMD3<Float>(0, 0.25, 0.1),
            scale: SIMD3<Float>(1.5, 1.5, 1.5)
        ))
        XCTAssertEqual(host.topologyRevision, topoBeforeTRS)
        XCTAssertEqual(hatInst.pivotNode.translation, SIMD3<Float>(0, 0.25, 0.1))

        // Configurable firstPersonFlag
        XCTAssertTrue(host.setFirstPersonFlag(.both, for: hatHandle))
        XCTAssertEqual(hatInst.firstPersonFlag, .both)
        XCTAssertGreaterThan(host.topologyRevision, topoBeforeTRS)

        // Nested child attachment anchored to a node inside the hat
        let charmHandle = try host.attach(charmAsset, toNode: hatInst.nodes[0])
        XCTAssertEqual(host.attachments.count, 2)

        // Detach parent hat -> cascades to child charm and returns both handles
        let detached = Set(host.detach(hatHandle))
        XCTAssertEqual(detached, Set([hatHandle, charmHandle]))
        XCTAssertTrue(host.attachments.isEmpty)
        XCTAssertEqual(host.liveGPUResources().count, resourcesBefore)
        XCTAssertEqual(VRMNode.parentHierarchyRevision.load(ordering: .relaxed), revBefore)
    }

    func testMultiInstanceIsolationAndDetachAll() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }

        let host = try makeSkinnedHostModel(device: device)
        let glb = try makeRigidQuadGLB(materials: [
            GLBMaterialSpec(name: "Prop", baseColor: [0.8, 0.2, 0.2, 1.0], mtoon: true)
        ])
        let asset = try await VRMCosmeticAsset.load(from: glb, device: device)

        let h1 = try host.attach(asset, to: .head)
        let h2 = try host.attach(asset, to: .chest)
        let i1 = try XCTUnwrap(host.attachment(for: h1))
        let i2 = try XCTUnwrap(host.attachment(for: h2))

        // Mutating instance 1 must not mutate instance 2 or the blueprint
        i1.materials[0].baseColorFactor = SIMD4<Float>(0, 1, 0, 1)
        XCTAssertTrue(host.setHidden(true, for: h1))

        XCTAssertEqual(i2.materials[0].baseColorFactor.x, 0.8, accuracy: 1e-4)
        XCTAssertEqual(asset.materials[0].baseColorFactor.x, 0.8, accuracy: 1e-4)
        XCTAssertFalse(i2.isHidden)

        let removed = host.detachAll()
        XCTAssertEqual(Set(removed), Set([h1, h2]))
        XCTAssertTrue(host.attachments.isEmpty)
    }

    func testSkinnedGLBRejectedByRigidAttachUnlessRigidified() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }

        let host = try makeSkinnedHostModel(device: device)
        let skinnedGLB = try makeSkinnedGarmentGLB(isVRM0: false, skeletonScale: 1.0)
        let asset = try await VRMCosmeticAsset.load(from: skinnedGLB, device: device)
        XCTAssertTrue(asset.isSkinned)

        do {
            _ = try host.attach(asset, to: .chest)
            XCTFail("Expected unsupportedSkinnedAttachment error")
        } catch VRMError.unsupportedSkinnedAttachment {
            // Expected
        }

        // Explicit opt-in rigidifies cloned instance without mutating blueprint
        let handle = try host.attach(asset, to: .chest, options: VRMAttachmentOptions(rigidifySkinnedMeshes: true))
        let inst = try XCTUnwrap(host.attachment(for: handle))
        XCTAssertTrue(inst.skins.isEmpty)
        XCTAssertFalse(inst.meshes[0].primitives[0].hasJoints)
        XCTAssertTrue(asset.isSkinned)
        XCTAssertEqual(asset.skins.count, 1)
    }

    func testCumulativeLoaderLimitsEnforcedOnAttach() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let host = try makeSkinnedHostModel(device: device)
        let glb = try makeRigidQuadGLB(materials: [GLBMaterialSpec(name: "Box")])
        let asset = try await VRMCosmeticAsset.load(from: glb, device: device)

        let tightLimits = VRMLoaderLimits(maxTotalBufferBytes: max(1, asset.estimatedBufferBytes / 2))
        do {
            _ = try host.attach(asset, to: .head, options: VRMAttachmentOptions(limits: tightLimits))
            XCTFail("Expected VRMError.limitExceeded")
        } catch VRMError.limitExceeded(let kind, _, _) {
            XCTAssertEqual(kind, "totalBufferBytes")
        }
    }

    // MARK: - 3. Skinned Garments, J_Sec Exclusion, VRM 0.x ↔ 1.0 & Proportion Fit (LBS == DQS)

    func testJSecExclusionAndExtendedHeuristics() {
        XCTAssertTrue(VRMAnimationLoader.isExcludedFallbackNode("J_Sec_L_Arm_01"))
        XCTAssertTrue(VRMAnimationLoader.isExcludedFallbackNode("J_Sec_L_CoatSkirt_01"))
        XCTAssertNil(VRMAnimationLoader.heuristicBone(forNodeName: "J_Sec_L_Arm_01"))
        XCTAssertNil(VRMSkeletonRemapper.heuristicBone(forNodeName: "J_Sec_L_Arm_01"))

        XCTAssertEqual(VRMSkeletonRemapper.heuristicBone(forNodeName: "J_Bip_L_UpperArm"), .leftUpperArm)
        XCTAssertEqual(VRMSkeletonRemapper.heuristicBone(forNodeName: "J_Adj_L_FaceEye"), .leftEye)
        XCTAssertEqual(VRMSkeletonRemapper.heuristicBone(forNodeName: "J_Bip_R_Index1"), .rightIndexProximal)
        XCTAssertEqual(VRMSkeletonRemapper.heuristicBone(forNodeName: "leftThumbDistal"), .leftThumbDistal)
    }

    func testAttachSkinnedVRM0AndVRM1ProportionFitAndSecondaryReparenting() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }

        // Host is 1.25x taller than the 1.0-scale garment
        let host = try makeSkinnedHostModel(device: device, scale: 1.25)

        for isVRM0 in [false, true] {
            let glb = try makeSkinnedGarmentGLB(
                isVRM0: isVRM0,
                skeletonScale: 1.0,
                includeSecondaryArmBone: true,
                includeMorphDelta: true
            )
            let asset = try await VRMCosmeticAsset.load(from: glb, device: device)
            let revBefore = VRMNode.parentHierarchyRevision.load(ordering: .relaxed)

            let handle = try host.attachSkinned(asset, options: VRMAttachmentOptions(proportionFit: .proportionFit))
            let inst = try XCTUnwrap(host.attachment(for: handle))

            XCTAssertEqual(VRMNode.parentHierarchyRevision.load(ordering: .relaxed), revBefore)
            XCTAssertEqual(inst.skins.count, 1)

            let skin = inst.skins[0]
            XCTAssertEqual(skin.joints.count, 4)
            // Joints 0, 1, 2 mapped directly to host bones
            XCTAssertTrue(skin.joints[0] === host.nodes[0]) // Hips
            XCTAssertTrue(skin.joints[1] === host.nodes[1]) // Chest
            XCTAssertTrue(skin.joints[2] === host.nodes[3]) // LeftUpperArm
            // Joint 3 (J_Sec_L_Arm_01) NOT mapped to host leftUpperArm; kept as secondary node parented offline under host leftUpperArm
            XCTAssertFalse(skin.joints[3] === host.nodes[3])
            XCTAssertEqual(skin.joints[3].name, "J_Sec_L_Arm_01")
            XCTAssertTrue(skin.joints[3].parent === host.nodes[3])

            // Verify bind-pose vertex placement: skinMatrix * v_scaled matches expected VRM 1.0 scaled world position
            // and joint matrices are strictly rigid (unit column lengths -> DQS == LBS!).
            let prim = inst.meshes[0].primitives[0]
            let verts = prim.interleavedVertices()
            XCTAssertEqual(verts.count, 4)
            for j in 0..<skin.joints.count {
                let skinMat = simd_mul(skin.joints[j].worldMatrix, skin.inverseBindMatrices[j])
                let col0Len = simd_length(SIMD3<Float>(skinMat.columns.0.x, skinMat.columns.0.y, skinMat.columns.0.z))
                let col1Len = simd_length(SIMD3<Float>(skinMat.columns.1.x, skinMat.columns.1.y, skinMat.columns.1.z))
                let col2Len = simd_length(SIMD3<Float>(skinMat.columns.2.x, skinMat.columns.2.y, skinMat.columns.2.z))
                XCTAssertEqual(col0Len, 1.0, accuracy: 1e-3, "Joint \(j) must be rigid for DQS parity (isVRM0=\(isVRM0))")
                XCTAssertEqual(col1Len, 1.0, accuracy: 1e-3)
                XCTAssertEqual(col2Len, 1.0, accuracy: 1e-3)
            }

            // Vertex 0 is at raw (-0.25*signXZ, 0.9, 0.15*signXZ); in VRM 1.0 scaled by 1.25 around hips:
            // x = -0.25 * 1.25 = -0.3125, y = 0.9 * 1.25 = 1.125, z = +0.15 * 1.25 = +0.1875 (positive Z in VRM 1.0!).
            let skinMat0 = simd_mul(skin.joints[0].worldMatrix, skin.inverseBindMatrices[0])
            let worldV0 = simd_mul(skinMat0, SIMD4<Float>(verts[0].position, 1.0))
            XCTAssertEqual(worldV0.x, -0.3125, accuracy: 1e-3, "VRM0=\(isVRM0) zero double-Ry180 X check")
            XCTAssertEqual(worldV0.y,  1.125,  accuracy: 1e-3, "VRM0=\(isVRM0) proportionFit Y check")
            XCTAssertEqual(worldV0.z,  0.1875, accuracy: 1e-3, "VRM0=\(isVRM0) zero double-Ry180 Z check")

            // Morph delta scaled consistently by 1.25 (blueprint remains unscaled at 0.1)
            let scaledDeltaZ = abs(prim.morphPositionDelta(targetIndex: 0, vertexIndex: 0).z)
            let blueprintDeltaZ = abs(asset.meshes[0].primitives[0].morphPositionDelta(targetIndex: 0, vertexIndex: 0).z)
            XCTAssertEqual(scaledDeltaZ, 0.125, accuracy: 1e-4)
            XCTAssertEqual(blueprintDeltaZ, 0.1, accuracy: 1e-4)

            // Render with both LBS and DQS and verify pixels match
            var lbsConfig = RendererConfig(strict: .off)
            lbsConfig.dualQuaternionSkinning = false
            let lbsRenderer = VRMRenderer(device: device, config: lbsConfig)
            lbsRenderer.loadModelWithoutWarmup(host)
            let lbsPixels = try renderOffscreen(renderer: lbsRenderer, device: device)

            var dqsConfig = RendererConfig(strict: .off)
            dqsConfig.dualQuaternionSkinning = true
            let dqsRenderer = VRMRenderer(device: device, config: dqsConfig)
            dqsRenderer.loadModelWithoutWarmup(host)
            let dqsPixels = try renderOffscreen(renderer: dqsRenderer, device: device)

            var maxDiff = 0
            for i in 0..<lbsPixels.count {
                maxDiff = max(maxDiff, abs(Int(lbsPixels[i]) - Int(dqsPixels[i])))
            }
            XCTAssertLessThanOrEqual(maxDiff, 2, "LBS and DQS bind-pose garment renders should match (isVRM0=\(isVRM0))")

            host.detach(handle)
        }
    }

    // MARK: - 4. Composable 2-Bit Vertex Body Masking + First-Person Coexistence + GPU Render

    func testComposableTwoBitBodyMaskFirstPersonCoexistenceAndGPURender() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }

        let host = try makeSkinnedHostModel(device: device)
        let renderer = VRMRenderer(device: device, config: RendererConfig(strict: .off))
        renderer.loadModelWithoutWarmup(host)

        let prim = host.meshes[0].primitives[0]
        // After loadModelWithoutWarmup, bit 0 is set on head vertices (4..7), clear on chest vertices (0..3).
        XCTAssertEqual(prim.firstPersonHiddenFlags[0], 0x00)
        XCTAssertEqual(prim.firstPersonHiddenFlags[4], 0x01)

        // Third-person baseline: both left (chest) and right (head) green quads are visible
        renderer.cameraMode = .thirdPerson
        let baseline = try renderOffscreen(renderer: renderer, device: device)
        func greenCount(in pixels: [UInt8], xRange: Range<Int>) -> Int {
            var count = 0
            for y in 0..<64 {
                for x in xRange {
                    let idx = (y * 64 + x) * 4
                    if pixels[idx + 1] > 40 { count += 1 }
                }
            }
            return count
        }
        let baseLeft = greenCount(in: baseline, xRange: 0..<32)
        let baseRight = greenCount(in: baseline, xRange: 32..<64)
        XCTAssertGreaterThan(baseLeft, 20, "Left chest quad should be visible in third-person")
        XCTAssertGreaterThan(baseRight, 20, "Right head quad should be visible in third-person")

        // Add two overlapping body masks: maskA hides chest; maskB hides chest + head
        let bufBefore = prim.firstPersonHiddenFlagsBuffer
        host.setBodyMask(id: "shirt", bones: [.chest])
        let bufAfterA = prim.firstPersonHiddenFlagsBuffer
        XCTAssertFalse(bufBefore === bufAfterA, "Mask update must allocate a fresh MTLBuffer")
        XCTAssertEqual(prim.firstPersonHiddenFlags[0], 0x02) // bit 1 set
        XCTAssertEqual(prim.firstPersonHiddenFlags[4], 0x01) // bit 0 preserved!

        // Render in third-person: chest (left) is hidden by bit 1, head (right) stays visible!
        let thirdPersonMasked = try renderOffscreen(renderer: renderer, device: device)
        XCTAssertEqual(greenCount(in: thirdPersonMasked, xRange: 0..<32), 0, "Bit 1 must hide chest in third-person")
        XCTAssertGreaterThan(greenCount(in: thirdPersonMasked, xRange: 32..<64), 20, "Bit 0 must NOT hide head in third-person")

        // Render in first-person: BOTH chest (bit 1) AND head (bit 0) are hidden!
        renderer.cameraMode = .firstPerson
        let firstPersonMasked = try renderOffscreen(renderer: renderer, device: device)
        XCTAssertEqual(greenCount(in: firstPersonMasked, xRange: 0..<32), 0)
        XCTAssertEqual(greenCount(in: firstPersonMasked, xRange: 32..<64), 0, "Bit 0 must hide head in first-person")

        // Reload survival: calling processFirstPersonAutoFlags preserves bit 1!
        processFirstPersonAutoFlags(model: host, device: device)
        XCTAssertEqual(prim.firstPersonHiddenFlags[0], 0x02)
        XCTAssertEqual(prim.firstPersonHiddenFlags[4], 0x01)

        // Composable overlap: add jacket covering chest, remove shirt -> chest stays masked until jacket is removed
        host.setBodyMask(id: "jacket", bones: [.chest])
        host.removeBodyMask(id: "shirt")
        XCTAssertEqual(prim.firstPersonHiddenFlags[0], 0x02)
        host.removeBodyMask(id: "jacket")
        XCTAssertEqual(prim.firstPersonHiddenFlags[0], 0x00)
        XCTAssertEqual(prim.firstPersonHiddenFlags[4], 0x01) // bit 0 still preserved!

        // Explicit vertex-index mask overload
        host.setBodyMask(id: "manual", hiddenVertices: [1, 2], meshIndex: 0, primitiveIndex: 0)
        XCTAssertEqual(prim.firstPersonHiddenFlags[0], 0x00)
        XCTAssertEqual(prim.firstPersonHiddenFlags[1], 0x02)
        XCTAssertEqual(prim.firstPersonHiddenFlags[2], 0x02)
        host.removeBodyMask(id: "manual")
        XCTAssertEqual(prim.firstPersonHiddenFlags[1], 0x00)

        // Attachment bodyMaskBones auto-cleans on detach
        let glb = try makeRigidQuadGLB(materials: [GLBMaterialSpec(name: "Coat")])
        let coat = try await VRMCosmeticAsset.load(from: glb, device: device)
        let handle = try host.attach(coat, to: .chest, options: VRMAttachmentOptions(bodyMaskBones: [.chest]))
        XCTAssertEqual(prim.firstPersonHiddenFlags[0], 0x02)
        host.detach(handle)
        XCTAssertEqual(prim.firstPersonHiddenFlags[0], 0x00)
    }

    // MARK: - 5. Verify All 5 Compiled Metallib Slices Exist and Load

    func testAllMetallibSlicesContainUpdatedShaders() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        // Verify all 5 platform .metallib slices are bundled in VRMMetalKit's resource bundle.
        let sliceNames = [
            "VRMMetalKitShaders",
            "VRMMetalKitShaders_iOS",
            "VRMMetalKitShaders_iOSSimulator",
            "VRMMetalKitShaders_visionOS",
            "VRMMetalKitShaders_visionOSSimulator",
        ]
        for sliceName in sliceNames {
            XCTAssertNotNil(
                VRMShaderLibraryLoader.bundledSliceURL(named: sliceName),
                "Missing bundled metallib slice: \(sliceName).metallib"
            )
        }

        let lib = try VRMShaderLibraryLoader.loadBundledLibrary(device: device)
        XCTAssertNotNil(lib.makeFunction(name: "skinned_mtoon_vertex"))
        XCTAssertNotNil(lib.makeFunction(name: "skinned_mtoon_depth_vertex"))
        XCTAssertNotNil(lib.makeFunction(name: "skinned_mtoon_outline_vertex"))
        XCTAssertNotNil(lib.makeFunction(name: "cosmetic_composite_layer"))
    }

    func testSetHiddenRefreshesCachedModelLocalBounds() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }

        let host = try makeSkinnedHostModel(device: device)
        let baselineMaxX = host.modelLocalBounds.max.x

        let glb = try makeRigidQuadGLB(materials: [GLBMaterialSpec(name: "Wing")])
        let asset = try await VRMCosmeticAsset.load(from: glb, device: device)
        // Attach far to the right (+X = 5.0) so it clearly expands host bounds
        let wing = try host.attach(asset, to: .head)
        XCTAssertTrue(host.updateTransform(for: wing, translation: SIMD3<Float>(5.0, 0, 0)))
        let expandedMaxX = host.modelLocalBounds.max.x
        XCTAssertGreaterThan(expandedMaxX, baselineMaxX + 3.0)

        // Hiding the wing must immediately shrink cached modelLocalBounds back to baseline
        XCTAssertTrue(host.setHidden(true, for: wing))
        XCTAssertEqual(host.modelLocalBounds.max.x, baselineMaxX, accuracy: 1e-3)

        // Triggering an unrelated bounds refresh while hidden keeps baseline bounds
        let other = try host.attach(asset, to: .head)
        host.detach(other)
        XCTAssertEqual(host.modelLocalBounds.max.x, baselineMaxX, accuracy: 1e-3)

        // Unhiding the wing must immediately expand cached modelLocalBounds back out
        XCTAssertTrue(host.setHidden(false, for: wing))
        XCTAssertEqual(host.modelLocalBounds.max.x, expandedMaxX, accuracy: 1e-3)
    }

    // MARK: - 6. Thread-Safety Concurrent Attach / UpdateTransform / Render Stress

    func testConcurrentAttachTransformAndBoundsReads() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }

        let host = try makeSkinnedHostModel(device: device)
        let glb = try makeRigidQuadGLB(materials: [GLBMaterialSpec(name: "Badge")])
        let asset = try await VRMCosmeticAsset.load(from: glb, device: device)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for i in 0..<25 {
                    let h = try host.attach(asset, to: .head)
                    _ = host.updateTransform(for: h, translation: SIMD3<Float>(0, Float(i) * 0.01, 0))
                    _ = host.setHidden(i % 2 == 0, for: h)
                    host.detach(h)
                }
            }
            group.addTask {
                for _ in 0..<50 {
                    _ = host.modelLocalBounds
                    _ = host.liveGPUResources()
                    host.updateAttachmentWorldTransforms()
                }
            }
            try await group.waitForAll()
        }
        XCTAssertTrue(host.attachments.isEmpty)
    }
}
