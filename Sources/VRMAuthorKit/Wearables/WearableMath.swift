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

enum V3 {
    static func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { (a * b).sum() }
    static func length(_ a: SIMD3<Float>) -> Float { dot(a, a).squareRoot() }
    static func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { length(a - b) }
    static func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }

    static func normalize(_ a: SIMD3<Float>, fallback: SIMD3<Float> = SIMD3(0, 1, 0)) -> SIMD3<Float> {
        let l = length(a)
        return l > 1e-12 ? a / l : fallback
    }

    /// Component of `a` orthogonal to unit vector `axis`.
    static func reject(_ a: SIMD3<Float>, from axis: SIMD3<Float>) -> SIMD3<Float> { a - axis * dot(a, axis) }

    /// Rodrigues rotation of `v` about unit `axis` by `angle` radians.
    static func rotate(_ v: SIMD3<Float>, axis: SIMD3<Float>, angle: Float) -> SIMD3<Float> {
        let c = cos(angle), s = sin(angle)
        return v * c + cross(axis, v) * s + axis * (dot(axis, v) * (1 - c))
    }

    static func rotate(_ p: SIMD3<Float>, about pivot: SIMD3<Float>, axis: SIMD3<Float>, angle: Float) -> SIMD3<Float> {
        pivot + rotate(p - pivot, axis: axis, angle: angle)
    }

    static func rotate(_ v: SIMD3<Float>, by q: SIMD4<Float>) -> SIMD3<Float> {
        let u = SIMD3(q.x, q.y, q.z)
        let w = q.w
        return u * (2 * dot(u, v)) + v * (w * w - dot(u, u)) + cross(u, v) * (2 * w)
    }

    static func isFinite(_ v: SIMD3<Float>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }

    static func doubles(_ v: SIMD3<Float>) -> [Double] { [Double(v.x), Double(v.y), Double(v.z)] }
}

/// Column-major affine 4x4 matrix over the `SIMD16<Float>` layout used by
/// `CompiledSkin.inverseBindMatrices` (element (row r, column c) at c*4+r).
struct Mat4: Hashable {
    var m: SIMD16<Float>

    init(_ m: SIMD16<Float>) { self.m = m }

    static let identity = Mat4(SIMD16(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1))

    init(translation t: SIMD3<Float>, rotation q: SIMD4<Float> = SIMD4(0, 0, 0, 1), scale s: SIMD3<Float> = SIMD3(repeating: 1)) {
        let x = q.x, y = q.y, z = q.z, w = q.w
        let r00 = 1 - 2 * (y * y + z * z), r01 = 2 * (x * y - z * w), r02 = 2 * (x * z + y * w)
        let r10 = 2 * (x * y + z * w), r11 = 1 - 2 * (x * x + z * z), r12 = 2 * (y * z - x * w)
        let r20 = 2 * (x * z - y * w), r21 = 2 * (y * z + x * w), r22 = 1 - 2 * (x * x + y * y)
        m = SIMD16(r00 * s.x, r10 * s.x, r20 * s.x, 0,
                   r01 * s.y, r11 * s.y, r21 * s.y, 0,
                   r02 * s.z, r12 * s.z, r22 * s.z, 0,
                   t.x, t.y, t.z, 1)
    }

    subscript(row: Int, col: Int) -> Float {
        get { m[col * 4 + row] }
        set { m[col * 4 + row] = newValue }
    }

    var translation: SIMD3<Float> { SIMD3(m[12], m[13], m[14]) }

    static func * (a: Mat4, b: Mat4) -> Mat4 {
        var out = Mat4(SIMD16(repeating: 0))
        for c in 0..<4 {
            for r in 0..<4 {
                var acc: Float = 0
                for k in 0..<4 { acc += a[r, k] * b[k, c] }
                out[r, c] = acc
            }
        }
        return out
    }

    func transformPoint(_ p: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(self[0, 0] * p.x + self[0, 1] * p.y + self[0, 2] * p.z + self[0, 3],
              self[1, 0] * p.x + self[1, 1] * p.y + self[1, 2] * p.z + self[1, 3],
              self[2, 0] * p.x + self[2, 1] * p.y + self[2, 2] * p.z + self[2, 3])
    }

