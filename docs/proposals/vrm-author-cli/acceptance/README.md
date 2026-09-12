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

# Acceptance packs

An **acceptance pack** is one JSON file per catalog operation, frozen by its `packHash`
(sha256 of the canonical JSON — sorted keys, `,`/`:` separators, ASCII — with `packHash` set
to `""`). It pins the oracle files by sha256 and commit, declares positive/negative/degenerate
fixtures with expected results, the mutants the oracle must reject, the required evidence
level, and how to reproduce the run. `pack.schema.json` is the format; `packs/style-lint.json`
is the worked example that runs against the in-tree linter today. Small synthetic fixtures live
in `fixtures/`; gitignored avatars are found via `--fixtures DIR`, the fixture's `pathEnv`
variable (`VRM_ACCEPTANCE_FIXTURES`), or the repository root, as `make style-lint` does.

```bash
python3 scripts/acceptance_run.py docs/proposals/vrm-author-cli/acceptance/packs/style-lint.json          # summary
python3 scripts/acceptance_run.py docs/proposals/vrm-author-cli/acceptance/packs/style-lint.json --json   # result manifest
python3 scripts/test_acceptance_run.py                                                                    # runner tests
```

The runner validates the pack, verifies `packHash`, refuses to run when a pinned oracle file
differs from the working tree, grades every fixture, requires every mutant to be rejected (a
mutant indistinguishable from its baseline fails the pack), and lints the development corpus
per body family when the corpus dimension is required. An absent fixture or corpus asset is
reported as `pending`, never as a pass.

Swift packs (`runner.kind: swift-test`) name the XCTest suite that covers the command; the
runner executes `swift test --disable-sandbox --filter <suite>` (plus a `--filter` for every
mutant `suite` override), grades fixtures from the suite's test-case results and requires each
`swift-test` mutant's named test to run and pass. Their fixtures are `synthetic` (built
in-process by the suite, no bytes to pin) unless a git-tracked file is pinned by sha256.
`swift test --build-tests` once before running them; a cold test build eats the deadline.

## Pack index

| Pack | Entry point | Required level |
|---|---|---|
| `version`, `describe`, `capabilities`, `doctor`, `schema-show` | `DiscoveryPackTests` | fixture-tested |
| `serve` | `ServePackTests` (+ `MCPClientTests`) | fixture-tested |
| `project-init`, `project-inspect`, `history-list`, `history-restore` | `ProjectPackTests` | fixture-tested |
| `template-list` | `TemplateListPackTests` | fixture-tested |
| `recipe-export` | `ExportPackTests` | fixture-tested |
| `recipe-apply`, `build`, `export-vrm` | `ExportPackTests` (+ `QAMutantInjectionTests`, `WearableHairTests`, `TemplatePackTests`) | visually-validated |
| `control-list`, `control-describe` | `ControlPackTests` | fixture-tested |
| `control-set` | `ControlPackTests` (+ `ProjectPackTests`, `NativeAnimeGeometryTests`, `WearableOutfitTests`, `WearableHairTests`) | visually-validated |
| `object-list`, `object-get`, `object-set` | `ObjectPackTests` | fixture-tested |
| `asset-import`, `asset-inspect` | `ProvenancePackTests` | fixture-tested + interoperability |
| `provenance-inspect`, `provenance-resolve`, `provenance-verify` | `ProvenancePackTests` | fixture-tested |
| `style-attach` | `MaterialsPackTests` | fixture-tested |
| `style-lint` | `scripts/style_lint.py` (python) | corpus-validated |
| `material-shading` | `MaterialsPackTests` | visually-validated |
| `qa-plan`, `inspection-record`, `inspection-verify` | `QAPackTests` | fixture-tested |
| `qa-run`, `export-verify` | `QAPackTests` (+ `QAMutantInjectionTests`) | fixture-tested (mutant injection) |
| `deliver` | `DeliverPackTests` | fixture-tested |

The runner resolves the `fixture`, `provenance` and `corpus` dimensions for Swift packs, the
last by replaying the pack's pinned witnesses through the shipped CLI and linting each emitted
artifact; a pack whose policy also requires `visual` or `interoperability` reports `pending`
(exit 2) until those gates exist, never a pass.

`evidence.json` is the evidence registry, written only by the evaluator (a different model
family or a human running the pack from a clean checkout at `pinnedCommit`), who records the
pack hash, build hash and result hash of the run they witnessed. Handlers and pack authors never
write it; an empty `entries` list means nothing has been admitted yet.

Exit codes: `0` pass, `1` fail, `2` pending, `3` missing-handler (entry point absent, the
expected outcome for a schema-only operation), `4` pack invalid.
