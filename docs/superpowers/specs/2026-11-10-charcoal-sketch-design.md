# Charcoal Sketch Materialization Style: Design

Date: 2026-11-10

## Intent

Add a charcoal-drawing spawn effect to VRMMetalKit: one progress value takes a VRM avatar from blank toned paper, through a hand-drawn charcoal sketch, to its full MToon shading. It exists for the Patreon GiftCoal clip, which is posted between Nov 30 and Dec 10, and afterwards as a reusable style for Arkavo Creator, Game of Mods and Avatar Muse.

This design replaces the pasted "Charcoal Sketch Effect Spec" of the same date. That spec assumed a nine-style shared contract and a screen-space post-processing pipeline. Neither exists in this repo, so the parts that depended on them are deferred (see Non-goals).

## What the repo actually has

- `VRMMaterializationStyle` ships twelve styles (PR #421). Charcoal is raw value 13.
- The contract is `VRMMaterialization`: `progress`, `style`, `color`, `heightRange`, `seed`, `origin`, uploaded as three `float4`s (`materializeParams`, `materializeColor`, `materializeOrigin`). `materializeOrigin.w` is reserved and unused.
- Every style is resolved by `mat_resolve` in `MToonShader.metal` and composited inside the MToon fragment, in the single colour pass the host supplies. The renderer owns no screen-space targets.
- The effect is compiled out unless `RendererConfig.enableMaterialization` is true (function constant 14).
- The effect is stateless: the same `progress` always gives the same frame, so running `progress` backward is the reverse effect.

## Goals

1. `VRMMaterializationStyle.charcoal = 13`, implemented in the existing single MToon pass. No extra render targets, no compute passes.
2. A full-body sketch that can be held: at `progress = 0.6` the whole avatar is a finished charcoal drawing with no surface colour.
3. Deterministic output: on one loaded model and one renderer, the same `progress`, `seed`, `boilPhase`, camera and pose give byte-identical pixels on every render. Determinism across separate loads is out of scope: the loader varies node transforms by about 1e-7 between loads.
4. Works on skinned, morphing, animated avatars, VRM 1.0 and 0.x.
5. Zero effect on any renderer that does not opt in.

## Non-goals (deferred, not rejected)

- The screen-space path: extra targets, edge-detect and hatch compute passes, full-screen composite, half-resolution smudge blur.
- GLTFMetalKit and non-VRM meshes. Game of Mods props currently use their own forked PBR fragment.
- Field modes other than the head-down height sweep (`radial`, `boneDistance`, `noise`).
- Body-anchored hatching (`hatchSpace = body`). Hatching is screen-space.
- Transparent paper for OBS (`paperBackground = alpha`).
- The quality ladder, thermal handling, per-product performance budgets, and JSON presets.
- A shared field contract across the other twelve styles.
- HDR ember. The composite clamps to 0..1; the ember is blended, not added past white.
- A `direction` parameter. Reverse is `progress` running from 1 to 0.
- Integration work in Creator, Game of Mods and Muse (see Follow-on work).

## Anti-goals

- Any pixel change for renderers with `enableMaterialization == false`, or with it true and no active charcoal materialization.
- A look that reads as a cel outline or an ink stamp. The judgement is by eye; see Acceptance.
- Colour leaking into the held sketch at `progress = 0.6`.

## Behaviour

### Timeline

Two head-down fronts share one ragged field `f` (0 at the top of `heightRange`, 1 at the bottom):

```
fRaw   = 1 - hNorm                       // hNorm: saturate(world Y normalised by heightRange)
f      = mix(a, 1 - a, fRaw) + n         // a = 0.06, n = zero-mean noise in [-a, +a]
tDraw  = saturate(t / 0.6)
tCol   = saturate((t - 0.6) / 0.4)
sDraw  = saturate((tDraw * (1 + 0.35) - f) / 0.35)
sCol   = saturate((tCol  * (1 + 0.25) - f) / 0.25)
s      = 0.6 * sDraw                     // drawing progress: contour 0..0.3, hatching 0.3..0.6
```

| `progress` | What is on screen |
| --- | --- |
| 0 | Blank paper. Only faint grey construction dashes along the silhouette. |
| 0 to 0.6 | The drawing front sweeps head to feet. Contours land first, then tonal hatching. |
| 0.6 | The complete charcoal drawing, no colour, no ember. This is the hold frame. |
| 0.6 to 1 | The colour front sweeps head to feet behind an ember edge. |
| 1 | The plain MToon render. The effect is inert. |

The hold point 0.6 is a shader constant, exposed in Swift as `VRMMaterialization.charcoalHoldProgress`.

`hNorm` is clamped before use, so geometry outside `heightRange` (hair tips, shoes, a crouch, widened hull vertices) still reaches `sCol = 1` at `progress = 1`. Both `mat_resolve` and the hull widening return early when `progress >= 1`, so the inert case runs no charcoal arithmetic at all.

### Paper

The paper is not drawn by VRMMetalKit. The host clears its colour attachment to `VRMMaterialization.charcoalPaperColor`, (0.86, 0.83, 0.77).

Colour values in this document are the values the fragment writes. The MToon fragment does no output encoding: on a plain target such as `.bgra8Unorm` (the `RendererConfig` default, and what Creator captures into) they are stored as-is, and on an `_srgb` target the hardware encodes them. The look is tuned on `.bgra8Unorm`. The 2026-11-10 stills were rendered to an sRGB target, so their paper is lighter and their ink greyer than the clip will be. Bare paper on the avatar is exactly that colour with no grain, so the avatar's undrawn surface is seamless against the background. Paper tooth only shows where charcoal is deposited.

### Charcoal deposit model

All ink goes through one function. `tooth` is a 0..1 paper height field built from three octaves: a 2.4 px cell hash, 8 px value noise, and a coarse 11 to 30 px blotch. Pixel units are relative to a 1080-pixel-high output and scale with `viewportSize.y`.

```
deposit(pressure, tooth) = mix(smoothstep(0, 0.42, pressure - (1 - tooth)),
                               1,
                               smoothstep(0.78, 1.05, pressure))
```

Light pressure only catches the tooth peaks; heavy pressure fills to solid.

Ink colour is (0.030, 0.028, 0.026).

### Surface fragment (opaque and cutout materials)

1. **Contour.** A grazing-angle band on `abs(N·V)` with a low-frequency wobbling threshold and a soft inner feather, plus a curvature crease term from `fwidth(N)`. Broken by a dropout noise of about 19 px wavelength and scaled by a 70 px pressure noise.
2. **Stroke order.** A contour is "drawn" where `s` has passed a 46 px patch noise scaled to 0..0.24. Ahead of that, contours show as coherent grain-free grey dashes at 30% ink.
3. **Texture edges.** Ink where base-colour luminance changes sharply (`fwidth` of luminance), so eyes, lace and printed detail are drawn. This departs from the original spec's "shade by light, not colour" and is what makes the face readable.
4. **Tone.** `light = mix(halfLambert(key light), MToon shade ramp, 0.8)`, so the tone follows every light, the ambient and the authored shading shift, not the key light alone; shaded on undersides by a sky term on `N.y`, then multiplied down by a perceptual albedo value (`smoothstep(0.15, 0.75, sqrt(luma))`, weight 0.8).
5. **Hatching.** Three screen-space layers at 35°, -55° and 80°, 7 px spacing, appearing at tone below 0.62, 0.50 and 0.25. Strokes are broad, soft-edged, domain-warped, of finite length, with per-stroke strength. Layers arrive in order as `s` passes 0.30, 0.38 and 0.46.
6. **Fill and smudge.** A grainy fill in the darks, capped so stroke direction stays visible, over a grain-free grey smudge (about 20% in form shadows on pale surfaces, about 50% under the darks).
7. **Pale surfaces stay light.** Pale skin and fabric take at most the first hatch layer and the smudge. Facial shadow is a soft tone along the jaw and cheek; strokes do not cross the nose and mouth.
8. **Colour arrival.** `mix(sketch, lit, smoothstep(0.05, 0.25, sCol))`. Contour lines linger at about half strength over the arriving colour and settle out by `sCol = 0.7`.
9. **Ember.** A band centred on `sCol = 0.13`, half-width 0.10, tinted by `VRMMaterialization.color` (default (1.0, 0.42, 0.10)), with a darkened char rim just ahead of it around `sCol = 0.03`. Because `sCol` is 0 everywhere at the hold frame, a held sketch never glows. The char rim is part of the ember: a zero ember colour removes both.

### Blended materials

VRoid lashes, brows, blush and eye highlights are separate blended meshes. During the sketch:

- Dark overlays (luminance under about 0.3) draw as near-solid ink.
- Near-white, unsaturated overlays (eye highlights) draw as paper colour, cutting the highlight back out of the ink.
- Everything else (blush, tinted overlays) is fully transparent.

All three cross to their normal colour and alpha with the colour-arrival factor.

### Outline hull

The inverted-hull outline carries the contour weight:

- **Vertex:** while charcoal is active, the hull is widened in screen space by 2 to 6.5 px (at 1080p) with per-vertex pressure variation. The extra width grows in as the drawing front arrives and eases back to the authored width behind the colour front. It applies only where the material already has an outline, and respects the outline width mask.
- **Fragment:** tinted to the ink colour, returning to the authored outline colour as lines settle. Ahead of the drawing front the hull shows only as coherent dashes in 20% grey, matching the surface construction lines; once drawn it is ink and breaks up on the paper tooth where pressure is light.

This must cover all three hull paths: the merged colour-plus-outline draw on the rigid and skinned vertex shaders, and the dedicated outline pass (`mtoon_outline_vertex`, which has its own extrusion code).

### Line boil

`boilPhase` is an integer the host advances (the original spec's default is 10 steps a second). It is uploaded as an ordinary float, `Float(boilPhase & 0xFFFF)`, and decoded with `uint(w + 0.5)`. It must not be bit-cast: small integers are subnormal as float bit patterns and can be flushed to zero on the GPU. It is added to the seed of the stroke noises (contour wobble, dropout, pressure, hatch wobble and stroke breaks), so lines re-seed on each step. The paper tooth and the field `f` do not boil. `boilPhase = 0` with a still camera gives identical consecutive frames.

## API

```swift
public enum VRMMaterializationStyle: Int32 {
    // existing twelve cases
    case charcoal = 13
}

public struct VRMMaterialization {
    // existing fields
    public var boilPhase: UInt32 = 0        // charcoal only; uploaded in materializeOrigin.w

    public static let charcoalPaperColor: SIMD3<Float>   // (0.86, 0.83, 0.77)
    public static let charcoalHoldProgress: Float        // 0.6
}
```

- `VRMMaterializationStyle.requiresHostBackground` is true only for charcoal. Hosts that pick a style from `allCases` (Game of Mods' Construct picks one at random) use it to skip styles that need a specific clear colour.
- The twelve existing styles are unchanged. Goldens of all twelve are captured before any shader edit and checked after every change.
- `defaultColor(for: .charcoal)` is the ember colour, (1.0, 0.42, 0.10). Passing a zero colour turns the ember off (monochrome reveal).
- `boilPhase` is an added initialiser parameter with a default, so existing call sites compile unchanged.
- The `Uniforms` struct size and field offsets do not change.
- `usesDiscard` stays true for charcoal (the hull discards), so the depth prepass and contact shadow are skipped while it is active. This is my call, chosen as the conservative option.

## Constraints

- Shader edits follow the repo's shader workflow: `make shaders` for all five metallibs, update `knownGoodShaderHash`, commit the metallibs.
- Shaders compile with `-Wall -Wextra -Werror`.
- New files carry the Apache 2.0 header. No temporary or contextual comments in code.
- Work happens on a branch named `issue/{number}-charcoal-sketch` against a GitHub issue, with tests written before the implementation.
- `AvatarSample_U.png` is regenerated for the PR as the usual sanity render.

## Tests and acceptance

Automated, on the bundled VRM 1.0 fixture (`AvatarSample_A_1.0.vrm.glb`), rendered at `sampleCount = 1`. Every "byte-identical" comparison renders both frames from the same loaded model and the same renderer; comparisons against a different renderer configuration or a baseline commit use the existing differing-byte-fraction tolerance instead.

- **Inert at 1:** `progress = 1` is byte-identical to a render with no materialization.
- **Stripped when disabled:** with `enableMaterialization = false`, a charcoal materialization at any progress is byte-identical to the plain render.
- **Invisible by default:** with the effect compiled in but not set, output is byte-identical to the pre-change baseline commit, for both a rigid and a skinned material.
- **No colour in the sketch:** at `progress` 0, 0.3 and 0.6, every pixel lies on the line between paper colour and ink colour, within a small tolerance. On an `_srgb` target the readback bytes are decoded first, because the paper-ink mix is only a straight line in the space the fragment wrote.
- **Blank start:** at `progress = 0`, mean ink coverage over the frame is under a small bound (construction dashes only).
- **Hold frame is drawn:** at `progress = 0.6`, ink coverage inside the avatar's silhouette is well above the `progress = 0` value.
- **Monotonic colour:** as `progress` rises from 0.6 to 1, the count of pixels equal to the plain render never decreases. Only pixels that are chromatic in the plain render are counted (off the paper-ink line by more than about 0.04), so grey or black pixels that happen to match at the hold frame and are then crossed by the ember do not cause a false dip.
- **Deterministic:** two renders with the same inputs are byte-identical.
- **Boil:** a different `boilPhase` changes the frame at `progress = 0.6`; the same `boilPhase` does not.
- **Ember off:** a zero `color` produces no ember tint and no char rim at `progress = 0.8`.
- **Bookkeeping:** the style count test becomes thirteen; uniform size and offset tests still pass unchanged.

Also run once, not as permanent tests: the VRM 0.x fixture, a 4x MSAA render, and an animated clip, checking for crashes and obvious breakage.

By eye (Paul): the hold frame reads as charcoal, and the avatar is recognisable in it. The look is judged and tuned on the `AvatarSample*` fixtures at the repo root; no other avatar is required.

The approved reference is the spike stills from 2026-11-10, body and bust framings, at `progress` 0.30, 0.60 and 0.80. They are in `_visuals_charcoal/` at the repo root (untracked), with the spike's source patch and render test. They were made with `AvatarSample_A_1.0.vrm.glb`, seed 3, `heightRange 0...1.62`, 1080 x 1080, `sampleCount = 1`, an sRGB target, authored outlines, and `setupBrightToonLighting()`.

Both the lighting and the target format are the wrong target for the clip. Its key light travels upward, so the stills are lit from below; Creator replaces it with its own portrait rig (`AvatarLightRig`: key (-0.62, -0.52, -0.59) at 1.1, fill (0.25, -0.12, -0.96) at 0.55, back (0.51, -0.41, 0.76) at 0.55, ambient (0.20, 0.20, 0.22), radiometric). The first step of the build is to re-render the reference frames under that rig, on a `.bgra8Unorm` target, and get Paul's eye on them again. Tuning and the automated tests use that rig and format from then on.

The look also depends on the avatar: the blended-overlay split, the texture-edge threshold and the albedo value curve were tuned on one VRoid-style avatar, and the contour weight needs authored outlines. Tuning therefore checks more than one `AvatarSample*` fixture, including a VRM 0.x one.

Known tuning work, to be done against those stills and not blocking the structure:

- **Face shadow.** Under Creator's rig the spike cross-hatches the shadow side of the face. The target is a soft 10 to 15% jaw and cheek tone with the nose and mouth clear.
- **Pale fabric.** Settled by the relight: the cardigan's smudge and light hatching are at the right weight and should not go darker.
- **Dark tights.** They plug nearly solid on `.bgra8Unorm`; keep stroke direction legible.
- **Ember.** It is a soft peach patch. Without HDR, replace the single wide orange band with a tight three-stop ramp warped by noise: a dark char rim at `sCol` 0.02 to 0.06 (towards (0.02, 0.015, 0.01)), a narrow hot core at 0.06 to 0.10 (towards yellow-gold (1.0, 0.80, 0.30)), and a coal tail at 0.10 to 0.18 falling through red-orange (0.95, 0.25, 0.04) into the lit colour. The ramp is derived from `VRMMaterialization.color`; the values given are for the default.
- **Construction dashes.** They look like dark stencil ticks. Drop them to about 18 to 20% ink with a softer edge feather.

## Follow-on work (outside this repo or this design)

- **Creator:** opt in with `RendererConfig.enableMaterialization`, move its pin (currently one commit past 1.1.2) to a commit or release containing style 13, clear to the paper colour, keep any backdrop behind the avatar hidden until colour has fully arrived, drive `progress` and `boilPhase`, and add a fixed-timestep recording path, which it does not have today. Tracked as arkavo-org/Creator#141.
- **Game of Mods and Muse:** only need the pin and a style choice for avatars; props are out of scope. When Game of Mods moves its pin, `ConstructPasses.swift` must filter its random pick with `requiresHostBackground`, or one spawn in thirteen becomes a paper-coloured body on the Construct stage.
- **Screen-space path:** revisit only if the in-fragment look proves insufficient. Notes for that work: derivatives are unavailable in compute kernels; an integer object-ID target cannot be resolved under MSAA; the hull must be suppressed where a screen-space edge pass owns the linework.

## Left to the builder

- Exact noise functions and constants, within the look of the reference stills.
- Whether the hull widening is gated by a function constant or only by the runtime style check, provided the "invisible by default" test passes.
- How the tests measure "on the paper-ink line" and the coverage bounds.
- Whether the three run-once checks become permanent tests.

## Reference

Tracked as issue #471. A throwaway spike produced the approved stills. Its source diff is kept, uncommitted, at `_visuals_charcoal/charcoal-spike.patch`, with its render test beside it. It contains working versions of every stage above except line boil, the dedicated outline pass, the three-stop ember and the `fNoisy` form of the field. It is a reference for the look and the constants, not a base to apply: it has no tests and was only ever built for macOS.
