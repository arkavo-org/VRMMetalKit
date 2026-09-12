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

/// Head morph targets. `neutral` is the rest state and has no target.
public enum NativeAnimeMorphNames {
    public static let blink = "blink"
    public static let blinkLeft = "blinkLeft"
    public static let blinkRight = "blinkRight"
    public static let visemes = ["aa", "ih", "ou", "ee", "oh"]
    public static let emotions = ["happy", "angry", "sad", "relaxed", "surprised"]
    public static let all = [blink, blinkLeft, blinkRight] + visemes + emotions
}

/// Builds position-delta morph targets on the head primitives from the
/// feature handles, evaluated against the final (post-offset) geometry.
struct NativeAnimeMorphBuilder {
    let layout: NativeAnimeLayout
    let handles: HeadHandles
    let head: [BuildMesh]

    private var hh: Double { layout.headHeight }

    struct MouthShape {
        var open = 0.0
        var width = 1.0
        var pout = 0.0
        var corner = 0.0
    }

    struct LidShape {
        var upperClose = 0.0
        var lowerRise = 0.0
    }

    struct BrowShape {
        var inner = 0.0
        var outer = 0.0
    }

    struct Shape {
        var mouth = MouthShape()
        var lids: [String: LidShape] = [:]
        var brows = BrowShape()
    }

    func shapes() -> [(String, Shape)] {
        let both = ["left": LidShape(upperClose: 1), "right": LidShape(upperClose: 1)]
        return [
            (NativeAnimeMorphNames.blink, Shape(lids: both)),
            (NativeAnimeMorphNames.blinkLeft, Shape(lids: ["left": LidShape(upperClose: 1)])),
            (NativeAnimeMorphNames.blinkRight, Shape(lids: ["right": LidShape(upperClose: 1)])),
            ("aa", Shape(mouth: MouthShape(open: 0.050 * hh, width: 0.95))),
            ("ih", Shape(mouth: MouthShape(open: 0.018 * hh, width: 1.10))),
            ("ou", Shape(mouth: MouthShape(open: 0.022 * hh, width: 0.72, pout: 0.010 * hh))),
            ("ee", Shape(mouth: MouthShape(open: 0.012 * hh, width: 1.30, corner: 0.004 * hh))),
            ("oh", Shape(mouth: MouthShape(open: 0.040 * hh, width: 0.80, pout: 0.008 * hh))),
            ("happy", Shape(mouth: MouthShape(open: 0.004 * hh, width: 1.08, corner: 0.016 * hh),
                            lids: ["left": LidShape(upperClose: 0.15, lowerRise: 0.7), "right": LidShape(upperClose: 0.15, lowerRise: 0.7)],
                            brows: BrowShape(inner: 0.004 * hh, outer: 0.006 * hh))),
            ("angry", Shape(mouth: MouthShape(width: 0.92, corner: -0.012 * hh),
                            lids: ["left": LidShape(upperClose: 0.25), "right": LidShape(upperClose: 0.25)],
                            brows: BrowShape(inner: -0.020 * hh, outer: 0.004 * hh))),
            ("sad", Shape(mouth: MouthShape(width: 0.95, corner: -0.016 * hh),
                          lids: ["left": LidShape(upperClose: 0.35), "right": LidShape(upperClose: 0.35)],
                          brows: BrowShape(inner: 0.020 * hh, outer: -0.008 * hh))),
            ("relaxed", Shape(mouth: MouthShape(width: 1.02, corner: 0.010 * hh),
                              lids: ["left": LidShape(upperClose: 0.45), "right": LidShape(upperClose: 0.45)],
                              brows: BrowShape(inner: 0.006 * hh, outer: 0.006 * hh))),
            ("surprised", Shape(mouth: MouthShape(open: 0.032 * hh, width: 0.85, pout: 0.006 * hh),
                                lids: ["left": LidShape(upperClose: -0.2), "right": LidShape(upperClose: -0.2)],
                                brows: BrowShape(inner: 0.028 * hh, outer: 0.028 * hh))),
        ]
    }

