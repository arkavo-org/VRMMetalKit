# Corpus evidence path for swift-test acceptance packs

Date: 2026-09-11. Branch: `vrm-author-cli`. Status: design approved, spec under review.

## 1. Problem

Five packs declare `evidencePolicy.dimensions.corpus = required`: `build`,
`control-set`, `export-vrm`, `material-shading` and `recipe-apply`. All five use the
`swift-test` runner. `scripts/acceptance_run.py` invokes `run_corpus` only on the
`python` path, and `run_corpus` reaches its oracle only through `run_lint`, which
requires `runner.profile` — a field the pack schema permits on python packs alone.
The five therefore report `corpus: pending` unconditionally and can never reach
`corpus-validated`.

Two further defects sit behind that:

- `build.json` declares `corpus: required` while its `scope.excluded` lists
  `"corpus-wide builds"`. The pack contradicts itself.
- Their `corpus` blocks are byte-identical copies of `style-lint.json`'s. Re-linting
  the corpus with the profile that was fitted to it measures the linter's calibration
  error, which `style-lint`'s own pack already certifies. It would also pass with no
  handler installed, which §1 of the verification contract forbids as a passing skip.

## 2. What the corpus dimension claims for a generative command

verification.md §6 partitions the corpus by common ancestry, not filename. Everything
`native-anime-v1` emits shares one ancestry, so the operation's *output* cannot be
eighteen families. The family is therefore the **target**, not the output, and the
claim a generative command supports against the corpus is coverage:

> The template's control space reaches each body family's measured proportions, and the
> operation's output stays inside the profile's distribution at every reachable point.

This yields a real per-family denominator without relabelling one lineage as a test
set. A family the 44 controls cannot reach is **ineligible**, reported per family with
its residuals, never counted as a pass and never fudged. A low eligible count is a
finding about the template, which is what the corpus should be able to tell us.

## 3. Artifacts

### 3.1 Targets file

`docs/style/corpus/vroid-lineage-anime.targets.json`. Derived numbers, not bytes, so it
is redistributable in-tree even though the corpus assets are private and gitignored.

One representative asset per family:

1. Prefer an asset whose manifest entry carries no `note` (notes mark re-exports,
   re-dresses and constraint samples).
2. Among those, prefer a VRM 1.0 export over a VRM 0.x export.
3. Break any remaining tie by manifest order, which is fixed by the manifest hash.

Three of the eighteen families carry alternates today: `sample-A` (a VRM 0.x re-export),
`sample-V` (a re-dressed body) and `vroid-v110-female` (two un-noted assets plus a pixiv
constraint sample, resolved by rule 3).

Per family the file records the representative's path and sha256, its metric vector from
the pinned linter, and the alternates' per-metric deltas as a sanity field. Provenance
records the style linter hash, the profile hash, the manifest hash and the exact
generation command.

The metric vector is the target coordinates only. It excludes
`proportions.rest_pose_arm_horizontal_cos` and `proportions.limb_asymmetry`, which are
one-sided pose and symmetry invariants rather than body-shape coordinates.

### 3.2 Witnesses file

`docs/style/corpus/vroid-lineage-anime.witnesses.json`, hash-pinned alongside the
targets.

Per family: the solved control values, the per-metric residual, the `eligible` flag, the
solver budget and seed, and the sha256 of the template manifest it was solved against.

The solver must be a bounded deterministic search: a fixed iteration budget and a fixed
seed, no wall-clock or thread-count dependence, so re-running it on the same template
hash reproduces the file byte for byte.

The solver is a **generator**, run once per template hash and off the critical path. The
four packs **replay** a witness rather than solving. This takes solver determinism out
of four packs and delivers approach A's deduplication without cross-pack citation
plumbing.

A hand-edited witness cannot fake reach, because the pass criterion remains the pinned
linter's metrics on the operation's output measured against the corpus-derived targets.
A template manifest hash change invalidates the file and forces a re-solve.

## 4. Pack schema changes

The `corpus` block gains three fields:

| Field | Type | Meaning |
|---|---|---|
| `driver` | string | XCTest suite that replays the witnesses and emits per-family records. Required when `runner.kind` is `swift-test`. |
| `tolerance` | number | One fraction, applied to every target metric against that metric's own rule range width, inside which a residual counts as reached. Frozen in the pack, not in the suite. |
| `minEligibleFamilies` | integer ≥ 1 | Floor below which the dimension is `fail`, never `pass`. |

`witnesses` and `targets` paths with their sha256 join `manifest`/`sha256` in the block,
and both go into `runner.environment.oracleHashes` so the runner refuses a mismatch.

