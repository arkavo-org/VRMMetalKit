# Rendering Avatars

Drive a ``VRMRenderer`` from your render loop, tune it for MSAA and strict validation, and control the MToon outline and the opt-in finish, hair, and grounding effects.

## Overview

A ``VRMRenderer`` is long-lived. Create one per `Apple` `MTLDevice`, hand it a loaded ``VRMModel`` once, and then call into it every frame from your render loop. The renderer owns the pipeline cache (``VRMPipelineCache``), triple-buffered uniforms, and the dual skinned / non-skinned pipelines, so reusing a single instance across frames is what keeps the GPU hot path free of stalls.

Configuration is split across two surfaces. ``RendererConfig`` is the immutable, init-time bundle: pixel format, MSAA sample count, strict-mode policy, finish/hair/shadow switches, and a handful of debug filters that let you cull draw calls. Per-frame and per-material knobs — outline scale, expression weights, animation playback — are properties on the renderer or on the model's materials. When in doubt, reach for ``RendererConfig`` first; everything else is reachable after construction.

## Configure the renderer

The fields you will tune most often on ``RendererConfig`` are ``RendererConfig/strict``, ``RendererConfig/sampleCount``, and ``RendererConfig/colorPixelFormat``. `sampleCount: 4` enables 4x MSAA *and* alpha-to-coverage for MASK materials, which smoothly fades alpha-cutout edges using subpixel coverage instead of the hard binary threshold you get at 1x. `colorPixelFormat` defaults to `.bgra8Unorm` to match a standard `CAMetalLayer`; change it if you render into a different target.

The remaining init parameters — `renderFilter`, `drawUntil`, `drawOnlyIndex`, `testIdentityPalette`, `depthBiasScale` — exist for diagnostics and bisecting rendering bugs. They are documented on the ``RendererConfig`` symbol page and are not part of the day-to-day API.

## High-quality rendering

A config tuned for offline rendering or a production preview surface enables MSAA, tightens outlines, and turns on warn-level validation so any binding mistakes show up in the log without halting the render:

```swift
import VRMMetalKit
import Metal

let device = MTLCreateSystemDefaultDevice()!

var config = RendererConfig(
    strict: .warn,
    sampleCount: 4
)

let renderer = VRMRenderer(device: device, config: config)

// Optional: tighten outlines globally. Per-material widths still
// come from VRMMToonMaterial.outlineWidthFactor.
renderer.outlineWidth = 0.015
```

## Metallic and roughness finishes

MToon ignores the glTF `pbrMetallicRoughness` pair, and so does this renderer
by default. ``RendererConfig/enableMaterialFinish`` opts in to a **stylized
two-lobe finish** driven by those factors:

```swift
var config = RendererConfig()
config.enableMaterialFinish = true
let renderer = VRMRenderer(device: device, config: config)
```

Enable it only for assets whose metallic/roughness values were authored for
it. VRoid and UniVRM exports routinely write the glTF default
`metallicFactor = 1.0` on every material, skin and eyes included, and three-vrm
discards the pair on MToon materials; turning the finish on for such an avatar
puts a metal highlight on its face.

| `metallicFactor` | ``MToonSpecularMode`` | Shader behavior |
|---|---|---|
| `<= 0.0001` | `off` | The finish is skipped. |
| above `0.0001`, below `0.7` | `sheen` | A broad half-vector lobe at dielectric strength (at most 10% of the incident light) in the base colour's hue dominates: leather, patina, painted props. |
| `>= 0.7` | `metal` | A tight, base-colour-tinted band dominates. |

The two lobes blend: the metal weight ramps from `0.6` to `0.8`, and the mode
names whichever lobe dominates. Lower `roughnessFactor` narrows both lobes over
the whole `0...1` range. The leather reference is `0.22 / 0.36`
(metallic/roughness) and the metal reference `0.95 / 0.22`.

The finish is independent of ``VRMMToonMaterial/parametricRimColorFactor``: it
follows the light's reflection direction, while the parametric rim is a fresnel
silhouette term. Like the rim, it scales with light colour and the
light-normalization factor (not the Lambert `1/π`), so it stays linear in light
intensity. It shades from a full-precision normal, so glossy bands keep a clean
edge on the half-precision shader slices.

## Outlines

MToon outlines are drawn as a second, inverted-hull pass over each MToon mesh
whose ``VRMMToonMaterial/outlineWidthMode`` is not `.none`. The per-material
width comes from ``VRMMToonMaterial/outlineWidthFactor``.

