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

/// One lid vertex: which head primitive holds it, its lid-local frontal
/// coordinates at rest and its row fraction (0 = opening edge, 1 = root).
struct LidVertex {
    var primitive: Int
    var index: Int
    var column: Int
    var lx: Double
    var ly: Double
    var row: Double
    var upper: Bool
}

struct BrowVertex {
    var index: Int
    var innerFraction: Double
    var top: Bool
}

struct LoopVertex {
    var index: Int
    var alpha: Double
}

/// Feature handles the morph builder needs after the head is built.
struct HeadHandles {
    var lids: [String: [LidVertex]] = [:]
    var lidColumns = 0
    var brows: [String: [BrowVertex]] = [:]
    var lipOuter: [LoopVertex] = []
    var lipInner: [LoopVertex] = []
    var cavityFront: [LoopVertex] = []
    var cavityBack: [LoopVertex] = []
    var mouthCenter = NAVec3.zero
    var mouthHalfWidth = 0.0
    var jawWeights: [(index: Int, weight: Double)] = []
    var earRoots: [String: NAVec3] = [:]
    var noseBridge = NAVec3.zero
    /// Cheek vertices per side on the skin primitive (face region, below and
    /// outside the eyes): emotion morphs raise them to sell a smile.
    var cheeks: [String: [Int]] = [:]
}

/// Head mesh primitives in emission order.
enum HeadPrimitive: Int, CaseIterable {
    case skin = 0, eyelash, eyeline, brow, mouth

    var materialId: String {
        switch self {
        case .skin: return NativeAnimeMaterials.faceSkin
        case .eyelash: return NativeAnimeMaterials.eyelash
        case .eyeline: return NativeAnimeMaterials.eyeline
        case .brow: return NativeAnimeMaterials.brow
        case .mouth: return NativeAnimeMaterials.mouth
        }
    }
}

struct HeadParts {
    var primitives: [BuildMesh]
    var handles: HeadHandles
}

struct NativeAnimeHeadBuilder {
    static let shellSegments = 48
    static let shellRings = 30
    static let lidColumns = 11
    static let lipColumns = 16
    static let earSegments = 12
    static let noseSegments = 12
    static let browColumns = 5

    let layout: NativeAnimeLayout

    private var hh: Double { layout.headHeight }
    private var C: NAVec3 { layout.headCenter }
    private var R: NAVec3 { layout.headRadii }

    func build() -> HeadParts {
        var prims = HeadPrimitive.allCases.map { _ in BuildMesh() }
        var handles = HeadHandles()
        buildShell(&prims[HeadPrimitive.skin.rawValue], handles: &handles)
        buildEars(&prims[HeadPrimitive.skin.rawValue], handles: &handles)
        buildNose(&prims[HeadPrimitive.skin.rawValue], handles: &handles)
        for side in ["left", "right"] {
            buildLids(&prims, side: side, handles: &handles)
            buildBrow(&prims[HeadPrimitive.brow.rawValue], side: side, handles: &handles)
        }
        buildMouth(&prims[HeadPrimitive.mouth.rawValue], handles: &handles)
        return HeadParts(primitives: prims, handles: handles)
    }

    // MARK: Shell

