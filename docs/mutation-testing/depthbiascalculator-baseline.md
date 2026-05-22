# Mutation Testing Baseline — `DepthBiasCalculator`

**Issue:** [#282](https://github.com/arkavo-org/VRMMetalKit/issues/282)
**Last run:** 2026-05-21
**Target:** `Sources/GLTFCore/Utilities/DepthBiasCalculator.swift`
**Oracle suite:** `Tests/VRMMetalKitTests/DepthBiasCalculatorTests.swift` (32 tests)

## Tooling

`muter` built from `master` at SHA `99624ecfde93dac3cc1f7a66ac6f7df05611091d` with one local patch
(see `.muter/patches/v16-schemata-content-fallback.patch`). The patch fixes a v16 bug where
`SchemataMutationMapping` keyed mutant branches by SwiftSyntax tree-position identity, but
`ApplySchemata` re-parsed source files, so identity-based lookups always missed and the schemata
embedding produced no-op binaries (0% killed on any suite).

- Bootstrap: `make muter-bootstrap`
- Run: `make mutation-test-depth-bias`
- Report: `.build/mutation-testing/depth-bias.json` (gitignored)

### Bumping the muter SHA

1. Edit `MUTER_SHA` in `Makefile`.
2. Delete `.build/tools/muter-src` to force a fresh clone:
   `rm -rf .build/tools/muter-src`
3. Run `make muter-bootstrap`. The bootstrap target re-clones, checks out the new SHA, applies the
   patch (`git apply ../../../.muter/patches/v16-schemata-content-fallback.patch`), and builds.
4. If the patch fails to apply against the new SHA (`git apply` errors), refresh the patch:
   - Manually re-apply the content-based fallback in `SchemataMutationMapping.swift`
   - `cd .build/tools/muter-src && git diff > /tmp/muter-fix.patch`
   - `cp /tmp/muter-fix.patch .muter/patches/v16-schemata-content-fallback.patch`
   - Re-run `make muter-bootstrap` to confirm.
5. If the new SHA itself fails to build under Swift 6.2, fall back to the most recent ancestor
   that does (`cd .build/tools/muter-src && git log --oneline | head -20`).

## Performance

| Measurement | Time |
|---|---|
| Test suite cold run (`swift package clean && swift test --filter DepthBiasCalculatorTests --disable-sandbox`) | 16.6 s |
| Test suite warm run | 0.58 s |
| Total mutation-test wall time (8 mutants × baseline + 8 mutant runs) | ~7 s |

The warm-run cost is dominated by SwiftPM resolution overhead; the actual test execution is
sub-millisecond. Per-mutant wall time is well under the 15-second acceptance gate from the spec.

## Mutation score

| | Count |
|---|---|
| Total mutants generated | 8 |
| Killed | 7 |
| Survived (kill-pending) | 0 |
| Survived (equivalent) | 0 |
| Survived (accepted-gap) | 1 |
| Timed out (counted as killed) | 0 |

**Score: 7 / (8 − 0) = 87 %** — above the spec's 80 % acceptance bar.

## Survivors

Every surviving mutant in the final run is listed below. No unclassified survivors.

| # | File:line | Operator | Before → After | Classification | Rationale |
|---|---|---|---|---|---|
| 1 | `DepthBiasCalculator.swift:141` | `RemoveSideEffects` | `encoder.setDepthBias(bias, slopeScale: slopeScale, clamp: clamp)` → removed | `accepted-gap` | The mutant deletes the call to `MTLRenderCommandEncoder.setDepthBias`. No pure-Swift unit test can observe the absence of that side-effect without a real Metal device and an encoder fixture. Closing this gap requires either (a) wrapping the encoder behind a mockable protocol that a unit test can verify call counts on, or (b) a GPU integration test. Both are out of scope for this PR — file a follow-up if the gap proves to matter. |

## Survivors that were killed in triage

Five new multi-keyword tests were added to the oracle suite after the first muter run revealed
that single-keyword "alone" tests were caught by the partial-match scan in `computeBias()`. The
multi-keyword approach exploits the priority chain — the original code returns one value via the
explicit if-chain (the higher-priority branch), but a mutated code path falls through to a lower-
priority branch with a different value, which the test catches.

| # | Mutant file:line:col | Mutation | Killing test | Killing input |
|---|---|---|---|---|
| 1 | `:165:41` | `cloth \|\| clothing` → `&&` | `testClothBodyReturnsClothing` | `"cloth_body"` |
| 2 | `:165:76` | `clothing \|\| skirt` → `&&` | `testSkirtBodyReturnsClothing` | `"skirt_body"` |
| 3 | `:166:41` | `skirt \|\| bottoms` → `&&` | `testSkirtBodyReturnsClothing` | `"skirt_body"` |
| 4 | `:166:75` | `bottoms \|\| pants` → `&&` | `testBottomsBodyReturnsClothing` | `"bottoms_body"` |
| 5 | `:178:41` | `mouth \|\| lip` → `&&` | `testMouthEyeReturnsMouth` | `"mouth_eye"` |
| 6 | `:181:43` | `eyebrow \|\| brow` → `&&` | `testBrowEyeReturnsEyebrow` | `"brow_eye"` |
| 7 | `:112` | `isOverlay ? overlayBiasOffset : 0.0` → swapped | `testOverlayAddsOffsetToBody` and several others | (various) |

## Follow-ups proposed

- **Encoder side-effect coverage (#TBD):** the surviving `RemoveSideEffects` mutant on
  `encoder.setDepthBias` could be killed by wrapping the encoder behind a mockable protocol that
  records `setDepthBias` calls. Worth weighing the design cost against the value — the call is
  a one-liner that's hard to break silently.
- **Upstream the muter v16 patch:** the schemata identity-vs-content bug affects every muter user
  on Swift 6.2; consider sending the fix in `.muter/patches/v16-schemata-content-fallback.patch`
  upstream to [muter-mutation-testing/muter](https://github.com/muter-mutation-testing/muter).
- **Expand mutation testing to other GLTFCore files** (per issue #282 scoping): the next
  candidates by leverage are `Animation/KeyframeSampling.swift`, `Animation/SceneGraph.swift`,
  then `Builder/GLTFDocumentBuilder.swift`. Each gets its own focused PR.
