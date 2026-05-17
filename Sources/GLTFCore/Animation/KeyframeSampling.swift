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

/// glTF 2.0 §5.2 animation sampler interpolation modes.
public enum GLTFKeyframeInterpolation: Sendable {
    case linear
    case step
    /// Cubic spline. Output keyframes are triples `[in_tangent, value, out_tangent]`
    /// per the spec; sampled via the Hermite formula with tangent values pre-scaled
    /// by the keyframe interval `Δt`.
    case cubicSpline
}

// MARK: - Keyframe interval lookup

/// Binary-search for the keyframe interval enclosing `time`, returning the
/// lower index and the in-interval `[0, 1]` fraction.
///
/// Clamps to the domain endpoints — `time ≤ times[0]` returns `(0, 0)`,
/// `time ≥ times.last` returns `(count - 1, 1)`. Empty `times` returns
/// `(0, 0)`. The returned index is safe to address `times[index]` and
/// `times[index + 1]` provided `times.count >= 2`.
@inlinable
public func gltfFindKeyframeInterval(times: [Float], at time: Float) -> (index: Int, frac: Float) {
    if times.isEmpty { return (0, 0) }
    if time <= times.first! { return (0, 0) }
    if time >= times.last! { return (times.count - 1, 1) }

    var lo = 0
    var hi = times.count - 1
    while hi - lo > 1 {
        let mid = (lo + hi) / 2
        if times[mid] <= time { lo = mid } else { hi = mid }
    }
    let interval = max(times[hi] - times[lo], 1e-6)
    let frac = (time - times[lo]) / interval
    return (lo, frac)
}

// MARK: - Vector3 sampler (translation, scale)

/// Sample a glTF vec3 sampler (`translation` / `scale` channel targets, plus
/// any other 3-component data). All three interpolation modes supported.
@inlinable
public func gltfSampleVector3(
    times: [Float],
    values: [Float],
    interpolation: GLTFKeyframeInterpolation,
    at time: Float
) -> SIMD3<Float> {
    guard !times.isEmpty else { return SIMD3<Float>(0, 0, 0) }
    let (index, frac) = gltfFindKeyframeInterval(times: times, at: time)

    switch interpolation {
    case .step:
        return readVec3Value(values: values, keyIndex: index, interpolation: .step)
    case .linear:
        let v0 = readVec3Value(values: values, keyIndex: index, interpolation: .linear)
        if index + 1 >= times.count { return v0 }
        let v1 = readVec3Value(values: values, keyIndex: index + 1, interpolation: .linear)
        return mix(v0, v1, t: frac)
    case .cubicSpline:
        let v0 = readVec3Value(values: values, keyIndex: index, interpolation: .cubicSpline)
        if index + 1 >= times.count { return v0 }
        let next = index + 1
        let dt = max(times[next] - times[index], 1e-6)
        let v1 = readVec3Value(values: values, keyIndex: next, interpolation: .cubicSpline)
        let outTan0 = readVec3Tangent(values: values, keyIndex: index, isOut: true)
        let inTan1 = readVec3Tangent(values: values, keyIndex: next, isOut: false)
        let m0 = outTan0 * dt
        let m1 = inTan1 * dt
        return hermite(v0, m0, v1, m1, frac)
    }
}

// MARK: - Quaternion sampler (rotation)

