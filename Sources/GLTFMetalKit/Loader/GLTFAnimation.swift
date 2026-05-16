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

/// glTF 2.0 animation interpolation modes.
public enum GLTFAnimationInterpolation: Sendable {
    case linear
    case step
    /// Cubic spline. Output arrays are 3× longer than time arrays — each
    /// keyframe is (in-tangent, value, out-tangent). Sampling uses the
    /// Hermite formula from the spec.
    case cubicSpline

    init(rawString: String?) {
        switch rawString {
        case "STEP":         self = .step
        case "CUBICSPLINE":  self = .cubicSpline
        default:             self = .linear  // glTF default
        }
    }
}

/// Animatable property on a glTF node.
public enum GLTFAnimationProperty: Sendable {
    case translation  // SIMD3<Float>
    case rotation     // SIMD4<Float> quaternion (x, y, z, w)
    case scale        // SIMD3<Float>
    case weights      // [Float] — morph target weights (Phase 3b morphs)
}

/// One sampler: time array (keyframe inputs) + value array (keyframe outputs)
/// + interpolation rule. The number of floats per keyframe value depends on
/// the target property and the interpolation mode (cubic spline triples).
///
/// Sampling delegates to the stateless helpers in
/// `GLTFCore/Animation/KeyframeSampling.swift` (`gltfSampleVector3`,
/// `gltfSampleQuaternion`, `gltfSampleFloatArray`). Use the typed methods
/// when the channel target is known (rotation gets true slerp instead of
/// lerp+renormalize); the legacy `[Float]`-returning `sample(at:)` is
/// preserved for callers that don't dispatch by property.
public struct GLTFRuntimeSampler: Sendable {
    public let times: [Float]
    /// Flat array of N keyframes × components-per-keyframe floats. For
    /// translation/scale that's 3 per keyframe; for rotation it's 4; for
    /// weights N (the mesh's morph-target count). CUBICSPLINE: triple.
    public let values: [Float]
    public let interpolation: GLTFAnimationInterpolation
    /// Components per keyframe — NOT multiplied by the cubic-spline triple.
    public let componentsPerKeyframe: Int

    /// Sample at time `t` as a generic float array. Returns
    /// `componentsPerKeyframe` floats. This path uses **per-component lerp**
    /// for LINEAR — correct for translation, scale, and weights. Rotation
    /// channels should call ``sampleAsQuaternion(at:)`` instead so they
    /// get true slerp.
    public func sample(at t: Float) -> [Float] {
        gltfSampleFloatArray(
            times: times,
            values: values,
            interpolation: interpolation.asGLTFCore,
            components: componentsPerKeyframe,
            at: t
        )
    }

    /// Sample at time `t` as a 3-component vector — translation/scale channels.
    public func sampleAsVector3(at t: Float) -> SIMD3<Float> {
        gltfSampleVector3(
            times: times,
            values: values,
            interpolation: interpolation.asGLTFCore,
            at: t
        )
    }

    /// Sample at time `t` as a quaternion — rotation channel. Uses
    /// `simd_slerp` for LINEAR (not lerp+renormalize) so long-arc
    /// interpolations don't drift away from the great-circle path.
    public func sampleAsQuaternion(at t: Float) -> simd_quatf {
        gltfSampleQuaternion(
            times: times,
            values: values,
            interpolation: interpolation.asGLTFCore,
            at: t
        )
    }
}

private extension GLTFAnimationInterpolation {
    /// Bridge to the GLTFCore-side enum used by the keyframe-sampling helpers.
    /// Kept as a one-way adapter so this kit's public API stays stable while
    /// the shared math lives in GLTFCore.
    var asGLTFCore: GLTFKeyframeInterpolation {
        switch self {
        case .linear:      return .linear
        case .step:        return .step
        case .cubicSpline: return .cubicSpline
        }
    }
}

/// One animation channel: ties a sampler to a target (node + property).
public struct GLTFRuntimeChannel: Sendable {
    public let targetNode: Int
    public let property: GLTFAnimationProperty
    public let sampler: GLTFRuntimeSampler
}

/// A glTF animation clip — a name and a set of channels.
public struct GLTFAnimationClip: Sendable {
    public let name: String?
    public let channels: [GLTFRuntimeChannel]
    /// Largest time value across all this clip's sampler `times` arrays.
    /// Useful for loop-back time normalization.
    public let duration: Float
}
