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

/// Identifies one of the four legs of a quadruped.
public enum LegID: String, Sendable, CaseIterable {
    case frontLeft
    case frontRight
    case rearLeft
    case rearRight
}

/// Bone lengths of one leg, in meters.
public struct LegSegmentLengths: Sendable, Equatable {
    /// Hip pivot → knee pivot.
    public var upper: Float
    /// Knee pivot → ankle pivot.
    public var lower: Float
    /// Ankle pivot → paw contact point.
    public var paw: Float

    public init(upper: Float, lower: Float, paw: Float) {
        self.upper = upper
        self.lower = lower
        self.paw = paw
    }
}

/// Tunable parameters of a ``QuadrupedGaitEngine``.
public struct GaitParameters: Sendable, Equatable {
    /// Ground distance covered by one stride at ``referenceSpeed``, in meters.
    public var strideLength: Float
    /// Paw lift height during the swing phase, in meters.
    public var stepHeight: Float
    /// Strides per second at ``referenceSpeed``.
    public var strideFrequency: Float
    /// Speed (m/s) at which ``strideLength`` and ``strideFrequency`` apply.
    /// Both stride amplitude and phase advance scale linearly with
    /// `speed / referenceSpeed`, clamped to `[0, 1]`.
    public var referenceSpeed: Float
    /// Vertical body bob amplitude (m), oscillating at 2× stride frequency.
    public var bodyBobAmplitude: Float
    /// Body roll amplitude (rad) over the hips during trot.
    public var bodyRollAmplitude: Float
    /// Body pitch per unit of longitudinal acceleration (rad per m/s²) in
    /// drive mode — positive values squat the tail under acceleration.
    public var drivePitchPerAccel: Float
    /// Body roll per unit of steering input in `[-1, 1]` (rad) in drive mode.
    public var driveRollPerSteering: Float
    /// Duration (s) of drive ↔ walk mode transitions.
    public var transitionDuration: Float
    /// Drive-wheel radius (m). Converts linear speed to wheel spin rate.
    public var wheelRadius: Float
    /// Vertical distance from each hip pivot down to the ground plane (m)
    /// when the body is at standing height. The ground plane used by the
    /// foot-fall clamp for a leg is `hipOffset.y - standingHeight` in body
    /// space.
    public var standingHeight: Float

    public init(
        strideLength: Float = 0.8,
        stepHeight: Float = 0.15,
        strideFrequency: Float = 1.6,
        referenceSpeed: Float = 2.0,
        bodyBobAmplitude: Float = 0.02,
        bodyRollAmplitude: Float = 0.03,
        drivePitchPerAccel: Float = 0.02,
        driveRollPerSteering: Float = 0.1,
        transitionDuration: Float = 0.4,
        wheelRadius: Float = 0.15,
        standingHeight: Float = 0.8
    ) {
        self.strideLength = strideLength
        self.stepHeight = stepHeight
        self.strideFrequency = strideFrequency
        self.referenceSpeed = referenceSpeed
        self.bodyBobAmplitude = bodyBobAmplitude
        self.bodyRollAmplitude = bodyRollAmplitude
        self.drivePitchPerAccel = drivePitchPerAccel
        self.driveRollPerSteering = driveRollPerSteering
        self.transitionDuration = transitionDuration
        self.wheelRadius = wheelRadius
        self.standingHeight = standingHeight
    }
}

/// Rotation state of one leg's joints.
///
/// `hip`, `knee` and `ankle` are rotations about each joint's local X axis
/// (the lateral axis): hip swings the leg, knee flexes it (positive flex
/// lifts the paw), ankle compensates to keep the paw level.
public struct LegJointPose: Sendable, Equatable {
    public var hip: simd_quatf
    public var knee: simd_quatf
    public var ankle: simd_quatf
    /// Accumulated drive-wheel spin (rad). Not interpolated during mode
    /// transitions — it freezes in walk and resumes in drive.
    public var wheelSpinAngle: Float

    public init(
        hip: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
        knee: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
        ankle: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
        wheelSpinAngle: Float = 0
    ) {
        self.hip = hip
        self.knee = knee
        self.ankle = ankle
        self.wheelSpinAngle = wheelSpinAngle
    }

    /// Convenience initializer building local-X rotations from angles (rad).
    public init(hipAngle: Float, kneeAngle: Float, ankleAngle: Float, wheelSpinAngle: Float = 0) {
        self.init(
            hip: simd_quatf(angle: hipAngle, axis: SIMD3<Float>(1, 0, 0)),
            knee: simd_quatf(angle: kneeAngle, axis: SIMD3<Float>(1, 0, 0)),
            ankle: simd_quatf(angle: ankleAngle, axis: SIMD3<Float>(1, 0, 0)),
            wheelSpinAngle: wheelSpinAngle
        )
    }
}

