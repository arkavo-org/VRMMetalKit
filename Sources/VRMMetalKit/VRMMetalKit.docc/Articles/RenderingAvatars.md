# Rendering Avatars

Drive a ``VRMRenderer`` from your render loop, tune it for MSAA and strict validation, and control MToon outline width.

## Overview

A ``VRMRenderer`` is long-lived. Create one per `Apple` `MTLDevice`, hand it a loaded ``VRMModel`` once, and then call into it every frame from your render loop. The renderer owns the pipeline cache (``VRMPipelineCache``), triple-buffered uniforms, and the dual skinned / non-skinned pipelines, so reusing a single instance across frames is what keeps the GPU hot path free of stalls.

Configuration is split across two surfaces. ``RendererConfig`` is the immutable, init-time bundle: pixel format, MSAA sample count, strict-mode policy, and a handful of debug filters that let you cull draw calls. Per-frame and per-material knobs — outline width, expression weights, animation playback — are properties on the renderer or on the model's materials. When in doubt, reach for ``RendererConfig`` first; everything else is reachable after construction.

## Configure the renderer

The fields you will tune most often on ``RendererConfig`` are ``RendererConfig/strict``, ``RendererConfig/sampleCount``, and ``RendererConfig/colorPixelFormat``. `sampleCount: 4` enables 4x MSAA *and* alpha-to-coverage for MASK materials, which smoothly fades alpha-cutout edges using subpixel coverage instead of the hard binary threshold you get at 1x. `colorPixelFormat` defaults to `.bgra8Unorm` to match a standard `CAMetalLayer`; change it if you render into a different target.

The remaining init parameters — `renderFilter`, `drawUntil`, `drawOnlyIndex`, `testIdentityPalette`, `depthBiasScale` — exist for diagnostics and bisecting rendering bugs. They are documented on the ``RendererConfig`` symbol page and are not part of the day-to-day API.

## High-quality rendering

A config tuned for offline rendering or a production preview surface enables MSAA and turns on warn-level validation so any binding mistakes show up in the log without halting the render:

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

## Outlines

MToon outlines are drawn as a second, inverted-hull pass over each MToon mesh whose ``VRMMToonMaterial/outlineWidthMode`` is not `.none`. The per-material width comes from ``VRMMToonMaterial/outlineWidthFactor``; the renderer's global ``VRMRenderer/outlineWidth`` (default `0.02`) acts as a scale factor that is normalized by dividing by `0.02`, so leaving it at the default reproduces the material's authored width exactly. Lower it for tighter outlines across every MToon material at once. See the MToon Topics group for the full material model.

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
- ``VRMPipelineCache``

### MToon materials

- ``VRMMToonMaterial``
- ``VRMOutlineWidthMode``
- ``MToonMaterialUniforms``

### Validation

- ``StrictLevel``
- ``RenderFilter``
- <doc:StrictMode>