    private func buildShell(_ mesh: inout BuildMesh, handles: inout HeadHandles) {
        let segs = Self.shellSegments
        let ringsN = Self.shellRings
        var rings: [Ring] = []
        for i in 0..<ringsN {
            let psi = Double.pi - Double.pi * Double(i + 1) / Double(ringsN + 1)
            let y = C.y + R.y * cos(psi)
            let (rx, rz) = NativeAnimeLayout.shellRadii(radii: R, center: C, y: y)
            rings.append(Ring(center: NAVec3(0, y, 0), u: NAMath.xAxis, v: -NAMath.zAxis, ru: rx * sin(psi), rv: rz * sin(psi), region: "shell"))
        }
        let base = mesh.vertexCount
        mesh.loft(rings, segments: segs, capStart: NAVec3(0, C.y - R.y, 0), capEnd: NAVec3(0, C.y + R.y, 0))
        mesh.regions["shell"] = nil
        var regionSets: [String: [Int]] = [:]
        for i in base..<mesh.vertexCount {
            let p = mesh.vertices[i].position
            let nx = p.x / R.x, ny = (p.y - C.y) / R.y, nz = p.z / R.z
            let region: String
            if ny > 0.45 || (nz <= -0.15 && ny > -0.35) {
                region = "scalp"
            } else if nz <= -0.15 {
                region = "nape"
            } else if ny > 0.10 {
                region = "forehead"
            } else if ny < -0.62 {
                region = (abs(nx) < 0.4 && nz > 0.1) ? "chin" : "jaw"
            } else {
                region = "face"
            }
            regionSets[region, default: []].append(i)
        }
        for key in regionSets.keys.sorted() { mesh.tag(key, regionSets[key]!) }

        // Cheek handles: face verts below and outside the eyes.
        for (side, sign) in [("left", 1.0), ("right", -1.0)] {
            guard let eye = layout.eyes[side] else { continue }
            var idx: [Int] = []
            for i in regionSets["face"] ?? [] {
                let p = mesh.vertices[i].position
                let dx = (p.x - eye.center.x) * sign
                let dy = p.y - eye.center.y
                if dx > 0.2 * eye.lidRadius, dx < 1.6 * eye.lidRadius, dy < -0.4 * eye.lidRadius, dy > -1.6 * eye.lidRadius, p.z > 0 {
                    idx.append(i)
                }
            }
            handles.cheeks[side] = idx
        }

        let defaultGlobe = layout.defaultLidRadius
        for (side, sign) in [("left", 1.0), ("right", -1.0)] {
            let eye = layout.eyes[side]!
            let defaultCenter = NAVec3(layout.defaultEyeX(sign), layout.eyeLineY, 0)
            var socket: [Int] = []
            for i in base..<mesh.vertexCount {
                let p = mesh.vertices[i].position
                guard p.z > 0 else { continue }
                let dDefault = ((p.x - defaultCenter.x) * (p.x - defaultCenter.x) + (p.y - defaultCenter.y) * (p.y - defaultCenter.y)).squareRoot()
                if dDefault < 2.2 * defaultGlobe { socket.append(i) }
            }
            for i in socket {
                let p = mesh.vertices[i].position
                let dx = p.x - eye.center.x, dy = p.y - eye.center.y
                let d = (dx * dx + dy * dy).squareRoot() / eye.lidRadius
                var z = p.z - 0.18 * eye.globeRadius * (1 - NAMath.smoothstep(0.7, 1.4, d))
                // Outside the opening the recessed shell must stay proud of
                // the globe — including under the lid cards, whose skin rows
                // vacate that area when a blink pulls them down; otherwise the
                // sclera frames the closed eye in white. Tilt-aware lid-local
                // coordinates.
                let c = cos(eye.tilt), s = sin(eye.tilt)
                let lx = dx * c + dy * s, ly = dy * c - dx * s
                let inOpening = abs(lx) < eye.openingHalfWidth && ly < Self.upperEdgeY(eye, lx: lx) && ly > Self.lowerEdgeY(eye, lx: lx)
                if !inOpening {
                    let gz = eye.globeRadius * eye.globeRadius - dx * dx - dy * dy
                    if gz > 0 { z = max(z, eye.center.z + gz.squareRoot() + 0.0008) }
                }
                mesh.vertices[i].position.z = z
            }
            mesh.tag("eyeSocket" + NativeAnimeControls.suffix(side), socket)
        }

        let mouthY = layout.mouthLineY
        for i in base..<mesh.vertexCount {
            let p = mesh.vertices[i].position
            guard p.z > 0.15 * R.z, p.y < mouthY + 0.02 * hh else { continue }
            let w = NAMath.smoothstep(mouthY + 0.02 * hh, mouthY - 0.12 * hh, p.y) * NAMath.smoothstep(0.1, 0.6, p.z / R.z)
            let lateral = 1 - NAMath.smoothstep(0.55, 0.95, abs(p.x) / R.x)
            let weight = w * lateral
            if weight > 1e-6 { handles.jawWeights.append((i, weight)) }
        }
    }

    /// UV rectangle inside the shell's front-face band that the nose and ear
    /// lofts are packed into, so face-texture paint aimed at shell regions
    /// (the scalp underlay) never lands on them.
    static let featureUVRect = (u: 0.70...0.80, v: 0.40...0.50)

