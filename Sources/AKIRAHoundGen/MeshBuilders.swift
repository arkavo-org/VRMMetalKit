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
import simd

/// CPU-side mesh: flat vertex arrays plus a triangle index list. Index type is
/// chosen at pack time (`UInt16` below 65535 vertices, else `UInt32`), so
/// indices are stored as `UInt32` here.
struct MeshData {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var uvs: [SIMD2<Float>] = []
    var indices: [UInt32] = []

    /// Appends a quad (two triangles) with a single flat normal shared by all
    /// four corners. Corner order is counter-clockwise seen from `normal`.
    mutating func addQuad(center: SIMD3<Float>, axisU: SIMD3<Float>, axisV: SIMD3<Float>,
                          halfU: Float, halfV: Float, normal: SIMD3<Float>) {
        let base = UInt32(positions.count)
        let u = axisU * halfU
        let v = axisV * halfV
        let corners = [center - u - v, center + u - v, center + u + v, center - u + v]
        positions.append(contentsOf: corners)
        normals.append(contentsOf: repeatElement(normal, count: 4))
        uvs.append(contentsOf: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)])
        indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
    }

    /// Appends a quad through four explicit points with a flat normal computed
    /// from the winding. The winding is flipped when the computed normal points
    /// against `outward`, so callers can order corners loosely.
    mutating func addQuadFlat(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>,
                              _ p2: SIMD3<Float>, _ p3: SIMD3<Float>,
                              outward: SIMD3<Float>) {
        var a = p0, b = p1, c = p2, d = p3
        var n = simd_cross(b - a, c - a)
        if simd_dot(n, outward) < 0 {
            swap(&b, &d)
            n = -n
        }
        let normal = simd_normalize(n)
        let base = UInt32(positions.count)
        positions.append(contentsOf: [a, b, c, d])
        normals.append(contentsOf: repeatElement(normal, count: 4))
        uvs.append(contentsOf: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)])
        indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
    }

    /// Returns a copy translated by `offset` (normals unchanged).
    func translated(by offset: SIMD3<Float>) -> MeshData {
        var copy = self
        for i in copy.positions.indices { copy.positions[i] += offset }
        return copy
    }
}

/// Axis-aligned box centred on the origin, flat normals, planar UVs.
func makeBox(size: SIMD3<Float>) -> MeshData {
    var mesh = MeshData()
    let h = size * 0.5
    // (normal, axisU, axisV, halfU, halfV) with axisU × axisV == normal.
    mesh.addQuad(center: SIMD3( h.x, 0, 0), axisU: SIMD3(0, 0, 1), axisV: SIMD3(0, -1, 0), halfU: h.z, halfV: h.y, normal: SIMD3(1, 0, 0))
    mesh.addQuad(center: SIMD3(-h.x, 0, 0), axisU: SIMD3(0, 0, -1), axisV: SIMD3(0, -1, 0), halfU: h.z, halfV: h.y, normal: SIMD3(-1, 0, 0))
    mesh.addQuad(center: SIMD3(0,  h.y, 0), axisU: SIMD3(1, 0, 0), axisV: SIMD3(0, 0, -1), halfU: h.x, halfV: h.z, normal: SIMD3(0, 1, 0))
    mesh.addQuad(center: SIMD3(0, -h.y, 0), axisU: SIMD3(1, 0, 0), axisV: SIMD3(0, 0, 1), halfU: h.x, halfV: h.z, normal: SIMD3(0, -1, 0))
    mesh.addQuad(center: SIMD3(0, 0,  h.z), axisU: SIMD3(1, 0, 0), axisV: SIMD3(0, 1, 0), halfU: h.x, halfV: h.y, normal: SIMD3(0, 0, 1))
    mesh.addQuad(center: SIMD3(0, 0, -h.z), axisU: SIMD3(-1, 0, 0), axisV: SIMD3(0, 1, 0), halfU: h.x, halfV: h.y, normal: SIMD3(0, 0, -1))
    return mesh
}

