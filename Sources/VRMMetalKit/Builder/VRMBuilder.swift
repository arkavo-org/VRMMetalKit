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


import Foundation
import simd

/// Builder for creating VRM models from scratch
///
/// Usage:
/// ```swift
/// let vrm = try VRMBuilder()
///     .setSkeleton(.defaultHumanoid)
///     .applyMorphs(["height": 1.15, "muscle_definition": 0.7])
///     .setHairColor([0.35, 0.25, 0.15])
///     .addExpressions([.happy, .sad, .blink])
///     .build()
///
/// try vrm.serialize(to: URL(fileURLWithPath: "character.vrm"))
/// ```
public class VRMBuilder {

    private var meta: VRMMeta
    private var skeletonPreset: SkeletonPreset = .defaultHumanoid
    private var morphValues: [String: Float] = [:]
    private var hairColor: SIMD3<Float> = SIMD3(0.35, 0.25, 0.15) // Default brown
    private var eyeColor: SIMD3<Float> = SIMD3(0.4, 0.3, 0.2) // Default brown
    private var skinTone: Float = 0.5 // Default medium
    private var expressions: [VRMExpressionPreset] = []

    // MARK: - Initialization

    public init(meta: VRMMeta? = nil) {
        self.meta = meta ?? VRMMeta.default()
    }

    // MARK: - Configuration

    /// Set the skeleton preset to use
    @discardableResult
    public func setSkeleton(_ preset: SkeletonPreset) -> VRMBuilder {
        self.skeletonPreset = preset
        return self
    }

    /// Apply morph target values (height, muscle, etc.)
    @discardableResult
    public func applyMorphs(_ morphs: [String: Float]) -> VRMBuilder {
        self.morphValues.merge(morphs) { _, new in new }
        return self
    }

    /// Set hair color (RGB 0-1)
    @discardableResult
    public func setHairColor(_ color: SIMD3<Float>) -> VRMBuilder {
        self.hairColor = color
        return self
    }

    /// Set eye color (RGB 0-1)
    @discardableResult
    public func setEyeColor(_ color: SIMD3<Float>) -> VRMBuilder {
        self.eyeColor = color
        return self
    }

    /// Set skin tone (0 = lightest, 1 = darkest)
    @discardableResult
    public func setSkinTone(_ tone: Float) -> VRMBuilder {
        self.skinTone = max(0, min(1, tone))
        return self
    }

    /// Add expression presets to the model
    @discardableResult
    public func addExpressions(_ expressions: [VRMExpressionPreset]) -> VRMBuilder {
        self.expressions = expressions
        return self
    }

    // MARK: - Build

    /// Build the VRM model
    public func build() throws -> VRMModel {
        vrmLog("[VRMBuilder] Building VRM model with skeleton: \(skeletonPreset)")

        // Create base glTF document
        let gltfDocument = try buildGLTFDocument()

        // Create VRM humanoid
        let humanoid = try buildHumanoid()

        // Create VRM model
        let model = VRMModel(
            specVersion: .v1_0,
            meta: meta,
            humanoid: humanoid,
            gltf: gltfDocument
        )

        // Set expressions
        if !expressions.isEmpty {
            model.expressions = buildExpressions()
        }

        vrmLog("[VRMBuilder] VRM model built successfully")
        return model
    }

    // MARK: - Private Build Methods

