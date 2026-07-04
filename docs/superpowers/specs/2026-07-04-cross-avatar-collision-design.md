# Cross-Avatar Spring-Bone Collision — Design

**Date:** 2026-07-04
**Status:** Design ratified through Section 1 (architecture + ordering contract); remaining sections drafted for redline.
**Scope:** Extend VRMMetalKit's SpringBone system so one VRM avatar's spring bones yield to another avatar's body colliders — cross-avatar mutual contact for settling, leaning, and hugging in a contemplative register.

---

## 1. Goal and framing

Two-plus VRM avatars should physically yield to each other: hair and cloth reacting to a partner's body, and — the hard case — two bodies in sustained mutual contact (a hug). This is **not** a second physics engine. Spring bones are already a constraint solver whose entire model is bones-pushed-out-of-colliders. Cross-avatar contact is **one more world-space collider source** unioned into a solver that already ingests foreign world-space colliders in three existing places (ARKit floor planes via `setPlaneColliders`, #309 synthetic augmented colliders via `appendSyntheticColliders`, and runtime radius overrides). Box3D or any rigid-body engine is explicitly rejected: introducing a second contact authority recreates the pose-fighting problem the whole approach avoids.

### Design property earned across all forks

Every load-bearing choice resolved on a **correctness argument that holds regardless of aesthetic**, with a register argument confirming nothing visible was given up:

| Fork | Choice | Correctness argument (primary) | Register argument (confirming) |
|------|--------|-------------------------------|-------------------------------|
| Driver shape | Coordinator, not multi-model system | One-system-per-model is a baked invariant; a thin coordinator is the only shape that doesn't disturb it | — |
| Foreign capacity | Reserve-headroom + snap, not realloc + interpolate | Snap makes the authored interpolation invariant *structurally unreachable* from the foreign path | Snapped motion is invisible at low partner velocity |
| Partner bit | Single foreign bit, not per-partner | Colliders carry no per-partner identity **and** the kernel push is uniform — per-partner has no data handle and no expression | — |
| Contact set | Skeleton-derived body set, not authored colliders | Humanoid bones are guaranteed on every VRM and bounded; authored colliders are neither | Skeleton-derived is also the actual hug surface, incl. the back |

This makes the spine robust to the contemplative register shifting — the property that matters most for a game whose identity is that register.

### Non-goals (v1)

- Per-partner **response** differentiation (softer push toward B than C). Not kernel-expressible today; a separate future kernel change, not reserved for.
- Using a partner's **authored** colliders as contact geometry (variable count, hair-avoidance placement, unreliable coverage — deferred refinement).
- Lockstep co-simulation and true zero-lag same-frame mutual resolution (identified escape hatches; see §3 upgrade ladder).

---

## 2. Architecture and component boundary

Five components. Two avatars means **two renderers, two `SpringBoneComputeSystem` instances, two command buffers** — each system holds a private per-model CPU mirror (`rootBoneIndices`, `chainRanges`, `chainSleepState`, `centerSpringRecords`, interpolation arrays). Nothing today sees both; the coordinator is the only thing that does.

### 2.1 `SpringBoneContactGroup` (new — thin coordination layer)

Owns exactly **membership** (which models participate this frame) and **temporal ordering** (snapshot-all → inject-union-minus-self → integrate-all). Its only per-model references are identity handles to participants' systems.

**Review-gate invariant (load-bearing tripwire):**

> The coordinator must cache **no per-model *simulation* state** that survives a frame.

The criterion is **sim-state vs. coordination-state**, not lifetime. Membership lists and system identity handles are coordinator-owned and frame-surviving *by design* — they are coordination state and are permitted. What is forbidden is caching anything that belongs to one model's simulation (interpolation mirrors, sleep state, swept-collider history, bone positions). The moment the coordinator holds one model's sim-state across a frame, it has drifted toward the multi-model-system shape (C) that this boundary exists to prevent.

### 2.2 `SpringBoneComputeSystem` (extended — two capabilities at the snapshot/integrate seam)

