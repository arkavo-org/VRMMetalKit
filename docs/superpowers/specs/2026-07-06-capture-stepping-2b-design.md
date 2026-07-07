# Capture-Stepping 2b — IK Executor + Stability Validation — Design

**Date:** 2026-07-06
**Status:** Design approved. Increment 2b — the IK half of the capture-step controller (2a built the pure core) plus the *real* stability validation that lives where the limit cycle lives.
**Scope:** Add the IK executor that turns 2a's world-space ankle targets into leg-bone rotations on a real rig, and validate stability with two gates on the two substrates where each signal is clean: a deterministic moving-CoM model gate (monotone regression-lock) and a real-rig confirmation (the model's validity gate). Single-avatar; crowd/visible demo is still deferred.

**Depends on:** 2a (`CaptureStepController`, `CaptureStepParams`, `step(balance:dt:)`, `plantedFeet`/`plantedPositions`, the provisional committed defaults), `BalanceModel` (increment 1), and `TwoBoneIKSolver` (existing).

---

## 0. The construction rule for this increment (read first)

**Every gate in 2b ships with a paired discriminating case that FAILS, proving the gate can detect the failure mode it claims to gate against.** This is the 2a lesson made structural: a gate can pass while measuring the wrong thing (2a's convergence gate passed at 0.10 while non-monotone and degenerate). The counter-case is what turns "passes at the committed value" into "detects the target failure." Concretely: the IK gate proves placement is right *across a target range* (not right-at-one-point); the model stability gate includes a just-over-the-line case that *cycles* (proving monotonicity detects instability); the rig confirmation includes an over-gain case that *grows* (proving the metric detects cycling). No stability gate ships without its failing counter-case.

---

## 1. The two failure surfaces, kept apart

2b introduces two things that can be *independently* wrong, and the whole design keeps them on separate substrates so a failure has one diagnosable cause:

1. **The world→local IK conversion** — the one surface with *no model to hide behind*: it only exists on the real rig, and it's either the correct parent-frame conjugation or it isn't. Validated *by itself* against a known-target test (§2), independent of any stepping/stability behavior.
2. **Stability** (the §2-of-2a-spec limit cycle) — a property of the CoM-response *loop*, validated by the model gate + rig confirmation (§4). Deliberately kept *off* the IK surface: the model gate has no IK at all; the rig confirmation reads *through* the IK and therefore *depends on* surface 1 being verified first (§4.3).

---

## 2. The IK executor + its isolated correctness gate

**`CaptureStepController.update(deltaTime:model:rootVelocity:groundY:)`** extends 2a's type (2a's `step` and state machine unchanged). Per frame, on a model already posed for this frame (clip + root motion applied, `updateNodeTransforms` run):

1. **Seed on first call** — source both ankle world positions from the rig (`model.nodes[footBoneIdx].worldPosition`) and `seed(...)`. (2a's `seed` takes positions as data; 2b is the caller that sources them from the rig.)
2. **Read balance** — `BalanceModel.evaluate(model:groundY:plantedFeet:)` using the controller's current planted-feet set.
3. **Decide** — call 2a's pure `step(balance:dt:)` → two world-space ankle targets. (No new stepping logic here; 2b only *executes* 2a's decisions.)
4. **Execute via IK** — for each leg, `TwoBoneIKSolver.solve(...)` returns a **world-space** aim; convert to the bone's local rotation by **direct parent-frame conjugation** — `localRotation = parentWorldRotation⁻¹ · worldAim` (the same world→local move the postural layer uses) — and write the hip and knee local rotations, then `updateNodeTransforms`. **Not** through `AnimationLayerCompositor`. `groundY` is a rig quantity (back this increment); the swing target's height is `groundY + restAnkleHeight` (captured at seed).

Velocity-free by default: `rootVelocity` feeds only the off-by-default predicted-target follow-plant hook (2a §5); the default configuration passes `.zero`. Disabled ⇒ `update` writes nothing.

### 2.1 IK-correctness gate (slice 1) — the measurement foundation
A standalone test, no stepping/stability involved: set a **known** world-space ankle target, run only the IK-conversion path, `updateNodeTransforms`, and assert **the actual ankle world position lands at the target within tolerance ε**. The counter-case per §0: assert this **across a range of target positions and leg configurations** (targets ahead/behind/beside the foot, at reachable distances), not a single point — placement must be right *everywhere in range*, because slice 4's CoM-from-posed-rig reads through exactly this placement. **ε is stated as an explicit number** (the measured worst-case placement error across the range) and **flows to slice 4 as the residual noise floor** (§4.3). Targets beyond leg reach are clamped/handled and excluded from the ε bound (documented).

---

## 3. Real-rig behavior tests (the executor working)

On a loaded VRM, single avatar:
- **Follow / moonwalk (slice 2):** drive the root laterally at a slow (under-threshold) scripted speed; assert the planted foot **holds its world position** while the hip moves over it (plant, not slide), a step fires and re-plants toward the CoM, and the margin recovers. Over the run the feet advance in discrete footfalls, not a skate. This also exercises the *real* CoM-response the model (§4.1) approximates.
- **Non-interference:** controller disabled ⇒ leg bones bit-identical to the input pose.

---

## 4. Stability validation — Option 3 (both gates required)

