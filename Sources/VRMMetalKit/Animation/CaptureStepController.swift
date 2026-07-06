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

    /// Provisional committed arrest defaults. These are NOT proven-stable bounds: 2a's
    /// test only sanity-checks that they *contract a static residual* under a fixed-CoM
    /// model, which cannot exhibit the §2 limit cycle (that is a moving-CoM phenomenon).
    /// The STABILITY of these values — that the real, moving-CoM stepping response does
    /// not limit-cycle — is validated in 2b's real-rig gate, where the CoM-response
    /// lives. Treat as defaults pending that 2b validation, not as a stability guarantee.
    public static let committedCaptureDistanceMax: Float = 0.10
    public static let committedStepDampingMin: Float = 0.4
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

/// Procedural capture-step controller — the pure core (design 2026-07-06). Consumes a
/// `BalanceState`, emits world-space ankle targets, and owns the per-foot state
/// machine. **Seam invariant: this type never touches a bone rotation, an IK solver,
/// or the rig — 2b owns all of that.** Root motion is an input; the feet follow/catch.
public final class CaptureStepController {
    public var params: CaptureStepParams
    private var left: FootPhase = .planted(SIMD3<Float>(repeating: 0))
    private var right: FootPhase = .planted(SIMD3<Float>(repeating: 0))
    private var timeSinceLastStep: Float = 0

    public init(params: CaptureStepParams = CaptureStepParams()) {
        self.params = params
    }

    /// Seed both feet planted at the given (synthetic in 2a; rig-sourced in 2b) ankle
    /// world positions. Rig-free — takes positions as data.
    public func seed(leftAnkle: SIMD3<Float>, rightAnkle: SIMD3<Float>) {
        left = .planted(leftAnkle)
        right = .planted(rightAnkle)
        timeSinceLastStep = params.minStepInterval   // ready to step immediately
    }

    public func phase(_ foot: BalanceModel.Foot) -> FootPhase { foot == .left ? left : right }

    public func target(_ foot: BalanceModel.Foot) -> SIMD3<Float> {
        switch phase(foot) {
        case .planted(let p):
            return p
        case .swinging(let from, let to, let elapsed):
            let t = params.swingDuration > 0 ? elapsed / params.swingDuration : 1
            return CaptureStepMath.swingArc(from: from, to: to, t: t, stepHeight: params.stepHeight)
        }
    }

    public var plantedFeet: Set<BalanceModel.Foot> {
        var s = Set<BalanceModel.Foot>()
        if case .planted = left { s.insert(.left) }
        if case .planted = right { s.insert(.right) }
        return s
    }

    public func plantedPositions() -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        if case .planted(let p) = left { out.append(p) }
        if case .planted(let p) = right { out.append(p) }
        return out
    }

    /// Advance one frame and return the two world-space ankle targets. Begins at most
    /// one swing (≥1 foot always planted), rate-limited by `minStepInterval`.
    @discardableResult
    public func step(balance: BalanceState, dt: Float) -> (left: SIMD3<Float>, right: SIMD3<Float>) {
        timeSinceLastStep += dt
        advanceSwing(&left, dt: dt)
        advanceSwing(&right, dt: dt)

        let bothPlanted = { if case .planted = left, case .planted = right { return true }; return false }()
        if bothPlanted, timeSinceLastStep >= params.minStepInterval, balance.margin < params.triggerMargin,
           case .planted(let lp) = left, case .planted(let rp) = right {
            let foot = CaptureStepMath.trailingFoot(leftPlant: lp, rightPlant: rp,
                                                    comGround: balance.comGround,
                                                    imbalanceDirection: balance.imbalanceDirection)
            let txz = CaptureStepMath.captureTargetXZ(comGround: balance.comGround,
                                                      imbalanceDirection: balance.imbalanceDirection,
                                                      supportCentroid: balance.supportCentroid,
                                                      captureDistance: params.captureDistance,
                                                      stepDamping: params.stepDamping)
            let from = foot == .left ? lp : rp
            let to = SIMD3<Float>(txz.x, from.y, txz.y)   // preserve the foot's own height (flat ground; groundY is 2b)
            let swing = FootPhase.swinging(from: from, to: to, elapsed: 0)
            if foot == .left { left = swing } else { right = swing }
            timeSinceLastStep = 0
        }
        return (target(.left), target(.right))
    }

    private func advanceSwing(_ phase: inout FootPhase, dt: Float) {
        guard case .swinging(let from, let to, let elapsed) = phase else { return }
        let e = elapsed + dt
        phase = e >= params.swingDuration ? .planted(to) : .swinging(from: from, to: to, elapsed: e)
    }
}
