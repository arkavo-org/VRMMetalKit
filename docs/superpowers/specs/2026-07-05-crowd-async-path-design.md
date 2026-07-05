# Crowd Async-Path Support — Design (feature-complete subsystem 1 of 5)

**Date:** 2026-07-05
**Status:** Design approved.
**Scope:** Prove and expose cross-avatar spring-bone collision on the library's **asynchronous** render path — the path a live interactive app uses — so the feature works on *both* render paths, not just the offline synchronous demo.

**Program context:** This is subsystem 1 of the "feature-complete" program on `design/cross-avatar-collision`. The remaining subsystems (2: N>2 crowds, 3: authored-collider inclusion, 4: per-partner responses [needs a kernel change], 5: lockstep hug-convergence [rung 3]) get their own design→plan→build cycles. This one grounds the rest by establishing a working real-time base.

---

## 1. The gap

The crowd demo runs `config.synchronousSpringBone = true`: spring bones settle in their own committed command buffer, the sleep gate is **off** (every chain awake every frame), and there's no readback lag. That is *not* how a live app renders. A live app uses the **async path** (`config.synchronousSpringBone = false`): spring compute is piped into the renderer's shared command buffer, `writeBonesToNodes` consumes the *previous* frame's snapshot (one-frame lag), and the **sleep gate is live** — which is exactly where blocker **F1** applies (a settled avatar's sleeping chains must wake to a partner leaning in; fixed in `foreignCollidersChanged`). So multi-avatar cross-avatar contact on the async path is currently **unproven end-to-end**, and the `joinContactGroup` seam still carries the caveat "async multi-caller ordering unproven."

## 2. Why it already composes (verified)

`drawCore` encodes spring compute into the **passed** command buffer before its render encoder. In the crowd composite, `CrowdFrameStepper.drawComposite` passes **one shared command buffer** to all N avatars' `drawOffscreenHeadless`. So on the async path the encoders lay down sequentially:

```
[spring0][render0][spring1][render1] … [springN][renderN]   — all in one command buffer
```

No two encoders are ever active simultaneously (each closes before the next opens), so Metal's no-overlap rule holds. `CrowdFrameStepper.step()` still poses every avatar and calls `exchange()` **before** `drawComposite`, so the snapshot precedes every avatar's integrate-encode — the ordering invariant is preserved, with the accepted **(b) one-frame lag** (the rendered pose trails the spring sim by one frame). The loop commits+waits per frame, satisfying the shared-buffer frame-boundary sync the async spring path requires.

## 3. What changes

Minimal, because the machinery exists:

- **A `--realtime` CLI flag** on the crowd demo. When set, the crowd renderers are built with `config.synchronousSpringBone = false` instead of `true`; everything else (stepper, composite, motion, contact group) is unchanged.
- The behavioral differences that this *exercises for the first time* under multi-avatar contact: the **live sleep gate** (so F1 matters and is proven), and the **one-frame readback lag**.
- **Seam doc caveat lifted:** `VRMRenderer.joinContactGroup` doc changes from "async multi-caller ordering unproven" to "validated on the async multi-avatar path (see crowd async tests)."

No new types, no kernel changes, no ordering changes. This subsystem is a toggle plus the tests that make the async path a *proven* path.

## 4. Testing — the actual deliverable

The value is proof, not the flag. Three tests, all Metal-gated, driving the **async** spring path (`update(model:deltaTime:commandBuffer:<real cb>)`, sleep gate live):

