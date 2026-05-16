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
public struct GLTFRuntimeSampler: Sendable {
    public let times: [Float]
    /// Flat array of N keyframes × components-per-keyframe floats. For
    /// translation/scale that's 3 per keyframe; for rotation it's 4; for
    /// weights N (the mesh's morph-target count). CUBICSPLINE: triple.
    public let values: [Float]
    public let interpolation: GLTFAnimationInterpolation
    /// Components per keyframe — NOT multiplied by the cubic-spline triple.
    public let componentsPerKeyframe: Int

    /// Sample at time `t`, clamped to the sampler's domain. Returns
    /// `componentsPerKeyframe` floats. For empty samplers returns an
    /// all-zero array of the right size.
    public func sample(at t: Float) -> [Float] {
        guard !times.isEmpty else {
            return Array(repeating: 0, count: componentsPerKeyframe)
        }
        if t <= times.first! {
            return Self.readKeyframe(values: values, index: 0, components: componentsPerKeyframe, interpolation: interpolation)
        }
        if t >= times.last! {
            return Self.readKeyframe(values: values, index: times.count - 1, components: componentsPerKeyframe, interpolation: interpolation)
        }

        // Binary search for the keyframe interval (i, i+1) where times[i] <= t < times[i+1].
        var lo = 0, hi = times.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if times[mid] <= t { lo = mid } else { hi = mid }
        }
        let i = lo
        let t0 = times[i]
        let t1 = times[i + 1]
        let interval = max(t1 - t0, 1e-6)
        let u = (t - t0) / interval

        let v0 = Self.readKeyframe(values: values, index: i, components: componentsPerKeyframe, interpolation: interpolation)
        let v1 = Self.readKeyframe(values: values, index: i + 1, components: componentsPerKeyframe, interpolation: interpolation)

        switch interpolation {
        case .step:
            return v0
        case .linear:
            // For rotation (quaternion, components == 4), we want slerp. We
            // detect it on the caller's side via componentsPerKeyframe == 4
            // and shortest-arc; here we lerp + renormalize, which is the
            // common spec-permitted shortcut for short intervals.
            var out = [Float](repeating: 0, count: componentsPerKeyframe)
            for c in 0..<componentsPerKeyframe {
                out[c] = v0[c] * (1 - u) + v1[c] * u
            }
            if componentsPerKeyframe == 4 {
                let len = sqrt(out[0]*out[0] + out[1]*out[1] + out[2]*out[2] + out[3]*out[3])
                if len > 1e-6 {
                    for c in 0..<4 { out[c] /= len }
                }
            }
            return out
        case .cubicSpline:
            // CUBICSPLINE storage per keyframe: [in_tangent, value, out_tangent], each `components` floats.
            // Hermite formula: p(t) = (2u³ - 3u² + 1) p0 + (u³ - 2u² + u) Δ·m0 + (-2u³ + 3u²) p1 + (u³ - u²) Δ·m1
            let m0 = Self.readKeyframeTangent(values: values, index: i, components: componentsPerKeyframe, isOut: true)
            let m1 = Self.readKeyframeTangent(values: values, index: i + 1, components: componentsPerKeyframe, isOut: false)
            let p0 = v0
            let p1 = v1
            let u2 = u * u
            let u3 = u2 * u
            let a =  2*u3 - 3*u2 + 1
            let b =      u3 - 2*u2 + u
            let c = -2*u3 + 3*u2
            let d =      u3 -   u2
            let dt = interval
            var out = [Float](repeating: 0, count: componentsPerKeyframe)
            for k in 0..<componentsPerKeyframe {
                out[k] = a * p0[k] + b * dt * m0[k] + c * p1[k] + d * dt * m1[k]
            }
            if componentsPerKeyframe == 4 {
                let len = sqrt(out[0]*out[0] + out[1]*out[1] + out[2]*out[2] + out[3]*out[3])
                if len > 1e-6 {
                    for k in 0..<4 { out[k] /= len }
                }
            }
            return out
        }
    }

    private static func readKeyframe(
        values: [Float], index: Int, components: Int, interpolation: GLTFAnimationInterpolation
    ) -> [Float] {
        let stride = (interpolation == .cubicSpline) ? components * 3 : components
        let valueStart = index * stride + (interpolation == .cubicSpline ? components : 0)
        var out = [Float](repeating: 0, count: components)
        for c in 0..<components {
            let idx = valueStart + c
            if idx < values.count { out[c] = values[idx] }
        }
        return out
    }

    private static func readKeyframeTangent(
        values: [Float], index: Int, components: Int, isOut: Bool
    ) -> [Float] {
        let stride = components * 3
        let tangentStart = index * stride + (isOut ? 2 * components : 0)
        var out = [Float](repeating: 0, count: components)
        for c in 0..<components {
            let idx = tangentStart + c
            if idx < values.count { out[c] = values[idx] }
        }
        return out
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
