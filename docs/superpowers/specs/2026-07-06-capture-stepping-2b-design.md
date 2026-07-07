# Capture-Stepping 2b — IK Executor + Stability Validation — Design

**Date:** 2026-07-06
**Status:** Design approved, then RE-AXISED (2026-07-07) after investigation. The failure mode is a **tracking-capacity limit** (a disturbance that outpaces the stepper's relocation rate escapes the support), **not** a momentum limit cycle — the fully-procedural no-momentum architecture cannot limit-cycle (three sweeps confirmed: `captureDistance` is monotonically *stabilizing*, not a loop-gain term). The stability gates below are re-axised onto **disturbance rate** (§4.1/§4.2). See the Re-axis note in §4.
**Scope:** Add the IK executor that turns 2a's world-space ankle targets into leg-bone rotations on a real rig, and validate stability with two gates on the two substrates where each signal is clean: a deterministic moving-CoM model gate (monotone regression-lock) and a real-rig confirmation (the model's validity gate). Single-avatar; crowd/visible demo is still deferred.

**Depends on:** 2a (`CaptureStepController`, `CaptureStepParams`, `step(balance:dt:)`, `plantedFeet`/`plantedPositions`, the provisional committed defaults), `BalanceModel` (increment 1), and `TwoBoneIKSolver` (existing).

---

## 0. The construction rule for this increment (read first)

**Every gate whose metric can pass VACUOUSLY ships with a paired discriminating case that FAILS, proving the gate can detect the failure mode it claims to gate against.** This is the 2a lesson made structural: a gate can pass while measuring the wrong thing (2a's convergence gate passed at 0.10 while non-monotone and degenerate). A metric passes *vacuously* when success proves nothing on its own — **stability / boundedness** claims are the canonical case ("the residual stayed bounded for 1000 frames" is true of every finite run, cycling or not). Those require a failing counter-case: the model stability gate includes an over-capacity disturbance-rate case that *escapes* (residual grows — proving monotonicity detects the tracking failure); the rig confirmation includes an over-capacity disturbance-rate case that *grows* (proving the metric detects track-vs-escape).

A **direct-measurement** metric cannot pass vacuously — the IK gate's "ankle lands at target within ε" is falsified by any real placement error, so its rigor comes from **range coverage plus an explicit ε** (placement right *everywhere in range*, not right-at-one-point), not from a manufactured failing case. The rule targets vacuity, not every gate.

---

## 1. The two failure surfaces, kept apart

2b introduces two things that can be *independently* wrong, and the whole design keeps them on separate substrates so a failure has one diagnosable cause:

1. **The world→local IK conversion** — the one surface with *no model to hide behind*: it only exists on the real rig, and it's either the correct parent-frame conjugation or it isn't. Validated *by itself* against a known-target test (§2), independent of any stepping/stability behavior.
2. **Stability** (the §2-of-2a-spec limit cycle) — a property of the CoM-response *loop*, validated by the model gate + rig confirmation (§4). Deliberately kept *off* the IK surface: the model gate has no IK at all; the rig confirmation reads *through* the IK and therefore *depends on* surface 1 being verified first (§4.3).

---

## 2. The IK executor + its isolated correctness gate

**`CaptureStepController.update(deltaTime:model:rootVelocity:groundY:)`** extends 2a's type (2a's `step` and state machine unchanged). Per frame, on a model already posed for this frame (clip + root motion applied, `updateNodeTransforms` run):

1. **Seed on first call** — source both ankle world positions from the rig (`model.nodes[footBoneIdx].worldPosition`) and `seed(...)`. (2a's `seed` takes positions as data; 2b is the caller that sources them from the rig.)
2. **Restore the controller's feet BEFORE reading balance (load-bearing — see below).** IK each planted foot back to its **stored world pivot** and the swinging foot to its current arc point, then `updateNodeTransforms`, so the leg bones reflect the controller's foot state, not the clip's. This needs no balance (the controller already stores planted feet as world positions) — it's a pure restore.
3. **Read balance** — `BalanceModel.evaluate(model:groundY:plantedFeet:)` using the controller's current planted-feet set.
4. **Decide** — call 2a's pure `step(balance:dt:)` → two world-space ankle targets. (No new stepping logic here; 2b only *executes* 2a's decisions.)
5. **Execute via IK** — for each leg, `TwoBoneIKSolver.solve(...)` returns a **world-space** aim; convert to the bone's local rotation by **direct parent-frame conjugation** — `localRotation = parentWorldRotation⁻¹ · worldAim` (the same world→local move the postural layer uses) — and write the hip and knee local rotations, then `updateNodeTransforms`. **Not** through `AnimationLayerCompositor`. `groundY` is a rig quantity (back this increment); the swing target's height is `groundY + restAnkleHeight` (captured at seed).
   - **Chained-frame correctness (Redline 2):** within one leg the knee's parent is the upper leg, whose rotation the hip write just changed. Since both writes precede a single `updateNodeTransforms`, the knee's parent-world rotation read from the node hierarchy is the **stale pre-hip-write** value. The knee's conjugation MUST use the **post-write** upper-leg world rotation — either composed explicitly (`hipsWorld · newHipLocal`) or by refreshing transforms between the hip and knee writes — never the cached pre-IK value. (Across the two legs one refresh is fine; the chains are independent off the unmodified hips.) *Confirm the solver's exact per-bone return shape at the code level before implementing — the API determines where the composition happens.*

