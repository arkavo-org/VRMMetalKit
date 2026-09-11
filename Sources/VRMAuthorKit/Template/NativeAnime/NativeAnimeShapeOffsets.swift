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

/// Calibrated shape basis: every bipolar shape key is a signed blend between
/// two authored endpoint offset sets computed from the base mesh, restricted
/// to the key's declared regions. All keys are evaluated against the same base
/// so their contributions add commutatively; a key at 0 contributes exactly nothing.
struct NativeAnimeShapeOffsets {
    let layout: NativeAnimeLayout
    let controls: NativeAnimeControlSet
    let handles: HeadHandles

    private var hh: Double { layout.headHeight }
    private var C: NAVec3 { layout.headCenter }
    private var R: NAVec3 { layout.headRadii }

    typealias Endpoint = (_ p: NAVec3, _ pivot: NAVec3) -> NAVec3

    private struct Key {
        var control: String
        var regions: [String]
        var plus: Endpoint
        var minus: Endpoint
    }

    func apply(body: inout BuildMesh, head: inout [BuildMesh]) {
        let bodyBase = body.vertices.map(\.position)
        let headBase = head.map { $0.vertices.map(\.position) }
        for key in bodyKeys() {
            let v = controls[key.control]
            guard v != 0 else { continue }
            Self.blend(&body, base: bodyBase, key: key, value: v)
        }
        for key in headKeys() {
            let v = controls[key.control]
            guard v != 0 else { continue }
            for pi in head.indices { Self.blend(&head[pi], base: headBase[pi], key: key, value: v) }
        }
        applyBrowThickness(&head[HeadPrimitive.brow.rawValue], base: headBase[HeadPrimitive.brow.rawValue])
    }

    private static func blend(_ mesh: inout BuildMesh, base: [NAVec3], key: Key, value: Double) {
        let t = abs(value)
        let endpoint = value > 0 ? key.plus : key.minus
        var touched = Set<Int>()
        for region in key.regions {
            for i in mesh.indices(in: region) where touched.insert(i).inserted {
                let p = base[i]
                let offset = endpoint(p, mesh.vertices[i].pivot) - p
                mesh.vertices[i].position += offset * t
            }
        }
    }

    private static func radial(_ sx: Double, _ sy: Double, _ sz: Double) -> Endpoint {
        { p, piv in piv + (p - piv) * NAVec3(sx, sy, sz) }
    }

    private func bodyKeys() -> [Key] {
        let limbs = NativeAnimeControls.armRegions + NativeAnimeControls.legRegions
        return [
            Key(control: "body.shape.chest", regions: ["chest"], plus: Self.radial(1.08, 1, 1.25), minus: Self.radial(0.95, 1, 0.85)),
            Key(control: "body.shape.waist", regions: ["waist"], plus: Self.radial(1.15, 1, 1.15), minus: Self.radial(0.88, 1, 0.88)),
            Key(control: "body.shape.hip", regions: ["hips"], plus: Self.radial(1.15, 1, 1.15), minus: Self.radial(0.88, 1, 0.88)),
            Key(control: "body.shape.muscle", regions: ["chest", "torso", "waist", "hips"] + limbs, plus: Self.radial(1.10, 1.10, 1.10),
                minus: Self.radial(0.92, 0.92, 0.92)),
        ]
    }