/// Locomotion mode of a ``QuadrupedGaitEngine``.
public enum LocomotionMode: Sendable, Equatable {
    /// Wheeled driving: legs hold the tucked pose, wheels spin with speed.
    case drive
    /// Legged walking: diagonal-pair trot, wheels frozen.
    case walk
}

/// Procedural quadruped gait / wheel-drive pose generator.
///
/// Pure math: no Metal, no glTF — feed the output poses to your renderer or
/// scene graph (see `QuadrupedRigController` for a GLTFMetalKit adapter).
///
/// ## Conventions
/// - Body space: +Y up, +Z forward, +X left-to-right lateral.
/// - All joint rotations are about the local X (lateral) axis; the leg chain
///   is forward-kinematics'd in the sagittal (Y/Z) plane. A leg with all
///   joint angles zero points straight down from its hip pivot.
/// - Trot pairing: ``LegID/frontLeft`` + ``LegID/rearRight`` share phase 0;
///   ``LegID/frontRight`` + ``LegID/rearLeft`` share phase π.
/// - Foot height: 2-bone IK pushes the paw up to a phase-dependent height
///   on the ground plane (`hipOffset.y - GaitParameters/standingHeight`).
///   Stance (`cos(phase) ≤ 0`) plants at the ground; swing lifts by
///   ``GaitParameters/stepHeight`` at mid-swing. The body and hip pivots
///   are never translated. Unreachable targets clamp to full extension.
public struct QuadrupedGaitEngine {
    /// Per-leg segment lengths supplied at init.
    public let segments: [LegID: LegSegmentLengths]
    /// Per-leg hip pivot positions in body space supplied at init.
    public let hipOffsets: [LegID: SIMD3<Float>]
    /// Legs whose authored joint chains swing the opposite world direction
    /// for the same local joint angle (e.g. X-mirrored geometry). Their
    /// computed walk angles are negated so the engine's diagonal-pair trot
    /// stays diagonal in world space. Mirroring is longitudinal (Z); the
    /// vertical ground clamp is unaffected. `tuckedPose` is supplied in
    /// asset space, so it is used as-is.
    public let mirroredLegs: Set<LegID>
    /// Active gait parameters.
    public var parameters: GaitParameters

    /// 0 = fully tucked (drive), 1 = fully deployed (walk). Animates over
    /// ``GaitParameters/transitionDuration`` after a mode change.
    public private(set) var transitionBlend: Float

    /// Normalized tucked (drive) pose per leg.
    private let tuckedPose: [LegID: LegJointPose]
    /// Master stride phase in radians, advancing in walk mode.
    private var phase: Float = 0
    /// Accumulated wheel spin per leg (rad).
    private var wheelAngles: [LegID: Float]
    /// Latest computed walk-cycle joint angles (hip, knee, ankle) per leg.
    private var walkAngles: [LegID: (hip: Float, knee: Float, ankle: Float)]
    /// Most recent steering input, for drive-mode body roll.
    private var lastSteering: Float = 0
    /// Most recent acceleration input, for drive-mode body pitch.
    private var lastAcceleration: Float = 0

    /// Creates an engine. `segments`, `tuckedPose` and `hipOffsets` must
    /// contain an entry for every ``LegID`` (precondition).
    public init(
        segments: [LegID: LegSegmentLengths],
        tuckedPose: [LegID: LegJointPose],
        hipOffsets: [LegID: SIMD3<Float>],
        parameters: GaitParameters,
        mirroredLegs: Set<LegID> = []
    ) {
        for leg in LegID.allCases {
            precondition(segments[leg] != nil, "segments missing \(leg)")
            precondition(tuckedPose[leg] != nil, "tuckedPose missing \(leg)")
            precondition(hipOffsets[leg] != nil, "hipOffsets missing \(leg)")
        }
        self.segments = segments
        self.hipOffsets = hipOffsets
        self.parameters = parameters
        self.mirroredLegs = mirroredLegs
        self.tuckedPose = tuckedPose.mapValues { pose in
            LegJointPose(
                hip: Self.sanitized(pose.hip),
                knee: Self.sanitized(pose.knee),
                ankle: Self.sanitized(pose.ankle),
                wheelSpinAngle: pose.wheelSpinAngle
            )
        }
        self.wheelAngles = Dictionary(uniqueKeysWithValues: LegID.allCases.map { ($0, Float(0)) })
        self.walkAngles = Dictionary(uniqueKeysWithValues: LegID.allCases.map { ($0, (0, 0, 0)) })
        self.transitionBlend = 0
    }

