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
@testable import VRMMetalKit

/// Test-only ground truth: signed penetration against the actual skinned body
/// mesh, rather than against fitted capsules.
///
/// The capsule oracle (``SkinReferenceOracle``) carries 10 hand-authored shapes
/// over 9 bones and covers neither hands nor torso, so a finger through a dress
/// produces no signal. Extending it means ~60 authored shapes and converges its
/// method with the collider sizing it is supposed to check. The mesh needs no
/// authoring and is ground truth rather than an approximation of it.
///
/// Never shipped: this type lives in the test target and has no runtime budget.
struct SkinMeshOracle {

    struct Triangle {
        let a: SIMD3<Float>
        let b: SIMD3<Float>
        let c: SIMD3<Float>
        /// Dominant skinning bone, used to scale tolerance by body region.
        let region: VRMHumanoidBone?

        init(a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>, region: VRMHumanoidBone?) {
            self.a = a; self.b = b; self.c = c; self.region = region
        }
    }

    struct Penetration {
        /// Metres the query's surface lies past the mesh surface. Always > 0.
        let depth: Float
        let region: VRMHumanoidBone?
        let surfacePoint: SIMD3<Float>
    }

    private let triangles: [Triangle]
    private let faceNormals: [SIMD3<Float>]
    /// Angle-weighted pseudonormal per welded vertex, keyed by quantised position.
    private let vertexPseudonormals: [VertexKey: SIMD3<Float>]
    /// Sum of adjacent face normals per welded edge.
    private let edgePseudonormals: [EdgeKey: SIMD3<Float>]
    private let grid: SpatialGrid

    var triangleCount: Int { triangles.count }

    init(triangles input: [Triangle]) {
        var kept: [Triangle] = []
        var normals: [SIMD3<Float>] = []
        var vpn: [VertexKey: SIMD3<Float>] = [:]
        var epn: [EdgeKey: SIMD3<Float>] = [:]

        for t in input {
            let cross = simd_cross(t.b - t.a, t.c - t.a)
            let len = simd_length(cross)
            // A zero-area triangle has no normal; keeping it yields NaN downstream.
            guard len > 1e-12 else { continue }
            let n = cross / len
            kept.append(t)
            normals.append(n)

            let keys = [VertexKey(t.a), VertexKey(t.b), VertexKey(t.c)]
            let corners = [t.a, t.b, t.c]
            for i in 0..<3 {
                // Angle weighting is what makes the vertex pseudonormal correct
                // regardless of how finely the surface is tessellated there.
                let e1 = corners[(i + 1) % 3] - corners[i]
                let e2 = corners[(i + 2) % 3] - corners[i]
                let l1 = simd_length(e1), l2 = simd_length(e2)
                guard l1 > 1e-12, l2 > 1e-12 else { continue }
                let angle = acos(max(-1, min(1, simd_dot(e1 / l1, e2 / l2))))
                vpn[keys[i], default: .zero] += angle * n
                let ek = EdgeKey(keys[i], keys[(i + 1) % 3])
                epn[ek, default: .zero] += n
            }
        }

        self.triangles = kept
        self.faceNormals = normals
        self.vertexPseudonormals = vpn
        self.edgePseudonormals = epn
        self.grid = SpatialGrid(triangles: kept)
    }

    /// Signed penetration of a sphere of `radius` centred at `point`.
    ///
    /// Returns `nil` when the sphere is clear of the surface. There is no
    /// distance cutoff at any layer: a cutoff makes a deeply buried query find
    /// no triangle and report clean, which inverts the gate — the deepest
    /// defects would become the invisible ones.
    func penetration(of point: SIMD3<Float>, radius: Float) -> Penetration? {
        guard let hit = grid.nearest(to: point, triangles: triangles) else { return nil }
        let t = triangles[hit.index]
        let signed = signedDistance(from: point, to: hit, triangle: t, faceNormal: faceNormals[hit.index])
        let depth = radius - signed
        guard depth > 0 else { return nil }
        return Penetration(depth: depth, region: t.region, surfacePoint: hit.point)
    }

