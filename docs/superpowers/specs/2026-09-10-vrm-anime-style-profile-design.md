# VRM anime style profile — design

**Date:** 2026-09-10
**Status:** implemented (v0.1.0 profile, linter, schema)

## Problem

VRM 1.0 standardises the technical contract of an avatar (humanoid bones, T-pose rest
pose, MToon parameters, expression presets, meta/licence) and reference implementations
pin down behaviour where the spec is loose. Nothing standardises the *aesthetic*. VRoid
Studio encodes "VRM anime" implicitly as slider ranges and a fixed base topology; UTS-
derived cel-shading conventions and Japanese character-design pedagogy exist as prose.
A generator that wants to emit avatars that read as VRM-anime has no target to hit, and
a renderer has no way to say "this asset is in style" the way `vrm-conformance` says
"this render matches".

## Goal

Formalise the aesthetic as a machine-readable, lintable profile and make it a
conformance target: proportions as bone ratios and head counts, face landmark placement,
MToon parameter envelopes, hair/physics structure, budgets. Derive every envelope from
measured assets, never from assumption, and keep the file format tool-agnostic so a
competing generator is graded on style, not on whether it imitates VRoid's exporter.

## Non-goals

- No Swift target and no renderer change. The linter is a standalone Python tool.
- No writes to `../vrm-conformance`; it is referenced for its operation contract and its
  synthetic assets are used as negative controls.
- No claim about styles outside the VRoid lineage (kemono, chibi) — those are future
  profiles.

## Design

### Profile format (`docs/style/vrm-anime-style-profile.schema.json`)

A profile is `{id, version, title, corpus, metric_definitions, material_roles,
reference_tiers, rules[]}`. A rule is `{id, class, severity, scope, roles?, filter?,
vrm_versions?, metric, check, provenance}`. Checks are `range | equals | enum |
superset_of | subset_of | present`. Rules are data; the linter is a generic evaluator.

Two decisions shape the format:

1. **Fingerprints are a class, not a severity.** The corpus is 22 files but effectively
   18 bodies from one tool, so many constants (lookAt offset 0.06, 57 morphs, one
   outline RGB, giEq 0.9, rimFresnel 100) are shared by every asset without being
   aesthetic. They are recorded as `class: fingerprint, severity: info` so they inform
   without ever gating.
2. **Metrics are computed only from spec-mandated data.** Mesh names ("Face (merged)")
   and VRoid's material tags are not part of the VRM contract. Proportions come from
   humanoid bones; head height comes from skin weights (vertices whose dominant joint is
   the head, centre column, chin in front of the head bone). Material roles are an
   explicit linter input with a documented name heuristic as default.

### Linter (`scripts/style_lint.py`)

`describe | measure | lint`, `--json` everywhere, exit status 1 when any `must` rule
fails. Parses GLB directly (numpy only), handles VRM 0.x and 1.0, converts 0.x MToon
properties to 1.0 space with the same formulas as `VRMMToonMaterial.toMToonMaterial()`.
An unavailable metric fails its rule rather than passing.

### Derived shading metrics

MToon 1.0 shading is `linearstep(−1 + toony, 1 − toony, NdotL + shift)`. The profile
constrains `shadow_end = −1 + toony − shift` and `terminator_width = 2(1 − toony)`
rather than the raw sliders, because VRoid's two shading presets reach the same visible
result (a face that is never fully shaded) through different slider values.

## Findings encoded in v0.1.0

- Face region `shadow_end ≤ −0.6` (18/21 corpus faces; the three failures are
  non-VRoid-authored toon faces).
- Body/cloth `terminator_width ≤ 0.4`; hair `≤ 1.4`; both with shade edge near grazing
  light.
- Skin shade warmer than base (ratio ≥ 1.0), luminance ≥ 60% of base.
- World-space outlines 0.3–3 mm on skin/cloth, dark and warm; none on facial features.
- Eye layers BLEND at render-queue offsets ≤ 0; sclera/mouth MASK, single-sided.
- Eyes at 0.82–0.94 of height (must), hips 0.50–0.62 (must), 4.5–8 heads, eye line at
  0.25–0.50 of head height, hand span 0.55–0.78 of height, shin/thigh 1.0–1.3.