    private func headKeys() -> [Key] {
        let shell = NativeAnimeControls.headShellRegions
        let eyeLineY = layout.eyeLineY
        let jawLineY = C.y - 0.35 * hh
        let jawWeight: (NAVec3) -> Double = { p in NAMath.smoothstep(eyeLineY, jawLineY, p.y) }
        let chinWeight: (NAVec3) -> Double = { p in NAMath.smoothstep(layout.mouthLineY, C.y - 0.50 * hh, p.y) }
        var keys: [Key] = [
            Key(control: "face.head.width", regions: shell, plus: { p, _ in NAVec3(p.x * 1.08, p.y, p.z) }, minus: { p, _ in NAVec3(p.x * 0.92, p.y, p.z) }),
            Key(control: "face.head.depth", regions: shell,
                plus: { p, _ in NAVec3(p.x, p.y, p.z * (p.z < 0 ? 1.10 : 1.03)) }, minus: { p, _ in NAVec3(p.x, p.y, p.z * (p.z < 0 ? 0.90 : 0.97)) }),
            Key(control: "face.jaw.width", regions: ["face", "jaw", "chin", "earL", "earR"],
                plus: { p, _ in NAVec3(p.x * (1 + 0.10 * jawWeight(p)), p.y, p.z) }, minus: { p, _ in NAVec3(p.x * (1 - 0.10 * jawWeight(p)), p.y, p.z) }),
            Key(control: "face.chin.length", regions: ["jaw", "chin"],
                plus: { p, _ in NAVec3(p.x, p.y - 0.05 * hh * chinWeight(p), p.z) }, minus: { p, _ in NAVec3(p.x, p.y + 0.035 * hh * chinWeight(p), p.z) }),
            Key(control: "face.chin.pointedness", regions: ["jaw", "chin"],
                plus: { p, _ in NAVec3(p.x * (1 - 0.35 * chinWeight(p)), p.y, p.z) }, minus: { p, _ in NAVec3(p.x * (1 + 0.25 * chinWeight(p)), p.y, p.z) }),
            Key(control: "face.nose.height", regions: ["nose"], plus: Self.radial(1, 1.3, 1), minus: Self.radial(1, 0.7, 1)),
            Key(control: "face.nose.width", regions: ["nose"], plus: Self.radial(1.3, 1, 1), minus: Self.radial(0.7, 1, 1)),
            Key(control: "face.nose.projection", regions: ["nose"], plus: Self.radial(1, 1, 1.4), minus: Self.radial(1, 1, 0.6)),
            Key(control: "face.mouth.width", regions: ["lipsUpper", "lipsLower", "innerMouth"], plus: Self.radial(1.2, 1, 1), minus: Self.radial(0.8, 1, 1)),
            Key(control: "face.mouth.height", regions: ["lipsUpper", "lipsLower", "innerMouth"], plus: Self.radial(1, 1.25, 1), minus: Self.radial(1, 0.75, 1)),
            Key(control: "face.lip.fullness", regions: ["lipsUpper", "lipsLower"],
                plus: { p, piv in NAVec3(p.x, piv.y + (p.y - piv.y) * 1.35, p.z + 0.0005) }, minus: { p, piv in NAVec3(p.x, piv.y + (p.y - piv.y) * 0.7, p.z - 0.0003) }),
        ]
        for (side, sign) in [("left", 1.0), ("right", -1.0)] {
            let sfx = side == "left" ? "L" : "R"
            let root = handles.earRoots[side] ?? .zero
            keys.append(Key(control: NativeAnimeControls.sided("face.brow.{side}.height", side: side), regions: ["brow\(sfx)"],
                            plus: { p, _ in NAVec3(p.x, p.y + 0.02 * hh, p.z) }, minus: { p, _ in NAVec3(p.x, p.y - 0.02 * hh, p.z) }))
            keys.append(Key(control: NativeAnimeControls.sided("face.brow.{side}.angle", side: side), regions: ["brow\(sfx)"],
                            plus: { p, piv in NAMath.rotate(p, about: NAMath.zAxis, angle: sign * NAMath.degrees(15), pivot: piv) },
                            minus: { p, piv in NAMath.rotate(p, about: NAMath.zAxis, angle: -sign * NAMath.degrees(15), pivot: piv) }))
            keys.append(Key(control: NativeAnimeControls.sided("face.ear.{side}.size", side: side), regions: ["ear\(sfx)"],
                            plus: { p, _ in root + (p - root) * 1.3 }, minus: { p, _ in root + (p - root) * 0.75 }))
            keys.append(Key(control: NativeAnimeControls.sided("face.ear.{side}.angle", side: side), regions: ["ear\(sfx)"],
                            plus: { p, _ in NAMath.rotate(p, about: NAMath.yAxis, angle: -sign * NAMath.degrees(20), pivot: root) },
                            minus: { p, _ in NAMath.rotate(p, about: NAMath.yAxis, angle: sign * NAMath.degrees(20), pivot: root) }))
        }
        return keys
    }

    /// Brow thickness moves only the top row of the strip, so it needs the brow handles.
    private func applyBrowThickness(_ mesh: inout BuildMesh, base: [NAVec3]) {
        let thickness = 0.16 * layout.defaultLidRadius
        for side in ["left", "right"] {
            let v = controls.side("face.brow.{side}.thickness", side)
            guard v != 0, let verts = handles.brows[side] else { continue }
            let delta = v > 0 ? 0.6 * thickness * v : 0.5 * thickness * v
            for b in verts where b.top { mesh.vertices[b.index].position.y += delta }
        }
    }
}
