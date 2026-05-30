# Design: Procedural Collider Augmentation + Stressed-Pose Penetration Harness

**Issue:** #309 — SpringBone collision: coarse collider shapes cause systemic clipping (hair→forehead, hair→arms, arm→skirt)
**Date:** 2026-05-29
**Status:** Approved (brainstorming) — pending spec review before implementation plan

---

## 1. Problem (validated against the code)

The collision **solver** is correct and complete. All five shapes — `sphere`, `capsule`, `plane`, `insideSphere`, `insideCapsule` — are implemented in `Shaders/SpringBoneCollision.metal` and run as the **final** XPBD substep (after the distance constraint, per the VRM spec). Closest-point-on-segment capsule math, group-bitmask filtering, world-space upload, and containment (`inside`) math are all present and working.

The defect is **collider geometry coverage**, not the solver:

- The head is approximated by **one sphere** offset toward the crown (AvatarSample_A: `r=0.107`, offset `(0, +0.107, -0.014)`). A sphere cannot represent a forward-jutting brow/forehead.
- Limbs are sparse **axis-aligned sphere chains** (3–4 spheres each) that cannot hug the limb silhouette end-to-end.
- The forced VRM-0.x `gravityPower 0→1.0` substitution walks chains *down* into the regions the coarse colliders under-cover; collision then pins the chain on a surface that sits **inside** the real skin → visible penetration.

The fix is **collider-side only**. The `gravityPower 0→1.0` substitution is load-bearing for AvatarSample_A's frozen-hair baseline (#306/#307) and must remain untouched — we add coverage where the sphere under-covers, we do not change gravity.

**Non-goals (YAGNI / out of scope):**
- No mesh/SDF-aware collision path (rejected: a large new GPU subsystem is wrong for a winding-down project).
- No per-model hand-authored *runtime* colliders (rejected: VMK is a library; asset-fitting belongs in the app layer). Hand-fit colliders appear **only** as test oracles, never shipped.
- No solver/shader-code changes.

---

## 2. Architecture — one additive value-type seam, solver unchanged

```
parse  →  model.springBone.colliders   (AUTHORED, never mutated)
              │
              ▼
VRMModel.initializeSpringBoneGPUSystem(device:)        ← ALLOCATION TIME
    if config.colliderAugmentation == .on:
       synthetic = SpringBoneColliderAugmentor.synthesize(
                       humanoid, nodeTransforms, authoredColliders)
       model.syntheticColliders = synthetic          ← separate model-held list
    totalSpheres/Capsules  = (authored + synthetic) counts
    allocateBuffers(..., numSpheres:, numCapsules:, numPlanes:)
    SpringBoneGlobalParams.numSpheres/numCapsules = augmented counts
              │
              ▼
SpringBoneComputeSystem.populateSpringBoneData(model:)  ← UPLOAD TIME
    build upload arrays from (authored + model.syntheticColliders)   ← SAME list
    OR the synthetic group's bit into every spring's colliderGroupMask
    updateSphereColliders(...) / updateCapsuleColliders(...)
              │
              ▼
existing GPU kernels run UNCHANGED (read counts from globalParams)
```

### 2.1 The count-equality contract (load-bearing — do not get this wrong)

Verified in the code:

- `VRMModel.initializeSpringBoneGPUSystem` (`Core/VRMModel.swift:1152–1197`) derives `totalSpheres`/`totalCapsules`/`totalPlanes` from `springBone.colliders` and allocates collider buffers to **exactly** that count, and seeds `SpringBoneGlobalParams.num{Spheres,Capsules,Planes}` from the same counts.
- `SpringBoneBuffers.updateCapsuleColliders` (`SpringBoneBuffers.swift:158`) — and the sphere/plane equivalents — **hard-guard `colliders.count == numCapsules`**. On mismatch they log a warning and **no-op** (the upload is silently dropped).

**Consequence:** synthetic colliders MUST enter at **allocation** time, not only at upload. If the augmentor injected colliders only in `populateSpringBoneData`, the buffer would be sized to the authored count, the count-equality guard would fail, and the synthetic colliders would be **silently discarded** — passing unit tests while doing nothing at runtime.

**Therefore:** the augmentor runs inside `initializeSpringBoneGPUSystem`, its output is stored in a **new `model.syntheticColliders` list** (authored `springBone.colliders` is never mutated — satisfies "additive only"), and **both** the allocation path and `populateSpringBoneData` consume `authored + syntheticColliders` so buffer size, `globalParams` counts, and the uploaded arrays all agree.

### 2.2 Verified: no shader-code changes, no fixed-capacity limit

