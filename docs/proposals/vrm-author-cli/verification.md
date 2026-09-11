<!--
Copyright 2026 Arkavo
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at https://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software distributed
under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied. See the License for the
specific language governing permissions and limitations under the License.
-->

# Verification contract for agent-coordinated implementation

Status: active. This is the primary coordination artifact for the
[authoring proposal](README.md); the [v1](commands.md) and [reserved](reserved.md)
command catalogs consume it. This Markdown file is not itself an oracle. The
executable pieces live under `acceptance/`: the pack schema
[`pack.schema.json`](acceptance/pack.schema.json), the worked `style lint` pack
[`packs/style-lint.json`](acceptance/packs/style-lint.json) and the evidence registry
[`evidence.json`](acceptance/evidence.json). Python-oracle packs run through
[`scripts/acceptance_run.py`](../../../scripts/acceptance_run.py).

## 1. Acceptance before implementation

Every operation, including project CRUD, RPC adapters, template generation, geometry
kernels and each promoted reserved command, requires an executable acceptance pack
**before handler implementation begins**. A wrapper is an implementation too. Contract
and test-harness code may be built first; an untested production algorithm may not be
smuggled into the harness as its own expected result.

Acceptance ownership is separate from implementation ownership. A pack declares:

| Field | Required content |
|---|---|
| Identity | Operation ID/version, request/result schema hashes, target/backends and pack version/hash |
| Provenance | Acceptance author/model family/version, independent reviewer, source references and review receipt |
| Scope | Parameter ranges, supported input classes, invariants, units/spaces and deliberately excluded domains |
| Inputs | Redistributable hashed positive/negative/degenerate fixtures and deterministic seeds |
| Executable oracle | Pinned runner/environment, assertions, numeric tolerances, expected errors and required artifacts |
| Sensitivity controls | Known-bad outputs/mutants the checks must reject; expected classifications fixed in advance |
| Visual/semantic rubric | Required views, motions, semantic landmarks, judging thresholds and adjudication rule, or reviewed nonvisual applicability |
| Evidence policy | Required evidence dimensions and held-out-family policy for this input class |
| Resource policy | CPU/GPU/judge-call limits, per-run deadline, maximum repair attempts and failure behaviour |
| Reproduction | Exact runner entry point, input/output manifest schema and canonical artifact rules |

The pack runs successfully against its declared positive references and rejects known
bad references. A missing handler produces an expected harness failure, not a passing
skip. Before admission, inject failures such as identity/no-op transforms, wrong unit
conversion, discarded morphs, broken eyelids or fabricated report success. Tests that
only compare output to the implementation's own recomputation are insufficient.

Thresholds must be finite, justified and frozen in the actual pack; the proposal's
example categories are not license to defer acceptance criteria until after coding.
A contract change requires a new pack hash, independent review and requalification.
Keep previous results; never rewrite evidence to match the new criteria.

**Minimum viable pack.** A discovery or CRUD pack may declare the visual and corpus
dimensions inapplicable through a reviewed applicability record for each: the visual
dimension through `visual.applicabilityRecord`, the corpus dimension through
`evidencePolicy.corpusApplicabilityRecord`, which is the field the body-independent
carve-out below uses. It must still carry positive, negative and degenerate
fixtures, at least two mutants with fixed expected classifications, and the expected
missing-handler failure (exit code or error class). The field layout is enforced by
[`pack.schema.json`](acceptance/pack.schema.json); `packHash` is the sha256 of the
pack file with `packHash` set to the empty string. A pack whose corpus dimension is
required also carries a `corpus` block naming the manifest, its sha256, the family key,
the expected family count, the tolerance and the eligibility floor, so per-family
denominators and the floor are fixed before the run.

A **body-independent** pack may declare the corpus dimension inapplicable on the same
terms. A pack is body-independent when its input class contains no body geometry, so
partitioning its inputs by body family carries no information; `material shading`, whose
input is a project material object, is the v1 example. The record names the parameter
sweep that covers its input space instead.

## 2. Pinned oracles

The in-tree oracles for the Materials/style class and the corpus dimension are pinned
by content hash; the hashes are the pin, and nothing else about their provenance is one.
The style linter is a single global oracle, shared by every style set. The remaining
oracles are grouped per style set. Packs record the hashes in
`runner.environment.oracleHashes` and the runner refuses a mismatch; the head commit
is reported in the result manifest for provenance and is not itself a check.

