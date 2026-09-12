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

# MCP authoring loop: facade tools, starter recipes, QA images

Date: 2026-09-12. Branch: `vrm-author-cli`. Status: design, awaiting review.

## 1. Goal

Give an MCP client the loop in README §5 (brief → Recipe → build → QA
artifacts → bounded repair) through a handful of tools whose results the model
can read and, for QA, *see*. The 35 CLI commands stay exactly as they are and
remain reachable 1:1 over `serve --stdio --protocol jsonrpc`. MCP stops being a
mechanical 1:1 projection of that registry and becomes a short facade over the
same handlers.

Non-goals (unchanged from the approved design): `.vroid` import, promoting
reserved sliders, duplicating acceptance packs, a GUI "Male/Female" product,
and filling production `tools/list` by forging evidence. Evidence admission
still belongs to the independent evaluator.

## 2. Current state (measured 2026-09-12)

- `ServeSession` (`Sources/VRMAuthorKit/Serve/ServeSession.swift`) exposes one
  MCP tool per runnable registry operation, gated by evidence policy; harness
  sessions expose all 35. `resources/*` returns method-not-found.
- `acceptance/evidence.json` has zero admitted entries, so production
  `tools/list` is empty today.
- `qa run` only renders for suite `authoring-v1`; `spec+style` has no render
  scenarios. An `authoring-v1` run on the seed-42 `native-anime-v1` project
  produces 11 PNGs at 1024²: three `visual.*`, three `expression.*`, five
  `motion.idle` frames. `vrm-author-render` honours per-scenario
  `width`/`height`.
- `recipe export` returns the Recipe inline in `result.recipe` as well as at
  `--out`. `export vrm` succeeds on an untouched seed-42 project (rights and
  meta are complete by default).
- The Recipe already carries the levers two bases need: `body.heightM`,
  `body.headCount`, `body.proportion.{shoulderWidth,hipWidth,torsoLength,
  armLength,legLength}`, `body.shape.{chest,waist,hip,muscle}`, `face.*`
  (jaw, chin, brows, eyes, nose, mouth, ears), hair preset + controls +
  texture, outfit presets (`top-v1`, `bottom-v1`, `skirt-v1`, `footwear-v1`).
- Hair presets are `bob-v1`, `long-v1`, `ponytail-v1`. There is no short cut.
- VRMAuthorKit has a PNG encoder and no decoder, so it cannot resample stills
  in-process.
- Seed-42 stills show: a dark open band at the neckline of `top-v1`, hair
  clumps rendered as separated ribbons with visible scalp gaps, uniform noise
  cloth rasters with no UV island structure, and expression cameras that crop
  the crown. The expression camera is a locked oracle and is not changed here.

## 3. MCP surface

### 3.1 Session model

`serve --stdio --protocol mcp` keeps its transport, `initialize` negotiation,
stderr-only logging and `vrmauthor/1` envelopes. What changes:

- `tools/list` returns the six facade tools below and nothing else, in every
  session (release, tightened, harness). The 1:1 projection of registry
  operations is removed from MCP; it remains the whole of `--protocol jsonrpc`.
- `initialize` declares `capabilities.resources = {subscribe:false,
  listChanged:false}` alongside `tools`, and its `instructions` string
  describes the loop: read a starter resource, `vrm_project` init, patch the
  Recipe, `vrm_recipe apply`, `vrm_build`, `vrm_qa`, repeat, `vrm_export`.
- `resources/list` and `resources/read` become real methods (§4).
- `serve --project <dir>` still sets the session's default project; every
  facade tool accepts an explicit `project` that overrides it.

### 3.2 Facade tools

Each tool is a thin dispatcher in a new file
`Sources/VRMAuthorKit/Serve/MCPFacade.swift`. It validates its own small input
schema, maps to one or more registry operations through the existing
`invokeOperation`, and returns a `tools/call` result. Nothing in the facade
touches project state directly; it only composes handler envelopes.

