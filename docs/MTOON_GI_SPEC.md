# MToon 1.0 — Global Illumination spec excerpt and VMK's implementation

This document quotes the canonical MToon 1.0 specification on
`giEqualizationFactor`, then documents how `VRMMetalKit` implements
indirect diffuse.

## Source

[VRMC_materials_mtoon-1.0/README.md (vrm-c/vrm-specification, master)](https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_materials_mtoon-1.0/README.md)

Section: "GI Equalization Factor".

## What the spec defines

> The GI Equalization Factor allows the geometry to have constant global
> illumination independent of the geometry's face direction. As a result,
> the resulting shading under global illuminations is weaker and the
> geometry's detail becomes milder. Specifically, this is achieved by
> smoothing the global illumination factor depending on the direction.

Pseudocode (verbatim from the spec):

```
let giEqualizationFactor: number

let worldUpVector: Vector3 = Vector3(0, +1, 0)
let worldDownVector: Vector3 = Vector3(0, -1, 0)

let uniformedGi: ColorRGB = (rawGi(worldUpVector) + rawGi(worldDownVector)) / 2.0
let passthroughGi: ColorRGB = rawGi(normal)

let gi: ColorRGB = lerp(passthroughGi, uniformedGi, giEqualizationFactor)

-- color already has the direct lighting factor
color = color + gi * litColor
```

Default: `0.9`. Range: `[0.0, 1.0]`.

`rawGi(n)` is the renderer's directionally-sampled indirect illumination —
i.e. it requires a directional GI source such as IBL, SH lighting, or
environment cubemap probes. With those, `rawGi(up)`, `rawGi(down)` and
`rawGi(normal)` differ; the lerp meaningfully smooths between
"directional" and "uniform" indirect illumination.

## What `VRMMetalKit` does

`Sources/VRMMetalKit/Shaders/MToonShader.metal` (indirect-diffuse
section) computes:

```metal
float3 indirectDiffuse = uniforms.ambientColor.xyz * baseColor.rgb * occlusionFactor;
```

VMK's only global illumination is a uniform ambient colour, so `rawGi(n)`
is the same in every direction: `rawGi(normal)`, `rawGi(up)` and
`rawGi(down)` all equal the ambient colour, `uniformedGi` equals it too, and
`gi = lerp(ambient, ambient, factor) = ambient` for any factor. The indirect
term is therefore `ambient * litColor`, exactly as the spec defines it for
this lighting, and `giEqualizationFactor` has no visible effect until VMK
gains directional GI.

Before 1.2.1 VMK used `ambient * mix(shadeColor, baseColor, giEqualizationFactor)`,
an artistic reinterpretation of the factor. With the default factor of 0.9
that put a tenth of the shade colour into the indirect term and lowered the
base colour's share, which made shaded areas differ from the spec (#465).

### What this means for spec-authored content

- Content renders as the spec defines it under uniform ambient light.
- `giEqualizationFactor` is parsed and kept on the material, ready for
  directional GI; it does not change the image today.
- three-vrm declares the uniform but doesn't use it either; its indirect
  term is `irradiance * BRDF_Lambert(diffuseColor)`, which adds a `1/π` the
  spec doesn't have.

### Direct-vs-indirect magnitude ratio (post-#205)

