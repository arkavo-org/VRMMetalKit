# Animation and Retargeting

Load VRMA clips, drive playback with ``AnimationPlayer``, and understand how rest-pose retargeting keeps a single clip portable across models.

## Overview

VRM Animation (`.vrma`) is a glTF-based clip format that stores humanoid joint
rotations, optional `Hips` translation, expression weights, and morph weights
as keyframe tracks. A clip references bones by their VRM humanoid role
(`hips`, `leftUpperArm`, …) rather than by node index, so the same file can
target any compliant skeleton.

The retargeting promise is simple: a clip authored against one VRM should
play cleanly on another VRM with the standard humanoid skeleton, regardless
of bone lengths or rest orientations. VRMMetalKit delivers this by combining
two independent rest poses at load time — see <doc:AnimationAndRetargeting#Retargeting-model>.

## Loading a clip

Use ``VRMAnimationLoader/loadVRMA(from:model:)`` to parse a `.vrma` file.
``VRMAnimationLoader`` is an enum-namespace (no instance), exposing a single
static entry point. Passing the target ``VRMModel`` lets the loader bake
rest-pose retargeting and VRM 0.x coordinate conversion into the resulting
``AnimationClip`` once, instead of paying that cost every frame.

## Playing the clip

``AnimationPlayer`` is a reference type marked `@unchecked Sendable`. It uses
an internal `NSLock` and cooperates with ``VRMModel``'s lock, so
``AnimationPlayer/update(deltaTime:model:)`` may be called from any thread —
typically your render loop's per-frame tick.

```swift
import VRMMetalKit

let model: VRMModel = /* loaded elsewhere */

// Load with retargeting baked against this model's rest pose.
let clip = try VRMAnimationLoader.loadVRMA(from: clipURL, model: model)

let player = AnimationPlayer()
player.load(clip)
player.isLooping = true
player.speed = 1.0
player.play()

// In your render loop, call once per frame with the elapsed seconds.
// Safe to call from any thread; the player cooperates with the model's lock.
let dt: Float = 1.0 / 60.0
player.update(deltaTime: dt, model: model)
```

Read ``AnimationPlayer/time``, ``AnimationPlayer/progress``, and
``AnimationPlayer/isFinished`` to drive UI or sequence transitions.

## Retargeting model

Animation rest pose and model rest pose are two independent, immutable
sources of truth. You cannot infer one from the other — the clip captures
how its author posed the source rig, while the model captures how its
T-pose was authored. For each humanoid joint with rotation track output
`animRotation`, VRMMetalKit computes:

```
delta = inverse(animRest) * animRotation
final = modelRest * delta
```

`delta` is the pure motion the animator intended (the offset from the clip's
own neutral). Pre-multiplying by `modelRest` re-anchors that motion onto the
target skeleton's neutral. This is why VRMA clips travel cleanly between
models with different rest orientations.

## Root motion and looping

`Hips` is the only humanoid bone where translation tracks are honored.
``AnimationPlayer/applyRootMotion`` defaults to `false`, which holds the
character in place; set it to `true` to let `Hips` translation drive the
root. ``AnimationPlayer/isLooping`` defaults to `true` (the clip wraps at
its duration), and ``AnimationPlayer/speed`` defaults to `1.0`. Scale tracks
and non-`Hips` translation tracks are intentionally ignored.

## Topics

### Loading

- ``VRMAnimationLoader``
- ``AnimationClip``

### Playback

- ``AnimationPlayer``

### Skinning and morphs

- ``VRMSkinningSystem``
- ``VRMMorphTargetSystem``

### Tracks

- ``JointTrack``
- ``MorphTrack``
- ``ExpressionTrack``
- ``NodeTrack``

### Related

- <doc:ARKitIntegration>
- <doc:MigratingFromVRM0>