**Why step 2 is load-bearing (Redline 1 — a bug NO other gate catches).** The model is posed clip-then-root *before* `update`. If the clip still writes leg locals, then at *evaluate* time the foot bones sit at the **clip's** positions, which **skate with the root** (that's the moonwalk) — not at the controller's planted world pivots. `BalanceModel`'s support polygon is built from foot-bone world positions (increment 1 §4.2), so the margin and the step trigger would be computed against a support that is **wrong by up to a step length**, growing as the root advances — while the *visual* feet are fine (the IK restores them at end of frame) and the moonwalk test passes (it asserts end-of-frame hold + margin recovery, both of which survive). The trigger logic runs on a corrupted polygon **undetected**. Note masking the clip's leg writes is *necessary but not sufficient*: persisted leg *locals* translate rigidly with the root, so a masked-but-not-restored planted foot moves by the root's Δ instead of holding its world pivot — **restore-IK (step 2) is what holds the world position**; masking is a redundant optimization on top. The CoM at evaluate has the same contamination (clip-posed legs are ~16% of body mass each, up to ~0.05 m CoM error at a step of displacement); restore-IK fixes both.
   - **Gate (§0):** assert the **support-polygon corners at decision time match the controller's `plantedPositions` within tolerance** — the test that turns "implemented right by care" into "detected if wrong."

Velocity-free by default: `rootVelocity` feeds only the off-by-default predicted-target follow-plant hook (2a §5); the default configuration passes `.zero`. Disabled ⇒ `update` writes nothing.

### 2.1 IK-correctness gate (slice 1) — the measurement foundation
A standalone test, no stepping/stability involved: set a **known** world-space ankle target, run only the IK-conversion path, `updateNodeTransforms`, and assert **the actual ankle world position lands at the target within tolerance ε**. The counter-case per §0: assert this **across a range of target positions and leg configurations** (targets ahead/behind/beside the foot, at reachable distances), not a single point — placement must be right *everywhere in range*, because slice 4's CoM-from-posed-rig reads through exactly this placement. **ε is stated as an explicit number** (the measured worst-case placement error across the range) and **flows to slice 4 as the residual noise floor** (§4.3). Targets beyond leg reach are clamped/handled and excluded from the ε bound (documented).

---

## 3. Real-rig behavior tests (the executor working)

On a loaded VRM, single avatar:
- **Follow / moonwalk (slice 2):** drive the root laterally at a slow (under-threshold) scripted speed; assert the planted foot **holds its world position** while the hip moves over it (plant, not slide), a step fires and re-plants toward the CoM, and the margin recovers. Over the run the feet advance in discrete footfalls, not a skate. This also exercises the *real* CoM-response the model (§4.1) approximates.
- **Non-interference:** controller disabled ⇒ leg bones bit-identical to the input pose.

---

## 4. Stability validation — Option 3, RE-AXISED onto disturbance rate

**Re-axis note (2026-07-07 — read first).** The original §4 gated a momentum **limit cycle** along `captureDistance`. Three independent sweeps (2a fixed-CoM, 2b moving-CoM with the swung-leg self-feedback, and a direct drive-rate probe) proved that cycle **does not exist in this no-momentum architecture**: without integrated velocity the CoM cannot overshoot the support, and `captureDistance` *extends the support toward the CoM* — it is monotonically **stabilizing**, not a loop-gain term (larger `captureDistance` tracks a *faster* disturbance). The **real** failure mode is a **tracking-capacity limit**: the stepper relocates the support at a bounded rate (one foot per `swingDuration + minStepInterval`), so a disturbance whose rate exceeds that capacity **escapes the support and the residual grows monotonically** (the §5 swing-lag as a stability question). Measured boundary (committed params): tracks at ≤ ~0.2 m/s, escapes at ≥ ~0.3 m/s; the boundary rises with faster stepping and with larger `captureDistance`. Both gates below are re-axised onto **disturbance rate**; the two-substrate structure (model + rig, both required) is unchanged.

The moving-CoM model keeps **both** CoM terms — driver advance (the disturbance input) **and** the swung-leg self-feedback (~0.16 of body mass pulled toward the plant), the latter for fidelity so the model's capacity matches the rig's. What is swept is the *disturbance rate*, not `captureDistance`.