    static func remapUV(_ mesh: inout BuildMesh, from first: Int, into rect: (u: ClosedRange<Double>, v: ClosedRange<Double>)) {
        for i in first..<mesh.vertexCount {
            let uv = mesh.vertices[i].uv
            mesh.vertices[i].uv = NAVec2(rect.u.lowerBound + uv.x * (rect.u.upperBound - rect.u.lowerBound),
                                         rect.v.lowerBound + uv.y * (rect.v.upperBound - rect.v.lowerBound))
        }
    }

    // MARK: Ears

    private func buildEars(_ mesh: inout BuildMesh, handles: inout HeadHandles) {
        let earY = C.y - 0.05 * hh
        let (rx, _) = NativeAnimeLayout.shellRadii(radii: R, center: C, y: earY)
        for (side, sign) in [("left", 1.0), ("right", -1.0)] {
            let sfx = NativeAnimeControls.suffix(side)
            let root = NAVec3(sign * (rx - 0.012 * hh), earY, -0.02 * hh)
            let u = NAMath.yAxis
            let v = NAMath.zAxis * sign
            func ring(_ t: Double, _ ry: Double, _ rz: Double) -> Ring {
                Ring(center: root + NAVec3(sign * t, 0, 0), u: u, v: v, ru: ry, rv: rz, region: "ear\(sfx)")
            }
            let rings = [ring(0, 0.10 * hh, 0.065 * hh), ring(0.02 * hh, 0.11 * hh, 0.07 * hh), ring(0.036 * hh, 0.08 * hh, 0.05 * hh)]
            let first = mesh.vertexCount
            mesh.loft(rings, segments: Self.earSegments, capStart: root - NAVec3(sign * 0.008 * hh, 0, 0), capEnd: root + NAVec3(sign * 0.046 * hh, 0, 0))
            Self.remapUV(&mesh, from: first, into: Self.featureUVRect)
            handles.earRoots[side] = NAVec3(sign * rx, earY, -0.02 * hh)
        }
    }

    // MARK: Nose

    private func buildNose(_ mesh: inout BuildMesh, handles: inout HeadHandles) {
        let y = layout.noseLineY
        let zBase = layout.shellZ(x: 0, y: y)
        let base = NAVec3(0, y, zBase)
        func ring(_ dz: Double, _ rx: Double, _ ry: Double) -> Ring {
            Ring(center: base + NAVec3(0, 0, dz), u: NAMath.xAxis, v: NAMath.yAxis, ru: rx, rv: ry, region: "nose")
        }
        let rings = [ring(-0.006 * hh, 0.06 * hh, 0.045 * hh), ring(0.018 * hh, 0.045 * hh, 0.035 * hh), ring(0.034 * hh, 0.028 * hh, 0.022 * hh)]
        let first = mesh.vertexCount
        mesh.loft(rings, segments: Self.noseSegments, capStart: base + NAVec3(0, 0, -0.014 * hh), capEnd: base + NAVec3(0, 0, 0.044 * hh))
        Self.remapUV(&mesh, from: first, into: Self.featureUVRect)
        handles.noseBridge = NAVec3(0, y + 0.06 * hh, layout.shellZ(x: 0, y: y + 0.06 * hh))
    }

    // MARK: Lids

    static func lidPoint(_ eye: NativeAnimeLayout.EyeParams, lx: Double, ly: Double) -> NAVec3 {
        let c = cos(eye.tilt), s = sin(eye.tilt)
        let x = lx * c - ly * s
        let y = lx * s + ly * c
        let r = eye.lidRadius
        let z = max(r * r - x * x - y * y, (0.05 * r) * (0.05 * r)).squareRoot()
        return eye.center + NAVec3(x, y, z)
    }

    static func upperEdgeY(_ eye: NativeAnimeLayout.EyeParams, lx: Double) -> Double {
        let t = min(1, abs(lx) / eye.openingHalfWidth)
        return eye.upperHeight * pow(max(0, 1 - t * t), 0.6)
    }

    static func lowerEdgeY(_ eye: NativeAnimeLayout.EyeParams, lx: Double) -> Double {
        let t = min(1, abs(lx) / eye.openingHalfWidth)
        return -eye.lowerHeight * pow(max(0, 1 - t * t), 0.8)
    }

    static let upperRootRise = 0.42
    static let lowerRootDrop = 0.55
    static let lashRow = 0.18
    static let lineRow = 0.15

