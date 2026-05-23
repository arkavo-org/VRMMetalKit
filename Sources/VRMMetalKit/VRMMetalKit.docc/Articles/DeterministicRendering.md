# Deterministic Rendering

Byte-identical output across repeated runs for golden-image regression suites, conformance harnesses, and CI pixel diffing.

## Overview

For an interactive avatar app, "deterministic" doesn't matter — what matters is that the chain motion *feels* right under the actual wall-clock pacing of the display. For an offline test rig or a conformance harness, the calculus inverts: the same input has to produce the same pixels on every run, on every machine. VRMMetalKit ships an explicit deterministic-rendering contract for the second case, kept out of the way for the first.

## The contract

Given a ``VRMRenderer`` configured with ``RendererConfig/synchronousSpringBone`` set to `true`, repeated calls to ``VRMRenderer/drawOffscreenHeadless(to:depth:commandBuffer:renderPassDescriptor:)`` against the same input — same model state, same animation state, same camera, same lighting, same target format — produce byte-identical output, on identical hardware, in the same OS/driver build.

What "the same input" means concretely:

- The `VRMModel` instance is loaded the same way (same VRM bytes, same loader options).
- The animation state at the time of each render is the same — the same VRMA clip applied at the same time, or the same direct node-transform overrides.
- The camera (`projectionMatrix`, `viewMatrix`) and lighting (lights, ambient, normalization mode) are bit-equal.
- The render targets are created with the same `MTLPixelFormat` and dimensions.
- The host hardware is the same. Cross-hardware bit-determinism is *not* part of the contract; Metal driver differences across GPU families can produce small floating-point divergence even on the same shader bytecode.

## Why the flag changes timestep behavior

The spring-bone integrator (``SpringBoneBuffers`` + the XPBD compute kernel) advances on a fixed 120 Hz substep cadence, but the *number* of substeps per render call depends on the delta-time the caller passes in. By default `VRMRenderer` measures elapsed wall-clock time between draws via `CACurrentMediaTime()` — correct for interactive use, fatal for reproducibility because the per-render substep count drifts run to run.

When `synchronousSpringBone == true` and ``VRMRenderer/simulationDeltaTime`` is unset, the renderer instead feeds the integrator a fixed `1/60 s` per render call. Same delta-time, same substep count, same physics, same pixels. Set ``VRMRenderer/simulationDeltaTime`` explicitly to override the 60 Hz default — useful when the test rig wants to render at a non-60 fps cadence (video frame extraction, slow-motion analysis).

Issue [#283](https://github.com/arkavo-org/VRMMetalKit/issues/283) is the historical context: before this contract, the conformance suite's animated multi-joint swing reproducer produced multiple distinct PNGs from the same binary and same input across repeated runs, because the wall-clock-derived delta-time picked up a different substep count each frame. The renderer-side fix made `synchronousSpringBone` the single switch that opts an offline harness into reproducibility.

## Canonical offline-render config

```swift
import Metal
import VRMMetalKit

let device = MTLCreateSystemDefaultDevice()!
var config = RendererConfig()
config.sampleCount = 4                  // MSAA, optional
config.synchronousSpringBone = true     // <-- the determinism flag
let renderer = VRMRenderer(device: device, config: config)
renderer.loadModel(model)
renderer.enableSpringBone = true

// Camera, lighting, render target setup as usual...

// Each draw is deterministic given the model + animation state above it.
renderer.drawOffscreenHeadless(
    to: colorTexture,
    depth: depthTexture,
    commandBuffer: commandBuffer,
    renderPassDescriptor: rpd
)
```

For a test rig running at a custom cadence — say, extracting one frame every 1/30 s — also set ``VRMRenderer/simulationDeltaTime``:

```swift
renderer.simulationDeltaTime = 1.0 / 30.0
```

## Regression gates

Two test files in this repository gate the contract and serve as the canonical examples:

- `SpringBoneRendererDeterminismTests.testSynchronousSpringBoneIsDeterministicAcrossRendererRuns` — drives 15 swing frames through the renderer 12 times with `synchronousSpringBone = true` and no explicit `simulationDeltaTime`, asserts byte-identical `bonePosCurr` across every run. This is the bit-determinism gate for the renderer path; if it fails, the contract above is broken.
- `MToonShadingBoundaryRenderTests` — renders three MToon material-boundary sweeps (`shadingShift`, `shadingToony`, `rimLightingMix`) and asserts each sweep produces distinct SHA256 hashes. This is the spec-equivalence gate; the determinism contract is what lets it use raw pixel hashes instead of SSIM thresholds.

`SpringBoneAnimatedDeterminismTests` covers the sim-level (``SpringBoneComputeSystem``) path with an explicit `deltaTime`; pair it with the renderer-level test above for end-to-end coverage.

## When to leave the flag off

Live applications driving frames at display-refresh rate should leave `synchronousSpringBone` and `simulationDeltaTime` at their defaults. Wall-clock-based timing keeps the chain motion's *feel* tied to actual elapsed time, which is what users perceive as "natural". The synchronous path also costs one extra GPU/CPU sync per frame — fine for offline rendering, a fps hit at 60 fps interactive.

## Topics

### Configuration

- ``RendererConfig/synchronousSpringBone``
- ``VRMRenderer/simulationDeltaTime``

### Related

- <doc:SpringBonePhysics>
- <doc:RenderingAvatars>