The world-space collider computation is **already separable** from kernel dispatch: `captureTargetColliderTransforms` (`SpringBoneComputeSystem.swift:2092`) produces pure CPU arrays of world-space colliders at the top of `update()`, before any kernel runs. It is private, stateful, and unexposed. The two new capabilities live at this existing seam:

- **`contactColliderSnapshot(model:) -> [ForeignCollider]`** — a **pure** recompute of this avatar's world-space body contact set (§5). Reuses the transform math of `captureTargetColliderTransforms` but **must not** perform the first-frame `previousSphereColliders`/`previousCapsuleColliders` init or mutate any interpolation mirror. This purity is a **correctness requirement, not cleanliness**: the coordinator calls it before this system's integrate, so any side effect on the interpolation mirror would perturb the very state the subsequent integrate depends on — reintroducing authored-path contamination through the snapshot door instead of the injection door (gap-2).

- **Foreign-collider injection sink** — accepts the coordinator's per-frame foreign array and writes it, tagged with the reserved foreign group bit, to a **reserved fixed tail** of the sphere/capsule buffers, once per frame (§4.2). Foreign colliders never enter the `previousSphereColliders.count == targetSphereColliders.count` invariant (`SpringBoneComputeSystem.swift:2244`), so the authored path's interpolation is structurally unreachable from the foreign path. Sink contract detailed in §4.

Both capabilities read node world matrices. The snapshot's purity guarantee (no *write* to the interpolation mirror) is necessary but not sufficient for correctness — the matrices it *reads* must be in a well-defined state at call time. Under option (b) those matrices are last frame's committed result, which imposes an ordering precondition on `exchange()` stated in §3.2. (Note the snapshot compute region near `:2092` and the interpolation invariant guard at `:2244` are in the same file; the implementer should read that whole span, since the foreign tail write sits outside the interpolation write-range rather than adjacent to either.)

### 2.3 Contact-set generator (new — a system capability, not a #309 byproduct)

Builds the skeleton-derived body set (torso spine→chest capsule + upper arms + head) from the humanoid skeleton the avatar always has.

**Shared geometry, independent trigger** (the section's most important structural call — one bone→capsule implementation, two callers that can't disagree):

- **Shares with #309:** the bone→capsule geometry generation and world-space transform math. This code is proven per-frame. **Extract it** from `SpringBoneColliderAugmentor` into a shared bone→capsule generator that both callers use. Do **not** reimplement the transform math (duplication → drift).
- **Does NOT share with #309:** the *trigger* and the *bone selection*. #309 fires because the avatar wants its own cloth colliders (gated on `VRMLoadingOptions.augmentSpringBoneColliders`). The contact-set generator fires because the coordinator asked, and selects a different bone set (adds the torso segment #309 omits). It must **not** be reached through the augmentor's enable flag.

This is the conformance-harness pattern applied to geometry. It prevents both failure modes: reimplementing the math (drift), and coupling contact-set generation to `augmentSpringBoneColliders` — which would make cross-avatar contact silently depend on the partner having #309 enabled, exactly the coverage gap that Option 2 (authored colliders) was rejected to avoid.

### 2.4 Buffer capacity (reserved headroom)

Sphere/capsule buffers gain `N` reserved foreign slots beyond authored+synthetic, `N = maxPartners × contactSetCardinality`, a documented load/compile-time constant. Detailed in §6.

### 2.5 Group-bit reception

The reserved foreign bit is OR'd into every receiving spring bone's `colliderGroupMask` at load. Detailed in §7.

---

## 3. Ordering / driver API

