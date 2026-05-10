# MToon 1.0 — Global Illumination spec excerpt and our deviation

This document quotes the canonical MToon 1.0 specification on
`giEqualizationFactor`, then documents how `VRMMetalKit` currently
implements indirect diffuse and where it deviates from the spec.

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

## What `VRMMetalKit` does today (and how it deviates)

`Sources/VRMMetalKit/Shaders/MToonShader.metal` (indirect-diffuse
section) currently computes:

```metal
float3 giAlbedo = mix(shadeColor, baseColor.rgb, material.giEqualizationFactor);
float3 indirectDiffuse = uniforms.ambientColor.xyz * giAlbedo;
```

This is **not** what the spec defines. We have no IBL/SH plumbing, so we
have no `rawGi(n)` that varies with normal direction — meaning the
spec-correct implementation degenerates to a no-op: `lerp(ambient, ambient, factor) = ambient`.

Rather than ship the no-op, we reinterpret `giEqualizationFactor` as a
lit-side / shade-side mix on the indirect *albedo* (not on the indirect
*illumination*). At `factor = 1.0` indirect uses the lit baseColor; at
`factor = 0.0` indirect uses the shadeColor. This gives authors a
visually meaningful artistic knob today and approximates what
sphere-equalized indirect would look like under harsh lighting.

This is documented as a known deviation. When IBL/SH plumbing lands the
shader should be updated to compute `gi(n)` per the spec.

### What this means for spec-authored content

- If a model author tunes `giEqualizationFactor` against three-vrm or
  another spec-aware renderer with IBL, they will see a different image
  in `VRMMetalKit` than they expect.
- Without IBL, neither three-vrm's nor our renderer can faithfully
  implement the spec — three-vrm declares the uniform but doesn't apply
  it (`RE_IndirectDiffuse_MToon`), so its non-IBL output also doesn't
  match the spec.
- Our deviation produces a meaningful visual difference at non-default
  values; three-vrm's no-op behavior produces no difference.

## Testing

`Tests/VRMMetalKitTests/RendererLightingCorrectnessTests.swift` tests
the current implementation behavior, not the spec behavior. The tests
labeled `testGIEqualizationFactor*` verify our lit/shade mix
interpretation. A spec-conformant test would require IBL infrastructure
to distinguish `passthroughGi` from `uniformedGi`.

## Open work

Tracked separately. The IBL/SH implementation work would let us:

1. Implement `rawGi(n)` from a cubemap or SH probe.
2. Compute `uniformedGi` as the spec describes (or with SH low-order
   approximation).
3. Replace the lit/shade mix with the spec lerp.
4. Update the regression tests to check actual spec compliance.