    /// Negative inside, positive outside. Classified against the angle-weighted
    /// pseudonormal of the CLOSEST FEATURE (Bærentzen–Aanæs), not the face
    /// normal: when the closest point lands on a shared edge or vertex — finger
    /// creases, palm webbing, the wrist — an arbitrary adjacent face's normal
    /// flips the sign.
    private func signedDistance(from point: SIMD3<Float>, to hit: ClosestHit,
                                triangle: Triangle, faceNormal: SIMD3<Float>) -> Float {
        let delta = point - hit.point
        let distance = simd_length(delta)
        let pseudonormal: SIMD3<Float>
        switch hit.feature {
        case .face:
            pseudonormal = faceNormal
        case .vertex(let corner):
            let key = VertexKey([triangle.a, triangle.b, triangle.c][corner])
            pseudonormal = vertexPseudonormals[key] ?? faceNormal
        case .edge(let i, let j):
            let corners = [triangle.a, triangle.b, triangle.c]
            let key = EdgeKey(VertexKey(corners[i]), VertexKey(corners[j]))
            pseudonormal = edgePseudonormals[key] ?? faceNormal
        }
        return simd_dot(delta, pseudonormal) < 0 ? -distance : distance
    }
}

extension SkinMeshOracle {

    enum ClosestFeature {
        case face
        case edge(Int, Int)
        case vertex(Int)
    }

    struct ClosestHit {
        let index: Int
        let point: SIMD3<Float>
        let feature: ClosestFeature
        let distanceSquared: Float
    }

    /// Closest point on a triangle by Voronoi region (Ericson, *Real-Time
    /// Collision Detection* §5.1.5), reporting WHICH feature owns the closest
    /// point so the caller can pick the right pseudonormal.
    static func closestPoint(on t: Triangle, to p: SIMD3<Float>) -> (SIMD3<Float>, ClosestFeature) {
        let ab = t.b - t.a, ac = t.c - t.a, ap = p - t.a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return (t.a, .vertex(0)) }

        let bp = p - t.b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return (t.b, .vertex(1)) }

        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 {
            let v = d1 / (d1 - d3)
            return (t.a + v * ab, .edge(0, 1))
        }

        let cp = p - t.c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return (t.c, .vertex(2)) }

        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 {
            let w = d2 / (d2 - d6)
            return (t.a + w * ac, .edge(0, 2))
        }

        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return (t.b + w * (t.c - t.b), .edge(1, 2))
        }

        let denom = 1 / (va + vb + vc)
        return (t.a + ab * (vb * denom) + ac * (vc * denom), .face)
    }

    /// Quantised position so coincident corners from different triangles weld.
    /// 1e-5 m is well below any real mesh feature and well above float noise.
    struct VertexKey: Hashable {
        let x: Int32, y: Int32, z: Int32
        init(_ p: SIMD3<Float>) {
            x = Int32((p.x * 100_000).rounded())
            y = Int32((p.y * 100_000).rounded())
            z = Int32((p.z * 100_000).rounded())
        }
    }

    struct EdgeKey: Hashable {
        let lo: VertexKey, hi: VertexKey
        init(_ a: VertexKey, _ b: VertexKey) {
            if (a.x, a.y, a.z) <= (b.x, b.y, b.z) { lo = a; hi = b } else { lo = b; hi = a }
        }
    }

    /// Brute-force nearest. Task 3 replaces the internals with a uniform grid
    /// and must return identical results.
    struct SpatialGrid {
        init(triangles: [Triangle]) {}

        func nearest(to p: SIMD3<Float>, triangles: [Triangle]) -> ClosestHit? {
            var best: ClosestHit?
            for (i, t) in triangles.enumerated() {
                let (q, feature) = SkinMeshOracle.closestPoint(on: t, to: p)
                let d2 = simd_length_squared(p - q)
                // Ties break by lowest triangle index so results are deterministic.
                if best == nil || d2 < best!.distanceSquared - 1e-12 {
                    best = ClosestHit(index: i, point: q, feature: feature, distanceSquared: d2)
                }
            }
            return best
        }
    }
}
