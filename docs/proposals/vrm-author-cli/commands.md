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

# V1 command contract

Part of the [proposal](README.md). All commands are proposed, not implemented.
This is the complete **Stage B release allowlist**. Stage A defines the entire
registry and each operation's executable acceptance pack before handler assignment;
see the primary [verification contract](verification.md), whose staging section
defines Stage A0, A and B. The table's `spine` entries
form the end-to-end integration scenario; `release` entries complete v1. These labels
are not an implementation ordering. Advanced schemas live in the
[reserved namespace](reserved.md) and qualify independently.

## Invocation and discovery

`vrm-author <command> --project PATH --request JSON_PATH|- [named arguments]`

Table fields use `!` for required and `?` for optional. Unmarked defaults are stated
explicitly in [parameters.md](parameters.md). JSON keys use camelCase; scalar CLI
aliases use kebab-case. Nested values are always available through `--request`.
A key supplied in both JSON and flags is an error. Unknown fields, invalid IDs,
nonfinite values, incompatible combinations and unsupported flags are errors.
No shell, Python, templates or imported instructions are evaluated.

`describe [COMMAND]` returns request/result schemas, examples, units, validity and
recommended bounds, defaults, dependencies, capability prerequisites, schema hashes
and the command's *required* evidence level; it does not return evidence status.
Every accepted leaf is discoverable. `describe` includes registered schema-only
operations, explicitly marked non-runnable, within the selected namespace.
`capabilities` returns one entry per operation with the fields defined in
[verification.md](verification.md): `operation`, `schemaHash`, `implementationHash`
(absent for schema-only), `backendHash`, `availability`
(`schema-only|implemented|unavailable`), `evidenceLevel`, `evidenceStatus`
(`current|stale|failed|pending`), `dimensions` (`fixture`, `corpus`, `visual`,
`interoperability`, `provenance`, each `applicable|pass|fail|pending` with a
`reportHash`), `scope`, `acceptancePackHash`, `evaluationPolicyHash`, `evaluators[]`,
`runnable`, `productionEligible`, `blockers[]` and `artifactRefs[]`, together with the
non-evidence fields `targets`, `templateHashes`, `supportedImports`, `backends`,
`renderers` and `signerAvailable`.
An implemented handler is not automatically production-eligible. The default production
policy requires current, admitted evidence appropriate to each operation and input scope.
`--evidence-policy PATH` can impose stricter requirements; it cannot weaken release gates.
`--namespace reserved` exposes registered advanced schemas and their actual evidence,
including schema-only entries. It never turns a schema into a callable implementation.
MCP tool discovery filters to the session's admitted runnable tools.

## Common fields and results

| Field | Type / default | Contract |
|---|---|---|
| `project` | path, required for project-bound operations | No implicit current project |
| `requestId` | string; optional reads, generated writes | Persisted idempotency key, returned to caller; reuse for retry |
| `expectedRevision` | nonnegative integer; required for RPC mutations | Compare-and-swap; CLI resolves current revision if omitted and reports it |
| `dryRun` | boolean=false | Exact edit plan and invalidations without mutation |
| `expectedPlanHash` | SHA-256? | Apply only the inspected plan on its stated base revision |
| `out` | path, required in rows below | Atomic file/directory result; existing output fails unless replace |
| `replace` | boolean=false | Explicit atomic replacement, without deleting project history |
| `format` | `json` | Structured stdout only; errors/logs on stderr where appropriate |
| `timeoutSeconds` | positive number=300 | Deadline; failed mutation leaves project unchanged |
| `maxMemoryMb` | positive integer=4096 | Resource bound; fail before corrupting state |
| `threads` | positive integer=1 | Independent work only; does not change strict output bytes |
| `logLevel` | error/warn/info/debug=warn | Stderr logging |

These fields apply only where meaningful; generated command schemas enumerate them.
V1 has no `async` or multi-request `transaction` flag. Commands are synchronous and
bounded; a long render can be delegated to a configured worker within that deadline.
Future async implementations must preserve the progress/cancel/resume guarantees in
the proposal's [agent interaction contract](README.md#4-agent-interaction-contract).