| Tool | Underlying operations | Input | Result (`structuredContent`) |
|---|---|---|---|
| `vrm_discover` | `capabilities`, `template list`, `control list` on a scratch or given project | `{project?}` | `{templates:[{id,sha256}], controls:[control descriptors], presets:{hair:[…],outfit:[…],accessory:[…]}, renderers:[…], starters:[resource URIs], evidence:{admitted:[op names]}}` |
| `vrm_project` | `project init` / `project inspect` | `{action:"init", dir, template?, seed?, name?}` or `{action:"inspect", project?}` | `project init` result (with `recipe`) or `project inspect` result; `revision` at top level |
| `vrm_recipe` | `recipe export` / `recipe apply` | `{action:"export", project?}` or `{action:"apply", project?, recipe, expectedRevision, requestId?, dryRun?}` | `recipe export` result (`recipe` inline) or `recipe apply` result; `revision` at top level |
| `vrm_build` | `build` | `{project?, out?, replace?}` | `build` result (`buildHash`, `artifacts`, `stale`); `out` defaults to `<project>/builds/draft.vrm` with `replace:true` |
| `vrm_qa` | `qa run` (+ preview render pass, §5) | `{project?, file?, suite?, out?, images?, previewSize?}` | `qa run` result (`verdict`, `checks`, `reportHash`, `artifacts`) plus `previews:[{scenarioId, path, sha256}]`; `content` carries text then image blocks |
| `vrm_export` | `export vrm` | `{project?, out, replace?}` | `export vrm` result (`buildHash`, `artifacts`, `lossReport`, `meta`) |

Conventions shared by every tool:

- `project` defaults to the session project; if neither is set the tool fails
  with `-32602` naming `/project`.
- `vrm_discover` needs a project only for `control list`; without one it
  initialises a temporary project in a private temp directory with the default
  template and seed 0, lists controls, and removes it. It never writes inside
  the caller's tree.
