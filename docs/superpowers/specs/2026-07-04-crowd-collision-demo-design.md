# Crowd Collision Demo — Design

**Date:** 2026-07-04
**Status:** Design ratified (all sections approved).
**Scope:** Make the cross-avatar spring-bone collision feature *visible*: a new `--crowd` mode in `VRMVideoRenderer` that renders multiple VRM avatars approaching and touching, with their hair/cloth spring bones visibly yielding to each other's bodies, output as a shareable `.mov`.

**Depends on:** the cross-avatar collision feature (`docs/superpowers/specs/2026-07-04-cross-avatar-collision-design.md`), whose `SpringBoneContactGroup` coordinator is built but dormant. This work wires it into a render loop for the first time.

---

## 1. Goal and framing

The collision feature ships opt-in and dormant — no code path drives two avatars into contact. This makes it visible: a scripted two-avatar (default) approach-and-part in an offline video, where one avatar's hair/skirt spring bones deflect off the other's body instead of clipping through. The deliverable is a `.mov` you can watch, plus a `--crowd-no-contact` toggle that renders the identical scene without the coordinator so the difference (deflect vs. clip) is provable side by side.

This is an **assembly of proven pieces**, not new machinery:
- `VRMBenchmark`'s render mode already composites N avatars into one shared color+depth texture via `drawOffscreenHeadless` (first avatar clears, rest `.load`), each avatar its own `VRMRenderer` + model + player + spring-bone system.
- `VRMVideoRenderer` already owns the offline pipeline: MSAA resolve texture → `CVPixelBuffer` → `AVAssetWriter` → `.mov`, with `config.synchronousSpringBone = true` and `--orbit`.
- `SpringBoneContactGroup` + `exchange()` already exist and are public/tested.

The genuinely new code is: the multi-avatar `--crowd` setup, one shared camera, a small public seam to join a contact group, a pure scripted motion driver, and the per-frame orchestration.

### Why offline/synchronous is the right surface

`VRMVideoRenderer` sets `config.synchronousSpringBone = true` (`VRMVideoRenderer/main.swift:387`). On the synchronous spring path the sleep gate is **off** (`sleepGateEnabled = commandBuffer != nil`; the sync path passes `commandBuffer: nil`), so every chain stays awake every frame. This **structurally sidesteps blocker F1** (the async sleep gate stranding settled chains) from the collision feature's final review — there is no settled-chain problem here. It also lets the single-threaded loop enforce a deterministic pose→snapshot→integrate ordering an async multi-renderer app could not guarantee (see §3).

---

## 2. Architecture and component boundary

A new `--crowd` code path in `VRMVideoRenderer/main.swift`, guarded so the existing single-avatar path is byte-for-byte untouched when `--crowd` is absent.

### 2.1 Components

- **Avatar instances (N, default 2).** Each is `{ model: VRMModel, renderer: VRMRenderer, player, sceneRoot }`, built exactly as `VRMBenchmark` does — one `VRMRenderer` per avatar, each loading its own independent instance of the passed VRM and playing the passed idle VRMA. `config.synchronousSpringBone = true` and `enableSpringBone = true` on every renderer.
- **One shared camera.** All N renderers render with the *same* `viewMatrix`/`projectionMatrix` so they compose into one coherent scene; `--orbit` drives this single shared camera. (Each `VRMRenderer` exposes `viewMatrix`/`projectionMatrix`; the loop sets identical values on all.)
- **`SpringBoneContactGroup` coordinator.** Created once; each avatar joins via the new public seam (§2.2). `exchange()` (already public) is called by the loop each frame at the ordering point in §3.
- **Motion driver.** A pure `position(at: frameTime) -> SIMD3<Float>` per avatar (§4). Position-only; facing is baked at placement.
- **Frame composite.** Loop avatars, `drawOffscreenHeadless` into the shared MSAA texture, then the existing `VRMVideoRenderer` resolve→pixelBuffer→AVAssetWriter path writes the frame. **Store-action contract (each avatar is a *separate* render pass into one MSAA target):** the first avatar clears color+depth; **intermediate passes must `storeAction = .store` on both color and depth** so the next pass's `.load` sees real content (correct occlusion) — a bare `.load` after a resolving/`.dontCare` pass reads undefined memory; **only the final pass uses `.multisampleResolve`** (color) into the resolve texture. The benchmark's simpler "first-clears/rest-load" works only because it renders into a *single-sample* target with no resolve; the MSAA video path requires the explicit intermediate `.store`.
- **`CrowdFrameStepper` (orchestration unit).** A headless, testable unit owning the per-frame Phase 0→1→2 sequence (pose all → `exchange()`), so the video glue (Phase 3 draw + encode) stays a thin shell. Tests drive the stepper without the video pipeline.