    private func buildGLTFDocument() throws -> GLTFDocument {
        // Build nodes for skeleton
        let nodes = buildNodes()

        // Generate mesh geometry data first
        let meshData = generateHumanoidGeometry()

        // Build material
        let material = buildMaterial()

        // Create buffer with actual binary data
        var allBufferData = Data()
        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []

        // Helper function to add data to buffer and create buffer view/accessor
        func addAccessor(data: [Any], componentType: Int, type: String, byteLength: Int) -> Int {
            let bufferViewOffset = allBufferData.count

            // Convert data to bytes and append to buffer
            var dataBytes = Data()
            for value in data {
                if let floatValue = value as? Float {
                    let floatBytes = withUnsafeBytes(of: floatValue) { Data($0) }
                    dataBytes.append(floatBytes)
                } else if let uint16Value = value as? UInt16 {
                    let uint16Bytes = withUnsafeBytes(of: uint16Value) { Data($0) }
                    dataBytes.append(uint16Bytes)
                }
            }
            allBufferData.append(dataBytes)

            // Create buffer view
            let bufferView: [String: Any] = [
                "buffer": 0,
                "byteOffset": bufferViewOffset,
                "byteLength": byteLength
            ]
            bufferViews.append(bufferView)

            // Create accessor
            let count = type == "VEC3" ? data.count / 3 : (type == "VEC2" ? data.count / 2 : data.count)
            let accessorIndex = accessors.count
            let accessorDict: [String: Any] = [
                "bufferView": accessorIndex,
                "byteOffset": 0,
                "componentType": componentType,
                "count": count,
                "type": type
            ]
            accessors.append(accessorDict)

            return accessorIndex
        }

        // Add position accessor
        let positionIndex = addAccessor(
            data: meshData.positions.map { $0 as Any },
            componentType: 5126, // Float
            type: "VEC3",
            byteLength: meshData.positions.count * 4
        )

        // Add normal accessor
        let normalIndex = addAccessor(
            data: meshData.normals.map { $0 as Any },
            componentType: 5126, // Float
            type: "VEC3",
            byteLength: meshData.normals.count * 4
        )

        // Add texcoord accessor
        let texcoordIndex = addAccessor(
            data: meshData.texcoords.map { $0 as Any },
            componentType: 5126, // Float
            type: "VEC2",
            byteLength: meshData.texcoords.count * 4
        )

        // Add indices accessor
        let indicesIndex = addAccessor(
            data: meshData.indices.map { $0 as Any },
            componentType: 5123, // Unsigned short
            type: "SCALAR",
            byteLength: meshData.indices.count * 2
        )

        // Build mesh with correct accessor indices
        let mesh = buildHumanoidMeshWithAccessors(
            positionAccessor: positionIndex,
            normalAccessor: normalIndex,
            texcoordAccessor: texcoordIndex,
            indicesAccessor: indicesIndex
        )

        // Create buffer
        let buffer: [String: Any] = [
            "byteLength": allBufferData.count
        ]

        // Create glTF document using dictionary then encode/decode
        var documentDict: [String: Any] = [
            "asset": [
                "version": "2.0",
                "generator": "VRMBuilder (GameOfMods)"
            ],
            "scene": 0,
            "scenes": [
                [
                    "name": "Scene",
                    "nodes": [0] // Root is hips
                ]
            ],
            "extensionsUsed": ["VRMC_vrm"]
        ]

        if let copyright = meta.copyrightInformation {
            var asset = documentDict["asset"] as! [String: Any]
            asset["copyright"] = copyright
            documentDict["asset"] = asset
        }

        // Encode nodes as JSON-compatible
        let nodesData = try! JSONEncoder().encode(nodes)
        let nodesArray = try! JSONSerialization.jsonObject(with: nodesData) as! [[String: Any]]
        documentDict["nodes"] = nodesArray

        // Encode meshes
        let meshesData = try! JSONEncoder().encode([mesh])
        let meshesArray = try! JSONSerialization.jsonObject(with: meshesData) as! [[String: Any]]
        documentDict["meshes"] = meshesArray

        // Encode materials
        let materialsData = try! JSONEncoder().encode([material])
        let materialsArray = try! JSONSerialization.jsonObject(with: materialsData) as! [[String: Any]]
        documentDict["materials"] = materialsArray

        // Add buffer data to document
        documentDict["accessors"] = accessors
        documentDict["bufferViews"] = bufferViews
        documentDict["buffers"] = [buffer]

        // Decode back to GLTFDocument
        let jsonData = try! JSONSerialization.data(withJSONObject: documentDict)
        var document = try! JSONDecoder().decode(GLTFDocument.self, from: jsonData)

        // Store the binary buffer data so it can be serialized
        document.binaryBufferData = allBufferData

        vrmLog("[VRMBuilder] Generated geometry: \(meshData.positions.count/3) vertices, \(meshData.indices.count/3) triangles")
        vrmLog("[VRMBuilder] Binary buffer data: \(allBufferData.count) bytes")

        if allBufferData.isEmpty {
            vrmLog("❌ [VRMBuilder] ERROR: Binary buffer is empty!", level: .error)
        }

        return document
    }