- Mutations (`vrm_recipe apply`) require `expectedRevision` exactly like RPC
  mutations do. The facade never auto-fills it. Every facade result puts
  `revision` (the project's revision after the call) at the top level so the
  next call can pass it.
- `vrm_recipe apply` takes the complete Recipe document. The agent edits the
  export in place (for example `/body/body.heightM`); there is no patch
  format and no partial apply.
- `vrm_qa` `suite` defaults to `authoring-v1`. `file` defaults to the newest
  `build` artifact recorded in the project (`builds/<hash>/`), and fails with
  a `build` suggestion if there is none. `out` defaults to
  `<project>/reports/mcp-qa-<revision>-<n>/`.
- `isError` is true only for protocol or handler errors (an envelope with
  `status:"failed"` whose errors are not QA check failures). A QA verdict of
  `fail` or `incomplete` is a *result*: `isError:false`, verdict in
  `structuredContent`. `recipe apply` domain failures (invalid recipe, stale
  revision) stay `isError:true` because the call did nothing.
- `content[0]` is always a compact text block: one line per check or error,
  never the full envelope JSON. The full envelope is `structuredContent`.

Tool descriptors set `readOnlyHint:true` only on `vrm_discover`; every other
tool can write files or revisions.
`destructiveHint:false` everywhere; `idempotentHint:true` on `vrm_recipe apply`
(requestId) and `vrm_build`.

### 3.3 Evidence gating

A facade tool appears in `tools/list` when every operation it maps to is
production-eligible under the session's evidence policy, or when the session is
a harness session. `vrm_discover` maps to `capabilities`, `template list` and
`control list`; `vrm_project` to both `project init` and `project inspect`;
`vrm_recipe` to both `recipe export` and `recipe apply`; `vrm_qa` to `qa run`.
With today's empty `evidence.json`, production `tools/list` is empty and
harness `tools/list` has six entries. Calling a hidden tool fails with
`-32602 Unknown tool` and lists the available names, as today.

This is the same admission rule the CLI `capabilities` command applies, just
evaluated per facade tool. No new evidence level or policy field is added.

## 4. Starter resources

Two resources, both `application/json`:

| URI | Meaning |
|---|---|
| `recipe://native-anime-v1/female` | The pack's default Recipe (seed 42) with the female override set applied |
| `recipe://native-anime-v1/male` | The same default with the male override set applied |

They are generated, not stored: `TemplateRegistry` resolves the pack, its
content hash fills `template.sha256`, the pack's default recipe is exported,
and a per-base override table (a `[String: JSONValue]` keyed by JSON pointer,
defined next to the pack in `NativeAnimeV1Pack.swift`) is applied. `name` is
`"female"` / `"male"`. The agent reads one, edits it, and passes it to
`vrm_recipe apply` on a project it initialised with the same template and any
seed; `recipe apply` already validates `template.sha256` against the installed
pack.

`resources/list` returns both entries with `name`, `title`, `description`,
`mimeType`. `resources/read` returns `contents:[{uri, mimeType, text}]` with
the canonical JSON. Unknown URIs fail with `-32002` (resource not found) per
MCP 2025-06-18. Resources are listed in every session; they are data, not
operations, and reading them mutates nothing.

Override sets (values are recipe fields; ranges are the published control
ranges):

| Field | female | male |
|---|---|---|
| `body.heightM` | 1.60 | 1.74 |
| `body.headCount` | 6.6 | 7.2 |
| `body.proportion.shoulderWidth` | -0.20 | 0.45 |
| `body.proportion.hipWidth` | 0.30 | -0.20 |
| `body.proportion.torsoLength` | 0 | 0.10 |
| `body.shape.chest` | 0.45 | -0.10 |
| `body.shape.waist` | -0.35 | 0.10 |
| `body.shape.hip` | 0.35 | -0.15 |
| `body.shape.muscle` | -0.10 | 0.35 |
| `face.jaw.width` | -0.25 | 0.35 |
| `face.chin.length` | -0.15 | 0.20 |
| `face.chin.pointedness` | 0.20 | -0.10 |
| `face.eye.{left,right}.height` | 0.25 | -0.15 |
| `face.brow.{left,right}.thickness` | -0.20 | 0.35 |
| `face.lip.fullness` | 0.20 | -0.20 |
| hair preset / `lengthM` / `tipBendDeg` | `bob-v1` / 0.20 / 12 | `bob-v1` / 0.13 / 0 |
| outfits | `top-v1`, `skirt-v1`, `footwear-v1` | `top-v1`, `bottom-v1`, `footwear-v1` |

The numbers are a starting point for the craft pass in §6, which tunes them
against the stills; the spec fixes the *fields* each base sets, not the final
values. Both bases keep every other default, including rights and meta, so
`vrm_export` succeeds on an unedited starter.

## 5. QA images

`vrm_qa` runs the locked `qa run` exactly as the CLI does; the report, evidence
JSON and 1024² artifacts are unchanged and remain the hashed evidence. It then
runs a *preview pass*: for each scenario in `QAPins.renderScenarios()` whose
`kind` is `visual` or `expression`, it re-renders through the same
`RenderAdapter` with `width`/`height` overridden to `previewSize` (default
512, valid 128–1024) into `<out>/preview/<scenarioId>/`. Previews are recorded
in the result as `previews` with path and sha256, and are returned inline as
MCP image content (`{type:"image", data:<base64 PNG>, mimeType:"image/png"}`)
after the text block, in scenario order. `motion.idle` frames are never
inlined; their paths are in `artifacts` like today.

`images` selects `"inline"` (default) or `"paths"` (no preview pass, no image
blocks). A preview is a view for the model, not evidence: it is not added to
the QA report, evidence JSON, or any inspection binding, and its hash never
appears in a pack. The preview pass reuses the same scenario configuration so
what the model sees is the locked view at a smaller size.

When the renderer is unavailable (no `vrm-author-render` sibling or no Metal
device, e.g. Linux), `qa run` already returns `incomplete` for render
scenarios. `vrm_qa` then returns the checks, no image blocks, `previews:[]`,
`isError:false`, and a warning naming the missing renderer.

Inspection records remain outside this facade. An agent seeing a preview does
not produce the record README §5 needs for `complete`; `inspection record`
stays a CLI/RPC command, and the loop reaches at most `draft` status through
MCP until a later design adds an inspection tool. `vrm_qa`'s text block says
so on every run so the agent does not report completion it cannot claim.

## 6. Default craft on the two starters

`vrm_qa` images are the agent's eyes, so the seed-42 bases must not read as
lofted mannequins. Four items, each with an acceptance visible in an existing
locked still and a numeric check where one is cheap. These are template and
wearable changes, independent of §3–§5, and may ship as a separate plan.

| Item | Change | Acceptance |
|---|---|---|
| Closed collar | `top-v1` collar band closes the neckline: the crew rim meets the neck shell with a positive overlap instead of the current open gap that renders as a dark band | `visual.front` at 1024² has no run of ≥ 8 consecutive rows in the neckline region whose mean luminance is below 0.15; a `WearableValidation` check reports neckline clearance ≥ 0 |
| Hair coverage | Bob clumps overlap laterally so the scalp underlay is not visible between ribbons at rest: raise default `widthScale` for the bob layout and add a scalp cap clump set under the parted region | Scalp-colour pixel ratio inside the hair silhouette in `visual.front` and `visual.threeQuarter` below 2%; existing bang clearance and sweep checks still pass |
| Face raster | Iris/pupil sizes and brow strokes follow the base's `face.*` values; the base cheek blush and lip colour desaturate to the profile's face defaults so the face reads as skin, not paint | `style.lint` stays conforming; a geometry test asserts the raster's iris radius tracks `face.iris.*.size` |
| Garment UV islands | Cloth rasters gain island structure: `top-v1`, `bottom-v1`, `skirt-v1` unwrap to named islands (front, back, sleeves/legs) with a seam-aligned weave direction and hem/cuff bands, replacing uniform noise | UV island count per garment equals the layout's declared count; no island overlap; `visual.threeQuarter` shows a hem band |

None of these change camera, threshold or scenario oracles. Each item updates
the affected NativeAnime or Wearables tests, and the affected packs are re-pinned
afterwards.

## 7. Files

New:
- `Sources/VRMAuthorKit/Serve/MCPFacade.swift`: tool table, input schemas,
  dispatch, text-block formatting, evidence gate per tool.
- `Sources/VRMAuthorKit/Serve/MCPResources.swift`: starter resource
  generation, `resources/list`/`read`.
- `Sources/VRMAuthorKit/QA/QAPreviewRenderer.swift`: preview pass over
  `RenderAdapter` with size override and base64 PNG loading.
- `Tests/VRMAuthorKitTests/Serve/MCPFacadeTests.swift`,
  `MCPResourcesTests.swift`; a render-guarded `MCPQAImagesTests.swift`.

Changed:
- `ServeSession.swift`: `dispatchMCP` routes `tools/*` to the facade and adds
  `resources/*`; `initialize` capabilities and instructions; `exposedOperations`
  becomes the per-tool gate.
- `NativeAnimeV1Pack.swift`: female/male override tables.
- `Tests/VRMAuthorKitTests/Serve/MCPClientTests.swift`: the assertions that
  encode the old surface (resources/list → -32601; harness list > 2 tools;
  calling `control.set` by registry name) move to the new shape.
- Docs: `docs/proposals/vrm-author-cli/README.md` §4 (MCP adapter paragraph),
  `commands.md` (serve: MCP exposes the facade), `CLAUDE.md` (the sentence
  about harness exposing every runnable handler now applies to `jsonrpc`
  and to the evidence gate, not to MCP tool count).
- Packs: `serve.json` and any pack whose pinned test files change, re-pinned
  with `scripts/repin_packs.py`.

## 8. Testing

- Facade unit tests drive `ServeSession` with raw JSON-RPC lines, as
  `MCPClientTests` does: six tools listed in harness, zero in release with
  empty evidence, partial exposure when only some underlying operations are
  admitted (e.g. `project init` admitted but not `project inspect` hides
  `vrm_project`).
- End-to-end in one session: read `recipe://native-anime-v1/female`, init,
  apply with `expectedRevision`, build, `vrm_qa` with `images:"paths"`
  (renderer not required), export; assert `revision` increments, the build
  hash equals the CLI's for the same recipe, and `isError` is false on a QA
  `incomplete` verdict.
- Image test (skips without Metal): `vrm_qa` returns six image blocks whose
  decoded size is `previewSize`², preview sha256s match the files on disk, and
  the 1024² report hash is identical to a plain `qa run` on the same file.
- Resource tests: both URIs parse as a valid `Recipe`, `template.sha256`
  equals `capabilities.templateHashes`, unknown URI → `-32002`.
- Craft tests per §6; `swift test --filter VRMAuthorKitTests --disable-sandbox`
  green; `scripts/repin_packs.py --check` clean after re-pinning.

## 9. Open items outside this spec

- An inspection tool for MCP (§5) so the loop can reach `complete`.
- A short hair preset; until then the male starter wears the bob at its short
  end.
- Evidence admission for any command remains the evaluator's job; nothing here
  changes what production sessions expose.