    /// Per primitive, the ordered list of (name, deltas).
    func build() -> [[(String, [NAVec3])]] {
        var out = [[(String, [NAVec3])]](repeating: [], count: head.count)
        for (name, shape) in shapes() {
            var deltas = head.map { [NAVec3](repeating: .zero, count: $0.vertexCount) }
            applyLids(shape, &deltas)
            applyMouth(shape.mouth, &deltas)
            applyBrows(shape.brows, &deltas)
            for pi in head.indices { out[pi].append((name, deltas[pi])) }
        }
        return out
    }

    private func applyLids(_ shape: Shape, _ deltas: inout [[NAVec3]]) {
        for side in ["left", "right"] {
            guard let lid = shape.lids[side], let verts = handles.lids[side], let eye = layout.eyes[side] else { continue }
            for v in verts {
                let gap = NativeAnimeHeadBuilder.lowerEdgeY(eye, lx: v.lx) - NativeAnimeHeadBuilder.upperEdgeY(eye, lx: v.lx)
                let shift: Double
                if v.upper {
                    shift = (1 - v.row) * lid.upperClose * gap
                } else {
                    shift = (1 - v.row) * lid.lowerRise * -gap
                }
                guard shift != 0 else { continue }
                let target = NativeAnimeHeadBuilder.lidPoint(eye, lx: v.lx, ly: v.ly + shift)
                deltas[v.primitive][v.index] = target - head[v.primitive].vertices[v.index].position
            }
        }
    }

    private func applyMouth(_ m: MouthShape, _ deltas: inout [[NAVec3]]) {
        guard m.open != 0 || m.width != 1 || m.pout != 0 || m.corner != 0 else { return }
        let prim = HeadPrimitive.mouth.rawValue
        let mesh = head[prim]
        let cx = handles.mouthCenter.x
        func drop(_ alpha: Double, _ scale: Double) -> Double {
            let sa = sin(alpha)
            return sa < 0 ? -m.open * scale * pow(-sa, 0.7) : m.open * 0.15 * scale * pow(sa, 0.7)
        }
        func lipDelta(_ v: LoopVertex, dropScale: Double, cornerScale: Double) -> NAVec3 {
            let p = mesh.vertices[v.index].position
            let ca = cos(v.alpha)
            let dx = (p.x - cx) * (m.width - 1)
            let dy = drop(v.alpha, dropScale) + m.corner * ca * ca * cornerScale
            let dz = m.pout * (1 - abs(ca))
            return NAVec3(dx, dy, dz)
        }
        for v in handles.lipOuter { deltas[prim][v.index] += lipDelta(v, dropScale: 0.9, cornerScale: 1) }
        for v in handles.lipInner { deltas[prim][v.index] += lipDelta(v, dropScale: 1, cornerScale: 0.9) }
        for v in handles.cavityFront {
            let p = mesh.vertices[v.index].position
            deltas[prim][v.index] += NAVec3((p.x - cx) * (m.width - 1), drop(v.alpha, 0.6), 0)
        }
        for v in handles.cavityBack {
            let p = mesh.vertices[v.index].position
            deltas[prim][v.index] += NAVec3((p.x - cx) * (m.width - 1) * 0.5, drop(v.alpha, 0.3), 0)
        }
        let skin = HeadPrimitive.skin.rawValue
        for jw in handles.jawWeights { deltas[skin][jw.index] += NAVec3(0, -0.8 * m.open * jw.weight, 0) }
        for i in handles.tongue { deltas[prim][i] += NAVec3(0, -1.0 * m.open, 0) }
        // A smile raises the cheeks and pushes them slightly out and forward.
        if m.corner > 0 {
            for (side, sign) in [("left", 1.0), ("right", -1.0)] {
                for i in handles.cheeks[side] ?? [] {
                    deltas[skin][i] += NAVec3(sign * m.corner * 0.12, m.corner * 0.45, m.corner * 0.2)
                }
            }
        }
    }

    private func applyBrows(_ b: BrowShape, _ deltas: inout [[NAVec3]]) {
        guard b.inner != 0 || b.outer != 0 else { return }
        let prim = HeadPrimitive.brow.rawValue
        for side in ["left", "right"] {
            for v in handles.brows[side] ?? [] {
                deltas[prim][v.index] += NAVec3(0, NAMath.lerp(b.inner, b.outer, v.innerFraction), 0)
            }
        }
    }
}
