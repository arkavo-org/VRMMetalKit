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
/// is a stabilizing LEAD knob — a larger lead tracks a faster disturbance — NOT a
/// loop-gain or stability-bound term. The bounded quantity is the max disturbance
/// RATE the stepper can track. Follow regime (driver-driven motion) uses
/// `captureDistance = 0, stepDamping = 0`.
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

    /// Committed arrest defaults. The MAX DISTURBANCE RATE (not `captureDistance`) is
    /// validated by two gates: the 2b moving-CoM tracking-capacity MODEL gate
    /// (`CaptureStepStabilityTests`, monotone in drive rate, with an over-capacity
    /// escape counter-case) AND the real-rig CONFIRMATION gate
    /// (`CaptureStepIKTests.testRigTrackingCapacity_belowHolds_overCapacityGrows`,
    /// on the actual skeleton + IK, measured on the BALANCE RESIDUAL — the same
    /// quantity the model gate measures). What the rig gate ASSERTS is exactly two
    /// drive rates: 0.08 m/s holds the residual, 0.6 m/s grows it. Where the rig's
    /// escape boundary falls between them (the 0.15–0.4 m/s sweep) is print-only
    /// characterization, NOT gated — "the boundary sits in the model's committed
    /// band" is an observation, not a checked fact. THIS fixture's physical leg
    /// reach does clamp at below-capacity drive rates
    /// (it stands with near-zero reach-slack at rest), but reach-clamping is a graceful
    /// KINEMATIC degradation mode (the foot lands short of its ideal capture point) that
    /// does not by itself indicate balance failure and does not bound the rig's balance
    /// capacity below the model's band. `captureDistance` is a stabilizing LEAD knob,
    /// not a loop-gain term: a larger lead tracks a faster disturbance
    /// (`testLargerCaptureDistance_tracksFasterDisturbance`), it does not bound
    /// stability on its own.
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
        // Clamp to the documented domains: damping > 1 steps to the far side of the
        // centroid (never recovers), negative overshoots; a negative lead steps
        // away from the fall.
        let damping = min(max(stepDamping, 0), 0.999)
        let lead = max(captureDistance, 0)
        let rawTarget = comGround + imbalanceDirection * lead
        return supportCentroid + (rawTarget - supportCentroid) * (1 - damping)
    }
}

/// Procedural capture-step controller — the pure core (design 2026-07-06). Consumes a
/// `BalanceState`, emits world-space ankle targets, and owns the per-foot state
/// machine. **Seam invariant (2a): the state machine above never touches a bone
/// rotation or an IK solver.** `placeAnkle` (2b) is the sole, deliberate exception —
/// the IK executor that turns a world-space ankle target into rig motion. Root motion
/// is an input; the feet follow/catch.
public final class CaptureStepController {
    public var params: CaptureStepParams
    private var left: FootPhase = .planted(SIMD3<Float>(repeating: 0))
    private var right: FootPhase = .planted(SIMD3<Float>(repeating: 0))
    private var timeSinceLastStep: Float = 0

    /// Whether the override drives the legs this frame.
    public var isEnabled: Bool = true
    private var seeded = false

    /// The BalanceState the last update() computed, for tests to confirm evaluate read
    /// the controller's restored feet (not the clip's skating positions).
    public private(set) var lastBalance: BalanceState?

    /// Whether ANY of the frame's `placeAnkle` calls clamped its reach (a requested
    /// world target exceeded the summed leg length) — reset at the top of `update`,
    /// then OR-accumulated across the four calls `update` makes per frame. A clamp
    /// means the IK solver's ε guarantee (spec §2.1) no longer applies to that
    /// frame, since the ankle lands short of the target by construction. Recorded
    /// for diagnostics only: the rig-tracking gate does NOT gate on clamps — the
    /// trailing leg reach-clamps routinely below capacity (169/180 frames at
    /// 0.08 m/s) because this fixture stands with near-zero reach-slack at rest.
    public private(set) var lastStepClamped = false

    public init(params: CaptureStepParams = CaptureStepParams()) {
        self.params = params
    }

