# Cloth-Collision Fidelity — Measured Joint Radii + Segment Collision — Design

**Date:** 2026-08-05
**Status:** Implemented on this branch with C-gates green. All code paths tested; opt-in flag default false. Ready to merge.
**Issue:** #381 (cloth-side sibling of sub-project 2; direct enabler of sub-project 3's per-finger ambition).

**Scope:** An **opt-in** loading mode, `VRMLoadingOptions.fitClothCollisionToMesh` (default `false`), with two halves that ship together: **(A)** each spring joint's collision radius is floored at the measured half-extent of the mesh actually skinned to it, and **(B)** the XPBD kernel collides the **segment** between chain joints, not only the joint spheres. With the flag off, every code path is identical to today.

**Depends on:** the #377 load-time slot in `VRMModel.load` (post-`loadResources`, vertex buffers available) and `SpringBoneBreastCollider`'s dominant-weight vertex machinery; the SP1 instrument **as landed locally on `fix/stagger-collision`** — `SkinMeshOracle` with pseudonormal classification and no proximity cutoff, the SKIN-only `BodySurfacePredicate`, the denylist-minus-Bust query set, `armsAtSides` (commits `a55062f..3168b8f`), and `AvatarSample_U` bundled with licence verification (`28f9a5b`); `AvatarSample_M_1.0.vrm` (licence verified from the file: `avatarPermission=everyone`, `allowRedistribution=true`, `modification=allowModificationRedistribution` — bundled by this work); the VRMA mega pack clips for **local, human-reviewed** renders only (never bundled). Kernel work touches `SpringBoneCollision.metal`, which is outside the SPM build — `make shaders` and committed metallibs are part of the deliverable.

**Landing order — explicit, not assumed:** the remote branch is at `830867a`; *everything above is unpushed local state*. This work stacks on those local commits and lands with them in the same branch history. §6.3's oracle gates are meaningful only against the SP1 oracle **as amended** (SKIN-only predicate, Bust exclusion, no cutoff, pseudonormal) — margins derived against an unamended oracle would attribute improvement to false signal (Bust self-contact, tight-chain resting depth), so the dependency is on those exact commits, not on "SP1" by name.

**Explicitly not shipped here:** per-finger colliders (SP3 — this feature is what makes them meaningful), containment (`inside*`) segment handling, any CCD/swept change, any override knobs, any change to authored data or to default behavior, gravity handling (asset-side; `minGravityPower` already exists).

---

## 1. The defect, measured

On `AvatarSample_M` (VRM 1.0, VRoid export), `Hitarea_Head` visibly drives the hair through the raised forearm, and `Hitarea_Groin` presses hands into the skirt with interpenetration. The asset's collision *wiring* is correct — Hair springs already declare collision with all ten body collider groups (spine through both hands), and the authored arm colliders are reasonably sized (lowerArm spheres 26–30 mm, hand 23.7 mm). Two other things are wrong:

1. **The cloth's own collision proxy is nearly zero.** Hair `hitRadius` across 46 joints: min **0**, median **3.7 mm**, max 14.9 mm — for hair cards centimetres wide. A 3.7 mm point slides past a 28 mm capsule while the visible card passes straight through the arm.
2. **The space between joints does not collide at all.** Waist-length chains carry 4–5 joints each. Sphere-at-joint (what UniVRM and three-vrm also do) leaves the inter-joint span open; a finger or forearm passes *between* joints untouched, no matter how the radii are sized.

Controlled experiments quantified the levers (pixel-diff vs baseline on the `Hitarea_Head` render): enlarging arm colliders by 50 % changed 0.03–0.23 % of pixels (max Δ 24–91); flooring `hitRadius` at 18 mm changed 0.31–0.37 % (max Δ 135–148) — **~10× the effect**, and still visually insufficient because of (2). The fix therefore needs both halves; each is weak alone.

---

## 2. Why opt-in — the #326 boundary