**Deviation from the stated tolerance scale, for review.** The instruction was to express
tolerance as a fraction of each must-rule's range width. Only two target metrics are
`must` rules with two-sided ranges: `proportions.eye_height_ratio` (width 0.12) and
`proportions.hips_height_ratio` (width 0.12). The other twelve are `should` or `may`.
This spec therefore scales each metric's tolerance by **that metric's own rule range
width regardless of severity**, which preserves the intent of using the one
corpus-derived scale available while covering every target coordinate. Range widths run
from 0.05 (`proportions.ipd_m`) to 3.5 (`proportions.head_count`), so a single absolute
tolerance would be meaningless across them.

## 5. Runner changes

A `run_corpus_swift` path in `scripts/acceptance_run.py`, selected when the pack's
runner kind is `swift-test` and the corpus dimension is required.

1. Verify the manifest, targets and witnesses hashes against the pack. A mismatch is
   `fail` before anything runs.
2. Invoke the `corpus.driver` suite. The suite replays each witness, runs the pack's
   operation, and writes one artifact per eligible family to a temp directory plus a
   per-family record. Every pack emits a measurable artifact: `control-set` and
   `recipe-apply` compile and export the avatar their witness produces, because the
   metric vector is only observable on exported bytes.
3. Lint each emitted artifact with the pinned linter and profile. The oracle stays in
   Python where it already lives, so the suite never grades itself.
4. Roll up per family.

The roll-up gains an `ineligible` status distinct from `fail` and `pending`. Per-family
records carry a **residual per metric**, not a boolean, so an ineligible family is
attributable to a named metric rather than to "the solver".

Dimension status:

| Condition | Status |
|---|---|
| Eligible families < `minEligibleFamilies` | `fail` |
| Any eligible family fails its assertions or lints non-conforming | `fail` |
| Targets, witnesses or a required artifact absent | `pending` |
| Every eligible family passes and the floor is met | `pass` |

## 6. Eligibility, written down

A family is eligible when:

- `body.heightM` is set exactly to the family's `asset.height_m`, and `body.headCount`
  exactly to its `proportions.head_count`. These two invert one-to-one.
- Every remaining target metric's residual is within `tolerance × range_width` for that
  metric, using the nine normalized `[-1, 1]` controls, which have no analytic inverse
  and are solved numerically.

Otherwise the family is ineligible, recorded with its residuals.

## 7. Per-pack assertions

| Pack | Per eligible family |
|---|---|
| `control-set` | The witness's control values apply and compile; the resulting metrics match the target within tolerance. Proves reach. |
| `recipe-apply` | The same reach through the recipe path rather than direct control edits. |
| `build` | Build succeeds, artifacts and spec validation pass, output lints conforming. |
| `export-vrm` | The linter's metric vector on the exported bytes **equals** the vector on the build draft from the same witness replay, both GLB, exact equality given byte-determinism; and the export lints conforming. Consumer coverage stays in the interoperability dimension and is not counted twice. |

`build.json`'s `scope.excluded` entry `"corpus-wide builds"` is removed, resolving the
contradiction.

## 8. Material shading carve-out

`material shading` is body-independent by its own declaration: its `scope.inputClasses`
is "project material object with MToon fields". Partitioning it by body family is
pseudo-precision.

Its corpus dimension becomes `inapplicable` with a reviewed applicability record, and it
gains a fixture sweep instead: `shadowEnd` and `terminatorWidth` at their range extremes
plus the `(-1, 0)` edge, across the thirteen role defaults, linted per role.

## 9. Contract edits

These are wider than the §4 table rows.

- **§1** permits a corpus-inapplicable applicability record only for a "discovery or
  CRUD" pack. `material shading` is neither, so its record is out of policy until §1
  gains a **body-independent** class. The runner does not enforce this clause; it is
  prose the independent reviewer applies.
- **§2** gains two oracle rows, the targets file and the witnesses file, with their
  hashes.
- **§3** gains the written definition of "eligible" from section 6 above.
- **§4** rows for the five commands are updated to match.
- Five packs re-pinned. `packHash` changes for all of them.

## 10. Sequencing and scope

Approach B with witnesses lands the targets artifact, the witnesses artifact, the
`driver` field, the runner path and eligibility reporting.

Approach A, a single shared eighteen-family sweep cited by four packs, is **deferred**.
The witnesses file already removes the duplicated solve, which was A's main saving. The
decision on A waits until the first witnesses file reports how many of the eighteen
families the template reaches. If reach is low, A is moot and the finding is about the
template.

Out of scope: Stage C holdout cohorts, the visual dimension, any change to the profile
or its envelopes, and redistribution of corpus bytes.

## 11. Testing

- `scripts/test_acceptance_run.py` gains cases for the new path: hash mismatch on
  targets or witnesses is `fail`; eligible count below the floor is `fail`, not `pass`;
  an ineligible family is neither a pass nor a fail; a missing artifact is `pending`.
- The generator is exercised on the in-tree corpus and its output committed, so the
  witnesses file is reproducible from the pinned inputs.
- Every affected pack runs green or reports an honest non-pass through
  `scripts/acceptance_run.py`.
- `swift test --filter VRMAuthorKitTests --disable-sandbox` stays green.
