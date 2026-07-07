# Stagger Impulse — Cross-Avatar Collision → Balance Step — Design

**Date:** 2026-07-07
**Status:** Ratified (brainstorm complete); review feedback applied 2026-07-07 (contact-onset gating, return-glide made explicit, capacity-margin clarifications, `StaggerShoveSolver` naming); ready for planning.
**Increment:** 3 of the cross-avatar-collision north-star ("two avatars collide, stagger, and stay upright"). Builds directly on **Increment 2** (balance model + capture-step controller) and the shipped **cross-avatar body-response** feature (`PosturalContactSolver`, `PosturalContactLayer`, `CrowdFrameStepper`, contact collider snapshot).

**Scope:** Convert the *existing* contemplative crowd contact into a **ground-plane center-of-mass displacement** that the already-built capture-step controller absorbs by **stepping** — so at deeper overlap an avatar visibly staggers a foot to keep its balance instead of only leaning. Strictly kinematic, no momentum. The displacement is rate-limited to sit **under the rig-confirmed ~0.2 m/s tracking capacity** validated in Increment 2, so the avatar stays upright.

**Depends on:**
- `CaptureStepController` (Increment 2) — reads the model's root/CoM, restores planted feet to world pivots, steps a foot when the support margin is lost. Validated: rig tracks a CoM disturbance up to ~0.2 m/s (holds through 0.2, escapes by 0.3).
- `PosturalContactSolver.penetration(point:capsuleP0:capsuleP1:radius:)` — yields `(depth, pushDir)` of a point (this avatar's chest) into a partner torso capsule. Reused verbatim as the contact signal.
- `CrowdFrameStepper.step()` — the per-frame phase pipeline (0a animation → 0b/0c root placement + Component-A clamp → 0d postural lean → `exchange()` snapshot → spring solver → render).

---

## 1. Framing — what this crosses, and what it deliberately does not

The shipped body-response feature makes the **upper body lean** away from a penetrating partner (postural yield) and clamps torso overlap (Component A). Its §5 finding is that **the lean is self-relieving**: leaning away reduces penetration, so the system settles at a shallow lean. The lean therefore rarely shifts the center of mass far enough to threaten balance.

Increment 3 crosses one new boundary, minimally: it adds a **whole-body CoM displacement** channel — a "shove" — driven by the same penetration signal, that *is* strong enough to move the CoM past the support margin and force a **capture step**. The upper-body lean stays exactly as shipped; the shove is a separate, complementary channel (lean = visual upper-body yield; shove = whole-body stagger + step).

**Held lines (out of scope):**
- **No momentum / no dynamics.** The displacement is a position-driven, rate-limited function of the *current* penetration. It does not integrate velocity, coast, or persist after contact. (Confirmed user choice, consistent with Increment 2's fully-procedural architecture.)
- **No rigid-body / ragdoll / IK-avoidance.** Same line the body-response feature held.
- **No upright recovery.** When contact ends the shove goes to zero and the feet stay where they stepped; walking the stance back to neutral is **Increment 4**, a separate sub-project.
  - *Return-glide (intentional):* the offset's decay-to-zero on separation returns the **root** to its scripted placement at ≤ `velocityCap`, so the controller may lose the support margin in reverse and take a step **back**. The avatar steps out, then steps back — that return-glide is a deliberate consequence of strict coupling and is distinct from Increment 4's stance re-centering (which walks the **feet** back to neutral under a settled root). A *latched* offset (held after separation) would be equally momentum-free but leaves permanent state in the solver; decay-to-zero is the chosen behaviour and G2 tests it.

**The architectural invariant (why the shove is a root offset, not a controller change):** Increment 2 validated one disturbance channel — *the root translates, the planted feet are held at their world pivots, the controller sees the CoM drift past the held support and steps.* Increment 3 rides that exact channel: the shove is an additive lateral offset on the **scene root**, applied in the kinematic phase before the capture-step controller runs. The controller is used **unchanged**. This keeps the integration gate exercising the precise path Task 4 confirmed, rather than a new, unvalidated input path (the controller's reserved `rootVelocity` hook stays unused).

---

## 2. Component A — `StaggerShoveSolver` (pure core)

A new `public struct StaggerShoveSolver: Sendable` in `Sources/VRMMetalKit/Animation/`, Metal-free and model-free, mirroring `PosturalContactSolver`'s structure so the stagger behaviour is unit-testable in isolation. (Named *shove*, not *impulse* — §1 explicitly rules out momentum, and an "impulse" type would misstate the semantics; "stagger-impulse" survives only as the increment's working name.)

**State (carried across frames):** `offset: SIMD2<Float>` — the current ground-plane (XZ) CoM displacement, initially zero.

**Params — `StaggerShoveParams: Sendable`:**
- `shoveGain: Float` — metres of CoM offset per metre of penetration depth. Amplifies a shallow (Component-A-clamped) penetration into an offset that can exceed the support margin. Calibrated in the visual spike against `bodyContactMargin` (see §5).
- `velocityCap: Float` — maximum rate of change of `offset` (m/s). **Defaulted to `0.7 × 0.2 = 0.14` m/s**, i.e. a safety fraction of the rig-confirmed ~0.2 m/s capacity, so the disturbance the controller sees stays inside the validated tracking band. This is the load-bearing tie to Increment 2. Two clarifications on the margin:
  - The measured boundary is *holds at 0.2, escapes by 0.3* — 0.2 is the last **known-good** point, not the cliff. The cap bounds the **shove component only**; the controller sees total CoM velocity, which also includes animation sway and any residual clamp/part motion. The 0.3× margin is what absorbs those uncapped contributions (and the G5 fixture zeroes scripted root motion so the shove is the dominant disturbance, per the §3 activation rationale).
  - For a more dramatic stagger, raise `shoveGain` (displacement magnitude — forces bigger/multiple steps, not capacity-bounded), **not** `velocityCap`.

**Method:**
```swift
mutating func update(depth: Float, pushDirXZ: SIMD2<Float>, dt: Float) -> SIMD2<Float>
```
1. **Target:** `let target = depth > 0 && length(pushDirXZ) > εdir ? shoveGain * depth * normalize(pushDirXZ) : .zero` (zero and well-defined when there is no contact or the push direction is degenerate).
2. **Rate-limited move toward target** (first-order rate limiter — converges to `target`, never overshoots, never coasts, so no momentum):
   ```
   let delta = target - offset
   let maxStep = velocityCap * dt
   offset += length(delta) <= maxStep ? delta : normalize(delta) * maxStep
   ```
3. Return `offset`.

On separation (`depth → 0`) the target becomes zero and `offset` ramps back to zero at `≤ velocityCap`, so there is no snap as the partner withdraws (the crowd part-phase is gradual). Deterministic; no wall-clock, no randomness.

---

## 3. Component B — Crowd wiring (`Phase 0e` in `CrowdFrameStepper`)

`CaptureStepController` is **not yet wired into the crowd path**; Increment 3 wires it in as the mechanism the shove drives.

**Construction:** a new optional `stagger: StaggerShoveParams?` parameter on `CrowdFrameStepper.init` (nil ⇒ stagger off), parallel to the existing `postural:` parameter. When enabled, the stepper builds, per avatar:
- one `StaggerShoveSolver` (with `stagger` params),
- one `CaptureStepController` built with the **committed arrest defaults** (`captureDistance = CaptureStepParams.committedCaptureDistanceMax`, `stepDamping = CaptureStepParams.committedStepDampingMin`) — the exact configuration the ~0.2 m/s capacity was validated with (`testRigTrackingCapacity_belowHolds_overCapacityGrows`); the plain `CaptureStepParams()` defaults are the *follow* regime and carry no validated capacity. Initially **dormant**.

**Activation — contact-onset gating (per avatar):** the stagger channel is dormant until the first frame with `depth > 0`. On that frame the controller is **seeded from the avatar's current left/right ankle world positions** via `seed(leftAnkle:rightAnkle:)`, and both solver and controller run every frame thereafter. Rationale: Phase 0b's scripted approach translates the root the whole run; a controller live from frame 0 would pin the feet at their frame-0 world pivots and read the approach itself as a CoM disturbance — spurious capture steps during approach, or escape before contact ever occurs, contaminating G5/G6's residual. Once contact starts, the Component-A clamp pins separation at the margin, so scripted root motion is ≈ 0 during hold and the shove is the dominant disturbance — the regime the §2 capacity tie assumes. The part-phase's scripted withdrawal overlaps the offset decay; both are small, rate-limited, and same-order (see §1's return-glide note).

**Phase 0e — after 0d (postural lean), before `exchange()`:** for each avatar, when stagger is enabled:
1. Read the nearest partner torso capsule (already gathered for 0d when `needsTorsos`) and this avatar's **chest** world position — compute `(depth, pushDir)` via `PosturalContactSolver.penetration`. Project `pushDir` to the ground plane (XZ), drop the vertical component.
2. If the channel is still dormant and `depth > 0`, activate: seed the controller from the current ankle world positions (see Activation above). While dormant, skip steps 3–5 (the frame is byte-identical to the stagger-off path until first contact).
3. `let offset = staggerSolver.update(depth: depth, pushDirXZ: pushDirXZ, dt: frameDt)`; apply `offset` additively to the **scene root translation** (on top of 0b's placement), then `avatar.model.updateNodeTransforms()`.
4. `captureStepController.update(deltaTime: frameDt, model: avatar.model)` — restores planted feet to their world pivots (they do **not** follow the root shove), evaluates the shoved CoM against the held support, and steps a foot if the margin is lost. The controller writes leg bones via IK.
5. `avatar.model.updateNodeTransforms()` so `exchange()` snapshots the stepped pose.

`frameDt` is the real per-frame `dt` already threaded through the crowd path (the `--realtime`/frame-time value; §ordering note: the stagger and stepper are position-driven, so they use the same `dt` the postural solver uses).

**Accessors** (mirroring `posturalLayer(forAvatar:)`): `staggerSolver(forAvatar:)` and `captureStepController(forAvatar:)` for test inspection.

---

## 4. Component C — Renderer flag

A `--stagger` flag on `VRMVideoRenderer` (`Sources/VRMVideoRenderer/main.swift`), parallel to the existing `--postural` / `--body-contact-margin` flags, constructing `StaggerShoveParams` and passing it to the crowd `CrowdFrameStepper`. Enables the feature in the crowd `.mov` demo. Off by default (opt-in), so existing renders are byte-unaffected.

---

## 5. The Component-A tension (calibration risk, not an architectural unknown)

Component A clamps torso overlap to a small `bodyContactMargin` to prevent deep clip-through. Strict coupling means the shove target ∝ penetration depth, so a small clamped overlap yields a small raw depth. The resolution is **`shoveGain`**: even a few-centimetre penetration, amplified by `shoveGain`, produces a CoM offset that exceeds the support margin and triggers a step, while `velocityCap` keeps that offset trackable. Component A stays intact (no deep clip-through); the stagger still fires.

Why the resolution works mechanically: because Phase 0b re-places the root from the script every frame, the penetration read in Phase 0e is computed from the **un-shoved** pose — the shove does not feed back into its own signal the way the lean does (§1). As long as the clamp maintains margin-overlap, `depth` holds steady and the offset **saturates** at `shoveGain · depth` instead of self-relieving to zero. This is exactly the property the lean lacks. (The lean *does* still relieve the signal — Phase 0e reads the chest after 0d — which is what G6 measures.)

Whether the clamped-overlap penetration signal is large enough to drive a convincing stagger is a **calibration** question the visual spike resolves — by tuning `shoveGain` (and, if needed, feeding the chest-into-partner-torso penetration, which is nonzero even at the torso-torso margin because the chest sits forward of the torso axis) — exactly as `PosturalContactParams.kGain` was tuned against `bodyContactMargin`. It is **not** an architectural unknown: the channel and its capacity bound are fixed; only the gain is empirical.

---

## 6. Testing — every gate ships a discriminating counter-case

Carried directly from Increment 2's gate discipline: **a gate whose pass side can pass without exercising the mechanism is measuring the wrong thing.** Each gate below names the counter-case that must *fail*. Confirm-the-model gates use the model's own metric (residual contraction), not a proxy.

### 6.1 Solver gates (pure, CI-safe, no GPU)

**G1 — Rate-cap binds.** A fast-deepening penetration (large `depth` step in one frame) produces a per-frame `|Δoffset| ≤ velocityCap · dt`.
*Counter-case:* with `velocityCap` set effectively infinite, the same input produces `|Δoffset| > velocityCap · dt` — proving the cap actually binds and the pass is not vacuous (a slow input would satisfy the bound trivially).

**G2 — Zero-on-separation (no momentum).** After a contact ramp, hold `depth = 0`: `offset` decays to `≈ 0` within `⌈length(offset)/(velocityCap·dt)⌉` frames and *stays* zero.
*Counter-case:* a velocity-integrating (momentum) variant retains a non-zero residual offset after separation. This is the strict-coupling proof.

**G3 — No overshoot at target.** With a constant `depth`, `offset` converges monotonically to `shoveGain · depth · d̂` and holds — it never exceeds the target magnitude.
*Counter-case:* a second-order integrator overshoots the target on the way in. Proves position-driven, not ballistic.

**G4 — Direction.** `offset` points along `pushDirXZ` (away from the partner) to within ε, for several `pushDir` orientations.
*Counter-case:* a sign flip (offset toward the partner) fails. Direct-measurement metric → rigor from orientation coverage + tight ε, per the §0 rule (no vacuous-pass risk to counter).

### 6.2 Integration gate (rig + GPU — the load-bearing one)

**G5 — Stagger-stays-upright, and the capacity tie is real.** In the crowd + real-rig path, drive an **escalating penetration** (ramp `depth` up over the run) with `velocityCap` **under** the rig capacity (the 0.14 m/s default):
- the avatar **steps** — a foot transitions to swing at least once (`plantedFeet` drops to one), and
- it **stays balanced** — the residual *contracts*: `tail ≤ peak · 0.5 + ε`, the **same** metric Increment 2's Task 3/4 gates use.

*Counter-case (non-negotiable):* set `velocityCap` **over** the rig's 0.2–0.3 escape boundary (e.g. 0.4 m/s) → the residual **grows** (`tail ≈ peak`, escape). Without this counter-case "gentle shove stays balanced" passes vacuously (a gentle shove never threatens balance); with it, the gate proves the north-star claim — *a shove within the validated capacity staggers but stays upright; one over it falls.*

*Fixture constraints:* (a) scripted root motion is zeroed (hold-only driver) so the shove is the only root disturbance — the §2 capacity tie assumes this; (b) the pass side's "steps at least once" depends on `shoveGain · depth_max` exceeding the support margin, so the visual-spike calibration of `shoveGain` (§5) must **precede** authoring this gate, or a fail is ambiguous between mechanism and tuning.

**G6 — Self-relief independence.** Run G5's under-capacity case with the **postural lean active**. The step still fires — proving the shove channel triggers the stagger independently of the self-relieving lean (validates the §5 tension resolution directly). Folds into G5's fixture setup (postural on).

### 6.3 Determinism / no-op

**G7 — Disabled is a no-op.** With `stagger: nil`, `CrowdFrameStepper.step()` leaves every avatar's leg bones and root byte-identical to the pre-Increment-3 path (opt-in guarantee; existing renders unaffected).

---

## 7. Non-goals (explicit)

- **Upright recovery** (walking the stance back to neutral after contact) — Increment 4.
- **Momentum / follow-through / recoil** — ruled out; strict contact-coupling only.
- **Per-avatar mass/scale weighting of the shove** — uniform `shoveGain` in v1, matching the postural yield's uniform-in-v1 stance.
- **Vertical disturbance / lifting / knock-down** — ground-plane XZ only; the avatar stays upright by construction (that is the whole point).
- **Rigid-body contact resolution** — the shove is a one-way read of penetration into a CoM offset, not a solved contact.

---

## 8. File map

- **Create:** `Sources/VRMMetalKit/Animation/StaggerShoveSolver.swift` (Component A: `StaggerShoveParams` + `StaggerShoveSolver`).
- **Modify:** `Sources/VRMMetalKit/Crowd/CrowdFrameStepper.swift` (Component B: `stagger:` init param, per-avatar solver + `CaptureStepController`, Phase 0e, accessors).
- **Modify:** `Sources/VRMVideoRenderer/main.swift` (Component C: `--stagger` flag).
- **Create:** `Tests/VRMMetalKitTests/Animation/StaggerShoveSolverTests.swift` (G1–G4).
- **Create:** `Tests/VRMMetalKitTests/Crowd/StaggerShoveIntegrationTests.swift` (G5–G7).