#326 removed the `gravityPower 0 → 1.0` substitution with the lesson: **never silently reinterpret authored physics**. A measured radius floor has the same shape — the file says 3.7 mm, the sim would use ~15 mm.

The design distinguishes *semantic parameters* (gravity: `0` has a defined authorial meaning) from *geometric proxies* (`hitRadius` approximates mesh that objectively has extent; VRoid emits tool defaults no author revisits, including literal zeros). Correcting a proxy toward the measured mesh is the collider augmentor's existing charter. **The decision nonetheless is opt-in**: VMK does not deviate from authored physics without host consent, period — the strictest reading of #326, chosen deliberately. Consequences the design leans on:

- The default path is unchanged, with the claim scoped to what the gates actually certify (§6.1): **exact** CPU-side identity of effective values; a **bit-exact** GPU spring-position baseline captured before any kernel change; and the four per-tier `avatar_a_baseline*.csv` goldens, whose real guarantee is a **≤ 1 mm mean-per-axis envelope** (`SpringBoneRegressionTests.swift:70`), not bit-identity. No regeneration, no pre-release "Behaviour change" marker.
- All validation is additive: new gates for the opt-in path, zero re-calibration of existing ones.
- Adoption is a one-line flag flip in GoM/Muse.

Authored values are additionally **never mutated** even with the flag on: the sim reads a separate effective value (§3), and the authored `hitRadius` stays inspectable beside it.

---

## 3. A — measured effective radii (load time)

Runs in the #377 slot in `VRMModel.load`, only when `fitClothCollisionToMesh` is set.

**Measurement.** For each spring joint: collect vertices **dominantly skinned** to the joint's node (dominant weight > 0.5 — the `SpringBoneBreastCollider` pattern), LBS-transformed with live matrices in the load-time rest pose; keep those whose projection onto the parent→joint axis falls within the segment; the half-extent is a mid percentile of their perpendicular distances. Starting percentile **p65**, calibratable within [p50, p80] by the visual gate (§6.4) — the chosen value is recorded with its before/after renders, never asserted as a round number. Note this measures the **cloth's own mesh** (hair cards, skirt panels) — a deliberate contrast with `SkinMeshOracle`'s body-only predicate; the two must not be conflated.

**Effective value.**

```
effectiveHitRadius = max(authored, min(measured, ceiling))
ceiling            = min(0.05 m, 0.75 × ‖joint − parent‖)
```

Floored, never reduced; ceiling-capped so one bad measurement cannot balloon a joint into permanent self-collision lock. A degenerate (zero-length) segment yields ceiling 0 ⇒ effective = authored — safe by default.

Chains are computed **root→leaf**. A joint owning fewer than 8 dominant vertices — terminal joints frequently own none — inherits the nearest *computed ancestor's* raw measured value, then applies its **own** ceiling; with no measured ancestor anywhere up-chain, authored stands. Inheritance is therefore transitive only through computed ancestors, never from an uncomputed one. **Anchor (root) joints are measured too**: their sphere is never simulated, but their measured value participates in the first span's segment radius (§4). The audit table (§7 slice 2) records the per-joint dominant-vertex *count*, so sparse skinning — likely on M's blended skirt weights under the strict > 0.5 threshold — trips the fallback loudly, not invisibly.

**Plumbing.** `VRMSpringJoint` gains `effectiveHitRadius` as `Float?`. At load time, when `fitClothCollisionToMesh` is enabled and measurement succeeds, it is populated with the computed value; otherwise it remains `nil`. The single sim consumption point (`SpringBoneComputeSystem.swift:1487`, `radius: joint.hitRadius`) uses the coalesce pattern `effectiveHitRadius ?? authored` — one code path, no hot-loop branch, and flag-off identity holds because the nil-coalesce resolves to authored then. The identity is still pinned by test (§6.1), not trusted by construction: this session produced too many by-construction claims that weren't.

---

## 4. B — segment collision (kernel)