    func transformDirection(_ d: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(self[0, 0] * d.x + self[0, 1] * d.y + self[0, 2] * d.z,
              self[1, 0] * d.x + self[1, 1] * d.y + self[1, 2] * d.z,
              self[2, 0] * d.x + self[2, 1] * d.y + self[2, 2] * d.z)
    }

    /// Inverse of an affine matrix (last row 0 0 0 1).
    func affineInverse() -> Mat4 {
        let a = self[0, 0], b = self[0, 1], c = self[0, 2]
        let d = self[1, 0], e = self[1, 1], f = self[1, 2]
        let g = self[2, 0], h = self[2, 1], i = self[2, 2]
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        let inv = det.magnitude > 1e-20 ? 1 / det : 0
        var r = Mat4.identity
        r[0, 0] = (e * i - f * h) * inv
        r[0, 1] = (c * h - b * i) * inv
        r[0, 2] = (b * f - c * e) * inv
        r[1, 0] = (f * g - d * i) * inv
        r[1, 1] = (a * i - c * g) * inv
        r[1, 2] = (c * d - a * f) * inv
        r[2, 0] = (d * h - e * g) * inv
        r[2, 1] = (b * g - a * h) * inv
        r[2, 2] = (a * e - b * d) * inv
        let t = translation
        let it = r.transformDirection(t)
        r[0, 3] = -it.x
        r[1, 3] = -it.y
        r[2, 3] = -it.z
        return r
    }
}

/// Signed distance queries against a triangle soup with per-vertex normals.
/// Sign comes from the interpolated vertex normal at the closest point.
struct SurfaceProbe {
    struct Hit {
        var distance: Float
        var closest: SIMD3<Float>
        var normal: SIMD3<Float>
        var triangle: Int
    }

    let positions: [SIMD3<Float>]
    let normals: [SIMD3<Float>]
    let triangles: [SIMD3<Int>]
    private let centres: [SIMD3<Float>]
    private let radii: [Float]

    init(positions: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32], include: ((Int, Int, Int) -> Bool)? = nil) {
        self.positions = positions
        self.normals = normals
        var tris: [SIMD3<Int>] = []
        var cs: [SIMD3<Float>] = []
        var rs: [Float] = []
        var t = 0
        while t + 2 < indices.count {
            let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
            t += 3
            guard a < positions.count, b < positions.count, c < positions.count else { continue }
            if let include, !include(a, b, c) { continue }
            let pa = positions[a], pb = positions[b], pc = positions[c]
            let centre = (pa + pb + pc) / 3
            let radius = max(V3.distance(centre, pa), V3.distance(centre, pb), V3.distance(centre, pc))
            tris.append(SIMD3(a, b, c))
            cs.append(centre)
            rs.append(radius)
        }
        triangles = tris
        centres = cs
        radii = rs
    }

    var isEmpty: Bool { triangles.isEmpty }

    func nearest(to p: SIMD3<Float>) -> Hit? {
        var best: Hit?
        var bestD = Float.infinity
        for (t, tri) in triangles.enumerated() {
            if V3.distance(p, centres[t]) - radii[t] >= bestD { continue }
            let (q, bary) = SurfaceProbe.closestPoint(p, positions[tri.x], positions[tri.y], positions[tri.z])
            let d = V3.distance(p, q)
            if d < bestD {
                bestD = d
                let n = V3.normalize(normals[tri.x] * bary.x + normals[tri.y] * bary.y + normals[tri.z] * bary.z)
                best = Hit(distance: d, closest: q, normal: n, triangle: t)
            }
        }
        guard var hit = best else { return nil }
        let outward = V3.dot(p - hit.closest, hit.normal) >= 0
        hit.distance = outward ? hit.distance : -hit.distance
        return hit
    }

    func signedDistance(to p: SIMD3<Float>) -> Float? { nearest(to: p)?.distance }

    /// Closest point on triangle abc to p and its barycentric coordinates.
    static func closestPoint(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = V3.dot(ab, ap), d2 = V3.dot(ac, ap)
        if d1 <= 0, d2 <= 0 { return (a, SIMD3(1, 0, 0)) }
        let bp = p - b
        let d3 = V3.dot(ab, bp), d4 = V3.dot(ac, bp)
        if d3 >= 0, d4 <= d3 { return (b, SIMD3(0, 1, 0)) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0, d1 >= 0, d3 <= 0 {
            let v = d1 / (d1 - d3)
            return (a + ab * v, SIMD3(1 - v, v, 0))
        }
        let cp = p - c
        let d5 = V3.dot(ab, cp), d6 = V3.dot(ac, cp)
        if d6 >= 0, d5 <= d6 { return (c, SIMD3(0, 0, 1)) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0, d2 >= 0, d6 <= 0 {
            let w = d2 / (d2 - d6)
            return (a + ac * w, SIMD3(1 - w, 0, w))
        }
        let va = d3 * d6 - d5 * d4
        if va <= 0, d4 - d3 >= 0, d5 - d6 >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return (b + (c - b) * w, SIMD3(0, 1 - w, w))
        }
        let denom = 1 / (va + vb + vc)
        let v = vb * denom, w = vc * denom
        return (a + ab * v + ac * w, SIMD3(1 - v - w, v, w))
    }
}

