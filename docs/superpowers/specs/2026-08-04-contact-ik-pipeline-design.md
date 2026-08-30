# Contact IK — Stage Pipeline Unification — Design

**Date:** 2026-08-04
**Status:** Implemented on branch `fix/stagger-collision`; C1–C4 landed.
**Track:** Contact IK — a track parallel to the cross-avatar-collision increments, not a member of that sequence (Increment 4 there is upright recovery / stance re-centering, still unclaimed). Builds on **Increment 3** (`StaggerShoveSolver`, capture step) and the shipped cross-avatar body-response (`PosturalContactSolver`, `PosturalContactLayer`, `CrowdFrameStepper`). Its first client is the Contact IK protocol RFC.

**Scope:** Replace the two competing frame orderings — `AnimationLayerCompositor` priorities and `CrowdFrameStepper`'s hand-rolled phases — with **one named stage pipeline**, hoist the VRM node-constraint solve to run on the final pose, and make limb IK terminal. Ships the seams that the follow-on protocol RFC (`InteractionVolume`, `ContactGoal`) specifies against.

**Explicitly not shipped here:** pelvis solver internals, arm/hand IK, `InteractionVolume` / `ContactGoal` definitions, look-at layerization, spring-collider-as-proxy export. Each of those specs against an S2/S3 seam that this increment creates by name.

---

## 1. Framing — why ordering, and why now

Two orderings exist today and neither is authoritative.

`AnimationLayerCompositor` runs layers by integer priority (`LocomotionBlend -10`, `IdleBreathing 0`, `Expression 1`, `ARLookAt 2`, `IK 4`, `PosturalContact 5`, `ArmCounterbalance 6`). `CrowdFrameStepper.step()` runs a hand-rolled phase sequence (0a animation → 0b placement → 0c propagate → 0d postural → 0e shove + capture step → 0f counterbalance) and calls two of those "layers" through `applyDirect`, bypassing the compositor entirely.

That bypass is the evidence. Someone had to pull postural yield out of the compositor to get the ordering right, because priorities could not express the guarantee "the lean lands before the spring solver reads the chest." **The crowd's phase list is a discovered ordering that the priority mechanism could not represent.** This increment promotes it to *the* ordering rather than merging two peers, and single-avatar becomes the n=1 case of the same pipeline.

Three defects follow from having no authoritative order, and all three close here or become reachable here:

1. **Constraints run on the wrong pose.** `ConstraintSolver.solve()` is called inside `AnimationPlayer.update()` (`AnimationPlayer.swift:272`), immediately after clip sampling and before every layer. Twist bones therefore track the raw animation, not the posed skeleton — visible today as forearm twist ignoring the counterbalanced arm, and fatal the day hand IK lands.
2. **The stagger shove is out of band.** It mutates the scene root in `CrowdFrameStepper` Phase 0e (`:264-272`), outside the compositor. No assignment of layer priorities reaches it, so the moment foot IK holds world-space targets, a post-IK root displacement is guaranteed foot sliding.
3. **Contact seams land in the wrong pipeline if crowd stays separate.** The follow-on RFC's subject is cross-entity interaction, and avatar-avatar interaction exists *only* in the crowd path. Specifying seams into the single-avatar pipeline would leave the path that actually interacts off-spec.

**The structural move:** limb IK leaves the compositor. Priorities keep meaning only *within* the pose stage; cross-stage order becomes unrepresentable-wrong rather than a number that can be misassigned.

---

## 2. Execution model

**Stage-major across avatars.** All avatars complete Sn before any avatar starts Sn+1. Stable iteration order (the existing `avatars` array order).

### 2.1 Verified starting state — the loop is avatar-major today

`CrowdFrameStepper.step()` is a single `for avatar in avatars` loop (`CrowdFrameStepper.swift:214-295`) containing phases 0a through 0f. Only the torso gather (`:179`) and the postural partner-feed (`:208`) are stage-major, and both run *before* the loop.

