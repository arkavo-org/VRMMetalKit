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
import Metal
import simd

/// One joint's measured collision extent, spec §3.
public struct JointRadiusMeasurement {
    public let springIndex: Int
    public let jointIndex: Int
    public let node: Int
    public let authored: Float
    /// Raw measured half-extent (pre-ceiling), nil when nothing was measurable
    /// anywhere up-chain.
    public let measured: Float?
    /// Vertices dominantly skinned to this joint's node. Below 8, the value is
    /// inherited from the nearest computed ancestor (spec §3) — recorded so
    /// sparse skinning is loud, not inferred.
    public let dominantVertexCount: Int
    public let ceiling: Float
    public let effective: Float
}

/// Measures each spring joint's collision half-extent from the mesh actually
/// skinned to it — the cloth's own geometry (hair cards, skirt panels), NOT the
/// body surface. `hitRadius` is a geometric proxy; VRoid routinely authors it
/// near zero (median 3.7 mm on AvatarSample_M's hair, some joints 0) for cards
/// centimetres wide. The effective value floors the proxy at the measured
/// extent without ever mutating the authored field (spec §2/§3).
public enum SpringBoneJointRadiusMeasure {

    public static func measure(model: VRMModel, percentile: Float = 0.65) -> [JointRadiusMeasurement] {
        guard let springBone = model.springBone else { return [] }

        // One pass over every skinned primitive: bucket world-space positions
        // of dominantly-skinned vertices by node index. All meshes participate —
        // hair and garment materials included; this measures the cloth itself.
        var vertsByNode: [Int: [SIMD3<Float>]] = [:]
        for (mi, mesh) in model.meshes.enumerated() {
            guard let node = model.nodes.first(where: { $0.mesh == mi }),
                  let skinIndex = node.skin, skinIndex >= 0, skinIndex < model.skins.count else { continue }
            let skin = model.skins[skinIndex]
            let palette = skin.joints.indices.map { skin.joints[$0].worldMatrix * skin.inverseBindMatrices[$0] }
            let slotToNode: [Int] = skin.joints.map { j in
                model.nodes.firstIndex(where: { $0 === j }) ?? -1
            }
            for primitive in mesh.primitives {
                guard let vb = primitive.vertexBuffer, primitive.vertexCount > 0 else { continue }
                let verts = vb.contents().bindMemory(to: VRMVertex.self, capacity: primitive.vertexCount)
                for vi in 0..<primitive.vertexCount {
                    let v = verts[vi]
                    let js = [Int(v.joints.x), Int(v.joints.y), Int(v.joints.z), Int(v.joints.w)]
                    let ws = [v.weights.x, v.weights.y, v.weights.z, v.weights.w]
                    var dom = -1; var domW: Float = 0
                    for k in 0..<4 where ws[k] > domW { domW = ws[k]; dom = js[k] }
                    guard domW > 0.5, dom >= 0, dom < palette.count else { continue }
                    let nodeIndex = slotToNode[dom]
                    guard nodeIndex >= 0 else { continue }
                    let h = palette[dom] * SIMD4<Float>(v.position, 1)
                    vertsByNode[nodeIndex, default: []].append(SIMD3<Float>(h.x, h.y, h.z))
                }
            }
        }

        var out: [JointRadiusMeasurement] = []
        for (si, spring) in springBone.springs.enumerated() {
            // Root→leaf: inheritance flows only from computed ancestors (spec §3).
            var lastMeasured: Float? = nil
            for (ji, joint) in spring.joints.enumerated() {
                guard joint.node >= 0, joint.node < model.nodes.count else { continue }
                let selfPos = model.nodes[joint.node].worldPosition
                // Axis: parent→self for chain joints; self→first-child for the
                // anchor (roots are measured too — their value feeds the first
                // span's segment radius, spec §3/§4).
                let otherPos: SIMD3<Float>
                if ji > 0 {
                    otherPos = model.nodes[spring.joints[ji - 1].node].worldPosition
                } else if spring.joints.count > 1 {
                    otherPos = model.nodes[spring.joints[1].node].worldPosition
                } else {
                    otherPos = selfPos
                }
                let segLen = simd_length(selfPos - otherPos)
                let ceiling = min(0.05, 0.75 * segLen)

                let verts = vertsByNode[joint.node] ?? []
                var measuredRaw: Float? = nil
                if verts.count >= 8, segLen > 1e-5 {
                    let a = ji > 0 ? otherPos : selfPos
                    let b = ji > 0 ? selfPos : otherPos
                    let axis = simd_normalize(b - a)
                    var perps: [Float] = []
                    perps.reserveCapacity(verts.count)
                    for p in verts {
                        let d = p - a
                        let t = simd_dot(d, axis)
                        guard t >= 0, t <= segLen else { continue }
                        perps.append(simd_length(d - t * axis))
                    }
                    if perps.count >= 8 {
                        perps.sort()
                        let idx = min(perps.count - 1, max(0, Int(Float(perps.count - 1) * percentile)))
                        measuredRaw = perps[idx]
                    }
                }
                if measuredRaw != nil { lastMeasured = measuredRaw }
                let inherited = measuredRaw ?? lastMeasured
                let effective = max(joint.hitRadius, min(inherited ?? joint.hitRadius, ceiling))
                out.append(JointRadiusMeasurement(
                    springIndex: si, jointIndex: ji, node: joint.node,
                    authored: joint.hitRadius, measured: inherited,
                    dominantVertexCount: verts.count,
                    ceiling: ceiling, effective: effective))
            }
        }
        return out
    }
}
