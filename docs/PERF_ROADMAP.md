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
| 6 | Vertex layout: position-only + attribute split | [#195](https://github.com/arkavo-org/VRMMetalKit/issues/195) | open | |
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