| Oracle | Path | sha256 |
|---|---|---|
| Style linter (global) | [`scripts/style_lint.py`](../../../scripts/style_lint.py) | `01679f040546fa76b6c4b8f6c84244388201ad04f0f449157c5ec634716b5881` |

**Style set `vroid-lineage-anime`:**

| Oracle | Path | sha256 |
|---|---|---|
| Profile v0.1.0 | [`docs/style/profiles/vroid-lineage-anime.json`](../../style/profiles/vroid-lineage-anime.json) | `7eeb1f41bada650d39b7c32a31c273bbd889cca22d390164b8a7dd9b1f9c1f35` |
| Corpus manifest | [`docs/style/corpus/vroid-lineage-anime.manifest.json`](../../style/corpus/vroid-lineage-anime.manifest.json) | `b393eb0c8c49050caab772f8bdd6ad884d6dd027ad310249ae9805a22b1a8cb6` |
| Measurements | [`docs/style/corpus/vroid-lineage-anime.measurements.json`](../../style/corpus/vroid-lineage-anime.measurements.json) | `c71ab0f1fbdb268b7eb66e04b18a84a103e8a4649a5d49887560a196a10e35bc` |
| Witnesses, `native-anime-v1` | [`docs/style/corpus/vroid-lineage-anime.witnesses.native-anime-v1.json`](../../style/corpus/vroid-lineage-anime.witnesses.native-anime-v1.json) | `20635cf23e0c2214a49e82c0af269976cc2739d068dad4426eddaf0b72b6e803` |

Witnesses are per template as well as per style set: a second template measured against
the same style adds a witnesses row of its own. A second style adds a group. Family
counts, tolerances and eligibility floors are per style set, never global. A pack may
declare more than one style set only on the `swift-test` path; a `python`-kind pack
declaring two is rejected as invalid rather than measuring the first and discarding
the rest.

The profile content hash is the freeze. `style_lint.py envelopes --write` must not be
run against the pinned profile without bumping the profile version and re-hashing;
a rehash is a contract change under §1 and requalifies every pack that names it.

Runner substrate: Swift packs run as `swift test --filter <PackSuite>` on macOS;
Python-oracle packs run as `python3 scripts/acceptance_run.py <pack.json>`. Both
emit a runner output hash that the evaluator receipt (§7) binds.

## 3. Evidence levels

| Level | Definition |
|---|---|
| `schema-only` | Request/result schema registered and validated; handler may be absent. A missing handler produces an expected harness failure (exit code or error class), never a skip |
| `fixture-tested` | The command's acceptance pack runs green on macOS via its declared runner; positive, negative and degenerate fixtures pass; every declared mutant is rejected |
| `corpus-validated` | Fixture-tested, plus the pack's corpus dimension passes across every eligible body family of the development corpus for each style set the pack declares (§6; 18 families for `vroid-lineage-anime`) with per-family denominators reported; no family may fail |
| `visually-validated` | Corpus-validated where applicable, plus the visual rubric passes under the v1 visual gate (§5) |

A body family is **eligible** for a generative command when the template's directly
invertible controls are set exactly to that family's corresponding measured metrics, and
every remaining target metric's residual is within the pack's `tolerance` multiplied by
that metric's rule range width in the style set's profile. On `native-anime-v1` the
direct pairs are `body.heightM` to `asset.height_m` and `body.headCount` to
`proportions.head_count`; another template declares its own. An ineligible family is
reported with a residual per metric and is neither a pass nor a fail, but a pack's
`minEligibleFamilies` floor must still be met or the dimension fails: "every eligible
family passed" is vacuously true at zero eligible families.

Levels are cumulative over **applicable** dimensions; visual validation cannot leapfrog
a failed fixture or required corpus check. An implemented but untested handler stays
at `schema-only`. A broad level never certifies untested parameter ranges or input
families. `evidenceStatus` is the enum `current | stale | failed | pending` everywhere
it appears (packs, registry, `capabilities`).

## 4. Required evidence per v1 command

Every command in the [v1 allowlist](commands.md) must reach the level below before the
Stage B release. Parenthesised items are fixtures the pack must contain.