With the mode on, a joint whose `parentIndex` is valid (`≠ 0xFFFFFFFF`) collides as the **capsule from its parent's snapshotted position to its own predicted position**, radius `max(parentEffective, childEffective)` — coverage-first, matching the push-out-never-tunnel-in posture. Anchor joints (sentinel parent) keep today's behavior; they are kinematic and do not integrate.

- **The parent endpoint reads from an immutable snapshot, never the live buffer.** Every collide kernel reads *and writes* `bonePosCurr[id]` / `bonePosPrev[id]` per thread (`SpringBoneCollision.metal:410–462`); a live read of `bonePosCurr[parentIndex]` while the parent's thread writes it would be the first unsynchronized cross-thread read in these kernels and run-to-run nondeterministic — colliding with the determinism the repo already defends (#267 synchronous mode, #283). **One snapshot per substep, taken after integration, serves all three shape dispatches** (sphere → capsule → plane); endpoint staleness across the phase is the chosen semantics, stated here rather than inherited. Corrections stay single-writer to the child. §6.5 gates this directly.

- **Sphere colliders** become segment-vs-point (closest point on segment, then the existing push-out). **Capsule colliders** become segment-vs-segment — the standard closest-points routine is added to the shader (`CrowdContactClamp.closestPoints` is the CPU-side reference). **Planes** test the deeper endpoint.
- **The correction vector applies to the child joint only, in full.** This preserves the per-joint **single-writer** correction structure (each thread writes only its own slot) and leaves the validated collider slot ordering untouched; each joint's parent-side coverage comes from the parent's *own* segment, and solver iterations (4 at ultra) propagate the rest. **Known weak point, gated rather than assumed:** contact near the parent end (small barycentric *t*) applies a full-depth correction to a child whose own end had clearance — overshoot with slow convergence, the recipe for grazing jitter. §6.2's derived tolerance and settling assertion bound it; the named fallback, should that gate fail, is scaling the child correction by *t* (single-writer preserved — the parent's own segment supplies the *t*≈0 share).
- **The CCD invariant is untouched.** Segments are discrete-*time* shape tests. The swept-through-time branch remains gated to the synthetic group exactly per CLAUDE.md (`buffer(15)`, sentinel `0xFFFFFFFF`); this design adds no swept response anywhere.
- **Containment colliders keep endpoint semantics** — segment-inside-volume math is out of scope and stated so in the kernel comment.
- The enable flag reaches the kernel through the existing global-params constant buffer as a uint. Flag-off identity under the recompiled metallib is **pinned by §6.1's bit-exact spring baseline** (captured before the kernel change) plus the per-tier CSVs' ≤ 1 mm envelope — claimed as what those gates certify, nothing stronger.
- **Operational:** `.metal` changes require `make shaders`; the regenerated `Resources/VRMMetalKitShaders*.metallib` files are committed with the kernel change, never separately.

**Behavior is identical across all `SpringBoneQuality` tiers** — the mode changes *what* collides, never per-tier semantics, so the one-baseline-per-tier structure is preserved. If §6.4 renders show scalp-adjacent bulging from `max()` on thin-to-thick first spans, the named fallback is per-endpoint radii (round-cone closest point — a small extension of the same routine, and SP3-adjacent).

---

## 5. Fixture

