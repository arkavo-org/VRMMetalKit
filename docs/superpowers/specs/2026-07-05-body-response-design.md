# Cross-Avatar Body Response — Design

**Date:** 2026-07-05
**Status:** Implemented 2026-07-05 (TDD, all §6 tests green). Design ratified, then revised after a code-verification pass surfaced three prerequisites not in the tree (see §3.1): the crowd path runs no layer stack, the postural apply is not the stock compositor compose, and the partner torso capsule is not addressable in the snapshot — all three resolved in the implementation. Implementation also surfaced a behavioural finding (the yield is self-relieving; see §5).
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

1. For each avatar, take its torso capsule and the **nearest partner's** torso capsule. **Prerequisite (see §3.1):** `contactColliderSnapshot` returns an *unlabeled bag* of capsules (torso + upper arms + head + thighs + authored colliders) — the torso is not individually addressable today. Component A depends on the same new torso-capsule accessor Component B needs.
2. Compute the current body separation along the approach axis. Note the only snapshot available at placement time is the **previous frame's** (`exchange()` runs after Phase 0 placement), so this clamp is one-frame-stale — acceptable at contemplative velocities, same as §4.
3. The driver *proposes* a half-separation (`CrowdMotionDriver.halfSeparation`). Placement is **center-symmetric off that single `halfSep`** (`CrowdPlacement.rootTranslation` maps it to each avatar's translation), so the clamp operates on the shared `halfSep` quantity, **not** two independent per-avatar offsets: the stepper raises the effective half-separation floor so the two torso capsules overlap by **at most `bodyContactMargin`**. Bodies press to controlled contact, never to the driver's raw deep-overlap distance.

So the driver still choreographs approach/hold/part, but the stepper enforces "no deep clip-through." This lives in the crowd demo (`CrowdFrameStepper` + a new `bodyContactMargin` on the crowd path); beyond the shared torso-capsule accessor it needs no rig or library changes.

---

## 3. Component B — `PosturalContactLayer` (lever 2, library)

A new `public final class PosturalContactLayer: AnimationLayer`, `affectedBones = [.spine, .chest]`, following the `AnimationLayer` protocol (`update(deltaTime:context:)` + `evaluate() -> LayerOutput`). **Two pieces of the surrounding infrastructure it needs do not exist in the crowd path yet — see §3.1 before implementing.** Each frame it runs this deterministic, O(1) algorithm (the ratified spec):

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

**D. Apply in the kinematic phase.** Distribute `q_active` across `spine` and `chest` (each takes a fraction, so it reads as a natural bend rather than a single hinge) and **post-multiply onto the current animated rotation** — the yield must compose onto the clip's live per-frame spine pose:
- `bone.localRotation = animRotation × q_activeShare`

⚠️ **This is *not* the stock `AnimationLayerCompositor` compose.** The compositor writes `node.rotation = baseRotation × delta` where `baseRotation` is captured **once at `setup()`** (`ProceduralAnimation.swift:215,353`). Run naively over clip playback it would *overwrite* the clip's spine/chest motion with `setupPose × delta` every frame, not multiply the yield onto the animated pose — and clip-playback + compositor coexistence is not an exercised path (the `IKLayer` tests run the compositor *without* concurrent clip playback). See §3.1 for the required apply path.

Because the layer writes the leaned spine rotation **before** `drawComposite` runs the spring compute (the whole pose phase precedes `drawComposite` in `step()`), the chest's spring bones inherit the lean automatically.

**Reusable:** as a standard `AnimationLayer`, any app that already runs a compositor gets postural yield by adding it to the stack and feeding it a partner collider — it is the durable library surface. Component A is demo glue.

### 3.1 Required wiring (does not exist in the crowd path today)

Two prerequisites the earlier spec assumed as pre-existing but that are **not** in the tree:

1. **No layer stack runs in the crowd path.** `IKLayer` runs through `AnimationLayerCompositor` (`ProceduralAnimation.swift:186`), a subsystem *separate* from clip playback. `CrowdFrameStepper.step()` only calls `player.update(...)` (`CrowdFrameStepper.swift:73`), and `AnimationPlayer.update` invokes **no** compositor or layer; `Sources/VRMVideoRenderer/main.swift` constructs neither a compositor nor an `IKLayer`. So there is no "stack slot" to drop into. **Implementation must add a compositor (or a direct post-multiply hook) to the crowd path**, run after `player.update` and after `CrowdPlacement` root motion, but **before** `updateNodeTransforms()` + `exchange()`. Given the apply-semantics mismatch above, the simplest v1 is a **direct post-multiply** in `step()` — read each affected bone's current animated `localRotation` and write `animRotation × q_activeShare` — rather than routing through `AnimationLayerCompositor`. The `AnimationLayer` conformance is retained for the library surface (apps that re-capture base pose per frame, or don't run clips on the spine, can use the compositor path).
2. **The partner torso capsule is not addressable.** `contactColliderSnapshot` returns a `ForeignColliderSnapshot` of unlabeled `spheres`/`capsules` (`SpringBoneComputeSystem.swift:1195-1218`); the set is torso + upper arms + head + thighs (927fd1d) + authored colliders (36a3b6a), and `CapsuleCollider` has no role field. **Add a torso-capsule accessor** — a tagged field on the snapshot, or a documented convention (the torso is the first capsule `synthesize` emits) — consumed by both Component A and B.