    /// UV rectangle for the lid skin rows, next to `featureUVRect` in the
    /// flat-skin area: the rows' natural UVs land on the scalp underlay, so an
    /// unmapped closed lid would render hair-coloured.
    static let lidUVRect = (u: 0.82...0.90, v: 0.40...0.50)

    private func buildLids(_ prims: inout [BuildMesh], side: String, handles: inout HeadHandles) {
        let eye = layout.eyes[side]!
        let sfx = NativeAnimeControls.suffix(side)
        let K = Self.lidColumns
        handles.lidColumns = K
        var lidVertices: [LidVertex] = []

        func columnX(_ c: Int) -> Double { -eye.openingHalfWidth + 2 * eye.openingHalfWidth * Double(c) / Double(K - 1) }

        func addRow(_ prim: HeadPrimitive, row f: Double, upper: Bool, region: String) -> [Int] {
            var out: [Int] = []
            for c in 0..<K {
                let lx = columnX(c)
                let ly = upper
                    ? Self.upperEdgeY(eye, lx: lx) + f * Self.upperRootRise * eye.lidRadius
                    : Self.lowerEdgeY(eye, lx: lx) - f * Self.lowerRootDrop * eye.lidRadius
                let p = Self.lidPoint(eye, lx: lx, ly: ly)
                let uv = NAVec2(Double(c) / Double(K - 1), upper ? 0.5 - 0.5 * f : 0.5 + 0.5 * f)
                let i = prims[prim.rawValue].addVertex(p, uv: uv, pivot: eye.center, regions: [region])
                lidVertices.append(LidVertex(primitive: prim.rawValue, index: i, column: c, lx: lx, ly: ly, row: f, upper: upper))
                out.append(i)
            }
            return out
        }

        let upperRegion = "eyelidUpper\(sfx)", lowerRegion = "eyelidLower\(sfx)"
        let lashEdge = addRow(.eyelash, row: 0, upper: true, region: upperRegion)
        let lashTop = addRow(.eyelash, row: Self.lashRow, upper: true, region: upperRegion)
        prims[HeadPrimitive.eyelash.rawValue].bridge(lashEdge, lashTop)
        let skinLash = addRow(.skin, row: Self.lashRow, upper: true, region: upperRegion)
        let skinMid = addRow(.skin, row: 0.5, upper: true, region: upperRegion)
        let skinRoot = addRow(.skin, row: 1, upper: true, region: upperRegion)
        prims[HeadPrimitive.skin.rawValue].bridge(skinLash, skinMid)
        prims[HeadPrimitive.skin.rawValue].bridge(skinMid, skinRoot)

        let lineEdge = addRow(.eyeline, row: 0, upper: false, region: lowerRegion)
        let lineBottom = addRow(.eyeline, row: Self.lineRow, upper: false, region: lowerRegion)
        prims[HeadPrimitive.eyeline.rawValue].bridge(lineBottom, lineEdge)
        let skinLine = addRow(.skin, row: Self.lineRow, upper: false, region: lowerRegion)
        let skinLowerRoot = addRow(.skin, row: 1, upper: false, region: lowerRegion)
        prims[HeadPrimitive.skin.rawValue].bridge(skinLowerRoot, skinLine)

        let lidRect = Self.lidUVRect
        for i in skinLash + skinMid + skinRoot + skinLine + skinLowerRoot {
            let uv = prims[HeadPrimitive.skin.rawValue].vertices[i].uv
            prims[HeadPrimitive.skin.rawValue].vertices[i].uv = NAVec2(lidRect.u.lowerBound + uv.x * (lidRect.u.upperBound - lidRect.u.lowerBound),
                                                                       lidRect.v.lowerBound + uv.y * (lidRect.v.upperBound - lidRect.v.lowerBound))
        }

        handles.lids[side] = lidVertices
    }

    // MARK: Brows