- Collider buffers are **dynamically sized** to actual count — there is no `MAX_COLLIDERS` constant and no statically-sized collider buffer (grepped `SpringBoneBuffers` / `SpringBoneComputeSystem`).
- Kernels read `numSpheres`/`numCapsules`/`numPlanes` from `SpringBoneGlobalParams` at dispatch — adding colliders requires **zero** `.metal` edits.
- The only new runtime component is `SpringBoneColliderAugmentor` (a pure value type, no Metal dependency, in the spirit of `ProceduralBoneTransform`). The compute/model code gains a small wiring delta at the two sites above.

### 2.3 Components

| Component | File (new/changed) | Responsibility | Dependencies |
|---|---|---|---|
| `SpringBoneColliderAugmentor` | **new** `Sources/.../SpringBoneColliderAugmentor.swift` | Pure function: `(humanoid bone→node map, node world transforms, authored colliders) → [synthetic VRMCollider] + synthetic group index`. No Metal. | `VRMHumanoidBone`, node transforms, `VRMCollider`/`VRMColliderShape` |
| `model.syntheticColliders` | **changed** `Core/VRMModel.swift` | Separate additive list, consumed by allocation + upload. | — |
| Allocation wiring | **changed** `Core/VRMModel.swift:~1152–1197` | Run augmentor when gated on; fold synthetic counts into buffer sizes + globalParams. | augmentor, config |
| Upload wiring | **changed** `SpringBoneComputeSystem.populateSpringBoneData` (~685–935) | Build arrays from authored+synthetic; OR synthetic group bit into every spring mask. | `model.syntheticColliders` |
| Config flag | **changed** SpringBone/`RendererConfig` config | `colliderAugmentation: .on \| .off` (default `.on`). | — |

---

## 3. Generation heuristics

### 3.1 Limb capsules (manifestations 2 & 3 — hair→arms, arm→skirt)

For each humanoid limb segment — `upperArm→lowerArm→hand`, `upperLeg→lowerLeg→foot` (both sides) — emit **one capsule end-to-end** between consecutive bone-head world positions.

- **Radius — primary:** the max authored sphere radius among colliders parented to that bone (the author already encoded model scale).
- **Radius — fallback** (no authored sphere on that bone): a fraction of the segment length, `≈0.18 × length` for arms, `≈0.13 × length` for legs. These fractions are **tunable generator parameters**, not per-model constants.
- Authored sphere-chains are **kept** (additive); the capsule adds the missing hug.

### 3.2 Head / brow capsule (manifestation 1 — hair→forehead)

The crown-offset head sphere under-covers the forward brow/face. Synthesize a forward-and-down capsule.

- **Forward axis:** the head node's local `+Z` mapped to world. The parser already normalizes VRM-0.x `−Z` facing to `+Z` (Ry180 conjugation at parse time).
  - **Dependency / risk — #299:** if facing is wrong, brow coverage lands *behind* the head. The skin-reference oracle (§6) catches this loudly (the look-up pose would still penetrate).
- **Geometry — all expressed as RATIOS, never world-space distances** (this is the "derived, not magic-constant" line; do not let a raw metre value slip in):
  - `forwardOffset = k_fwd × r_head` — how far forward of head center the capsule's far end sits.
  - `downExtent   = k_down × r_head` — how far down the brow/face the capsule sweeps.
  - `capsuleRadius = k_rad × r_head`.
  - `r_head` = authored head sphere radius (skull-scale proxy; acknowledged coarse — it encodes scale, not brow protrusion — but it is the only bone-anchored scale available and it generalizes). If head→neck bone length is more stable across the VRoid family during tuning, use that as the ratio base instead; decide during §7 phase 3 tuning, but the value committed MUST be a ratio.
  - `k_fwd`, `k_down`, `k_rad` are tuned against AvatarSample_A (and a VRoid-family representative) and committed as **generator ratios**.

### 3.3 Tuning honesty

Bone-derived capsules can be loose on stylized VRoid proportions (large heads / thin limbs). Tuning targets the **generator ratios** against a VRoid-family representative — tuning a generalizable generator, not one model's colliders. That is the line; per-model collider authoring stays out of the runtime.

---

## 4. Broadphase association

Synthetic colliders are placed in **one** synthetic collider group; its bit is OR'd into **every** spring's `colliderGroupMask`, so all chains collide with all synthetic colliders.

