# Mutation Testing on `DepthBiasCalculator` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the end-to-end mutation-testing loop on one pure-math GLTFCore utility (`DepthBiasCalculator`), backed by a direct unit suite, with a ≥80% mutation score and every surviving mutant classified in a committed baseline document.

**Architecture:** Install `muter` from a pinned `master` SHA into `.build/tools/`, scaffold a direct unit test suite (`DepthBiasCalculatorTests.swift`) before any mutation run, point muter at only that suite via `.muter/depth-bias.json`, triage survivors, then publish a Markdown baseline.

**Tech Stack:** Swift 6.2, XCTest, [muter](https://github.com/muter-mutation-testing/muter) (built from source at pinned SHA `99624ec`), Make.

**Spec:** `docs/superpowers/specs/2026-05-21-mutation-testing-gltfcore-design.md`
**Issue:** [#282](https://github.com/arkavo-org/VRMMetalKit/issues/282)

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `Makefile` | Modify | Add `MUTER_SHA` var, `$(MUTER_BIN)` rule, `muter-bootstrap`, `mutation-test` targets |
| `.muter/depth-bias.json` | Create | muter config: target one file, run one test filter |
| `Tests/VRMMetalKitTests/DepthBiasCalculatorTests.swift` | Create | Direct unit oracle suite — written before any muter run |
| `docs/mutation-testing/depthbiascalculator-baseline.md` | Create | Mutation score, every-survivor classification, measured per-test time, pinned SHA |
| `.build/tools/muter-src/` | Create (gitignored) | muter source clone, gitignored under existing `.build/` rule |
| `.build/tools/bin/muter` | Create (gitignored) | symlink to built binary |
| `.build/mutation-testing/last-run.json` | Create (gitignored) | Deterministic JSON output path for future CI |

No other files modified.

---

## Task 1: Bootstrap `muter` from pinned SHA

**Files:**
- Modify: `Makefile`

The candidate pinned SHA is `99624ecfde93dac3cc1f7a66ac6f7df05611091d` (muter master @ 2026-04-27, the "fix: Prevent memory exhaustion on large codebases" commit). If this SHA fails to build under Swift 6.2 locally, the implementer chooses the most recent ancestor that does (see Step 4 below).

- [ ] **Step 1: Add Makefile targets.**

Append to `Makefile` (after the existing `gltf-shaders` block, before `clean`):

```makefile
# Mutation testing (issue #282) — first target: DepthBiasCalculator
# muter is built from a pinned master SHA into .build/tools/ because the
# last tagged release (16, 2023) predates Swift 6.2 toolchain changes.
MUTER_SHA := 99624ecfde93dac3cc1f7a66ac6f7df05611091d
MUTER_BIN := .build/tools/bin/muter

$(MUTER_BIN):
	@echo "🔧 Building muter @ $(MUTER_SHA)..."
	@mkdir -p .build/tools
	@if [ ! -d .build/tools/muter-src ]; then \
		git clone https://github.com/muter-mutation-testing/muter.git .build/tools/muter-src; \
	fi
	@cd .build/tools/muter-src && git fetch && git checkout $(MUTER_SHA)
	@cd .build/tools/muter-src && swift build -c release
	@mkdir -p .build/tools/bin
	@ln -sf ../muter-src/.build/release/muter $(MUTER_BIN)
	@echo "✅ muter built: $$(./$(MUTER_BIN) --version 2>/dev/null || echo unknown)"

muter-bootstrap: $(MUTER_BIN)
	@$(MUTER_BIN) --version

mutation-test: $(MUTER_BIN)
	@mkdir -p .build/mutation-testing
	@$(MUTER_BIN) run --configuration .muter/depth-bias.json
```

Also update `.PHONY` near the top of the file. Find the existing line (it currently includes `shaders shaders-macos shaders-ios shaders-iossim gltf-shaders clean test docs docs-static`) and add `muter-bootstrap mutation-test` at the end:

```makefile
.PHONY: help shaders shaders-macos shaders-ios shaders-iossim gltf-shaders clean test docs docs-static muter-bootstrap mutation-test
```

Update the `help:` block to mention the new targets. Find the existing shaders-related help lines and add immediately after:

```makefile
	@echo "  make muter-bootstrap - Build muter from a pinned SHA into .build/tools/"
	@echo "  make mutation-test - Run mutation testing against DepthBiasCalculator"
```

- [ ] **Step 2: Run `make muter-bootstrap` to clone and build muter at the pinned SHA.**

Run:

```bash
make muter-bootstrap 2>&1 | tail -20
```

Expected: build completes, `muter --version` prints a version string (likely `0.x.0` or similar; the exact number depends on the SHA's build metadata).

- [ ] **Step 3: If the build fails, fall back to the most recent ancestor that builds.**

If `swift build -c release` inside `.build/tools/muter-src` errors out (e.g., Swift 6.2 macro expansion issues, missing API, dependency conflicts):

1. From inside `.build/tools/muter-src`, run `git log --oneline $(MUTER_SHA) -20` to list the 20 commits preceding the pinned SHA.
2. Try each prior commit (oldest-first within that window): `git checkout <sha> && swift build -c release`.
3. On the first commit that builds cleanly, copy its SHA back into `Makefile`'s `MUTER_SHA :=` line.
4. Re-run `make muter-bootstrap` to confirm the bumped SHA builds via the Makefile path.

If no commit in the 20-commit window builds, STOP and escalate — this is a tooling problem the plan didn't anticipate.

- [ ] **Step 4: Verify the binary works on a no-op invocation.**

Run:

```bash
.build/tools/bin/muter help 2>&1 | head -20
```

Expected: muter prints its CLI help banner. If it prints nothing or crashes, the build artifact is bad — STOP and investigate.

- [ ] **Step 5: Commit the Makefile changes.**

```bash
git add Makefile
git commit -m "build(mutation-testing): bootstrap muter from pinned SHA (#282)

Adds make muter-bootstrap to build muter from a pinned master SHA into
.build/tools/, and make mutation-test as the run target. The 2023 tagged
release (16) predates Swift 6.2 toolchain changes; building from source
is the only reliable path until muter cuts a new release.

Issue #282

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
"
```

(If the implementer bumped `MUTER_SHA` to an ancestor in Step 3, the commit message body should note the substitution and why.)

---

## Task 2: Write the direct unit test suite

**Files:**
- Create: `Tests/VRMMetalKitTests/DepthBiasCalculatorTests.swift`

The suite is written **before** any mutation run. Tests target the public surface of `DepthBiasCalculator` with oracle pairs (known input → known output). They are not yet survivor-driven; the survivor-driven additions land in Task 5.

- [ ] **Step 1: Create the test file.**

Create `Tests/VRMMetalKitTests/DepthBiasCalculatorTests.swift` with:

```swift
//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import XCTest
@testable import GLTFCore

/// Direct unit tests for `DepthBiasCalculator` — the mutation-testing oracle suite.
///
/// These tests assert known input/output pairs on the calculator's public
/// surface so that mutation testing (issue #282) has a meaningful target.
/// `HipSkirtTests` exercises the calculator only incidentally via the
/// hip-skirt scenario; muter must not be pointed at it.
final class DepthBiasCalculatorTests: XCTestCase {

    // MARK: - Construction & constants

    func testDefaultScaleIsOne() {
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.scale, 1.0)
    }

    func testExplicitScaleIsRetained() {
        let calc = DepthBiasCalculator(scale: 2.5)
        XCTAssertEqual(calc.scale, 2.5)
    }

    func testSlopeScaleConstant() {
        XCTAssertEqual(DepthBiasCalculator().slopeScale, 2.0)
    }

    func testClampConstant() {
        XCTAssertEqual(DepthBiasCalculator().clamp, 0.1)
    }

    // MARK: - Exact-match lookups (from baseBiasValues table)

    func testBodySkinExactMatch() {
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "Body_SKIN", isOverlay: false), 0.005, accuracy: 1e-6)
    }

    func testFaceExactMatch() {
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "Face", isOverlay: false), 0.01, accuracy: 1e-6)
    }

    func testEyeExactMatch() {
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "Eye", isOverlay: false), 0.03, accuracy: 1e-6)
    }

    func testHighlightExactMatch() {
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "Highlight", isOverlay: false), 0.04, accuracy: 1e-6)
    }

    // MARK: - Priority ordering in computeBias

    func testClothingPriorityBeatsBody() {
        // "Body_Clothing" — clothing check (Priority 1) must fire before body check (Priority 2).
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "Body_Clothing", isOverlay: false), 0.015, accuracy: 1e-6,
                       "Material containing both 'body' and 'clothing' must hit the clothing branch first")
    }

    func testBodyPriorityBeatsFaceAndSkin() {
        // "Body_Face_Skin" — body (Priority 2) must fire before face (Priority 3) and skin (Priority 4).
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "Body_Face_Skin", isOverlay: false), 0.005, accuracy: 1e-6)
    }

    func testEyebrowPriorityBeatsEye() {
        // "Eyebrow" contains "eye", but the eyebrow check fires first.
        let calc = DepthBiasCalculator()
        let bias = calc.depthBias(for: "left_eyebrow_inner", isOverlay: false)
        XCTAssertEqual(bias, 0.025, accuracy: 1e-6,
                       "Eyebrow-containing names must hit eyebrow (0.025), not eye (0.03)")
    }

    func testMouthPriorityFires() {
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "mouth_inner", isOverlay: false), 0.02, accuracy: 1e-6)
    }

    // MARK: - Case-insensitive substring match

    func testLowercaseInputMatchesBody() {
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "body_mesh", isOverlay: false), 0.005, accuracy: 1e-6)
    }

    func testUppercaseInputMatchesBody() {
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "BODY_MESH", isOverlay: false), 0.005, accuracy: 1e-6)
    }

    func testMixedCaseInputMatchesClothing() {
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "MyCloThInG_Material", isOverlay: false), 0.015, accuracy: 1e-6)
    }

    // MARK: - Default fallback

    func testUnknownMaterialReturnsDefault() {
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "totally_unknown_material_xyz", isOverlay: false), 0.01, accuracy: 1e-6)
    }

    func testEmptyStringReturnsDefault() {
        let calc = DepthBiasCalculator()
        XCTAssertEqual(calc.depthBias(for: "", isOverlay: false), 0.01, accuracy: 1e-6)
    }

    // MARK: - Overlay offset

    func testOverlayAddsOffsetToBody() {
        let calc = DepthBiasCalculator()
        let base = calc.depthBias(for: "Body_SKIN", isOverlay: false)
        let overlay = calc.depthBias(for: "Body_SKIN", isOverlay: true)
        XCTAssertEqual(overlay - base, 0.01, accuracy: 1e-6,
                       "isOverlay:true must add exactly 0.01 to the base bias")
    }

    func testOverlayAddsOffsetToDefault() {
        let calc = DepthBiasCalculator()
        let base = calc.depthBias(for: "unknown_xyz", isOverlay: false)
        let overlay = calc.depthBias(for: "unknown_xyz", isOverlay: true)
        XCTAssertEqual(overlay - base, 0.01, accuracy: 1e-6)
    }

    // MARK: - Scale multiplication

    func testScaleMultipliesBase() {
        let calc = DepthBiasCalculator(scale: 3.0)
        let bias = calc.depthBias(for: "Body_SKIN", isOverlay: false)
        XCTAssertEqual(bias, 0.015, accuracy: 1e-6, "0.005 * 3.0 = 0.015")
    }

    func testScaleMultipliesOverlay() {
        let calc = DepthBiasCalculator(scale: 2.0)
        let bias = calc.depthBias(for: "Body_SKIN", isOverlay: true)
        XCTAssertEqual(bias, 0.03, accuracy: 1e-6, "(0.005 + 0.01) * 2.0 = 0.03")
    }

    func testScaleZeroProducesZero() {
        let calc = DepthBiasCalculator(scale: 0.0)
        XCTAssertEqual(calc.depthBias(for: "Highlight", isOverlay: true), 0.0, accuracy: 1e-6)
    }

    func testNegativeScaleNegates() {
        let calc = DepthBiasCalculator(scale: -1.0)
        XCTAssertEqual(calc.depthBias(for: "Body_SKIN", isOverlay: false), -0.005, accuracy: 1e-6)
    }

    // MARK: - Cache behavior (observable via repeated calls)

    func testRepeatCallsReturnSameValue() {
        let calc = DepthBiasCalculator()
        let first = calc.depthBias(for: "Skirt_v2", isOverlay: true)
        let second = calc.depthBias(for: "Skirt_v2", isOverlay: true)
        let third = calc.depthBias(for: "Skirt_v2", isOverlay: true)
        XCTAssertEqual(first, second, accuracy: 0.0,
                       "Cache hit must return bit-identical value")
        XCTAssertEqual(second, third, accuracy: 0.0)
    }

    func testCacheDoesNotConflateDistinctMaterials() {
        let calc = DepthBiasCalculator()
        let body = calc.depthBias(for: "Body_SKIN", isOverlay: false)
        let cloth = calc.depthBias(for: "Skirt", isOverlay: false)
        XCTAssertNotEqual(body, cloth,
                          "Distinct material names must produce distinct biases")
    }
}
```

- [ ] **Step 2: Build the test target.**

Run:

```bash
swift build --target VRMMetalKitTests 2>&1 | tail -10
```

Expected: build succeeds. The `@testable import GLTFCore` needs the `GLTFCore` module to be visible — it should be, since `VRMMetalKitTests` already imports `GLTFCore`-using helpers via `VRMMetalKit`. If the import fails, add `@testable import VRMMetalKit` as a second line (since `VRMMetalKit` re-exports `GLTFCore` types) — but try `GLTFCore` first.

- [ ] **Step 3: Run the suite and verify all tests pass.**

```bash
swift test --filter DepthBiasCalculatorTests --disable-sandbox 2>&1 | tail -30
```

Expected: all ~22 tests pass. If any fail, the test or the calculator has a real bug — STOP and investigate before adding more code.

- [ ] **Step 4: Commit.**

```bash
git add Tests/VRMMetalKitTests/DepthBiasCalculatorTests.swift
git commit -m "test(gltfcore): direct unit oracle suite for DepthBiasCalculator (#282)

Adds 22 direct unit tests covering construction, exact-match lookups,
priority ordering, case-insensitive matching, default fallback, overlay
offset, scale multiplication, and cache observability. This suite is
the muter target for issue #282; HipSkirtTests stays as the integration
suite and is not part of the mutation oracle.

Issue #282

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
"
```

---

## Task 3: Measure per-test-run time before committing to the loop

**Files:** (none modified yet — this is a measurement step that informs Task 4)

- [ ] **Step 1: Cold run.**

```bash
swift package clean
time swift test --filter DepthBiasCalculatorTests --disable-sandbox 2>&1 | tail -5
```

Record the `real` time. Cold time includes full SwiftPM resolution.

- [ ] **Step 2: Warm run.**

Immediately re-run (no `swift package clean` this time):

```bash
time swift test --filter DepthBiasCalculatorTests --disable-sandbox 2>&1 | tail -5
```

Record the `real` time. This is the per-mutant cost muter will pay.

- [ ] **Step 3: Acceptance gate.**

- **Warm time ≤ 15 seconds:** proceed to Task 4.
- **Warm time > 15 seconds:** STOP. Report the timing and pause for direction — the spec defines this as a checkpoint, not a stop-and-give-up. Possible mitigations include reducing operator set, using a smaller filter, or accepting longer runtimes.

Record both times (cold and warm) — they go into the baseline doc in Task 6.

(No commit here; nothing changed.)

---

## Task 4: Write muter configuration

**Files:**
- Create: `.muter/depth-bias.json`

- [ ] **Step 1: Generate a template via muter init.**

Run:

```bash
.build/tools/bin/muter init 2>&1 | head -10
```

This writes a `muter.conf.yml` (or `.muter.conf.yml`) at the repo root. Read that file to learn the exact key names and structure for the muter version you built. Then craft the JSON variant below.

- [ ] **Step 2: Create the JSON config.**

Create `.muter/depth-bias.json` with:

```json
{
  "executable": "/usr/bin/env",
  "arguments": [
    "swift",
    "test",
    "--filter",
    "DepthBiasCalculatorTests",
    "--disable-sandbox"
  ],
  "mutate": {
    "filesToMutate": [
      "Sources/GLTFCore/Utilities/DepthBiasCalculator.swift"
    ],
    "operators": ["all"]
  },
  "exclude_files": [],
  "outputPath": ".build/mutation-testing/last-run.json"
}
```

**Note on key names:** muter's schema has shifted over time. Adapt the key names to match the `muter init` template you generated in Step 1 — if the schema uses `mutate_files` instead of `mutate.filesToMutate`, or `report` instead of `outputPath`, follow the template. The semantic contents (target file, test command, output path) are what matters.

**Note on `--disable-sandbox`:** this flag is required because the project's tests need filesystem access for fixtures (per `CLAUDE.md` convention); muter additionally needs FS write access to perform source rewrites.

- [ ] **Step 3: Delete the auto-generated template.**

```bash
rm -f muter.conf.yml .muter.conf.yml
```

We don't ship the template; the curated `.muter/depth-bias.json` is the single source of truth.

- [ ] **Step 4: Dry-run-validate the config.**

```bash
.build/tools/bin/muter run --configuration .muter/depth-bias.json --steps 2>&1 | tail -20
```

If muter has a `--steps`, `--dry-run`, or schema-validation flag (varies by version), use it to confirm the config parses. If no such flag exists in the pinned SHA, skip this step.

- [ ] **Step 5: Commit.**

```bash
git add .muter/depth-bias.json
git commit -m "build(mutation-testing): muter config targeting DepthBiasCalculator (#282)

Mutates Sources/GLTFCore/Utilities/DepthBiasCalculator.swift using
muter's default operator set. Tests run via swift test --filter
DepthBiasCalculatorTests --disable-sandbox (sandbox-disabled because
project tests need FS access for fixtures, and muter needs FS write
access for source rewrites). JSON output path is deterministic for
future CI artifact consumption.

Issue #282

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
"
```

---

## Task 5: First muter run + survivor triage

**Files:**
- Modify: `Tests/VRMMetalKitTests/DepthBiasCalculatorTests.swift` (add tests to kill kill-pending survivors)

- [ ] **Step 1: Run muter.**

```bash
make mutation-test 2>&1 | tee /tmp/muter-first-run.log
```

Expected: muter parses `DepthBiasCalculator.swift`, generates mutants, runs the unit suite against each, and reports results to stdout + `.build/mutation-testing/last-run.json`. Total wall time should be (warm-test-time × mutant-count); for a 253-LOC file with default operators, expect roughly 30–60 mutants.

Capture and save:
- Total mutants generated.
- Killed / survived / equivalent / timeout counts.
- Overall score `killed / (total - equivalent)`.
- Wall time.

- [ ] **Step 2: Triage every survivor.**

Open `.build/mutation-testing/last-run.json`. For each surviving mutant, classify it into one of three buckets:

1. **`kill-pending`** — the test suite has a real gap. Write an assertion that distinguishes the mutant. Add it to `DepthBiasCalculatorTests.swift` under a new `// MARK: - Survivor-driven additions` section.
2. **`equivalent`** — the mutation produces semantically identical behavior under all reachable inputs. Examples: a constant `* 1.0` cast, mutating an unreachable `else` branch, or a default-fallback that's already been hit. Record one-line rationale.
3. **`accepted-gap`** — a real gap that is deliberately not being closed in this PR (e.g., requires fixture data we don't have, would exercise a code path scheduled for removal). Record rationale and propose a follow-up if appropriate.

- [ ] **Step 3: Re-run muter with the new tests.**

```bash
make mutation-test 2>&1 | tail -30
```

Repeat Step 2 if the score is still under 80% and unclassified survivors remain — but only until the score either reaches 80% or every remaining survivor is classified as `equivalent` or `accepted-gap` (i.e., legitimately unclosable in this PR).

If the score plateaus below 80% and the spec's escape hatch applies (inherent equivalent-mutant surface), document why in the baseline doc and stop — do not gold-plate tests to hit a number.

- [ ] **Step 4: Commit the new tests once the score stabilizes.**

```bash
git add Tests/VRMMetalKitTests/DepthBiasCalculatorTests.swift
git commit -m "test(gltfcore): kill survivors from first DepthBiasCalculator mutation run (#282)

Survivor-driven additions to the oracle suite. <one-line summary of what
kinds of assertions were added — e.g., 'explicit constant-value checks
for each priority branch, off-by-one boundary tests on the partial-match
loop'.>

Issue #282

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
"
```

(Customize the body to reflect the actual additions. Avoid copying the bullet list verbatim.)

---

## Task 6: Write the baseline document

**Files:**
- Create: `docs/mutation-testing/depthbiascalculator-baseline.md`

- [ ] **Step 1: Create the directory.**

```bash
mkdir -p docs/mutation-testing
```

- [ ] **Step 2: Write the baseline doc.**

Create `docs/mutation-testing/depthbiascalculator-baseline.md` with this exact structure (fill in measurements from the actual run):

```markdown
# Mutation Testing Baseline — `DepthBiasCalculator`

**Issue:** [#282](https://github.com/arkavo-org/VRMMetalKit/issues/282)
**Last run:** YYYY-MM-DD
**Target:** `Sources/GLTFCore/Utilities/DepthBiasCalculator.swift`
**Oracle suite:** `Tests/VRMMetalKitTests/DepthBiasCalculatorTests.swift`

## Tooling

- `muter` built from `master` at SHA `<pinned-sha>`.
- Bootstrap: `make muter-bootstrap`.
- Run: `make mutation-test`.

### Bumping the muter SHA

1. Edit `MUTER_SHA` in the project `Makefile`.
2. Delete `.build/tools/muter-src` to force a fresh clone.
3. Run `make muter-bootstrap`. If the new SHA fails to build, try the most recent ancestor that does (`cd .build/tools/muter-src && git log --oneline`).

## Performance

| Measurement | Time |
|---|---|
| Test suite warm run (`swift test --filter DepthBiasCalculatorTests --disable-sandbox`) | _Xs_ |
| Test suite cold run | _Xs_ |
| Total mutation-test wall time | _Xm Ys_ |

## Mutation score

| | Count |
|---|---|
| Total mutants generated | _N_ |
| Killed | _N_ |
| Survived (kill-pending) | _N_ |
| Survived (equivalent) | _N_ |
| Survived (accepted-gap) | _N_ |
| Timed out (counted as killed) | _N_ |

**Score (killed / (total - equivalent)):** _NN%_

## Survivors

Every surviving mutant in the final run is listed here. No unclassified survivors.

| # | File:line | Operator | Before → After | Classification | Rationale |
|---|---|---|---|---|---|
| 1 | DepthBiasCalculator.swift:115 | RelationalOperatorReplacement | `+ overlayOffset` → `- overlayOffset` | kill-pending | Closed by testOverlayAddsOffsetToBody |
| 2 | DepthBiasCalculator.swift:90 | ChangeNumber | `0.01` → `1.0` | equivalent | Unreachable fallback when baseBiasValues lookup succeeds for all tested inputs |
| ... | ... | ... | ... | ... | ... |

## Follow-ups proposed

(Empty if none. Otherwise: one bullet per follow-up issue with a one-line motivation.)
```

- [ ] **Step 3: Commit.**

```bash
git add docs/mutation-testing/depthbiascalculator-baseline.md
git commit -m "docs(mutation-testing): DepthBiasCalculator mutation baseline (#282)

First-target proof-of-concept baseline: score, every-survivor classification,
performance measurements, and SHA-bump instructions.

Issue #282

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
"
```

---

## Task 7: Push and open PR

**Files:** (none)

- [ ] **Step 1: Confirm with the user before pushing.**

The project convention (see `CLAUDE.md` memory) is to not push without explicit consent. Ask the user; if approved, proceed.

- [ ] **Step 2: Push the branch.**

```bash
git push -u origin issue/282-mutation-testing
```

- [ ] **Step 3: Open the PR.**

```bash
gh pr create --title "feat(testing): mutation testing on DepthBiasCalculator (#282)" --body "$(cat <<'EOF'
Closes #282

## Summary
- Bootstraps `muter` from a pinned `master` SHA into `.build/tools/` (the 2023 tagged release predates Swift 6.2).
- Adds a direct unit oracle suite (`DepthBiasCalculatorTests.swift`) — written before any mutation run so the muter target isn't an integration suite.
- Ships `.muter/depth-bias.json` configured to mutate only `DepthBiasCalculator.swift`, run only the new unit suite, write JSON to a deterministic path.
- Produces a baseline document with mutation score, per-survivor classification (kill-pending / equivalent / accepted-gap), and performance measurements.
- `make muter-bootstrap` and `make mutation-test` reproduce the run locally.

## Out of scope
- Other GLTFCore files (own follow-ups).
- CI integration (deferred until cost is understood).
- Custom operator sets.

## Test plan
- [x] `make muter-bootstrap` builds muter from the pinned SHA
- [x] `make mutation-test` produces a non-zero mutation score
- [x] `swift test --filter DepthBiasCalculatorTests --disable-sandbox` passes
- [x] Baseline doc classifies every surviving mutant
- [x] Mutation score ≥80% (or documented escape hatch applies)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Hand the PR URL back to the user.

---

## Self-Review

**Spec coverage:**
- §1 (Toolchain, Approach B, bootstrap layout) → Task 1.
- §2 (Direct unit suite first) → Task 2.
- §3 (Measure before trust, 15s gate) → Task 3.
- §4 (muter config, deterministic output path, --disable-sandbox justification) → Task 4.
- §5 (Baseline doc structure) → Task 6.
- §6 (Survivor triage workflow) → Task 5.
- All 5 acceptance criteria mapped: bootstrap+run (Tasks 1, 4) → AC 1; unit suite (Task 2) → AC 2; ≥80% score (Task 5) → AC 3; every-survivor classification (Tasks 5, 6) → AC 4; warm time recorded (Tasks 3, 6) → AC 5.
- All three risks have mitigation steps: pinned SHA failure (Task 1 Step 3), 80% unreachable (Task 5 Step 3), per-test-run time blow-up (Task 3 Step 3).

**Placeholder scan:** No TBDs. The one templated section is the baseline doc's measurement values (intentional — the implementer fills them in from the actual run, not from a guess). Task 5 Step 4's commit message body has a `<one-line summary>` placeholder, which is also intentional — the implementer summarizes the actual additions.

**Type consistency:** `DepthBiasCalculator`, `DepthBiasCalculatorTests`, `MUTER_SHA`, `MUTER_BIN`, `.muter/depth-bias.json`, `.build/mutation-testing/last-run.json` — names consistent across all tasks.