/// Closed cylinder centred on the origin with its axis along `axis`.
/// Side wall has smooth radial normals; caps are triangle fans with flat normals.
func makeCylinder(axis: SIMD3<Float>, radius: Float, halfLength: Float, segments: Int) -> MeshData {
    var mesh = MeshData()
    let reference: SIMD3<Float> = abs(axis.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
    let u = simd_normalize(simd_cross(axis, reference))
    let v = simd_cross(axis, u)  // u × v == axis

    // Side wall: two rings with duplicated seam vertices for clean UVs.
    for i in 0...segments {
        let theta = Float(i) / Float(segments) * 2 * .pi
        let dir = u * cos(theta) + v * sin(theta)
        mesh.positions.append(-axis * halfLength + dir * radius)
        mesh.positions.append(axis * halfLength + dir * radius)
        mesh.normals.append(dir)
        mesh.normals.append(dir)
        let s = Float(i) / Float(segments)
        mesh.uvs.append(SIMD2(s, 0))
        mesh.uvs.append(SIMD2(s, 1))
    }
    for i in 0..<segments {
        let base = UInt32(i * 2)
        // Winding chosen so triangle normals point radially outward.
        mesh.indices.append(contentsOf: [base, base + 3, base + 1])
        mesh.indices.append(contentsOf: [base, base + 2, base + 3])
    }

    // Caps: centre vertex + ring, fanned. +axis cap wound (c, i, i+1);
    // -axis cap wound (c, i+1, i).
    for sign in [Float(1), Float(-1)] {
        let centerIndex = UInt32(mesh.positions.count)
        let center = axis * (halfLength * sign)
        mesh.positions.append(center)
        mesh.normals.append(axis * sign)
        mesh.uvs.append(SIMD2(0.5, 0.5))
        let ringBase = UInt32(mesh.positions.count)
        for i in 0..<segments {
            let theta = Float(i) / Float(segments) * 2 * .pi
            let dir = u * cos(theta) + v * sin(theta)
            mesh.positions.append(center + dir * radius)
            mesh.normals.append(axis * sign)
            mesh.uvs.append(SIMD2(dir.x * 0.5 + 0.5, dir.y * 0.5 + 0.5))
        }
        for i in 0..<segments {
            let a = ringBase + UInt32(i)
            let b = ringBase + UInt32((i + 1) % segments)
            if sign > 0 {
                mesh.indices.append(contentsOf: [centerIndex, a, b])
            } else {
                mesh.indices.append(contentsOf: [centerIndex, b, a])
            }
        }
    }
    return mesh
}

/// One cross-section of a lofted body: a rectangle at station `z`, optionally
/// offset laterally by `xCenter`.
struct LoftSection {
    var z: Float
    var yBottom: Float
    var yTop: Float
    var halfWidth: Float
    var xCenter: Float = 0
}

/// Lofts a series of rectangular cross-sections into a closed body (top,
/// bottom, two flanks, front and rear caps). Flat normals; used for the
/// chassis wedge, nose cowl, spine fairing, and flank light strips.
func makeLoft(sections: [LoftSection]) -> MeshData {
    var mesh = MeshData()
    guard sections.count >= 2 else { return mesh }

    func corner(_ s: LoftSection, _ xSign: Float, _ top: Bool) -> SIMD3<Float> {
        SIMD3(s.xCenter + xSign * s.halfWidth, top ? s.yTop : s.yBottom, s.z)
    }

    for i in 0..<(sections.count - 1) {
        let a = sections[i]
        let b = sections[i + 1]
        mesh.addQuadFlat(corner(a, -1, true), corner(a, 1, true),
                         corner(b, 1, true), corner(b, -1, true), outward: SIMD3(0, 1, 0))
        mesh.addQuadFlat(corner(a, -1, false), corner(a, 1, false),
                         corner(b, 1, false), corner(b, -1, false), outward: SIMD3(0, -1, 0))
        mesh.addQuadFlat(corner(a, -1, false), corner(a, -1, true),
                         corner(b, -1, true), corner(b, -1, false), outward: SIMD3(-1, 0, 0))
        mesh.addQuadFlat(corner(a, 1, false), corner(a, 1, true),
                         corner(b, 1, true), corner(b, 1, false), outward: SIMD3(1, 0, 0))
    }
    if let first = sections.first {
        mesh.addQuadFlat(corner(first, -1, false), corner(first, 1, false),
                         corner(first, 1, true), corner(first, -1, true), outward: SIMD3(0, 0, -1))
    }
    if let last = sections.last {
        mesh.addQuadFlat(corner(last, -1, false), corner(last, 1, false),
                         corner(last, 1, true), corner(last, -1, true), outward: SIMD3(0, 0, 1))
    }
    return mesh
}
