# Strict Mode

Catch renderer integration bugs early with runtime validation of buffer bindings, draw-call shape, and uniform layout.

## Overview

Strict mode is the renderer's built-in validation layer. It checks the structural correctness of every frame: that buffer and texture indices fall inside the argument table, that vertex buffers are large enough for the vertex count and stride a primitive declares, that the Swift-side uniform structs match their Metal counterparts byte-for-byte, that joint and morph indices stay inside their declared ranges, and that no draw call is silently empty. It does **not** check shader source correctness, nor does it diff pixel output — those belong to the Metal compiler and to your visual regression harness respectively.

Strict mode is configured once, at renderer construction, via ``RendererConfig/strict``. The level you pick is a policy decision about how aggressively validation should interrupt the frame. Leave it at ``StrictLevel/off`` in production, raise it to ``StrictLevel/warn`` while a feature is in active development, and pin it to ``StrictLevel/fail`` inside test suites so a regression in binding layout fails the test rather than silently rendering black.

## The three levels

- ``StrictLevel/off`` — production default. Validators still log to the package's logging hooks, but no errors are collected and nothing is thrown. Zero observable overhead in a release build.
- ``StrictLevel/warn`` — every violation is logged with the `[StrictMode.warn]` prefix and collected into a per-frame error list. The frame still completes. At end-of-frame, the validator emits a one-line summary of how many errors fired. Use this in CI smoke tests and integration runs.
- ``StrictLevel/fail`` — the first violation throws ``StrictModeError`` out of the encoder. The frame is abandoned. Use this in unit tests and during local debugging so a regression surfaces with a stack trace at its source instead of as a missing draw call.

## Enabling strict mode

```swift
import VRMMetalKit
import Metal

let device = MTLCreateSystemDefaultDevice()!
let config = RendererConfig(strict: .fail)
let renderer = VRMRenderer(device: device, config: config)
// Any binding or draw-call violation now throws StrictModeError.
```

## Narrowing with RenderFilter

When you already know which mesh or material is misbehaving, set ``RendererConfig/renderFilter`` to a ``RenderFilter`` value to skip every draw call except the matching one. The three cases — `.mesh(name)`, `.material(name)`, `.primitive(index)` — pair well with the adjacent debug knobs ``RendererConfig/drawUntil`` and ``RendererConfig/drawOnlyIndex``, which bisect by sorted-draw-list position. All three are diagnostic-only; leave them `nil` in production.

## What gets validated

- Shader function presence in the library — ``StrictModeError/missingVertexFunction(name:)``, ``StrictModeError/missingFragmentFunction(name:)``, ``StrictModeError/missingComputeFunction(name:)``.
- Pipeline-state creation — ``StrictModeError/pipelineCreationFailed(_:)``.
- Uniform struct byte layout vs. its Metal counterpart — ``StrictModeError/uniformLayoutMismatch(swift:metal:type:)``.
- Uniform and vertex buffer sizing — ``StrictModeError/uniformBufferTooSmall(required:actual:)``, ``StrictModeError/vertexBufferTooSmall(required:actual:)``.
- Argument-table index conflicts — ``StrictModeError/bufferIndexConflict(index:existing:new:)``, ``StrictModeError/textureIndexConflict(index:)``, ``StrictModeError/samplerIndexConflict(index:)``.
- Vertex attribute format and stride — ``StrictModeError/invalidVertexFormat(attribute:expected:actual:)``, ``StrictModeError/vertexStrideInvalid(expected:actual:)``, ``StrictModeError/missingVertexAttribute(name:)``.
- Empty draw calls and out-of-range indices — ``StrictModeError/zeroVertices(primitive:)``, ``StrictModeError/zeroIndices(primitive:)``, ``StrictModeError/invalidIndexRange(max:vertexCount:)``, ``StrictModeError/noDrawCalls(expected:)``.
- Skinning and morph index ranges — ``StrictModeError/jointIndexOutOfBounds(joint:max:)``, ``StrictModeError/invalidJointCount(expected:actual:)``, ``StrictModeError/morphIndexOutOfBounds(index:max:)``, ``StrictModeError/morphWeightInvalid(index:weight:)``.
- Command-buffer status at frame end — ``StrictModeError/commandBufferFailed(error:)``.

## What does NOT get validated

- Shader source correctness — that is the Metal compiler's job, surfaced at `make shaders` time.
- Pixel output correctness — wire up a visual-diff harness; strict mode only sees structure.
- GPU-side state machine validity beyond what the Metal API validation layer (enabled via ``RendererConfig/enableMetalValidation``) already covers.

## Topics

### Configuration

- ``StrictLevel``
- ``RendererConfig/strict``
- ``RenderFilter``
- ``RendererConfig/renderFilter``

### Errors

- ``StrictModeError``

### Related

- ``RendererConfig``
- ``VRMRenderer``
