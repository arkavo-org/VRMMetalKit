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
