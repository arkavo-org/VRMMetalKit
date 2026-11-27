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
import Metal
import simd

// MARK: - Composable 2-Bit Vertex Body Masking

extension VRMModel {
    /// Registers or replaces a named body-mask layer that hides skinned host vertices
    /// driven by any of `bones` whose summed influence meets `weightThreshold`.
    ///
    /// Body masks occupy bit 1 (`0x02`) of each skinned primitive's per-vertex hidden-flag
    /// buffer (`buffer(26)`), leaving bit 0 (`0x01`, first-person head culling) untouched.
    /// Multiple named layers compose via bitwise OR so overlapping garments (e.g. shirt +
    /// jacket) hide their union cleanly and removing one leaves the other intact.
    ///
    /// For pixel-exact cutouts along necklines or sleeves without partial-triangle spikes,
    /// prefer `VRMTextureLayerStack` with `.eraseAlpha` over a `MASK` body material.
    public func setBodyMask(
        id: String,
        bones: Set<VRMHumanoidBone>,
        weightThreshold: Float = 0.25,
        meshFilter: ((VRMMesh, Int) -> Bool)? = nil
    ) {
        withLock {
            setBodyMaskLocked(
                id: id,
                bones: bones,
                weightThreshold: weightThreshold,
                meshFilter: meshFilter
            )
        }
    }

    /// Registers or replaces a named body-mask layer that hides an explicit set of
    /// vertex indices on a specific host mesh primitive.
    public func setBodyMask(
        id: String,
        hiddenVertices: Set<Int>,
        meshIndex: Int,
        primitiveIndex: Int
    ) {
        withLock {
            guard meshIndex >= 0 && meshIndex < meshes.count else { return }
            let mesh = meshes[meshIndex]
            guard primitiveIndex >= 0 && primitiveIndex < mesh.primitives.count else { return }
            let primitive = mesh.primitives[primitiveIndex]
            guard primitive.vertexCount > 0 else { return }

            let previouslyAffected: Set<ObjectIdentifier> = bodyMaskLayers[id].map { Set($0.keys) } ?? []
            var layer: [ObjectIdentifier: [UInt8]] = [:]
            if !hiddenVertices.isEmpty {
                var flags = [UInt8](repeating: 0, count: primitive.vertexCount)
                for idx in hiddenVertices where idx >= 0 && idx < primitive.vertexCount {
                    flags[idx] = 1
                }
                layer[ObjectIdentifier(primitive)] = flags
            }
            if layer.isEmpty {
                bodyMaskLayers.removeValue(forKey: id)
            } else {
                bodyMaskLayers[id] = layer
            }

            let affected = previouslyAffected.union(layer.keys)
            rebuildBodyMaskBuffersLocked(affectedPrimitives: affected)
            bumpVisibilityRevisionLocked()
        }
    }

    /// Removes a previously registered body-mask layer by identifier, restoring any
    /// vertices not still hidden by other active layers while preserving bit 0
    /// (first-person culling).
    public func removeBodyMask(id: String) {
        withLock {
            removeBodyMaskLocked(id: id)
        }
    }

    // MARK: - Internal Locked Helpers