    private func buildNodes() -> [GLTFNode] {
        let skeleton = skeletonPreset.createSkeleton()
        var nodes: [GLTFNode] = []

        // Apply height morph to skeleton if specified
        let heightScale = morphValues["height"] ?? 1.0
        let shoulderScale = morphValues["shoulder_width"] ?? 1.0

        for boneData in skeleton.bones {
            var translation = boneData.translation
            var scale: [Float] = [1.0, 1.0, 1.0]

            // Apply morphs
            if boneData.bone == .hips {
                translation[1] *= heightScale // Scale Y position
            }

            if boneData.bone == .leftShoulder || boneData.bone == .rightShoulder {
                scale[0] *= shoulderScale
            }

            // Build node as dictionary then encode/decode
            var nodeDict: [String: Any] = [
                "name": boneData.bone.rawValue,
                "translation": translation,
                "rotation": [0, 0, 0, 1], // Identity quaternion
                "scale": scale
            ]

            if let children = boneData.children {
                nodeDict["children"] = children
            }

            if boneData.bone == .hips {
                nodeDict["mesh"] = 0 // Attach mesh to hips
            }

            let jsonData = try! JSONSerialization.data(withJSONObject: nodeDict)
            let node = try! JSONDecoder().decode(GLTFNode.self, from: jsonData)

            nodes.append(node)
        }

        return nodes
    }

    private func buildHumanoid() throws -> VRMHumanoid {
        let humanoid = VRMHumanoid()
        let skeleton = skeletonPreset.createSkeleton()

        // Map bones to node indices
        for (index, boneData) in skeleton.bones.enumerated() {
            humanoid.humanBones[boneData.bone] = VRMHumanoid.VRMHumanBone(node: index)
        }

        // Validate required bones
        try humanoid.validate()

        return humanoid
    }

    private func buildExpressions() -> VRMExpressions {
        let vrmExpressions = VRMExpressions()

        // Add requested expressions (placeholder - no morph targets yet)
        for preset in expressions {
            let expression = VRMExpression(name: preset.rawValue, preset: preset)
            vrmExpressions.preset[preset] = expression
        }

        return vrmExpressions
    }

    private func buildHumanoidMesh() -> GLTFMesh {
        // Create a humanoid mesh with actual geometry
        let meshDict: [String: Any] = [
            "name": "Body",
            "primitives": [
                [
                    "attributes": [
                        "POSITION": 0,
                        "NORMAL": 1,
                        "TEXCOORD_0": 2
                    ],
                    "indices": 3,
                    "material": 0,
                    "mode": 4 // TRIANGLES
                ]
            ]
        ]

        let jsonData = try! JSONSerialization.data(withJSONObject: meshDict)
        let mesh = try! JSONDecoder().decode(GLTFMesh.self, from: jsonData)
        return mesh
    }

    private func buildHumanoidMeshWithAccessors(positionAccessor: Int, normalAccessor: Int, texcoordAccessor: Int, indicesAccessor: Int) -> GLTFMesh {
        // Create a humanoid mesh with specific accessor indices
        let meshDict: [String: Any] = [
            "name": "Body",
            "primitives": [
                [
                    "attributes": [
                        "POSITION": positionAccessor,
                        "NORMAL": normalAccessor,
                        "TEXCOORD_0": texcoordAccessor
                    ],
                    "indices": indicesAccessor,
                    "material": 0,
                    "mode": 4 // TRIANGLES
                ]
            ]
        ]

        let jsonData = try! JSONSerialization.data(withJSONObject: meshDict)
        let mesh = try! JSONDecoder().decode(GLTFMesh.self, from: jsonData)
        return mesh
    }

    private struct MeshData {
        let positions: [Float]
        let normals: [Float]
        let texcoords: [Float]
        let indices: [UInt16]
    }

