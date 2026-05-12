//
// Copyright 2025 Arkavo
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

/// Time-keyed clip of joint, node, morph, and expression samplers driven by an ``AnimationPlayer``.
///
/// ## Discussion
/// An `AnimationClip` is a pure value type that bundles four kinds of tracks
/// sampled by closure at a given time:
///
/// - ``jointTracks`` target humanoid bones via ``VRMHumanoidBone``. These
///   carry the already-retargeted rotation / translation samplers produced by
///   ``VRMAnimationLoader`` (or hand-authored via ``addEulerTrack(bone:axis:sample:)``).
/// - ``nodeTracks`` target arbitrary non-humanoid nodes (hair, bust,
///   accessories) resolved by name at playback time via
///   `VRMModel.findNodeByNormalizedName`.
/// - ``morphTracks`` carry per-frame weights for expression names (resolved
///   to a ``VRMExpressionPreset`` when possible, otherwise applied as a
///   custom expression).
/// - ``expressionTracks`` are the typed equivalent of morph tracks for
///   recognised presets and are emitted alongside the morph track entry by
///   the loader so existing consumers keep working.
///
/// The clip is otherwise dumb: it stores ``duration`` and a closure per
/// track. Coordinate-space conversion and rest-pose retargeting are baked
/// into the closures at load time by ``VRMAnimationLoader``.
public struct AnimationClip {
    /// Total clip duration in seconds, derived from the maximum input time across all samplers.
    public let duration: Float
    /// Humanoid-bone tracks keyed by ``VRMHumanoidBone``.
    public var jointTracks: [JointTrack] = []
    /// Morph-weight tracks keyed by expression name (preset raw value or custom name).
    public var morphTracks: [MorphTrack] = []
    /// Non-humanoid node tracks (hair, bust, accessories) resolved by name at playback time.
    public var nodeTracks: [NodeTrack] = []
    /// Typed expression tracks for recognised ``VRMExpressionPreset`` values.
    public var expressionTracks: [ExpressionTrack] = []
    /// Returns the head-bone-local look-at target position at the given time, or `nil` when the
    /// source VRMA file did not contain a `lookAt` block (per VRMC_vrm_animation-1.0).
    /// (internal: B1 spec compliance)
    public var lookAtTargetSampler: ((Float) -> SIMD3<Float>)?

    /// Creates an empty clip with the given duration in seconds.
    public init(duration: Float) {
        self.duration = duration
    }

    /// Appends a humanoid-bone track.
    public mutating func addJointTrack(_ track: JointTrack) {
        jointTracks.append(track)
    }

    /// Appends a morph-weight track.
    public mutating func addMorphTrack(_ track: MorphTrack) {
        morphTracks.append(track)
    }

    /// Appends a non-humanoid node track.
    public mutating func addNodeTrack(_ track: NodeTrack) {
        nodeTracks.append(track)
    }

    /// Builds and appends a rotation-only humanoid track that rotates `bone` about a single euler `axis`.
    ///
    /// Convenience used by hand-authored clips (see ``AnimationLibrary``);
    /// the supplied `sample` closure returns the rotation angle in radians at
    /// each time.
    public mutating func addEulerTrack(bone: VRMHumanoidBone, axis: EulerAxis, sample: @escaping (Float) -> Float) {
        let track = JointTrack(
            bone: bone,
            rotationSampler: { time in
                let angle = sample(time)
                switch axis {
                case .x:
                    return simd_quatf(angle: angle, axis: simd_float3(1, 0, 0))
                case .y:
                    return simd_quatf(angle: angle, axis: simd_float3(0, 1, 0))
                case .z:
                    return simd_quatf(angle: angle, axis: simd_float3(0, 0, 1))
                }
            }
        )
        jointTracks.append(track)
    }

    /// Appends a morph-weight track from a sampler closure.
    public mutating func addMorphTrack(key: String, sample: @escaping (Float) -> Float) {
        morphTracks.append(MorphTrack(key: key, sampler: sample))
    }

    /// Appends a typed expression track for a recognised ``VRMExpressionPreset``.
    public mutating func addExpressionTrack(_ track: ExpressionTrack) {
        expressionTracks.append(track)
    }
}

/// Per-humanoid-bone animation track with optional rotation, translation, and scale samplers.
public struct JointTrack {
    /// The humanoid bone this track drives.
    public let bone: VRMHumanoidBone
    /// Closure returning the bone's local rotation at a given time, or `nil` if rotation is not animated.
    public let rotationSampler: ((Float) -> simd_quatf)?
    /// Closure returning the bone's local translation at a given time, or `nil` if translation is not animated.
    public let translationSampler: ((Float) -> simd_float3)?
    /// Closure returning the bone's local scale at a given time, or `nil` if scale is not animated.
    public let scaleSampler: ((Float) -> simd_float3)?

