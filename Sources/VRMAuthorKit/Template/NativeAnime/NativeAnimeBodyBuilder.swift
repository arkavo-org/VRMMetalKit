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

/// Lofted low-poly body: torso, neck, arms with mitt hands, legs and feet.
/// Every part is a closed loft that overlaps into its parent volume.
struct NativeAnimeBodyBuilder {
    static let torsoSegments = 24
    static let limbSegments = 16
    static let handSegments = 12
    static let neckSegments = 14
    static let thumbSegments = 8

    let layout: NativeAnimeLayout

    func build() -> BuildMesh {
        var mesh = BuildMesh()
        buildTorso(&mesh)
        buildNeck(&mesh)
        for side in ["left", "right"] {
            buildArm(&mesh, side: side)
            buildLeg(&mesh, side: side)
        }
        return mesh
    }

    private var H: Double { layout.height }

    /// Ring in a plane perpendicular to +Y (loft going up): u = +X, v = -Z.
    private func yRing(_ y: Double, rx: Double, rz: Double, region: String) -> Ring {
        Ring(center: NAVec3(0, y, 0), u: NAMath.xAxis, v: -NAMath.zAxis, ru: rx, rv: rz, region: region)
    }

    private func buildTorso(_ mesh: inout BuildMesh) {
        let y0 = layout.hipJointY - 0.02 * H
        let y1 = layout.neckBaseY
        func at(_ f: Double) -> Double { NAMath.lerp(y0, y1, f) }
        let hipW = layout.hipHalfWidth + 0.03 * H
        let shoulderW = layout.shoulderHalfWidth - 0.01 * H
        let rings = [
            yRing(at(0.00), rx: hipW * 0.90, rz: 0.058 * H, region: "hips"),
            yRing(at(0.12), rx: hipW, rz: 0.065 * H, region: "hips"),
            yRing(at(0.26), rx: hipW * 0.86, rz: 0.058 * H, region: "waist"),
            yRing(at(0.42), rx: 0.075 * H, rz: 0.055 * H, region: "waist"),
            yRing(at(0.58), rx: 0.080 * H, rz: 0.064 * H, region: "chest"),
            yRing(at(0.72), rx: 0.086 * H, rz: 0.066 * H, region: "chest"),
            yRing(at(0.86), rx: shoulderW, rz: 0.058 * H, region: "chest"),
            yRing(at(0.95), rx: shoulderW * 0.75, rz: 0.050 * H, region: "torso"),
            yRing(at(1.00), rx: 0.055 * H, rz: 0.046 * H, region: "torso"),
        ]
        mesh.loft(rings, segments: Self.torsoSegments, capStart: NAVec3(0, y0 - 0.025 * H, 0), capEnd: NAVec3(0, y1 + 0.01 * H, 0), extraRegions: ["torso"])
    }

    private func buildNeck(_ mesh: inout BuildMesh) {
        let y0 = layout.neckBaseY - 0.02 * H
        let y1 = layout.headBottomY + 0.05 * layout.headHeight
        let r = 0.040 * H
        let rings = [
            yRing(y0, rx: r * 1.15, rz: r * 1.1, region: "neck"),
            yRing(NAMath.lerp(y0, y1, 0.5), rx: r, rz: r * 0.95, region: "neck"),
            yRing(y1, rx: r, rz: r * 0.95, region: "neck"),
        ]
        mesh.loft(rings, segments: Self.neckSegments, capStart: NAVec3(0, y0 - 0.01 * H, 0), capEnd: NAVec3(0, y1 + 0.01 * H, 0))
    }

    /// Ring perpendicular to the X axis, lofting outward along `sign * X`.
    private func xRing(_ x: Double, y: Double, z: Double, ry: Double, rz: Double, sign: Double, region: String) -> Ring {
        Ring(center: NAVec3(x, y, z), u: NAMath.yAxis, v: NAMath.zAxis * sign, ru: ry, rv: rz, region: region)
    }