| Command | Oracle class | Required level | corpus | visual |
|---|---|---|---|---|
| `version`, `describe`, `capabilities`, `doctor`, `schema show` | Discovery/registry | fixture-tested | n/a | n/a |
| `serve` | RPC/transport | fixture-tested (stale writer, replayed receipt, changed-payload request ID, malformed transport) | n/a | n/a |
| `project init`, `project inspect`, `history list`, `history restore` | Revision/transaction | fixture-tested (atomic rollback, crash/restart replay) | n/a | n/a |
| `template list`, `control list`, `control describe`, `object list`, `object get` | Discovery/registry | fixture-tested | n/a | n/a |
| `object set` | Revision/transaction | fixture-tested | n/a | n/a |
| `control set` | Shape/deformation | visually-validated | required (reach) | required |
| `recipe export` | Import/export/provenance | fixture-tested (round-trip byte identity) | n/a | n/a |
| `recipe apply` | Shape/deformation + provenance | visually-validated (owned by the Shape pack; provenance fixtures included) | required (reach) | required |
| `asset import`, `asset inspect` | Import/export/provenance | fixture-tested + interoperability dimension | n/a | n/a |
| `style attach` | Revision/transaction | fixture-tested | n/a | n/a |
| `style lint` | Materials/style (oracle = pinned `style_lint.py` + profile) | corpus-validated | required | n/a (numeric-only, reviewed applicability) |
| `material shading` | Materials/style | visually-validated | n/a (body-independent, reviewed applicability; covered by a parameter sweep) | required |
| `build` | Compile (Shape + Hair/springs + Materials aggregated) | visually-validated | required (reach) | required |
| `qa plan` | QA machinery | fixture-tested | n/a | n/a |
| `qa run`, `export verify` | QA machinery | fixture-tested via mutant injection (must fail on each declared mutant class: identity transform, wrong units, discarded morphs, broken eyelids, fabricated report) | n/a | n/a |
| `inspection record`, `inspection verify` | Provenance/inspection | fixture-tested (append-only, `uncertain` blocks completion, rebuild ⇒ new evidence) | n/a | n/a |
| `provenance inspect`, `provenance resolve`, `provenance verify` | Import/export/provenance | fixture-tested (missing sidecar, untrusted signer, tampered binding, stale manifest, conflicting rights) | n/a | n/a |
| `export vrm` | Import/export/provenance + consumer matrix | visually-validated + interoperability (every required consumer in the README consumer matrix) | required (reach) | required |
| `deliver` | Delivery | fixture-tested; production-eligible only when every command it invokes is production-eligible | n/a | n/a |

`required (reach)` names the corpus dimension of a generative command: the pack replays
the per-family witnesses of §2 through the template, so only eligible families (§3) are
measured. Plain `required`, which in v1 is `style lint` alone, measures the corpus assets
themselves: no template is solved and no witnesses are replayed, so the §3 eligibility
test does not arise. Every family of the style set is measured and the floor is the full
family count.

None of the four `required (reach)` rows carries corpus evidence for `native-anime-v1`
today. The pinned witnesses report zero of the 18 `vroid-lineage-anime` families eligible
against each pack's floor of one, so the dimension reports `fail`, which is the truthful
result and not a defect of the packs. The template's solved-best eye spacing is about
0.21 of head width, 0.265 at its default, against family targets of 0.13 to 0.17, leaving
16 families unreachable; `alicia-solid` sits at 0.2641, which the default already matches,
and is blocked instead by shoulder width with its control at the rail, and `heroes-alex`
is rejected before the template runs because its height of 1.1764 m is below the
template's 1.2 m floor. Recovering the dimension is a change to the template's eye
spacing relative to head width, not a loosening of any pack's tolerance or floor. Such a
template change regenerates the witnesses, whose hash four packs pin, so it is a contract
change under §1 and requalifies them.

Hair/springs and Garment fit are reached in v1 only through `control set`,
`recipe apply` and `build` on HairItem/OutfitItem; their checks live inside the
control-set and build packs. The operation classes and what their oracles must show
beyond return status:

| Operation class | Required evidence beyond return status |
|---|---|
| Discovery/registry | Every accepted leaf discoverable; schema hashes stable across runs; non-runnable and reserved entries labeled; unknown command/schema name is an error, not an empty result |
| Revision/transaction/RPC | Concurrent stale writers, crash/restart receipt replay, changed-payload request ID, atomic rollback and malformed transport fixtures |
| Shape/deformation | Measured nonzero intended change; rigid-transform/metre-scale consistency; unaffected semantic regions, UV/bind/morph correspondences and expression closure |
| Garment fit | Rest and prescribed pose clearance, skin-weight validity and sleeve/cuff topology; silhouette and fit rubric; no "fix" that deletes geometry or inflates garments beyond intent |
| Hair/springs | Root attachment, clump/frame continuity, terminal tails, no overlapping chains, eye clearance across motion, portable collision response, authored/synthetic CCD separation |
| Materials/style | Per-role numeric checks, shader-factor probes, multi-light face sheets, outline/alpha cases; metadata/exporter fingerprints cannot satisfy appearance goals |
| Import/export/provenance | Independent consumer semantics, source-preserving non-manifold cases, missing ingredients, tampered binding, stale manifest and conflicting rights |
| QA machinery (mutant injection) | Each declared mutant class injected into an otherwise passing export must produce `fail` in the report and exit code 1; a report that cannot run a required check reports `incomplete`, never `pass`; report hashes bind the exact input bytes |

