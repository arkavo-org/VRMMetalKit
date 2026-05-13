# Performance Roadmap

Engineering tracking doc for the prioritized performance work captured in the
**[Romero-style perf review epic — #200][epic]**. Each row links to a focused
issue. This file is an index, not a spec — design and implementation detail
live on each issue.

[epic]: https://github.com/arkavo-org/VRMMetalKit/issues/200

## Prerequisite

| Issue | Title |
|-------|-------|
| [#156](https://github.com/arkavo-org/VRMMetalKit/issues/156) | Benchmark CI regression gate — **must land first** |

Romero / Carmack rule: never optimise anything you haven't measured. Every
optimisation below claims an impact; none of those claims are verifiable
until #156 produces a baseline.

## Optimisations (priority order)

| # | Area | Issue | Notes |
|---|------|-------|-------|
| 1 | Baselines | [#156](https://github.com/arkavo-org/VRMMetalKit/issues/156) | prerequisite, already filed |
| 2 | Outline pass merge (tile memory / instanced draws) | [#192](https://github.com/arkavo-org/VRMMetalKit/issues/192) | alternative to [#88](https://github.com/arkavo-org/VRMMetalKit/issues/88) (ICBs) — pick one |
| 3 | SpringBone sleep gate | [#149](https://github.com/arkavo-org/VRMMetalKit/issues/149) | already filed |
| 4 | MToon shader specialisation via `[[function_constant]]` | [#193](https://github.com/arkavo-org/VRMMetalKit/issues/193) | |
| 5 | Mask-dispatch morph targets | [#194](https://github.com/arkavo-org/VRMMetalKit/issues/194) | orthogonal to [#150](https://github.com/arkavo-org/VRMMetalKit/issues/150) |
| 6 | Vertex layout: position-only + attribute split | [#195](https://github.com/arkavo-org/VRMMetalKit/issues/195) | |
| 7 | Half-precision MToon fragment math | [#196](https://github.com/arkavo-org/VRMMetalKit/issues/196) | |
| 8 | Tile-memory pass merge | folded into [#192](https://github.com/arkavo-org/VRMMetalKit/issues/192) | |
| 9 | MPS-backed Kalman face smoothing | [#198](https://github.com/arkavo-org/VRMMetalKit/issues/198) | |
| 10 | Dual-quaternion joint palette | [#197](https://github.com/arkavo-org/VRMMetalKit/issues/197) | |
| + | GPU occlusion queries for crowd avatars | [#199](https://github.com/arkavo-org/VRMMetalKit/issues/199) | extends [#91](https://github.com/arkavo-org/VRMMetalKit/issues/91) / [#154](https://github.com/arkavo-org/VRMMetalKit/issues/154) |

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
