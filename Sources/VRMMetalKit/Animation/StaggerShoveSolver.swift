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

/// Tuning for the stagger shove (design 2026-07-07 §2). Uniform across avatars
/// in v1 (per-avatar mass/scale weighting is a deferred non-goal).
public struct StaggerShoveParams: Sendable {
    /// Metres of ground-plane CoM offset per metre of penetration depth.
    /// Amplifies a shallow (Component-A-clamped) penetration into an offset that
    /// can exceed the support margin; calibrated against `bodyContactMargin` in
    /// the visual spike (design §5).
    public var shoveGain: Float
    /// Maximum rate of change of the offset (m/s). Defaults to 0.7 × 0.2 = 0.14 —
    /// a safety fraction of the rig-confirmed ~0.2 m/s tracking capacity
    /// (`CaptureStepIKTests.testRigTrackingCapacity_belowHolds_overCapacityGrows`),
    /// so the disturbance the capture-step controller sees stays inside the
    /// validated band. Bounds the shove component only; for a more dramatic
    /// stagger raise `shoveGain`, not this.
    public var velocityCap: Float

    public init(shoveGain: Float = 6.0, velocityCap: Float = 0.14) {
        self.shoveGain = shoveGain
        self.velocityCap = velocityCap
    }
}

/// The pure, deterministic core of the stagger shove (design 2026-07-07 §2):
/// penetration (depth, pushDir) → a rate-limited ground-plane (XZ) CoM offset.
/// A first-order rate limiter — converges to the target, never overshoots,
/// never coasts, so there is no momentum: on separation the target becomes zero
/// and the offset ramps back at ≤ `velocityCap` (the §1 return-glide).
/// Metal-free and model-free; ``CrowdFrameStepper`` wraps it with the
/// root/controller plumbing (Phase 0e).
public struct StaggerShoveSolver: Sendable {
    public var params: StaggerShoveParams
    /// The current ground-plane CoM displacement, carried across frames.
    public private(set) var offset: SIMD2<Float> = .zero

    public init(params: StaggerShoveParams = StaggerShoveParams()) {
        self.params = params
    }

    /// Advance one frame: aim at `shoveGain · depth` along the normalized
    /// ground-plane push direction — zero when there is no contact or the
    /// direction is degenerate — and move `offset` toward that target by at most
    /// `velocityCap · dt`. Returns the updated offset.
    @discardableResult
    public mutating func update(depth: Float, pushDirXZ: SIMD2<Float>, dt: Float) -> SIMD2<Float> {
        let dirLength = simd_length(pushDirXZ)
        let target: SIMD2<Float> = (depth > 0 && dirLength > 1e-6)
            ? params.shoveGain * depth * (pushDirXZ / dirLength)
            : .zero
        let delta = target - offset
        let maxStep = params.velocityCap * max(dt, 0)
        if simd_length(delta) <= maxStep {
            offset = target
        } else if maxStep > 0 {
            offset += simd_normalize(delta) * maxStep
        }
        return offset
    }
}
