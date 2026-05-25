# Mutation Testing Baseline — VRMA Retargeting Samplers

**Issue:** [#282](https://github.com/arkavo-org/VRMMetalKit/issues/282)
**Last run:** 2026-05-21
**Target:** `Sources/VRMMetalKit/Animation/RetargetingSamplers.swift`
**Oracle suite:** `Tests/VRMMetalKitTests/RetargetingSamplersTests.swift` (15 tests)

## Tooling

`muter` built from `master` at the SHA pinned in `Makefile`, with the local
`.muter/patches/v16-schemata-content-fallback.patch` applied at bootstrap.

- Bootstrap: `make muter-bootstrap`
- Run: `make mutation-test-retargeting`
- Report: `.build/mutation-testing/retargeting-samplers.json` (gitignored)

## Mutation score

| | Count |
|---|---|
| Total mutants generated | 6 |
| Killed | 6 |
| Survived (equivalent) | 0 |
| Survived (accepted-gap) | 0 |

**Score (killed / (total − equivalent)): 100 %**

Total wall time: ~15 s. The first run scored 100 % — no triage cycle, no
survivor-driven tests added.

## Survivors

None.

## Mutant distribution — the result that matters

All 6 mutants muter generated landed inside `safeDivide` (lines 129–131):

| Line | Operator | Before → After |
|---|---|---|
| 129 | `RelationalOperatorReplacement` | `abs(denominator.x) > epsilon` → `< epsilon` |
| 130 | `RelationalOperatorReplacement` | `abs(denominator.y) > epsilon` → `< epsilon` |
| 131 | `RelationalOperatorReplacement` | `abs(denominator.z) > epsilon` → `< epsilon` |
| 129 | `SwapTernary` | `… ? denominator.x : 1` → `… ? 1 : denominator.x` |
| 130 | `SwapTernary` | `… ? denominator.y : 1` → `… ? 1 : denominator.y` |
| 131 | `SwapTernary` | `… ? denominator.z : 1` → `… ? 1 : denominator.z` |

The three retargeting samplers themselves — `makeRotationSampler` (the W-term
pose-normalization), `makeTranslationSampler` (additive delta),
`makeScaleSampler` (ratio) — generated **zero mutants**.

The reason is structural. muter v16 ships exactly four operators:
`RelationalOperatorReplacement`, `RemoveSideEffects`, `ChangeLogicalConnector`,
`SwapTernary`. The retargeting math is composed entirely of `simd` quaternion
and vector operations — `simd_normalize`, `simd_inverse`, quaternion `*`,
`SIMD3 + / - / *` — with no relational comparisons, no logical connectors, no
ternaries, and no discardable side-effecting statements. There is nothing in
that code for muter's operator set to mutate. `safeDivide` is the one part of
the file with scalar comparisons and ternaries, so it absorbed all 6 mutants.

## Verdict

**Validated, not adopted — lean stop. Do not stand mutation testing up as a
routine.**

Run #2 was the agreed go/no-go. It did not surface a test-effectiveness blind
spot the way the `DepthBiasCalculator` POC did — but it surfaced something more
decision-relevant: a **tooling blind spot**. muter v16's four scalar-oriented
operators are nearly inert against `simd`-based math. A 100 % score here means
"every mutant muter could generate was killed," and muter could only generate
mutants in a 3-line guard helper. The retargeting formulas — the actual reason
this file was chosen, the math where VMK#269 regressed — received no mutation
coverage at all.

This recontextualizes the POC. `DepthBiasCalculator` scored well *and* produced
a meaningful finding because it is scalar control-flow code — string
`contains`, `||` chains, dictionary fallbacks, `?` defaults — exactly what
muter's operators target. That made it an unrepresentative first pick.
VRMMetalKit's core — rendering, animation, physics — is overwhelmingly `simd`
vector and quaternion math. Expanding mutation testing to further Animation /
Renderer / physics modules would mostly reproduce this run's near-empty result.

**Recommendation:**
- Do **not** adopt mutation testing as a routine or CI gate.
- Keep it as an occasional, opt-in spot-check for **scalar-logic-heavy files**
  specifically — config/parameter resolvers, validation, state machines,
  enum-dispatch tables — where muter's operator set has real purchase and the
  POC demonstrated genuine value.
- The infrastructure stays in place (`make mutation-test-*`, the patched muter
  bootstrap, two baseline docs) so a future spot-check is one command away.

### Considered and rejected: extending muter

muter is open-source; one could add an arithmetic-operator-replacement operator
and a `simd`-aware variant so the retargeting math becomes mutable. That is a
real project — authoring and maintaining custom muter operators on top of the
already-carried v16 schemata patch — and the maintenance cost is not justified
at this project's scale. Recorded here so the option is not silently lost.

## Follow-ups

- Issue #282 can be closed after this run: the technique is validated, the
  scope question is answered (stop at two targets), and the reasoning is
  captured in this doc + `depthbiascalculator-baseline.md`.
- If the muter v16 schemata patch is ever worth upstreaming, that remains a
  standalone contribution independent of whether VRMMetalKit adopts the tool.
