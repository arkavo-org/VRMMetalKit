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

/// The 55 VRM 1.0 humanoid bones.
public enum VRMHumanBone: String, Codable, Hashable, Sendable, CaseIterable, CodingKeyRepresentable {
    case hips, spine, chest, upperChest, neck, head, leftEye, rightEye, jaw
    case leftUpperLeg, leftLowerLeg, leftFoot, leftToes
    case rightUpperLeg, rightLowerLeg, rightFoot, rightToes
    case leftShoulder, leftUpperArm, leftLowerArm, leftHand
    case rightShoulder, rightUpperArm, rightLowerArm, rightHand
    case leftThumbMetacarpal, leftThumbProximal, leftThumbDistal
    case leftIndexProximal, leftIndexIntermediate, leftIndexDistal
    case leftMiddleProximal, leftMiddleIntermediate, leftMiddleDistal
    case leftRingProximal, leftRingIntermediate, leftRingDistal
    case leftLittleProximal, leftLittleIntermediate, leftLittleDistal
    case rightThumbMetacarpal, rightThumbProximal, rightThumbDistal
    case rightIndexProximal, rightIndexIntermediate, rightIndexDistal
    case rightMiddleProximal, rightMiddleIntermediate, rightMiddleDistal
    case rightRingProximal, rightRingIntermediate, rightRingDistal
    case rightLittleProximal, rightLittleIntermediate, rightLittleDistal

    public var isRequired: Bool {
        switch self {
        case .hips, .spine, .head,
             .leftUpperLeg, .leftLowerLeg, .leftFoot, .rightUpperLeg, .rightLowerLeg, .rightFoot,
             .leftUpperArm, .leftLowerArm, .leftHand, .rightUpperArm, .rightLowerArm, .rightHand:
            return true
        default:
            return false
        }
    }

    public static var required: [VRMHumanBone] { allCases.filter(\.isRequired) }
}

public struct CompiledNode: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var parentId: String?
    public var translation: SIMD3<Float>
    public var rotation: SIMD4<Float>
    public var scale: SIMD3<Float>
    public var humanoidBone: VRMHumanBone?

    public init(id: String, name: String, parentId: String? = nil, translation: SIMD3<Float> = .zero, rotation: SIMD4<Float> = SIMD4(0, 0, 0, 1),
                scale: SIMD3<Float> = SIMD3(repeating: 1), humanoidBone: VRMHumanBone? = nil) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
        self.humanoidBone = humanoidBone
    }
}

public struct CompiledMorph: Codable, Hashable, Sendable {
    public var name: String
    public var positionDeltas: [SIMD3<Float>]

    public init(name: String, positionDeltas: [SIMD3<Float>]) {
        self.name = name
        self.positionDeltas = positionDeltas
    }
}

public struct CompiledPrimitive: Codable, Hashable, Sendable {
    public var materialId: String
    public var positions: [SIMD3<Float>]
    public var normals: [SIMD3<Float>]
    public var uv0: [SIMD2<Float>]
    public var joints0: [SIMD4<UInt16>]?
    public var weights0: [SIMD4<Float>]?
    public var indices: [UInt32]
    public var morphTargets: [CompiledMorph]

    public init(materialId: String, positions: [SIMD3<Float>], normals: [SIMD3<Float>], uv0: [SIMD2<Float>], joints0: [SIMD4<UInt16>]? = nil,
                weights0: [SIMD4<Float>]? = nil, indices: [UInt32], morphTargets: [CompiledMorph] = []) {
        self.materialId = materialId
        self.positions = positions
        self.normals = normals
        self.uv0 = uv0
        self.joints0 = joints0
        self.weights0 = weights0
        self.indices = indices
        self.morphTargets = morphTargets
    }
}

public struct CompiledMesh: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var primitives: [CompiledPrimitive]

    public init(id: String, name: String, primitives: [CompiledPrimitive]) {
        self.id = id
        self.name = name
        self.primitives = primitives
    }
}

/// Inverse bind matrices are 16 floats each, column-major.
public struct CompiledSkin: Codable, Hashable, Sendable {
    public var id: String
    public var jointNodeIds: [String]
    public var inverseBindMatrices: [SIMD16<Float>]

    public init(id: String, jointNodeIds: [String], inverseBindMatrices: [SIMD16<Float>]) {
        self.id = id
        self.jointNodeIds = jointNodeIds
        self.inverseBindMatrices = inverseBindMatrices
    }
}

public struct CompiledMeshInstance: Codable, Hashable, Sendable {
    public var nodeId: String
    public var meshId: String
    public var skinId: String?

    public init(nodeId: String, meshId: String, skinId: String? = nil) {
        self.nodeId = nodeId
        self.meshId = meshId
        self.skinId = skinId
    }
}

public struct CompiledImage: Codable, Hashable, Sendable {
    public var id: String
    public var pngData: Data
    public var colourSpace: ColourSpace
    public var usage: ImageUsage

    public init(id: String, pngData: Data, colourSpace: ColourSpace, usage: ImageUsage) {
        self.id = id
        self.pngData = pngData
        self.colourSpace = colourSpace
        self.usage = usage
    }

