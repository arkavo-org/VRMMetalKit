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

Date: 2026-09-12. Branch: `vrm-author-cli`. Status: design, revised after review.

## 1. Goal

Give an MCP client the loop in README §5 (brief → Recipe → build → QA
artifacts → bounded repair) through a handful of tools whose results the model
can read and, for QA, *see*. The 35 CLI commands stay exactly as they are and
remain reachable 1:1 over `serve --stdio --protocol jsonrpc`. MCP stops being a
mechanical 1:1 projection of that registry and becomes a short facade over the
same handlers.

Non-goals (unchanged from the approved design): `.vroid` import, promoting
reserved sliders, widening any published control range, duplicating acceptance
packs, a GUI "Male/Female" product, and filling production `tools/list` by
forging evidence. Evidence admission still belongs to the independent evaluator.

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
- `build` records `builds/<hash>/{avatar.vrm, idmap.json, buildinfo.json}` and
  `builds/latest.json`; `BuildSupport.avatarURL` resolves a hash to its file.
- `recipe export` returns the Recipe inline in `result.recipe` as well as at
  `--out`. `export vrm` succeeds on an untouched seed-42 project (rights and
  meta are complete by default).
- `template list` needs no project and already returns the pack's 44 avatar
  control descriptors plus every hair/outfit/accessory item with its controls.
  `control list` adds only the project's current values.
- Avatar controls are flat maps under `body` and `face`, so the JSON pointer
  to height is `/body/body.heightM`. Hair and outfit items are arrays:
  `/hair/0/preset`, `/outfits/1/preset`.
- The pack default bob already sets `widthScale: 1.25`, which is the top of
  its valid range (0.75–1.25). Hair presets are `bob-v1`, `long-v1`,
  `ponytail-v1`; there is no short cut.
- `OutfitPresets.addTrimBands` already builds a crew collar; it is rise-only
  (`+0.012 y`, `+0.001 n`) because leaning in crossed the neck on slim hosts,
  and the seed-42 stills still show a dark band at the neckline.
- VRMAuthorKit has a PNG encoder (`PNGEncoder`) and no decoder, so it cannot
  read or resample stills in-process.
- Seed-42 stills also show hair clumps as separated ribbons with visible scalp
  between them, uniform-noise cloth rasters with no UV island structure, and
  expression cameras that crop the crown. Cameras are locked oracles and are
  not changed here.

## 3. MCP surface

### 3.1 Session model

`serve --stdio --protocol mcp` keeps its transport, `initialize` negotiation,
stderr-only logging and `vrmauthor/1` envelopes. What changes:

- `tools/list` returns facade tools only, in every session (release,
  tightened, harness). The 1:1 projection of registry operations is removed
  from MCP; it remains the whole of `--protocol jsonrpc`.
- `initialize` declares `capabilities.resources = {subscribe:false,
  listChanged:false}` alongside `tools`, and its `instructions` string
  describes the loop: read a starter resource, `vrm_project` init, edit the
  Recipe, `vrm_recipe apply`, `vrm_build`, `vrm_qa`, repeat, `vrm_export`.
- `resources/list` and `resources/read` become real methods (§4).
- `serve --project <dir>` still sets the session's default project; every
  facade tool accepts an explicit `project` that overrides it.

### 3.2 Facade tools

Each tool is a thin dispatcher in a new file
`Sources/VRMAuthorKit/Serve/MCPFacade.swift`. It validates its own small input
schema, maps to one or more registry operations through the existing public
`invokeOperation`, and returns a `tools/call` result. Nothing in the facade
touches project state directly; it only composes handler envelopes.

| Tool | Underlying operations | Input | Result (`structuredContent`) |
|---|---|---|---|
| `vrm_discover` | `capabilities`, `template list`; `control list` only when `project` is given | `{project?}` | `{templates:[{id,sha256}], controls:[avatar control descriptors, with `value` when a project was given], presets:{hair:[…],outfit:[…],accessory:[…]} each with controls, renderers:[…], starters:[resource URIs], evidence:{admitted:[op names]}}` |
| `vrm_project` | `project init` / `project inspect` | `{action:"init", dir, template?, seed?, name?}` or `{action:"inspect", project?}` | `project init` result (with `recipe`) or `project inspect` result; `revision` at top level |
| `vrm_recipe` | `recipe export` / `recipe apply` | `{action:"export", project?}` or `{action:"apply", project?, recipe, expectedRevision, requestId?, dryRun?}` | `recipe export` result (`recipe` inline) or `recipe apply` result; `revision` at top level |
| `vrm_build` | `build` | `{project?, out?, replace?}` | `build` result (`buildHash`, `artifacts`, `stale`) |
| `vrm_qa` | `qa run` (+ preview pass, §5) | `{project?, file?, suite?, out?, images?, previewSize?}` | `qa run` result (`verdict`, `checks`, `reportHash`, `artifacts`) plus `previews:[{scenarioId, path, sha256, width, height}]`; `content` carries text then image blocks |
| `vrm_export` | `export vrm` | `{project?, out, replace?}` | `export vrm` result (`buildHash`, `artifacts`, `lossReport`, `meta`) |