1. **Async multi-avatar contact / F1 end-to-end.** Two avatars in a contact group on the async path. Settle avatar A to sleep (`sleepingBoneCount > 0`). Bring avatar B into contact (inject B's contact colliders via the coordinator, or drive B's approach). Assert A's chains **wake** (`sleepingBoneCount → 0`) **and its bones move** (deflect) — the end-to-end proof that a *settled* avatar reacts to an approaching partner on the real render path, not just the unit-level `foreignCollidersChanged` wake.
2. **Async ordering.** Within a frame, assert `exchange()`'s snapshot is taken from pre-integrate poses — i.e. every avatar's spring integrate on the shared buffer is encoded *after* `step()`/`exchange()` completes. Concretely: after `step()`, each system's `pendingForeignSnapshot` reflects the partner's *current* pose, and no integrate has run yet.
3. **Async composite renders both avatars.** The MSAA two-half assertion (non-clear pixels in both the left and right halves of the resolved frame) with the renderers on the async path (`synchronousSpringBone = false`), confirming the shared-command-buffer `[springi][renderi]` sequence composites all avatars correctly, not just the last.

## 5. Non-goals

- No change to the sync/offline demo path (still the default; deterministic for regression/video).
- No new ordering scheme (this is the accepted (b) one-frame-lag path; zero-lag rung-2/rung-3 convergence is subsystem 5).
- No windowed interactive app — the deliverable is *library async-path support proven and exposed*, which a real app consumes via the same `joinContactGroup` + `exchange()` pattern the crowd demo uses.

---

## 6. Feature-complete status + Lockstep (rung 3) escape hatch

The cross-avatar collision feature is **feature-complete** on this branch:

| Subsystem | Status |
|-----------|--------|
| 1. Async render-path support | ✅ built + proven (`CrowdAsyncPathTests`) |
| 2. N>2 crowds (nearest-K partners) | ✅ built (`CrowdNPlusTests`) |
| 3. Authored-collider inclusion | ✅ built (`CrowdAuthoredColliderTests`) |
| 4. Per-partner response scaling | ✅ built, shader change (`CrowdResponseScaleTests`) |
| 5. Lockstep hug-convergence (rung 3) | **deliberately NOT built — see below** |

### Lockstep — evaluated, deliberately not built

Lockstep (per-substep interleaved co-simulation: advance every avatar one substep, re-`exchange()` colliders, repeat) targets a **drag-damped anti-phase limit cycle** at sustained contact. It was evaluated and deliberately not built because in the current design it is **inert against that cycle — not globally inert** (this precision matters):

**Trigger 1 — the anti-phase cycle: structurally cannot form here.** A limit cycle needs a *closed feedback loop* (an avatar's spring state → its own contact colliders → the partner's springs → back). The contact set is **body colliders on humanoid bones, driven by animation, independent of the spring-bone state** (subsystem 3 explicitly filters *out* hair/accessory colliders). So the coupling is a dead-end (`A's body → B's hair`), never a loop — no cycle can form, and lockstep has nothing to converge. This trigger only appears **IF the contact set ever includes spring-bone-driven (dynamic) colliders** — e.g. a collider anchored to a hair/cloth bone — which would create the loop.

**Trigger 2 — approach staleness: real but bounded, and out-ranked.** During *fast relative body motion* (the approach, not the hold), the (b) one-frame / frozen-partner lag samples the partner's body trajectory coarsely, so contact *onset* can lag. Lockstep's finer per-substep re-sampling reduces this. But the effect is **bounded by the accepted snap-staleness argument** (staleness ∝ partner velocity, small in the contemplative register) and is **~zero at the sustained hold** (near-static bodies). A hold-focused test would measure ~zero and mislead into a "global no-op" overclaim; the regime where lockstep is non-zero is the *approach*.

**Fix ranking for approach staleness (if it ever reads wrong), cheapest first:**
1. **Slow the approach** — motion-driver tuning; the contemplative register already favors this.
2. **Tune compliance/drag** on the contact bones — damps onset overshoot.
3. **Lockstep (rung 3)** — the last resort: lift the substep loop into the coordinator and interleave advance/exchange per substep.

**Build lockstep only when** either trigger fires: (1) the contact set gains dynamic colliders (feedback loop becomes possible), or (2) the approach demonstrably reads wrong *after* the cheaper fixes above. Until then it is dead complexity by the reasoning above.
