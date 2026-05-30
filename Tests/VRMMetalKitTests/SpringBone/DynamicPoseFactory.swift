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

/// Fast OSCILLATING motion clips that drive sustained SpringBone lag (#309).
///
/// Static poses settle: a limb-parented cloth chain rides rigidly with its
/// limb and reaches a fixed offset OUTSIDE the skin. Issue #309 manifestations
/// 2/3 (hair→arm, cloth→leg) are MOTION-TRANSIENT — a fast-moving limb makes
/// the trailing spring-bone cloth lag and dip into the body for a few frames,
/// then recover. These clips sweep the upper arms / upper legs through a large
/// fast arc so the inertial lag transiently drives cloth into the limb oracle.
///
/// Axes / signs mirror the static `armsRaised` (Z axis, ∓ per side) and
/// `seatedDeepFlexion` (X axis) clips in `StressPoseFactory`. The samplers are
/// continuous (sin-driven), never teleporting — physically plausible swings.
enum DynamicPoseFactory {

    private static func rot(_ deg: Float, _ axis: SIMD3<Float>) -> simd_quatf {
        simd_quatf(angle: deg * .pi / 180, axis: simd_normalize(axis))
    }

    /// Oscillates BOTH upper arms through a large fast arc about the Z axis, so
    /// each rising arm sweeps toward the hair/sleeve cloth. `armsRaised` raises
    /// the left arm with -90° and the right with +90° about Z; we sweep each
    /// arm from near-down (0°) to overhead (~110°) at `f` Hz, mirroring those
    /// signs so both arms travel up together each cycle.
    static func armSwingFast(duration: Float = 3.0, f: Float = 3.2, amplitude: Float = 62) -> AnimationClip {
        var clip = AnimationClip(duration: duration)
        let mid = amplitude           // travels 0 → 2*amplitude (≈ 0° → 110°)
        let twoPiF = 2 * Float.pi * f
        // -π/2 phase so motion starts at the bottom of the arc (angle 0).
        func angle(_ t: Float) -> Float { mid + amplitude * sin(twoPiF * t - .pi / 2) }
        clip.addJointTrack(JointTrack(bone: .leftUpperArm,
            rotationSampler: { t in rot(-angle(t), [0, 0, 1]) }))
        clip.addJointTrack(JointTrack(bone: .rightUpperArm,
            rotationSampler: { t in rot(angle(t), [0, 0, 1]) }))
        return clip
    }

    /// Oscillates BOTH upper legs forward/up fast (knee-raise march) about the
    /// X axis, so each thigh repeatedly drives up into the skirt's hang.
    /// `seatedDeepFlexion` flexes the upper legs +90° about X; we sweep each
    /// from 0° to ~95° at `f` Hz.
    static func legMarchFast(duration: Float = 3.0, f: Float = 2.0, amplitude: Float = 47.5) -> AnimationClip {
        var clip = AnimationClip(duration: duration)
        let mid = amplitude           // travels 0 → 2*amplitude (≈ 0° → 95°)
        let twoPiF = 2 * Float.pi * f
        func angle(_ t: Float) -> Float { mid + amplitude * sin(twoPiF * t - .pi / 2) }
        clip.addJointTrack(JointTrack(bone: .leftUpperLeg,
            rotationSampler: { t in rot(angle(t), [1, 0, 0]) }))
        clip.addJointTrack(JointTrack(bone: .rightUpperLeg,
            rotationSampler: { t in rot(angle(t), [1, 0, 0]) }))
        return clip
    }
}