The conversion to stage-major is nonetheless **observationally identity-preserving today**, for a specific reason: every cross-avatar read goes through the frame-frozen pre-loop `torsos` snapshot. `nearestPartnerTorso(of:torsos:)` reads that snapshot; Phase 0e's partner side deliberately stays stale (the documented one-frame lag) while only `mine` is recomputed live from the avatar's own just-updated pose. **No phase reads another avatar's current-frame mutated state**, so avatar-major and stage-major produce identical output.

That equivalence is contingent on the snapshot discipline, not guaranteed by it. Hence §2.2.

### 2.2 The snapshot invariant — enforced by signature

Stage functions take the shape:

```swift
func stage(avatar: inout AvatarState, partners: FrozenSnapshot)
```

Stages never receive the live avatar array. Live partner reads become **unwritable**, not merely detectable by assertion.

**Invariant, with its forward significance:** *cross-avatar interaction is interaction with the partner's last-committed frame.*

This is not a limitation the cross-entity RFC works around — it is the interface that RFC builds on. The one-frame partner lag is already documented behavior in the body-response design (§4 lag); it is what keeps stage-major and avatar-major equivalent; and it is what makes contact-goal synchronization deterministic across processes later. Anyone wanting live partner reads is proposing a different execution model and has to say so explicitly.

---

## 3. Stages

Per frame, in order:

### S0 — Sample
`AnimationPlayer` clip sampling, root motion, morph-track caching, VRMA look-at target. The `ConstraintSolver.solve()` call at `AnimationPlayer.swift:272` no longer runs in the pipeline (see §5 for the flag and its sunset).

### S1 — Compose
Pose-intent layers: locomotion, idle breathing, expression, look-at, postural contact, arm counterbalance. `IKLayer` is **removed from this stage**.

**S1 fixes sequence, not math.** Two application mechanisms coexist and stay distinct:

| Mechanism | Operation | Meaning |
|---|---|---|
| Compositor-composed | `node.rotation = basePose * delta` (`ProceduralAnimation.swift:353`) | pose *selection* |
| Direct-apply | `node.rotation = node.rotation * share` (`PosturalContactLayer.swift:167`) | a *correction operator* |

They coexist because they mean different things; unifying them would be churn for purity. S1's order is: compositor evaluation first, then direct-apply layers in declared order.

**Direct-apply rewrite contract (per-bone obligation):** *every direct-apply target bone must have a guaranteed every-frame upstream writer, or the yield accumulates frame-over-frame instead of decaying away.* Currently satisfied — postural writes spine/chest, counterbalance writes the four arm bones, neither overlaps a conditionally-driven bone. Future direct-apply layers are checked against this obligation.

**Stage-entry predicates are extracted behavior.** Counterbalance is currently nested inside `if staggerActive.contains(avatar.index)` inside `if staggerParams != nil` (`CrowdFrameStepper.swift:284`) — it runs only when stagger is enabled *and* that avatar has had contact. That predicate travels with the stage unchanged. Un-gating it is a separate behavioral decision and probably a bad one: `ArmCounterbalanceLayer` ticks a decay path at intensity 0 (`:75,:80`), so unconditional execution burns work on never-contacted avatars and evolves state that today stays untouched.

### S2 — Displace
**Sole writer of scene root and hips.** A displacement request queue absorbs crowd steering (Phase 0b placement), the stagger shove (Phase 0e), and later goal-approach motion.

**Displacement conflict rule:** At most one absolute request per avatar per frame; every other request is an additive delta applied after it, in insertion order. Scripted placement is the absolute writer; the shove and later goal-approach are deltas. A second absolute request is a wiring bug (`precondition` in debug). See `RootDisplacement`.

**Exit contract:** root and hips are final, **and world transforms are refreshed** (see §4).

**S2 executes in two beats:** The actual stage ordering is `sample → place → compose → displace → limbSolve → constrain`, not a linear S0–S6 sequence. Placement (crowd steering) must precede S1 composition because the postural lean measures its own trunk endpoints in world space, which depends on where the avatar was placed. The shove must follow S1 because its penetration signal is derived from the lean-relieved pose. Collapsing the two beats into a single contiguous S2 would alter the depth signal — placement before lean-measure gives a different result than shove-after-lean-measure, because the shove reads the lean's output and fires based on it.

