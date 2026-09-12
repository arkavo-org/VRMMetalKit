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
    static let torsoSegments = 40
    static let limbSegments = 28
    static let handSegments = 16
    static let neckSegments = 20
    static let thumbSegments = 10

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
    /// `zc` shifts the ring centre forward, giving the torso a front/back
    /// profile (bust, waist indent, glutes) instead of a straight extrusion.
    private func yRing(_ y: Double, rx: Double, rz: Double, region: String, zc: Double = 0) -> Ring {
        Ring(center: NAVec3(0, y, zc), u: NAMath.xAxis, v: -NAMath.zAxis, ru: rx, rv: rz, region: region)
    }

    private func buildTorso(_ mesh: inout BuildMesh) {
        let y0 = layout.hipJointY - 0.02 * H
        let y1 = layout.neckBaseY
        func at(_ f: Double) -> Double { NAMath.lerp(y0, y1, f) }
        let hipW = layout.hipHalfWidth + 0.03 * H
        let shoulderW = layout.shoulderHalfWidth - 0.006 * H
        let rings = [
            yRing(at(0.00), rx: hipW * 0.86, rz: 0.058 * H, region: "hips", zc: -0.004 * H),
            yRing(at(0.12), rx: hipW * 0.94, rz: 0.068 * H, region: "hips", zc: -0.006 * H),
            yRing(at(0.26), rx: hipW * 0.84, rz: 0.058 * H, region: "waist", zc: -0.003 * H),
            yRing(at(0.42), rx: 0.064 * H, rz: 0.050 * H, region: "waist", zc: -0.002 * H),
            yRing(at(0.58), rx: 0.068 * H, rz: 0.058 * H, region: "chest", zc: 0.004 * H),
            yRing(at(0.72), rx: 0.072 * H, rz: 0.064 * H, region: "chest", zc: 0.010 * H),
            yRing(at(0.86), rx: shoulderW, rz: 0.054 * H, region: "chest", zc: 0.004 * H),
            yRing(at(0.95), rx: shoulderW * 0.80, rz: 0.048 * H, region: "torso", zc: 0.001 * H),
            yRing(at(1.00), rx: 0.046 * H, rz: 0.042 * H, region: "torso"),
        ]
        mesh.loft(rings, segments: Self.torsoSegments, capStart: NAVec3(0, y0 - 0.006 * H, -0.002 * H), capEnd: NAVec3(0, y1 + 0.01 * H, 0), extraRegions: ["torso"])
        // The cap poles sit on the axis inside the neck/hips. The top pole must
        // not join the "torso" region: garments copy regions, and a shirt ends
        // in a neck hole — covering the pole would seal it shut and, at big
        // headCounts where the pole exits the fused neck overlap, trip the
        // penetration gate on interior geometry nobody sees.
        let topPole = mesh.vertexCount - 1
        mesh.regions["torso"]?.removeAll { $0 == topPole }
        mesh.tag("torsoCap", [topPole])
    }

    private func buildNeck(_ mesh: inout BuildMesh) {
        let y0 = layout.neckBaseY - 0.02 * H
        let y1 = layout.headBottomY + 0.05 * layout.headHeight
        let r = 0.030 * H
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

    /// One loft from inside the torso to the knuckle line; regions switch at
    /// the elbow and wrist rings so garments and weights see the same names.
    private func buildArm(_ mesh: inout BuildMesh, side: String) {
        let s = side == "left" ? 1.0 : -1.0
        let sfx = NativeAnimeControls.suffix(side)
        let upper = layout.joint(side == "left" ? .leftUpperArm : .rightUpperArm)
        let lower = layout.joint(side == "left" ? .leftLowerArm : .rightLowerArm)
        let hand = layout.joint(side == "left" ? .leftHand : .rightHand)
        let y = upper.y
        let hl = layout.handLength
        func ring(_ x: Double, _ ry: Double, _ rz: Double, _ region: String) -> Ring {
            xRing(x, y: y, z: 0, ry: ry * H, rz: rz * H, sign: s, region: region + sfx)
        }
        let arm = [
            ring(upper.x - s * 0.030 * H, 0.026, 0.031, "upperArm"),
            ring(upper.x + s * 0.030 * H, 0.029, 0.030, "upperArm"),
            ring(NAMath.lerp(upper.x, lower.x, 0.55), 0.027, 0.027, "upperArm"),
            ring(lower.x - s * 0.012 * H, 0.024, 0.024, "upperArm"),
            ring(lower.x + s * 0.012 * H, 0.024, 0.024, "forearm"),
            ring(NAMath.lerp(lower.x, hand.x, 0.40), 0.023, 0.024, "forearm"),
            ring(NAMath.lerp(lower.x, hand.x, 0.80), 0.017, 0.019, "forearm"),
            ring(hand.x - s * 0.006 * H, 0.014, 0.017, "forearm"),
            ring(hand.x + s * 0.10 * hl, 0.010, 0.020, "hand"),
            ring(hand.x + s * 0.30 * hl, 0.009, 0.026, "hand"),
            ring(hand.x + s * 0.48 * hl, 0.008, 0.028, "hand"),
        ]
        mesh.loft(arm, segments: Self.limbSegments, capStart: NAVec3(upper.x - s * 0.045 * H, y, 0), capEnd: NAVec3(hand.x + s * 0.52 * hl, y, 0))
        buildFingers(&mesh, side: side)
    }

    private func buildFingers(_ mesh: inout BuildMesh, side: String) {
        let s = side == "left" ? 1.0 : -1.0
        let sfx = NativeAnimeControls.suffix(side)
        let hl = layout.handLength
        let fingerRadius: [Double] = [0.0055, 0.0058, 0.0054, 0.0047]
        for (fi, finger) in ["Index", "Middle", "Ring", "Little"].enumerated() {
            let joints = ["Proximal", "Intermediate", "Distal"].map { layout.joint(VRMHumanBone(rawValue: side + finger + $0)!) }
            let r0 = fingerRadius[fi] * H
            let dir = NAMath.normalize(joints[2] - joints[0])
            let v = NAMath.normalize(NAMath.cross(dir, NAMath.yAxis))
            func fring(_ p: NAVec3, _ r: Double) -> Ring {
                Ring(center: p, u: NAMath.yAxis, v: v, ru: r * 0.85, rv: r, region: "hand\(sfx)")
            }
            let rings = [
                fring(joints[0] - dir * (0.08 * hl), r0 * 1.15),
                fring(joints[0] - dir * (0.04 * hl), r0 * 1.15),
                fring(joints[0] + dir * (0.03 * hl), r0),
                fring(joints[1], r0 * 0.92),
                fring(joints[2], r0 * 0.80),
            ]
            mesh.loft(rings, segments: Self.thumbSegments, capStart: joints[0] - dir * (0.13 * hl), capEnd: joints[2] + dir * (0.09 * hl))
        }
        let meta = layout.joint(side == "left" ? .leftThumbMetacarpal : .rightThumbMetacarpal)
        let proximal = layout.joint(side == "left" ? .leftThumbProximal : .rightThumbProximal)
        let distal = layout.joint(side == "left" ? .leftThumbDistal : .rightThumbDistal)
        let thumbDir = NAMath.normalize(distal - meta)
        let tu = NAMath.yAxis
        let tv = NAMath.normalize(NAMath.cross(thumbDir, tu))
        func thumbRing(_ p: NAVec3, _ r: Double) -> Ring {
            Ring(center: p, u: tu, v: tv, ru: r, rv: r, region: "hand\(sfx)")
        }
        let thumb = [thumbRing(meta, 0.010 * H), thumbRing(proximal, 0.0085 * H), thumbRing(distal, 0.0065 * H)]
        mesh.loft(thumb, segments: Self.thumbSegments, capStart: meta - thumbDir * (0.012 * H), capEnd: distal + thumbDir * (0.06 * hl))
    }

    /// Ring perpendicular to -Y (loft going down): u = +X, v = +Z.
    private func downRing(_ x: Double, _ y: Double, rx: Double, rz: Double, region: String) -> Ring {
        Ring(center: NAVec3(x, y, 0), u: NAMath.xAxis, v: NAMath.zAxis, ru: rx, rv: rz, region: region)
    }

    /// One loft from inside the hips to the ankle with a knee narrowing and a
    /// calf; the end pole sits inside the foot loft.
    private func buildLeg(_ mesh: inout BuildMesh, side: String) {
        let sfx = NativeAnimeControls.suffix(side)
        let upper = layout.joint(side == "left" ? .leftUpperLeg : .rightUpperLeg)
        let lower = layout.joint(side == "left" ? .leftLowerLeg : .rightLowerLeg)
        let foot = layout.joint(side == "left" ? .leftFoot : .rightFoot)
        let x = upper.x
        func ring(_ y: Double, _ rx: Double, _ rz: Double, _ region: String) -> Ring {
            downRing(x, y, rx: rx * H, rz: rz * H, region: region + sfx)
        }
        let leg = [
            ring(upper.y + 0.035 * H, 0.045, 0.049, "thigh"),
            ring(upper.y - 0.030 * H, 0.046, 0.050, "thigh"),
            ring(NAMath.lerp(upper.y, lower.y, 0.55), 0.040, 0.043, "thigh"),
            ring(lower.y + 0.020 * H, 0.034, 0.036, "thigh"),
            ring(lower.y - 0.020 * H, 0.033, 0.035, "shin"),
            ring(NAMath.lerp(lower.y, foot.y, 0.35), 0.035, 0.040, "shin"),
            ring(NAMath.lerp(lower.y, foot.y, 0.75), 0.026, 0.028, "shin"),
            ring(foot.y + 0.005 * H, 0.019, 0.021, "shin"),
        ]
        mesh.loft(leg, segments: Self.limbSegments, capStart: NAVec3(x, upper.y + 0.050 * H, 0), capEnd: NAVec3(x, foot.y - 0.020 * H, 0))
        buildFoot(&mesh, side: side)
    }

    private func buildFoot(_ mesh: inout BuildMesh, side: String) {
        let sfx = NativeAnimeControls.suffix(side)
        let x = layout.joint(side == "left" ? .leftUpperLeg : .rightUpperLeg).x
        func footRing(_ z: Double, rx: Double, ry: Double) -> Ring {
            Ring(center: NAVec3(x, ry * H, z * H), u: NAMath.xAxis, v: NAMath.yAxis, ru: rx * H, rv: ry * H, region: "foot\(sfx)")
        }
        let footRings = [
            footRing(-0.030, rx: 0.022, ry: 0.024),
            footRing(0.000, rx: 0.026, ry: 0.030),
            footRing(0.040, rx: 0.027, ry: 0.024),
            footRing(0.080, rx: 0.028, ry: 0.016),
            footRing(0.115, rx: 0.024, ry: 0.010),
        ]
        mesh.loft(footRings, segments: Self.limbSegments, capStart: NAVec3(x, 0.022 * H, -0.040 * H), capEnd: NAVec3(x, 0.008 * H, 0.130 * H))
    }
}
