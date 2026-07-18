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

/// Mesh-aware breast collider sizing (#377). On VRoid rigs the visible breast
/// surface rides FORWARD on the spring-driven `Bust` bones (`J_Sec_*_Bust*`),
/// tens of millimetres beyond the authored chest colliders — which sit back on
/// `UpperChest` (the breast spheres are even offset *behind* the sternum). Hair
/// therefore rests legally on the authored/synthetic chest colliders yet still
/// pierces the forward breast MESH. No collision-response change (swept twins,
/// segment collision) can fix that — only a collider that actually reaches the
/// breast surface.
///
/// This fits a per-side bounding sphere to the *skinned* breast mesh so a
/// synthetic swept collider can hug the breast and follow its spring motion
/// (anchored on the side's `Bust1`). Unlike `SpringBoneColliderAugmentor` /
/// `SpringBoneBoneGeometry` (pure, bone-derived), this reads the skinned vertex
/// buffers, so it must run at load where the device-backed buffers exist.
enum SpringBoneBreastCollider {

    /// A fitted per-side breast sphere. `offset` is the sphere centre expressed
    /// in the anchor node's LOCAL frame, so re-applying the anchor's world
    /// matrix each frame rides the breast's spring motion.
    struct BreastSphere: Equatable {
        let node: Int
        let offset: SIMD3<Float>
        let radius: Float
    }

    /// One fitted breast per `Bust` spring chain: the anchor (side's Bust1), the
    /// world-space centroid of the skinned breast surface, and a radius at the
    /// given percentile of vertex-to-centroid distance.
    private struct BreastFit {
        let anchor: Int
        let centroidWorld: SIMD3<Float>
        let radius: Float
    }

    private static func fitBreasts(model: VRMModel, radiusPercentile: Float) -> [BreastFit] {
        guard let springBone = model.springBone else { return [] }
        var sides: [(anchor: Int, bustNodes: Set<Int>)] = []
        for spring in springBone.springs where (spring.name ?? "").lowercased().contains("bust") {
            let nodeIndices = spring.joints.map { $0.node }
            guard let anchor = nodeIndices.first else { continue }
            sides.append((anchor, Set(nodeIndices)))
        }
        guard !sides.isEmpty, let (meshIndex, skin) = bodyMeshAndSkin(model: model) else { return [] }

        let skinMatrices = skin.joints.indices.map { i in
            skin.joints[i].worldMatrix * skin.inverseBindMatrices[i]
        }
        let sideSlots: [Set<Int>] = sides.map { side in
            Set(skin.joints.indices.filter { side.bustNodes.contains(skin.joints[$0].index) })
        }

        var sideVerts: [[SIMD3<Float>]] = Array(repeating: [], count: sides.count)
        for primitive in model.meshes[meshIndex].primitives {
            guard let vb = primitive.vertexBuffer, primitive.vertexCount > 0 else { continue }
            let ptr = vb.contents().bindMemory(to: VRMVertex.self, capacity: primitive.vertexCount)
            for vi in 0..<primitive.vertexCount {
                let v = ptr[vi]
                let js = [Int(v.joints.x), Int(v.joints.y), Int(v.joints.z), Int(v.joints.w)]
                let ws = [v.weights.x, v.weights.y, v.weights.z, v.weights.w]
                var domSlot = -1
                var domW: Float = 0
                for k in 0..<4 where ws[k] > domW { domW = ws[k]; domSlot = js[k] }
                guard domSlot >= 0, domW > 0.5 else { continue }
                for (s, slots) in sideSlots.enumerated() where slots.contains(domSlot) {
                    sideVerts[s].append(skinVertex(v.position, v.joints, v.weights, skinMatrices))
                    break
                }
            }
        }

        var out: [BreastFit] = []
        for (s, side) in sides.enumerated() {
            let verts = sideVerts[s]
            guard verts.count >= 8, side.anchor >= 0, side.anchor < model.nodes.count else { continue }
            let centroid = verts.reduce(SIMD3<Float>(repeating: 0), +) / Float(verts.count)
            let dists = verts.map { simd_length($0 - centroid) }.sorted()
            let pIdx = min(dists.count - 1, max(0, Int(Float(dists.count - 1) * radiusPercentile)))
            let radius = dists[pIdx]
            guard radius.isFinite, radius > 1e-4 else { continue }
            out.append(BreastFit(anchor: side.anchor, centroidWorld: centroid, radius: radius))
        }
        return out
    }

