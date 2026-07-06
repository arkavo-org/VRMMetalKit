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

/// Tuning for the capture-step controller (design 2026-07-06 §6). `captureDistance`
/// is the capture-gain term in the §2 feedback loop — bounded above JOINTLY with
/// `stepDamping` by the stability region, NOT a free firmness knob. Follow regime
/// (driver-driven motion) uses `captureDistance = 0, stepDamping = 0`.
public struct CaptureStepParams: Sendable {
    /// Step when `BalanceState.margin` drops below this.
    public var triggerMargin: Float
    /// Distance the foot reaches BEYOND the CoM. `0` = follow (plant under CoM).
    public var captureDistance: Float
    /// Fraction of the step held back (`[0,1)`; higher = smaller/safer step).
    public var stepDamping: Float
    /// Seconds per swing.
    public var swingDuration: Float
    /// Peak of the swing lift arc.
    public var stepHeight: Float
    /// Minimum time between steps (rate limit — decouples step rhythm from disturbance rate).
    public var minStepInterval: Float

    public init(triggerMargin: Float = 0.02, captureDistance: Float = 0, stepDamping: Float = 0,
                swingDuration: Float = 0.25, stepHeight: Float = 0.06, minStepInterval: Float = 0.15) {
        self.triggerMargin = triggerMargin
        self.captureDistance = captureDistance
        self.stepDamping = stepDamping
        self.swingDuration = swingDuration
        self.stepHeight = stepHeight
        self.minStepInterval = minStepInterval
    }
}

/// Per-foot state: an ankle locked at a world point, or mid-swing.
public enum FootPhase: Sendable {
    case planted(SIMD3<Float>)
    case swinging(from: SIMD3<Float>, to: SIMD3<Float>, elapsed: Float)
}

/// Pure math for the capture-step controller (rig-free).
public enum CaptureStepMath {
    /// Position along a swing at parameter `t ∈ [0,1]`: smoothstep across `from→to`
    /// with a `stepHeight` lift that is zero at both ends and peaks at mid-swing.
    public static func swingArc(from: SIMD3<Float>, to: SIMD3<Float>, t: Float, stepHeight: Float) -> SIMD3<Float> {
        let c = simd_clamp(t, 0, 1)
        let eased = c * c * (3 - 2 * c)
        var p = from + (to - from) * eased
        // Lift only in the interior to avoid floating-point precision issues at endpoints.
        if c > 0 && c < 1 {
            p.y += stepHeight * sin(Float.pi * c)
        }
        return p
    }

    /// The planted foot furthest BEHIND the fall (smallest projection onto
    /// `imbalanceDirection`) — the one to swing toward the CoM for a capture step.
    public static func trailingFoot(leftPlant: SIMD3<Float>, rightPlant: SIMD3<Float>,
                                    comGround: SIMD2<Float>, imbalanceDirection: SIMD2<Float>) -> BalanceModel.Foot {
        let l = SIMD2<Float>(leftPlant.x, leftPlant.z)
        let r = SIMD2<Float>(rightPlant.x, rightPlant.z)
        let lp = simd_dot(l - comGround, imbalanceDirection)
        let rp = simd_dot(r - comGround, imbalanceDirection)
        return lp <= rp ? .left : .right
    }

    /// The damped capture target (xz): from the support centroid, step a fraction
    /// `(1 − stepDamping)` of the way toward the raw capture point
    /// `comGround + imbalanceDirection·captureDistance`. Follow (`captureDistance = 0,
    /// stepDamping = 0`) collapses to `comGround`.
    public static func captureTargetXZ(comGround: SIMD2<Float>, imbalanceDirection: SIMD2<Float>,
                                       supportCentroid: SIMD2<Float>, captureDistance: Float,
                                       stepDamping: Float) -> SIMD2<Float> {
        let rawTarget = comGround + imbalanceDirection * captureDistance
        return supportCentroid + (rawTarget - supportCentroid) * (1 - stepDamping)
    }
}
