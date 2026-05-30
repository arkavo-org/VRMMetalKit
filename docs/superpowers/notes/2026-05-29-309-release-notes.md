# Release notes — collider augmentation (#309)

## Behaviour change

`VRMLoadingOptions.augmentSpringBoneColliders` is **default `true`** starting with the release that includes PR #309. The loader now synthesizes additional bone-derived SpringBone colliders at load time, which shifts resting spring-bone positions on affected models (e.g. AvatarSample_A front hair) relative to all previous releases.

**Escape hatch.** Pass `augmentSpringBoneColliders: false` to restore authored-only collider behaviour:

```swift
let options = VRMLoadingOptions(augmentSpringBoneColliders: false)
let model = try await VRMModel.load(from: url, device: device, options: options)
```

**Pre-release policy.** Per project convention, the release carrying this change must be published as a GitHub **pre-release** until the primary consumer (Avatar Muse) validates their assets against the new resting positions. SPM stable-version resolvers skip pre-releases, so downstream pinned-to-`from:` constraints are unaffected.

## What shipped

- **Forward head/brow capsule** — eliminates front-hair-into-forehead sinking (#309 primary repro). Sized from the model's stored head-reference radius; placed along the forward axis of the head bone. Additive to any authored head/neck colliders.
- **End-to-end leg capsules** — one capsule per leg from upper-leg to ankle. Reduces skirt-panel-into-thigh peak penetration from roughly 23 mm to roughly 10 mm in the worst dynamic case and never regresses. A single-frame transient during fast leg swings can remain.
- **Lateral skull sphere** — one head-centered sphere (sized oracle-blind to the model's own authored cranium estimate) that gives the head lateral coverage the forward brow capsule can't reach. Closes the temple side-bang residual (look-up worst penetration 5.9 mm → 0 mm) with a localized baseline shift (4 temple strands, ≤5 mm, laterally outward) and no floaty hair.

## Follow-ups (post-PR #311)

| Artefact | Root cause | Status |
|---|---|---|
| Sleeve / arm clipping | PBD without CCD: joint tunnels through capsule in one substep, impulse overshoots → visible whip | **Deferred** — arm capsules investigated and dropped (net regression); needs CCD/substep/per-chain stiffness |
| Skirt→leg residual transient | Single-frame penetration during high-velocity swing; no CCD | **Deferred** — same CCD class |
| Lateral side-bang at temple | Forward brow capsule can't reach a lateral temple strand | **Resolved** — lateral skull sphere (this follow-up) |
| Models with ≥31 authored collider groups skip augmentation | Off-by-one: skip threshold was one too conservative | **Resolved** — supported up to 31 groups (skip now at ≥32, this follow-up) |
| Models with ≥32 authored collider groups skip augmentation | GPU group-bitmask is 32-bit; one slot required for synthetic group | By design; fully lifting it needs a shader-side universal-collider flag |
