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

extension AuthorErrorCode {
    public static let outfitLayerConflict: AuthorErrorCode = "OUTFIT_LAYER_CONFLICT"
    public static let garmentPenetration: AuthorErrorCode = "GARMENT_PENETRATION"
    public static let springChainOverlap: AuthorErrorCode = "SPRING_CHAIN_OVERLAP"
    public static let springTailMissing: AuthorErrorCode = "SPRING_TAIL_MISSING"
    public static let attachmentNotFound: AuthorErrorCode = "ATTACHMENT_NOT_FOUND"
    public static let hairClearanceUnsatisfiable: AuthorErrorCode = "HAIR_CLEARANCE_UNSATISFIABLE"
    public static let hostRegionMissing: AuthorErrorCode = "HOST_REGION_MISSING"
    public static let meshInvalid: AuthorErrorCode = "MESH_INVALID"
}

/// Per-clump metadata emitted with the hair mesh so acceptance tests and
/// editors can reason about the generated strips without private state.
public struct HairClumpInfo: Codable, Hashable, Sendable {
    public var id: String
    public var hairItemId: String
    public var isBang: Bool
    public var rootSampleIndex: Int
    public var rootPosition: SIMD3<Float>
    /// Chain node ids root → terminal tail.
    public var nodeIds: [String]
    public var springId: String
    /// Vertex range of this clump inside the hair primitive.
    public var vertexStart: Int
    public var vertexCount: Int
    /// Vertices before this index belong to the scalp-attached first bone and
    /// are exempt from the bang clearance requirement.
    public var clearanceVertexStart: Int
    /// Vertices at or after this index belong to the last (tip) bone segment.
    public var tipVertexStart: Int
    /// The last rotating joint and the axis a tip-bend sweep rotates about.
    public var sweepPivot: SIMD3<Float>
    public var sweepAxis: SIMD3<Float>
    public var sectionCentres: [SIMD3<Float>]

    public init(id: String, hairItemId: String, isBang: Bool, rootSampleIndex: Int, rootPosition: SIMD3<Float>, nodeIds: [String], springId: String,
                vertexStart: Int, vertexCount: Int, clearanceVertexStart: Int, tipVertexStart: Int, sweepPivot: SIMD3<Float>, sweepAxis: SIMD3<Float>,
                sectionCentres: [SIMD3<Float>]) {
        self.id = id
        self.hairItemId = hairItemId
        self.isBang = isBang
        self.rootSampleIndex = rootSampleIndex
        self.rootPosition = rootPosition
        self.nodeIds = nodeIds
        self.springId = springId
        self.vertexStart = vertexStart
        self.vertexCount = vertexCount
        self.clearanceVertexStart = clearanceVertexStart
        self.tipVertexStart = tipVertexStart
        self.sweepPivot = sweepPivot
        self.sweepAxis = sweepAxis
        self.sectionCentres = sectionCentres
    }
}

/// What a garment covers and hides, for first-person annotation and QA.
public struct GarmentInfo: Codable, Hashable, Sendable {
    public var id: String
    public var preset: String
    public var meshId: String
    public var layer: Int
    public var offsetM: Double
    public var minClearanceM: Double
    public var coveredRegions: [String]
    public var hiddenRegions: [String]

    public init(id: String, preset: String, meshId: String, layer: Int, offsetM: Double, minClearanceM: Double, coveredRegions: [String], hiddenRegions: [String]) {
        self.id = id
        self.preset = preset
        self.meshId = meshId
        self.layer = layer
        self.offsetM = offsetM
        self.minClearanceM = minClearanceM
        self.coveredRegions = coveredRegions
        self.hiddenRegions = hiddenRegions
    }
}

/// Everything the wearable compiler adds to a `CompiledAvatar`. Garment mesh
/// instances reference the host body skin id, which is not repeated in `skins`.
public struct WearableOutput: Codable, Hashable, Sendable {
    public var meshes: [CompiledMesh]
    public var nodes: [CompiledNode]
    public var skins: [CompiledSkin]
    public var meshInstances: [CompiledMeshInstance]
    public var springs: [SpringObject]
    public var colliders: [ColliderObject]
    public var colliderGroups: [ColliderGroupObject]
    public var hiddenRegions: [String]
    /// Preset id → layers it may occupy.
    public var permittedLayers: [String: [Int]]
    public var hairClumps: [HairClumpInfo]
    public var garments: [GarmentInfo]
    public var warnings: [AuthorWarning]

    public init(meshes: [CompiledMesh] = [], nodes: [CompiledNode] = [], skins: [CompiledSkin] = [], meshInstances: [CompiledMeshInstance] = [],
                springs: [SpringObject] = [], colliders: [ColliderObject] = [], colliderGroups: [ColliderGroupObject] = [], hiddenRegions: [String] = [],
                permittedLayers: [String: [Int]] = [:], hairClumps: [HairClumpInfo] = [], garments: [GarmentInfo] = [], warnings: [AuthorWarning] = []) {
        self.meshes = meshes
        self.nodes = nodes
        self.skins = skins
        self.meshInstances = meshInstances
        self.springs = springs
        self.colliders = colliders
        self.colliderGroups = colliderGroups
        self.hiddenRegions = hiddenRegions
        self.permittedLayers = permittedLayers
        self.hairClumps = hairClumps
        self.garments = garments
        self.warnings = warnings
    }

    /// Id-sorted copy with the same ordering rules as `CompiledAvatar.sorted()`.
    public func sorted() -> WearableOutput {
        var copy = self
        copy.meshes = CompiledAvatar.sortedById(meshes, \.id)
        copy.nodes = CompiledAvatar.sortedById(nodes, \.id)
        copy.skins = CompiledAvatar.sortedById(skins, \.id)
        copy.meshInstances = meshInstances.sorted { CompiledAvatar.precedes($0.nodeId + "\u{0}" + $0.meshId, $1.nodeId + "\u{0}" + $1.meshId) }
        copy.springs = CompiledAvatar.sortedById(springs, \.id)
        copy.colliders = CompiledAvatar.sortedById(colliders, \.id)
        copy.colliderGroups = CompiledAvatar.sortedById(colliderGroups, \.id)
        copy.hiddenRegions = Array(Set(hiddenRegions)).sorted(by: CompiledAvatar.precedes)
        copy.hairClumps = CompiledAvatar.sortedById(hairClumps, \.id)
        copy.garments = CompiledAvatar.sortedById(garments, \.id)
        return copy
    }

    public func buildHash() throws -> String {
        try CanonicalJSON.sha256(try JSONValue.from(sorted()))
    }

    /// Appends this output to an avatar and returns the sorted result.
    public func merged(into avatar: CompiledAvatar) -> CompiledAvatar {
        var out = avatar
        out.meshes += meshes
        out.nodes += nodes
        out.skins += skins
        out.meshInstances += meshInstances
        out.springs += springs
        out.colliders += colliders
        out.colliderGroups += colliderGroups
        return out.sorted()
    }
}
