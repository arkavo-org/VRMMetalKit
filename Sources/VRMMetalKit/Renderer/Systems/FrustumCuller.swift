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

import simd

/// Six view-frustum planes extracted from a view-projection matrix, used by ``cullsAABB(min:max:)`` for trivial reject tests.
///
/// ## Discussion
/// Planes are stored as `(nx, ny, nz, d)` with the inward-facing convention:
/// a point `p` is inside when `dot(plane.xyz, p) + plane.w >= 0`. Built from a
/// `simd_float4x4` view-projection matrix using the standard Gribb/Hartmann
/// extraction. The near plane assumes Metal NDC z in `[0, 1]`.
public struct Frustum {
    /// Left clip plane.
    public var left: SIMD4<Float>
    /// Right clip plane.
    public var right: SIMD4<Float>
    /// Bottom clip plane.
    public var bottom: SIMD4<Float>
    /// Top clip plane.
    public var top: SIMD4<Float>
    /// Near clip plane (Metal NDC z = 0).
    public var near: SIMD4<Float>
    /// Far clip plane (Metal NDC z = 1).
    public var far: SIMD4<Float>

    /// Extracts the six planes from a view-projection matrix using the Gribb/Hartmann method.
    /// - Parameter vp: Column-major view-projection matrix.
    public init(viewProjection vp: matrix_float4x4) {
        // simd_float4x4 columns: vp.columns.0 = column 0, etc.
        // Row i = (col0[i], col1[i], col2[i], col3[i]).
        let r0 = SIMD4<Float>(vp.columns.0.x, vp.columns.1.x, vp.columns.2.x, vp.columns.3.x)
        let r1 = SIMD4<Float>(vp.columns.0.y, vp.columns.1.y, vp.columns.2.y, vp.columns.3.y)
        let r2 = SIMD4<Float>(vp.columns.0.z, vp.columns.1.z, vp.columns.2.z, vp.columns.3.z)
        let r3 = SIMD4<Float>(vp.columns.0.w, vp.columns.1.w, vp.columns.2.w, vp.columns.3.w)

        // Inward-facing planes (point is inside when plane.dot(p,1) >= 0)
        left   = Frustum.normalize(r3 + r0)
        right  = Frustum.normalize(r3 - r0)
        bottom = Frustum.normalize(r3 + r1)
        top    = Frustum.normalize(r3 - r1)
        // Metal NDC z is [0, 1]. Near plane: z >= 0 → r2 >= 0.
        near   = Frustum.normalize(r2)
        far    = Frustum.normalize(r3 - r2)
    }

    private static func normalize(_ p: SIMD4<Float>) -> SIMD4<Float> {
        let len = simd_length(SIMD3<Float>(p.x, p.y, p.z))
        return len > 0 ? p / len : p
    }

    /// Returns `true` if the world-space AABB is entirely outside the frustum (trivial-reject test).
    ///
    /// Uses the positive-vertex optimisation: for each plane, only the corner
    /// farthest in the inward-normal direction is tested. If that corner is
    /// on the negative side of any plane, the whole box is outside.
    ///
    /// - Parameters:
    ///   - lo: World-space AABB minimum corner.
    ///   - hi: World-space AABB maximum corner.
    public func cullsAABB(min lo: SIMD3<Float>, max hi: SIMD3<Float>) -> Bool {
        return cullsByPlane(left, lo, hi)
            || cullsByPlane(right, lo, hi)
            || cullsByPlane(bottom, lo, hi)
            || cullsByPlane(top, lo, hi)
            || cullsByPlane(near, lo, hi)
            || cullsByPlane(far, lo, hi)
    }

    @inline(__always)
    private func cullsByPlane(_ plane: SIMD4<Float>, _ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> Bool {
        let p = SIMD3<Float>(
            plane.x >= 0 ? hi.x : lo.x,
            plane.y >= 0 ? hi.y : lo.y,
            plane.z >= 0 ? hi.z : lo.z)
        return simd_dot(SIMD3<Float>(plane.x, plane.y, plane.z), p) + plane.w < 0
    }
}

/// Culling support for skinned primitives, whose vertices are posed by the
/// joint palette rather than the mesh node's `worldMatrix`.
public enum SkinnedCullBounds {
    /// Model matrix that positions a model's rest-pose bounds for a skinned
    /// frustum test: a pure translation by the hips joint's displacement from
    /// its rest-pose world position.
    ///
    /// Skinned vertices follow the joint palette, so the mesh node's
    /// `worldMatrix` says nothing about where the body is. Testing the
    /// rest-pose bounds untranslated (the pre-#301 behavior) pins the cull
    /// volume at the model's load position — a character that walks away is
    /// culled while visibly on screen. Pose variance (raised arms, crouches)
    /// is absorbed by the caller's bounds inflation; this matrix only needs
    /// to track gross displacement, for which the hips joint is the anchor.
    ///
    /// Returns identity when either position is unavailable (non-humanoid
    /// glTF) — the rest-pose box at the load position is the best available
    /// estimate there.
    public static func cullModelMatrix(
        hipsWorldPosition: SIMD3<Float>?,
        restHipsWorldPosition: SIMD3<Float>?
    ) -> matrix_float4x4 {
        guard let now = hipsWorldPosition, let rest = restHipsWorldPosition else {
            return matrix_identity_float4x4
        }
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(now.x - rest.x, now.y - rest.y, now.z - rest.z, 1)
        return m
    }
}

/// Helpers for transforming axis-aligned bounding boxes between coordinate spaces.
public enum AABBTransform {
    /// Transforms a local-space AABB by a model matrix into a (conservative) world-space AABB.
    ///
    /// Uses the Arvo (1990) abs-extent expansion: O(1) regardless of vertex
    /// count, but yields the smallest axis-aligned box that contains the
    /// transformed (potentially oriented) box.
    ///
    /// - Parameters:
    ///   - lo: Local-space AABB minimum corner.
    ///   - hi: Local-space AABB maximum corner.
    ///   - m: Model-to-world transform.
    /// - Returns: Tuple `(min, max)` of the world-space AABB.
    public static func worldAABB(
        localMin lo: SIMD3<Float>,
        localMax hi: SIMD3<Float>,
        modelMatrix m: matrix_float4x4
    ) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        let center = (lo + hi) * 0.5
        let extent = (hi - lo) * 0.5
        let translated = SIMD3<Float>(
            m.columns.3.x + m.columns.0.x * center.x + m.columns.1.x * center.y + m.columns.2.x * center.z,
            m.columns.3.y + m.columns.0.y * center.x + m.columns.1.y * center.y + m.columns.2.y * center.z,
            m.columns.3.z + m.columns.0.z * center.x + m.columns.1.z * center.y + m.columns.2.z * center.z)
        let absExtent = SIMD3<Float>(
            abs(m.columns.0.x) * extent.x + abs(m.columns.1.x) * extent.y + abs(m.columns.2.x) * extent.z,
            abs(m.columns.0.y) * extent.x + abs(m.columns.1.y) * extent.y + abs(m.columns.2.y) * extent.z,
            abs(m.columns.0.z) * extent.x + abs(m.columns.1.z) * extent.y + abs(m.columns.2.z) * extent.z)
        return (translated - absExtent, translated + absExtent)
    }
}
