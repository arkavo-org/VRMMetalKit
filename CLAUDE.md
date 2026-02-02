# CLAUDE.md / AGENTS.md

## Project Overview
**VRMMetalKit** is a high-performance Swift Package for loading, rendering, and animating VRM 1.0 avatars using Apple's Metal framework.
- **Target:** macOS 26+, iOS 26+
- **Language:** Swift 6.2
- **Repo:** [https://github.com/arkavo-org/VRMMetalKit](https://github.com/arkavo-org/VRMMetalKit)

## Development Workflow
1. **Select Issue:** Pick a GitHub issue to work on.
2. **Branch:** Create a branch named `issue/{number}-{description}`.
3. **Implement:** Make changes.
4. **Verify:** Run `swift build` and `swift test`.
5. **Format:** Ensure code style matches existing patterns.
6. **Commit:** Git commit with clear message.
7. **Push & PR:** Push branch and create PR referencing the issue (e.g., "Fixes #123").

do not put temporary contextual/informational comments in code or CLAUDE.md

## Build & Test Commands

### Core Commands
```bash
# Build
swift build

# Test (All) - Optimal parallel settings (~5x faster)
swift test --parallel --num-workers 14 -j 16 --disable-sandbox

# Test (Specific)
swift test --filter VRMCreatorSimpleTests --disable-sandbox

# Release Build
swift build --configuration release
```

### Debug Flags (Conditional Compilation)
Use `-Xswiftc -D{FLAG_NAME}` to enable zero-cost debug logging:
- `VRM_METALKIT_ENABLE_LOGS`: General logging
- `VRM_METALKIT_ENABLE_DEBUG_ANIMATION`: Retargeting/Bone data
- `VRM_METALKIT_ENABLE_DEBUG_PHYSICS`: SpringBone simulation
- `VRM_METALKIT_ENABLE_DEBUG_LOADER`: VRMA parsing

### Shader Compilation
Metal shaders are **excluded** from SPM build. You must compile them manually if `.metal` files change:
```bash
make shaders      # Compiles to Resources/VRMMetalKitShaders.metallib
make clean        # Cleans temp files
```

```bash
# MSAA Alpha-to-Coverage tests
swift test --filter MSAAAlphaToCoverageTests --disable-sandbox
```

**Usage:**
```swift
var config = RendererConfig()
config.sampleCount = 4  // Enable 4x MSAA for MASK materials
let renderer = VRMRenderer(device: device, config: config)
```

**Requirements:**
- Metal device (tests skip on CI without GPU)
- `AvatarSample_A.vrm.glb` in `../Muse/Resources/VRM/` or set `MUSE_RESOURCES_PATH` env var

## Architecture & Design Patterns

### Core Systems
*   **Renderer (`VRMRenderer`):**
  *   **Triple-Buffered Uniforms:** Eliminates CPU-GPU stalls.
  *   **Dual Pipelines:** Separate states for Skinned vs. Non-Skinned geometry.
  *   **Pipeline Cache:** `VRMPipelineCache` avoids runtime shader compilation.
  *   **StrictMode:** `RendererConfig(strict: .fail)` validates buffer/texture indices and draw calls.
  *   **MSAA Alpha-to-Coverage:** `RendererConfig(sampleCount: 4)` enables 4x MSAA with alpha-to-coverage for MASK materials. Smoothly fades alpha cutout edges using subpixel coverage.
*   **Animation:**
  *   **VRMA Retargeting:** Automatically maps animation rest pose to model rest pose (T-pose).
  *   **Hybrid Compute:** Uses GPU compute shaders for morphs when >8 targets are active.
*   **Physics (`SpringBone*`):**
  *   XPBD simulation running at fixed 120Hz substeps in Compute Shaders.
*   **ARKit Integration:**
  *   **Face:** `ARKitFaceDriver` maps 52 ARKit shapes → 18 VRM expressions.
  *   **Body:** `ARKitBodyDriver` retargets ARKit skeletons to VRM nodes using Graham-Schmidt orthogonalization.
  *   **Smoothing:** Configurable filters (EMA, Kalman) in `SmoothingFilters.swift`.

### Directory Structure
*   **Core/**: Model representation (`VRMModel`), types, and strict mode validation.
*   **Loader/**: glTF parsing, binary buffer loading, texture handling.
*   **Renderer/**: Metal pipelines, geometry management, z-sorting.
*   **Shaders/**: `.metal` sources (MToon, SpringBone, Morph) and Swift interfaces.
*   **Animation/**: Playback, VRMA loading, Skinning, Retargeting logic.
*   **ARKit/**: Face/Body drivers, mappers, and smoothing logic.

## Key Implementation Details

### 1. VRM Animation Retargeting
Stick to the logic that treats Rest Pose and Animation Data as two separate, immutable sources of truth. Do not try to infer one from the other.
*   **Logic:** We compute `delta = inverse(animRest) * animRotation` and apply it as `modelRest * delta`.
*   **Location:** `VRMAnimationLoader.swift` (look for `makeRotationSampler`).

### 2. StrictMode Validation
Used to catch rendering bugs early. Configured via `RendererConfig`.
*   `.off`: Production default.
*   `.warn`: Logs violations.
*   `.fail`: Throws errors on invalid buffer bindings or empty draw calls.

### 3. Error Handling
Errors must implement `LocalizedError`. Messages should be LLM-friendly:
1.  **What** went wrong.
2.  **Where** (file/index).
3.  **Suggestion** for fixing.
4.  **Link** to VRM spec.

## Licensing
*   **Source Code:** Apache License 2.0.
*   **Assets/Models:** VRM Platform License 1.0 (check model metadata).
*   *Note:* New files must include the Apache 2.0 header.
