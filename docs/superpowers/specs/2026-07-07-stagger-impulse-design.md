# Stagger Impulse — Cross-Avatar Collision → Balance Step — Design

**Date:** 2026-07-07
**Status:** Ratified (brainstorm complete); review feedback applied 2026-07-07 (contact-onset gating, return-glide made explicit, capacity-margin clarifications, `StaggerShoveSolver` naming); ready for planning.
**Increment:** 3 of the cross-avatar-collision north-star ("two avatars collide, stagger, and stay upright"). Builds directly on **Increment 2** (balance model + capture-step controller) and the shipped **cross-avatar body-response** feature (`PosturalContactSolver`, `PosturalContactLayer`, `CrowdFrameStepper`, contact collider snapshot).

**Scope:** Convert the *existing* contemplative crowd contact into a **ground-plane center-of-mass displacement** that the already-built capture-step controller absorbs by **stepping** — so at deeper overlap an avatar visibly staggers a foot to keep its balance instead of only leaning. Strictly kinematic, no momentum. The displacement is rate-limited to sit **under the rig-confirmed ~0.2 m/s tracking capacity** validated in Increment 2, so the avatar stays upright.

**Depends on:**
- `CaptureStepController` (Increment 2) — reads the model's root/CoM, restores planted feet to world pivots, steps a foot when the support margin is lost. Validated: rig tracks a CoM disturbance up to ~0.2 m/s (holds through 0.2, escapes by 0.3).
- `PosturalContactSolver.penetration(point:capsuleP0:capsuleP1:radius:)` — yields `(depth, pushDir)` of a point (this avatar's chest) into a partner torso capsule. This remains the **postural lean's** chest signal only; the stagger's contact signal is the **torso-pair surface overlap** via `CrowdContactClamp` (own capsule read fresh, partner from the lagged snapshot — see §3 step 1's amendment).
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
1. Read the nearest partner torso capsule (the lagged snapshot gathered when `needsTorsos`) and this avatar's **own torso capsule** (computed fresh, post-placement — the frame-0 lagged snapshot predates Phase 0b placement, where all avatars still sit coincident at their base pose and a stale-stale pair reads a large spurious overlap that would permanently latch activation) — compute `depth` as the **torso-pair surface overlap** (`radiusA + radiusB − segmentDistance`, the exact quantity Component A's clamp measures via `CrowdContactClamp`) and `pushDir` as the closest-point delta (own − partner, away from the partner). Project `pushDir` to the ground plane (XZ), drop the vertical component. *(Amended 2026-07-07 after the visual spike: the original chest-point-into-partner-capsule signal is structurally zero at the clamp floor — `torsoCollider` is built spine→chest, so the chest sits ON its own torso axis and only penetrates the partner capsule when the axes are within one radius (~0.10 m), which the margin clamp (axes held at ~0.19 m) prevents by construction. The torso-overlap signal is nonzero exactly when the bodies are in contact, and equals `bodyContactMargin` at the clamp floor.)*
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

Why the resolution works mechanically: because Phase 0b re-places the root from the script every frame, the **own-side** signal is computed from the un-shoved pose — an avatar's shove does not feed back through its own root. There *is* a partner-side feedback (the lagged partner snapshot carries the partner's applied offset, so a mutual shove separates the pair and `depth` settles at an equilibrium `offset ≈ d₀ · g/(1+g)` — see G5's amendment), but the equilibrium displacement is ≈ the initial contact depth itself, which at genuine contact exceeds the ~0.1 m support half-width and fires the step before settling. Unlike the lean, the signal never self-relieves to zero while the bodies remain in proposed overlap. (The lean *does* still relieve its chest signal — Phase 0e runs after 0d — which is what G6 measures.)

Whether the clamped-overlap penetration signal is large enough to drive a convincing stagger is a **calibration** question the visual spike resolves — by tuning `shoveGain` — exactly as `PosturalContactParams.kGain` was tuned against `bodyContactMargin`. It is **not** an architectural unknown: the channel and its capacity bound are fixed; only the gain is empirical.

*(Spike outcome, 2026-07-07: the risk materialized against the original chest-point signal — it is identically zero at the clamp floor (see §3 step 1's amendment), and the anticipated "chest sits forward of the torso axis" fallback is false for this rig's spine→chest torso capsule. Resolved by switching the depth signal to the torso-pair overlap Component A already measures: at the clamp floor `depth = bodyContactMargin` exactly, so the §5 amplification argument holds with `target = shoveGain · bodyContactMargin` — e.g. gain 6–15 × margin 0.02 → 0.12–0.30 m of CoM offset, past the ~0.1 m support half-width. The channel, capacity bound, and controller are untouched.)*

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

**G5 — Stagger-stays-upright, and the step is what keeps it upright.** In the crowd + real-rig path, at deep constant overlap with `velocityCap` at the 0.14 m/s default:
- the avatar **steps** — a foot transitions to swing at least once (`plantedFeet` drops to one), and
- it **stays balanced** — the residual *contracts*: `tail ≤ peak · 0.5 + ε`, the **same** metric Increment 2's Task 3/4 gates use.

*Counter-case (non-negotiable) — step-suppressed:* the same shove with the controller's step trigger made unreachable (`triggerMargin` set below any attainable margin via the test accessor; feet still restored/pinned, no capture step can fire) → the residual reaches a real peak and **fails to contract** (`tail > peak · 0.5 + ε`). This isolates the north-star mechanism directly: *the shove displaces the CoM past the support margin, and it is the capture step — nothing else — that brings the avatar back.*

*Rate discriminator:* `velocityCap = 0.4` (over the rig's sustained-drive boundary) must produce a materially larger residual **peak** than 0.14 (≥ 2×) while **still contracting** — the cap is load-bearing for how far balance transiently degrades, and the contraction at 0.4 documents the self-limiting property below.

*(Amended 2026-07-07, gate authoring: the original over-capacity **escape** counter-case is structurally unrealizable in the mutual-contact fixture — and the reason is a safety property, not a bug. Both avatars shove; each reads its partner from the lagged snapshot, which includes the partner's own applied offset, so the pair separates and `depth` collapses to an equilibrium `offset ≈ d₀ · g/(1+g)` (measured: pinned at ~0.13 m across velocityCap 0.14→2.0 and targets 1.5→7 m). Total CoM displacement is bounded by the initial penetration depth regardless of rate or gain — the crowd shove **cannot** produce a sustained over-capacity drive, so the rig always recovers. §5's no-self-relief argument covered the own-root reset (Phase 0b) but missed the partner-side feedback. Escape under sustained drive remains proven where it is realizable: Increment 2's rig gate (`testRigTrackingCapacity_belowHolds_overCapacityGrows`, holds at 0.2, escapes by 0.3). The `velocityCap = 0.14` default stays as defense-in-depth on the transient, with G1 proving the cap binds.)*

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