    private func buildArm(_ mesh: inout BuildMesh, side: String) {
        let s = side == "left" ? 1.0 : -1.0
        let sfx = NativeAnimeControls.suffix(side)
        let upper = layout.joint(side == "left" ? .leftUpperArm : .rightUpperArm)
        let lower = layout.joint(side == "left" ? .leftLowerArm : .rightLowerArm)
        let hand = layout.joint(side == "left" ? .leftHand : .rightHand)
        let y = upper.y

        let ua = [
            xRing(upper.x - s * 0.035 * H, y: y, z: 0, ry: 0.040 * H, rz: 0.040 * H, sign: s, region: "upperArm\(sfx)"),
            xRing(upper.x + s * 0.03 * H, y: y, z: 0, ry: 0.036 * H, rz: 0.036 * H, sign: s, region: "upperArm\(sfx)"),
            xRing(NAMath.lerp(upper.x, lower.x, 0.6), y: y, z: 0, ry: 0.031 * H, rz: 0.031 * H, sign: s, region: "upperArm\(sfx)"),
            xRing(lower.x, y: y, z: 0, ry: 0.027 * H, rz: 0.027 * H, sign: s, region: "upperArm\(sfx)"),
        ]
        mesh.loft(ua, segments: Self.limbSegments, capStart: NAVec3(upper.x - s * 0.05 * H, y, 0), capEnd: NAVec3(lower.x + s * 0.01 * H, y, 0))

        let la = [
            xRing(lower.x - s * 0.005 * H, y: y, z: 0, ry: 0.028 * H, rz: 0.028 * H, sign: s, region: "forearm\(sfx)"),
            xRing(NAMath.lerp(lower.x, hand.x, 0.3), y: y, z: 0, ry: 0.026 * H, rz: 0.027 * H, sign: s, region: "forearm\(sfx)"),
            xRing(NAMath.lerp(lower.x, hand.x, 0.7), y: y, z: 0, ry: 0.020 * H, rz: 0.022 * H, sign: s, region: "forearm\(sfx)"),
            xRing(hand.x, y: y, z: 0, ry: 0.014 * H, rz: 0.019 * H, sign: s, region: "forearm\(sfx)"),
        ]
        mesh.loft(la, segments: Self.limbSegments, capStart: NAVec3(lower.x - s * 0.015 * H, y, 0), capEnd: NAVec3(hand.x + s * 0.008 * H, y, 0))

        let hl = layout.handLength
        let palm = [
            xRing(hand.x, y: y, z: 0, ry: 0.013 * H, rz: 0.021 * H, sign: s, region: "hand\(sfx)"),
            xRing(hand.x + s * 0.25 * hl, y: y, z: 0, ry: 0.012 * H, rz: 0.029 * H, sign: s, region: "hand\(sfx)"),
            xRing(hand.x + s * 0.45 * hl, y: y, z: 0, ry: 0.011 * H, rz: 0.031 * H, sign: s, region: "hand\(sfx)"),
        ]
        mesh.loft(palm, segments: Self.handSegments, capStart: NAVec3(hand.x - s * 0.005 * H, y, 0), capEnd: NAVec3(hand.x + s * 0.56 * hl, y, 0))

        // Four finger lofts along the rig's finger chains; the "hand" region's
        // allowed-bone set already includes the finger bones, and the tighter
        // hand sigma in bodySkinning binds each finger to its own chain.
        let fingerRadius: [Double] = [0.0068, 0.0073, 0.0068, 0.0056]
        for (fi, finger) in ["Index", "Middle", "Ring", "Little"].enumerated() {
            let joints = ["Proximal", "Intermediate", "Distal"].map { layout.joint(VRMHumanBone(rawValue: side + finger + $0)!) }
            let r0 = fingerRadius[fi] * H
            let dir = NAMath.normalize(joints[2] - joints[1])
            func fring(_ p: NAVec3, _ r: Double) -> Ring {
                Ring(center: p, u: NAMath.yAxis, v: NAMath.zAxis * s, ru: r, rv: r, region: "hand\(sfx)")
            }
            let rings = [
                fring(joints[0] - NAMath.xAxis * (s * 0.06 * hl), r0 * 1.1),
                fring(joints[0], r0),
                fring(joints[1], r0 * 0.88),
                fring(joints[2], r0 * 0.72),
            ]
            mesh.loft(rings, segments: Self.thumbSegments, capStart: joints[0] - NAMath.xAxis * (s * 0.11 * hl), capEnd: joints[2] + dir * (0.10 * hl))
        }

        let thumbBase = NAVec3(hand.x + s * 0.22 * hl, y - 0.002 * H, 0.018 * H)
        let thumbDir = NAMath.normalize(NAVec3(s * 0.45, 0, 1))
        let tu = NAMath.yAxis
        let tv = NAMath.normalize(NAMath.cross(thumbDir, tu))
        func thumbRing(_ t: Double, _ r: Double) -> Ring {
            Ring(center: thumbBase + thumbDir * t, u: tu, v: tv, ru: r, rv: r, region: "hand\(sfx)")
        }
        let thumb = [thumbRing(0, 0.010 * H), thumbRing(0.22 * hl, 0.0085 * H), thumbRing(0.40 * hl, 0.006 * H)]
        mesh.loft(thumb, segments: Self.thumbSegments, capStart: thumbBase - thumbDir * (0.01 * H), capEnd: thumbBase + thumbDir * (0.45 * hl))
    }

