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

/// Rest-pose skeleton and anchor geometry derived from the layout controls
/// (stature, head count, proportions, eye placement). Model space is VRM 1.0:
/// +Y up, +Z forward (facing direction), +X the avatar's left. T-pose.
struct NativeAnimeLayout {
    let height: Double
    let headHeight: Double
    let headCenter: NAVec3
    let headRadii: NAVec3
    let neckLength: Double
    let hipsY: Double
    let hipJointY: Double
    let neckBaseY: Double
    let ankleY: Double
    let hipHalfWidth: Double
    let shoulderHalfWidth: Double
    let clavicleHalfWidth: Double
    let shoulderY: Double
    let upperArmLength: Double
    let lowerArmLength: Double
    let handLength: Double
    let thighLength: Double
    let shinLength: Double
    let toesForward: Double
    let controls: NativeAnimeControlSet

    /// Face landmark constants as fractions of head height (eye line, globe radius,
    /// eye pivot lateral offset as a fraction of head width, nose and mouth lines).
    static let globeRadiusFactor = 0.078
    static let eyeLineFactor = 0.11
    static let eyeSpacingFactor = 0.21
    static let noseLineFactor = 0.23
    static let mouthLineFactor = 0.34
    static var defaultLidRadiusFactor: Double { globeRadiusFactor * 1.05 }

    var eyeLineY: Double { headCenter.y - NativeAnimeLayout.eyeLineFactor * headHeight }
    var noseLineY: Double { headCenter.y - NativeAnimeLayout.noseLineFactor * headHeight }
    var mouthLineY: Double { headCenter.y - NativeAnimeLayout.mouthLineFactor * headHeight }
    var defaultLidRadius: Double { NativeAnimeLayout.defaultLidRadiusFactor * headHeight }
    func defaultEyeX(_ sign: Double) -> Double { sign * NativeAnimeLayout.eyeSpacingFactor * headRadii.x * 2 }

    /// World-space rest positions for every humanoid bone.
    let joints: [VRMHumanBone: NAVec3]

    struct EyeParams {
        var center: NAVec3
        var globeRadius: Double
        var lidRadius: Double
        var openingHalfWidth: Double
        var upperHeight: Double
        var lowerHeight: Double
        var tilt: Double
        var irisAngle: Double
        var pupilAngle: Double
        var sideSign: Double
    }

    let eyes: [String: EyeParams]