Every application result carries `protocol=vrmauthor/1`, `requestId`, `status`,
`revisionBefore`, `revisionAfter`, `artifacts[]`, `warnings[]` and `errors[]`; reads use
the same revision twice and project-free operations use null revisions. An artifact
has `path`, `sha256`, `mediaType`, `sizeBytes`, `role` and applicable `buildHash`.
Plans add `planHash`, exact edits, invalidations, prerequisites and cost estimates.
Errors have `code`, object/path, observed/required values, message, suggested supported
commands and optional evidence references. Request receipts and revisions commit
atomically; restart and repeated delivery requests must not duplicate edits/signatures.

Exit codes: 0 successful operation or conforming/conforming-with-warnings lint;
1 completed evaluation with failed required gates (including style `must` failures);
2 invalid request; 3 missing capability/input/credential; 4 revision/idempotency/plan
conflict; 5 internal error. Reports preserve `pass|fail|incomplete|notApplicable` per
check. Required unavailable checks are incomplete, never successful skips.

## Command allowlist

Common fields above are omitted from the rows. `Request` types are defined in the
parameter catalog; all operations also return the common result envelope.

| Command | Use | Operation arguments | Result |
|---|---|---|---|
| `version` | spine | none | Tool/protocol/ABI versions |
| `describe` | spine | `command:string?`, `namespace:v1\|reserved=v1` | Registered schemas, including non-runnable candidates, and each command's required evidence level |
| `capabilities` | spine | `target:portable-vrm1=portable-vrm1`, `evidencePolicy:path?` | Scoped availability/evidence manifest |
| `doctor` | release | none | CPU/backend/renderer/signer/dependency diagnostics |
| `schema show` | spine | `name:string!` | Registered schema, content hash and applicability |
| `serve` | release | `stdio:true!`, `protocol:jsonrpc\|mcp=jsonrpc` | JSON-RPC 2.0 session; MCP adapter negotiates version |
| `project init` | spine | `dir:path!`, `template:ID!`, `seed:uint53=0` | New revision 0 and resolved prototype/production recipe |
| `project inspect` | spine | none | Revision, dependency state, input lock and draft/completion status |
| `history list` | release | `limit:int[1,1000]=100` | Revisions and receipts |
| `history restore` | release | `revision:int!` | New revision restoring that state |
| `template list` | spine | `category:avatar\|hair\|outfit\|accessory?` | Installed packs/items with hashes and control schemas |
| `recipe export` | spine | `resolved:bool=true`, `out:path!` | Canonical complete Recipe, including pack defaults |
| `recipe apply` | spine | `Recipe!` | Materialized dependency graph and invalidations |
| `control list` | release | `object:ID?` | Available controls for this template/object |
| `control describe` | release | `key:string!`, `object:ID!` | Complete descriptor, endpoints, units and dependencies |
| `control set` | release | `ControlEdit!` | Calibrated source edits and invalidations |
| `object list` | release | `kind:ObjectKind?` | IDs, types, editable field paths and revisions |
| `object get` | release | `id:ID!` | Typed object and provenance |
| `object set` | release | `ObjectEdit!` | Atomic edits to existing supported object fields |
| `asset import` | release | `AssetImport!` | Hashed source, preservation report and ingredient ledger entry |
| `asset inspect` | release | `id:ID!` | Geometry/texture facts, extension coverage and credential status |
| `style attach` | spine | `profile:Blob!` | Pinned profile; pack material roles retained |
| `style lint` | spine | `file:path!`, `profile:Blob?` | Profile linter JSON and must-fail exit semantics |
| `material shading` | release | `material:ID!`, `shadowEnd:number!`, `terminatorWidth:number[0,2]!` | Derived MToon factors, or error if factors out of legal bounds |
| `build` | spine | `target:portable-vrm1=portable-vrm1`, `backend:portable-strict/1=portable-strict/1`, `out:path!` | Unsigned draft VRM, build hash and ID map |
| `qa plan` | release | `suite:spec+style\|authoring-v1!`, `file:path!`, `out:path!` | Required scenarios, locked thresholds, renderer and consumers for a v1 QA suite |
| `qa run` | spine | `QARequest!`, `out:path!` | Findings, observations and hashed evidence; acceptance runs require an isolated evaluator session |
| `inspection record` | release | `Inspection!` | Append-only artifact inspection attestation |
| `inspection verify` | release | `report:path!` | Missing/stale/failed inspection coverage |
| `provenance inspect` | release | `asset:ID?`, `file:path?` | Ingredient graph and separate binding/signature/trust results |
| `provenance resolve` | release | `declaration:RightsDeclaration!` | Source-linked VRM metadata and rights conflicts |
| `provenance verify` | release | `file:path!`, `manifest:path!`, `trustPolicy:Blob!` | Credential validation and asset binding report |
| `export vrm` | spine | `target:portable-vrm1=portable-vrm1`, `out:path!` | Final unsigned bytes and loss/metadata report; unresolved mandatory metadata fails |
| `export verify` | release | `file:path!`, `suite:authoring-v1=authoring-v1`, `out:path!` | Checks on the exact export under the `authoring-v1` suite, including consumer import and visual evidence |
| `deliver` | release | `file:path!`, `report:path!`, `signer:string!`, `trustPolicy:Blob!`, `out:path!` | VRM, C2PA sidecar/ingredients, editable project, lock, QA and inspections |

