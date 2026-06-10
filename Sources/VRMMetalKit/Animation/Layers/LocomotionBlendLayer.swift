import Foundation
import simd

/// Base-pose locomotion layer (locomotion design §5): a 1-D speed blend
/// space populated with an idle entry (strideSpeed 0) and a walk entry.
/// Owns the full 0→max base pose; `IdleBreathingLayer` composes additively
/// above it and `IKLayer` (priority 4) corrects foot plant after everything.
///
/// Purity contract: output is a function of (targetSpeed, accumulated
/// sim dt, phaseOffset, clips). No clocks, no smoothing, no velocity
/// dynamics — the host's controller owns those (design §6).
public final class LocomotionBlendLayer: AnimationLayer {
    public enum LocomotionError: Error {
        case missingMetadata
        case walkStrideMustBePositive
    }

    public let identifier = "locomotion-blend"
    /// Below every existing layer: breathing 0, expression 1, lookAt 2, IK 4.
    public let priority = -10
    public var isEnabled = true
    public private(set) var affectedBones: Set<VRMHumanoidBone> = []

    /// Speed in m/s, set by the host controller. No internal smoothing.
    public var targetSpeed: Float = 0
    /// Normalized [0,1) cycle offset, seeded per-entity by the host.
    public var phaseOffset: Float = 0

    private var idleClip: AnimationClip?
    private var walkClip: AnimationClip?
    private var math: LocomotionBlendMath?
    private var idlePhase: Float = 0  // seconds into idle clip
    private var walkPhase: Float = 0  // seconds into walk clip

    public init() {}

    public func setClips(idle: AnimationClip, walk: AnimationClip) throws {
        guard idle.locomotion != nil, let walkMeta = walk.locomotion else {
            throw LocomotionError.missingMetadata
        }
        guard walkMeta.strideSpeed > 0 else { throw LocomotionError.walkStrideMustBePositive }
        idleClip = idle
        walkClip = walk
        math = LocomotionBlendMath(walkStrideSpeed: walkMeta.strideSpeed)
        affectedBones = Set(idle.jointTracks.map(\.bone)).union(walk.jointTracks.map(\.bone))
    }

    public func update(deltaTime: Float, context: AnimationContext) {
        guard let math, let idleClip, let walkClip else { return }
        let blend = math.blend(forSpeed: targetSpeed)
        idlePhase = advance(idlePhase, by: deltaTime, duration: idleClip.duration)
        walkPhase = advance(walkPhase, by: deltaTime * blend.walkRate, duration: walkClip.duration)
    }

    private func advance(_ phase: Float, by dt: Float, duration: Float) -> Float {
        guard duration > 0 else { return 0 }
        return fmodf(phase + dt, duration)
    }

    public func evaluate() -> LayerOutput {
        guard let math, let idleClip, let walkClip else { return LayerOutput() }
        let blend = math.blend(forSpeed: targetSpeed)
        var bones: [VRMHumanoidBone: ProceduralBoneTransform] = [:]

        func sample(_ clip: AnimationClip, phase: Float) -> [VRMHumanoidBone: simd_quatf] {
            var out: [VRMHumanoidBone: simd_quatf] = [:]
            let duration = max(clip.duration, 1e-5)
            let t = fmodf(phase + phaseOffset * duration, duration)
            for track in clip.jointTracks {
                if let q = track.rotationSampler?(t) { out[track.bone] = q }
            }
            return out
        }
        let idlePose = sample(idleClip, phase: idlePhase)
        let walkPose = sample(walkClip, phase: walkPhase)

        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        for bone in affectedBones {
            let qi = idlePose[bone] ?? identity
            let qw = walkPose[bone] ?? identity
            let q = simd_slerp(qi, qw, blend.walkWeight)
            bones[bone] = ProceduralBoneTransform(rotation: q)
        }
        // This layer IS the base pose for the bones it drives; additive
        // layers (breathing) stack on top of the compositor's result.
        return LayerOutput(bones: bones, morphWeights: [:], blendMode: .replace)
    }
}