    private func generateHumanoidGeometry() -> MeshData {
        // Generate a basic humanoid body mesh using parametric modeling
        let height = morphValues["height"] ?? 1.0
        let muscleDefinition = morphValues["muscle_definition"] ?? 1.0
        let shoulderWidth = morphValues["shoulder_width"] ?? 1.0

        // Basic human body parameters (simplified)
        let bodyHeight: Float = 1.8 * height
        let headRadius: Float = 0.12
        let neckRadius: Float = 0.08
        let chestRadius: Float = 0.18 * muscleDefinition
        let waistRadius: Float = 0.12
        let hipRadius: Float = 0.15

        // Generate a simple humanoid using connected spheres and cylinders
        var positions: [Float] = []
        var normals: [Float] = []
        var texcoords: [Float] = []
        var indices: [UInt16] = []

        let segments = 16
        let rings = 8
        var vertexIndex: UInt16 = 0

        // Helper function to add a sphere
        func addSphere(center: SIMD3<Float>, radius: Float, segments: Int, rings: Int) {
            for i in 0...rings {
                let phi = Float.pi * Float(i) / Float(rings)
                for j in 0..<segments {
                    let theta = 2 * Float.pi * Float(j) / Float(segments)

                    let x = center.x + radius * sin(phi) * cos(theta)
                    let y = center.y + radius * cos(phi)
                    let z = center.z + radius * sin(phi) * sin(theta)

                    positions.append(x)
                    positions.append(y)
                    positions.append(z)

                    // Normal (for sphere, normalized position - center)
                    let nx = (x - center.x) / radius
                    let ny = (y - center.y) / radius
                    let nz = (z - center.z) / radius
                    normals.append(nx)
                    normals.append(ny)
                    normals.append(nz)

                    // UV coordinates
                    let u = Float(j) / Float(segments)
                    let v = Float(i) / Float(rings)
                    texcoords.append(u)
                    texcoords.append(v)
                }
            }

            // Add indices for triangles
            for i in 0..<rings {
                for j in 0..<segments {
                    let current = vertexIndex + UInt16(i * segments + j)
                    let next = vertexIndex + UInt16(((i + 1) % (rings + 1)) * segments + j)
                    let nextJ = vertexIndex + UInt16(i * segments + ((j + 1) % segments))
                    let nextNextJ = vertexIndex + UInt16(((i + 1) % (rings + 1)) * segments + ((j + 1) % segments))

                    // Two triangles per quad
                    indices.append(contentsOf: [current, next, nextJ])
                    indices.append(contentsOf: [nextJ, next, nextNextJ])
                }
            }

            vertexIndex += UInt16((rings + 1) * segments)
        }

        // Generate body parts as connected spheres
        // TORSO
        // Head
        addSphere(center: SIMD3<Float>(0, bodyHeight - headRadius, 0), radius: headRadius, segments: segments, rings: rings)

        // Neck
        addSphere(center: SIMD3<Float>(0, bodyHeight - headRadius - 0.15, 0), radius: neckRadius, segments: segments/2, rings: rings/2)

        // Chest
        addSphere(center: SIMD3<Float>(0, bodyHeight - headRadius - 0.4, 0), radius: chestRadius, segments: segments, rings: rings)

        // Waist
        addSphere(center: SIMD3<Float>(0, bodyHeight - headRadius - 0.7, 0), radius: waistRadius, segments: segments, rings: rings)

        // Hips
        addSphere(center: SIMD3<Float>(0, bodyHeight - headRadius - 0.9, 0), radius: hipRadius, segments: segments, rings: rings)

        // ARMS
        let armRadius: Float = 0.05 * muscleDefinition
        let shoulderY = bodyHeight - headRadius - 0.4
        let shoulderX: Float = 0.15 * shoulderWidth

        // Left arm
        addSphere(center: SIMD3<Float>(shoulderX, shoulderY, 0), radius: armRadius * 1.1, segments: segments/2, rings: rings/2) // Shoulder
        addSphere(center: SIMD3<Float>(shoulderX + 0.13, shoulderY - 0.05, 0), radius: armRadius, segments: segments/2, rings: rings/2) // Upper arm mid
        addSphere(center: SIMD3<Float>(shoulderX + 0.25, shoulderY - 0.1, 0), radius: armRadius * 0.8, segments: segments/2, rings: rings/2) // Elbow
        addSphere(center: SIMD3<Float>(shoulderX + 0.38, shoulderY - 0.15, 0), radius: armRadius * 0.7, segments: segments/2, rings: rings/2) // Lower arm mid
        addSphere(center: SIMD3<Float>(shoulderX + 0.5, shoulderY - 0.2, 0), radius: armRadius * 0.6, segments: segments/2, rings: rings/2) // Hand

        // Right arm
        addSphere(center: SIMD3<Float>(-shoulderX, shoulderY, 0), radius: armRadius * 1.1, segments: segments/2, rings: rings/2) // Shoulder
        addSphere(center: SIMD3<Float>(-shoulderX - 0.13, shoulderY - 0.05, 0), radius: armRadius, segments: segments/2, rings: rings/2) // Upper arm mid
        addSphere(center: SIMD3<Float>(-shoulderX - 0.25, shoulderY - 0.1, 0), radius: armRadius * 0.8, segments: segments/2, rings: rings/2) // Elbow
        addSphere(center: SIMD3<Float>(-shoulderX - 0.38, shoulderY - 0.15, 0), radius: armRadius * 0.7, segments: segments/2, rings: rings/2) // Lower arm mid
        addSphere(center: SIMD3<Float>(-shoulderX - 0.5, shoulderY - 0.2, 0), radius: armRadius * 0.6, segments: segments/2, rings: rings/2) // Hand

        // LEGS
        let legRadius: Float = 0.08 * muscleDefinition
        let hipY = bodyHeight - headRadius - 0.95
        let hipX: Float = 0.1

        // Left leg
        addSphere(center: SIMD3<Float>(hipX, hipY, 0), radius: legRadius * 1.2, segments: segments/2, rings: rings/2) // Upper thigh
        addSphere(center: SIMD3<Float>(hipX, hipY - 0.23, 0), radius: legRadius, segments: segments/2, rings: rings/2) // Mid thigh
        addSphere(center: SIMD3<Float>(hipX, hipY - 0.45, 0), radius: legRadius * 0.9, segments: segments/2, rings: rings/2) // Knee
        addSphere(center: SIMD3<Float>(hipX, hipY - 0.68, 0), radius: legRadius * 0.7, segments: segments/2, rings: rings/2) // Mid shin
        addSphere(center: SIMD3<Float>(hipX, hipY - 0.9, 0), radius: legRadius * 0.8, segments: segments/2, rings: rings/2) // Ankle
        addSphere(center: SIMD3<Float>(hipX, hipY - 0.95, 0.05), radius: legRadius * 0.6, segments: segments/2, rings: rings/2) // Foot

        // Right leg
        addSphere(center: SIMD3<Float>(-hipX, hipY, 0), radius: legRadius * 1.2, segments: segments/2, rings: rings/2) // Upper thigh
        addSphere(center: SIMD3<Float>(-hipX, hipY - 0.23, 0), radius: legRadius, segments: segments/2, rings: rings/2) // Mid thigh
        addSphere(center: SIMD3<Float>(-hipX, hipY - 0.45, 0), radius: legRadius * 0.9, segments: segments/2, rings: rings/2) // Knee
        addSphere(center: SIMD3<Float>(-hipX, hipY - 0.68, 0), radius: legRadius * 0.7, segments: segments/2, rings: rings/2) // Mid shin
        addSphere(center: SIMD3<Float>(-hipX, hipY - 0.9, 0), radius: legRadius * 0.8, segments: segments/2, rings: rings/2) // Ankle
        addSphere(center: SIMD3<Float>(-hipX, hipY - 0.95, 0.05), radius: legRadius * 0.6, segments: segments/2, rings: rings/2) // Foot

        return MeshData(
            positions: positions,
            normals: normals,
            texcoords: texcoords,
            indices: indices
        )
    }