Conventions shared by every tool:

- `project` defaults to the session project; if neither is set the tool fails
  with `-32602` naming `/project`. `vrm_discover` is the exception: it never
  needs a project and never creates one; without a project its `controls`
  carry descriptors and defaults only.
- Mutations (`vrm_recipe apply`) require `expectedRevision` exactly like RPC
  mutations do. The facade never auto-fills it. Every facade result puts
  `revision` (the project's revision after the call) at the top level so the
  next call can pass it.
- `vrm_recipe apply` takes the complete Recipe document. The agent edits the
  export in place (for example `/body/body.heightM`); there is no patch
  format and no partial apply.
- `vrm_build` `out` defaults to `<project>/draft.vrm` with `replace:true`.
  Nothing but `recordBuild` writes under `builds/`.
- `vrm_qa` `suite` defaults to `authoring-v1`. `file` defaults to the newest
  build's `builds/<hash>/avatar.vrm` resolved through `builds/latest.json`,
  and fails with a `build` suggestion if there is none. `out` defaults to
  `<project>/reports/mcp-qa-<revision>-<n>/`.
- `isError` is true only for protocol or handler errors (an envelope with
  `status:"failed"` whose errors are not QA check failures). A QA verdict of
  `fail` or `incomplete` is a *result*: `isError:false`, verdict in
  `structuredContent`. `recipe apply` domain failures (invalid recipe, stale
  revision) stay `isError:true` because the call did nothing.
- `content[0]` is always a compact text block: one line per check or error,
  never the full envelope JSON. The full envelope is `structuredContent`.

Tool descriptors set `readOnlyHint:true` only on `vrm_discover`; every other
tool can write files or revisions, and the two-action tools cannot mark their
read action separately. `destructiveHint:false` everywhere; `idempotentHint:true`
on `vrm_recipe apply` (requestId) and `vrm_build`.

### 3.3 Evidence gating

A facade tool appears in `tools/list` when *any* operation it maps to is
production-eligible under the session's evidence policy, or when the session is
a harness session. Calling an action whose operation is not eligible returns a
tool result with `isError:true` and a `vrmauthor/1` envelope carrying one
`MISSING_CAPABILITY` error that names the operation, its required evidence
level and the `capabilities` command, so the model learns what is admitted
without the whole tool vanishing. `vrm_discover`'s `evidence.admitted` lists
the same set.

Mapping: `vrm_discover` → `capabilities`, `template list`, `control list`;
`vrm_project` → `project init`, `project inspect`; `vrm_recipe` →
`recipe export`, `recipe apply`; `vrm_build` → `build`; `vrm_qa` → `qa run`;
`vrm_export` → `export vrm`. With today's empty `evidence.json`, production
`tools/list` is empty and harness `tools/list` has six entries. Admitting
`project init` alone makes `vrm_project` appear with `inspect` refused.

This is the same admission rule the CLI `capabilities` command applies,
evaluated per operation. No new evidence level or policy field is added.

## 4. Starter resources

Two resources, both `application/json`:

| URI | Meaning |
|---|---|
| `recipe://native-anime-v1/female` | The pack's default Recipe with the female override set applied |
| `recipe://native-anime-v1/male` | The same default with the male override set applied |

They are generated, not stored: `TemplateRegistry` resolves the pack, its
content hash fills `template.sha256`, the pack's default recipe is materialised,
`seed` is set to 42 and `name` to `"female"` / `"male"`, then a per-base
override table is applied. The table is `[(pointer: String, value: JSONValue)]`
in `NativeAnimeV1Pack.swift`, applied in order with RFC 6901 pointers through
the existing `JSONPointer` support; every pointer must resolve to an existing
location (no array inserts, no new keys), so an override that no longer matches
the default recipe fails a unit test rather than silently skipping. The agent
reads one, edits it, and passes it to `vrm_recipe apply` on a project it
initialised with the same template and any seed; `recipe apply` already
validates `template.sha256` against the installed pack.

`resources/list` returns both entries with `name`, `title`, `description`,
`mimeType`. `resources/read` returns `contents:[{uri, mimeType, text}]` with
the canonical JSON. Unknown URIs fail with `-32002` (resource not found) per
MCP 2025-06-18. Resources are listed in every session; they are data, not
operations, and reading them mutates nothing.

Override tables (values within the published control ranges; array items keep
their ids and material bindings, only `preset` and controls change):

| Pointer | female | male |
|---|---|---|
| `/body/body.heightM` | 1.60 | 1.74 |
| `/body/body.headCount` | 6.6 | 7.2 |
| `/body/body.proportion.shoulderWidth` | -0.20 | 0.45 |
| `/body/body.proportion.hipWidth` | 0.30 | -0.20 |
| `/body/body.proportion.torsoLength` | 0 | 0.10 |
| `/body/body.shape.chest` | 0.45 | -0.10 |
| `/body/body.shape.waist` | -0.35 | 0.10 |
| `/body/body.shape.hip` | 0.35 | -0.15 |
| `/body/body.shape.muscle` | -0.10 | 0.35 |
| `/face/face.jaw.width` | -0.25 | 0.35 |
| `/face/face.chin.length` | -0.15 | 0.20 |
| `/face/face.chin.pointedness` | 0.20 | -0.10 |
| `/face/face.eye.left.height`, `/face/face.eye.right.height` | 0.25 | -0.15 |
| `/face/face.brow.left.thickness`, `/face/face.brow.right.thickness` | -0.20 | 0.35 |
| `/face/face.lip.fullness` | 0.20 | -0.20 |
| `/hair/0/preset` | `bob-v1` | `bob-v1` |
| `/hair/0/controls/lengthM` | 0.20 | 0.13 |
| `/hair/0/controls/tipBendDeg` | 12 | 0 |
| `/outfits/1/preset` (item `outfit.bottom`) | `skirt-v1` | `bottom-v1` |

The numbers are a starting point for the craft pass in §6, which tunes them
against the stills; the spec fixes the *pointers* each base sets, not the final
values. Both bases keep every other default, including rights and meta, so
`vrm_export` succeeds on an unedited starter. Note that the locked expression
cameras sit at y = 1.45 with a 0.9 m stand-off, so the 1.74 m male crown is
cropped harder than the 1.60 m female one; the face itself stays in frame for
both, and the cameras are not changed for it.

## 5. QA images

`vrm_qa` runs the locked `qa run` exactly as the CLI does; the report, evidence
JSON and 1024² artifacts are unchanged and remain the hashed evidence. It then
runs a *preview pass*: for the selected scenarios it re-renders through the
same `RenderAdapter` with `width`/`height` overridden to `previewSize`
(default 512, valid 128–1024) into `<out>/preview/<scenarioId>/`. The preview
PNGs are read as bytes and base64-encoded; nothing decodes or resamples the
1024² stills. A preview is a second rasterisation at a different resolution:
its pixels do not match the evidence still, its hash never appears in a QA
report, evidence file, inspection binding or pack, and `previews` in the result
is labelled `"evidence": false`.

`images` selects which scenarios get a preview and an inline image block:

| `images` | Preview scenarios | Inline blocks |
|---|---|---|
| `"key"` (default) | `visual.front`, `expression.happy` | 2 |
| `"all"` | the three `visual.*` and three `expression.*` | 6 |
| `"paths"` | none | 0 |

`motion.idle` frames are never previewed or inlined; their 1024² paths are in
`artifacts` like today. Image blocks are `{type:"image", data:<base64 PNG>,
mimeType:"image/png"}` after the text block, in scenario order.

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
lofted mannequins. Four items, each with a geometric acceptance and, where a
still can carry one deterministically, a pixel acceptance on a locked still.
These are template and wearable changes, independent of §3–§5, and ship as a
separate plan. No control range changes.

| Item | Change | Acceptance |
|---|---|---|
| Closed collar | Fix the existing crew band in `OutfitPresets.addTrimBands`: keep rise-only where the neck is narrower than the rim, but lean the band inward by the measured rim-to-neck gap minus 2 mm (clamped ≥ 0) so it meets the neck shell without crossing it on slim hosts or at large `headCount` | New `WearableValidation` check: at collar rim height the radial gap between the band's inner edge and the neck surface is ≤ 0.002 m at every rim sample, and no band vertex lies inside the neck shell. Pixel check on `visual.front`: within the box obtained by projecting the `neck` and `head` bone origins from `idmap.json` through the locked front camera and padding ±0.04 m, no run of ≥ 8 consecutive rows has mean luminance < 0.15 |
| Hair coverage | Geometry, not range: add a scalp-cap clump set under the part and between existing clumps in the bob layout, and raise the default clump count; `widthScale` stays at its 1.25 default and its range is untouched | Scalp-colour pixel ratio inside the hair silhouette in `visual.front` and `visual.threeQuarter` below 2% (silhouette = pixels whose colour is within the hair palette's hue band, tested against the hair raster colours); existing bang clearance and sweep checks still pass; spring chain count stays at 40 |
| Face raster | Iris/pupil sizes and brow strokes follow the base's `face.*` values; the base cheek blush and lip colour desaturate to the profile's face defaults so the face reads as skin, not paint | `style.lint` stays conforming; a geometry test asserts the raster's iris radius tracks `face.iris.*.size` |
| Garment UV islands | Cloth rasters gain island structure: `top-v1`, `bottom-v1`, `skirt-v1` unwrap to named islands (front, back, sleeves/legs) with a seam-aligned weave direction and hem/cuff bands, replacing uniform noise | UV island count per garment equals the layout's declared count; no island overlap; `visual.threeQuarter` shows a hem band (row of ≥ 6 px darker than the surrounding cloth mean at the projected hem height) |

None of these change camera, threshold or scenario oracles. Each item updates
the affected NativeAnime or Wearables tests, and the affected packs are re-pinned
afterwards.

## 7. Files

New:
- `Sources/VRMAuthorKit/Serve/MCPFacade.swift`: tool table, input schemas,
  dispatch, text-block formatting, per-operation evidence gate.
- `Sources/VRMAuthorKit/Serve/MCPResources.swift`: starter resource
  generation, `resources/list`/`read`.
- `Sources/VRMAuthorKit/QA/QAPreviewRenderer.swift`: preview pass over
  `RenderAdapter` with size override; reads the preview PNG bytes and
  base64-encodes them.
- `Tests/VRMAuthorKitTests/Serve/MCPFacadeTests.swift`,
  `MCPResourcesTests.swift`; a render-guarded `MCPQAImagesTests.swift`.

Changed:
- `ServeSession.swift`: `dispatchMCP` routes `tools/*` to the facade and adds
  `resources/*`; `initialize` capabilities and instructions; `exposedOperations`
  becomes the per-operation gate the facade consults.
- `NativeAnimeV1Pack.swift`: female/male override tables.
- `Tests/VRMAuthorKitTests/Serve/MCPClientTests.swift`: the assertions that
  encode the old surface (`resources/list` → -32601; harness list > 2 tools;
  calling `control.set` by registry name) move to the new shape. The pack
  invariant "tools/list follows the session evidence policy" is kept.
- Docs: `docs/proposals/vrm-author-cli/README.md` §4 (MCP adapter paragraph),
  `commands.md` (serve: MCP exposes the facade), `CLAUDE.md` (AGENTS.md is a
  symlink to it): the sentence about harness exposing every runnable handler
  now applies to `jsonrpc` and to the evidence gate, not to MCP tool count.
- Packs: `serve.json` pins the Serve test files, so it is re-pinned with
  `scripts/repin_packs.py` together with any other pack whose pinned tests
  change.

## 8. Testing

- Facade unit tests drive `ServeSession` with raw JSON-RPC lines, as
  `MCPClientTests` does: six tools listed in harness, zero in release with
  empty evidence, `vrm_project` listed when only `project init` is admitted
  and its `inspect` action refused with `MISSING_CAPABILITY`.
- End-to-end in one session: read `recipe://native-anime-v1/female`, init,
  apply with `expectedRevision`, build, `vrm_qa` with `images:"paths"`
  (renderer not required), export; assert `revision` increments, the build
  hash equals the CLI's for the same recipe, `draft.vrm` sits at the project
  root and nothing but `recordBuild` output sits under `builds/`, and
  `isError` is false on a QA `incomplete` verdict.
- Image test (skips without Metal): default `vrm_qa` returns two image blocks
  and `images:"all"` six; each decodes as a PNG whose IHDR reports
  `previewSize`²; preview sha256s match the files on disk; the 1024² report
  hash is identical to a plain `qa run` on the same file; `previews[*].evidence`
  is false.
- Resource tests: both URIs parse as a valid `Recipe`, `template.sha256`
  equals `capabilities.templateHashes`, `seed` is 42, every override pointer
  resolves in the default recipe, unknown URI → `-32002`.
- `vrm_discover` without a project writes nothing to disk and returns the same
  descriptors as `template list`.
- Craft tests per §6; `swift test --filter VRMAuthorKitTests --disable-sandbox`
  green; `scripts/repin_packs.py --check` clean after re-pinning.

## 9. Open items outside this spec

- An inspection tool for MCP (§5) so the loop can reach `complete`.
- A short hair preset; until then the male starter wears the bob at its short
  end.
- Evidence admission for any command remains the evaluator's job; nothing here
  changes what production sessions expose.