    init(controls c: NativeAnimeControlSet) {
        controls = c
        let H = c["body.heightM"]
        height = H
        let hh = H / c["body.headCount"]
        headHeight = hh
        neckLength = 0.12 * hh
        ankleY = 0.055 * H

        let legLength = c["body.proportion.legLength"]
        let torsoLength = c["body.proportion.torsoLength"]
        let bodyBelowHead = H - hh
        let legBase = 0.53 * bodyBelowHead
        let torsoBase = bodyBelowHead - neckLength - 0.04 * H - legBase
        let leg = legBase * (1 + 0.08 * legLength) - torsoBase * 0.10 * torsoLength
        hipJointY = leg
        hipsY = leg + 0.04 * H
        neckBaseY = H - hh - neckLength
        let torso = neckBaseY - hipsY

        hipHalfWidth = 0.075 * H * (1 + 0.10 * c["body.proportion.hipWidth"])
        shoulderHalfWidth = 0.115 * H * (1 + 0.12 * c["body.proportion.shoulderWidth"])
        clavicleHalfWidth = 0.035 * H
        shoulderY = neckBaseY - 0.025 * H
        let armScale = 1 + 0.10 * c["body.proportion.armLength"]
        upperArmLength = 0.155 * H * armScale
        lowerArmLength = 0.145 * H * armScale
        handLength = 0.10 * H
        let legSpan = hipJointY - ankleY
        thighLength = 0.52 * legSpan
        shinLength = 0.48 * legSpan
        toesForward = 0.085 * H

        let headBottom = H - hh
        headCenter = NAVec3(0, headBottom + hh / 2, 0)
        headRadii = NAVec3(0.41 * hh, 0.5 * hh, 0.45 * hh)

        var j: [VRMHumanBone: NAVec3] = [:]
        j[.hips] = NAVec3(0, hipsY, 0)
        j[.spine] = NAVec3(0, hipsY + 0.20 * torso, 0)
        j[.chest] = NAVec3(0, hipsY + 0.45 * torso, 0)
        j[.upperChest] = NAVec3(0, hipsY + 0.70 * torso, 0)
        j[.neck] = NAVec3(0, neckBaseY, 0)
        j[.head] = NAVec3(0, headBottom, 0)
        j[.jaw] = NAVec3(0, headBottom + 0.12 * hh, 0.28 * hh)
        for (side, sign) in [("left", 1.0), ("right", -1.0)] {
            let s = side == "left"
            let shoulder = NAVec3(sign * clavicleHalfWidth, shoulderY, 0)
            let upperArm = NAVec3(sign * shoulderHalfWidth, shoulderY, 0)
            let lowerArm = upperArm + NAVec3(sign * upperArmLength, 0, 0)
            let hand = lowerArm + NAVec3(sign * lowerArmLength, 0, 0)
            j[s ? .leftShoulder : .rightShoulder] = shoulder
            j[s ? .leftUpperArm : .rightUpperArm] = upperArm
            j[s ? .leftLowerArm : .rightLowerArm] = lowerArm
            j[s ? .leftHand : .rightHand] = hand
            let hl = handLength
            let fingerZ: [Double] = [0.012, 0.004, -0.004, -0.012].map { $0 * H }
            let fingers: [[VRMHumanBone]] = s
                ? [[.leftIndexProximal, .leftIndexIntermediate, .leftIndexDistal], [.leftMiddleProximal, .leftMiddleIntermediate, .leftMiddleDistal],
                   [.leftRingProximal, .leftRingIntermediate, .leftRingDistal], [.leftLittleProximal, .leftLittleIntermediate, .leftLittleDistal]]
                : [[.rightIndexProximal, .rightIndexIntermediate, .rightIndexDistal], [.rightMiddleProximal, .rightMiddleIntermediate, .rightMiddleDistal],
                   [.rightRingProximal, .rightRingIntermediate, .rightRingDistal], [.rightLittleProximal, .rightLittleIntermediate, .rightLittleDistal]]
            for (fi, chain) in fingers.enumerated() {
                let base = hand + NAVec3(sign * 0.50 * hl, 0, fingerZ[fi])
                j[chain[0]] = base
                j[chain[1]] = base + NAVec3(sign * 0.22 * hl, 0, 0)
                j[chain[2]] = base + NAVec3(sign * 0.40 * hl, 0, 0)
            }
            let thumbMeta = hand + NAVec3(sign * 0.15 * hl, -0.004 * H, 0.020 * H)
            j[s ? .leftThumbMetacarpal : .rightThumbMetacarpal] = thumbMeta
            j[s ? .leftThumbProximal : .rightThumbProximal] = thumbMeta + NAVec3(sign * 0.16 * hl, 0, 0.16 * hl)
            j[s ? .leftThumbDistal : .rightThumbDistal] = thumbMeta + NAVec3(sign * 0.28 * hl, 0, 0.28 * hl)

            let upperLeg = NAVec3(sign * hipHalfWidth, hipJointY, 0)
            let lowerLeg = upperLeg + NAVec3(0, -thighLength, 0)
            let foot = lowerLeg + NAVec3(0, -shinLength, 0)
            let toes = foot + NAVec3(0, -(ankleY - 0.015 * H), toesForward)
            j[s ? .leftUpperLeg : .rightUpperLeg] = upperLeg
            j[s ? .leftLowerLeg : .rightLowerLeg] = lowerLeg
            j[s ? .leftFoot : .rightFoot] = foot
            j[s ? .leftToes : .rightToes] = toes
        }

        var eyeTable: [String: EyeParams] = [:]
        for (side, sign) in [("left", 1.0), ("right", -1.0)] {
            let heightB = c.side("face.eye.{side}.height", side)
            let widthB = c.side("face.eye.{side}.width", side)
            let spacingB = c.side("face.eye.{side}.spacing", side)
            let tiltB = c.side("face.eye.{side}.tilt", side)
            let globe = NativeAnimeLayout.globeRadiusFactor * hh * (1 + 0.08 * heightB) * (1 + 0.06 * widthB)
            let lid = globe * 1.05
            let ex = sign * NativeAnimeLayout.eyeSpacingFactor * headRadii.x * 2 * (1 + 0.15 * spacingB)
            let ey = headCenter.y - NativeAnimeLayout.eyeLineFactor * hh
            let surfaceZ = NativeAnimeLayout.shellZ(radii: headRadii, center: headCenter, x: ex, y: ey)
            let center = NAVec3(ex, ey, surfaceZ - 0.6 * globe)
            let irisAngle = NAMath.degrees(15 + 30 * c.side("face.iris.{side}.size", side))
            let pupilAngle = irisAngle * (0.25 + 0.5 * c.side("face.pupil.{side}.size", side))
            eyeTable[side] = EyeParams(center: center, globeRadius: globe, lidRadius: lid,
                                       openingHalfWidth: 0.72 * lid * (1 + 0.15 * widthB),
                                       upperHeight: 0.55 * lid * (1 + 0.35 * heightB),
                                       lowerHeight: 0.35 * lid * (1 + 0.35 * heightB),
                                       tilt: NAMath.degrees(12) * tiltB * sign,
                                       irisAngle: irisAngle, pupilAngle: pupilAngle, sideSign: sign)
            j[side == "left" ? .leftEye : .rightEye] = center
        }
        eyes = eyeTable
        joints = j
    }

    /// Egg-shaped head shell radii at height `y`: narrower below the centre.
    static func shellRadii(radii: NAVec3, center: NAVec3, y: Double) -> (rx: Double, rz: Double) {
        let t = max(0, (center.y - y) / radii.y)
        return (radii.x * (1 - 0.18 * t * t), radii.z * (1 - 0.10 * t * t))
    }

    /// Front-surface z of the head shell at (x, y); 0 when outside the ellipse.
    static func shellZ(radii: NAVec3, center: NAVec3, x: Double, y: Double) -> Double {
        let (rx, rz) = shellRadii(radii: radii, center: center, y: y)
        let nx = x / rx, ny = (y - center.y) / radii.y
        let inside = 1 - nx * nx - ny * ny
        return inside > 0 ? rz * inside.squareRoot() : 0
    }

    func shellZ(x: Double, y: Double) -> Double { NativeAnimeLayout.shellZ(radii: headRadii, center: headCenter, x: x, y: y) }

    /// Point on the head's front surface at (x, y) pushed outward by `offset` along the local normal.
    func onShell(x: Double, y: Double, offset: Double) -> NAVec3 {
        let z = shellZ(x: x, y: y)
        let (rx, rz) = NativeAnimeLayout.shellRadii(radii: headRadii, center: headCenter, y: y)
        let n = NAMath.normalize(NAVec3(x / (rx * rx), (y - headCenter.y) / (headRadii.y * headRadii.y), z / (rz * rz)), fallback: NAVec3(0, 0, 1))
        return NAVec3(x, y, z) + n * offset
    }

    func joint(_ bone: VRMHumanBone) -> NAVec3 { joints[bone]! }
}
