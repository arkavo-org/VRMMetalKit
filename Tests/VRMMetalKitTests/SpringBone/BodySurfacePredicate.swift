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
@testable import VRMMetalKit

/// Which primitives constitute the body surface a simulated garment should be
/// pushed OUT of.
///
/// Excludes CLOTH categorically, not by per-material judgement: CLOTH is
/// simulated garment surface (skirts, sleeves, tops, hair accessories), and a
/// garment whose own joints are driven by spring bones would report those
/// joints as permanently inside it — the nearest triangle to a buried joint
/// would be the garment's own surface, at distance ≈0, so the region reported
/// would be the garment's own body-region tag rather than whatever it is
/// actually penetrating. This holds even for a CLOTH primitive that happens
/// not to be simulated (e.g. shoes): the exclusion is a property of the
/// method, not a fact checked per material. CLOTH is also frequently a thin
/// double-sided shell, on which nearest-triangle-normal classification is
/// undefined. Must also exclude hair for the same reason. Scoped over
/// materials across every mesh, never by mesh name — name-matching drops the
/// Face mesh's SKIN primitives.
enum BodySurfacePredicate {

    static func includes(materialName: String?) -> Bool {
        guard let raw = materialName?.uppercased() else { return false }
        if raw.contains("HAIR") { return false }
        return raw.contains("SKIN")
    }

    static func inventory(model: VRMModel) -> [BodySurfaceInventory] {
        var out: [BodySurfaceInventory] = []
        for (mi, mesh) in model.meshes.enumerated() {
            for (pi, primitive) in mesh.primitives.enumerated() {
                guard let materialIndex = primitive.materialIndex,
                      materialIndex < model.materials.count else { continue }
                let name = model.materials[materialIndex].name ?? ""
                guard includes(materialName: name) else { continue }
                out.append(BodySurfaceInventory(
                    meshIndex: mi,
                    primitiveIndex: pi,
                    materialName: name,
                    vertexCount: primitive.vertexCount,
                    boundaryEdgeCount: boundaryEdgeCount(of: primitive),
                    isTriangleTopology: primitive.primitiveType == .triangle))
            }
        }
        return out
    }

    /// Edges used by exactly one triangle. A SKIN-only surface is open — eye
    /// sockets, and geometry deleted under garments — and signed classification
    /// is one-sided near an opening, so the count is recorded rather than
    /// discovered later as a mystery sign flip.
    static func boundaryEdgeCount(of primitive: VRMPrimitive) -> Int {
        guard primitive.primitiveType == .triangle,
              let indices = readIndices(primitive) else { return 0 }
        var counts: [UInt64: Int] = [:]
        var i = 0
        while i + 2 < indices.count {
            let tri = [indices[i], indices[i + 1], indices[i + 2]]
            for k in 0..<3 {
                let a = UInt64(min(tri[k], tri[(k + 1) % 3]))
                let b = UInt64(max(tri[k], tri[(k + 1) % 3]))
                counts[(a << 32) | b, default: 0] += 1
            }
            i += 3
        }
        return counts.values.filter { $0 == 1 }.count
    }

    static func readIndices(_ primitive: VRMPrimitive) -> [UInt32]? {
        guard let buffer = primitive.indexBuffer, primitive.indexCount > 0 else { return nil }
        let base = buffer.contents().advanced(by: primitive.indexBufferOffset)
        if primitive.indexType == .uint32 {
            let p = base.bindMemory(to: UInt32.self, capacity: primitive.indexCount)
            return (0..<primitive.indexCount).map { p[$0] }
        }
        let p = base.bindMemory(to: UInt16.self, capacity: primitive.indexCount)
        return (0..<primitive.indexCount).map { UInt32(p[$0]) }
    }
}

struct BodySurfaceInventory {
    let meshIndex: Int
    let primitiveIndex: Int
    let materialName: String
    let vertexCount: Int
    let boundaryEdgeCount: Int
    let isTriangleTopology: Bool
}