    internal func setBodyMaskLocked(
        id: String,
        bones: Set<VRMHumanoidBone>,
        weightThreshold: Float = 0.25,
        meshFilter: ((VRMMesh, Int) -> Bool)? = nil
    ) {
        let previouslyAffected: Set<ObjectIdentifier> = bodyMaskLayers[id].map { Set($0.keys) } ?? []

        guard !bones.isEmpty, let humanoid else {
            bodyMaskLayers.removeValue(forKey: id)
            if !previouslyAffected.isEmpty {
                rebuildBodyMaskBuffersLocked(affectedPrimitives: previouslyAffected)
                bumpVisibilityRevisionLocked()
            }
            return
        }

        let targetNodeIndices = Set(bones.compactMap { humanoid.getBoneNode($0) })
        guard !targetNodeIndices.isEmpty else {
            bodyMaskLayers.removeValue(forKey: id)
            if !previouslyAffected.isEmpty {
                rebuildBodyMaskBuffersLocked(affectedPrimitives: previouslyAffected)
                bumpVisibilityRevisionLocked()
            }
            return
        }

        var layer: [ObjectIdentifier: [UInt8]] = [:]

        for node in nodes {
            guard let meshIndex = node.mesh, meshIndex >= 0, meshIndex < meshes.count,
                  let skinIndex = node.skin, skinIndex >= 0, skinIndex < skins.count else {
                continue
            }
            let mesh = meshes[meshIndex]
            if let meshFilter, !meshFilter(mesh, meshIndex) {
                continue
            }

            let skin = skins[skinIndex]
            var targetJointIndices = Set<UInt32>()
            for (jointIdx, jointNode) in skin.joints.enumerated() {
                if targetNodeIndices.contains(jointNode.index) {
                    targetJointIndices.insert(UInt32(jointIdx))
                }
            }
            guard !targetJointIndices.isEmpty else { continue }

            for primitive in mesh.primitives {
                guard primitive.hasJoints && primitive.hasWeights,
                      primitive.vertexCount > 0,
                      let sourceBuffer = primitive.attributeBuffer ?? primitive.vertexBuffer else {
                    continue
                }

                let primID = ObjectIdentifier(primitive)
                var flags = layer[primID] ?? [UInt8](repeating: 0, count: primitive.vertexCount)
                var anyHidden = false

                if primitive.attributeBuffer != nil {
                    let attrs = sourceBuffer.contents().bindMemory(
                        to: VRMAttributeVertex.self,
                        capacity: primitive.vertexCount
                    )
                    for i in 0..<primitive.vertexCount {
                        let j = attrs[i].joints
                        let w = attrs[i].weights
                        var totalWeight: Float = 0
                        if targetJointIndices.contains(j.x) { totalWeight += w.x }
                        if targetJointIndices.contains(j.y) { totalWeight += w.y }
                        if targetJointIndices.contains(j.z) { totalWeight += w.z }
                        if targetJointIndices.contains(j.w) { totalWeight += w.w }
                        if totalWeight >= weightThreshold {
                            flags[i] = 1
                            anyHidden = true
                        }
                    }
                } else {
                    let verts = sourceBuffer.contents().bindMemory(
                        to: VRMVertex.self,
                        capacity: primitive.vertexCount
                    )
                    for i in 0..<primitive.vertexCount {
                        let j = verts[i].joints
                        let w = verts[i].weights
                        var totalWeight: Float = 0
                        if targetJointIndices.contains(j.x) { totalWeight += w.x }
                        if targetJointIndices.contains(j.y) { totalWeight += w.y }
                        if targetJointIndices.contains(j.z) { totalWeight += w.z }
                        if targetJointIndices.contains(j.w) { totalWeight += w.w }
                        if totalWeight >= weightThreshold {
                            flags[i] = 1
                            anyHidden = true
                        }
                    }
                }

                if anyHidden {
                    layer[primID] = flags
                }
            }
        }

        if layer.isEmpty {
            bodyMaskLayers.removeValue(forKey: id)
        } else {
            bodyMaskLayers[id] = layer
        }

        let affected = previouslyAffected.union(layer.keys)
        if !affected.isEmpty {
            rebuildBodyMaskBuffersLocked(affectedPrimitives: affected)
            bumpVisibilityRevisionLocked()
        }
    }

    internal func removeBodyMaskLocked(id: String) {
        guard let removed = bodyMaskLayers.removeValue(forKey: id) else { return }
        let affected = Set(removed.keys)
        if !affected.isEmpty {
            rebuildBodyMaskBuffersLocked(affectedPrimitives: affected)
            bumpVisibilityRevisionLocked()
        }
    }

    private func rebuildBodyMaskBuffersLocked(affectedPrimitives: Set<ObjectIdentifier>) {
        guard !affectedPrimitives.isEmpty else { return }

        for mesh in meshes {
            for primitive in mesh.primitives {
                let primID = ObjectIdentifier(primitive)
                guard affectedPrimitives.contains(primID), primitive.vertexCount > 0 else { continue }

                var combined: [UInt8]
                if primitive.firstPersonHiddenFlags.count == primitive.vertexCount {
                    // Preserve bit 0 (first-person head culling), clear bit 1 before recomputing.
                    combined = primitive.firstPersonHiddenFlags.map { $0 & 0x01 }
                } else {
                    combined = [UInt8](repeating: 0, count: primitive.vertexCount)
                }

                for (_, layer) in bodyMaskLayers {
                    guard let mask = layer[primID] else { continue }
                    let count = min(combined.count, mask.count)
                    for i in 0..<count where mask[i] != 0 {
                        combined[i] |= 0x02
                    }
                }

                primitive.firstPersonHiddenFlags = combined
                if let device {
                    // Allocates a fresh MTLBuffer so in-flight GPU frames never see torn writes.
                    primitive.uploadFirstPersonHiddenFlagsBuffer(device: device)
                }
            }
        }
    }
}