    /// Creates a track for the given bone. Any sampler omitted as `nil` is left untouched at playback time.
    public init(
        bone: VRMHumanoidBone,
        rotationSampler: ((Float) -> simd_quatf)? = nil,
        translationSampler: ((Float) -> simd_float3)? = nil,
        scaleSampler: ((Float) -> simd_float3)? = nil
    ) {
        self.bone = bone
        self.rotationSampler = rotationSampler
        self.translationSampler = translationSampler
        self.scaleSampler = scaleSampler
    }

    /// Samples all configured channels at `time`. Channels with no sampler return `nil`.
    public func sample(at time: Float) -> (rotation: simd_quatf?, translation: simd_float3?, scale: simd_float3?) {
        return (
            rotation: rotationSampler?(time),
            translation: translationSampler?(time),
            scale: scaleSampler?(time)
        )
    }
}

/// Morph-weight track identified by expression name (preset raw value or custom).
public struct MorphTrack {
    /// Expression key (e.g. `"happy"`, `"aa"`, or a custom expression name).
    public let key: String
    /// Closure returning the morph weight in [0, 1] at a given time.
    public let sampler: (Float) -> Float

    /// Creates a morph track for `key`.
    public init(key: String, sampler: @escaping (Float) -> Float) {
        self.key = key
        self.sampler = sampler
    }

    /// Samples the weight at `time`.
    public func sample(at time: Float) -> Float {
        return sampler(time)
    }
}

/// Typed expression track keyed by a recognised ``VRMExpressionPreset``.
///
/// Emitted by ``VRMAnimationLoader`` in parallel with a matching ``MorphTrack``
/// when a VRMC_vrm_animation expression resolves to a preset name. Consumers
/// that prefer the typed enum may use this; consumers that key by string may
/// keep using ``MorphTrack``.
public struct ExpressionTrack {
    /// The standardised expression preset this track drives.
    public let expression: VRMExpressionPreset
    /// Closure returning the expression weight in [0, 1] at a given time.
    public let sampler: (Float) -> Float

    /// Creates an expression track for the given preset.
    public init(expression: VRMExpressionPreset, sampler: @escaping (Float) -> Float) {
        self.expression = expression
        self.sampler = sampler
    }

    /// Samples the expression weight at `time`.
    public func sample(at time: Float) -> Float {
        return sampler(time)
    }
}

/// Animation track for arbitrary nodes that are not part of the humanoid skeleton.
///
/// Used for hair, bust, and accessory bones that are matched by name rather
/// than by ``VRMHumanoidBone``. The loader also stores a lowercased,
/// punctuation-stripped form in ``nodeNameNormalized`` so the player can
/// resolve targets via `VRMModel.findNodeByNormalizedName` without repeating
/// the normalisation work each frame.
public struct NodeTrack {
    /// The original node name from the VRMA file.
    public let nodeName: String
    /// `nodeName` lowercased with `_` and `.` stripped, for resilient name matching at playback time.
    public let nodeNameNormalized: String
    /// Closure returning the node's local rotation at a given time, or `nil` if rotation is not animated.
    public let rotationSampler: ((Float) -> simd_quatf)?
    /// Closure returning the node's local translation at a given time, or `nil` if translation is not animated.
    public let translationSampler: ((Float) -> simd_float3)?
    /// Closure returning the node's local scale at a given time, or `nil` if scale is not animated.
    public let scaleSampler: ((Float) -> simd_float3)?

    /// Creates a node track for `nodeName`. The normalised form is computed once at construction.
    public init(
        nodeName: String,
        rotationSampler: ((Float) -> simd_quatf)? = nil,
        translationSampler: ((Float) -> simd_float3)? = nil,
        scaleSampler: ((Float) -> simd_float3)? = nil
    ) {
        self.nodeName = nodeName
        self.nodeNameNormalized = nodeName.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ".", with: "")
        self.rotationSampler = rotationSampler
        self.translationSampler = translationSampler
        self.scaleSampler = scaleSampler
    }

    /// Samples all configured channels at `time`. Channels with no sampler return `nil`.
    public func sample(at time: Float) -> (rotation: simd_quatf?, translation: simd_float3?, scale: simd_float3?) {
        return (
            rotation: rotationSampler?(time),
            translation: translationSampler?(time),
            scale: scaleSampler?(time)
        )
    }
}

/// Euler axis for single-axis rotation tracks built via ``AnimationClip/addEulerTrack(bone:axis:sample:)``.
public enum EulerAxis {
    /// Rotate about the local X axis.
    case x
    /// Rotate about the local Y axis.
    case y
    /// Rotate about the local Z axis.
    case z
}
