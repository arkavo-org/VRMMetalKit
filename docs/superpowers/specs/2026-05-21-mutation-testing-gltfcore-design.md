# Mutation Testing — First Target: `DepthBiasCalculator` (GLTFCore)

**Status:** Approved — ready for implementation plan
**Issue:** [#282](https://github.com/arkavo-org/VRMMetalKit/issues/282)
**Date:** 2026-05-21

## Problem

Line/branch coverage tells us *which lines run*, not *which lines have assertions
that would catch a regression*. Mutation testing closes that gap by introducing
small syntactic changes (mutants) and asking whether the test suite kills them.
Issue #282 scoped this work; this spec is the first concrete deliverable:
prove the mutation-testing loop on one well-bounded GLTFCore utility before
expanding.

## Goal

Land a reproducible mutation-testing workflow targeting
`Sources/GLTFCore/Utilities/DepthBiasCalculator.swift` (253 LOC, pure math, no
I/O) backed by a direct unit suite, and produce a durable baseline document
that records mutation score, per-mutant classification, and a per-test-run
performance measurement.

## Non-Goals

- Other GLTFCore files (`OrthographicCamera`, `GLTFError`, `GLTFLogger`, the
  loaders) — separate follow-up issues.
- Other modules (`Animation/`, `Renderer/`, shaders).
- CI integration. Local-only first; CI is a future decision once we know the
  cost.
- Custom muter operator sets. Defaults until we have evidence to revisit.
- Automated equivalent-mutant detection.

## Design

### 1. Toolchain — muter built from a pinned SHA

`muter` is the only mature Swift mutation-testing tool. Its last tagged release
is from 2023 (tag `16`); the project remains actively committed-to on `master`
(most recent commit at writing: `99624ec` on 2026-04-27, fixing memory
exhaustion on large codebases). Homebrew's package would install the 2023
tag, which is unlikely to parse Swift 6.2 source. We therefore install from
source at a pinned SHA. Approach B from brainstorming.

**Layout under `.build/tools/`** (the entire `.build/` tree is already
gitignored, so no new `.gitignore` rules needed):

```
.build/tools/
  muter-src/          # git clone @ pinned SHA
  bin/muter           # symlink to muter-src/.build/release/muter
```

**Makefile additions:**

```makefile
MUTER_SHA := 99624ecfde93dac3cc1f7a66ac6f7df05611091d
MUTER_BIN := .build/tools/bin/muter

$(MUTER_BIN):
	@mkdir -p .build/tools
	@if [ ! -d .build/tools/muter-src ]; then \
		git clone https://github.com/muter-mutation-testing/muter.git .build/tools/muter-src; \
	fi
	@cd .build/tools/muter-src && git fetch && git checkout $(MUTER_SHA)
	@cd .build/tools/muter-src && swift build -c release
	@mkdir -p .build/tools/bin
	@ln -sf ../muter-src/.build/release/muter $(MUTER_BIN)

muter-bootstrap: $(MUTER_BIN)
	@$(MUTER_BIN) --version

mutation-test: $(MUTER_BIN)
	@$(MUTER_BIN) run --configuration .muter/depth-bias.json
```

**Bumping the pinned SHA:** edit `MUTER_SHA`, remove `.build/tools/muter-src`,
re-run `make muter-bootstrap`. This procedure is mirrored in the baseline doc.

**SHA selection criterion at implementation time:** the implementer verifies
the candidate SHA (`99624ec` or the latest at that moment) builds locally with
the host's Swift 6.2 toolchain *before* committing it to the Makefile. If it
fails to build, fall back to the most recent ancestor that does.

### 2. Direct Unit Suite — Written Before muter Runs

`DepthBiasCalculator` is currently exercised only incidentally by
`Tests/VRMMetalKitTests/HipSkirtTests.swift`, which is a behavioral suite for
the hip-skirt simulation that happens to call into the calculator. Pointing
muter at an integration suite would dominate the report with arithmetic and
boundary survivors the integration tests genuinely cannot distinguish — the
classic failure mode that makes teams abandon mutation testing.

**New file: `Tests/VRMMetalKitTests/DepthBiasCalculatorTests.swift`** with direct
oracle tests on the calculator's public surface:
- Known-input / expected-output pairs for the core calculation paths.
- Boundary cases (zero, negative, very-large scale values).
- Mode/configuration variants exposed by the calculator's API.

Why this lives in `VRMMetalKitTests` (not a new `GLTFCoreTests` target):
`Tests/VRMMetalKitTests/GLTFParserStateTests.swift` already sets the precedent
for GLTFCore unit tests living under `VRMMetalKitTests`. Adding a new target is
out of scope.

muter targets only this new file's suite; `HipSkirtTests` is untouched and is
not part of the mutation oracle.

### 3. Measure Before Trusting Estimates

Before kicking off the first muter run, the implementer times one
`swift test --filter DepthBiasCalculatorTests --disable-sandbox` invocation
cold-cache and warm-cache. The warm time is recorded in the baseline doc and
used to sanity-check total mutation-run cost. **Acceptance gate:** if warm
time exceeds 15 seconds per invocation, stop and revisit (operator set,
test selection, or whether mutation testing here is cost-justified) before
committing to the loop.

### 4. muter Configuration

One file: `.muter/depth-bias.json`. Schema follows muter's documented format.
Required fields:

- `executable`: path to `swift` (or `xcrun swift` if needed by muter to locate
  the SDK; implementer determines empirically).
- `arguments`: `["test", "--filter", "DepthBiasCalculatorTests", "--disable-sandbox"]`.
  The `--disable-sandbox` flag is required because the project's tests need
  filesystem access for fixtures (per CLAUDE.md convention); muter additionally
  needs FS write access to perform source rewrites.
- `mutate_files`: glob matching `Sources/GLTFCore/Utilities/DepthBiasCalculator.swift`.
- `exclude_files`: empty.
- Output: JSON report at `.build/mutation-testing/last-run.json` — a
  deterministic path so a future CI run can publish the artifact without
  needing further changes.

Default operator set is used; tuning is a follow-up only if results justify it.

### 5. Baseline Document — Durable, Not a Snapshot

**File:** `docs/mutation-testing/depthbiascalculator-baseline.md`.

**Required sections:**
- Pinned muter SHA + bump instructions (mirror of §1).
- Per-test-run time (warm), measured at run time.
- Total mutation-test wall time observed.
- Overall mutation score: `killed / (total - equivalent)` and the raw counts.
- **Survivors table:** every surviving mutant listed with:
  - file:line
  - mutation operator
  - mutated code snippet (before / after)
  - classification: `kill-pending` (real gap, fix later), `equivalent`
    (semantically identical), `accepted-gap` (real gap, deliberately
    not fixed yet — rationale required)
  - one-line rationale
- Date of last run.

No raw muter report is committed (the JSON at `.build/mutation-testing/last-run.json`
is gitignored via the `.build/` rule). The committed Markdown is the only
durable artifact.

### 6. Survivor Triage Pass

After the first muter run produces a baseline, the implementer:
1. Reads through every survivor.
2. Writes additional test cases in `DepthBiasCalculatorTests.swift` to kill
   the highest-value real gaps (target: score climbs to ≥80%).
3. Classifies remaining survivors as `equivalent` or `accepted-gap` with
   rationale.
4. Re-runs muter and updates the baseline doc with the final score and
   classification.

The plan should treat steps 1–4 as one task block — the loop only closes when
the doc is published with a non-trivial number of `kill-pending` mutants
actually killed.

## Acceptance Criteria

1. `make muter-bootstrap && make mutation-test` runs cleanly on a fresh
   checkout. (`make muter-bootstrap` builds muter; `make mutation-test`
   produces the JSON report.)
2. A new unit suite `Tests/VRMMetalKitTests/DepthBiasCalculatorTests.swift`
   exists with direct oracle tests on `DepthBiasCalculator`.
3. The unit suite achieves a mutation score of **≥80%** on
   `DepthBiasCalculator.swift`.
4. **Every** surviving mutant in the final run has a classification
   (`kill-pending` / `equivalent` / `accepted-gap`) and a one-line rationale
   in the baseline doc — no unclassified survivors.
5. Per-test-run warm time recorded in the baseline doc.

If criterion 3 (80%) is not achievable for legitimate reasons (e.g., the
calculator has inherent equivalent-mutant surface like `*1.0` casts that bend
the score down), document why in the baseline doc and propose a revised bar in
a follow-up issue. Do **not** gold-plate tests just to hit the number.

## Risks

- **Pinned muter SHA fails to build under Swift 6.2.** Mitigation: implementer
  verifies the SHA builds locally before committing it; falls back to the most
  recent ancestor that does. The Makefile uses a single `MUTER_SHA` variable
  so the bump is one line.
- **`DepthBiasCalculator` has inherent equivalent-mutant surface that puts
  ≥80% out of reach.** Mitigation: acceptance criterion 3 has the documented
  escape hatch above. The baseline doc captures *why* and proposes a revised
  bar.
- **Per-test-run time blows up.** Mitigation: the measure-before-trust step
  (§3) catches this before the implementer commits to the loop.
- **muter's JSON schema changes between SHA bumps.** Mitigation: the baseline
  doc is Markdown, written by hand from whatever muter outputs. We do not
  parse muter's JSON in any committed code.

## Out of Scope

- Other GLTFCore files (own follow-up issues).
- Other modules.
- CI integration.
- Custom operator sets.
- Automated equivalent-mutant detection.
- A `GLTFCoreTests` SPM target (precedent says GLTFCore tests live under
  `VRMMetalKitTests`).
