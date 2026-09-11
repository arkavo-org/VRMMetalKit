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

/// Semantic data the template exposes alongside its `CompiledAvatar` so the
/// hair/outfit/accessory and export areas can compose against it: named
/// vertex regions, scalp surface samples, attachment nodes, eye geometry and
/// the per-control region masks.
public struct TemplateAttachments: Codable, Hashable, Sendable {
    /// Vertex indices of one region inside one primitive of one mesh.
    public struct RegionRef: Codable, Hashable, Sendable {
        public var meshId: String
        public var primitiveIndex: Int
        public var indices: [Int]

        public init(meshId: String, primitiveIndex: Int, indices: [Int]) {
            self.meshId = meshId
            self.primitiveIndex = primitiveIndex
            self.indices = indices
        }
    }

    public struct SurfaceSample: Codable, Hashable, Sendable {
        public var position: SIMD3<Float>
        public var normal: SIMD3<Float>
        public var vertexIndex: Int

        public init(position: SIMD3<Float>, normal: SIMD3<Float>, vertexIndex: Int) {
            self.position = position
            self.normal = normal
            self.vertexIndex = vertexIndex
        }
    }

    public struct EyeGeometry: Codable, Hashable, Sendable {
        public var side: String
        public var meshId: String
        public var boneNodeId: String
        public var center: SIMD3<Float>
        public var globeRadius: Float
        public var lidRadius: Float
        public var openingHalfWidth: Float
        public var upperOpeningHeight: Float
        public var lowerOpeningHeight: Float
        public var irisAngleRadians: Float
        public var pupilAngleRadians: Float
        public var irisUVRadius: Float
        public var pupilUVRadius: Float
    }

    /// Region name → every (mesh, primitive, indices) carrying it.
    public var regions: [String: [RegionRef]]
    /// Positions and normals of the head skin primitive's scalp vertices.
    public var scalpSamples: [SurfaceSample]
    /// Semantic attachment name → node ID (head, neck, chest, upperChest, spine, hips,
    /// earLeft, earRight, glasses, leftHand, rightHand, leftFoot, rightFoot, root).
    public var attachmentNodes: [String: String]
    public var eyes: [EyeGeometry]
    /// Control key → region names it may displace ("*" = everything).
    public var controlRegions: [String: [String]]
    /// Ordered opening-edge rows of each lid, keyed upperL/lowerL/upperR/lowerR,
    /// column-aligned so index i of the upper row sits above index i of the lower row.
    public var lidEdges: [String: RegionRef]
    public var bodyMeshId: String
    public var headMeshId: String
    public var eyeMeshIds: [String]
    public var skinId: String
    public var jointWorldPositions: [VRMHumanBone: SIMD3<Float>]
    public var heightM: Float
    public var headHeightM: Float
    public var headCenter: SIMD3<Float>
    public var headRadii: SIMD3<Float>

    public init(regions: [String: [RegionRef]], scalpSamples: [SurfaceSample], attachmentNodes: [String: String], eyes: [EyeGeometry],
                controlRegions: [String: [String]], lidEdges: [String: RegionRef], bodyMeshId: String, headMeshId: String, eyeMeshIds: [String],
                skinId: String, jointWorldPositions: [VRMHumanBone: SIMD3<Float>], heightM: Float, headHeightM: Float, headCenter: SIMD3<Float>,
                headRadii: SIMD3<Float>) {
        self.regions = regions
        self.scalpSamples = scalpSamples
        self.attachmentNodes = attachmentNodes
        self.eyes = eyes
        self.controlRegions = controlRegions
        self.lidEdges = lidEdges
        self.bodyMeshId = bodyMeshId
        self.headMeshId = headMeshId
        self.eyeMeshIds = eyeMeshIds
        self.skinId = skinId
        self.jointWorldPositions = jointWorldPositions
        self.heightM = heightM
        self.headHeightM = headHeightM
        self.headCenter = headCenter
        self.headRadii = headRadii
    }

    /// Vertex indices of `region` within one primitive, or empty.
    public func indices(of region: String, mesh: String, primitive: Int = 0) -> [Int] {
        regions[region]?.first { $0.meshId == mesh && $0.primitiveIndex == primitive }?.indices ?? []
    }
}