    public var sha256: String { SHA256Hex.hex(pngData) }
}

public typealias CompiledMaterial = MaterialObject
public typealias CompiledExpression = ExpressionObject

/// The contract between template, hair, materials and export. Arrays are kept
/// sorted by id; the export index of an object is its position after sorting.
public struct CompiledAvatar: Codable, Hashable, Sendable {
    public var nodes: [CompiledNode]
    public var meshes: [CompiledMesh]
    public var skins: [CompiledSkin]
    public var meshInstances: [CompiledMeshInstance]
    public var images: [CompiledImage]
    public var materials: [CompiledMaterial]
    public var humanoid: [VRMHumanBone: String]
    public var expressions: [CompiledExpression]
    public var lookAt: LookAtObject
    public var firstPerson: FirstPersonObject
    public var springs: [SpringObject]
    public var colliders: [ColliderObject]
    public var colliderGroups: [ColliderGroupObject]
    public var meta: VRMMeta

    public init(nodes: [CompiledNode], meshes: [CompiledMesh], skins: [CompiledSkin], meshInstances: [CompiledMeshInstance], images: [CompiledImage],
                materials: [CompiledMaterial], humanoid: [VRMHumanBone: String], expressions: [CompiledExpression], lookAt: LookAtObject,
                firstPerson: FirstPersonObject, springs: [SpringObject], colliders: [ColliderObject], colliderGroups: [ColliderGroupObject], meta: VRMMeta) {
        self.nodes = nodes
        self.meshes = meshes
        self.skins = skins
        self.meshInstances = meshInstances
        self.images = images
        self.materials = materials
        self.humanoid = humanoid
        self.expressions = expressions
        self.lookAt = lookAt
        self.firstPerson = firstPerson
        self.springs = springs
        self.colliders = colliders
        self.colliderGroups = colliderGroups
        self.meta = meta
    }

    /// Stable ordering: every id-keyed array sorted by id (UTF-16 code unit order),
    /// mesh instances by node id then mesh id.
    public func sorted() -> CompiledAvatar {
        var copy = self
        copy.nodes = CompiledAvatar.sortedById(nodes, \.id)
        copy.meshes = CompiledAvatar.sortedById(meshes, \.id)
        copy.skins = CompiledAvatar.sortedById(skins, \.id)
        copy.meshInstances = meshInstances.sorted { CompiledAvatar.precedes($0.nodeId + "\u{0}" + $0.meshId, $1.nodeId + "\u{0}" + $1.meshId) }
        copy.images = CompiledAvatar.sortedById(images, \.id)
        copy.materials = CompiledAvatar.sortedById(materials, \.id)
        copy.expressions = CompiledAvatar.sortedById(expressions, \.id)
        copy.springs = CompiledAvatar.sortedById(springs, \.id)
        copy.colliders = CompiledAvatar.sortedById(colliders, \.id)
        copy.colliderGroups = CompiledAvatar.sortedById(colliderGroups, \.id)
        return copy
    }

    public static func precedes(_ a: String, _ b: String) -> Bool {
        Array(a.utf16).lexicographicallyPrecedes(Array(b.utf16))
    }

    public static func sortedById<T>(_ items: [T], _ id: KeyPath<T, String>) -> [T] {
        items.sorted { precedes($0[keyPath: id], $1[keyPath: id]) }
    }

    /// Export index of an id after stable sorting, or nil when absent.
    public static func exportIndex<T>(of id: String, in items: [T], _ key: KeyPath<T, String>) -> Int? {
        sortedById(items, key).firstIndex { $0[keyPath: key] == id }
    }

    /// Canonical JSON of the sorted avatar with each image's bytes replaced by its sha256.
    public func hashableJSON() throws -> JSONValue {
        let s = sorted()
        let view = HashView(
            nodes: s.nodes, meshes: s.meshes, skins: s.skins, meshInstances: s.meshInstances,
            images: s.images.map { ImageDigest(id: $0.id, pngSha256: $0.sha256, colourSpace: $0.colourSpace, usage: $0.usage) },
            materials: s.materials, humanoid: s.humanoid, expressions: s.expressions, lookAt: s.lookAt, firstPerson: s.firstPerson,
            springs: s.springs, colliders: s.colliders, colliderGroups: s.colliderGroups, meta: s.meta)
        return try JSONValue.from(view)
    }

    public func buildHash() throws -> String {
        try CanonicalJSON.sha256(try hashableJSON())
    }

    private struct ImageDigest: Encodable {
        var id: String
        var pngSha256: String
        var colourSpace: ColourSpace
        var usage: ImageUsage
    }

    private struct HashView: Encodable {
        var nodes: [CompiledNode]
        var meshes: [CompiledMesh]
        var skins: [CompiledSkin]
        var meshInstances: [CompiledMeshInstance]
        var images: [ImageDigest]
        var materials: [CompiledMaterial]
        var humanoid: [VRMHumanBone: String]
        var expressions: [CompiledExpression]
        var lookAt: LookAtObject
        var firstPerson: FirstPersonObject
        var springs: [SpringObject]
        var colliders: [ColliderObject]
        var colliderGroups: [ColliderGroupObject]
        var meta: VRMMeta
    }
}