/// Sample a glTF quaternion sampler. Uses `simd_slerp` with shortest-arc
/// fixup for LINEAR; Hermite + shortest-arc fixup + renormalisation for
/// CUBICSPLINE. This is the spec-correct rotation path — lerp+renormalize
/// produces visible artifacts on long-arc interpolations and should not be
/// used.
@inlinable
public func gltfSampleQuaternion(
    times: [Float],
    values: [Float],
    interpolation: GLTFKeyframeInterpolation,
    at time: Float
) -> simd_quatf {
    guard !times.isEmpty else { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
    let (index, frac) = gltfFindKeyframeInterval(times: times, at: time)

    switch interpolation {
    case .step:
        return readQuaternion(values: values, keyIndex: index, interpolation: .step)
    case .linear:
        let q0 = readQuaternion(values: values, keyIndex: index, interpolation: .linear)
        if index + 1 >= times.count { return q0 }
        var q1 = readQuaternion(values: values, keyIndex: index + 1, interpolation: .linear)
        // Shortest-arc fixup so slerp goes the short way around.
        if simd_dot(q0.vector, q1.vector) < 0 {
            q1 = simd_quatf(vector: -q1.vector)
        }
        return simd_normalize(simd_slerp(q0, q1, frac))
    case .cubicSpline:
        let v0 = readVec4Value(values: values, keyIndex: index, interpolation: .cubicSpline)
        if index + 1 >= times.count {
            return simd_normalize(simd_quatf(ix: v0[0], iy: v0[1], iz: v0[2], r: v0[3]))
        }
        let next = index + 1
        let dt = max(times[next] - times[index], 1e-6)
        var v1 = readVec4Value(values: values, keyIndex: next, interpolation: .cubicSpline)
        var inTan1 = readVec4Tangent(values: values, keyIndex: next, isOut: false)
        let outTan0 = readVec4Tangent(values: values, keyIndex: index, isOut: true)

        // Shortest-arc fixup on both the next value AND its in-tangent so
        // the Hermite curve follows the short path. Mirrors the convention
        // used by Three.js, Filament, and the Khronos reference renderer.
        if simd_dot(v0, v1) < 0 {
            v1 = -v1
            inTan1 = -inTan1
        }

        let m0 = outTan0 * dt
        let m1 = inTan1 * dt
        let h = hermite(v0, m0, v1, m1, frac)
        return simd_normalize(simd_quatf(ix: h[0], iy: h[1], iz: h[2], r: h[3]))
    }
}

// MARK: - Float-array sampler (morph weights, generic N-component data)

/// Sample a generic N-component float-array sampler. Used for morph weights
/// (`weights` channel target) and any other multi-scalar animation data
/// that doesn't deserve per-component vector math.
///
/// LINEAR is per-component lerp. STEP holds the previous keyframe.
/// CUBICSPLINE applies the Hermite formula per component using the
/// in/out tangent triples stored per the glTF spec.
@inlinable
public func gltfSampleFloatArray(
    times: [Float],
    values: [Float],
    interpolation: GLTFKeyframeInterpolation,
    components: Int,
    at time: Float
) -> [Float] {
    guard components > 0 else { return [] }
    guard !times.isEmpty else { return Array(repeating: 0, count: components) }

    let (index, frac) = gltfFindKeyframeInterval(times: times, at: time)

    let stride = (interpolation == .cubicSpline) ? components * 3 : components
    let valueOffset = (interpolation == .cubicSpline) ? components : 0

    @inline(__always)
    func value(_ keyIndex: Int) -> [Float] {
        let base = keyIndex * stride + valueOffset
        var out = [Float](repeating: 0, count: components)
        for c in 0..<components {
            let idx = base + c
            if idx < values.count { out[c] = values[idx] }
        }
        return out
    }

    @inline(__always)
    func tangent(_ keyIndex: Int, isOut: Bool) -> [Float] {
        // CUBICSPLINE layout per keyframe: [in_tangent, value, out_tangent].
        let base = keyIndex * stride + (isOut ? 2 * components : 0)
        var out = [Float](repeating: 0, count: components)
        for c in 0..<components {
            let idx = base + c
            if idx < values.count { out[c] = values[idx] }
        }
        return out
    }

    switch interpolation {
    case .step:
        return value(index)
    case .linear:
        let v0 = value(index)
        if index + 1 >= times.count { return v0 }
        let v1 = value(index + 1)
        var out = [Float](repeating: 0, count: components)
        for c in 0..<components {
            out[c] = v0[c] * (1 - frac) + v1[c] * frac
        }
        return out
    case .cubicSpline:
        let v0 = value(index)
        if index + 1 >= times.count { return v0 }
        let next = index + 1
        let dt = max(times[next] - times[index], 1e-6)
        let v1 = value(next)
        let outTan0 = tangent(index, isOut: true)
        let inTan1 = tangent(next, isOut: false)

        let u = frac
        let u2 = u * u
        let u3 = u2 * u
        let a =  2*u3 - 3*u2 + 1
        let b =      u3 - 2*u2 + u
        let c = -2*u3 + 3*u2
        let d =      u3 -   u2

        var out = [Float](repeating: 0, count: components)
        for k in 0..<components {
            out[k] = a * v0[k] + b * dt * outTan0[k] + c * v1[k] + d * dt * inTan1[k]
        }
        return out
    }
}

// MARK: - Private helpers

/// Hermite spline interpolation: `p(t) = h00·p0 + h10·m0 + h01·p1 + h11·m1`
/// where `m0`/`m1` are tangent vectors *already scaled* by the keyframe Δt.
@usableFromInline
internal func hermite<V>(_ p0: V, _ m0: V, _ p1: V, _ m1: V, _ t: Float) -> V
where V: SIMD, V.Scalar == Float {
    let t2 = t * t
    let t3 = t2 * t
    let h00 = 2 * t3 - 3 * t2 + 1
    let h10 = t3 - 2 * t2 + t
    let h01 = -2 * t3 + 3 * t2
    let h11 = t3 - t2
    return h00 * p0 + h10 * m0 + h01 * p1 + h11 * m1
}

@usableFromInline
internal func readVec3Value(values: [Float], keyIndex: Int, interpolation: GLTFKeyframeInterpolation) -> SIMD3<Float> {
    let stride = (interpolation == .cubicSpline) ? 9 : 3
    let valueOffset = (interpolation == .cubicSpline) ? 3 : 0
    let base = keyIndex * stride + valueOffset
    guard base + 3 <= values.count else { return SIMD3<Float>(0, 0, 0) }
    return SIMD3<Float>(values[base], values[base + 1], values[base + 2])
}

@usableFromInline
internal func readVec3Tangent(values: [Float], keyIndex: Int, isOut: Bool) -> SIMD3<Float> {
    let stride = 9  // cubic-spline triples: 3 floats × 3 segments
    let base = keyIndex * stride + (isOut ? 6 : 0)
    guard base + 3 <= values.count else { return SIMD3<Float>(0, 0, 0) }
    return SIMD3<Float>(values[base], values[base + 1], values[base + 2])
}

@usableFromInline
internal func readQuaternion(values: [Float], keyIndex: Int, interpolation: GLTFKeyframeInterpolation) -> simd_quatf {
    let v = readVec4Value(values: values, keyIndex: keyIndex, interpolation: interpolation)
    return simd_normalize(simd_quatf(ix: v[0], iy: v[1], iz: v[2], r: v[3]))
}

@usableFromInline
internal func readVec4Value(values: [Float], keyIndex: Int, interpolation: GLTFKeyframeInterpolation) -> SIMD4<Float> {
    let stride = (interpolation == .cubicSpline) ? 12 : 4
    let valueOffset = (interpolation == .cubicSpline) ? 4 : 0
    let base = keyIndex * stride + valueOffset
    guard base + 4 <= values.count else { return SIMD4<Float>(0, 0, 0, 1) }
    return SIMD4<Float>(values[base], values[base + 1], values[base + 2], values[base + 3])
}

@usableFromInline
internal func readVec4Tangent(values: [Float], keyIndex: Int, isOut: Bool) -> SIMD4<Float> {
    let stride = 12  // cubic-spline triples: 4 floats × 3 segments
    let base = keyIndex * stride + (isOut ? 8 : 0)
    guard base + 4 <= values.count else { return SIMD4<Float>(0, 0, 0, 0) }
    return SIMD4<Float>(values[base], values[base + 1], values[base + 2], values[base + 3])
}
