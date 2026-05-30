# SpringBone Physics

Secondary motion for hair, accessories, and clothing, simulated on the GPU.

## Overview

SpringBone is what makes long hair sway when the head turns, lets a skirt trail behind a walk cycle, and gives earrings or charms a small bounce on impact. It is purely cosmetic — none of it feeds back into the humanoid skeleton — but it is the difference between an avatar that reads as "rigged" and one that reads as alive.

VRMMetalKit simulates spring bones with XPBD (Extended Position-Based Dynamics) running at a fixed 120 Hz substep cadence inside a Metal compute kernel. The fixed timestep is what keeps a long ponytail stable whether the render loop is delivering 30, 60, or 120 fps: each rendered frame integrates as many 120 Hz substeps as wall-clock time has accumulated, so behaviour does not change with refresh rate. The work runs entirely on the GPU and does not block the render pass.

## Configuration on disk

Spring configuration is authored as part of the VRM file, under the `VRMC_springBone` glTF extension. The loader parses it into ``VRMSpringBone`` (the top-level container), ``VRMSpring`` (one chain of joints), ``VRMSpringJoint`` (the per-joint parameters such as stiffness, drag, gravity, and hit radius), and ``VRMCollider`` shapes referenced through ``VRMColliderGroup``. At model load the renderer translates these spec types into the GPU-side buffers in ``SpringBoneBuffers`` and uploads them once.

## Colliders

``VRMColliderShape`` supports the two shapes the VRM 1.0 spec defines: sphere and capsule. Each collider belongs to one or more ``VRMColliderGroup`` instances, and a spring chain only collides against the groups it explicitly references — this is how a hair chain can ignore a hand collider while a skirt chain respects it. Plane colliders exist in the GPU layer (``PlaneCollider``) but are an internal implementation detail and are not authored from the file.

## Runtime controls

Most applications never touch the spring system at runtime: it is configured at load and stepped automatically. For transient effects — a wind gust, an impact, a jump landing — use ``VRMRenderer/applySpringBoneForce(gravity:wind:duration:)``. It overrides the global gravity and/or wind for `duration` seconds and then restores gravity to `(0, -9.8, 0)` and clears the wind amplitude. Either input can be `nil` to leave that channel untouched.

```swift
// Apply a 2-second wind gust while keeping default gravity.
renderer.applySpringBoneForce(
    gravity: nil,
    wind: simd_float3(2.5, 0, 0),
    duration: 2.0
)
```

``VRMRenderer/resetSpringBone()`` is provided as a stable entry point but is currently a no-op: the GPU pipeline reinitializes whenever a model is loaded.

## Procedural collider augmentation (#309)

VRM files rarely include colliders for every body part that animated geometry can reach, which leads to hair sinking into the forehead, skirt panels clipping through thighs, or sleeves passing through arms. To close the most common gaps, the loader can synthesize additional colliders at load time from bone positions and a stored head-radius estimate.

This behaviour is controlled by ``VRMLoadingOptions/augmentSpringBoneColliders`` (default `true`). The flag is purely additive: authored colliders are never mutated or removed. Set it to `false` to restore authored-only colliders — useful when A/B-testing a newly rigged model or bisecting a physics regression.

```swift
// Authored-only colliders — disable augmentation.
let options = VRMLoadingOptions(augmentSpringBoneColliders: false)
let model = try await VRMModel.load(from: url, device: device, options: options)
```

### What is synthesized

**Forward head/brow capsule.** A single capsule oriented along the forward axis of the head bone, sized from the model's stored head-reference radius. It closes the persistent front-hair-into-forehead clipping (#309 primary repro). Residual: a lone lateral side-bang strand at the temple can still touch the skull region; a future lateral head collider is needed to address it.

**End-to-end leg capsules.** One capsule per leg spanning from the upper-leg to the ankle joint. These substantially reduce skirt-panel-into-thigh clipping (peak penetration drops from roughly 23 mm to roughly 10 mm in the worst dynamic case and is never worse), though a single-frame transient can remain during fast leg swings.

### What is not addressed

Arm and sleeve clipping was investigated and intentionally not shipped: arm capsules could not be validated as an improvement and worsened a stiff-sleeve "whip" artefact. The root cause is PBD without continuous collision detection (CCD); when a joint tunnels through a collider in one substep the impulse overshoots, producing a visible snap. This is deferred.

### Behaviour-change note

Because augmentation is default-on, resting spring-bone positions shift on affected models relative to versions before #309. Any consumer that validates asset appearance against a golden render must re-approve those renders after updating. Per project policy, the release carrying this change is cut as a GitHub pre-release until the primary consumer (Avatar Muse) completes asset validation.

### Known limitation

Models whose authored VRM file already contains 32 or more collider groups cause augmentation to be skipped entirely, because the GPU-side group-bitmask is 32 bits and at least one slot must remain free for the synthetic group. Up to 31 authored groups are supported.

## Tuning

Spring parameters are interrelated, and that is the single biggest pitfall when adjusting them. Stiffness and drag together determine settling time; gravity scale shifts the rest pose every chain hangs from; hit radius interacts with collider placement. Changing one value on a model that has already been tuned will usually destabilize the others. Issue [#162](https://github.com/arkavo-org/VRMMetalKit/issues/162) tracks this.

When you do have to tune, work in the order **drag → stiffness → gravity**: damping first so chains stop ringing, then stiffness to set the response curve, and gravity last because it changes the equilibrium that the first two parameters were tuned against. Record the baseline values before you start so you can revert.

## Topics

### Spec types

- ``VRMSpringBone``
- ``VRMSpring``
- ``VRMSpringJoint``
- ``VRMCollider``
- ``VRMColliderShape``
- ``VRMColliderGroup``

### GPU layer

- ``SpringBoneBuffers``
- ``BoneParams``
- ``SphereCollider``
- ``CapsuleCollider``
- ``SpringBoneGlobalParams``

### Renderer controls

- ``VRMRenderer/applySpringBoneForce(gravity:wind:duration:)``
- ``VRMRenderer/resetSpringBone()``
