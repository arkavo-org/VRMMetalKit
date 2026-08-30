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

Most applications never touch the spring system at runtime: it is configured at load and stepped automatically. For transient effects — a wind gust, an impact, a jump landing — use ``VRMRenderer/applySpringBoneForce(gravity:wind:duration:)``. The `gravity` channel is an additive *external force* (VRMC_springBone-1.0 `model.ExternalForce`) layered on top of each joint's spec-scale `gravityDir · gravityPower`; it overrides the external force and/or wind for `duration` seconds and then restores the external force to zero and clears the wind amplitude. Either input can be `nil` to leave that channel untouched.

```swift
// Apply a 2-second wind gust while keeping default gravity.
renderer.applySpringBoneForce(
    gravity: nil,
    wind: simd_float3(2.5, 0, 0),
    duration: 2.0
)
```

``VRMRenderer/resetSpringBone()`` is provided as a stable entry point but is currently a no-op: the GPU pipeline reinitializes whenever a model is loaded.

On the async (shared command-buffer) path, a still chain sleeps after ``VRMRenderer/springBoneSleepDelayFrames`` consecutive frames under ``VRMRenderer/springBoneSleepThreshold`` (defaults 5 frames at 1 mm/s). Sleeping chains skip XPBD until a wake condition fires (root motion, a reachable collider moving, a global param change). The sync/offline path never sleeps, so conformance renders stay bit-deterministic. Set the threshold to `0` to pin the gate off for A/B; raise the delay to make settle slower. ``VRMRenderer/wakeAllBones()`` forces every chain awake on the next update.

## External and cross-avatar colliders

Two runtime paths let colliders that do not live in the VRM file deflect an avatar's hair and cloth. Both feed foreign, world-space shapes into the live simulation each frame, and both are independent second sources that compose with — rather than replace — the avatar's authored colliders.

``VRMRenderer/setExternalColliders(spheres:capsules:)`` injects arbitrary world-space props into the running simulation: a picked-up rigid body, an external physics rig, a level prop the avatar leans against. It takes the already-public ``SphereCollider`` and ``CapsuleCollider`` value types, expressed in world space. The call is replace-or-clear each frame — the supplied arrays become the entire external set for the next step, with no interpolation, so a moved prop snaps to its new pose and a removed prop leaves no ghost. Passing empty arrays clears the set; an empty external set is bit-identical to the authored-only simulation. When an external collider moves or first appears, a settled or sleeping avatar is woken so it responds. Colliders beyond the reserved external budget are clamped with a log rather than silently dropped. It works standalone with no contact group at all — a single avatar plus props needs nothing else.

The cross-avatar path, ``VRMRenderer/joinContactGroup(_:)`` / ``VRMRenderer/leaveContactGroup(_:)``, registers an avatar with a shared ``SpringBoneContactGroup`` coordinator so that avatars in a crowd deflect each other's secondary motion. The coordinator's `exchange()` publishes each member's body colliders into the group and hands every other member the crowd's world-space colliders for the frame; ``VRMRenderer/setContactResponseScale(_:in:)`` scales how strongly a given avatar reacts to that crowd contact.

External props and crowd contact are unioned into a dedicated reserved budget and both apply on the same frame: neither source clobbers the other, and either works with the other absent. A single avatar can therefore take on level props while also being jostled in a crowd, with both deflections composited into the one XPBD step.

## Procedural collider augmentation (#309)

VRM files rarely include colliders for every body part that animated geometry can reach, which leads to hair sinking into the forehead, skirt panels clipping through thighs, or sleeves passing through arms. To close the most common gaps, the loader can synthesize additional colliders at load time from bone positions and a stored head-radius estimate.

This behaviour is controlled by ``VRMLoadingOptions/augmentSpringBoneColliders`` (default `true`). The flag is purely additive: authored colliders are never mutated or removed. Set it to `false` to restore authored-only colliders — useful when A/B-testing a newly rigged model or bisecting a physics regression.

```swift
// Authored-only colliders — disable augmentation.
let options = VRMLoadingOptions(augmentSpringBoneColliders: false)
let model = try await VRMModel.load(from: url, device: device, options: options)
```

### What is synthesized

**Forward head/brow capsule.** A single capsule oriented along the forward axis of the head bone, sized from the model's stored head-reference radius. It closes the persistent front-hair-into-forehead clipping (#309 primary repro).

**Lateral skull sphere.** One midline sphere lifted toward the cranium, giving the head lateral coverage the brow capsule cannot reach (temple side-bang strands).

**End-to-end leg capsules.** One capsule per leg spanning from the upper-leg to the ankle joint. These substantially reduce skirt-panel-into-thigh clipping (peak penetration drops from roughly 23 mm to roughly 10 mm in the worst dynamic case and is never worse), though a single-frame transient can remain during fast leg swings.

**Lower-arm→hand capsules and palm spheres (#321).** Forearm capsules plus one sphere capping each palm, so a slow hand gesture into the chest ribbon, hair, or skirt collides instead of interpenetrating.

**Torso and upper-arm capsules.** One capsule over the spine→chest segment and one per upper arm, closing the hair-into-chest/breast and hair-into-upper-arm gap. Their radii floor at the model's own authored collider hints (an authored chest sphere still wins), so they hug the body rather than reading as an invisible forcefield.

### What is not addressed

Full-arm capsules for cloth sleeves were investigated and intentionally not shipped: they could not be validated as an improvement and worsened a stiff-sleeve "whip" artefact. The root cause is PBD without continuous collision detection (CCD) on fast cloth chains; when a joint tunnels through a collider in one substep the impulse overshoots, producing a visible snap. This is deferred. (Swept CCD does apply to all synthetic colliders above — the synthetic group is the swept group.)

### Collider group membership

Each collider carries the OR of every collider group's bit it belongs to (a 32-bit group mask), and a spring chain collides with any collider whose mask shares a bit with the chain's mask. A collider shared by several groups — a common authoring pattern, e.g. one chest capsule in both a "Body" and a "Hair" group — is therefore visible to springs referencing any of them.

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

### Cross-avatar & external collision

- ``VRMRenderer/setExternalColliders(spheres:capsules:)``
- ``VRMRenderer/joinContactGroup(_:)``
- ``VRMRenderer/leaveContactGroup(_:)``
- ``VRMRenderer/setContactResponseScale(_:in:)``
- ``SpringBoneContactGroup``