After [#205](https://github.com/arkavo-org/VRMMetalKit/issues/205), direct
lighting is multiplied by `BRDF_LAMBERT_NORM = 1/π` at the accumulation
site (matching three-vrm's `BRDF_Lambert` and UniVRM Built-in RP). Indirect
is **not** scaled by `1/π` — both because the no-IBL approximation
treats `irradiance = ambientColor` directly (no implicit `π`-scaling at
the source the way three.js does for some chunks) and because the spec
itself doesn't apply a Lambert BRDF to the indirect path.

The visible consequence: pre-#205 the brightest direct contribution
reached unit albedo (`1.0`) while ambient typically sat at `0.15–0.30`,
so direct dominated. Post-#205 the brightest direct contribution sits at
`albedo/π ≈ 0.318`, which is **comparable in magnitude to typical ambient**
(`0.15–0.30 × baseColor`). This is the intended steady state
for spec-aligned brightness — three-vrm shows the same direct/indirect
balance once both terms route through its `BRDF_Lambert(diffuseColor)`.

Practical implication for authors:

- A previously-tuned `ambientColor = 0.3` scene is now closer to a 50/50
  direct/indirect mix on the lit hemisphere instead of the prior ~25/75
  direct-dominant mix. Outputs land in the reference cluster but
  *individual scenes will look different from pre-#205 captures*.
- `setLightNormalizationMode(.manual(factor))` multiplies on top of the
  `/π` — `factor = 1.0` is now ~`1/π × pre-#205 brightness`. Pre-#205
  scenes that hardcoded `.manual(…)` may want to multiply their factor
  by `π` to recover the prior overall magnitude.

## Testing

`Tests/VRMMetalKitTests/RendererLightingCorrectnessTests.swift` checks the
spec behaviour under uniform ambient light: `giEqualizationFactor` 0 and 1
render identically, the indirect term carries the base colour, and no shade
colour leaks into it.

## Open work

Directional GI (#328) would let VMK:

1. Implement `rawGi(n)` from a cubemap or SH probe.
2. Compute `uniformedGi` as the spec describes (or with SH low-order
   approximation).
3. Apply the spec lerp, at which point `giEqualizationFactor` takes effect.
4. Extend the tests to cases where `rawGi(n)` varies with the normal.

## Direct lighting brightness conventions

Companion topic to the GI lerp above: matching the consortium reference
implementations' **direct** lighting brightness requires aligning on the
input convention for per-light intensity. Three reference cluster
points + VMK's choice:

| Renderer | Shader `BRDF_Lambert(1/π)` | Input intensity convention |
|---|---|---|
| **UniVRM Built-in RP** (`vrmc_materials_mtoon_lighting_mtoon.hlsl:79-82`) | **no** — returns `albedo × directLightColor × shadow` | Unity's `_LightColor0` pre-absorbs π |
| **three-vrm** (`mtoon.frag.glsl`, `getDiffuse`) | **yes** | vrm-conformance adapter pre-scales authored intensity by π |
| **VMK** (`MToonShader.metal:655`) | **yes** (per #205) | API takes "photometric" intensity (e.g. `1.0` ≈ "one unit of light") |

VMK applies `BRDF_LAMBERT_NORM = 1.0 / π` correctly per the Lambert BRDF
spec, but its public lighting API accepts intensity in the **photometric**
convention: a caller passing `intensity: 1.0` produces an effective light
contribution of `1.0 × (1/π) ≈ 0.318` after the shader's normalization.
That's the right answer if "1.0" means "one unit of perceived light";
it's ≈ 0.318× the UniVRM/three-vrm reference if "1.0" means "one unit of
radiometric flux" (the conformance corpus convention).

### `LightNormalizationMode.radiometric`

To match the reference cluster's brightness scale, set:

```swift
renderer.setLightNormalizationMode(.radiometric)
```

`.radiometric` sets `uniforms.lightNormalizationFactor = π`, which cancels
the shader's internal `1/π`. After this opt-in, a caller-passed
`intensity: 1.0` produces brightness matching UniVRM Built-in RP and
three-vrm rendering the same vrm-conformance test plan (the canonical
`mtoon_*.test.yaml` `intensity: 1.0` setup).

History: shipped in 0.14.x to close [vrm-conformance issue #213](https://github.com/arkavo-org/VRMMetalKit/issues/213).
The issue originally hypothesised a curve-shape mismatch (smoothstep vs
linearstep), but all three reference shaders use the same `linearstep`
formula. The real divergence was the intensity-unit mismatch above.

### Per-tool defaults

- `setup3PointLighting()` (auto-installed at `init`) keeps `.automatic`.
  Production apps that didn't pick a preset see no behaviour change.
- `setupBrightToonLighting()` (the `VRMRender` CLI preset) opts into
  `.radiometric` and rescales its 3-point intensities by `1.25 / π` so the
  visual output is preserved exactly.
- The `VRMVideoRenderer` and `VRMBenchmark` CLI presets opt into
  `.radiometric` with intensities rescaled by `1.0 / π` (their previous
  effective normalization was `.automatic` = 1.0).
