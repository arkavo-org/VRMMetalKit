# Performance Roadmap

Engineering tracking doc for the prioritized performance work captured in the
**[Romero-style perf review epic — #200][epic]**. Each row links to a focused
issue. This file is an index, not a spec — design and implementation detail
live on each issue.

[epic]: https://github.com/arkavo-org/VRMMetalKit/issues/200

## Prerequisite

| Issue | Title | Status |
|-------|-------|--------|
| [#156](https://github.com/arkavo-org/VRMMetalKit/issues/156) | Benchmark CI regression gate | ✅ **landed** — see [Benchmark gate](#benchmark-gate-156) |

Romero / Carmack rule: never optimise anything you haven't measured. The gate
below now produces a tracked baseline (`render.median` on the reference model),
so the optimisation claims that follow are verifiable against it.

## Benchmark gate (#156)

`.github/workflows/bench.yaml` gates per-frame render cost on every push.

- **Trigger:** `push` only — **never `pull_request`**. The repo is public and
  the runner is self-hosted, so a fork PR must never execute code on the runner
  host. Pushes are the maintainer's own (trusted) code. Fork PRs are still
  covered by the GitHub-hosted lint/codeql checks.
- **Metric:** `render.median` (+10 %) and `render.p95` (+20 %) of `VRMBenchmark`
  in `--mode render` against the committed reference model
  `AvatarSample_A_1.0.vrm.glb` (1024², 500 frames, release). Only the `render`
  total phase is gated (`--gate-phase render`); the `encode`/`wait`/near-zero
  `animation` sub-phases are skipped because their run-to-run noise (up to ~28 %
  on `wait.p95`) would false-fire. `render.median` is ~4.5 % stable.
- **Baseline:** `.benchmark-baseline.json` at the repo root, captured on the
  CI hardware. After the gate passes on a `main` push, the `refresh` job
  re-measures and auto-commits a new baseline **only when `render.median` moves
  more than ±5 %** — gating before refreshing means a regression never silently
  raises the bar.
- **Override:** put `[perf-override]` in the commit message to land an
  intentional regression (e.g. a new feature with known cost). The gate still
  runs and reports, but does not block; refresh the baseline afterward.
- **Runner:** requires a **self-hosted macOS runner** (labels `[self-hosted,
  macOS]`) holding no workflow-reachable secrets — a committed absolute
  frame-time baseline is only meaningful on fixed hardware. Runs queue until one
  is registered. Token scope is least-privilege: `contents: read` everywhere
  except the `refresh` job (`contents: write`).

### Updating the baseline manually

```bash
swift build -c release --product VRMBenchmark
.build/release/VRMBenchmark AvatarSample_A_1.0.vrm.glb \
  --mode render --frames 500 --warmup 30 --label ci-baseline \
  --json .benchmark-baseline.json
git add .benchmark-baseline.json && git commit -m "chore(bench): refresh baseline"
```

Run it on the same machine class as the CI runner, or the comparison is noise.

## Optimisations (priority order)

| # | Area | Issue | Notes |
|---|------|-------|-------|
| 1 | Baselines | [#156](https://github.com/arkavo-org/VRMMetalKit/issues/156) | ✅ landed — render-median gate + auto-refreshed baseline |
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