    private func buildBrow(_ mesh: inout BuildMesh, side: String, handles: inout HeadHandles) {
        let sign = side == "left" ? 1.0 : -1.0
        let sfx = NativeAnimeControls.suffix(side)
        let lid = layout.defaultLidRadius
        let centerX = layout.defaultEyeX(sign)
        let baseY = layout.eyeLineY + 1.05 * lid
        let half = 0.65 * lid
        let thickness = 0.16 * lid
        let n = Self.browColumns
        var bottom: [Int] = []
        var top: [Int] = []
        var verts: [BrowVertex] = []
        let pivot = NAVec3(centerX, baseY, layout.shellZ(x: centerX, y: baseY))
        for j in 0..<n {
            let t = Double(j) / Double(n - 1)
            let x = centerX - half + 2 * half * t
            let innerFraction = side == "left" ? t : 1 - t
            let arch = 0.18 * lid * sin(Double.pi * innerFraction) + 0.06 * lid * innerFraction
            let yb = baseY + arch
            let b = mesh.addVertex(layout.onShell(x: x, y: yb, offset: 0.0015), uv: NAVec2(t, 1), pivot: pivot, regions: ["brow\(sfx)"])
            let tp = mesh.addVertex(layout.onShell(x: x, y: yb + thickness, offset: 0.0015), uv: NAVec2(t, 0), pivot: pivot, regions: ["brow\(sfx)"])
            bottom.append(b)
            top.append(tp)
            verts.append(BrowVertex(index: b, innerFraction: innerFraction, top: false))
            verts.append(BrowVertex(index: tp, innerFraction: innerFraction, top: true))
        }
        mesh.bridge(bottom, top)
        handles.brows[side] = verts
    }

    // MARK: Mouth

    private func buildMouth(_ mesh: inout BuildMesh, handles: inout HeadHandles) {
        let M = Self.lipColumns
        let mouthY = layout.mouthLineY
        let W = 0.085 * hh
        let hUpper = 0.022 * hh
        let hLower = 0.026 * hh
        let innerGap = 0.002 * hh
        let center = layout.onShell(x: 0, y: mouthY, offset: 0)
        handles.mouthCenter = center
        handles.mouthHalfWidth = W

        var outer: [Int] = [], inner: [Int] = [], front: [Int] = [], back: [Int] = []
        for j in 0..<M {
            let a = 2 * Double.pi * Double(j) / Double(M)
            let sa = sin(a), ca = cos(a)
            let upper = sa > 1e-9
            let corner = abs(sa) <= 1e-9
            let regions = corner ? ["lipsUpper", "lipsLower"] : [upper ? "lipsUpper" : "lipsLower"]
            let oy = (sa >= 0 ? hUpper : hLower) * sa
            let o = mesh.addVertex(layout.onShell(x: W * ca, y: mouthY + oy, offset: 0.0012), uv: NAVec2(0.5 + 0.5 * ca, 0.5 - 0.5 * sa), pivot: center, regions: regions)
            let i = mesh.addVertex(layout.onShell(x: 0.86 * W * ca, y: mouthY + innerGap * sa, offset: 0.0006), uv: NAVec2(0.5 + 0.43 * ca, 0.5 - 0.1 * sa),
                                   pivot: center, regions: regions)
            let f = mesh.addVertex(center + NAVec3(0.75 * W * ca, 0.010 * hh * sa, -0.02 * hh), uv: NAVec2(0.5 + 0.3 * ca, 0.5 - 0.3 * sa), pivot: center,
                                   regions: ["innerMouth"])
            let b = mesh.addVertex(center + NAVec3(0.5 * W * ca, 0.012 * hh * sa, -0.05 * hh), uv: NAVec2(0.5 + 0.15 * ca, 0.5 - 0.15 * sa), pivot: center,
                                   regions: ["innerMouth"])
            outer.append(o)
            inner.append(i)
            front.append(f)
            back.append(b)
            handles.lipOuter.append(LoopVertex(index: o, alpha: a))
            handles.lipInner.append(LoopVertex(index: i, alpha: a))
            handles.cavityFront.append(LoopVertex(index: f, alpha: a))
            handles.cavityBack.append(LoopVertex(index: b, alpha: a))
        }
        mesh.bridgeLoop(outer, inner)
        mesh.bridgeLoop(inner, front)
        mesh.bridgeLoop(front, back)
        let pole = mesh.addVertex(center + NAVec3(0, 0, -0.07 * hh), uv: NAVec2(0.5, 0.5), pivot: center, regions: ["innerMouth"])
        for j in 0..<M { mesh.addTri(pole, back[j], back[(j + 1) % M]) }
    }
}
