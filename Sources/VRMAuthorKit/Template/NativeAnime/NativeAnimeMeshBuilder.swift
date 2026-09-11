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

/// A vertex under construction: double-precision position, its UV, and the
/// pivot (ring centre or feature anchor) that radial shape offsets scale about.
struct BuildVertex {
    var position: V3
    var uv: V2
    var pivot: V3
}

/// An elliptical cross-section: `u`/`v` span the ring plane and `u × v` points
/// along the loft direction so emitted quads wind outward.
struct Ring {
    var center: V3
    var u: V3
    var v: V3
    var ru: Double
    var rv: Double
    var region: String

    func point(_ theta: Double) -> V3 {
        center + u * (cos(theta) * ru) + v * (sin(theta) * rv)
    }
}

/// Quad-dominant mesh under construction. Quads are stored as authored and
/// triangulated on emit with the fixed diagonal (a,b,c),(a,c,d).
struct BuildMesh {
    var vertices: [BuildVertex] = []
    var quads: [SIMD4<Int>] = []
    var tris: [SIMD3<Int>] = []
    var regions: [String: [Int]] = [:]

    var vertexCount: Int { vertices.count }

    @discardableResult
    mutating func addVertex(_ p: V3, uv: V2, pivot: V3, regions tags: [String] = []) -> Int {
        vertices.append(BuildVertex(position: p, uv: uv, pivot: pivot))
        let i = vertices.count - 1
        for t in tags { regions[t, default: []].append(i) }
        return i
    }

    mutating func tag(_ region: String, _ indices: [Int]) {
        regions[region, default: []].append(contentsOf: indices)
    }

    mutating func addQuad(_ a: Int, _ b: Int, _ c: Int, _ d: Int) { quads.append(SIMD4(a, b, c, d)) }
    mutating func addTri(_ a: Int, _ b: Int, _ c: Int) { tris.append(SIMD3(a, b, c)) }

    func indices(in region: String) -> [Int] { regions[region] ?? [] }

    /// Lofts `rings` (ordered along the loft direction) with `segments` around
    /// each ring. Caps are pole fans, never collapsed rings. Returns the
    /// per-ring vertex indices.
    @discardableResult
    mutating func loft(_ rings: [Ring], segments: Int, capStart: V3?, capEnd: V3?, extraRegions: [String] = []) -> [[Int]] {
        precondition(rings.count >= 2 && segments >= 3)
        var rows: [[Int]] = []
        for (ri, ring) in rings.enumerated() {
            var row: [Int] = []
            let v = Double(ri) / Double(rings.count - 1)
            for j in 0..<segments {
                let theta = 2 * Double.pi * Double(j) / Double(segments)
                let u = Double(j) / Double(segments)
                row.append(addVertex(ring.point(theta), uv: V2(u, v), pivot: ring.center, regions: [ring.region] + extraRegions))
            }
            rows.append(row)
        }
        for ri in 0..<(rings.count - 1) {
            let lo = rows[ri], hi = rows[ri + 1]
            for j in 0..<segments {
                let k = (j + 1) % segments
                addQuad(lo[j], lo[k], hi[k], hi[j])
            }
        }
        if let cap = capStart {
            let pole = addVertex(cap, uv: V2(0.5, 0), pivot: rings[0].center, regions: [rings[0].region] + extraRegions)
            let row = rows[0]
            for j in 0..<segments { addTri(pole, row[(j + 1) % segments], row[j]) }
        }
        if let cap = capEnd {
            let last = rings[rings.count - 1]
            let pole = addVertex(cap, uv: V2(0.5, 1), pivot: last.center, regions: [last.region] + extraRegions)
            let row = rows[rows.count - 1]
            for j in 0..<segments { addTri(pole, row[j], row[(j + 1) % segments]) }
        }
        return rows
    }

    /// Connects two open rows of equal length with quads: (a[j], a[j+1], b[j+1], b[j]).
    mutating func bridge(_ a: [Int], _ b: [Int]) {
        precondition(a.count == b.count && a.count >= 2)
        for j in 0..<(a.count - 1) { addQuad(a[j], a[j + 1], b[j + 1], b[j]) }
    }

    /// Connects two closed loops of equal length with quads.
    mutating func bridgeLoop(_ a: [Int], _ b: [Int]) {
        precondition(a.count == b.count && a.count >= 3)
        for j in 0..<a.count {
            let k = (j + 1) % a.count
            addQuad(a[j], a[k], b[k], b[j])
        }
    }

    func triangles() -> [SIMD3<Int>] {
        var out: [SIMD3<Int>] = []
        out.reserveCapacity(quads.count * 2 + tris.count)
        for q in quads {
            out.append(SIMD3(q.x, q.y, q.z))
            out.append(SIMD3(q.x, q.z, q.w))
        }
        out.append(contentsOf: tris)
        return out
    }

    func normals() -> [V3] {
        var acc = [V3](repeating: .zero, count: vertices.count)
        for t in triangles() {
            let a = vertices[t.x].position, b = vertices[t.y].position, c = vertices[t.z].position
            let n = NAMath.cross(b - a, c - a)
            acc[t.x] += n
            acc[t.y] += n
            acc[t.z] += n
        }
        return acc.map { NAMath.normalize($0) }
    }

    /// Float32 quantization happens here, once, for positions, normals, UVs and morph deltas.
    func emit(materialId: String, joints: [SIMD4<UInt16>]?, weights: [SIMD4<Float>]?, morphs: [(String, [V3])]) -> CompiledPrimitive {
        let positions = vertices.map { NAMath.f($0.position) }
        let uvs = vertices.map { NAMath.f($0.uv) }
        let nrm = normals().map { NAMath.f($0) }
        var indices: [UInt32] = []
        indices.reserveCapacity((quads.count * 2 + tris.count) * 3)
        for t in triangles() {
            indices.append(UInt32(t.x))
            indices.append(UInt32(t.y))
            indices.append(UInt32(t.z))
        }
        let targets = morphs.map { CompiledMorph(name: $0.0, positionDeltas: $0.1.map { NAMath.f($0) }) }
        return CompiledPrimitive(materialId: materialId, positions: positions, normals: nrm, uv0: uvs, joints0: joints, weights0: weights,
                                 indices: indices, morphTargets: targets)
    }
}
