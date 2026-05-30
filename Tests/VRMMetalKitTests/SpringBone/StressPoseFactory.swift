//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

import simd
@testable import VRMMetalKit

enum StressPose: String, CaseIterable {
    case lookUp, armsRaised, armsCrossed, seatedDeepFlexion
}

enum StressPoseFactory {
    static func clip(_ pose: StressPose, duration: Float = 4.0) -> AnimationClip {
        var clip = AnimationClip(duration: duration)
        func fixed(_ q: simd_quatf) -> ((Float) -> simd_quatf) { { _ in q } }
        func rot(_ deg: Float, _ axis: SIMD3<Float>) -> simd_quatf {
            simd_quatf(angle: deg * .pi / 180, axis: simd_normalize(axis))
        }
        switch pose {
        case .lookUp:
            clip.addJointTrack(JointTrack(bone: .head, rotationSampler: fixed(rot(-35, [1, 0, 0]))))
        case .armsRaised:
            clip.addJointTrack(JointTrack(bone: .leftUpperArm,  rotationSampler: fixed(rot(-90, [0, 0, 1]))))
            clip.addJointTrack(JointTrack(bone: .rightUpperArm, rotationSampler: fixed(rot(90, [0, 0, 1]))))
        case .armsCrossed:
            clip.addJointTrack(JointTrack(bone: .leftUpperArm,  rotationSampler: fixed(rot(75, [0, 1, 0]))))
            clip.addJointTrack(JointTrack(bone: .rightUpperArm, rotationSampler: fixed(rot(-75, [0, 1, 0]))))
        case .seatedDeepFlexion:
            clip.addJointTrack(JointTrack(bone: .leftUpperLeg,  rotationSampler: fixed(rot(90, [1, 0, 0]))))
            clip.addJointTrack(JointTrack(bone: .rightUpperLeg, rotationSampler: fixed(rot(90, [1, 0, 0]))))
        }
        return clip
    }
}