    /// Ring perpendicular to -Y (loft going down): u = +X, v = +Z.
    private func downRing(_ x: Double, _ y: Double, rx: Double, rz: Double, region: String) -> Ring {
        Ring(center: NAVec3(x, y, 0), u: NAMath.xAxis, v: NAMath.zAxis, ru: rx, rv: rz, region: region)
    }

    private func buildLeg(_ mesh: inout BuildMesh, side: String) {
        let sfx = NativeAnimeControls.suffix(side)
        let upper = layout.joint(side == "left" ? .leftUpperLeg : .rightUpperLeg)
        let lower = layout.joint(side == "left" ? .leftLowerLeg : .rightLowerLeg)
        let foot = layout.joint(side == "left" ? .leftFoot : .rightFoot)
        let x = upper.x

        let thigh = [
            downRing(x, upper.y + 0.035 * H, rx: 0.047 * H, rz: 0.050 * H, region: "thigh\(sfx)"),
            downRing(x, upper.y - 0.03 * H, rx: 0.049 * H, rz: 0.052 * H, region: "thigh\(sfx)"),
            downRing(x, NAMath.lerp(upper.y, lower.y, 0.6), rx: 0.041 * H, rz: 0.043 * H, region: "thigh\(sfx)"),
            downRing(x, lower.y, rx: 0.036 * H, rz: 0.038 * H, region: "thigh\(sfx)"),
        ]
        mesh.loft(thigh, segments: Self.limbSegments, capStart: NAVec3(x, upper.y + 0.05 * H, 0), capEnd: NAVec3(x, lower.y - 0.01 * H, 0))

        let shin = [
            downRing(x, lower.y + 0.005 * H, rx: 0.037 * H, rz: 0.039 * H, region: "shin\(sfx)"),
            downRing(x, NAMath.lerp(lower.y, foot.y, 0.3), rx: 0.036 * H, rz: 0.040 * H, region: "shin\(sfx)"),
            downRing(x, NAMath.lerp(lower.y, foot.y, 0.7), rx: 0.028 * H, rz: 0.030 * H, region: "shin\(sfx)"),
            downRing(x, foot.y, rx: 0.024 * H, rz: 0.026 * H, region: "shin\(sfx)"),
        ]
        mesh.loft(shin, segments: Self.limbSegments, capStart: NAVec3(x, lower.y + 0.015 * H, 0), capEnd: NAVec3(x, foot.y - 0.012 * H, 0))

        func footRing(_ z: Double, rx: Double, ry: Double) -> Ring {
            Ring(center: NAVec3(x, ry, z), u: NAMath.xAxis, v: NAMath.yAxis, ru: rx, rv: ry, region: "foot\(sfx)")
        }
        let footRings = [
            footRing(-0.032 * H, rx: 0.026 * H, ry: 0.026 * H),
            footRing(0.0, rx: 0.030 * H, ry: 0.031 * H),
            footRing(0.045 * H, rx: 0.032 * H, ry: 0.026 * H),
            footRing(0.085 * H, rx: 0.031 * H, ry: 0.019 * H),
            footRing(0.115 * H, rx: 0.025 * H, ry: 0.013 * H),
        ]
        mesh.loft(footRings, segments: Self.limbSegments, capStart: NAVec3(x, 0.024 * H, -0.042 * H), capEnd: NAVec3(x, 0.012 * H, 0.128 * H))
    }
}
