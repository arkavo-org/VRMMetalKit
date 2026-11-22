# Performance Roadmap

Engineering tracking doc for the prioritized performance work captured in the
**[Romero-style perf review epic — #200][epic]**. Each row links to a focused
issue. This file is an index, not a spec — design and implementation detail
live on each issue.

[epic]: https://github.com/arkavo-org/VRMMetalKit/issues/200

## Prerequisite

| Issue | Title | Status |
|-------|-------|--------|
| [#156](https://github.com/arkavo-org/VRMMetalKit/issues/156) | Benchmark CI regression gate — **must land first** | ✅ landed (PR #344) |

Romero / Carmack rule: never optimise anything you haven't measured. Every
optimisation below claims an impact; none of those claims are verifiable
until #156 produces a baseline.

The gate is now in place: `VRMBenchmark` plus `make bench-baseline` / `make
bench-gate` run on a **fixed performance machine** (hosted-runner numbers vary
too much to gate on), comparing against `baselines/baseline.json` committed from
that machine. The CI `Bench` workflow runs the same benchmark but its comparison
is **advisory only**.

## Optimisations (priority order)

| # | Area | Issue | Status | Notes |
|---|------|-------|--------|-------|
| 1 | Baselines | [#156](https://github.com/arkavo-org/VRMMetalKit/issues/156) | ✅ landed (PR #344) | prerequisite |
| 2 | Outline pass merge (tile memory / instanced draws) | [#192](https://github.com/arkavo-org/VRMMetalKit/issues/192) | open | alternative to [#88](https://github.com/arkavo-org/VRMMetalKit/issues/88) (ICBs) — pick one |
| 3 | SpringBone sleep gate | [#149](https://github.com/arkavo-org/VRMMetalKit/issues/149) | ✅ landed (PR #344) | |
| 4 | MToon shader specialisation via `[[function_constant]]` | [#193](https://github.com/arkavo-org/VRMMetalKit/issues/193) | ✅ landed (PR #344) | |
| 5 | Mask-dispatch morph targets | [#194](https://github.com/arkavo-org/VRMMetalKit/issues/194) | ✅ landed (PR #344) | orthogonal to [#150](https://github.com/arkavo-org/VRMMetalKit/issues/150) |
| 6 | Vertex layout: position-only + attribute split | [#195](https://github.com/arkavo-org/VRMMetalKit/issues/195) | ✅ done (opt-in) | shipped as `RendererConfig.enableDepthPrepass` (default off): position-only depth prepass + shared `vrm_skin` helper. **Measured neutral for a single avatar** (overdraw too low); kept as opt-in infra for high-overdraw/crowd scenes. Pixel-identical verified |
| 7 | Half-precision MToon fragment math | [#196](https://github.com/arkavo-org/VRMMetalKit/issues/196) | ✅ done (close issue) | shipped: shaders build with `-DMTOON_USE_HALF_PRECISION=1`, so both texture returns *and* lighting intermediates (`mtoon_float`) are `half`; verified the committed metallib is the half build |
| 8 | Tile-memory pass merge | folded into [#192](https://github.com/arkavo-org/VRMMetalKit/issues/192) | open | |
| 9 | MPS-backed Kalman face smoothing | [#198](https://github.com/arkavo-org/VRMMetalKit/issues/198) | wontfix | measured net-negative: ~52–280 B/frame, ~15 µs CPU; a GPU roundtrip matches/exceeds it and there is no `MTLDevice` in the face driver |
| 10 | Dual-quaternion joint palette | [#197](https://github.com/arkavo-org/VRMMetalKit/issues/197) | open | |
| + | GPU occlusion queries for crowd avatars | [#199](https://github.com/arkavo-org/VRMMetalKit/issues/199) | open | extends [#91](https://github.com/arkavo-org/VRMMetalKit/issues/91) / [#154](https://github.com/arkavo-org/VRMMetalKit/issues/154) |

## Loading-pipeline wins (not yet filed)

Orthogonal to the render-path items above; surfaced by the load-time review.
**All three landed** — measured ~49% load-time reduction (144 ms → 73 ms, max
preset, `AvatarSample_A_1.0` via `VRMBenchmark --mode load`):

- ✅ Parallel primitive decoding *within* each mesh (was per-mesh only).
- ✅ Pre-sized accessor decode arrays (`reserveCapacity` before the decode loop).
- ✅ Coalesced `MainActor` progress callbacks (≤~20 hops instead of per-item).

## Why this lives in the repo as well as in issues

GitHub issues are the source of truth; this file is a stable, code-adjacent
index so contributors browsing `docs/` find the roadmap alongside
[`PERFORMANCE_REPORT.md`](PERFORMANCE_REPORT.md) and
[`PERFORMANCE_OPTIMIZATION_GUIDE.md`](PERFORMANCE_OPTIMIZATION_GUIDE.md).
Update the table whenever issues close or new ones are filed.

## Cultural commitments the source review called out

- Every PR runs against a fixed reference scene (`AvatarSample_A_1.0.vrm.glb`).
- No performance regression merges without explicit sign-off.
- Publish a frame-time budget and defend it.

## Hotspot instrumentation (how a change is judged)

Total frame time is too noisy to attribute to any one stage on a single avatar,
so the renderer emits per-stage CPU phases through `PerformanceTracker`, and
`VRMBenchmark` persists each as a distribution under `BenchmarkReport.stats`.
Run `make bench-hotspots` before and after a change and diff the JSON; the phase
key for the code you touched is the signal, not the total.

| Phase key | What it times |
|-----------|----------------|
| `transformUpdate` | Node world-transform propagation (pre-draw and post-physics walks). |
| `skinPalette` | Per-skin dirty check and joint-palette rebuild. |
| `morphSetup` | Whole morph compute pass; `morphActiveSet` isolates per-primitive active-set build. |
| `springBone` | Whole spring step; `springTargetCapture` (per-frame target/collider capture), `springSubsteps` (XPBD loop), `springReadback` (GPU positions → node writeback) isolate its stages. |
| `renderItemBuild` | Render-item build, culling and sort. |
| `depthPrepass` / `outlinePass` | The optional depth prepass and the inverted-hull outline pass. |

Each phase is one sample per frame: a phase the renderer begins several times
in a frame (`transformUpdate` walks twice with spring bone on, `morphActiveSet`
runs once per primitive) is summed, so the percentiles compare frames, not calls.

`make bench-hotspots` amplifies each stage by combining animation with ultra
spring physics on a single avatar (the tracker is attached to one renderer, so
extra avatars would not reach the per-phase samples). The spring phases only
do real work with `--fixed-step`: the benchmark loop is unpaced, so without it
the renderer's wall-clock delta is near zero, the XPBD loop runs no substeps
and `springReadback` samples on a handful of frames (probe rows in the table
below); `BENCH_HOTSPOT_ARGS` does not yet pass the flag. `bench-gate` intersects
common phase keys against `baselines/baseline.json`, so re-recording the
baseline gates the phases its `BENCH_ARGS` exercise — `transformUpdate`,
`skinPalette`, `morphSetup`, `renderItemBuild`, `outlinePass` and
`commandEncode`. The spring phases (`springBone`, `springTargetCapture`,
`springSubsteps`, `springReadback`) and `depthPrepass` emit no samples without
`--spring-bone` / `--depth-prepass`, so they stay out of the baseline until
those flags are added to `BENCH_ARGS` in the Makefile and the baseline is
re-recorded on the perf machine. `morphActiveSet` only runs when expression
weights change between frames (the morph gate reuses the previous output
otherwise), and `VRMBenchmark` drives no expressions, so gating it needs a new
benchmark option first. `PerformanceTrackerTests` pins the phase→metric
mapping so a new phase cannot silently miss the report.

## Measured: PR #437 hotspot commits

Evidence for the two perf claims in this PR's commit messages, taken with the
instrumentation above. Environment: Apple M4 Max, macOS 26.6.2. VRMMetalKit
source at `caf4ee5`; benchmark binary built at `ab9aa7c` (adds `--fixed-step`).
Model `AvatarSample_U_1.0.vrm.glb` (more spring chains than the reference
scene `AvatarSample_A_1.0`). Invocation per run:

```
VRMBenchmark AvatarSample_U_1.0.vrm.glb --mode render --frames 1000 --warmup 30 \
  --vrma VRMA_01.vrma --spring-bone --spring-bone-quality ultra --fixed-step --json <out>
```

`--fixed-step` matters: without it the unpaced loop hands spring bone a
near-zero wall-clock delta, the XPBD loop runs no substeps and `springReadback`
only samples on the few frames where a GPU frame happens to complete (see the
probe row). The phase percentiles cover the last 600 measured frames (the
tracker's ring buffer); `cpuBudget` covers all 1000. Warmup frames are in
neither.

Configurations, all built from the same tree:

- **A** — `caf4ee5` as-is.
- **B** — A with 759a1c6's `localMatrixDirty` guard removed, so
  `updateWorldTransform()` rebuilds every node's local matrix on every walk
  (the only behavioural difference of that commit).
- **C** — A with 789bfe5's readback-copy hunk reverted: `writeBonesToNodes`
  takes `let positions = latestPositionsSnapshot` under the lock again instead
  of the unconditional copy into `writebackPositions`. The tracker phases and
  the splat hoist from that commit are retained so C emits the same phases.

Runs were interleaved A/B/A/B/A/B and then A/C/A/C/A/C (the A rows are
reported per pair because the pairing is the control). "Median" is the median
of the three run medians, "p95" the median of the three run p95s. **All runs
were concurrent with another `swift test` job on the same machine**, so
absolute numbers are inflated and the min/max spread is the noise floor.

| Pair | Config | Phase | Median ms | p95 ms | Run medians min / max | vs A | Samples per run |
|------|--------|-------|-----------|--------|-----------------------|------|-----------------|
| AB | A | `transformUpdate` | 0.0608 | 0.0698 | 0.0607 / 0.0608 | — | 600 x3 runs |
| AB | A | `cpuBudget` | 0.3036 | 0.3314 | 0.3022 / 0.3038 | — | 1000 x3 runs |
| AB | A | `springBone` | 0.1235 | 0.1435 | 0.1235 / 0.1236 | — | 600 x3 runs |
| AB | A | `springReadback` | 0.0564 | 0.0640 | 0.0563 / 0.0565 | — | 600 x3 runs |
| AB | A | `springSubsteps` | 0.0058 | 0.0065 | 0.0058 / 0.0058 | — | 600 x3 runs |
| AB | A | `springTargetCapture` | 0.0280 | 0.0312 | 0.0280 / 0.0280 | — | 600 x3 runs |
| AB | B | `transformUpdate` | 0.0771 | 0.0942 | 0.0762 / 0.0842 | +26.8% | 600 x3 runs |
| AB | B | `cpuBudget` | 0.3469 | 0.3829 | 0.3454 / 0.3636 | +14.2% | 1000 x3 runs |
| AB | B | `springBone` | 0.1497 | 0.1795 | 0.1476 / 0.1602 | +21.2% | 600 x3 runs |
| AB | B | `springReadback` | 0.0738 | 0.0887 | 0.0729 / 0.0777 | +30.8% | 600 x3 runs |
| AB | B | `springSubsteps` | 0.0060 | 0.0070 | 0.0059 / 0.0064 | +2.9% | 600 x3 runs |
| AB | B | `springTargetCapture` | 0.0281 | 0.0318 | 0.0278 / 0.0296 | +0.4% | 600 x3 runs |
| AC | A | `transformUpdate` | 0.0610 | 0.0690 | 0.0608 / 0.0630 | — | 600 x3 runs |
| AC | A | `cpuBudget` | 0.3044 | 0.3362 | 0.3017 / 0.3073 | — | 1000 x3 runs |
| AC | A | `springBone` | 0.1236 | 0.1447 | 0.1232 / 0.1243 | — | 600 x3 runs |
| AC | A | `springReadback` | 0.0563 | 0.0641 | 0.0563 / 0.0564 | — | 600 x3 runs |
| AC | A | `springSubsteps` | 0.0058 | 0.0067 | 0.0058 / 0.0060 | — | 600 x3 runs |
| AC | A | `springTargetCapture` | 0.0280 | 0.0316 | 0.0280 / 0.0283 | — | 600 x3 runs |
| AC | C | `transformUpdate` | 0.0612 | 0.0695 | 0.0609 / 0.0680 | +0.2% | 600 x3 runs |
| AC | C | `cpuBudget` | 0.3064 | 0.3375 | 0.3034 / 0.3221 | +0.6% | 1000 x3 runs |
| AC | C | `springBone` | 0.1232 | 0.1450 | 0.1228 / 0.1365 | -0.3% | 600 x3 runs |
| AC | C | `springReadback` | 0.0561 | 0.0653 | 0.0560 / 0.0623 | -0.3% | 600 x3 runs |
| AC | C | `springSubsteps` | 0.0059 | 0.0065 | 0.0058 / 0.0065 | +0.7% | 600 x3 runs |
| AC | C | `springTargetCapture` | 0.0281 | 0.0313 | 0.0281 / 0.0307 | +0.4% | 600 x3 runs |
| probe | A, no `--fixed-step`, 100 frames | `springReadback` | 0.0577 | 0.0584 | single run | — | 7 x1 run |
| probe | A, no `--fixed-step`, 100 frames | `springSubsteps` | 0.0001 | 0.0040 | single run | — | 100 x1 run |

**Claim (a), 759a1c6 dirty-flag skip of local-matrix rebuilds:** supported —
`transformUpdate` and `cpuBudget` are lower in A than B in every interleaved
pair with no overlap between the A and B run-median ranges; `springReadback`
and `springBone` move with it because `writeBonesToNodes` calls
`updateLocalMatrix()` + `updateWorldTransform()` per chain node, which in B
rebuilds those subtrees a second time. The commit message's original figure
was a `cpuBudget` median from an unnamed machine and is superseded by the
table; the effect on this model is likely larger because U has more nodes and
spring bone adds a second walk per frame.

**Claim (b), 789bfe5 readback-buffer reuse:** not supported as a measurable
win — every A-vs-C delta is within one percent, smaller than the spread of C's
own run medians, so the unconditional copy under `snapshotLock` is neutral on
the render thread. The completion handler updates `latestPositionsSnapshot`
in place (`withUnsafeMutableBufferPointer`), so the old second reference only
forced a COW copy while it was alive during that write — a race window on the
completion thread that no per-frame phase can observe. `springReadback` begins
after the lock in both A and C, so `springBone` is the discriminating phase.
The commit stands on its hoist and instrumentation, not on the copy.

## Measured: CPU hot-path, SpringBone, command-encode & loading optimizations (`1130e8c`+)

Interleaved A/B/A/B/A/B release measurements on an idle Apple M4 Max (128 GB,
macOS 27.2.1, Swift 6.4.2). **A** is `main` (`1130e8c`); **B** adds:
- Lazy `VRMNode.normalMatrix` caching, direct TRS `updateLocalMatrix()`, and
  non-recursive `updateWorldTransformShallow()` for $O(L)$ SpringBone chain
  writeback (eliminating double `updateLocalMatrix()`, $O(L^2)$ subtree walks,
  and the redundant post-spring full-skeleton `model.updateNodeTransforms()`).
- Pre-resolved flat SpringBone capture caches (`cachedRootNodes`,
  `cachedBindDirEntries`, `cachedColliderGroupMasks`, `cachedColliderNodes`,
  `cachedSyntheticColliderNodes`, and precomputed static `boneInitialAxes`,
  reading live `collider.shape` per frame) and zero-allocation sleep/wake
  tracking with bitmask-OR collider matching (`SpringBoneSleepGate`).
- `VRMRenderer` `commandEncode` cleanup: `EncoderStateCache` vertex-texture
  dedup, shared `uniformsBuffer` binding for skinned draws (avoiding per-draw
  496-byte `setVertexBytes`), hoisted frame constants (`vertexOffset`,
  `lightCount`, `usesDebugFragment`), `hasMorphedPositionsFlag` dedup,
  precomputed `RenderItem` flags/cull mode, and single-pass `MToonMaterialUniforms`
  initialization.
- Zero-copy top-8 `VRMMorphTargetSystem.buildActiveSet` (eliminates
  `Array(ArraySlice)` copy and $O(m \log m)$ sort).
- Zero-allocation parallel `TextureBlockCompressor` (BC7 Mode 6), specialized
  parallel even-2×2 `TextureMipUploader`, memory-mapped GLB reads, and zero-copy
  chunk/bufferView slices.

### Render CPU hotspots (1000 frames, animated + ultra spring + `--fixed-step`)

| Model | Phase | A median ms | A p95 ms | A min/max | B median ms | B p95 ms | B min/max | Delta |
|-------|-------|-------------|----------|-----------|-------------|----------|-----------|-------|
| `AvatarSample_A_1.0` | `cpuBudget` | 0.1360 | 0.1517 | 0.1352 / 0.1363 | 0.1027 | 0.1171 | 0.1023 / 0.1035 | **-24.5%** |
| `AvatarSample_A_1.0` | `encode` | 0.1049 | 0.1200 | 0.1042 / 0.1050 | 0.0743 | 0.0886 | 0.0740 / 0.0749 | **-29.2%** |
| `AvatarSample_A_1.0` | `transformUpdate` | 0.0128 | 0.0146 | 0.0128 / 0.0129 | 0.0066 | 0.0082 | 0.0065 / 0.0066 | **-48.7%** |
| `AvatarSample_A_1.0` | `springBone` | 0.0301 | 0.0359 | 0.0301 / 0.0302 | 0.0170 | 0.0197 | 0.0170 / 0.0171 | **-43.4%** |
| `AvatarSample_A_1.0` | `springTargetCapture` | 0.0070 | 0.0077 | 0.0070 / 0.0071 | 0.0036 | 0.0041 | 0.0035 / 0.0036 | **-49.1%** |
| `AvatarSample_A_1.0` | `springReadback` | 0.0093 | 0.0098 | 0.0093 / 0.0094 | 0.0061 | 0.0063 | 0.0060 / 0.0061 | **-34.5%** |
| `AvatarSample_A_1.0` | `commandEncode` | 0.0579 | 0.0716 | 0.0575 / 0.0582 | 0.0403 | 0.0490 | 0.0397 / 0.0403 | **-30.5%** |
| `AvatarSample_A_1.0` | `animation` | 0.0310 | 0.0328 | 0.0309 / 0.0313 | 0.0285 | 0.0306 | 0.0281 / 0.0285 | **-8.1%** |
| `AvatarSample_U_1.0` | `cpuBudget` | 0.2721 | 0.2935 | 0.2720 / 0.2723 | 0.1864 | 0.2053 | 0.1863 / 0.1868 | **-31.5%** |
| `AvatarSample_U_1.0` | `encode` | 0.2197 | 0.2390 | 0.2195 / 0.2200 | 0.1412 | 0.1582 | 0.1411 / 0.1412 | **-35.7%** |
| `AvatarSample_U_1.0` | `transformUpdate` | 0.0440 | 0.0514 | 0.0437 / 0.0444 | 0.0221 | 0.0255 | 0.0220 / 0.0221 | **-49.9%** |
| `AvatarSample_U_1.0` | `springBone` | 0.1070 | 0.1217 | 0.1068 / 0.1075 | 0.0543 | 0.0683 | 0.0543 / 0.0543 | **-49.2%** |
| `AvatarSample_U_1.0` | `springTargetCapture` | 0.0258 | 0.0284 | 0.0256 / 0.0258 | 0.0123 | 0.0130 | 0.0121 / 0.0124 | **-52.2%** |
| `AvatarSample_U_1.0` | `springReadback` | 0.0491 | 0.0585 | 0.0491 / 0.0496 | 0.0325 | 0.0440 | 0.0324 / 0.0329 | **-33.8%** |
| `AvatarSample_U_1.0` | `commandEncode` | 0.0774 | 0.0920 | 0.0768 / 0.0778 | 0.0516 | 0.0656 | 0.0515 / 0.0519 | **-33.3%** |
| `AvatarSample_U_1.0` | `animation` | 0.0520 | 0.0591 | 0.0519 / 0.0525 | 0.0452 | 0.0531 | 0.0449 / 0.0454 | **-13.2%** |

### visionOS stereo & multi-avatar scaling

| Scenario | Metric | A median ms (min/max) | B median ms (min/max) | Delta |
|----------|--------|-----------------------|-----------------------|-------|
| visionOS stereo preferred (`AvatarSample_U`, 90 Hz) | `cpuBudget` | 0.4051 (0.3893 / 0.4070) | 0.2701 (0.2701 / 0.2767) | **-33.3%** |
| visionOS stereo preferred (`AvatarSample_U`, 90 Hz) | `encode` | 0.3466 (0.3320 / 0.3497) | 0.2157 (0.2106 / 0.2234) | **-37.8%** |
| 5-avatar crowd (`AvatarSample_A`, ultra spring) | `cpuBudget` | 0.6670 (0.6626 / 0.7306) | 0.4928 (0.4880 / 0.5097) | **-26.1%** |
| 5-avatar crowd (`AvatarSample_A`, ultra spring) | `encode` | 0.5193 (0.5174 / 0.5774) | 0.3556 (0.3513 / 0.3727) | **-31.5%** |

### Load latency & peak RSS (`--mode load --frames 5`, `/usr/bin/time -l`)

| Model / Preset | A median ms (min/max) | B median ms (min/max) | Load Δ | A Peak RSS | B Peak RSS | RSS Δ |
|----------------|-----------------------|-----------------------|--------|------------|------------|-------|
| `AvatarSample_A` (`default`) | 169.9 (169.7 / 170.7) | 169.6 (169.5 / 169.7) | -0.2% | 381.4 MiB | 361.5 MiB | **-5.2%** |
| `AvatarSample_A` (`max`, BC7) | 632.6 (624.7 / 633.4) | 175.0 (174.4 / 176.0) | **-72.3%** | 399.9 MiB | 313.0 MiB | **-21.7%** |
| `AvatarSample_U` (`default`) | 194.5 (194.2 / 196.4) | 195.2 (194.6 / 196.0) | +0.4% | 551.0 MiB | 530.7 MiB | **-3.7%** |
| `AvatarSample_U` (`max`, BC7) | 1059.0 (1054.3 / 1063.6) | 200.7 (200.7 / 201.1) | **-81.0%** | 504.3 MiB | 420.0 MiB | **-16.7%** |
| `AvatarSample_A` (mipmapped `9987`) | 212.0 (210.6 / 217.2) | 192.2 (185.6 / 192.5) | **-9.4%** | — | — | — |
