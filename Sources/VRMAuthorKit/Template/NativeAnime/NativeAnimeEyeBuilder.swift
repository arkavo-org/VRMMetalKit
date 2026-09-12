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

/// Eye globe mesh primitives in emission order: sclera, iris disc (iris ring
/// to pupil ring to front pole) and a small highlight card.
enum EyePrimitive: Int, CaseIterable {
    case sclera = 0, iris, highlight

    var materialId: String {
        switch self {
        case .sclera: return NativeAnimeMaterials.eyeWhite
        case .iris: return NativeAnimeMaterials.iris
        case .highlight: return NativeAnimeMaterials.eyeHighlight
        }
    }
}

/// Sculpted globe with the pole axis along +Z. Latitude rings are concentric
/// around the gaze direction; the pupil and iris boundaries are rings whose
/// polar angle the iris/pupil controls set. UV radii per ring are constant so
/// the iris texture region never moves: pupil ≤ 0.10, iris ≤ 0.25, sclera beyond.
struct NativeAnimeEyeBuilder {
    static let segments = 28
    static let scleraAngles: [Double] = [150, 120, 95, 75, 55]
    static let scleraUVRadii: [Double] = [0.50, 0.47, 0.42, 0.37, 0.32]
    static let irisUVRadius = 0.25
    static let pupilUVRadius = 0.10

    let eye: NativeAnimeLayout.EyeParams

    func build() -> [BuildMesh] {
        let r = eye.globeRadius
        let E = eye.center
        let segs = Self.segments
        let globe = eye.sideSign > 0 ? "globeL" : "globeR"

        func ring(_ theta: Double, region: String) -> Ring {
            Ring(center: E + NAMath.zAxis * (r * cos(theta)), u: NAMath.xAxis, v: NAMath.yAxis, ru: r * sin(theta), rv: r * sin(theta), region: region)
        }

        func stampUV(_ mesh: inout BuildMesh, rows: [[Int]], radii: [Double]) {
            for (ri, row) in rows.enumerated() {
                for (j, idx) in row.enumerated() {
                    let phi = 2 * Double.pi * Double(j) / Double(segs)
                    mesh.vertices[idx].uv = NAVec2(0.5 + radii[ri] * cos(phi), 0.5 - radii[ri] * sin(phi))
                }
            }
        }

        var sclera = BuildMesh()
        var scleraRings = Self.scleraAngles.map { ring(NAMath.degrees($0), region: globe) }
        scleraRings.append(ring(eye.irisAngle, region: globe))
        let scleraRows = sclera.loft(scleraRings, segments: segs, capStart: E - NAMath.zAxis * r, capEnd: nil)
        stampUV(&sclera, rows: scleraRows, radii: Self.scleraUVRadii + [Self.irisUVRadius])
        sclera.tag("iris", scleraRows[scleraRows.count - 1])
        if let pole = sclera.regions[globe]?.last { sclera.vertices[pole].uv = NAVec2(1, 0.5) }

        var iris = BuildMesh()
        let irisRings = [ring(eye.irisAngle, region: "iris"), ring(eye.pupilAngle, region: "pupil")]
        let irisRows = iris.loft(irisRings, segments: segs, capStart: nil, capEnd: E + NAMath.zAxis * r, extraRegions: [globe])
        stampUV(&iris, rows: irisRows, radii: [Self.irisUVRadius, Self.pupilUVRadius])
        iris.tag("iris", irisRows[1])
        if let pole = iris.regions["pupil"]?.last {
            iris.vertices[pole].uv = NAVec2(0.5, 0.5)
            iris.tag("iris", [pole])
        }

        var highlight = BuildMesh()
        let theta = eye.irisAngle * 0.55
        let phi = eye.sideSign > 0 ? NAMath.degrees(135) : NAMath.degrees(45)
        let dir = NAVec3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta))
        let centre = E + dir * (r * 1.02)
        let tangentU = NAMath.normalize(NAMath.cross(NAMath.yAxis, dir))
        let tangentV = NAMath.normalize(NAMath.cross(dir, tangentU))
        let size = 0.12 * r
        let corners = [
            centre - tangentU * size - tangentV * size,
            centre + tangentU * size - tangentV * size,
            centre + tangentU * size + tangentV * size,
            centre - tangentU * size + tangentV * size,
        ]
        let uvs = [NAVec2(0, 1), NAVec2(1, 1), NAVec2(1, 0), NAVec2(0, 0)]
        var ids: [Int] = []
        for (k, c) in corners.enumerated() { ids.append(highlight.addVertex(c, uv: uvs[k], pivot: E, regions: [globe, "highlight"])) }
        highlight.addQuad(ids[0], ids[1], ids[2], ids[3])
        return [sclera, iris, highlight]
    }
}
