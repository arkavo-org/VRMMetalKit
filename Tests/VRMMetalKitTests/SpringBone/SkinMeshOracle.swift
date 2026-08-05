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

    /// Uniform spatial hash over triangle bounds with an EXPANDING ring search.
    ///
    /// The search widens until the nearest ring's minimum possible distance
    /// exceeds the best found, so it terminates on a true nearest with no
    /// distance gate anywhere. A fixed search radius would make a deeply buried
    /// query find nothing and read clean.
    struct SpatialGrid {
        private let cell: Float
        private let buckets: [Cell: [Int]]
        private let origin: SIMD3<Float>
        /// Every occupied bucket lies within this range (inclusive), since a
        /// triangle can only ever be inserted into cells spanning its own
        /// bounds, which are themselves within the mesh's overall extent.
        private let minCell: Cell
        private let maxCell: Cell

        struct Cell: Hashable { let x: Int32, y: Int32, z: Int32 }

        init(triangles: [Triangle]) {
            guard !triangles.isEmpty else {
                cell = 1; buckets = [:]; origin = .zero
                minCell = Cell(x: 0, y: 0, z: 0); maxCell = Cell(x: 0, y: 0, z: 0)
                return
            }
            var lo = triangles[0].a, hi = triangles[0].a
            var edgeSum: Float = 0
            for t in triangles {
                for v in [t.a, t.b, t.c] { lo = simd_min(lo, v); hi = simd_max(hi, v) }
                edgeSum += simd_length(t.b - t.a)
            }
            // Cell ~ mean edge length keeps occupancy near one triangle per cell.
            cell = max(edgeSum / Float(triangles.count), 1e-4)
            origin = lo
            var b: [Cell: [Int]] = [:]
            for (i, t) in triangles.enumerated() {
                let tlo = simd_min(simd_min(t.a, t.b), t.c)
                let thi = simd_max(simd_max(t.a, t.b), t.c)
                let c0 = Self.cellIndex(tlo, origin: lo, cell: cell)
                let c1 = Self.cellIndex(thi, origin: lo, cell: cell)
                for x in c0.x...c1.x { for y in c0.y...c1.y { for z in c0.z...c1.z {
                    b[Cell(x: x, y: y, z: z), default: []].append(i)
                } } }
            }
            buckets = b
            minCell = Self.cellIndex(lo, origin: lo, cell: cell)
            maxCell = Self.cellIndex(hi, origin: lo, cell: cell)
        }

        private static func cellIndex(_ p: SIMD3<Float>, origin: SIMD3<Float>, cell: Float) -> Cell {
            let q = (p - origin) / cell
            return Cell(x: Int32(q.x.rounded(.down)), y: Int32(q.y.rounded(.down)), z: Int32(q.z.rounded(.down)))
        }

        /// Chebyshev distance in cells from `c` to the occupied bucket range.
        /// Zero if `c` is inside it. Every ring below this value is provably
        /// empty, so the search can start there directly instead of walking
        /// out from ring 0 — the win that matters for a query far outside the
        /// whole mesh, where the alternative is thousands of empty rings.
        private func ringToReach(_ c: Cell) -> Int32 {
            let dx = max(0, max(minCell.x - c.x, c.x - maxCell.x))
            let dy = max(0, max(minCell.y - c.y, c.y - maxCell.y))
            let dz = max(0, max(minCell.z - c.z, c.z - maxCell.z))
            return max(dx, max(dy, dz))
        }

        func nearest(to p: SIMD3<Float>, triangles: [Triangle]) -> ClosestHit? {
            guard !buckets.isEmpty else { return nil }
            let centre = Self.cellIndex(p, origin: origin, cell: cell)
            var best: ClosestHit?
            // A triangle whose bounds span many cells (e.g. a large flat panel
            // next to finely-tessellated detail) is inserted into every one of
            // them at build time, so the same index can turn up in several
            // shell cells within one search. Skipping indices already scored
            // this call avoids recomputing an identical closest point — same
            // candidate, same winner, just not redundantly.
            var seen = Set<Int>()
            func consider(_ c: Cell) {
                guard let ids = buckets[c] else { return }
                for i in ids {
                    guard seen.insert(i).inserted else { continue }
                    let (q, feature) = SkinMeshOracle.closestPoint(on: triangles[i], to: p)
                    let d2 = simd_length_squared(p - q)
                    if best == nil || d2 < best!.distanceSquared - 1e-12 {
                        best = ClosestHit(index: i, point: q, feature: feature, distanceSquared: d2)
                    }
                }
            }
            // Every ring below this is provably outside the occupied bucket
            // range, so start where the shell can first possibly touch it.
            var ring: Int32 = ringToReach(centre)
            while true {
                // Visit exactly the cells at Chebyshev distance `ring` from
                // `centre` — the six faces of the (2·ring+1)³ cube's boundary —
                // rather than the whole cube filtered down. A query far from
                // any occupied bucket (e.g. the far-outside case) can need a
                // large ring before finding a candidate; walking the full cube
                // at every ring is O(ring³) of wasted work per ring, which
                // makes that case pathologically slow without changing the
                // answer. Visiting the shell directly is O(ring²) per ring and
                // examines the identical set of cells.
                if ring == 0 {
                    consider(centre)
                } else {
                    for x in [centre.x - ring, centre.x + ring] {
                        for y in (centre.y - ring)...(centre.y + ring) {
                            for z in (centre.z - ring)...(centre.z + ring) {
                                consider(Cell(x: x, y: y, z: z))
                            }
                        }
                    }
                    for y in [centre.y - ring, centre.y + ring] {
                        for x in (centre.x - ring + 1)...(centre.x + ring - 1) {
                            for z in (centre.z - ring)...(centre.z + ring) {
                                consider(Cell(x: x, y: y, z: z))
                            }
                        }
                    }
                    for z in [centre.z - ring, centre.z + ring] {
                        for x in (centre.x - ring + 1)...(centre.x + ring - 1) {
                            for y in (centre.y - ring + 1)...(centre.y + ring - 1) {
                                consider(Cell(x: x, y: y, z: z))
                            }
                        }
                    }
                }
                // A triangle outside this shell cannot be nearer than the shell's
                // own minimum distance, so once that exceeds `best` we are done.
                if let b = best {
                    let shellDistance = Float(ring) * cell
                    if shellDistance * shellDistance > b.distanceSquared { return best }
                }
                ring += 1
                if ring > 4096 { return best }
            }
        }
    }
}