v1 uses **option (b): one-frame-lagged exchange** — snapshot reads current node poses (= last frame's committed result), then each renderer runs its existing render path unchanged. Chosen because it is provably non-disruptive to the proven render path (no split, no reordering) and the register makes the lag invisible.

### 3.1 The ordering contract (option (b), reconciled)

```
Between frames, across all participants:
  Phase 1  SNAPSHOT   exchange() calls contactColliderSnapshot() on each system,
                      reading current node poses = last frame's committed result   [pure]
  Phase 2  INJECT     exchange() computes union-minus-self, hands each system its foreign array
Per participant, then (existing render path, UNCHANGED):
  Phase 3  INTEGRATE  renderer applies this-frame animation → runs update() → kernels;
                      sink appends foreign to reserved tail
```

`exchange()` is a **single call the app makes between frames**, interposed after last frame's commit and before this frame's renders. No renderer restructuring.

### 3.2 The symmetry guarantee under (b) — stated precisely

The property is **not** option (a)'s "every snapshot before every integrate against start-of-frame poses." Under (b) it is:

> **Uniform one-frame lag, consistent-prior-frame mutual resolution.** Every snapshot reads the *same committed frame* (last frame's result) for all participants. A-vs-B and B-vs-A therefore resolve against a *consistent prior state* — the same frame boundary for both, lagged by one frame uniformly. Neither avatar ever sees the other already-integrated, so it is symmetric.

This is a genuinely different, **weaker-but-sufficient** guarantee than (a): (a) gives same-frame mutual resolution with zero lag; (b) gives consistent-prior-frame mutual resolution with uniform one-frame lag. (b) trades zero lag for zero render restructuring, and the one-frame lag (i) stacks cleanly with the spring system's *existing* one-frame readback lag (`VRMRenderer.swift:1590`), and (ii) is within the staleness tolerance already accepted for snap: staleness error scales with the *partner's* per-frame displacement, which is smallest exactly in the contemplative register.

**Ordering precondition (multi-renderer — the `exchange()` sequencing that makes the guarantee hold).** "Consistent-prior-frame" requires that at `exchange()` time every participant's node transforms are in their *last-frame-committed* state. With two renderers and two command buffers, "after last frame's commit" is ambiguous about *whose* commit — and the guarantee breaks *silently* (subtly-wrong contact, not a crash) if `exchange()` reads a half-committed pose. So the precondition is precise: **`exchange()` must be sequenced after *all* participants' render commits, not merely after "a" commit.** If any participant defers matrix writes (async render), `exchange()` waits on that participant before snapshotting. This is the multi-renderer form of the snapshot's read-state requirement (§2.2).

**Stated so a future debugger reads it correctly:** a reader chasing a convergence issue must not look for a start-of-frame animation lift — there isn't one under (b). The escape hatch to (a) is legible as "remove the uniform lag by lifting animation ahead of `exchange()`."

### 3.3 The three-rung convergence upgrade ladder

Convergence-if-needed is **two hops from v1, not one**. Each rung is localized to the coordinator/app seam; none is a coordinator rewrite:

1. **(b) — v1.** One-frame-lagged exchange. No render restructuring.
2. **(a) — remove the uniform lag.** Lift this-frame animation for all participants ahead of `exchange()`, so snapshots read start-of-frame (not prior-frame) poses. Same-frame mutual resolution, zero lag. Cost: the render-path restructuring v1 defers.
3. **(a)+lockstep — remove the phase lag.** Phase 3 becomes per-substep interleaved (advance all one substep → re-snapshot → re-inject → repeat). This targets the residual sustained-contact risk: a drag-damped **anti-phase limit cycle** where two one-frame-lagged push-outs pump a slow oscillation. **Only reachable after rung 2**, because per-substep interleaving requires the animation-ahead-of-integrate seam that (b) deliberately lacks.

The honest cost of convergence is therefore: rung 1→2 is the deferred render restructuring; rung 2→3 is the substep interleave. Both at the same seam, no coordinator rewrite — but a ladder, not a single hop.

**Escalation order, not a direct jump.** If the anti-phase limit cycle appears, lockstep (rung 3) is the *last* resort, not the first response. The cycle is drag-damped, so the first lever is **drag/compliance tuning** — increasing damping on the postural/contact bones to kill the oscillation at its energy source (§8.3). Only if tuning cannot damp it without making the contact read stiff do you climb to rung 3. Stated here so the ladder doesn't read as "oscillation → jump to lockstep."

### 3.4 Driver API sketch

```swift
final class SpringBoneContactGroup {
    func add(_ system: SpringBoneComputeSystem, model: VRMModel)   // membership
    func remove(_ system: SpringBoneComputeSystem)
    func exchange()   // Phase 1 (snapshot all) + Phase 2 (inject union-minus-self)
}
```

App frame loop: `... commit last frame → contactGroup.exchange() → render each participant ...`. The coordinator holds `[(system, model)]` handles (coordination state, permitted) and no sim-state.

---

## 4. Injection-sink mechanics

The sink receives the coordinator's per-frame foreign array and writes it to the reserved buffer tail after `interpolateColliders`, tagged with the reserved foreign group bit.

### 4.1 Replace-or-clear contract (frame-surviving-state guard, one level down)

The stored foreign array is **replaced every frame if present and cleared every frame if absent** — it must never accumulate or persist across a membership change. This is the same class of bug the coordinator's review gate guards against, one level down in the *system*: a foreign array from a partner who left, still occupying the tail because injection replaced-if-present but did not clear-if-absent, would leave the departed partner's body colliding as a ghost.

Concretely: `exchange()` calls the sink on **every** participant every frame — with an empty array when a system has no partners this frame — and the sink writes exactly that frame's foreign set (possibly empty) to the tail, zeroing the unused tail slots. There is no "no call = keep last." The sink's contract is total over frames.

### 4.2 Tail write — once per frame, not per substep

The foreign write happens **once per frame**, not per substep. This is provable from the code, not a convenience: `interpolateColliders` rewrites only the prefix `[0, previousSphereColliders.count)` = `[0, authored+synthetic)` (`SpringBoneComputeSystem.swift:2247-2248`) and never touches the reserved tail. So a foreign tail written once at the top of the frame **persists across all that frame's substeps**, untouched by interpolation. Because the foreign set is snap (fixed per frame), there is nothing to rewrite per substep.

- Foreign colliders occupy sphere/capsule buffer indices `[authored+synthetic .. authored+synthetic+activeForeign)`, contiguous immediately after the synthetic region (no gap — the kernel's linear `0..<numSpheres` loop must hit exactly the active set).
- Each foreign collider is written with `groupIndex = foreignGroupIndex` (§7).
- Written once per frame, after `exchange()` has injected the frame's foreign array and **before the first substep's collision dispatch** (top of `update()`'s substep processing). Foreign colliders snap; authored/synthetic interpolate per substep as today.

**Three quantities that currently coincide must be deliberately separated** (they are all "the sphere count" today):

| Quantity | Today | Under this design |
|----------|-------|-------------------|
| **Allocation capacity** (`allocateBuffers` size) | `authored+synthetic` | `authored+synthetic+N` (§6) |
| **Count-guard reference** (`buffers.numSpheres`, guards `updateSphereColliders`) | `= allocation` | must equal the **active** count for the load-time authored-only upload, so the initial `populateSpringBoneData` upload isn't rejected by the `count == numSpheres` guard (`SpringBoneBuffers.swift:155`) |
| **Kernel active count** (`globalParams.numSpheres`, bounds `for i in 0..<numSpheres`) | set **once at init** (`VRMModel.swift:1235`) | set **per frame** to `authored+synthetic+activeForeign`; constant across that frame's substeps because the foreign set is fixed per frame |

Inactive reserved slots sit at indices `≥ globalParams.numSpheres`, so the kernel's `0..<numSpheres` loop **never reaches them** — they are excluded from the active count, not merely zeroed geometry. (A zeroed sphere still has a center and radius; gating on the count, not the geometry, is the difference between "dead slots ignored" and "dead slots colliding at the origin.") Making `globalParams.numSpheres` per-frame is a real new write point — the sink updates it before the substep loop. The §8.1 bit-identical non-interference test pins this: with zero active foreign, `globalParams.numSpheres` must equal the pre-design value exactly.

### 4.3 Interaction with the fallback path

`updateAnimatedPositions` (`SpringBoneComputeSystem.swift:1515`) is the non-interpolation fallback. **v1 requires interpolation-on** (`VRMConstants.Physics.enableRootInterpolation == true`) for contact-group participants; foreign injection hooks only the interpolation path. Because foreign colliders snap (never interpolate), the fallback's interpolation concerns don't apply to them anyway — but v1 scopes cross-avatar contact to interpolation-on participants explicitly rather than dual-hooking both paths. Stated as a scope decision, not discovered.

**Loud precondition, not silent no-contact.** Per the no-silent-caps principle governing this design, adding a participant whose `enableRootInterpolation` is off must **fail loudly** at `SpringBoneContactGroup.add()` — assert in debug and log in release — not silently produce no contact. A participant that yields to no one because of an unmet precondition is exactly the invisible coverage gap the design rejects elsewhere.

---

## 5. Contact-set generator and the torso capsule

### 5.1 The set

Skeleton-derived body colliders, from spec-standard humanoid bones (guaranteed present on every VRM 1.0 avatar):

- **Torso:** a spine→chest capsule (**new geometry** — see §5.3).
- **Upper arms:** capsules (reuse #309's arm segment generation).
- **Head:** a brow capsule **and** a lateral skull sphere — both, exactly as #309 emits (`SpringBoneColliderAugmentor.swift:34`), so "reuse #309's head generation" is literal, not an either/or the generator must resolve.

Bounded cardinality (~5–9 shapes), which is what makes the reserved-tail constant `N` a constant (§6) rather than a per-model unknown.

### 5.2 Ownership boundary

The **system** owns "what is my contact set" — it has the node→humanoid-bone data. It hands the coordinator a flat, bounded array of world-space `ForeignCollider`s. The coordinator never reasons about body semantics; it only unions and clamps. Selection policy (which bones → contact set) lives in the generator, computed from the humanoid skeleton independently of `augmentSpringBoneColliders` (§2.3).

### 5.3 The torso capsule — the one piece with no precedent to inherit correctness from

Everything else in the contact set reuses #309's proven per-frame generator/transform code. The spine→chest capsule is **new**: new sizing ratio, new placement, and — the disproportionate risk — **new contact behavior at the primary hug surface**, exactly where jitter or interpenetration reads worst because it's the surface the player is watching.

Its architectural footprint is one shape from the generator; its **risk is register, not structure**. Therefore it is its **own line item in the tuning/testing bucket** (§8), separate from "limb ratios like #309," because it is the single most likely thing to make a hug read as contemplative-yielding vs. mannequin-clipping and it has no existing tuning to borrow. Sizing follows the #309 idiom (radius as a fraction of the spine→chest segment length) but the specific ratio is calibrated visually against the hug spike, not inherited.

---

## 6. Buffer capacity constant

- `N = maxPartners × contactSetCardinality` reserved foreign slots per sphere/capsule buffer, allocated at load.
- Both factors are load/compile-time constants; `contactSetCardinality` is bounded because the set is skeleton-derived.
- For the contemplative register (2–3 avatars, ~5–9 contact shapes each), `N` is small — a documented constant, not something engineered around.
- The coordinator **clamps** injected colliders to `N` and, per the no-silent-caps rule, **logs any drop** rather than truncating silently. A drop means the reserved tail is undersized for the active membership — a visible diagnostic, never a silent coverage loss.
- Allocation adds `N` slots to the existing `allocateBuffers(numSpheres:numCapsules:)` sizing; the sink writes into the reserved region and never reallocates per-frame (the reason snap was chosen over realloc+interpolate).

---

## 7. Group-bit reception

- One reserved **foreign group bit**, distinct from the #309 synthetic reserved bit, assigned in the per-model group numbering (which is per-receiving-avatar; the 32-bit ceiling is per-avatar, not global).
- The bit is OR'd into **every receiving spring bone's `colliderGroupMask`** at load (`populateSpringBoneData`).
- **Safe when idle:** with no foreign colliders injected (empty tail, §4.1), the foreign bit matches nothing, so a non-participating avatar — or a participant with zero partners this frame — is unaffected.
- **Single bit, all partners:** all injected foreign colliders carry the same foreign bit regardless of source partner. Per-partner *presence* is decided by coordinator membership (which partners' sets get unioned into this system), not by the bit. Per-partner *response* is a non-goal (§1) and unimplementable in the uniform-push kernel regardless of bits.
- Ceiling note: two reserved bits total (synthetic + foreign) against a per-avatar 32-group ceiling. The real headroom is `32 − authored − 1 (synthetic) − 1 (foreign)`; it only binds at ≥30 *authored* groups, which no real VRM approaches.
- **The both-at-once avatar reserves both bits distinctly — they do not share.** An avatar that is *simultaneously* a #309 cloth user (its own springs collide with its own synthetic body colliders) *and* a contact-group participant (its springs collide with a partner's foreign body colliders) keeps the synthetic and foreign bits **separate**, so the total is genuinely 2 even in this composite case, not 3 and not a shared 1. The reason they must not share is behavioral, not just bookkeeping: swept (continuous) CCD is scoped to the synthetic group *only* (`sweptColliderGroupIndex`, #313 / CLAUDE invariant). Foreign contact colliders are discrete (snap, no sweep). If foreign shared the synthetic group index, foreign colliders would inherit swept CCD — deflecting contact chains the way authored CCD deflects the sleeve→arm chain. Distinct bits keep foreign in the discrete-collision regime where it belongs. The shared bone→capsule *generator* (§2.3) shares geometry; it does **not** imply a shared collision *group*.

---

## 8. Testing

### 8.1 Non-interference (the correctness spine — highest priority)

- **Authored-path untouched with foreign active.** A single avatar's spring-bone trajectory must be bit-identical with the foreign path present-but-empty vs. absent. Proves the reserved-tail + snap design leaves the authored interpolation invariant structurally unreachable.
- **Snapshot purity.** `contactColliderSnapshot(model:)` called repeatedly must not alter the system's interpolation mirror or subsequent integrate result (gap-2 correctness requirement).
- **Replace-or-clear.** A partner added then removed must leave zero foreign colliders in the tail on the removal frame — no ghost collision. Assert the tail is cleared, not merely stale.

### 8.2 Cross-avatar behavior

- **One-way yielding.** Inject A→B only; B's hair/cloth yields to A's body, A unaffected. The simplest cross-avatar assertion.
- **Mutual settling / leaning.** Two avatars, mutual injection; both yield, symmetric, stable at rest. Assert the uniform-one-frame-lag symmetry (§3.2): neither resolves against the other already-integrated.
- **Shared bone→capsule generator parity.** The extracted generator produces identical geometry for the #309 caller and the contact-set caller given the same bones — the "two callers that can't disagree" guarantee (§2.3).

### 8.3 Register / visual (the spike)

- **Hug spike — torso capsule.** Its own line item. Two avatars in sustained mutual torso contact. Visual attention concentrates here: watch for (i) mannequin-clipping/interpenetration at the torso surface, (ii) the anti-phase limit-cycle oscillation during and after the approach (the §3.3 rung-3 trigger). The torso capsule's sizing/placement is calibrated against this spike, not inherited from #309.
- **Approach vs. hold.** Per the staleness analysis, expect worst staleness at the *approach* (highest relative velocity), not the settled hold. If oscillation appears in the hold, it is the anti-phase limit cycle → drag/compliance tuning first, then rung-3 lockstep.
- Regenerate `AvatarSample_A.png` sanity render per PR touching the contact path.

### 8.4 Determinism

- Cross-avatar tests run on the synchronous/offline path (`config.synchronousSpringBone`) for bit-determinism, consistent with existing SpringBone conformance tests.
- The new suite must **not** depend on the arm-swing guard (known-flaky under parallel execution) and must run single-threaded where determinism is asserted, so a pre-existing flaky guard never gates the cross-avatar suite.

---

## 9. Open items deferred (not v1)

- Authored-collider inclusion in the contact set (Option 3 union) — fidelity refinement, gated on solving variable-count tail sizing and double-surface overlap.
- Convergence rungs 2 (option (a) animation lift) and 3 (lockstep) — built only if the hug spike shows the one-frame lag or the anti-phase cycle.
- Per-partner response differentiation — requires a kernel change to make push strength per-collider; out of scope.