### 2.2 The public seam — `VRMRenderer.joinContactGroup(_:)`

The only new module-level API. `SpringBoneComputeSystem` (the per-model simulation-state container) stays **internal** — publicizing it would expose exactly the per-model sim-state (`chainSleepState`, interpolation mirror, CPU bone mirror) the collision design's §2.1 review-gate invariant depends on the coordinator *not* holding. The seam enforces that boundary structurally: the app can't reach the system type to hand the coordinator any sim-state, so the coordinator's "holds no per-model sim-state" invariant is "structurally can't," not "conventionally doesn't."

```swift
// On VRMRenderer:
public func joinContactGroup(_ group: SpringBoneContactGroup)   // group.add(system: springBoneComputeSystem, model: model)
public func leaveContactGroup(_ group: SpringBoneContactGroup)  // group.remove(system:)
```

Callable **after `loadModel`** (the spring-bone system is created there). The app calls `group.exchange()` directly (already public) at the §3 ordering point.

**Seam validation scope (shipped-vs-proven honesty).** This executable is the *first and only* caller of the seam, exercising exactly one usage pattern: offline, synchronous, scripted, single-caller. The seam's doc contract states verbatim: **"validated against offline-synchronous single-caller; real-time / async multi-caller ordering is unproven."** A future real-time app-facing caller may need `exchange()` to interleave differently (async commits, variable participant counts mid-session) — that is the deliberately-deferred rung-2/3 async ordering, and it must not be assumed covered by this seam's tested surface. Do not over-build for it now (YAGNI).

---

## 3. Per-frame ordering contract (load-bearing)

The offline single-threaded loop lets us pose every avatar for the current frame *before any spring integrate*, achieving zero-lag start-of-frame mutual resolution — the collision design's (a) ideal, better than the (b) one-frame lag an async app is stuck with.

