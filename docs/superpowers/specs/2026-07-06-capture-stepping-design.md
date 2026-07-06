# Capture-Stepping Controller — Design

**Date:** 2026-07-06
**Status:** Design approved. Increment 2 of the procedural staggering north star — the first *actuator*.
**Scope:** A procedural, kinematic controller that keeps an avatar's feet under its center of mass by taking **capture steps**: it locks planted feet as world-space pivots and, when the balance margin drops, swings a foot toward the CoM and re-plants. Library-only this increment; validated single-avatar headless. Fixes the moonwalk (as a follow-stepping case) and is the recovery mechanic a collision shove (increment 3) will drive.

**Depends on:** the balance model (`BalanceModel.evaluate` → `BalanceState`: CoM, `margin`, `imbalanceDirection`, `supportPolygon`, `plantedFeet` parameter) and the existing `TwoBoneIKSolver` (hip→knee→ankle leg IK, already used by `IKLayer`).

---

## 1. Framing — where this sits, and what it is

**North star (agreed):** two colliding avatars *stagger and react to gravity while trying to stay upright*, **fully procedural / kinematic** (no rigid body, no ragdoll). Decomposition: (1) balance model — **done**; (2) **capture stepping — this spec**; (3) collision → stagger impulse; (4) upright recovery.

**The mechanic — capture step.** A biped stays up by keeping its base of support under its CoM; when the CoM moves toward the edge, it steps *toward where it is falling* to re-establish support. This controller does exactly that, procedurally: planted feet are world-space pivots (the leg IK bends to hold the ankle at a fixed world point as the body moves over it), and when the balance margin drops below a threshold it swings the trailing foot to a target derived from the CoM and re-plants.

**Root as input, not output.** The controller **never moves the root**. The root's motion is an *input* — supplied this increment by a test's scripted root motion, later by `CrowdPlacement`'s scripted approach (increment 2 of the crowd) or a collision shove (increment 3). The feet **follow or catch** the root-driven body; they do not cause its trajectory. This is load-bearing — see §2.

**Grounded override (ratified).** When enabled, the controller takes over both legs — the feet become world pivots instead of following the source clip's foot motion. Half-measures (blending IK against the clip's own foot motion) fight the clip's skate and read as sliding-with-hitches. Discarding the idle's foot motion while active is the correct trade; IK↔clip blending is a deferred polish increment. The controller's "≥1 foot planted at all times" invariant (§3) is what makes `BalanceModel`'s `plantedFeet` parameter usable mid-step — the override scope and the increment-1 API are consistent by construction.

**Library-only this increment.** No crowd wiring, no render. Validated on single-avatar headless tests (§7). The crowd/visible demo comes *after* the controller is proven in isolation — see §7 for why.

---

## 2. The feedback edge — READ THIS BEFORE RAISING `captureDistance`

**This section documents a feedback loop that is not obvious from the code and the reason it is bounded. If you are extending this controller and tempted to raise `captureDistance` for a snappier catch, this is the section that says why you must not do so past its cap.**

`BalanceModel`'s support polygon **is** the planted feet. So `margin = f(CoM, plantedFeet)`, and this controller decides *where to plant* from `margin` and `imbalanceDirection`. That closes a loop:

```
plantedFeet ──> margin ──> step decision ──> plantedFeet
```

The planted foot positions are **stored cross-frame state** (they persist as world pivots). No velocity is integrated — but the loop is live anyway, because next frame's support (and thus next frame's margin, and thus the next step) depends on where this frame's step planted. This is the CoM→root feedback the balance design forbade, arriving through the **feet** instead of through momentum. It is **capture-point control**, and unbounded capture gain **oscillates** (a limit cycle: a step plants support past the CoM, over-recovers the margin, the disturbance re-drags, re-trips — and the stepping *rhythm* couples to the disturbance rate).

`captureDistance` — how far *beyond* the CoM the foot lands — **is the capture-gain term in this loop.** It is not a free "firmness" knob. Raising it past the stability cap reintroduces the oscillation. It is bounded above by the no-overshoot / stability-region constraint (§6), calibrated visually, and is this increment's highest-risk parameter.

The loop is bounded by splitting `captureDistance`'s two collapsed roles into two regimes:

- **Follow (driver-driven motion, `captureDistance ≈ 0`).** When the root's motion is an external *input* (the scripted crowd approach), the body's progress is not emergent — so the feet must *follow*, planting **under** the CoM, never beyond it. A plant under a driver-driven CoM merely re-centers support and resets the margin: no overshoot, loop provably non-oscillating (the body is an input, not a consequence of the plant). This is the moonwalk fix.
- **Arrest (the shove is the input, `captureDistance > 0`, damped).** When steps genuinely *drive* the recovery (a collision shove, increment 3), the foot lands *beyond* the CoM to catch it, and convergence is guaranteed by damping — each step corrects a fraction of the residual imbalance, with the pair `(captureDistance, stepDamping)` held inside the joint stability region (§6).

Same controller, two regimes selected by parameters. **The follow case cannot oscillate (gain 0); the arrest case converges geometrically iff the loop gain stays under 1 (§6).** Do not collapse these back into one aggressive "always catch beyond the CoM" behavior — that is the limit cycle.

---

## 3. `CaptureStepController` — shape & state

A `public final class CaptureStepController` (procedural, kinematic, Metal-free). It **reads** `BalanceModel` (computing `evaluate` with its own current planted-feet set) and **writes** leg-bone rotations via `TwoBoneIKSolver`. It owns:

- `params: CaptureStepParams` (§6).
- Per-foot state, `left` and `right`, each:
  - `.planted(worldTarget: SIMD3<Float>)` — the ankle is IK-locked to this world point.
  - `.swinging(from: SIMD3<Float>, to: SIMD3<Float>, elapsed: Float)` — mid-step.
- **Invariant: at least one foot is `.planted` at all times** (never double-swing). The planted foot(feet) are the `plantedFeet` the controller passes to `BalanceModel.evaluate`.
- A rate-limit timer (`timeSinceLastStep`) so step frequency cannot couple to the disturbance rate (§6).

Lifecycle: `initialize(with:)` captures leg geometry (bone lengths) and seeds both feet `.planted` at their current world ankle positions. `update(deltaTime:model:rootVelocity:)` advances one frame and writes leg rotations. `rootVelocity` is **optional and defaults to zero** — it is used only by the predicted-target escape hatch (§5); the controller is velocity-free in its default (cap-approach-speed) configuration.

Test-visible accessors: each foot's state, its planted world position, and swing phase — so the headless tests can assert plant-then-step, the ≥1-planted invariant, and convergence.

---

## 4. Per-frame algorithm

Given the model already posed for this frame (clip + root motion applied, `updateNodeTransforms` run):

1. **Read balance.** `let b = BalanceModel.evaluate(model: model, plantedFeet: currentlyPlantedSet)`. If `nil` (no support), hold — do nothing this frame.
2. **Advance any swinging foot.** Interpolate `from → to` by `elapsed / swingDuration`, eased, with a `stepHeight` lift arc (peaks mid-swing, returns to ground at the ends). On `elapsed ≥ swingDuration`, transition to `.planted(to)`.
3. **Decide a step** (only if both feet planted and `timeSinceLastStep ≥ minStepInterval`): if `b.margin < triggerMargin`, choose the **trailing foot** (the planted foot on the far side of `b.imbalanceDirection` — the one *not* in the direction of the fall, so the swung foot moves toward the CoM), compute its target (§5), and enter `.swinging(from: currentPlant, to: target, elapsed: 0)`. Reset `timeSinceLastStep`.
4. **IK both legs.** For each leg, `TwoBoneIKSolver` solves hip→knee→ankle to place the ankle at its current target (a planted foot's lock, or a swinging foot's arc point); write the hip and knee rotations onto the model's leg bones.
5. Advance timers.

During a driver-driven approach, the dragged CoM repeatedly trips step 3 → a sequence of **follow** steps (§5) that carry the feet along under the moving body — real footfalls, not a skate. Under a shove (increment 3), the same path fires **arrest** steps.

---

## 5. Step placement — follow vs. arrest

The target for a step is computed from the balance state:

```
rawTarget_xz = b.comGround + b.imbalanceDirection × captureDistance
```

- **`captureDistance == 0` (follow):** `rawTarget_xz = b.comGround` — the foot plants **under** the CoM. Used when the root is driver-driven. **Gain 0 → cannot oscillate.**
- **`captureDistance > 0` (arrest):** the foot plants **beyond** the CoM, toward the fall, to catch it. **Damped** (below): the actual target steps only a fraction of the way, so the recovery converges.

**Damping (arrest).** Rather than planting at `rawTarget` outright, the step corrects a fraction of the residual:

```
plantTarget_xz = supportCentroid + (1 − stepDamping) × (rawTarget_xz − supportCentroid)
```

`stepDamping ∈ [0, 1)`: higher = more damped = smaller step = safer/slower. The effective per-step loop gain is `(1 − stepDamping) × k(captureDistance)`, where `k` grows with `captureDistance` (§6). This is the term that must stay < 1.