### S3 — Limb solve
Terminal pose writes, in order: pelvis height/tilt slot (empty this increment), then leg two-bone IK, later arm/hand contact IK.

The foot target source is injected behind a protocol. Day one it is `FootContactDetector` unchanged — a behavior-preserving relocation, not a rewrite. `InteractionVolume` swaps in at the same seam later.

Because S2's exit contract is finality, `groundProbe` timing is now a definable sentence: **S3 entry, after S2 finality.**

### S4 — Constrain
`ConstraintSolver.solve()` runs here, on the final pose. **Nothing before S4 reads constraint outputs.** A layer needing post-constraint pose is a cycle — a design smell to surface, not accommodate.

### S5 — Secondary
Spring bones, on the constrained skeleton. Collider-as-proxy export is next-RFC; the one-frame latency is noted now.

### S6 — Commit
`updateNodeTransforms` + skinning upload.

---

## 4. Transform validity as a stage-boundary contract

The loop currently calls `updateNodeTransforms()` up to **five times per avatar per frame** (`CrowdFrameStepper.swift:226, 234, 271, 277, 291`). Those calls are not redundancy — subsequent phases read world space: the shove computes penetration from world positions, leg IK reads world-space feet. **Collapsing them to a single S6 call would stale every mid-loop world-space read.** This is a behavior-change hazard, not a free win.

The principled form: **transform validity is a stage-boundary contract.** S2's exit contract already says root/hips final; it extends to *world transforms refreshed*, because S3 reads world space.

Propagation count in the fully-active regime (stagger enabled, constraints enabled) is **seven per avatar per frame**, not the two proposed here. The reason: `place`, `compose`, `displace`-exit, and `limbSolve`'s IK and arm branches each have real downstream readers that require current world space, and `CaptureStepController` propagates twice internally as part of its own algorithm. C1 preserves all five existing call sites as stage postludes so byte-identity holds trivially; the 5→2 projection was superseded by C4's observed floor.

| constraints | staggerActive | old | new | Δ |
|---|---|---|---|---|
| yes | yes | 8 | 7 | −1 |
| no | yes | 7 | 7 | 0 |
| yes | no | 4 | 4 | 0 |
| no | no | 3 | 4 | +1 |

**C4 is a structural cleanup, not a performance win:** idle crowd members pay one extra hierarchy walk per frame when both stagger and constraints are disabled.

---

## 5. `AnimationPlayer.solvesConstraints` — flag and sunset

Removing the constraint solve from `AnimationPlayer.update()` is a public API behavior change. Direct callers that will never run the pipeline: `VRMVideoRenderer`, `VRMAValidator`, `VRMBenchmark`, `VRMRenderer`, plus `DualQuaternionSkinningTests`, `VRMAMinimalTest`, `VRMAComprehensiveTests`, `SkinningTests`, `VRMAValidationTests`, and the `AnimationAndRetargeting` docc article documenting the behavior. A silent delete drops twist bones for all of them.

- `AnimationPlayer.solvesConstraints`, defaulting `true`. S0 sets it `false`; S4 takes over.
- **Sunset:** production render paths (`VRMRenderer`, `VRMVideoRenderer`) eventually run the pipeline and stop touching the flag. Validators, benchmarks, and test suites keep it **indefinitely** — they test `AnimationPlayer` in isolation, where constraint-inclusive output is the correct contract. The flag is a permanent seam for isolation testing, not debt awaiting cleanup.
- The docc article gains a paragraph, not a rewrite.

---

## 6. Commits and gates

**Gate form: golden *sequences*, not golden frames.** Evolving state (counterbalance decay, shove offset, contact-detector latch) diverges only over frames — a single-frame byte-identity check can pass while the trajectory forks.

**C1 — mechanical extraction.**
Stages extracted; crowd phases become bindings to shared stage functions; stage-entry predicates travel unchanged; all five `updateNodeTransforms` sites preserved as stage postludes; constraint call stays at its old site behind the default-`true` flag.
*Gate:* byte-identity over N-frame sequences across the matrix {stagger-off, stagger-on-pre-contact, stagger-on-post-contact} × {single-avatar, crowd}.
*Behavior change:* none, by construction.