- This matches the breadth already present in authored data (AvatarSample_A's hair already subscribes to head + both arms + hands + neck + spine + chest) and directly serves all three manifestations.
- Region-targeted association is deferred (YAGNI).
- Cost: `O(bones × colliders)`, adding ~8 capsules to ~20 existing colliders — negligible.

### 4.1 Over-subscription gap — closed, not hand-waved

The global group means a hair chain can now collide with a **leg** capsule it never authored a subscription to. In a deep hip-flexion pose (sit/crouch), that leg capsule rotates up near the hair's rest region and could splay the hair outward — a *new* artifact introduced by augmentation.

The three primary stress poses (look-up, arms-raised, arms-crossed) **do not exercise** this. Rather than rely on "the oracle catches it" for a pose the oracle never runs, the harness includes a **fourth pose: deep hip flexion (seated/crouch)** (§6). If that pose shows hair-vs-leg splay against the skin-reference oracle, scope the synthetic group down to region-targeted association — but only if observed.

---

## 5. Config + release

- New flag on the SpringBone/`RendererConfig` config: `colliderAugmentation: .on | .off`, **default `.on`**, escape hatch `.off`.
- Default-on re-baselines everyone's physics → ship the release as a **GitHub pre-release** (behavior-change rule) and **regenerate the SpringBone regression baseline CSVs** as part of the PR.
- Secondary sanity check (not the TDD signal): regenerate the `AvatarSample_A` stressed-pose render for visual review.

---

## 6. Test strategy — TDD against an independent oracle

### 6.1 Oracle: hand-fit skin-reference colliders

A tight, hand-fit collider set for AvatarSample_A that traces the **real skin** (brow, jaw, end-to-end limbs).

- **Test-only fixtures, never shipped.** Committed beside the model asset, stamped with authoring date + neutral-pose assumption, documented as *ground truth, not the runtime collider set* — so nobody "fixes" the generator to match them or mistakes them for live colliders.
- **Independence is the whole point:** the oracle is traced from skin; the generator is derived from bones. Different sources, so a green test is a real signal.
- It need not generalize — the *generator* generalizes; the *oracle* only needs to be a trustworthy yardstick for the regression-tested models.

### 6.2 Fixture-integrity guard (drift fails the build, not silently passes)

At test load, assert an integrity **checksum** of AvatarSample_A — vertex count + bounding-box checksum — against a committed expected value. If the model is re-exported, the skin-reference oracle silently drifts out of alignment; the checksum makes that **fail loudly** instead of passing a now-meaningless test. (Documentation tells a human it can drift; the checksum makes it impossible to rot quietly.)

### 6.3 Stress poses

Parameterized static extremal `AnimationClip`s built from `JointTrack` rotation samplers (extends the existing `SpringBoneRegressionTests` harness):

1. `lookUp` — head pitch ≥ 30°.
2. `armsRaised` — both upper arms raised ~90°.
3. `armsCrossed` — upper arms rotated inward.
4. `seatedDeepFlexion` — deep hip flexion (closes the §4.1 over-subscription gap).

### 6.4 Red → green shape

- **RED:** coarse shipped colliders → chains penetrate the skin-reference set across all four poses.
- **GREEN:** bone-derived augmented colliders → chains stay outside the skin-reference set across all four poses.

### 6.5 Supporting tests

- `SpringBoneColliderAugmentor` unit tests — deterministic synthetic-collider geometry from a fixed humanoid + transform fixture; no GPU. Asserts end-to-end limb capsule endpoints/radii and head-capsule ratios.
- Re-baselined neutral regression CSVs (the existing `avatar_a_baseline.csv` path) regenerated under `colliderAugmentation == .on`.
- A guard that `colliderAugmentation == .off` reproduces the pre-change (authored-only) collider set exactly.

---

## 7. Phased implementation (one spec, phased plan)

0. **Oracle + red.** Skin-reference fixtures + integrity checksum + four-pose harness + **failing** penetration tests against current colliders. (No generator code yet.)
1. **Seam.** `model.syntheticColliders`, allocation/upload wiring, config gate, `SpringBoneColliderAugmentor` skeleton (returns empty). Tests still red; `.off` path proven identical to today.
2. **Limb capsules.** End-to-end arm/leg capsules → arms-raised / arms-crossed / seated poses green.
3. **Head/brow capsule.** Forward-and-down capsule with ratio geometry → look-up pose green; tune ratios against AvatarSample_A + a VRoid representative.
4. **Validation.** Re-baseline regression CSVs, regenerate stressed-pose render, write pre-release notes, document the oracle + checksum.

---

## 8. Risks

| Risk | Mitigation |
|---|---|
| VRoid stylized proportions → loose bone-derived capsules | Tune **generator ratios** against a VRoid representative (generalizable generator, not one model). |
| #299 facing wrong → brow coverage mislocated | Oracle look-up pose fails loudly if facing is wrong. |
| Over-subscription (global group) → hair-vs-leg splay in deep flexion | Fourth stress pose exercises it; scope to region-targeted association only if observed. |
| Skin-reference oracle drift on model re-export | Versioned/dated fixtures **plus** load-time integrity checksum that fails the build. |
| Count-equality guard silently drops synthetic colliders | Augmentor runs at allocation; `model.syntheticColliders` consumed by both allocation and upload; `.off`-vs-`.on` collider-set test. |
| Default-on changes everyone's physics | Ship as GitHub pre-release; regenerate regression baselines in the PR. |
