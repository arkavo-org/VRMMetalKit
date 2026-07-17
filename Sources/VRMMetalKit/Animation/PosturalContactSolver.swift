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

/// Tuning for the postural yield (design §5). Uniform across avatars in v1
/// (per-avatar mass/scale weighting is a deferred non-goal).
public struct PosturalContactParams: Sendable {
    /// Lean angle (radians) per metre of chest penetration into the partner torso.
    public var kGain: Float
    /// Safety clamp on the lean angle (radians) so the spine can't break awkwardly.
    public var maxLeanAngle: Float
    /// Exponential approach rate (no overshoot): yield speed on contact +
    /// recovery speed on separation. Larger = firmer/faster.
    public var stiffness: Float
    /// Overall layer weight 0–1 (mirrors ``IKLayer/ikBlendWeight``).
    public var blendWeight: Float

    /// Defaults calibrated for the contemplative crowd register (design §5); tune
    /// `kGain`/`maxLeanAngle` against `bodyContactMargin` in the visual spike.
    public init(kGain: Float = 3.0,
                maxLeanAngle: Float = 0.45,   // ~26°
                stiffness: Float = 8.0,
                blendWeight: Float = 1.0) {
        self.kGain = kGain
        self.maxLeanAngle = maxLeanAngle
        self.stiffness = stiffness
        self.blendWeight = blendWeight
    }
}

/// The pure, deterministic core of the postural yield (design §3 A/B/C):
/// chest-vs-partner-torso penetration → target lean → exponential-approach
/// smoothing. Metal-free and model-free so the yield behaviour is unit-testable
/// in isolation; ``PosturalContactLayer`` wraps it with the model/stack plumbing.
public struct PosturalContactSolver: Sendable {
    public var params: PosturalContactParams
    /// Layer state carried across frames: the currently-applied lean (`q_active`).
    /// Eases toward the target on contact and back to identity on separation.
    public private(set) var lean: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    public init(params: PosturalContactParams = PosturalContactParams()) {
        self.params = params
    }

    /// **A.** Penetration of `point` (this avatar's chest) into the partner torso
    /// capsule `[capsuleP0, capsuleP1]` of the given `radius`. Returns the overlap
    /// `depth` (`0` when the point is outside) and the outward `pushDir` (unit,
    /// from the capsule axis toward the point — i.e. away from the partner).
    public static func penetration(point: SIMD3<Float>,
                                   capsuleP0: SIMD3<Float>, capsuleP1: SIMD3<Float>,
                                   radius: Float) -> (depth: Float, pushDir: SIMD3<Float>) {
        let axis = capsuleP1 - capsuleP0
        let axisLenSq = simd_length_squared(axis)
        let t = axisLenSq > 0 ? simd_clamp(simd_dot(point - capsuleP0, axis) / axisLenSq, 0, 1) : 0
        let closest = capsuleP0 + t * axis
        let delta = point - closest
        let dist = simd_length(delta)
        let depth = max(0, radius - dist)
        // Degenerate (point on the axis): no well-defined outward direction.
        let pushDir = dist > 1e-6 ? delta / dist : SIMD3<Float>(0, 0, 0)
        return (depth, pushDir)
    }

    /// **B.** Target lean rotation for a given penetration `depth` and outward
    /// `pushDir`. `θ = clamp(kGain·depth, 0, maxLeanAngle)`; the axis
    /// `cross(spineUp, pushDir)` tips the top of the spine along `pushDir` — away
    /// from the partner. Identity when `depth == 0` or the geometry is degenerate.
    public static func targetLean(depth: Float, pushDir: SIMD3<Float>, spineUp: SIMD3<Float>,
                                  params: PosturalContactParams) -> simd_quatf {
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        guard depth > 0 else { return identity }
        let theta = min(params.kGain * depth, params.maxLeanAngle)
        let rawAxis = simd_cross(spineUp, pushDir)
        let axisLen = simd_length(rawAxis)
        guard theta > 0, axisLen > 1e-6 else { return identity }
        return simd_quatf(angle: theta, axis: rawAxis / axisLen)
    }

    /// **A+B+C.** Advance one frame: recompute the target lean from the partner
    /// torso capsule and this chest position, then ease `lean` toward it —
    /// `slerp(lean, target, min(stiffness·dt, 1))`, an exponential approach
    /// (no overshoot). Returns the updated `lean`. When the chest no longer
    /// penetrates, the target is identity and `lean` decays back to identity.
    @discardableResult
    public mutating func update(partnerTorso: CapsuleCollider, chestWorld: SIMD3<Float>,
                                spineUp: SIMD3<Float>, dt: Float) -> simd_quatf {
        let (depth, pushDir) = Self.penetration(
            point: chestWorld, capsuleP0: partnerTorso.p0, capsuleP1: partnerTorso.p1,
            radius: partnerTorso.radius)
        let target = Self.targetLean(depth: depth, pushDir: pushDir, spineUp: spineUp, params: params)
        let alpha = simd_clamp(params.stiffness * dt, 0, 1)
        lean = simd_slerp(lean, target, alpha)
        return lean
    }
}
