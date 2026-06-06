# ADR-007: SpringBone sleeve→arm catapult is a spec-solver-class limitation, not a VMK defect

**Status:** Amended 2026-06-06 — the "do nothing" outcome is **superseded for hand/arm colliders** by the Amendment below (#321). The mechanism findings (catapult is a large-timestep instability; substepping is the only monotonic lever) still stand and now justify the fix rather than its deferral.

**Date:** 2026-06-06

**Deciders:** VMK, VRMConformance team; amended by product (Arkavo) for #321

**Tags:** physics, springbone, conformance

## Context and Problem Statement

Issue #313 tracked two motion-transient cloth-clipping manifestations. Track 1
(swept/continuous collision) is shipped. Track 2 is the residual: a stiff
3-joint sleeve chain on AvatarSample_U penetrates the arm during a fast arm
swing. #312 had dropped synthetic arm capsules because adding a collider made
peak penetration *worse* — the capsule deflects the stiff whip ("the catapult").
The question: can the catapult be fixed, and must it be, to meet the conformance
reference (UniVRM)?

## Decision Drivers

- The catapult signature: a collider *reduces* the number of penetrating frames
  but *raises* peak depth (occasional deep launch).
- Conformance methodology: a divergence from the UniVRM oracle is a documented
  finding, not a silent quality patch.
- Project is winding down; cost and scope matter.

## Considered Options

- **Re-add arm capsules + swept CCD** (Track 1 mechanism applied to arms).
- **Tune arm-capsule radius** (sizing gap vs. true skin).
- **Post-contact tangential friction** (bleed deflection energy).
- **Push-out velocity-kill** (carry `prev` along the correction so the positional
  push-out injects no velocity — the canonical PBD rule).
- **Finer substepping** (smaller dt → the stiff chain resolves the contact
  instead of catapulting).
- **Do nothing; document** (accept as a solver-class characteristic).

## Decision Outcome

**Chosen option: "Do nothing; document."** Two independent findings force it:

1. **Substepping *is* a real fix, but it is supererogatory.** A validated sweep
   (AvatarSample_U arm-swing, arm capsule in the synthetic group + CCD) shows the
   catapult is a large-timestep instability, not intrinsic geometry: at 120 Hz
   the arm capsule is worse than coarse; at 240 Hz it is ≤ coarse (3–7/180
   frames); at 480 Hz it nearly eliminates penetration (0–1/180 frames, 1–7 mm).
   The result is *monotonic* in substep rate — the fingerprint of a real fix —
   unlike the radius, friction, and velocity-kill sweeps, which were all
   non-monotonic and failed.

2. **The reference exhibits the catapult worse.** UniVRM's FastSpringBone does a
   single Verlet step per frame at frame-rate `deltaTime` (no accumulator, no
   substep), driven at 1/60 by the conformance harness — *coarser* than VMK's
   catapulting 120 Hz baseline, by the identical single-step positional-collision
   algorithm. An arm capsule on the stiff sleeve in UniVRM would therefore
   catapult at least as hard. There is no quality gap vs. the reference to close:
   VMK at 120 Hz already meets/exceeds UniVRM, and 240 Hz would put VMK *above*
   the reference.

So the sleeve→arm catapult is a characteristic of the VRM spring-bone solver
class on a stiff short chain (no DOF to drape — it can only lever), shared by the
reference, and **not a VMK defect**. The 2–4× spring-bone GPU cost of the
substepping fix buys quality beyond the reference bar on a winding-down project.

### Positive Consequences

- Track 1 (sphere + capsule swept CCD, synthetic-group scoped) is the clean,
  shipped deliverable; no behaviour-change baseline reset is needed.
- The substepping lever is documented and validated, so a future
  quality-above-reference effort has a known, monotonic path (raise substep rate,
  re-enable arm capsules in the synthetic group).
- Authoring guidance is clear: the real-ecosystem fix for stiff-chain clipping is
  more joints / a softer chain (or a compliant XPBD cloth solver à la Magica
  Cloth), not a better collider.

### Negative Consequences

- AvatarSample_U's sleeve still transiently clips the arm under fast motion
  (≈13/180 frames at 120 Hz). Accepted as conformant-class behaviour.

## Notes

- **Levers swept and rejected for the arm capsule** (all non-monotonic, all worse
  than coarse): discrete vs. swept CCD; radius fraction 0.12–0.36; tangential
  friction 0–0.9; push-out velocity-carry 0–1 (`carry=1` pure projection was the
  *worst* — it preserves the inward pre-collision velocity and the stiff chain
  levers it deeper). Only finer substepping moved the result.
- **Collision op-order confirmed correct**: VMK runs `predict → distance×N →
  collision` (collision last), so there is no length-reprojection amplifier.
- **Latent bug discovered (filed as #316, separate from #313):**
  `SpringBoneComputeSystem.update` never reassigns `params.dtSub` from the active
  substep rate. At the default ultra quality (120 Hz, load sets `dtSub = 1/120`)
  they match, so production is correct — but the non-ultra quality presets
  (60/90 Hz) integrate at the wrong `dtSub`. The one-line fix
  (`params.dtSub = Float(fixedDeltaTime)`) is a no-op at ultra; it ships with its
  own non-ultra validation under #316, not on the #313 branch.

- **Methodology footnote (how this conclusion was reached):** the initial call was
  a premature "deflection is intrinsic, collider route closed," reached after the
  radius and friction sweeps. That was overturned by evidence — the VRMConformance
  team's critique prompted sweeping two untried levers (velocity-kill, then
  substepping); velocity-kill also failed, but substepping revealed the catapult
  is a *resolvable* large-timestep instability, which reframed "intrinsic" as
  "intrinsic at this substep rate." The durable finding is the mechanism above
  (substepping is the only monotonic lever; the reference single-steps coarser, so
  there is no gap to close), not the bookkeeping of which interim call was wrong —
  but the correction is recorded so the "closed" verdict is not re-trusted blindly.

## Amendment (2026-06-06) — pursue hand/arm colliders for #321

**What changed:** product priority, not the physics. On-device QA of a production
VRoid avatar (`5824032820619220341`) confirms persistent **hand-poke-through** —
fingers passing through the chest ribbon, hair, and skirt when the hand contacts
the body (#321). This is a visible defect on real content; the original decision
optimized for *conformance cost on a winding-down project*, a weighting that no
longer holds now that the avatar quality bar is the priority.

**Why the original "do nothing" no longer binds here:**

- The hand-poke-through case is **not** the AvatarSample_U stiff-sleeve *catapult*
  the ADR analyzed. It is a **slow/deliberate gesture** (hand placed on chest,
  raised to head), not a fast whip — the large-timestep instability that made arm
  capsules worse is far weaker in this regime, so a hand/lower-arm collider can
  help at the production substep rate where the sleeve catapult could not.
- For the fast-motion residual, the ADR already identified the fix and proved it
  **monotonic**: raise the synthetic group's substep rate (240 Hz ≤ coarse,
  480 Hz ≈ eliminated) and run swept CCD (now shipped, #313). We accept the
  2–4× spring-bone GPU cost for the synthetic group as the price of the fix.

**New decision:** ADR-004's solver stands; this ADR's "do nothing" is **lifted for
the synthetic-collider augmentation path only**. Proceed to:

1. Extend `SpringBoneColliderAugmentor` to emit bone-derived **hand + lower-arm**
   colliders (palm sphere + lower-arm→hand capsule), in the reserved synthetic
   group, gated by the existing `augmentSpringBoneColliders` flag.
2. Validate against a hand-reachable cloth oracle/pose (net-new test infra,
   mirroring the #309 leg/head oracle) on a model whose hand contacts cloth.
3. For the fast-swing residual, gate the synthetic group at a higher substep rate
   (the proven monotonic lever) behind a quality tier, defaulting conservatively.

The arm/hand colliders remain **additive and authored-collider-safe**; if a model
or pose still catapults at the production rate, that specific case stays the
documented solver-class behaviour — but the common slow-gesture poke-through is
fixed. Tracked as #321.

## Links

- Refines [ADR-004](004-xpbd-springbone-physics.md)
- Amended for [#321](https://github.com/arkavo-org/VRMMetalKit/issues/321)
- Context: issues #309, #312, #313
