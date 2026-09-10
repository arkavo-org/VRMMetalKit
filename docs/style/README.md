# VRM style profiles

A **style profile** is a machine-readable, lintable definition of what makes a VRM avatar
read as a particular visual style. The technical contract of VRM 1.0 (humanoid bones,
T-pose, MToon parameters, expressions, meta) is fully specified upstream; the aesthetic
that sits on top of it is not written down anywhere. This directory writes it down as data
so that a generator can target it, a linter can check it, and a renderer can be measured
against it the same way `../vrm-conformance` measures rendering.

| File | Purpose |
|---|---|
| `vrm-anime-style-profile.schema.json` | JSON Schema for the profile format: rules, checks, scopes, provenance. |
| `profiles/vroid-lineage-anime-1.0.json` | The first profile: the VRoid-lineage anime look, envelopes measured from 22 local assets. |
| `../../scripts/style_lint.py` | Measures a `.vrm` (0.x or 1.0) and evaluates it against a profile. |

```bash
scripts/style_lint.py describe                                   # operation catalog
scripts/style_lint.py measure --json AvatarSample_U_1.0.vrm.glb  # raw metrics
scripts/style_lint.py lint --profile docs/style/profiles/vroid-lineage-anime-1.0.json \
    AvatarSample_U_1.0.vrm.glb vroid_default_F_1_0.vrm           # exit 1 on any must failure
scripts/style_lint.py lint --profile ... --roles roles.json a.vrm  # override material roles
make style-lint                                                  # lints the repo-root fixtures
```

Only NumPy is required. Binary payloads are passed by path and reports are JSON with
`--json`, mirroring the conformance repo's operation contract.

## How a profile is structured

Every rule has five parts:

- **metric**: a quantity the linter computes from spec-mandated data only (glTF geometry and
  skins, `VRMC_vrm` humanoid/expressions/lookAt/meta, `VRMC_springBone`,
  `VRMC_materials_mtoon`). Nothing keys off mesh names or a particular exporter's layout.
  Operational definitions live in `metric_definitions` inside the profile.
- **check**: `range`, `equals`, `enum`, `superset_of`, `subset_of`, `present`. A metric
  that cannot be computed on an asset fails the rule; it never silently passes.
- **scope**: `asset` (one value per file) or `material` (evaluated per material, filtered by
  role and optional equality `filter`).
- **severity**: `must` (verdict is `nonconforming`), `should` (`conforming-with-warnings`),
  `may`, `info`.
- **class**: what kind of statement the rule is.
  - `aesthetic`: what makes the avatar read as this style.
  - `interop`: round-trip requirements the ecosystem rejects files without (meta enums,
    T-pose, preset names).
  - `budget`: performance envelope.
  - `fingerprint`: a constant every corpus asset shares because a single tool wrote it
    (lookAt offset exactly 0.06, 57 morph targets, one outline RGB). Fingerprints are
    never `must`. They answer "was this exported by VRoid Studio?", which is the
    opposite of what a competing generator wants to be graded on, so they are reported
    as `[info]` and do not affect the verdict.

Each rule also carries `provenance`: how many observations the envelope rests on
(`n` materials or assets, `effective_n` distinct bodies after collapsing re-exports),
the observed min/median/max, and the source (`corpus`, `spec`, or a URL).

## Material roles

Material-scoped rules need to know which materials are skin, hair, eyes and so on. The
VRM file does not encode this, so role assignment is an **input** to the linter:

1. A name heuristic (VRoid's `_SKIN` / `_HAIR` / `EyeIris` tags plus plain English words;
   see `describe`) is the default.
2. `--roles roles.json` maps material names to roles explicitly and wins over the
   heuristic.
3. Materials that stay `other` are exempt from every material rule; the
   `roles.all_classified` rule reports how many there were so the exemption is visible.

Role groups (`face_region`, `facial_feature`, `surface`, `skin`, `lit_cutout`) let rules
address several roles at once.

## What the first profile found

The VRoid-lineage look, measured rather than assumed:

**Shading is three-tiered, and the face tier is the one nobody writes down.** In MToon 1.0
space, `shadow_end = −1 + shadingToony − shadingShift` is the NdotL below which a surface
is fully in shade colour. Every VRoid-authored face material keeps `shadow_end ≤ −0.78`,
meaning the face is never fully shaded for any front-facing light; the nose and brow
never cast toon shadows. VRoid's two presets get there differently (toony 0.91 with shift
+0.71, or toony 0.05 with shift −0.05), so the rule is written on the derived quantity, not
on the sliders. Body and clothing use a hard two-tone terminator (`terminator_width =
2(1 − toony) ≤ 0.4`, edge at grazing light); hair is a softer two-tone (width 0.4,
same edge). Skin shade colour is always warmer than the base and never below 70% of its
luminance.

**Outlines are on surfaces, off features.** Skin and cloth carry a world-space inverted
hull 0.5–1.3 mm wide in a warm near-black; iris, sclera, eyeline, lashes, brows and mouth
never have one. Eye layers are alpha-blended and drawn at render-queue offsets −4…0
under the highlight.

**Proportions, as bone ratios (tool-agnostic) and one skinning metric.** Eyes at
0.84–0.92 of height, hips at 0.54–0.58, hand-to-hand span only 0.59–0.72 of height,
shins longer than thighs (1.12–1.19). Head height is measured from vertices whose
dominant skin joint is the head (centre column, chin in front of the head bone), giving
5.1–7.5 heads with crown hair included and the eye line at 0.28–0.45 of chin-to-crown,
well below the realistic midpoint.

**Hair and physics.** 7–16 spring chains rooted under the head, 3–7 joints each,
stiffness 0.25–1.5, drag ≤ 0.8, authored gravityPower almost always 0, one head collider.

**Budgets.** 26–77k triangles, 6–24 materials, 2048² textures totalling 51–222 MB decoded,
73–276 skin joints. Every corpus asset lands in VRChat PC "Medium" or "Poor"; the VRChat
tables are carried in `reference_tiers` for context, not enforced.

## Verification

`lint` over the corpus returns `conforming` or `conforming-with-warnings` for all 22
assets; the warnings are the known minority choices (soft-gradient body shading on two
assets, toon faces on three non-VRoid-authored ones, non-spring hair on one). Two
synthetic generator outputs from `../vrm-conformance/assets/generated` return
`nonconforming` on `prop.eye_height_ratio` and `expr.core_presets`. Their single
material has no role, so the material rules skip; with `--roles` assigning it
`face_skin`, `shade.face_never_deep_shadowed`, `shade.skin_shade_not_dark` and
`outline.surface_present` fail as well. The profile discriminates rather than merely
describing.

## Known gaps

- **Hair clump topology** (strand count, clump taper, bang/side-lock/back split) is not
  measured. The profile covers hair through spring-chain structure and material
  parameters only.
- **Textured colour** is not sampled; shade/base ratios use the factor colours. A texture-
  aware skin-tone envelope needs the decoded images.
- **Silhouette and face landmarks** beyond the eye line (chin taper, jaw width, nose
  presence) need a mesh-analysis pass; head width includes hair over the temples.
- **Role assignment** for assets that use neither VRoid tags nor English material names
  needs a skinning-based fallback; today they must pass `--roles`.
- The corpus is 18 distinct bodies from one lineage. Kemono, chibi and realistic-anime
  sub-styles need their own profiles (the schema's `extends` field is reserved for that).