Two multipliers compose:

- ``VRMRenderer/outlineWidth`` (default `0.02`) is the legacy global knob. The
  renderer normalizes it by dividing by `0.02`, so the default is exactly `1x`
  the authored width. This keeps existing projects unchanged.
- ``VRMRenderer/outlineScale`` (default `1.0`) is an explicit multiplier where
  `1.0` means "use the authored width".

The effective multiplier is `(outlineWidth / 0.02) * outlineScale`. Setting
either multiplier to zero disables the pass.

The hull is drawn after its surface and never writes depth, as in three-vrm and
UniVRM. On a translucent material that means the surface's depth write decides
what you see: with `VRMC_materials_mtoon.transparentWithZWrite` the surface
writes depth and the outline shows only at the silhouette; without it the
outline covers the surface.

### Units

| Outline mode | Extrusion |
|---|---|
| `.worldCoordinates` | `outlineWidthFactor × camera distance × 0.01` world units along the normal. The distance term keeps the line's on-screen width constant as the camera moves, so a VRoid-typical `0.0005` is a small fraction of a pixel at any distance. |
| `.screenCoordinates` | `outlineWidthFactor` device pixels. |

### Minimum width

``VRMRenderer/outlineMinimumPixels`` sets a floor in device pixels. Wherever
the authored width projects thinner than the floor, the vertex is extruded in
screen space by the floor instead. The floor is scaled by
`outlineWidthMultiplyTexture`, so masked texels stay outline-free, and a
material with a zero width never gains a line.

```swift
renderer.outlineMinimumPixels = 1.5   // readable at 512–1024 px
```

The floor is absolute: where it applies, ``VRMRenderer/outlineScale`` has no
visible effect, so raise `outlineMinimumPixels` for a thicker sheet line. `0`
(the default) draws the authored width only, exactly as before. The floor
applies on every hull path: single- and double-sided, rigid and skinned.

## Hair highlight

Hair can opt into a stylized strand highlight. It is off by default and only
applies to materials selected by ``HairHighlightConfig``:

```swift
var config = RendererConfig()
config.hairHighlight = HairHighlightConfig(
    isEnabled: true,
    strength: 0.9,
    sharpness: 8,
    materialNameContains: "hair")   // nil = every material

let renderer = VRMRenderer(device: device, config: config)
```

The band runs across the strand direction, taken from the material's UV `v`
axis (how VRoid-style hair UVs are laid out), and falls back to a view-based
tangent where the UVs do not vary. It follows the key light and the camera and
fades at grazing angles. `strength` (`0...2`) controls intensity and
`sharpness` (`1...64`) width; values outside those ranges are clamped. Like the
finish, the band is linear in light intensity. Its tint follows the base colour
more closely as the hair darkens: light hair gets a pale band, and dark hair
(linear luminance up to `0.05`) is brightened in its own hue rather than
streaked grey.

## Contact shadow and crease AO

Both effects are opt-in and default off:

```swift
var config = RendererConfig()
config.enableContactShadows = true
config.contactShadowOpacity = 0.45   // clamped to 0...1
config.contactShadowScale = 1.15     // footprint radius multiplier, at least 0.1

config.enableSSAO = true
config.ssaoStrength = 0.6            // clamped to 0...2
```

``RendererConfig/enableContactShadows`` draws a soft radial shadow on the
ground. A skinned humanoid is grounded at its feet: the shadow is centred
between the current foot joints and sized to the stance, so it follows the
skeleton as the avatar moves and ignores T-pose arms. Other models (props,
rigid glTF) use the world bounds of every mesh node. The shadow is drawn before
the model, like part of the ground: opaque geometry covers it, translucent
surfaces and outlines are composited over it, and it lands on a floor the host
drew into the same depth buffer.

``RendererConfig/enableSSAO`` adds a screen-space **crease AO** term for
clothing and hair folds. It is a depth-free, derivative-based approximation of
SSAO (the screen-space normal gradient acts as an occlusion proxy), confined to
the indirect/ambient term exactly like a glTF occlusion map. It is not a
ray-marched SSAO and needs no depth prepass.

``PerformanceMetrics/contactShadowMs`` reports the shadow's CPU encode time.
The finish, hair band, and crease AO are per-fragment GPU work with no CPU
phase of their own; compare GPU frame times with the feature on and off.

