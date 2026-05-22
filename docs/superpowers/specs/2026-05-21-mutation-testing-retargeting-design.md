# Mutation Testing — Second Target: VRMA Retargeting Samplers

**Status:** Approved — ready for implementation plan
**Issue:** [#282](https://github.com/arkavo-org/VRMMetalKit/issues/282)
**Date:** 2026-05-21
**Predecessor:** `docs/superpowers/specs/2026-05-21-mutation-testing-gltfcore-design.md` (the
`DepthBiasCalculator` POC, shipped as PR #284)

## Problem

The `DepthBiasCalculator` POC proved the mutation-testing loop works and found a real
test-effectiveness blind spot (a priority if-chain with 100% line coverage but no
assertions that pinned its priority semantics). The open question from that POC: is
mutation testing worth standing up as a routine, or is one validated run enough?

This spec defines the **second and deciding run**. Per the agreed framing: if this run
surfaces a blind spot as meaningful as the POC's, expansion is justified; if it merely
confirms good coverage, mutation testing is "validated, not adopted" and we stop at two.

## Goal

Mutation-test the VRMA rest-pose retargeting math — the highest-signal Animation target,
where regression VMK#269 actually occurred. Produce a ≥80 % mutation score with every
surviving mutant classified, and a baseline document whose Verdict section feeds the
expand / stop decision.

## Non-Goals

- Other Animation files (`KeyframeSampling`, `AnimationPlayer`, IK, constraints).
- `makeExpressionWeightSampler` — it extracts a clamped weight, it is not retargeting math.
- Mutation testing the GLTFCore keyframe interpolation that the samplers call into.
- CI integration (still deferred — local-only).
- Custom muter operator sets.

## Background — why a refactor is required first

The retargeting math lives in three functions inside `VRMAnimationLoader.swift` (977 lines):

- `makeRotationSampler` — VRM 1.0 pose-normalization
  `Normalized = W_A · L_A⁻¹ · A · W_A⁻¹`, `B = L_B · W_B⁻¹ · Normalized · W_B`.
- `makeTranslationSampler` — additive delta `modelRest + (animTranslation - animRest)`.
- `makeScaleSampler` — ratio form `modelRest * safeDivide(animScale, animRest)`.

All three are `private`, return closures, and are interleaved with ~700 lines of GLB
parsing / node resolution / coordinate-conversion code. muter can only scope to whole
files, so mutating `VRMAnimationLoader.swift` would generate mutants across all the
parser code — most surviving for lack of `.vrma` fixtures — drowning the retargeting
signal. The math must be extracted into its own file before it can be mutation-tested
meaningfully. The extraction is also a genuine improvement: it turns three untestable
`private` closure-factories into an isolated, directly-testable unit.

## Design

### Phase 1 — Extract `RetargetingSamplers.swift` (behavior-preserving refactor)

**New file `Sources/VRMMetalKit/Animation/RetargetingSamplers.swift`.** Move from
`VRMAnimationLoader.swift`, changing `private` → `internal`:

- `makeRotationSampler(track:animationRestRotation:animationRestWorldRotation:modelRestRotation:modelRestWorldRotation:)`
- `makeTranslationSampler(track:animationRestTranslation:modelRestTranslation:)`
- `makeScaleSampler(track:animationRestScale:modelRestScale:)`
- `safeDivide(_:by:)` — used only by `makeScaleSampler`, moves with it.

**Modified `VRMAnimationLoader.swift`.** These symbols are shared with code that stays in
the loader (the look-at sampler, the expression-weight sampler), so they stay in place but
change `private` → `internal` so the new file and the test target can reach them:

- `struct KeyTrack`
- `sampleQuaternion(_:at:)`, `sampleVector3(_:at:)`

`makeExpressionWeightSampler` and `Interpolation.asGLTFCore` stay `private` in
`VRMAnimationLoader.swift` — neither is retargeting math and neither is needed across the
file boundary.

**Behavior contract:** no functional change. `VRMAnimationLoader` keeps calling the same
three functions, now cross-file within the module. The phase-1 gate is the existing VRMA
retargeting test suite passing unchanged (`swift test --disable-sandbox`, in particular
any `SpringBoneRegression` / animation-retargeting tests that load `.vrma` clips).

### Phase 2 — Mutation testing

**Oracle suite — `Tests/VRMMetalKitTests/RetargetingSamplersTests.swift`.** New file,
written before any mutation run. The retargeting samplers are `VRMMetalKit` code, so
`@testable import VRMMetalKit` reaches the now-`internal` functions and `KeyTrack`. Tests
build a `KeyTrack` with known `times`/`values`, call `makeRotationSampler(...)` (etc.) to
obtain the closure, invoke the closure at sample times, and assert the output. Required
coverage:

- **Identity rest poses** — when `animationRest == modelRest == identity`, the rotation
  formula collapses to `B = A`; hand-verifiable.
- **`W_A == W_B` collapse** — when animation and model share a world-rest orientation,
  the W terms cancel and `B = L_B · L_A⁻¹ · A`; hand-verifiable.
- **Full W-term change-of-basis** — animation rest ≠ model rest (the VMK#269 case): the
  W terms perform a real change of basis. Use a 90° offset that is hand-computable.
- **`nil` model-rest** — `makeRotationSampler` returns the passthrough closure
  (`sampleQuaternion(track, at:)` unmodified).
- **Translation** — additive delta `modelRest + (anim - animRest)`, plus the `nil`
  passthrough.
- **Scale** — ratio form `modelRest * (animScale / animRest)`, plus the `nil` passthrough.
- **`safeDivide`** — denominators that are zero, below the `1e-6` epsilon, and negative.

**muter config — `.muter/retargeting-samplers.yml`.** Same schema as the POC's
`.muter/depth-bias.yml`: `executable` = swift, `arguments` =
`["test", "--filter", "RetargetingSamplersTests", "--disable-sandbox"]`. File scoping,
JSON format, and output path are CLI flags in the Makefile (muter v16's config schema does
not carry them).

**Makefile.** Restructure the single `mutation-test` target into the aggregate pattern
already used by the `shaders` targets:

```makefile
mutation-test: mutation-test-depth-bias mutation-test-retargeting
	@echo "✅ All mutation-test targets complete"

mutation-test-depth-bias: $(MUTER_BIN)
	@mkdir -p .build/mutation-testing
	@$(MUTER_BIN) run \
		--configuration .muter/depth-bias.yml \
		--files-to-mutate Sources/GLTFCore/Utilities/DepthBiasCalculator.swift \
		--skip-coverage --format json \
		--output .build/mutation-testing/depth-bias.json

mutation-test-retargeting: $(MUTER_BIN)
	@mkdir -p .build/mutation-testing
	@$(MUTER_BIN) run \
		--configuration .muter/retargeting-samplers.yml \
		--files-to-mutate Sources/VRMMetalKit/Animation/RetargetingSamplers.swift \
		--skip-coverage --format json \
		--output .build/mutation-testing/retargeting-samplers.json
```

The existing `mutation-test` (currently hardcoded to DepthBiasCalculator, writing
`.build/mutation-testing/last-run.json`) is renamed to `mutation-test-depth-bias`; its
output path changes from `last-run.json` to `depth-bias.json` so the two targets do not
clobber each other. Update the `help:` block and `.PHONY` line accordingly. The existing
`docs/mutation-testing/depthbiascalculator-baseline.md` is updated in lockstep: both its
"Run" instruction (new target name `mutation-test-depth-bias`) and its report-path
reference (`depth-bias.json`).

**Baseline doc — `docs/mutation-testing/retargeting-samplers-baseline.md`.** Same
structure as the POC baseline (tooling + SHA-bump instructions, performance, mutation
score, every-survivor classification table) **plus a Verdict section**:

> ## Verdict
> Did this run surface a test-effectiveness blind spot comparable to the POC's
> priority-chain finding?
> - **If yes:** recommend expanding mutation testing to further Animation targets; name
>   the next candidates.
> - **If no (coverage merely confirmed):** recommend stopping at two targets — mutation
>   testing is validated as a technique for this codebase but not adopted as a routine.

### Survivor triage

Identical to the POC: each survivor is classified `kill-pending` (write a distinguishing
assertion), `equivalent` (semantically identical under all reachable inputs), or
`accepted-gap` (real gap deliberately not closed, with rationale). Iterate until the score
reaches ≥80 % or every remaining survivor is `equivalent` / `accepted-gap`.

## Acceptance Criteria

1. `RetargetingSamplers.swift` exists; `VRMAnimationLoader.swift` still compiles and the
   full existing test suite passes unchanged after the Phase-1 extraction.
2. `Tests/VRMMetalKitTests/RetargetingSamplersTests.swift` exists with direct oracle tests
   for all three samplers and `safeDivide`.
3. `make mutation-test-retargeting` runs cleanly and writes
   `.build/mutation-testing/retargeting-samplers.json`.
4. Mutation score ≥ 80 % on `RetargetingSamplers.swift`.
5. Every surviving mutant is classified with a one-line rationale in the baseline doc —
   no unclassified survivors.
6. The baseline doc's Verdict section gives a clear expand / stop recommendation.

If criterion 4 is unreachable for legitimate reasons — quaternion math has inherent
equivalent-mutant surface (`simd_normalize` of an already-normal value, `simd_inverse`
that equals the conjugate for unit quaternions) — document why in the baseline and propose
a revised bar. Do not gold-plate tests to hit the number.

## Risks

- **Quaternion oracle values are order-sensitive.** A wrong hand-computed expected value
  makes a test pass on mutated code by luck. Mitigation: anchor tests on the documented
  collapse cases (identity rest poses; `W_A == W_B`) where the formula simplifies to a
  hand-verifiable expression, and only then add the full W-term case.
- **Higher equivalent-mutant surface than the POC.** `simd_normalize` / `simd_inverse`
  calls mean some mutations are genuinely equivalent. Mitigation: criterion-4 escape
  hatch; classify rather than chase.
- **Phase-1 extraction changes visibility.** Promoting `KeyTrack` / `sampleQuaternion` /
  `sampleVector3` to `internal` widens the module-internal surface slightly. Acceptable —
  they remain `internal`, never `public`; no external API change.
- **muter patch fragility.** Unchanged from the POC: the v16 schemata patch is applied at
  bootstrap. No new exposure here; this run reuses the already-bootstrapped muter.

## Out of Scope

- Other Animation files; the GLTFCore keyframe samplers.
- CI integration.
- Custom operator sets.
- Any behavior change to the retargeting math itself — Phase 1 is a pure move.