extension SkinMeshOracle {
    /// Reference implementation for the grid's equivalence gate. Scans every
    /// triangle; correctness here is Task 2's, already pinned.
    static func bruteForcePenetrationForTesting(oracle: SkinMeshOracle, point: SIMD3<Float>,
                                                radius: Float) -> Penetration? {
        oracle.penetrationScanningAll(point: point, radius: radius)
    }

    /// Linear-scan twin of `penetration(of:radius:)`. Identical logic; the only
    /// difference is that it never consults the grid.
    func penetrationScanningAll(point: SIMD3<Float>, radius: Float) -> Penetration? {
        var best: ClosestHit?
        for (i, t) in triangles.enumerated() {
            let (q, feature) = SkinMeshOracle.closestPoint(on: t, to: point)
            let d2 = simd_length_squared(point - q)
            if best == nil || d2 < best!.distanceSquared - 1e-12 {
                best = ClosestHit(index: i, point: q, feature: feature, distanceSquared: d2)
            }
        }
        guard let hit = best else { return nil }
        let t = triangles[hit.index]
        let signed = signedDistance(from: point, to: hit, triangle: t, faceNormal: faceNormals[hit.index])
        let depth = radius - signed
        guard depth > 0 else { return nil }
        return Penetration(depth: depth, region: t.region, surfacePoint: hit.point)
    }
}