**Follow uses `stepDamping = 0`** — with `captureDistance = 0` and `stepDamping = 0` the formula collapses to `plantTarget_xz = comGround` (foot exactly under the CoM). Damping short of the CoM would land the foot behind it and reintroduce the very lag §5 warns about; damping is an *arrest*-regime knob only.

The ankle target's height is the foot's rest ground height (captured at `initialize`), so `plantTarget = (plantTarget_xz.x, restFootY, plantTarget_xz.y)`.

**The follow swing-lag (state it, don't paper over it).** Follow-plant targets the CoM **at trigger time**, but the foot lands `swingDuration` later. If the driver-driven CoM moves fast relative to `swingDuration`, the foot chronically plants *behind* the CoM → margin stays marginal → immediate re-trip → a degenerate high-frequency **shuffle** (not a limit cycle — no overshoot — but bad). Resolution, in order of preference:
1. **Cap the approach speed** at the *driver* so CoM travel during `swingDuration` is a small fraction of the support half-extent. This keeps the controller **velocity-free** (no velocity input), consistent with the no-integrated-momentum discipline, and pushes the constraint into the driver where it is a content knob. **Follow-plant assumes approach-speed-under-threshold**, enforced by the root's driver (the test this increment; `CrowdMotionDriver` later).
2. **Escape hatch (documented, not default):** if a faster approach is ever required, target the *predicted* CoM `b.comGround + rootVelocity × swingDuration` (lead the target by the swing lag). This needs a `rootVelocity` input (§3's optional param) and is the only reason that param exists; it is off by default.

"Plant under the CoM" therefore means **trigger-time CoM under the approach-speed cap**, with predicted-CoM as the explicit upgrade path.

---

## 6. Parameters & the joint stability region

| Param | Regime | Meaning |
|-------|--------|---------|
| `triggerMargin` | both | Step when `BalanceState.margin` drops below this (how close to the edge before stepping). |
| `captureDistance` | arrest | Distance **beyond** the CoM the foot reaches for. `0` = follow (under CoM). **The capture-gain term in the §2 feedback loop — bounded above by the stability region below, NOT a free firmness knob.** |
| `stepDamping` | arrest | Fraction of the step held back (`[0,1)`; higher = smaller, safer step). Compounds with `captureDistance` into the loop gain. |
| `swingDuration` | both | Seconds per swing; sets the follow swing-lag (§5). |
| `stepHeight` | both | Peak of the swing lift arc. |
| `minStepInterval` | both | Rate limit — minimum time between steps, so step *rhythm* cannot couple to the disturbance rate. |

**The stability region is joint, not two independent bounds.** The arrest recurrence for the residual imbalance `r` (horizontal CoM offset past the support) is approximately:

```
r_{n+1} = r_n · (1 − (1 − stepDamping) · k(captureDistance))
```

The loop gain `L = (1 − stepDamping) · k(captureDistance)` is the **product** — `captureDistance` and `stepDamping` are *not* independently safe. Monotone convergence requires `0 < L < 1`; `1 ≤ L < 2` is damped-oscillatory; `L ≥ 2` diverges. The usable parameter space is the region `{ L < 1 }`, and the two knobs must be tuned as a pair inside it. **Tuning `captureDistance` up after fixing `stepDamping` can silently push `L` back over 1 and re-oscillate** — this is the §2 trap. `captureDistance` is this increment's torso-capsule: no precedent, sits on the watched surface, calibrated visually — and additionally the loop-stability term, bounded above jointly with `stepDamping`.

**CORRECTION (2a review): the stability guarantee is NOT established in 2a — it is inherently 2b.** An earlier draft claimed a 2a "corner test" *brackets* the `L = 1` boundary. That was wrong, and a parameter sweep proved it. **The §2 limit cycle is a moving-CoM phenomenon** — a step over-recovers the margin, *the disturbance re-drags the CoM*, and it re-trips; the re-drag is the CoM moving in response to the plant and the ongoing disturbance. 2a's validation model **freezes the CoM** (§7), so there is no re-drag, so no cycle can occur under it — and under a fixed CoM the two-foot capture recurrence contracts across essentially the whole committed `captureDistance` range (swept: 0.05–0.30 all contract; there is **no monotone `L = 1` boundary for 2a to bracket**). A "convergence" test under a frozen CoM measures the step *placement math*, not the stability of the loop. **Stability lives in the CoM-response, and the CoM-response is 2b's domain**, so the stability gate — the one that catches the limit cycle — is a **2b moving-CoM test against the real rig** (§7). 2a proves the step *logic* (correct trailing foot, placement, damping, ≥1 planted); it cannot prove the closed loop is stable, because it stubs the CoM-response with a constant. The committed `(captureDistance, stepDamping)` are therefore **provisional defaults pending 2b's stability validation**, not proven-stable bounds.

---

## 7. Testing — the gate

**Validation = single-avatar headless.** This is the first *actuator*: two things can now be independently wrong — the **step logic** (trigger/placement/swing/state machine) and the **IK** (does `TwoBoneIKSolver` put the ankle where the target says) — plus the §2 feedback edge. Wiring straight into the crowd would confound all three with mutual approach + two avatars + the composite on a *visual* surface. So, exactly as increment 1 was "approve on tests, not a render," increment 2 is **approve on single-avatar headless tests**; the crowd/visible demo is a *separate step after* the controller is proven. 2a's tests prove the step *logic* and *contraction under the fixed-CoM model* — they are **not** the stability gate (see the §6 correction: the limit cycle is moving-CoM, hence 2b).

**Pure (no Metal, no model):**
- **Trailing-foot selection:** given `imbalanceDirection`, the chosen swing foot is the one on the far side of the fall (so the swing moves toward the CoM).
- **Capture-target math:** follow (`captureDistance = 0`) → target = `comGround`; arrest → target = `supportCentroid + (1−stepDamping)·(rawTarget − supportCentroid)`; matches hand-computed values.
- **Swing arc:** phase monotonic in `elapsed`; endpoints hit `from`/`to`; lift peaks mid-swing and is zero at the ends.
- **≥1-planted invariant:** across a full step cycle the controller never has both feet swinging.

**Single-avatar headless integration (Metal device; XCTSkip if none):**
- **Follow / moonwalk fix:** drive the root laterally at a **slow (under-threshold) scripted speed**; assert (a) the planted foot **holds its world position** while the hip moves over it (plant, not slide — the foot's world position is constant between steps), then (b) a step fires and re-plants **toward the CoM**, and (c) after the step the margin recovers. Over the run the feet advance in discrete footfalls, not a continuous skate. No spurious steps when the root is still.
- **Contraction sanity-check — 2a (a floor, NOT the stability gate).** With the **CoM held fixed**, drive the controller one clean two-foot step per iteration against `BalanceModel`'s pure statics and assert the static residual reduces to near zero on the committed params. This pins that the placement/damping math reduces a residual and doesn't blow up — a regression-lock on the step logic. It is explicitly **not** a stability proof: a fixed CoM cannot exhibit the §2 limit cycle, so this test cannot catch it (§6 correction). The harness must use a real rate limit (`minStepInterval > swingDuration`) so each iteration is a genuine two-foot step, not a single-foot collapse.
- **Stability gate — 2b (the real gate, moving CoM).** Because the limit cycle lives in the CoM-response, the gate that catches it belongs in 2b, on the real rig: drive a **sustained / re-dragging disturbance** (the scripted approach, or a held shove) and assert the *actual* stepping response **does not limit-cycle** across the committed `captureDistance` range, with a just-over-the-line case that *does* cycle to prove the test discriminates. **The test must assert the pass/fail is MONOTONE in `captureDistance`** — non-monotonic pass/fail is itself the signature of a degenerate gate (it is exactly what exposed the bad 2a draft), and if 2b's stability test comes back non-monotone that signals the loop-gain *model* is wrong, not just mis-tested, before any `captureDistance` default ships.
- **Rate limit:** steps never fire closer together than `minStepInterval`, regardless of how hard the margin is violated.

**Non-interference:**
- Controller disabled ⇒ leg bones untouched (bit-identical to the input pose).

---

## 8. Non-goals (this increment)

- **Collision → stagger impulse** (increment 3) — the shove that drives the arrest regime. This increment builds and unit-tests the arrest/convergence machinery but is *driven by a test's synthetic displacement*, not a real collision.
- **Upright root recovery** (increment 4) — the torso is already handled by the postural yield; root-level upright control is separate.
- **Crowd wiring / visible demo** — deferred until the controller is proven headless (§7). The demo is not the gate.
- **IK↔clip blending** — grounded override discards the clip's foot motion while active; blending back to source leg animation is a polish increment.
- **Gait / double-support polish, turning, uneven ground** — single flat `groundY`, discrete catch-steps only.
- **Predicted-target follow-plant as default** — the escape hatch stays off; the default is cap-approach-speed (§5).