    /// One frame: seed-once from the rig, RESTORE the controller's feet before reading
    /// balance (spec §2 / Redline 1), evaluate, decide (2a `step`), apply via IK.
    public func update(deltaTime: Float, model: VRMModel, rootVelocity: SIMD3<Float> = .zero) {
        lastStepClamped = false
        guard isEnabled, let humanoid = model.humanoid else { return }
        _ = rootVelocity   // velocity-free default; reserved for the predicted-target hook
        let dt = max(deltaTime, 0)   // a negative dt must not run the state machine backwards

        if !seeded {
            if let l = humanoid.getBoneNode(.leftFoot), let r = humanoid.getBoneNode(.rightFoot),
               l < model.nodes.count, r < model.nodes.count {
                seed(leftAnkle: model.nodes[l].worldPosition, rightAnkle: model.nodes[r].worldPosition)
            } else { return }
        }

        // RESTORE before evaluate: place both feet at the controller's current targets so
        // evaluate's support polygon + CoM reflect the controller, not the clip's skate.
        placeAnkle(.left, worldTarget: target(.left), model: model)
        placeAnkle(.right, worldTarget: target(.right), model: model)
        model.updateNodeTransforms()

        guard let balance = BalanceModel.evaluate(model: model, plantedFeet: plantedFeet) else { return }
        lastBalance = balance
        _ = step(balance: balance, dt: dt)

        // Apply the (possibly updated) targets.
        placeAnkle(.left, worldTarget: target(.left), model: model)
        placeAnkle(.right, worldTarget: target(.right), model: model)
        model.updateNodeTransforms()
    }

    /// Seed both feet planted at the given (synthetic in 2a; rig-sourced in 2b) ankle
    /// world positions. Rig-free — takes positions as data. Sets the seeded latch, so
    /// the next `update` keeps these positions instead of re-seeding from the rig.
    public func seed(leftAnkle: SIMD3<Float>, rightAnkle: SIMD3<Float>) {
        left = .planted(leftAnkle)
        right = .planted(rightAnkle)
        timeSinceLastStep = params.minStepInterval   // ready to step immediately
        seeded = true
    }