    /// Per-side breast bounding spheres (the MEASURING stick / mesh proxy).
    static func computeBreastSpheres(model: VRMModel,
                                     radiusPercentile: Float = 0.92) -> [BreastSphere] {
        var out: [BreastSphere] = []
        for fit in fitBreasts(model: model, radiusPercentile: radiusPercentile) {
            let anchorWorld = model.nodes[fit.anchor].worldMatrix
            let local = simd_inverse(anchorWorld) * SIMD4<Float>(fit.centroidWorld, 1)
            guard local.x.isFinite, local.y.isFinite, local.z.isFinite else { continue }
            out.append(BreastSphere(node: fit.anchor,
                                    offset: SIMD3<Float>(local.x, local.y, local.z),
                                    radius: fit.radius))
        }
        return out
    }

    /// Per-side breast COLLIDERS for the swept synthetic group (#377). A sphere at
    /// the breast bulge leaves the superior entry open — hair enters at the
    /// collarbone and slides down BEHIND it into the breast. So each collider is a
    /// CAPSULE spanning from the upperChest (the collarbone-height entry) down to
    /// the breast centroid, radius fitted to enclose the breast surface. Anchored
    /// on the side's Bust1 so it rides the breast's spring motion. Empty when the
    /// rig has no `Bust` spring / body mesh / upperChest bone.
    static func computeBreastColliders(model: VRMModel,
                                       radiusPercentile: Float = 1.0,
                                       radiusScale: Float = 1.0) -> [VRMCollider] {
        guard let humanoid = model.humanoid else { return [] }
        let superiorBone = humanoid.getBoneNode(.upperChest)
            ?? humanoid.getBoneNode(.chest) ?? humanoid.getBoneNode(.spine)
        guard let superiorNode = superiorBone, superiorNode < model.nodes.count else { return [] }
        let superiorWorld = model.nodes[superiorNode].worldPosition

        var out: [VRMCollider] = []
        for fit in fitBreasts(model: model, radiusPercentile: radiusPercentile) {
            let anchorWorld = model.nodes[fit.anchor].worldMatrix
            let invAnchor = simd_inverse(anchorWorld)
            // p0 = breast centroid (inferior-anterior); p1 = a point up toward the
            // collarbone entry (upperChest height, kept at the breast's forward z
            // so the capsule tracks the anterior chest wall, not the spine).
            let p0 = fit.centroidWorld
            let p1 = SIMD3<Float>(fit.centroidWorld.x, superiorWorld.y, fit.centroidWorld.z)
            let o0 = invAnchor * SIMD4<Float>(p0, 1)
            let o1 = invAnchor * SIMD4<Float>(p1, 1)
            let offset = SIMD3<Float>(o0.x, o0.y, o0.z)
            let tail = SIMD3<Float>(o1.x - o0.x, o1.y - o0.y, o1.z - o0.z)
            let radius = fit.radius * radiusScale
            guard offset.x.isFinite, tail.x.isFinite, radius.isFinite, radius > 1e-4 else { continue }
            out.append(VRMCollider(node: fit.anchor, shape: .capsule(offset: offset, radius: radius, tail: tail)))
        }
        return out
    }

    /// The body/skin mesh and its skin. Matches the mesh whose name contains
    /// "body" (VRoid exports the torso/skin/dress under a "Body" mesh) and that
    /// binds a skin.
    private static func bodyMeshAndSkin(model: VRMModel) -> (Int, VRMSkin)? {
        for (mi, mesh) in model.meshes.enumerated() {
            guard (mesh.name ?? "").lowercased().contains("body") else { continue }
            guard let node = model.nodes.first(where: { $0.mesh == mi }),
                  let skinIndex = node.skin, skinIndex >= 0, skinIndex < model.skins.count else { continue }
            return (mi, model.skins[skinIndex])
        }
        return nil
    }

    /// Linear-blend skinning of one vertex to world space (mirrors the GPU path).
    private static func skinVertex(_ position: SIMD3<Float>, _ joints: SIMD4<UInt32>,
                                   _ weights: SIMD4<Float>, _ skinMatrices: [float4x4]) -> SIMD3<Float> {
        let wsum = max(weights.x + weights.y + weights.z + weights.w, 1e-6)
        let w = weights / wsum
        let js = [Int(joints.x), Int(joints.y), Int(joints.z), Int(joints.w)]
        let ws = [w.x, w.y, w.z, w.w]
        var m = float4x4(0)
        for k in 0..<4 where ws[k] > 0 && js[k] >= 0 && js[k] < skinMatrices.count {
            m += skinMatrices[js[k]] * ws[k]
        }
        let p = m * SIMD4<Float>(position, 1)
        return SIMD3<Float>(p.x, p.y, p.z)
    }
}