    private func buildMaterial() -> GLTFMaterial {
        // Create MToon-style material
        let skinColor = interpolateSkinTone(skinTone)

        // Build material as dictionary then encode/decode
        // This works around the Codable-only initializer
        let materialDict: [String: Any] = [
            "name": "Skin",
            "pbrMetallicRoughness": [
                "baseColorFactor": [skinColor.x, skinColor.y, skinColor.z, 1.0],
                "metallicFactor": 0.0,
                "roughnessFactor": 1.0
            ],
            "alphaMode": "OPAQUE",
            "doubleSided": false
        ]

        let jsonData = try! JSONSerialization.data(withJSONObject: materialDict)
        let material = try! JSONDecoder().decode(GLTFMaterial.self, from: jsonData)
        return material
    }

    private func interpolateSkinTone(_ value: Float) -> SIMD3<Float> {
        let lightSkin = SIMD3<Float>(0.95, 0.85, 0.75)
        let darkSkin = SIMD3<Float>(0.35, 0.25, 0.20)
        let t = SIMD3<Float>(repeating: value)
        return lightSkin * (SIMD3<Float>(1, 1, 1) - t) + darkSkin * t
    }
}

// MARK: - Skeleton Presets

public enum SkeletonPreset {
    case defaultHumanoid
    case tall
    case short
    case stocky

    func createSkeleton() -> SkeletonDefinition {
        switch self {
        case .defaultHumanoid:
            return SkeletonDefinition.defaultHumanoid()
        case .tall:
            return SkeletonDefinition.tall()
        case .short:
            return SkeletonDefinition.short()
        case .stocky:
            return SkeletonDefinition.stocky()
        }
    }
}

// MARK: - Skeleton Definition

public struct BoneData {
    let bone: VRMHumanoidBone
    let translation: [Float]
    let children: [Int]?
}

public struct SkeletonDefinition {
    var bones: [BoneData]