### 4.1 Model gate (deterministic, the discriminating regression-lock) — slice 3
Extend 2a's fixed-CoM harness to a **moving CoM** that closes the real loop. Each step the CoM is updated by **two** terms:

- **Driver/shove advance (the disturbance, the input):** the CoM's trunk component advances by a scripted per-step displacement (a sustained approach, or a held shove).
- **Swung-leg self-feedback (the FEEDBACK — Push 1, the load-bearing term):** when the controller swings a foot to a plant target, the swung leg's mass (upperLeg + lowerLeg + foot ≈ 0.16 of body mass, from the Dempster table) moves with it, **pulling the CoM toward the plant target**. The model MUST include this: the CoM the margin is measured against at the *next* trigger has already been shifted by the *last* step. Model it from the leg segment masses at their approximate positions (foot mass at the foot, lower-leg at the knee ≈ swing midpoint, upper-leg at the hip ≈ trunk), so the net CoM shift is proportional to the step and directed toward the plant.

**Why this term is non-negotiable:** the limit cycle is a property of the feedback. A model with driver-advance *only* is an **open loop** — the CoM is frozen with respect to the controller's own actions — and an open loop is **trivially monotone**, so it would pass the monotonicity assertion *vacuously while corresponding to no real mechanism*. That is 2a's frozen-CoM failure in subtler dress. Monotonicity is therefore **necessary but not sufficient**; the model's *faithfulness* (that the self-feedback term matches how the real rig's CoM shifts) is guarded only by the rig confirmation (§4.2) — which is precisely why both gates are required.

The gate: **sweep `captureDistance` across the committed range and assert the pass/fail (contracts/holds vs. grows/cycles) is MONOTONE — a hard assertion.** If `L`'s real shape is non-monotone, the gate **fails loudly** (the model is wrong, ship-blocking), rather than passing at a lucky point. Counter-case per §0: a **just-over-the-line `captureDistance` that cycles**, proving the monotone gate detects instability.

### 4.2 Real-rig confirmation (the model's VALIDITY gate — NOT optional) — slice 4
At the committed `captureDistance` the model blessed, drive a **sustained disturbance** on the actual avatar and assert the stepping response is stable. **"Stable" needs a reference or it is unfalsifiable** (every finite run is trivially bounded), so the metric is discriminating, mirroring the model gate:

- **Committed `captureDistance`:** the residual (CoM offset past support, measured on the posed rig) **contracts or holds — does not grow** — over the run, beyond the ε noise floor (§4.3).
- **Counter-case (§0):** a deliberately **over-gain `captureDistance`** on the same rig **visibly grows / oscillates**, proving the rig metric can *tell the difference* between stable and cycling — not passing everything because 1000 frames is short.

This is the single check whose absence let 2a overclaim: it catches **model-reality divergence** (the §4.1 self-feedback term being wrong). **A committed `captureDistance` requires BOTH gates green. If the rig grows/wobbles where the model says stable, the model is corrected, not this test waived.** (Verbatim, so Option 3 cannot decay into Option 1 — model-only — by attrition: the model gate blocks *regressions*; the rig confirmation blocks *model-reality divergence*; the committed guarantee is only as good as the rig confirmation that the model matches reality.)

### 4.3 The slice 1 → slice 4 dependency (Push 2/3)
Slice 4's residual is computed from the posed skeleton **including the IK-placed legs** — it reads *through* the IK conversion (surface 1). A systematic IK error would bias the CoM → bias the residual → make a stable system look like it holds at a nonzero residual (false-stable) or drifts (false-cycle). Therefore **slice 4's residual measurement assumes slice 1's IK conversion is verified within tolerance ε**, and **ε from slice 1 is slice 4's residual noise floor**: "residual growing" (a real cycle) is only distinguishable from "residual jitter within ε" (IK placement noise) if ε is known. Slice 4 must not be trusted until slice 1 is green; this is a stated *dependency*, not just an ordering.

---

## 5. Decomposition (task-gated slices)

1. **IK executor + isolated known-target correctness gate.** `update(...)` + the world→local conversion; slice-1 gate asserts ankle-at-target within ε across a target range + leg configs; ε stated explicitly. *(Measurement foundation for slice 4.)*
2. **Real-rig follow/moonwalk + non-interference.**
3. **Moving-CoM model stability gate** — with the swung-leg self-feedback term (§4.1); monotonicity hard-asserted across `captureDistance`; just-over-the-line cycling counter-case.
4. **Real-rig stability confirmation** — committed `captureDistance` holds/contracts, over-gain counter-case grows; residual measured through the IK with ε (from slice 1) as the noise floor; wire "committed `captureDistance` requires both gates green" into the provisional-defaults framing (promote them from "provisional pending 2b" to "validated" only when both gates are green).

---

## 6. Non-goals (2b)

- **Crowd wiring / visible demo** — still deferred; 2b proves the actuator + stability single-avatar headless.
- **Collision → stagger impulse** (increment 3) — the thing that drives the arrest regime in anger; 2b's stability is driven by a *synthetic* sustained disturbance.
- **Upright root recovery** (increment 4).
- **Predicted-target follow-plant as default** (stays off; the speed cap is the default per 2a §5).
- **Gait / turning / uneven ground / double-support polish** — single flat `groundY`, discrete catch-steps.