    /// Advances the simulation.
    ///
    /// - Parameters:
    ///   - deltaTime: Elapsed time in seconds.
    ///   - speed: Forward speed in m/s. Negative walk speeds are clamped to
    ///     zero (no reverse gait).
    ///   - steering: Steering input in `[-1, 1]`; drives body roll in
    ///     ``LocomotionMode/drive``.
    ///   - acceleration: Longitudinal acceleration in m/s²; drives body
    ///     pitch in ``LocomotionMode/drive``.
    ///   - mode: Target locomotion mode. Changes animate ``transitionBlend``.
    public mutating func update(
        deltaTime: Float,
        speed: Float,
        steering: Float,
        acceleration: Float,
        mode: LocomotionMode
    ) {
        lastSteering = steering
        lastAcceleration = acceleration

        // Mode transition blend.
        let duration = max(parameters.transitionDuration, 1e-6)
        let target: Float = mode == .walk ? 1 : 0
        if transitionBlend < target {
            transitionBlend = min(target, transitionBlend + deltaTime / duration)
        } else if transitionBlend > target {
            transitionBlend = max(target, transitionBlend - deltaTime / duration)
        }

        // Normalized speed factor shared by phase advance and amplitudes.
        let referenceSpeed = max(parameters.referenceSpeed, 1e-6)
        let speedNorm = min(max(speed / referenceSpeed, 0), 1)

        switch mode {
        case .drive:
            let radius = max(parameters.wheelRadius, 1e-6)
            for leg in LegID.allCases {
                wheelAngles[leg, default: 0] += speed / radius * deltaTime
            }
        case .walk:
            phase += 2 * Float.pi * parameters.strideFrequency * speedNorm * deltaTime
            phase = phase.truncatingRemainder(dividingBy: 2 * Float.pi)
        }

        computeWalkAngles(speedNorm: speedNorm)
    }

    /// Current joint poses for all four legs: the tucked pose slerped toward
    /// the live gait pose by smoothstep(``transitionBlend``). Wheel spin is
    /// passed through unblended.
    public func jointPoses() -> [LegID: LegJointPose] {
        let t = transitionBlend
        let alpha = t * t * (3 - 2 * t)
        var result: [LegID: LegJointPose] = [:]
        for leg in LegID.allCases {
            let tucked = tuckedPose[leg] ?? LegJointPose()
            let angles = walkAngles[leg] ?? (0, 0, 0)
            let xAxis = SIMD3<Float>(1, 0, 0)
            let gaitHip = simd_quatf(angle: angles.hip, axis: xAxis)
            let gaitKnee = simd_quatf(angle: angles.knee, axis: xAxis)
            let gaitAnkle = simd_quatf(angle: angles.ankle, axis: xAxis)
            result[leg] = LegJointPose(
                hip: Self.blend(tucked.hip, gaitHip, alpha),
                knee: Self.blend(tucked.knee, gaitKnee, alpha),
                ankle: Self.blend(tucked.ankle, gaitAnkle, alpha),
                wheelSpinAngle: wheelAngles[leg] ?? 0
            )
        }
        return result
    }

    /// Current body offset pose. Drive contributes pitch (acceleration) and
    /// roll (steering); walk contributes 2×-frequency bob and stride-frequency
    /// roll. The two are linearly blended by smoothstep(``transitionBlend``).
    public func bodyPose() -> (pitch: Float, roll: Float, bobY: Float) {
        let t = transitionBlend
        let alpha = t * t * (3 - 2 * t)
        let drivePitch = -parameters.drivePitchPerAccel * lastAcceleration
        let driveRoll = -parameters.driveRollPerSteering * lastSteering
        let walkRoll = parameters.bodyRollAmplitude * sin(phase)
        let walkBob = parameters.bodyBobAmplitude * sin(2 * phase)
        return (
            pitch: drivePitch * (1 - alpha),
            roll: driveRoll * (1 - alpha) + walkRoll * alpha,
            bobY: walkBob * alpha
        )
    }

    // MARK: - Walk cycle