    /// Translate planted (and mid-swing) foot world targets by `delta`.
    /// Use when the app soft-resolves the root from collision so planted feet
    /// stay under the body instead of sliding into reverse-knee hyperextension.
    /// Does not change phase (planted stays planted; swing endpoints move).
    public func translatePlants(by delta: SIMD3<Float>) {
        guard simd_length_squared(delta) > 1e-12 else { return }
        switch left {
        case .planted(let p): left = .planted(p + delta)
        case .swinging(let from, let to, let e):
            left = .swinging(from: from + delta, to: to + delta, elapsed: e)
        }
        switch right {
        case .planted(let p): right = .planted(p + delta)
        case .swinging(let from, let to, let e):
            right = .swinging(from: from + delta, to: to + delta, elapsed: e)
        }
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
            let to = SIMD3<Float>(txz.x, from.y, txz.y)   // preserve the foot's own height (flat ground)
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

    /// Solve two-bone leg IK and apply it so `foot`'s ankle lands at `worldTarget`.
    /// The ONLY method that writes bone rotations (2b's IK surface).
    ///
    /// Knee bend uses a **character-forward pole** (hips world +Z, VRM facing),
    /// not a hard-coded world +Z — world-fixed poles reverse the knee when the
    /// avatar faces anything but +Z. The knee mid-point is placed explicitly on
    /// the hip–ankle–pole plane (law of cosines) so the joint cannot flip behind
    /// the thigh (hyperextension / reverse knee).
    public func placeAnkle(_ foot: BalanceModel.Foot, worldTarget: SIMD3<Float>, model: VRMModel) {
        guard let humanoid = model.humanoid else { return }
        let (up, lo, en): (VRMHumanoidBone, VRMHumanoidBone, VRMHumanoidBone) =
            foot == .left ? (.leftUpperLeg, .leftLowerLeg, .leftFoot)
                          : (.rightUpperLeg, .rightLowerLeg, .rightFoot)
        guard let hipIdx = humanoid.getBoneNode(up), let kneeIdx = humanoid.getBoneNode(lo),
              let ankleIdx = humanoid.getBoneNode(en),
              hipIdx < model.nodes.count, kneeIdx < model.nodes.count, ankleIdx < model.nodes.count
        else { return }

        let hipPos = model.nodes[hipIdx].worldPosition
        let kneePos = model.nodes[kneeIdx].worldPosition
        let anklePos = model.nodes[ankleIdx].worldPosition
        let a = TwoBoneIKSolver.boneLength(from: hipPos, to: kneePos)
        let b = TwoBoneIKSolver.boneLength(from: kneePos, to: anklePos)
        guard a > 1e-4, b > 1e-4 else { return }

        let rootToTarget = worldTarget - hipPos
        let rawReach = simd_length(rootToTarget)
        guard rawReach > 1e-4 else { return }
        let minReach = abs(a - b) + 0.001
        let maxReach = a + b - 0.001
        if rawReach > maxReach { lastStepClamped = true }
        let c = simd_clamp(rawReach, minReach, maxReach)
        let targetDir = simd_normalize(rootToTarget)

        // Character-forward pole (VRM front = +Z on the hips/root). Prefer the
        // side that matches the current knee so we don't flip mid-recovery.
        var pole = Self.characterForward(model: model, humanoid: humanoid)
        pole = pole - targetDir * simd_dot(pole, targetDir)
        if simd_length(pole) < 1e-4 {
            let upHint = abs(simd_dot(targetDir, SIMD3<Float>(0, 1, 0))) > 0.9
                ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
            pole = simd_cross(targetDir, upHint)
        }
        guard simd_length(pole) > 1e-4 else { return }
        pole = simd_normalize(pole)

        let hipToKnee = kneePos - hipPos
        let lateral = hipToKnee - targetDir * simd_dot(hipToKnee, targetDir)
        if simd_length(lateral) > 0.02, simd_dot(lateral, pole) < 0 {
            pole = -pole   // keep bend on the side the knee already occupies
        }

        // Explicit mid (knee) on the hip–ankle–pole plane — not "aim shin only",
        // which can put the joint behind the thigh (reverse knee).
        let h = (a * a - b * b + c * c) / (2 * c)
        let height = sqrtf(max(0, a * a - h * h))
        let kneeWorld = hipPos + targetDir * h + pole * height
        let exactAnkle = hipPos + targetDir * c

        // HIP: local rotation so bind thigh axis maps to hip→knee world direction.
        let thighRest = model.nodes[kneeIdx].initialTranslation
        guard simd_length(thighRest) > 1e-6 else { return }
        let thighRestDir = simd_normalize(thighRest)
        let desiredThigh = simd_normalize(kneeWorld - hipPos)
        let hipParentWorld = TwoBoneIKSolver.worldRotation(model.nodes[hipIdx].parent?.worldMatrix)
        let desiredThighLocal = simd_act(hipParentWorld.inverse, desiredThigh)
        guard simd_length(desiredThighLocal) > 1e-6 else { return }
        model.nodes[hipIdx].rotation = simd_normalize(
            simd_quatf(from: thighRestDir, to: simd_normalize(desiredThighLocal)))
        model.nodes[hipIdx].updateLocalMatrix()
        model.nodes[hipIdx].updateWorldTransform()

        // KNEE: aim bind shin axis at exact ankle from the post-hip knee position.
        let newKneePos = model.nodes[kneeIdx].worldPosition
        let shinVec = exactAnkle - newKneePos
        guard simd_length(shinVec) > 1e-6 else { return }
        let desiredShin = simd_normalize(shinVec)
        let shinRest = model.nodes[ankleIdx].initialTranslation
        guard simd_length(shinRest) > 1e-6 else { return }
        let shinRestDir = simd_normalize(shinRest)
        let kneeParentWorld = TwoBoneIKSolver.worldRotation(model.nodes[kneeIdx].parent?.worldMatrix)
        let desiredShinLocal = simd_act(kneeParentWorld.inverse, desiredShin)
        guard simd_length(desiredShinLocal) > 1e-6 else { return }
        model.nodes[kneeIdx].rotation = simd_normalize(
            simd_quatf(from: shinRestDir, to: simd_normalize(desiredShinLocal)))
        model.nodes[kneeIdx].updateLocalMatrix()
        model.nodes[kneeIdx].updateWorldTransform()
    }

    /// Avatar facing in world space (VRM front = local +Z). Prefers hips, then
    /// any scene root — never a hard-coded world axis.
    private static func characterForward(model: VRMModel, humanoid: VRMHumanoid) -> SIMD3<Float> {
        if let hips = humanoid.getBoneNode(.hips), hips < model.nodes.count {
            let m = model.nodes[hips].worldMatrix
            let f = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
            if simd_length(f) > 1e-4 { return simd_normalize(f) }
        }
        if let root = model.nodes.first(where: { $0.parent == nil }) {
            let m = root.worldMatrix
            let f = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
            if simd_length(f) > 1e-4 { return simd_normalize(f) }
        }
        return SIMD3<Float>(0, 0, 1)
    }
}