- ≥ 3 head-rooted spring chains, 2–16 joints, stiffness ≤ 4, drag ≤ 1, gravityPower
  ≤ 1, one head collider.
- Core presets present (must), `surprised` on 1.0 only (0.x has no equivalent), preset
  names valid (must), meta enums valid and licence URL exact (must).
- Budgets at the VRoid-typical envelope; VRChat rank tables cited, not enforced.

## Verification

- All 22 corpus assets: `conforming` or `conforming-with-warnings`; every warning is an
  identified minority choice.
- `smoke_default.vrm` and `springbone_default.vrm` from the conformance generator:
  `nonconforming` (`prop.eye_height_ratio`, `expr.core_presets`).
- Profile validates against the schema (`jsonschema` Draft 2020-12).

## Open items

Hair clump topology, texture-sampled colour envelopes, face landmark geometry beyond the
eye line, skinning-based role fallback, and additional lineage profiles. See "Known
gaps" in `docs/style/README.md`.

## Review corrections (2026-09-10, same day)

An external review of the first commit found seven measurement defects; all are fixed
and covered by `scripts/test_style_lint.py`:

1. VRM 0.x colour factors are now sRGB-decoded to linear before any colour metric (the
   0.x and 1.0 exports of one VRoid outline colour now agree at luminance 0.0202).
   Render queues, `_IndirectLightIntensity` and UV animation survive migration.
2. The 0.x chin search uses −Z as forward (0.x models face −Z; 1.0 models face +Z).
   Head counts on 0.x assets changed materially; the corpus was re-measured.
3. Absent VRM 1.0 meta fields take the schema defaults; only `name`, `authors` and
   `licenseUrl` are required upstream. `expr.core_presets` is reclassified as a profile
   (aesthetic) requirement because the spec makes every preset optional.
4. A black base colour no longer divides by zero; interleaved accessors with a nonzero
   accessor offset no longer over-read the buffer.
5. `asset.vertices` counts distinct POSITION accessors; `asset.vertex_references` keeps
   the per-primitive sum. The vertex budget was regenerated (max 47k, not 697k).
6. Role groups come from the profile, `--roles` values are validated against the
   profile's vocabulary, provenance is a required rule field, and fingerprint rules are
   schema-limited to `info`/`may`.
7. The shading interpretation is stated as a factor-only, direct-light envelope; the hair
   rule no longer claims hair is softer than the body.

Reproducibility: `docs/style/corpus/` holds the manifest (with body families) and the
measurements (with SHA-256 hashes and exporter strings); `style_lint.py envelopes --write`
regenerates every rule's provenance. pixiv's FAQ is cited as the documentary source for
the face-shading convention and the gamma-to-linear change.

## Second review (PR #436 at 1dd0186)

Five further defects, all fixed with tests: `corpus` now fails on a missing manifest
asset unless `--allow-missing` is passed; VRM 0.x material properties are paired with
glTF materials by index; sparse accessors and accessors without a bufferView are decoded;
medians use `statistics.median` (the texture-memory median moved from 137.6 to 126.6 MB,
triangles from 37,326 to 36,944); and each rule's `effective_n` counts only the bodies
that contribute observations to it (12 for VRM 1.0-only rules, 8 for 0.x-only).

## Out of scope: VRM 0.x emission colour space in the Swift loader

While verifying the 0.x colour fix, the same class of gap showed up in the renderer:
`VRMMaterial.init(from:textures:vrm0MaterialProperty:)` linearises `_Color`,
`_ShadeColor`, `_RimColor` and `_OutlineColor` for VRM 0.x but copies the glTF
`emissiveFactor` verbatim (UniVRM writes it in gamma space) and ignores `_EmissionColor`
when that glTF field is absent (the Muse validation avatar's hair). A fix with three
XCTest cases was prototyped and then withdrawn from this PR, which is scoped to docs and
scripts. The linter already decodes 0.x emission correctly, so profile envelopes are
unaffected; the renderer follow-up is tracked separately.