    /// Recomputes the walk-cycle joint angles for every leg, including the
    /// foot-fall ground clamp.
    private mutating func computeWalkAngles(speedNorm: Float) {
        for leg in LegID.allCases {
            guard let seg = segments[leg] else { continue }
            // Diagonal trot pairing: FL+RR at phase 0, FR+RL at phase π.
            let legPhase = phase + ((leg == .frontRight || leg == .rearLeft) ? Float.pi : 0)

            let reach = max(seg.upper + seg.lower, 1e-6)
            let swingAmplitude = (parameters.strideLength * 0.5 * speedNorm) / reach
            var hip = swingAmplitude * sin(legPhase)

            // Knee flex lifts the paw during the swing half (paw moving
            // forward), peaking mid-swing.
            let liftAmplitude = min(max(parameters.stepHeight * speedNorm / max(seg.lower, 1e-6), 0), 1.2)
            var knee = liftAmplitude * max(0, cos(legPhase))

            // Ankle counter-rotates so the paw segment stays level.
            var ankle = -(hip + knee)

            applyGroundClamp(
                leg: leg, seg: seg, legPhase: legPhase, speedNorm: speedNorm,
                hip: &hip, knee: &knee, ankle: &ankle
            )

            // Mirrored chains: negate all joint angles. Vertical clamp
            // results carry over — paw Y depends only on angle magnitudes
            // (cos is even).
            if mirroredLegs.contains(leg) {
                hip = -hip
                knee = -knee
                ankle = -ankle
            }
            walkAngles[leg] = (hip, knee, ankle)
        }
    }

    /// Pushes the paw up to a phase-dependent height: ground during stance,
    /// `ground + stepHeight` at mid-swing. Only lifts — a paw already above
    /// the target (short legs / high standing height) is left on the sinusoid.
    /// Ankle stays level. Targets beyond leg reach clamp to full extension.
    private func applyGroundClamp(
        leg: LegID,
        seg: LegSegmentLengths,
        legPhase: Float,
        speedNorm: Float,
        hip: inout Float,
        knee: inout Float,
        ankle: inout Float
    ) {
        guard let hipOffset = hipOffsets[leg] else { return }
        // Degenerate segment lengths can't be IK-solved.
        guard seg.upper > 1e-6, seg.lower > 1e-6 else { return }

        let groundY = hipOffset.y - parameters.standingHeight
        // Swing envelope matches the knee-lift sinusoid: cos > 0 is swing.
        let lift = max(0, cos(legPhase))
        let targetPawY = groundY + max(parameters.stepHeight, 0) * speedNorm * lift

        // Sagittal-plane FK (angles measured from straight-down, positive
        // swinging toward +Z). Segment direction: (z: sin θ, y: -cos θ).
        let kneeY = hipOffset.y - seg.upper * cos(hip)
        let kneeZ = hipOffset.z + seg.upper * sin(hip)
        let ankleAngle = hip + knee
        let ankleY = kneeY - seg.lower * cos(ankleAngle)
        let ankleZ = kneeZ + seg.lower * sin(ankleAngle)
        let pawAngle = ankleAngle + ankle
        let pawY = ankleY - seg.paw * cos(pawAngle)
        let pawZ = ankleZ + seg.paw * sin(pawAngle)

        guard pawY < targetPawY else { return }

        // Keep the paw's longitudinal position; the ankle sits one paw-length
        // above the target (paw stays level).
        let targetZ = pawZ
        let targetY = targetPawY + seg.paw

        let dz = targetZ - hipOffset.z
        let dyDown = hipOffset.y - targetY  // positive when target below hip
        var d = sqrt(dz * dz + dyDown * dyDown)
        let u = seg.upper
        let l = seg.lower
        // Unreachable → clamp to full extension; folded singularity avoided.
        d = min(max(d, abs(u - l) + 1e-6), u + l)

        // Closed-form 2-bone solve (law of cosines). Positive knee flex.
        let beta = atan2(dz, dyDown)
        let cosDelta = min(max((u * u + d * d - l * l) / (2 * u * d), -1), 1)
        let delta = acos(cosDelta)
        let cosGamma = min(max((u * u + l * l - d * d) / (2 * u * l), -1), 1)
        let gamma = acos(cosGamma)

        hip = beta - delta
        knee = Float.pi - gamma
        ankle = -(hip + knee)
    }

    // MARK: - Quaternion helpers

    /// Slerp with exact endpoint short-circuits and hemisphere correction.
    private static func blend(_ a: simd_quatf, _ b: simd_quatf, _ alpha: Float) -> simd_quatf {
        if alpha <= 0 { return a }
        if alpha >= 1 { return b }
        var to = b
        if simd_dot(a.vector, b.vector) < 0 {
            to = simd_quatf(ix: -b.vector.x, iy: -b.vector.y, iz: -b.vector.z, r: -b.vector.w)
        }
        return simd_normalize(simd_slerp(a, to, alpha))
    }

    /// Normalizes user-supplied quaternions, mapping degenerate input to identity.
    private static func sanitized(_ q: simd_quatf) -> simd_quatf {
        let length = simd_length(q.vector)
        guard length > 1e-6, length.isFinite else {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        return simd_normalize(q)
    }
}