**C2 — constraint hoist.**
Move the solve to S4. Output changes only on constraint-source bones written after the old call site.
*Gate (split by caller):* pipeline fixtures assert the behavior change — forearm twist tracks the counterbalanced arm, today's latent candy-wrapper bug promoted to a fixture. Direct-caller fixtures (validator, benchmark, isolation tests) assert byte-identity via `solvesConstraints = true`. Bounded-delta check everywhere else.

**Gate reach limitation:** The test fixture authors zero VRM node constraints, so the C1 byte-identity gate is structurally incapable of detecting a C2 regression — hoisting the solve changes nothing observable on a constraint-free rig. C2's correctness rests on the synthetic-constraint tests in `ConstraintHoistTests`. Recommend adding a rig with authored `VRMC_node_constraint` twist bones as a second fixture to get real end-to-end coverage.

**C3 — S2→S3 re-solve.**
Foot IK re-solves after displacement. Identity when displacement is zero, so the no-contact regime is unchanged by construction.
*Gate (crowd fixture):* planted-foot drift measurement showed the crowd fixture already passed before any change (9.7e-05 m). The original threshold was rewritten as cumulative drift from the plant versus `controller.target(_:)` with a 2 mm threshold. The crowd path's headline was decorative; measurement also showed the original rate-limited shove (0.14 m/s maximum) could not fail the old 5 mm frame-to-frame threshold at 1/60 s (max 2.33 mm).
*Gate (single-avatar):* C3's actual evidence is the `IKLayer` gate, which failed by construction at 0.05 m before the change on the single-avatar fixture and passes after.

**C4 — propagation reduction.**
5 → 2 propagations per avatar per frame, per §4.
*Gate:* the same C1 golden sequences.

**Finding: pre-existing `IKLayer` bug discovered and fixed during C3.** `IKLayer.solveIKForLeg` assigned `TwoBoneIKSolver.solve`'s world-frame rotation directly as a bone-local rotation. VRM legs rest at roughly −Y, so the aim hit `aimAt`'s antiparallel branch and produced a ~174.5° misrotation even for a trivial identity target. All 24 existing `IKLayerTests` stayed green because none applied solve output to a rig. The defect is now pinned by `IKLayerRoundTripTests`. `TwoBoneIKSolver`'s documentation, which called its output "local rotation for root joint", was the proximate cause and has been corrected to state world-frame with a +Y rest assumption.

**Standing guards (debug builds):** write-assert on root/hips after S2 exits; read-assert on constraint outputs before S4. Regressions become structural failures rather than visual ones.

---

## 7. Ordering summary

```
S0 Sample     clip sampling, root motion
S1 Compose    pose-intent layers (compositor, then direct-apply, in declared order)
S2 Displace   sole root/hips writer  →  exit: root/hips final, world transforms refreshed
S3 Limb solve pelvis (slot) → leg IK → (later) arm/hand IK; target source injected
S4 Constrain  ConstraintSolver on the final pose
S5 Secondary  spring bones on the constrained skeleton
S6 Commit     updateNodeTransforms + skinning upload
```

Invariants, in one place:
- Cross-avatar interaction is interaction with the partner's **last-committed frame**; stages take a frozen snapshot, never the live array.
- Every direct-apply target bone has a **guaranteed every-frame upstream writer**.
- Root and hips are written **only** in S2.
- **Nothing before S4 reads constraint outputs.**
- Priorities govern **intra-S1** composition only.

---

## 8. Follow-on

When C1 is green, the protocol RFC (`InteractionVolume` pull-queries, `ContactGoal` push-intent) drafts against these seams — at which point "the IK stage calls this before X" has a real X. `PosturalContactLayer` is that RFC's first refactor client: partner avatars register in the volume as entities with spring-bone colliders as the proxy, and the bespoke partner-torso-capsule path collapses into `sweep`/`affordances` queries. `FootContactDetector` survives as the *when* (lock/unlock state machine) but is re-sourced — the *target* comes from `groundProbe` rather than the velocity/height heuristic.