---

## 4. Wiring & ordering (the one-frame lag)

The `PosturalContactLayer` needs the partner's torso capsule each frame. The coordinator produces every avatar's world-space contact set via `contactColliderSnapshot` (the torso extracted per §3.1), and `exchange()` runs the union-minus-self selection. The stepper feeds each avatar its **nearest partner's torso capsule** (`layer.partnerTorso = …`) before the postural apply runs.

**This reintroduces a one-frame lag the spring-contact path specifically avoids** — be precise about it. `CrowdFrameStepper` is deliberately structured so Phase 0 poses *every* avatar and *then* `exchange()` snapshots (`CrowdFrameStepper.swift:21-27,85-86`), so the spring solver reads a **fresh, same-frame** partner pose. The postural apply, running inside the pose phase, can only read the **previous frame's** snapshot — it is therefore **strictly staler than the spring path**, not "consistent" with it. This is accepted for v1 (staleness ∝ partner velocity, small in the contemplative register). A zero-lag two-pass reorder — pose all → snapshot all → postural apply → re-pose — is a documented future option, not v1.

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

**The yield is self-relieving (discovered in implementation, affects tuning).** Lever B measures the *chest point* against the partner torso capsule, but the chest is itself part of the trunk the lean rotates — leaning away moves the chest out of the partner, which *reduces the very penetration driving the lean*. The postural yield is therefore a negative-feedback loop that settles toward **light contact** (chest just grazing the partner torso), not toward a large sustained lean: the visible yield is a **transient** dip on approach, not a fixed pose. Two consequences: (1) the *steady-state* lean under a fixed hold is small by construction — the spring inheritance test asserts on the transient **peak**, not the settled end-state; (2) to hold a *visible* sustained press, Lever A (`bodyContactMargin`) — which moves the *roots* — is what keeps the bodies engaged while B relieves the chest. A and B act on different DOF (roots vs. spine) and compose rather than fight. If a firmer sustained lean is ever wanted, decouple B's measurement point from the leaning segment (measure e.g. the hips or a fixed chest offset) — a deliberate future change, not v1.

---

## 6. Testing

**Status: implemented and green** (except visual acceptance, which is a human check). File references below.

- **Postural math (pure unit tests)** — `PosturalContactSolverTests`: `θ = clamp(kGain·d, 0, θ_max)` monotonic in `d`, clamps at `θ_max`, identity at `d=0`; axis `cross(spineUp, v̂)` has the correct sign (leans *away* from the partner); critically-damped slerp eases toward the target without overshoot and recovers to identity when penetration clears.
- **Layer applies (headless)** — `PosturalContactLayerTests`: a penetrating partner torso capsule changes the spine/chest rotations (lean away); separation recovers them. `blendWeight = 0` or disabled ⇒ **exact no-op** (spine rotation bit-unchanged).
- **Kinematic-phase inheritance (load-bearing)** — `CrowdFrameStepperTests.testPosturalYieldIsInheritedBySpringBones`: the postural apply runs *before* the spring solver, so bones above the chest (head hair, since head descends from chest via neck) inherit the lean. With `bodyContactMargin` off the placement is identical between postural-on/off runs, so any divergence in solved spring positions is caused solely by the lean. Asserts on the transient **peak** (see the self-relieving note in §5), not the settled end-state.
- **Apply composes onto animated pose (§3D)** — `PosturalContactLayerTests.testApplyDirect_composesOntoCurrentAnimatedRotation`: the same yield frame applied onto two different animated spine rotations leaves the **same residual delta** (`base⁻¹·result`) — impossible under a fixed-base overwrite; proves `applyDirect` post-multiplies the live pose.
- **Torso-capsule accessor (§3.1)** — `SpringBoneContactSnapshotTests.testContactTorsoCapsuleMatchesFirstSnapshotCapsule`: the accessor returns exactly the torso capsule the snapshot emits first (single source of truth), spanning spine→chest.
- **Contact-aware clamp (Component A)** — `CrowdContactClampTests` (pure geometry) + `CrowdFrameStepperTests.testBodyContactMarginClampsTorsoOverlap` (integration, with an unclamped control): torso overlap never exceeds `bodyContactMargin`, and the clamp raises the applied half-separation above the driver's deep hold.
- **Non-interference** — `CrowdFrameStepperTests.testNoGroupIsBitIdenticalToSolo` (unchanged, still green): both components are opt-in, so the default crowd path stays bit-identical.
- **Visual acceptance** (human): the crowd render — bodies press to contact instead of clipping through, the upper body visibly yields on contact and recovers on separation.

---

## 7. Non-goals / deferred

- **Lever 3** (IK avoidance / rigid-body / ragdoll) — separate future sub-project.
- **Zero-lag two-pass** partner-collider feed — v1 uses the (b) one-frame lag.
- **Arm/hand contact response** — postural yield is spine/chest only; arms remain animation-driven (the hug's arm wrap is authored, not solved).
- **Per-avatar mass/scale-weighted yield** — v1 uses uniform params; who-yields-more-to-whom is a future refinement.
