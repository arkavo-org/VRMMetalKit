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

import simd

/// Where the opt-in contact shadow sits and how large it is.
///
/// A skinned humanoid is grounded at its feet: the bind-pose bounds span the
/// T-pose arms and stay at the load position while the skeleton moves, so the
/// shadow follows the current foot joints instead. Everything else (props,
/// rigid glTF, skinned models without feet) uses the world bounds of every
/// mesh-bearing node, including nested node transforms.
struct ContactShadowFootprint: Equatable {
    /// Shadow centre; `y` is the ground height.
    var center: SIMD3<Float>
    /// Radius before `RendererConfig.contactShadowScale` is applied.
    var radius: Float

    /// One mesh-bearing node's bounds. Rigid meshes pass their current
    /// `worldMatrix`; skinned meshes pass the placement transform of their
    /// scene root, because glTF ignores a skinned mesh node's own transform.
    struct MeshBox {
        var localMin: SIMD3<Float>
        var localMax: SIMD3<Float>
        var transform: simd_float4x4
    }

    /// World-space union of the mesh boxes, or `nil` when there are none.
    static func worldBounds(of boxes: [MeshBox]) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard !boxes.isEmpty else { return nil }
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for box in boxes {
            let world = AABBTransform.worldAABB(
                localMin: box.localMin,
                localMax: box.localMax,
                modelMatrix: box.transform)
            lo = simd_min(lo, world.min)
            hi = simd_max(hi, world.max)
        }
        return all(hi .>= lo) ? (lo, hi) : nil
    }

    /// Footprint from mesh bounds: the horizontal extent of the union, on its
    /// lowest point.
    static func fromMeshBounds(_ boxes: [MeshBox]) -> ContactShadowFootprint? {
        guard let bounds = worldBounds(of: boxes) else { return nil }
        let size = bounds.max - bounds.min
        let footprint = max(size.x, size.z)
        guard footprint > 0.0001 else { return nil }
        return ContactShadowFootprint(
            center: SIMD3<Float>(
                (bounds.min.x + bounds.max.x) * 0.5,
                bounds.min.y,
                (bounds.min.z + bounds.max.z) * 0.5),
            radius: footprint * 0.5)
    }

    /// Footprint from foot joints: centred between the feet on `groundY`,
    /// sized to the stance plus a margin for the soles. `legLength` (hips to
    /// ground) scales the margin so it tracks the avatar's size.
    static func fromFeet(
        _ feet: [SIMD3<Float>],
        groundY: Float,
        legLength: Float
    ) -> ContactShadowFootprint? {
        guard !feet.isEmpty else { return nil }
        var centerXZ = SIMD2<Float>(0, 0)
        for foot in feet { centerXZ += SIMD2<Float>(foot.x, foot.z) }
        centerXZ /= Float(feet.count)
        var stance: Float = 0
        for foot in feet {
            stance = max(stance, simd_length(SIMD2<Float>(foot.x, foot.z) - centerXZ))
        }
        let margin = max(0.08, 0.12 * max(legLength, 0))
        return ContactShadowFootprint(
            center: SIMD3<Float>(centerXZ.x, groundY, centerXZ.y),
            radius: stance + margin)
    }
}

/// One mesh-bearing node's bind-space bounds and the node whose world matrix
/// places them (the node itself for rigid meshes, its scene root for skinned).
struct ContactShadowMeshEntry {
    var transformNode: Int
    var localMin: SIMD3<Float>
    var localMax: SIMD3<Float>
}