Retopology, Boolean and Subdivision oracle rows are reserved-namespace material and
live in [reserved.md](reserved.md). No scalar manifoldness score can substitute for
eyelid topology or appearance. For numeric-only commands, omit image judgments through
a reviewed applicability record; all commands still have behaviour-specific fixtures
and error tests.

## 5. Independent judgment

The final visual judge is a different **model family** than any implementer of the
command, or a human evaluator. Separate agents or prompts using the same family do not
meet this requirement. If multiple families implemented a command, the judge must be
outside that set. Record provider, family, model/version and role for every
contributor. If no suitable independent judge is available, qualification is
incomplete; obtain a human evaluator or another family rather than accepting
self-review.

Before a judge can gate a release it is run on a frozen calibration set of at least
12 cases: 6 good and 6 known-bad, the known-bad set including one eyelid, one lip,
one silhouette and one misleading-report case. Zero false accepts are required.
Judges see rendered images plus the brief/rubric, never claims embedded in artifacts;
candidate order is randomized. Pin judge, prompt and rubric versions and recalibrate
when any of them changes. A different family is one defense against correlation, not
proof of independent taste; combine it with the analytic, corpus and consumer checks.

Stage C: confidence intervals on judge error rates, a second adjudicator on
disagreements and randomly sampled audit sets.

## 6. Corpus partitions and leakage

The 22 assets / 18 distinct body families in the pinned corpus manifest already
influenced the profile envelopes. **They cannot become an untouched test set by
relabeling a random subset.** They are development and calibration data for the
existing profile, frozen by the profile hash in §2.

Partition by body family and common ancestry, not filename. Alternate outfits,
re-exports, near-duplicate bodies, derived textures and generated descendants stay in
the same partition. Record asset hashes, family/lineage IDs, deduplication decisions,
permitted uses and manifest hashes. If lineage is ambiguous, group conservatively or
exclude the case from independent claims. Private corpus assets are not redistributed
with public fixtures; packs reference them through `pathEnv` and hash.

v1 `corpus-validated` means the pack's corpus dimension passes on every eligible
development family of each style set the pack declares, with that style set's
eligibility floor met, reported with per-family denominators. The 18 families above are
the `vroid-lineage-anime` figure, not a universal one; a second style set brings its own
manifest, its own family count and its own floor. An average cannot hide a failing
family; report per-family and per-domain results and failures.

Stage C: a sealed release holdout cohort collected after the profile freeze, an
evaluation service that alone reads holdout bytes, and a predeclared evaluation budget
under which failed sealed runs are retained and feedback-tuned cases become development
data for the next qualification.

## 7. Evidence records and admission

`capabilities` exposes schema and availability separately from qualification. Its entry
fields, shared with [commands.md](commands.md):

| Field | Meaning |
|---|---|
| `operation`, `schemaHash`, `implementationHash`, `backendHash` | Exact subject; `implementationHash` absent for schema-only entries |
| `availability` | `schema-only` / `implemented` / `unavailable` |
| `evidenceLevel` | Highest admitted level from §3 |
| `evidenceStatus` | `current` / `stale` / `failed` / `pending` |
| `dimensions` | `fixture`, `corpus`, `visual`, `interoperability`, `provenance`, each `applicable` / `pass` / `fail` / `pending` with a `reportHash` |
| `scope` | Tested input families, control ranges, template versions and output targets |
| `acceptancePackHash`, `evaluationPolicyHash` | Frozen criteria and reviewer admission policy |
| `evaluators[]` | Identities/families/versions and review receipts |
| `runnable`, `productionEligible` | Handler availability versus sufficient current evidence for the requested scope |
| `blockers[]`, `artifactRefs[]` | Missing/failed requirements and retrievable evidence |
| `targets`, `templateHashes`, `supportedImports`, `backends`, `renderers`, `signerAvailable` | Non-evidence environment facts |