/// Accumulates one primitive's vertex streams.
struct MeshBuilder {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var uv0: [SIMD2<Float>] = []
    var joints0: [SIMD4<UInt16>] = []
    var weights0: [SIMD4<Float>] = []
    var indices: [UInt32] = []

    var vertexCount: Int { positions.count }

    @discardableResult
    mutating func addVertex(_ p: SIMD3<Float>, normal: SIMD3<Float>, uv: SIMD2<Float>, joints: SIMD4<UInt16>, weights: SIMD4<Float>) -> UInt32 {
        positions.append(p)
        normals.append(normal)
        uv0.append(uv)
        joints0.append(joints)
        weights0.append(weights)
        return UInt32(positions.count - 1)
    }

    mutating func addTriangle(_ a: UInt32, _ b: UInt32, _ c: UInt32) { indices.append(contentsOf: [a, b, c]) }

    mutating func addQuad(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) {
        addTriangle(a, b, c)
        addTriangle(a, c, d)
    }

    /// Axis-aligned box with flat normals, rigidly bound to one joint.
    mutating func addBox(centre: SIMD3<Float>, halfExtents h: SIMD3<Float>, transform: (SIMD3<Float>) -> SIMD3<Float>,
                         normalTransform: (SIMD3<Float>) -> SIMD3<Float>) {
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, -1)),
            (SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)),
            (SIMD3(0, 1, 0), SIMD3(0, 0, -1), SIMD3(1, 0, 0)),
            (SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 0)),
            (SIMD3(0, 0, 1), SIMD3(0, 1, 0), SIMD3(1, 0, 0)),
            (SIMD3(0, 0, -1), SIMD3(0, 1, 0), SIMD3(-1, 0, 0)),
        ]
        for (n, up, right) in faces {
            let fc = centre + n * h
            let corners = [fc - right * h - up * h, fc + right * h - up * h, fc + right * h + up * h, fc - right * h + up * h]
            let uvs: [SIMD2<Float>] = [SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0)]
            let nn = V3.normalize(normalTransform(n))
            let base = UInt32(positions.count)
            for (i, corner) in corners.enumerated() {
                addVertex(transform(corner), normal: nn, uv: uvs[i], joints: SIMD4(0, 0, 0, 0), weights: SIMD4(1, 0, 0, 0))
            }
            addQuad(base, base + 1, base + 2, base + 3)
        }
    }

    func primitive(materialId: String, skinned: Bool) -> CompiledPrimitive {
        CompiledPrimitive(materialId: materialId, positions: positions, normals: normals, uv0: uv0,
                          joints0: skinned ? joints0 : nil, weights0: skinned ? weights0 : nil, indices: indices)
    }
}