`provenance inspect` takes exactly one of asset/file, or neither for the project ledger.
`recipe apply` invokes the same rights resolver as `provenance resolve`; it cannot bypass
metadata attribution or conflict detection. `spec+style` and `authoring-v1` are the v1
QA suite names accepted by `qa plan`, `qa run` and `export verify`.

### Required evidence

The per-command required-evidence table in [verification.md §4](verification.md) is canonical; this
table mirrors it for the 35 commands above.

| Required level | Commands | Pack requirements |
|---|---|---|
| fixture-tested | `version`, `describe`, `capabilities`, `doctor`, `schema show`, `template list`, `control list`, `control describe`, `object list`, `object get` | Discovery/registry fixtures |
| fixture-tested | `project init`, `project inspect`, `history list`, `history restore`, `object set`, `style attach` | Revision/transaction fixtures: atomic rollback, crash/restart replay |
| fixture-tested | `serve` | Transport fixtures: stale writer, replayed receipt, changed-payload request ID, malformed transport |
| fixture-tested | `recipe export`, `provenance inspect`, `provenance resolve`, `provenance verify` | Round-trip byte identity; missing sidecar, untrusted signer, tampered binding, stale manifest, conflicting rights |
| fixture-tested + interoperability | `asset import`, `asset inspect` | Import fixtures plus the interoperability dimension |
| fixture-tested | `qa plan`, `qa run`, `export verify` | `qa run` and `export verify` must fail on each declared mutant class: identity transform, wrong units, discarded morphs, broken eyelids, fabricated report |
| fixture-tested | `inspection record`, `inspection verify` | Append-only records; `uncertain` blocks completion; rebuild requires new evidence |
| fixture-tested | `deliver` | Production-eligible only when every command it invokes is production-eligible |
| corpus-validated | `style lint` | Oracle is the pinned `style_lint.py` and profile; corpus dimension across every eligible development body family; visual dimension not applicable |
| visually-validated | `control set`, `recipe apply`, `material shading`, `build`, `export vrm` | Corpus and visual dimensions required; `recipe apply` is owned by the Shape pack with provenance fixtures included; `export vrm` also requires the interoperability dimension across every required consumer |

`object set` is typed field access, not an arbitrary JSON patch bypass. It cannot
rewrite history, IDs, credentials, unknown extensions or derived geometry. Geometry
imports preserve original soup and glTF data; imported avatars may be inspected and
have supported material/metadata/binding fields edited, but do not acquire the native
parametric controls. An import loss report is required before any conversion.

V1 control editing covers hair, clothing, accessories, texture layers, expressions,
gaze and spring joints through the typed objects below; separate verb families are
unnecessary. Recipe arrays instantiate only installed pack items. No arbitrary mesh,
strand solver, garment-pattern editor or repair optimizer is required in v1.

`deliver` requires a report for the exact unsigned file and matching inspection records.
It resolves the ingredient ledger, signs the frozen bytes through the configured
credential reference, validates the sidecar, and atomically writes the bundle. A
missing signer/trust policy or failed required check returns incomplete/failure without
claiming delivery success. A failed signing attempt never alters the original VRM.