    /// Default humanoid skeleton (1.7m tall)
    static func defaultHumanoid() -> SkeletonDefinition {
        let bones: [BoneData] = [
            // 0: hips (root)
            BoneData(bone: .hips, translation: [0, 0.95, 0], children: [1, 8, 11]),
            // 1: spine
            BoneData(bone: .spine, translation: [0, 0.1, 0], children: [2]),
            // 2: chest
            BoneData(bone: .chest, translation: [0, 0.15, 0], children: [3]),
            // 3: upperChest
            BoneData(bone: .upperChest, translation: [0, 0.15, 0], children: [4, 5, 7]),
            // 4: neck
            BoneData(bone: .neck, translation: [0, 0.1, 0], children: [14]),
            // 5: leftShoulder
            BoneData(bone: .leftShoulder, translation: [0.05, 0.05, 0], children: [6]),
            // 6: leftUpperArm
            BoneData(bone: .leftUpperArm, translation: [0.15, 0, 0], children: [15]),
            // 7: rightShoulder
            BoneData(bone: .rightShoulder, translation: [-0.05, 0.05, 0], children: [16]),
            // 8: leftUpperLeg
            BoneData(bone: .leftUpperLeg, translation: [0.1, -0.05, 0], children: [9]),
            // 9: leftLowerLeg
            BoneData(bone: .leftLowerLeg, translation: [0, -0.45, 0], children: [10]),
            // 10: leftFoot
            BoneData(bone: .leftFoot, translation: [0, -0.45, 0], children: nil),
            // 11: rightUpperLeg
            BoneData(bone: .rightUpperLeg, translation: [-0.1, -0.05, 0], children: [12]),
            // 12: rightLowerLeg
            BoneData(bone: .rightLowerLeg, translation: [0, -0.45, 0], children: [13]),
            // 13: rightFoot
            BoneData(bone: .rightFoot, translation: [0, -0.45, 0], children: nil),
            // 14: head
            BoneData(bone: .head, translation: [0, 0.1, 0], children: nil),
            // 15: leftLowerArm
            BoneData(bone: .leftLowerArm, translation: [0.25, 0, 0], children: [17]),
            // 16: rightUpperArm
            BoneData(bone: .rightUpperArm, translation: [-0.15, 0, 0], children: [18]),
            // 17: leftHand
            BoneData(bone: .leftHand, translation: [0.25, 0, 0], children: nil),
            // 18: rightLowerArm
            BoneData(bone: .rightLowerArm, translation: [-0.25, 0, 0], children: [19]),
            // 19: rightHand
            BoneData(bone: .rightHand, translation: [-0.25, 0, 0], children: nil)
        ]

        return SkeletonDefinition(bones: bones)
    }

    /// Tall skeleton (2.0m)
    static func tall() -> SkeletonDefinition {
        var def = defaultHumanoid()
        // Scale all Y translations by 1.18
        def.bones = def.bones.map { bone in
            var newTranslation = bone.translation
            newTranslation[1] *= 1.18
            return BoneData(bone: bone.bone, translation: newTranslation, children: bone.children)
        }
        return def
    }

    /// Short skeleton (1.4m)
    static func short() -> SkeletonDefinition {
        var def = defaultHumanoid()
        // Scale all Y translations by 0.82
        def.bones = def.bones.map { bone in
            var newTranslation = bone.translation
            newTranslation[1] *= 0.82
            return BoneData(bone: bone.bone, translation: newTranslation, children: bone.children)
        }
        return def
    }

    /// Stocky skeleton (wider proportions)
    static func stocky() -> SkeletonDefinition {
        var def = defaultHumanoid()
        // Scale X translations by 1.2 for shoulders/hips
        def.bones = def.bones.map { bone in
            var newTranslation = bone.translation
            if bone.bone == .leftShoulder || bone.bone == .leftUpperLeg {
                newTranslation[0] *= 1.2
            } else if bone.bone == .rightShoulder || bone.bone == .rightUpperLeg {
                newTranslation[0] *= 1.2
            }
            return BoneData(bone: bone.bone, translation: newTranslation, children: bone.children)
        }
        return def
    }
}

// MARK: - Helper Extensions

extension VRMMeta {
    static func `default`() -> VRMMeta {
        var meta = VRMMeta(licenseUrl: "")
        meta.name = "VRMBuilder Character"
        meta.version = "1.0"
        meta.authors = ["VRMBuilder"]
        meta.copyrightInformation = "Generated by VRMBuilder"
        return meta
    }
}
