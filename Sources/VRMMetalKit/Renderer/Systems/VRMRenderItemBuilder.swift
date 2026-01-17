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

struct RenderItem {
    let node: VRMNode
    let mesh: VRMMesh
    let primitive: VRMPrimitive
    let alphaMode: String
    let materialName: String
    let meshIndex: Int
    var effectiveAlphaMode: String
    var effectiveDoubleSided: Bool
    var effectiveAlphaCutoff: Float
    var faceCategory: String?
    let materialNameLower: String
    let nodeNameLower: String
    let meshNameLower: String
    let isFaceMaterial: Bool
    let isEyeMaterial: Bool
    var renderOrder: Int
    // VRM material renderQueue for secondary sorting (Unity renderQueue values)
    // Default 2000 (geometry), transparent materials typically 3000+
    let materialRenderQueue: Int
}

final class VRMRenderItemBuilder {
    struct Result {
        let items: [RenderItem]
        let totalMeshesWithNodes: Int
    }

    private var cachedRenderItems: [RenderItem]?
    private var cachedTotalMeshes: Int = 0
    private var cacheInvalidated = true

    func invalidateCache() {
        cacheInvalidated = true
    }

    func buildItems(model: VRMModel, frameCounter: Int) -> Result {
        if let cached = cachedRenderItems, !cacheInvalidated {
            if frameCounter % 300 == 0 {
                vrmLog("[RenderItemBuilder] Using cached render items (")
            }
            return Result(items: cached, totalMeshesWithNodes: cachedTotalMeshes)
        }

        if frameCounter % 60 == 0 {
            vrmLog("[RenderItemBuilder] Rebuilding render items...")
        }

        var totalMeshes = 0
        let estimatedPrimCount = model.meshes.reduce(0) { $0 + $1.primitives.count }
        var allItems: [RenderItem] = []
        allItems.reserveCapacity(estimatedPrimCount)

        var opaqueCount = 0
        var maskCount = 0
        var blendCount = 0
        var faceSkinCount = 0
        var faceEyebrowCount = 0
        var faceEyelineCount = 0
        var faceEyeCount = 0
        var faceHighlightCount = 0

        for (nodeIndex, node) in model.nodes.enumerated() {
            if frameCounter <= 2 {
                vrmLog("[NODE SCAN] Node \(nodeIndex) '\(node.name ?? "unnamed")': mesh=\(node.mesh ?? -1)")
            }

            guard let meshIndex = node.mesh,
                  meshIndex < model.meshes.count else {
                continue
            }

            let mesh = model.meshes[meshIndex]
            if frameCounter <= 2 {
                vrmLog("[DRAW LIST] Node[\(nodeIndex)] '\(node.name ?? "?")' → mesh[\(meshIndex)] '\(mesh.name ?? "?")' skin=\(node.skin ?? -1)")
            }
            totalMeshes += 1

            for primitive in mesh.primitives {
                let alpha = primitive.materialIndex.flatMap { idx in idx < model.materials.count ? model.materials[idx].alphaMode : nil }?.lowercased() ?? "opaque"
                let materialName = (primitive.materialIndex.flatMap { idx in idx < model.materials.count ? model.materials[idx].name : nil }) ?? "unnamed"

                let nodeName = node.name ?? "unnamed"
                let meshName = mesh.name ?? "unnamed_mesh"
                let materialLower = materialName.lowercased()
                let nodeLower = nodeName.lowercased()
                let meshLower = meshName.lowercased()

                let nodeIsFace = nodeLower.contains("face") || nodeLower.contains("eye")
                let meshIsFace = meshLower.contains("face") || meshLower.contains("eye")
                let materialIsFace = materialLower.contains("face") || materialLower.contains("eye")

                if nodeIsFace || meshIsFace || materialIsFace {
                    logFaceCandidate(nodeName: nodeName, meshName: meshName, materialName: materialName, alpha: alpha, primitive: primitive)
                }

                var faceCategory: String?
                var renderOrder = 0

                if materialLower.contains("face_skin") || materialLower.contains("facebase") {
                    faceCategory = "skin"
                    renderOrder = 1
                    faceSkinCount += 1
                } else if materialLower.contains("eyebrow") || materialLower.contains("brow") {
                    faceCategory = "eyebrow"
                    renderOrder = 2
                    faceEyebrowCount += 1
                } else if materialLower.contains("eyeline") || materialLower.contains("eyeliner") {
                    faceCategory = "eyeline"
                    renderOrder = 3
                    faceEyelineCount += 1
                } else if materialLower.contains("highlight") || materialLower.contains("catchlight") {
                    faceCategory = "highlight"
                    renderOrder = 6
                    faceHighlightCount += 1
                } else if materialLower.contains("eye") {
                    faceCategory = "eye"
                    renderOrder = 5
                    faceEyeCount += 1
                } else {
                    switch alpha {
                    case "opaque":
                        renderOrder = 0
                        opaqueCount += 1
                    case "mask":
                        renderOrder = 4
                        maskCount += 1
                    case "blend":
                        renderOrder = 7
                        blendCount += 1
                    default:
                        renderOrder = 7
                        blendCount += 1
                    }
                }

                var effectiveDoubleSided = primitive.materialIndex.flatMap { idx in idx < model.materials.count ? model.materials[idx].doubleSided : nil } ?? false
                if faceCategory != nil {
                    effectiveDoubleSided = true
                }

                var effectiveAlphaMode = alpha
                var effectiveAlphaCutoff = primitive.materialIndex.flatMap { idx in idx < model.materials.count ? model.materials[idx].alphaCutoff : nil } ?? 0.5
                if effectiveAlphaMode == "opaque" && faceCategory == "eyebrow" {
                    vrmLog("[FACE FIX] Forcing eyebrow material '\(materialName)' to MASK mode")
                    effectiveAlphaMode = "mask"
                    effectiveAlphaCutoff = 0.35
                }
                if faceCategory == "highlight" {
                    effectiveAlphaMode = "blend"
                }

                let isFaceMaterial = faceCategory != nil
                let isEyeMaterial = faceCategory == "eye" || faceCategory == "highlight"

                // Get renderQueue from VRM material (for sorting face/transparent materials)
                let materialRenderQueue = primitive.materialIndex.flatMap { idx in
                    idx < model.materials.count ? model.materials[idx].renderQueue : 2000
                } ?? 2000

                let item = RenderItem(
                    node: node,
                    mesh: mesh,
                    primitive: primitive,
                    alphaMode: alpha,
                    materialName: materialName,
                    meshIndex: meshIndex,
                    effectiveAlphaMode: effectiveAlphaMode,
                    effectiveDoubleSided: effectiveDoubleSided,
                    effectiveAlphaCutoff: effectiveAlphaCutoff,
                    faceCategory: faceCategory,
                    materialNameLower: materialLower,
                    nodeNameLower: nodeLower,
                    meshNameLower: meshLower,
                    isFaceMaterial: isFaceMaterial,
                    isEyeMaterial: isEyeMaterial,
                    renderOrder: renderOrder,
                    materialRenderQueue: materialRenderQueue
                )

                allItems.append(item)
            }
        }

        // Sort by renderOrder first, then by materialRenderQueue for items with the same renderOrder
        allItems.sort { a, b in
            if a.renderOrder != b.renderOrder {
                return a.renderOrder < b.renderOrder
            }
            // Secondary sort by VRM materialRenderQueue (fixes z-fighting for eyebrows/eyelashes)
            return a.materialRenderQueue < b.materialRenderQueue
        }

        if frameCounter % 60 == 0 {
            vrmLog("[RenderItemBuilder] Sorted render items: opaque=\(opaqueCount) mask=\(maskCount) blend=\(blendCount) faceSkin=\(faceSkinCount)")
        }

        cachedRenderItems = allItems
        cachedTotalMeshes = totalMeshes
        cacheInvalidated = false

        return Result(items: allItems, totalMeshesWithNodes: totalMeshes)
    }

    private func logFaceCandidate(nodeName: String, meshName: String, materialName: String, alpha: String, primitive: VRMPrimitive) {
        vrmLog("[FACE MATERIAL DEBUG] Potential face material detected:")
        vrmLog("  - Node: '\(nodeName)'")
        vrmLog("  - Mesh: '\(meshName)'")
        vrmLog("  - Material: '\(materialName)'")
        vrmLog("  - Alpha mode: \(alpha)")
        vrmLog("  - IndexCount: \(primitive.indexCount)")
    }
}