`describe` returns schemas, units, bounds, dependencies, prerequisites, schema hashes
and the **required** evidence level for the command from §4. It does not return evidence
status; only `capabilities` does. `evidenceLevel` is the highest level ever admitted for
the entry and is historical; `evidenceStatus` says whether that level currently holds.
A newly known regression marks the affected scope `failed` immediately, even if its
level was `visually-validated`. This is enforced before execution and delivery, not
merely displayed in help.

The v1 evaluator is a second agent of a different model family, or a human, running
the pack from a clean checkout at the pinned commit in a scratch project with no access
to the implementer's session. Admission is that evaluator's signed receipt (pack hash,
build hash, runner output hash) recorded in
[`acceptance/evidence.json`](acceptance/evidence.json). A handler cannot write that
file, and cannot promote itself by emitting a level. The evaluator's checkout must
resolve the pack's fixtures (git-tracked fixtures, `--fixtures`, or the pack's
`pathEnv`) and, for a corpus-required pack, the development corpus through the
manifest root; an unresolved fixture or corpus yields `pending` (exit 2), never a pass,
and `corpus-validated` cannot be admitted from it.

Implementation, schema, template, profile, oracle, dependency, judge or rubric changes
invalidate affected evidence through the dependency graph: the entry moves to `stale`
until re-evaluated. MCP `tools/list` exposes only tools runnable under the session's
evidence policy; harness sessions may execute unqualified candidates in isolated
scratch projects. The default production session requires current command-specific
evidence. `capabilities --evidence-policy PATH` reports eligibility under a stricter
caller policy; a caller may narrow scope or raise the required level but cannot weaken
the release policy. Exploration records are never production qualification.

## 8. Target-specific evidence

Split QA into cheap screening, qualified numeric/reference checks, independent consumer
import, and canonical Metal visual/motion passes. Screening rejects bad candidates
before the GPU pass. CPU screening does not certify Metal MToon, transparency, outlines
or GPU spring behaviour; final target-specific evidence runs on the target renderer on
macOS via `swift test`. Work that cannot reach a Metal device may report fixture
results but cannot report a completed visual gate.

Linux CPU workers, a pinned software rasterizer and a CPU spring reference are Stage C:
GLTFCore imports Metal, and SpringBone is compute-only, so none of these references
exist to compare against today. Render fleet scheduling, worker receipts and cross-device
sampling are also Stage C. Wrap-versus-own backend accounting (Manifold, OpenSubdiv,
owned kernels) is reserved-namespace material and lives in [reserved.md](reserved.md).

## 9. Staging

| Stage | Content | Exit criterion |
|---|---|---|
| A0 | Contract corrected; acceptance pack JSON schema; one worked pack (`style lint`) that runs against the in-tree linter via `scripts/acceptance_run.py` and rejects its mutants; `evidence.json` registry format defined | `python3 scripts/acceptance_run.py docs/proposals/vrm-author-cli/acceptance/packs/style-lint.json` passes and `python3 scripts/test_acceptance_run.py` passes |
| A | Packs for the 14 spine commands; registry; `capabilities` emitting `schema-only` entries; every pack fails with the expected missing-handler error | All spine packs admitted at `schema-only` with a green harness |
| B | v1 release; release manifest signed by the evaluator | Every §4 row at its required level with `evidenceStatus = current`; manifest signed with a detached signature file, no signer service |
| C | Reserved, not a v1 gate: Linux CPU references and software rasterizer, CPU spring reference, sealed holdout cohort with evaluation service and budget, judge calibration with confidence intervals and second adjudicator, render fleet, wrap-vs-own accounting, Boolean/Subdivision/Retopology oracles | Each item qualifies independently under §1 |

## 10. Release criterion

A release is a signed manifest of supported operation scopes and **current admitted
evidence** (every §4 row at its required level with `evidenceStatus = current`), plus a
qualified procedural template, the per-family corpus result, the consumer matrix result
and completed unattended delivery sessions. The delivery sessions are run by the
evaluator in harness mode: an isolated scratch project in which unqualified candidates
may execute. Production-mode `deliver` is therefore not a prerequisite of its own
admission. The evaluator signs the manifest with a detached signature file; no signer
service is required.

A command count, code volume, self-reported success or a single linter score cannot
substitute for this manifest. Only operations with admitted acceptance packs are
assigned for implementation. The whole catalog may progress in parallel; verification
readiness and evidence capacity determine what may ship.
