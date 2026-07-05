# Cross-Avatar Body Response — Design

**Date:** 2026-07-05
**Status:** Design ratified (all sections approved).
**Scope:** Reduce body-on-body clip-through between avatars and make the rig visibly *yield* to contact — without a rigid-body/ragdoll engine. Two levers: contact-aware motion (bodies press to controlled contact instead of driving through) and a postural yield (the upper body leans away on contact).

**Depends on:** the shipped cross-avatar collision feature (`SpringBoneContactGroup`, `contactColliderSnapshot` world-space body colliders, `CrowdFrameStepper`/`CrowdMotionDriver`) and the animation-layer stack (`AnimationLayer`, `IKLayer`).

---

## 1. Framing — what this crosses, and what it deliberately does not

The shipped feature is **secondary-physics only**: hair/cloth spring bones yield to a partner's body, but the animation-driven **bodies interpenetrate** (no feedback from collision into the rig). This design crosses that boundary *minimally*, with two levers, and holds a hard line against a third:

- **Lever 1 — contact-aware motion** (demo-level): feed body colliders back into the motion so avatars stop at controlled contact instead of a fixed deep-overlap hold-sep.
- **Lever 2 — postural yield** (library): a stiff, procedural lean of the upper body away from a penetrating partner, so the rig visibly yields.
- **OUT of scope — lever 3:** full IK avoidance / rigid-body / ragdoll. It has real animation-quality risk, fights the source animation, and is a separate future sub-project.

**The load-bearing tension (design target):** a hug *wants* controlled overlap — arms wrap the back, chests press. The goal is **not** rigid zero-interpenetration; it is **"no deep clip-through + a visible postural yield"** with bodies allowed to press into controlled contact.

**The architectural invariant (why lever 2 is a procedural layer, not a spring chain):** the runtime pipeline is strictly unidirectional —
`kinematic animation → IK layers → secondary physics (spring bones)`.
VRM humanoid bones (hips/spine/chest/neck) are **kinematic anchors** — motion capture, tracking platforms (VSeeFace/Warudo), and network replication all assume them predictable. Routing them through the XPBD spring solver would create a nested feedback loop (spring bones lag relative to a spine that is *itself* dynamically solving), risking jitter and "noodle-spine," and would break hand/look-at IK that expects a predictable spine. So the postural yield stays **in the kinematic phase**: it computes a lean and writes the spine's local rotation *before* the spring solver runs. The chest's spring bones (hair) then **inherit the yield for free** — the solver simply reads the already-leaned spine. Unidirectional pipeline preserved.

---

## 2. Component A — Contact-aware motion (lever 1, demo-level)

In `CrowdFrameStepper.step()`, before applying the driver's translation offset, clamp the approach by body contact:

1. For each avatar, take its torso capsule and the **nearest partner's** torso capsule (from the last `contactColliderSnapshot`).
2. Compute the current body separation along the approach axis.
3. The driver *proposes* a half-separation (`CrowdMotionDriver.halfSeparation`); the stepper **clamps** the applied offset so the two torso capsules overlap by **at most `bodyContactMargin`** — bodies press to controlled contact, never to the driver's raw deep-overlap distance.

So the driver still choreographs approach/hold/part, but the stepper enforces "no deep clip-through." This lives in the crowd demo (`CrowdFrameStepper` + a new `bodyContactMargin` on the crowd path); it needs no rig or library changes.

---

## 3. Component B — `PosturalContactLayer` (lever 2, library)

A new `public final class PosturalContactLayer: AnimationLayer` — same stack slot and pattern as the foot-`IKLayer`, `affectedBones = [.spine, .chest]`. Each frame it runs this deterministic, O(1) algorithm (the ratified spec):

**A. Penetration detection.** Given the partner's torso capsule (fed per frame, §4) and this avatar's chest bone world position:
- `d` = penetration depth (overlap of this avatar's chest against the partner's torso capsule; `0` when not overlapping).
- `v̂` = normalized push direction, partner-chest → this-chest.

**B. Target lean rotation.**
- `θ_target = clamp(kGain · d, 0, maxLeanAngle)`
- axis `â = normalize(cross(spineUp, v̂))` (leans the upper body *away* from the partner)
- `q_target = angleAxis(θ_target, â)`

