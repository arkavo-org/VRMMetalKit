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

/// Compiles hair, outfit and accessory items against a `WearableHost` into
/// the meshes, nodes, skins, springs and colliders the integrator merges into
/// a `CompiledAvatar`. Deterministic: items are processed in id order, clump
/// layout is a pack constant, and every collection in the output is id-sorted.
public enum WearableCompiler {
    public static let hairMaterialFallbackId = "material:hair"
    public static let garmentMaterialFallbackId = "material:cloth"
    public static let accessoryMaterialFallbackId = "material:accessory"

    public static func compile(host: WearableHost, hair: [HairItem], outfits: [OutfitItem], accessories: [AccessoryItem],
                               materialsById: [String: MaterialRole]) throws -> WearableOutput {
        var out = WearableOutput(permittedLayers: OutfitPresets.permittedLayers)
        try OutfitPresets.checkLayerCombination(outfits)

        let hairItems = CompiledAvatar.sortedById(hair, \.id)
        if !hairItems.isEmpty {
            let hairMaterial = materialsById.keys.sorted(by: CompiledAvatar.precedes).first { materialsById[$0] == .hair }
            if hairMaterial == nil {
                out.warnings.append(AuthorWarning(code: "MATERIAL_ROLE_MISSING", message: "No material with role 'hair'; hair meshes reference '\(hairMaterialFallbackId)'.",
                                                  path: "/materials"))
            }
            let (colliders, groups) = try HairBobV1.colliders(host: host)
            out.colliders = colliders
            out.colliderGroups = groups
            for item in hairItems {
                try item.validate()
                let build = try HairBobV1.build(item: item, host: host, materialId: hairMaterial ?? hairMaterialFallbackId, colliderGroupIds: groups.map(\.id))
                out.meshes.append(build.mesh)
                out.nodes.append(build.meshNode)
                out.nodes += build.nodes
                out.skins.append(build.skin)
                out.meshInstances.append(build.meshInstance)
                out.springs += build.springs
                out.hairClumps += build.clumps
                out.warnings += build.warnings
            }
        }

        let regionOfVertex = regionMap(host: host)
        for item in CompiledAvatar.sortedById(outfits.filter(\.enabled), \.id) {
            try item.validate()
            let materialId = try resolveMaterial(item.materialIds, objectId: "garment:\(item.id)", fallback: garmentMaterialFallbackId, materialsById: materialsById, warnings: &out.warnings)
            let build = try OutfitPresets.build(item: item, host: host, materialId: materialId, regionOfVertex: regionOfVertex)
            out.meshes.append(build.mesh)
            out.nodes.append(build.meshNode)
            out.meshInstances.append(build.meshInstance)
            out.garments.append(build.info)
            out.hiddenRegions += build.info.hiddenRegions
            out.warnings += build.warnings
        }

        for item in CompiledAvatar.sortedById(accessories.filter(\.enabled), \.id) {
            try item.validate()
            var ids = item.materialIds
            let first = try resolveMaterial(ids, objectId: "accessory:\(item.id)", fallback: accessoryMaterialFallbackId, materialsById: materialsById, warnings: &out.warnings)
            if ids.isEmpty { ids = [first] }
            let build = try AccessoryPresets.build(item: item, host: host, materialIds: ids)
            out.meshes.append(build.mesh)
            out.nodes.append(build.meshNode)
            out.skins.append(build.skin)
            out.meshInstances.append(build.meshInstance)
            out.warnings += build.warnings
        }

        try WearableValidation.validateSprings(out.springs, nodes: out.nodes)
        for mesh in out.meshes { try WearableValidation.validateMesh(mesh) }
        return out.sorted()
    }

    static func resolveMaterial(_ ids: [String], objectId: String, fallback: String, materialsById: [String: MaterialRole], warnings: inout [AuthorWarning]) throws -> String {
        guard let first = ids.first else {
            warnings.append(AuthorWarning(code: "MATERIAL_MISSING", message: "'\(objectId)' declares no materialIds; using '\(fallback)'.", path: "/materialIds"))
            return fallback
        }
        if materialsById[first] == nil {
            warnings.append(AuthorWarning(code: "MATERIAL_UNKNOWN", message: "'\(objectId)' references material '\(first)', which is not in the recipe.", path: "/materialIds/0"))
        }
        return first
    }

    static func regionMap(host: WearableHost) -> [Int: String] {
        var map: [Int: String] = [:]
        for name in WearableRegion.all {
            for i in host.region(name) where map[i] == nil { map[i] = name }
        }
        return map
    }
}
