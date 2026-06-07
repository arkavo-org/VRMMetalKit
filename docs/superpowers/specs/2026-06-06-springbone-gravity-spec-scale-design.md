# Spec-conformant spring-bone gravity (#324)

## Problem

VMK applies spring-bone gravity at ~9.8× the VRM spec scale. The shader treats
`gravityPower` as a *fraction of Earth gravity* and multiplies it by
`length(globalParams.gravity)` (= 9.8, set unconditionally), plus an up-to-5×
settling `gravityBoost`. The `VRMC_springBone` algorithm — and UniVRM (both 0.x
and 1.0 paths), three-vrm, and godot-vrm — treat `gravityPower` as the strength
**directly**: `external = gravityDir · gravityPower · dt`, with no Earth-gravity
constant and no version-dependent scaling.

The oracle check (UniVRM) confirms there is **no** 0.x→1.0 gravity-scale
difference: both `SpringBoneJointInit.cs` (0.x) and `UpdateFastSpringBoneJob.cs`
(1.0) compute `gravityDir · gravityPower · dt` (the 0.x `scalingFactor` is
non-unit avatar scale, ≈1). So the 9.8 is a VMK data-model reinterpretation
applied ungated to every asset, not a conversion artifact. A spec-authored asset
sags ~9.8× harder in VMK than in any other VRM renderer.

## Decisions

- **Polarity:** spec scale becomes the **default** (no opt-in flag retaining the
  9.8). Migration documented in the PR and release notes.
- **No retained non-conformance** on the gravity term: drop both the
  `length(gravity)=9.8` multiplier and the settling `gravityBoost`.
- **Global force knob** stays in `SpringBoneGlobalParams` — repurposed to the
  spec's additive external force.

## Change

### Shader — `SpringBonePredict.metal`

Replace:
```metal
float gravityMagnitude = length(globalParams.gravity) * gravityBoost;
float3 effectiveGravity = boneParams[id].gravityDir * gravityMagnitude * boneParams[id].gravityPower;
```
with the spec form:
```metal
float3 effectiveGravity = boneParams[id].gravityDir * boneParams[id].gravityPower;
```
`gravityBoost` lives only inside `gravityMagnitude`, so it dies with it. Per-substep
gravity delta becomes `gravityPower · dtSub` — spec-exact.

### Global `gravity` param

Currently the global `gravity` feeds the gravity term only via its *length* (its
direction is ignored; per-joint `gravityDir` carries direction). The spec has no
global gravity multiplier; the only spec-sanctioned global force is UniVRM's
additive `ExternalForce`. Repurpose `SpringBoneGlobalParams.gravity` as an
**additive external force** (added alongside wind/inertial, not multiplied into
the gravity term), and change its default from `[0,−9.8,0]` to `[0,0,0]` so
per-joint gravity is the sole, spec-exact gravity source.
`applySpringBoneForce(gravity:)` and its restore-to-`[0,−9.8,0]` logic become
restore-to-zero.

## Out of scope (explicit)

1. **#162 `gravityPower=0→1.0` substitution** — a *separate* non-conformance
   (UniVRM treats `gravityPower=0` as no gravity). Folding it in would change
   whether 0.x hair has gravity at all. #324 closes only the 9.8 gap. Net effect:
   AvatarSample_A still droops, at spec scale (~9.8× less than today).
2. **Settling drag reduction and stiffness ramp** — affect velocity decay /
   bind-pose blend, not gravity magnitude; they don't violate #324's steady-state
   criterion. Removing the settle machinery is a separate concern.

## Verification (TDD-first)

- New spec test: 4-joint chain, `gravityDir=[1,0,0]`, `gravityPower=0.5`; assert
  first-step sideways tip displacement ≈ `gravityPower · dtSub` (spec scale), not
  the 9.8× value. Written red against current code first.
- Regenerate `SpringBoneRegressionTests` baseline (freezes the trajectory; will
  trip — expected) and any AvatarSample_A render baseline; regenerate
  `AvatarSample_A.png` sanity render.
- `swift build` + `make shaders` (the `.metal` change needs a manual `metallib`
  rebuild) + full spring-bone test suite.
- Migration notes in PR + release notes; mark the release a pre-release
  (behaviour change) per the established convention.

## Acceptance

VMK's per-step gravity displacement for a given `gravityPower` matches
`gravityPower · dt` — parity with three-vrm / godot / UniVRM / spec on a
sideways-gravity bend.
