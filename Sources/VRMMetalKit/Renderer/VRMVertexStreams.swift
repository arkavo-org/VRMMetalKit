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

import Metal
import simd

/// Position-only vertex used by depth, silhouette, and CPU AABB walks.
///
/// `SIMD3<Float>` is 16 bytes, matching the position field of ``VRMVertex``.
/// Values are not quantized.
public struct VRMPositionVertex {
    public var position: SIMD3<Float> = [0, 0, 0]

    public init(position: SIMD3<Float> = [0, 0, 0]) {
        self.position = position
    }
}

/// Non-position attributes for the main and outline passes.
///
/// Field values match the corresponding ``VRMVertex`` members; only the
/// stream split and padding change.
public struct VRMAttributeVertex {
    public var normal: SIMD3<Float> = [0, 1, 0]
    public var texCoord: SIMD2<Float> = [0, 0]
    public var color: SIMD4<Float> = [1, 1, 1, 1]
    public var joints: SIMD4<UInt32> = [0, 0, 0, 0]
    public var weights: SIMD4<Float> = [1, 0, 0, 0]

    public init(
        normal: SIMD3<Float> = [0, 1, 0],
        texCoord: SIMD2<Float> = [0, 0],
        color: SIMD4<Float> = [1, 1, 1, 1],
        joints: SIMD4<UInt32> = [0, 0, 0, 0],
        weights: SIMD4<Float> = [1, 0, 0, 0]
    ) {
        self.normal = normal
        self.texCoord = texCoord
        self.color = color
        self.joints = joints
        self.weights = weights
    }
}

/// Split / join and per-pass vertex descriptors for leftover #195 (Group 6b).
public enum VRMVertexStreams {
    public static func split(_ vertex: VRMVertex) -> (VRMPositionVertex, VRMAttributeVertex) {
        (
            VRMPositionVertex(position: vertex.position),
            VRMAttributeVertex(
                normal: vertex.normal,
                texCoord: vertex.texCoord,
                color: vertex.color,
                joints: vertex.joints,
                weights: vertex.weights
            )
        )
    }

    public static func split(_ vertices: [VRMVertex]) -> ([VRMPositionVertex], [VRMAttributeVertex]) {
        var positions = [VRMPositionVertex]()
        var attributes = [VRMAttributeVertex]()
        positions.reserveCapacity(vertices.count)
        attributes.reserveCapacity(vertices.count)
        for vertex in vertices {
            let parts = split(vertex)
            positions.append(parts.0)
            attributes.append(parts.1)
        }
        return (positions, attributes)
    }

    public static func join(position: VRMPositionVertex, attributes: VRMAttributeVertex) -> VRMVertex {
        var vertex = VRMVertex()
        vertex.position = position.position
        vertex.normal = attributes.normal
        vertex.texCoord = attributes.texCoord
        vertex.color = attributes.color
        vertex.joints = attributes.joints
        vertex.weights = attributes.weights
        return vertex
    }

    /// Main / outline / skinned color pass: positions in buffer 0, attributes in
    /// ``ResourceIndices/attributeBuffer``.
    public static func applyMainPass(to descriptor: MTLVertexDescriptor, skinned: Bool) {
        let posIdx = ResourceIndices.vertexBuffer
        let attrIdx = ResourceIndices.attributeBuffer

        descriptor.attributes[0].format = .float3
        descriptor.attributes[0].offset = MemoryLayout<VRMPositionVertex>.offset(of: \.position)!
        descriptor.attributes[0].bufferIndex = posIdx

        descriptor.attributes[1].format = .float3
        descriptor.attributes[1].offset = MemoryLayout<VRMAttributeVertex>.offset(of: \.normal)!
        descriptor.attributes[1].bufferIndex = attrIdx

        descriptor.attributes[2].format = .float2
        descriptor.attributes[2].offset = MemoryLayout<VRMAttributeVertex>.offset(of: \.texCoord)!
        descriptor.attributes[2].bufferIndex = attrIdx

        descriptor.attributes[3].format = .float4
        descriptor.attributes[3].offset = MemoryLayout<VRMAttributeVertex>.offset(of: \.color)!
        descriptor.attributes[3].bufferIndex = attrIdx

        if skinned {
            descriptor.attributes[4].format = .uint4
            descriptor.attributes[4].offset = MemoryLayout<VRMAttributeVertex>.offset(of: \.joints)!
            descriptor.attributes[4].bufferIndex = attrIdx

            descriptor.attributes[5].format = .float4
            descriptor.attributes[5].offset = MemoryLayout<VRMAttributeVertex>.offset(of: \.weights)!
            descriptor.attributes[5].bufferIndex = attrIdx
        }

        descriptor.layouts[posIdx].stride = MemoryLayout<VRMPositionVertex>.stride
        descriptor.layouts[attrIdx].stride = MemoryLayout<VRMAttributeVertex>.stride
    }

    /// Depth prepass: positions always; joints/weights only when skinned.
    public static func applyDepth(to descriptor: MTLVertexDescriptor, skinned: Bool) {
        let posIdx = ResourceIndices.vertexBuffer
        descriptor.attributes[0].format = .float3
        descriptor.attributes[0].offset = MemoryLayout<VRMPositionVertex>.offset(of: \.position)!
        descriptor.attributes[0].bufferIndex = posIdx
        descriptor.layouts[posIdx].stride = MemoryLayout<VRMPositionVertex>.stride

        guard skinned else { return }
        let attrIdx = ResourceIndices.attributeBuffer
        descriptor.attributes[4].format = .uint4
        descriptor.attributes[4].offset = MemoryLayout<VRMAttributeVertex>.offset(of: \.joints)!
        descriptor.attributes[4].bufferIndex = attrIdx
        descriptor.attributes[5].format = .float4
        descriptor.attributes[5].offset = MemoryLayout<VRMAttributeVertex>.offset(of: \.weights)!
        descriptor.attributes[5].bufferIndex = attrIdx
        descriptor.layouts[attrIdx].stride = MemoryLayout<VRMAttributeVertex>.stride
    }
}