### 4.1 Model gate (deterministic, the discriminating regression-lock) — slice 3
Drive the moving-CoM model at a range of **disturbance rates** at the committed params and classify each run as *tracks* (residual bounded — the support keeps up) or *escapes* (residual grows monotonically — the disturbance outpaced the stepper). The gate: **the pass/fail is MONOTONE in disturbance rate — a hard assertion** (once it escapes as the rate rises, it stays escaped; no bounce). A non-monotone boundary means the model is wrong (loud, ship-blocking) — the 2a lesson. Counter-case per §0: an **over-capacity disturbance rate that escapes**, proving the monotone gate detects the failure. Assert the committed max-disturbance-rate is on the *tracks* side.

### 4.2 Real-rig confirmation (the model's VALIDITY gate — NOT optional) — slice 4
At the committed params, drive a sustained disturbance on the actual avatar. **"Stable" needs a reference** (every finite run is trivially bounded), so the metric is discriminating:

- **Below the committed max disturbance rate:** the residual (CoM offset past support, on the posed rig) **holds/contracts — does not grow** — beyond the ε noise floor (§4.3).
- **Counter-case (§0):** an **over-capacity disturbance rate** on the same rig makes the residual **grow/escape**, proving the rig metric discriminates track-vs-escape (not passing everything because the run is short).
- **Counter-case reachability (Minor).** Since a fast enough disturbance *always* escapes (tracking capacity is finite), the over-capacity counter-case is guaranteed reachable — escalate the disturbance rate until the residual grows; "counter-case unreachable" is never terminal.

This is the check whose absence let 2a overclaim: it catches **model-reality divergence** (the model's tracking capacity differing from the rig's, e.g. a wrong self-feedback term). **The committed max disturbance rate requires BOTH gates green. If the rig escapes at a rate the model tracks, the model is corrected, not this test waived.** (Verbatim, so Option 3 cannot decay into model-only by attrition.)

**Consequence for later increments:** the committed quantity is a **max disturbance rate**, so §5's approach-speed cap is a *hard constraint*: the crowd driver (increment-2-of-crowd) and the collision shove magnitude (increment 3) must keep the CoM disturbance under this capacity, or the stepper falls behind. `captureDistance` is a stabilizing lead knob (raise it to track faster / catch firmer), bounded above only by animation quality (a big lead reads as a lunge), not stability.

### 4.3 The slice 1 → slice 4 dependency (Push 2/3)
Slice 4's residual is computed from the posed skeleton **including the IK-placed legs** — it reads *through* the IK conversion (surface 1). A systematic IK error would bias the CoM → bias the residual → make a stable system look like it holds at a nonzero residual (false-stable) or drifts (false-cycle). Therefore **slice 4's residual measurement assumes slice 1's IK conversion is verified within tolerance ε**, and **ε from slice 1 is slice 4's residual noise floor**: "residual growing" (the stepper escaping) is only distinguishable from "residual jitter within ε" (IK placement noise) if ε is known. Slice 4 must not be trusted until slice 1 is green; this is a stated *dependency*, not just an ordering.

**Clamp guard (Minor).** ε excludes beyond-reach targets that §2.1 clamps. So slice 4 must **assert zero clamp events during the stability run** (or explicitly account for them) — a fast/large sustained disturbance that pushes capture targets to the leg's reach limit would otherwise silently void the ε noise floor the residual measurement depends on.

---

## 5. Decomposition (task-gated slices)

1. **IK executor + isolated known-target correctness gate.** `update(...)` + the world→local conversion; slice-1 gate asserts ankle-at-target within ε across a target range + leg configs; ε stated explicitly. *(Measurement foundation for slice 4.)*
2. **Real-rig follow/moonwalk + non-interference + the restore-IK polygon gate.** Includes the Redline-1 gate: under a driven root, assert the support-polygon corners at decision time match `plantedPositions` within tolerance (proves restore-IK, step 2 of §2, feeds `evaluate` the controller's feet, not the clip's skating positions).
3. **Moving-CoM model stability gate** — with the swung-leg self-feedback term (§4.1); monotonicity hard-asserted across `captureDistance`; just-over-the-line cycling counter-case.
4. **Real-rig stability confirmation** — committed `captureDistance` holds/contracts, over-gain counter-case grows; residual measured through the IK with ε (from slice 1) as the noise floor; wire "committed `captureDistance` requires both gates green" into the provisional-defaults framing (promote them from "provisional pending 2b" to "validated" only when both gates are green).

---

## 6. Non-goals (2b)

- **Crowd wiring / visible demo** — still deferred; 2b proves the actuator + stability single-avatar headless.
- **Collision → stagger impulse** (increment 3) — the thing that drives the arrest regime in anger; 2b's stability is driven by a *synthetic* sustained disturbance.
- **Upright root recovery** (increment 4).
- **Predicted-target follow-plant as default** (stays off; the speed cap is the default per 2a §5).
- **Gait / turning / uneven ground / double-support polish** — single flat `groundY`, discrete catch-steps.