### Pipeline cost

The finish, hair band, and crease AO are function-constant specializations.
With all three off the output is exactly what it was before they existed. With
``RendererConfig/enableMToonFunctionConstants`` on (the default), each material
compiles in only the extensions it uses, so materials an extension does not
touch render exactly as before and pay nothing for it. Without function
constants a single fallback pipeline serves every material, so enabling an
extension compiles it in for all of them; untouched materials then cost a
little more and can differ by at most one 8-bit step on one channel.

## Supported material parameters

| Parameter | Source | Units / range | Renderer behavior |
|---|---|---|---|
| `pbrMetallicRoughness.baseColorFactor` | glTF core | Linear RGBA, `0...1` | Multiplied into the base-colour texture. |
| `pbrMetallicRoughness.baseColorTexture` | glTF core | Texture + UV set | Sampled with `KHR_texture_transform` applied. |
| `pbrMetallicRoughness.metallicFactor` | glTF core | `0...1` | Ignored unless ``RendererConfig/enableMaterialFinish``; then selects off/sheen/metal. |
| `pbrMetallicRoughness.roughnessFactor` | glTF core | `0...1` | Lobe width of the opt-in finish. |
| `normalTexture` + `normalTextureInfo.scale` | glTF core | Texture; scale `0...` | Tangent-space normal with a screen-derivative TBN. TANGENT vertex attributes are not read. |
| `occlusionTexture` + `occlusionTextureInfo.strength` | glTF core | Texture; strength `0...1` | Attenuates indirect/ambient only. |
| `emissiveFactor` + `emissiveTexture` | glTF core | Linear RGB | Added after lighting. |
| `alphaMode`, `alphaCutoff`, `doubleSided` | glTF core | OPAQUE / MASK / BLEND | Selects the pipeline, alpha test, and culling. |
| `KHR_texture_transform` | glTF extension | Offset / rotation / scale | Baked into every texture lookup. |
| `shadeColorFactor`, `shadeMultiplyTexture` | VRMC_materials_mtoon | Linear RGB, texture | Shadow-side toon colour. |
| `shadingToonyFactor`, `shadingShiftFactor`, `shadingShiftTexture` | VRMC_materials_mtoon | `0...1`, `-1...1` | Shape the toon ramp. VRM 0.x inputs are converted on load. |
| `giEqualizationFactor` | VRMC_materials_mtoon | `0...1` | Indirect albedo mix (see `docs/MTOON_GI_SPEC.md`). |
| `matcapFactor`, `matcapTexture` | VRMC_materials_mtoon | RGB, texture | Additive view-space matcap. |
| `parametricRimColorFactor`, `...FresnelPowerFactor`, `...LiftFactor`, `rimMultiplyTexture`, `rimLightingMixFactor` | VRMC_materials_mtoon | Colour / `>=0` / `0...1` | Fresnel rim, independent of the finish. |
| `outlineWidthMode`, `outlineWidthFactor`, `outlineWidthMultiplyTexture`, `outlineColorFactor`, `outlineLightingMixFactor` | VRMC_materials_mtoon | Mode enum; see the units table | Inverted-hull outline. The width mask reads the G channel. |
| `uvAnimation*` | VRMC_materials_mtoon | UV units / radians per second | Scroll/rotation with an optional mask. |

## Material report

``VRMRenderer/generateMaterialReport()`` emits a Codable per-material record
that includes the authored `metallicFactor` and `roughnessFactor`, the
`specularMode` this renderer draws (`off` unless the finish is enabled, then
`off` / `sheen` / `metal`), `outlineMode`, and `outlineWidthFactor`, alongside
the existing alpha and texture diagnostics.

## Strict mode

During development, promote validation from `.warn` to `.fail` so invalid buffer bindings and empty draw calls throw rather than silently rendering nothing. See <doc:StrictMode> for the full policy matrix.

```swift
var config = RendererConfig(strict: .fail, sampleCount: 4)
let renderer = VRMRenderer(device: device, config: config)
```

## Topics

### Renderer

- ``VRMRenderer``
- ``RendererConfig``
- ``HairHighlightConfig``
- ``VRMPipelineCache``

### MToon materials

- ``VRMMToonMaterial``
- ``VRMOutlineWidthMode``
- ``MToonMaterialUniforms``
- ``MToonSpecularMode``

### Validation

- ``StrictLevel``
- ``RenderFilter``
- <doc:StrictMode>