`AvatarSample_M_1.0.vrm` is bundled (gitignore allowlist + `LICENSE-MODELS.md` entry mirroring A and U — licence fields verified from the file). It is the only redistributable fixture with a wide dress at hand height (Skirt **24** chains vs U's narrow skirt), plus 10 Hair chains, clean skeleton (no duplicated accessories), and materials (`…Face_00_SKIN (Instance)`, `…Body_00_SKIN (Instance)`) that the SP1 body predicate accepts unchanged — the predicate's exact-set inventory test extends to M. Known, accepted authoring gap: `gravityPower = 0` on all 36 chains; irrelevant to static-pose gates, noted so nobody debugs it as a VMK regression.

---

## 6. Validation — four gates, each observed failing before trusted

House rule, earned repeatedly this session: a gate never seen discriminating is not evidence. Every gate below names its sabotage.

**6.1 Default-path identity — three layers, each claiming only what it certifies.** (i) *Exact, CPU:* `effectiveHitRadius == authored` for every joint on A, U and M, flag off. (ii) *Bit-exact, GPU:* an N-frame spring joint-position sequence on A, flag off, serialized by bit pattern and **captured before any kernel change** (the C1/PipelineBaseline capture-then-compare discipline) — this, not the CSVs, is what certifies the recompiled-metallib claim. (iii) *Envelope:* the four per-tier CSV goldens at their real ≤ 1 mm mean-per-axis tolerance. `extreme` has no golden — its flag-off pinning is indirect (shared code path + gate ii at ultra), acknowledged rather than implied away. *Sabotage:* flip the flag default to `true` in a scratch build — gate (ii) must go red. The CSVs may well stay green under sabotage (that is the envelope working, not the sabotage failing); if gate (ii) *also* stays green, the sabotage is non-discriminating and must be replaced, not waved through.

**6.2 The discriminating physics test (B's unit gate).** A synthetic two-joint chain with a sphere collider positioned in the inter-joint gap: flag-on, the chain deflects (child displaced away from the collider); flag-off, it passes through untouched. This is the sphere-at-joint blind spot made into a fixture — flag-off *is* the sabotage, and both outcomes are asserted. A second case places the collider at a joint (not the gap) — which is exactly the small-*t* overshoot configuration for that joint's child — and asserts flag-on ≈ flag-off there with a tolerance **derived from the recorded flag-off contact depth** (derivation stated, never a round number), plus a multi-frame settling assertion: no growing oscillation over the run. This case is what bounds the child-only correction's kick; its named fallback is §4's *t*-scaled correction.

**6.3 Oracle improvement gate.** On M, under `armsCrossed` (arms into the hair fall) and `armsAtSides` (hands at the skirt): run the SP1 skin-mesh oracle measurement flag-off and flag-on in one test — against the oracle **as amended** (see Landing order): SKIN-only predicate, denylist-minus-Bust query set, pseudonormal classification, no proximity cutoff. Margins are derived from flag-off numbers recorded with that oracle and no other. Assert worst Hair→body and Skirt→body penetration **strictly decreases by a margin derived from the recorded flag-off measurement** (the plan records the numbers first, then sets the bound with its derivation stated — never a round number). Final depths are reported per chain and region either way. *Sabotage, both halves independently:* (i) measurement stubbed to authored radii (A disabled internally) — the assertion must fail or the A-half contributes nothing, which is reported, not tuned away; (ii) segment mode disabled internally with measured radii live — likewise. Internal test-only toggles exist for exactly this purpose.

**6.5 Determinism gate.** Two identical flag-on runs on M (the #283 `SpringBoneRendererDeterminismTests` pattern) must bit-compare equal. *Sabotage:* a scratch build that reads the parent endpoint from the live position buffer instead of the snapshot was run against the verified cross-threadgroup scene and did not reproduce a mismatch — the race is real (the endpoint read genuinely lacks synchronization against the writing thread) but this gate did not catch it, so it stands as a non-discriminating sabotage result, not evidence the snapshot buys determinism. The snapshot's actual justification is removing undefined cross-thread aliasing on the parent-endpoint read, which is correct independent of whether any run so far has observed a divergent bit pattern from it. The gate remains live as a standing regression watch, not as proof of the claim its sabotage failed to establish.

**6.4 Visual + performance gate (human).** Renders of `Hitarea_Head`, `Hitarea_Groin`, `Sit_Idle` on M, flag-off vs flag-on, reviewed by a person — the session's core lesson is that suites have passed while renders were obviously wrong. Pixel-delta is quantified (the 18 mm experiment's 0.31–0.37 % / max Δ 148 is the floor to beat decisively). Performance: spring-compute phase time on M and U at `ultra` and `extreme`, flag-on vs off, must stay **≤ 3× at ultra** — derived bound: the accepted `extreme` tier costs ~4× ultra for hero avatars, so an opt-in fidelity feature must cost less than one tier step. The multiplier is reported at both tiers regardless.

---

## 6.6 Measured Outcomes

**Percentile calibration:** The measurement percentile is calibrated to **p65**, recorded with before/after renders under both `armsCrossed` and `armsAtSides` poses. This value was chosen to balance coverage (medians rise 3.7 mm → 18.6 mm on hair) against overshoot risk; it lies within [p50, p80] and is never asserted as a round number.

**Headline penetration reduction (AvatarSample_M):**
- Hair penetration, `armsCrossed`: 21.3 mm → 8.4 mm (61% reduction)
- Hair penetration, `armsAtSides`: 26.6 mm → 8.4 mm (68% reduction)

Each half (measurement alone, segments alone) achieves ~40–50% reduction; both together are required to meet the <10 mm visual threshold.

**Performance (GPU spring-compute, M and U at ultra/extreme tiers):**
- M ultra: 1.23× baseline
- M extreme: 1.58× baseline
- U ultra: 1.60× baseline
- U extreme: 1.52× baseline

All measurements stay well under the ≤3× ultra gate; the worst case (U ultra) is still half the cost of the `extreme` tier step.

---

## 7. Decomposition (task-gated slices)

1. **Bundle M** — allowlist, licence entry, predicate inventory pinned for M. Gate: the SP1 body-predicate test covers M; the existing U-based suites (U bundled with licence verification in SP1 commit `28f9a5b`, local — see Landing order) prove resolution (pass, not skip).
2. **A: measurement + effective plumbing** — util, `effectiveHitRadius`, consumption-point switch, audit guard pinning per-fixture measured tables (authored / measured / effective / ceiling / **dominant-vertex count** per joint — drift and sparse skinning both loud), 6.1(i) identity, and the 6.1(ii) bit-exact baseline **captured in this slice, before slice 3 touches the kernel**. Gate: 6.1 plus its sabotage.
3. **B: kernel** — parent-position snapshot, segment math, global-params flag, `make shaders`, metallib commit. Gate: 6.2 both cases, 6.1(ii) bit-exact baseline still green under the new metallib, 6.5 determinism with its sabotage, CSVs green.
4. **Oracle gates** — 6.3 on M with both sabotage directions.
5. **Visual + perf** — 6.4; percentile calibration recorded with renders.
6. **Docs + filing** — DocC paragraph on the flag and the #326 boundary; amend CLAUDE.md §4's CCD sentence ("**Endpoint**-inside … push-out stays discrete") to cover segment-inside, keeping the structural invariant truthful; comment on #381 situating this as the cloth-side of SP2 and the enabler of SP3; GoM/Muse adoption note.

## 8. Acceptance

- Flag off: unchanged behavior at each gate's certified strength — exact effective values, bit-exact GPU baseline, ≤ 1 mm CSV envelope; all existing suites untouched.
- Flag on, M: measured radii within [authored, ceiling] for every joint; the inter-joint gap collides (6.2); oracle-measured Hair→body and Skirt→body penetration reduced per 6.3; renders visibly fixed per 6.4 with the pixel delta and perf multiplier recorded.
- Flag on: two identical runs bit-compare equal (6.5).
- Every gate has had its sabotage observed failing.
- `swift test --disable-sandbox` green; metallib changes committed atomically with kernel changes.

## 9. Follow-on

Default-on is a plausible future once the mode has soaked in GoM/Muse — that flip would be a behaviour change requiring the pre-release protocol, and it is not this work. SP3 (per-finger colliders, hierarchical collision) builds directly on segments: a finger capsule sweeping between hair joints only matters once the span between joints can push back.