Verified code facts that make this expressible:
- `player.update(deltaTime:model:)` applies animation to bones **and calls `model.updateNodeTransforms()` internally** (`AnimationPlayer.swift`; drawCore's own comment confirms it).
- `drawCore` (via `drawOffscreenHeadless`) does **not** re-derive transforms from animation at its top (no `updateNodeTransforms` before the spring block at `VRMRenderer.swift:1581`); it reads world matrices as they are on entry, integrates, and only calls `updateNodeTransforms` *after* spring integrate. So the render entry point cannot invert the snapshot→render ordering.

Per-frame sequence:

```
# Phase 0 — pose every avatar for THIS frame (anim + scripted motion), fully committed:
for each avatar:
    player.update(dt, model)                        # idle VRMA on bones + internal updateNodeTransforms
    pos = motionDriver.position(at: frameTime)      # scripted approach-and-part
    for sceneRoot in model.nodes where sceneRoot.parent == nil:   # a VRM may have >1 root; offset all, like VRMBenchmark
        sceneRoot.translation = basePlacement[avatar] + pos       # placement (facing baked) + scripted motion
    model.updateNodeTransforms()                    # propagate root motion into world matrices

# Phase 1+2 — snapshot all, inject union-minus-self (reads the fresh committed poses):
contactGroup.exchange()

# Phase 3 — render each into the shared frame; each drawCore runs its own synchronous spring
#           integrate, now seeing the foreign colliders exchange() injected:
for idx, avatar in avatars:
    rpd.colorAttachments[0].loadAction = (idx == 0) ? .clear : .load
    rpd.depthAttachment.loadAction     = (idx == 0) ? .clear : .load
    avatar.renderer.drawOffscreenHeadless(to: sharedMSAAColor, depth: sharedMSAADepth,
                                          commandBuffer: cb, renderPassDescriptor: rpd)
cb.commit(); wait; copy resolveTexture → pixelBuffer → AVAssetWriter.append
```

Two invariants this order guarantees (both test-checked, §5):
1. **Every Phase-1 snapshot reads a post-motion, post-transform pose** — no motion lag stacked on the physics lag.
2. **All snapshots complete before any integrate** — avatar A integrating (Phase 3, first) cannot perturb the pose B already snapshotted, giving symmetric same-frame mutual resolution.

The translation targets every `parent == nil` node (a VRM may have more than one scene root) — the same nodes `VRMBenchmark` offsets for placement, which animation (targeting humanoid bones) never touches, so motion and animation compose without fighting. Facing yaw is baked into `basePlacement` at setup (§4.1); the driver contributes only the scripted translation `pos`.

---

## 4. Motion driver, placement, and CLI

### 4.1 Placement (bakes facing)

Two avatars (default) on the X axis, pre-rotated to face each other along the line between them: avatar 0 at `-startSep/2` facing +X, avatar 1 at `+startSep/2` facing −X. Facing is a fixed yaw set **once at setup** on the scene-root node; the driver never touches rotation. This designs out the shoulder-to-shoulder failure mode (translating +Z-facing avatars toward each other on X would hug them side-by-side, not chest-to-chest) rather than discovering it in the first render.

`N > 2` is a documented stretch (avatars ring around a center facing inward); v1 targets and tests N=2.

### 4.2 Motion driver (pure, position-only)

`position(at: t) -> SIMD3<Float>` per avatar, along each avatar's facing axis:
- `t < approachStart`: hold at `startSep` (contact sets provably disjoint — clean t=0).
- approach window: smoothstep-eased lerp inward from `startSep` to `holdSep`.
- hold window: rest at `holdSep` (sustained contact — the beat the hug reads in).
- part window: smoothstep-eased lerp back out.

Pure value logic; no Metal, no side effects. Facing baked at placement means the returned `SIMD3<Float>` is a translation along the pre-set facing axis.

### 4.3 The coupled pair (calibration)

`holdSep` and the torso capsule radius (`SpringBoneContactColliderSet.torsoRadiusFractionOfLength`, the untuned §5.3 geometry from the collision feature) are **not independent**. Together they decide whether the torso capsules *just* touch (contemplative yield) or interpenetrate (mannequin-clip). The spike calibrates the **pair**: pick `holdSep` so the two torso capsules' surfaces meet at roughly their combined radii, then nudge radius and hold together against the render. Getting one right with the other wrong reads identically to getting both wrong. Both are CLI-exposed so calibration never needs a rebuild.

### 4.4 CLI flags (all additive; single-avatar path untouched when `--crowd` absent)

- `--crowd` — enable the mode.
- `--avatar-count N` (default 2).
- `--crowd-start-sep M` — start separation (meters).
- `--crowd-hold-sep M` — hold separation (the tunable half of the coupled pair).
- `--crowd-no-contact` — render the identical scene *without* joining the contact group (before/after proof, and a visual regression baseline).
- Reuses existing `--orbit`, `--fps`, `--duration`, `--width/--height`, MSAA, codec flags.

The model + idle VRMA come from the existing positional args; the one model is loaded into N independent instances (each its own renderer/system), all playing that idle animation.

---

## 5. Testing

All logic is pushed out of the (pixel-untestable) video glue into testable units; the `AVAssetWriter` shell stays thin.

- **Motion driver — pure unit tests.** Assert `position(at:)` holds at `startSep` before approach, reaches `holdSep` at the hold window, is monotonic inward during approach and outward during part, and is symmetric for the two avatars. No Metal.
- **Placement invariants — headless via `contactColliderSnapshot`.** Assert the two avatars' contact sets are **disjoint at t=0** (the §4.3 precondition) and **overlapping at the hold window** (something to collide). Snapshot API only; no rendering.
- **Crowd-step ordering / union-minus-self — headless integration.** Drive `CrowdFrameStepper` Phase 0→1→2 for two overlapping avatars; assert A's injected foreign set contains B's contact colliders and not its own (`activeForeignCapsules > 0`; injected geometry matches B's snapshot). Reuses the collision Task 6 test pattern.
- **`--crowd-no-contact` parity — crowd-level non-interference.** Two avatars rendered without joining the group produce bit-identical spring trajectories to each avatar run solo — the collision §8.1 gate lifted to the crowd path, proving the crowd harness itself perturbs nothing when contact is off.
- **CLI smoke test (Metal-gated).** Render a short `--crowd` clip to a temp `.mov`; assert the file exists and is non-empty. End-to-end pipeline check, no pixel assertions. Skips without a Metal device.

**Manual/visual acceptance** (the "does it look right"): render the **contact vs `--crowd-no-contact` comparison** on an avatar with prominent hair/skirt — hair deflecting off the partner's torso with contact on, clipping through with it off. That comparison clip is the acceptance artifact and the calibration surface for the coupled `holdSep`/radius pair. Produced as part of finishing the work; stills shared.

---

## 6. Out of scope / deferred

- **N > 2 crowds** beyond the documented ring stretch — v1 is N=2.
- **Real-time / async wiring** of the seam — the seam ships validated for offline-synchronous single-caller only (§2.2); async multi-caller ordering is the collision design's deferred rung-2/3 work.
- **The collision feature's own deferred items** (convergence rungs, authored-collider inclusion) — untouched here. **F1 (async sleep-gate wake) is now FIXED** (`detectWakeConditions` wakes chains on a changed/moving foreign-collider set — `SpringBoneComputeSystem.foreignCollidersChanged`), so a settled avatar reacts to a partner leaning in on the async render path; the offline demo never needed it (sleep gate off). Real-time wiring of the coordinator into an async render loop is now unblocked by F1.
- **Multiple *different* models in one crowd** — v1 replicates one passed model into N instances. Distinct per-avatar models is a trivial later extension (load a list) but not a v1 requirement.