**C. Critically-damped smoothing** (the "yield" feel and the recovery-on-separation):
- `q_active = slerp(q_active, q_target, min(stiffness · dt, 1))`
- `q_active` is layer state carried across frames; it eases toward `q_target` on contact and back to identity when `d → 0`.

**D. Apply in the kinematic phase.** Distribute `q_active` across `spine` and `chest` (each takes a fraction, so it reads as a natural bend rather than a single hinge) and compose onto the animated rotation:
- `bone.localRotation = animRotation × q_activeShare`

Because the layer emits `ProceduralBoneTransform` rotations into the animation stack (before the spring solver), the chest's spring bones inherit the lean automatically.

**Reusable:** as a standard `AnimationLayer`, any app gets postural yield by adding it to a model's stack and feeding it a partner collider — it is the durable library surface. Component A is demo glue.

---

## 4. Wiring & ordering (the one-frame lag)

The `PosturalContactLayer` needs the partner's torso capsule each frame. The coordinator already produces every avatar's world-space torso capsule via `contactColliderSnapshot`, and `exchange()` runs the union-minus-self selection. The stepper feeds each avatar's layer its **nearest partner's torso capsule** (`layer.partnerTorso = …`) before `player.update` runs the animation stack.

Because `exchange()` currently runs *after* `player.update` in `step()`, the layer reads the **previous frame's** partner pose — a **one-frame lag**, consistent with the (b) scheme used across the collision feature. This is accepted (staleness ∝ partner velocity, small in the contemplative register). A zero-lag two-pass reorder is a documented future option, not v1.

---

## 5. Parameters & the coupled tuning tension

| Param | Component | Meaning |
|-------|-----------|---------|
| `bodyContactMargin` | A | Max torso-capsule overlap allowed (the hug-press allowance). Too tight → stiff/distant hug; too loose → clip-through. |
| `kGain` | B | Lean angle per metre of penetration. |
| `maxLeanAngle` (θ_max) | B | Safety clamp (~20–30°) so the spine can't break awkwardly. |
| `stiffness` (ω) | B | Critically-damped slerp rate: yield speed on contact + recovery speed on separation. |
| `blendWeight` | B | Overall layer weight 0–1 (mirrors `IKLayer.ikBlendWeight`). |

**Coupled pair:** `bodyContactMargin` sets how much penetration *exists*; `kGain`/`maxLeanAngle` map that penetration to *lean*. Tuned together — a bigger margin with a matched gain gives a deep, soft yield; a tight margin with high gain gives a firm, shallow one. Calibrated visually in the spike, same as the earlier `holdSep`↔`radius` pair.

---

## 6. Testing

- **Postural math (pure unit tests):** `θ = clamp(kGain·d, 0, θ_max)` monotonic in `d`, clamps at `θ_max`, identity at `d=0`; axis `cross(spineUp, v̂)` has the correct sign (leans *away* from the partner); critically-damped slerp approaches the target smoothly/monotonically and recovers to identity when penetration clears.
- **Layer applies (headless):** a penetrating partner torso capsule changes the spine/chest rotations (lean away); separation recovers them. `blendWeight = 0` or disabled ⇒ **exact no-op** (animation bit-unchanged).
- **Kinematic-phase inheritance (load-bearing):** the layer runs *before* the spring solver, so chest hair follows the *leaned* chest, not the un-leaned animated chest. Assert a chest-anchored spring bone's world position reflects the lean.
- **Contact-aware clamp (Component A):** body (torso-capsule) overlap never exceeds `bodyContactMargin`, regardless of the driver's raw hold-sep.
- **Non-interference:** no partner ⇒ postural layer is identity ⇒ single-avatar animation unchanged; and the standalone spring-bone sim stays bit-identical.
- **Visual acceptance:** the crowd render — bodies press to contact instead of clipping through, the upper body visibly yields on contact and recovers on separation.

---

## 7. Non-goals / deferred

- **Lever 3** (IK avoidance / rigid-body / ragdoll) — separate future sub-project.
- **Zero-lag two-pass** partner-collider feed — v1 uses the (b) one-frame lag.
- **Arm/hand contact response** — postural yield is spine/chest only; arms remain animation-driven (the hug's arm wrap is authored, not solved).
- **Per-avatar mass/scale-weighted yield** — v1 uses uniform params; who-yields-more-to-whom is a future refinement.
