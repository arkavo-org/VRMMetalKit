# Loading VRM Models

Pick the right loader entry point, drive a progress bar, cancel mid-load, and handle errors.

## Overview

VRMMetalKit exposes two loader surfaces. ``VRMMetalKit/VRMMetalKit/loadModel(from:device:)-(URL,_)`` and its `Data` overload are the convenience facade — one line, default options, no progress hook. ``VRMModel/load(from:device:options:)`` is the underlying entry point; reach for it when you need a progress callback, cancellation, or one of the ``VRMLoadingOptimization`` presets (for example, ``VRMLoadingOptimization/maximumPerformance`` for batch avatar previews).

Version detection is transparent. The loader parses the `VRMC_vrm` extension on VRM 1.0 files and the legacy `VRM` extension on VRM 0.x files in the same code path, so the same call site works for both. Material parameter conversion for 0.x is also handled internally — see <doc:MigratingFromVRM0> for the gotchas (MASK demotion, shade-texture aliasing, linearstep vs. smoothstep).

## Two ways to load

Use the facade for the happy path:

```swift
let model = try await VRMMetalKit.loadModel(from: url, device: device)
```

Use ``VRMModel/load(from:device:options:)`` directly whenever you need to pass a ``VRMLoadingOptions`` value. The facade does not forward options — it is the *only* reason to choose one entry point over the other. Note that the `Data` overload (``VRMModel/load(from:filePath:device:)``) does not take options today; load from a `URL` if you need progress or cancellation.

## Loading with progress and cancellation

Large avatars with many 4K textures can take several hundred milliseconds to decode. For UI scenarios, wire the load into a `Task` and pass a ``VRMLoadingOptions`` value with a progress callback. The callback fires on the `MainActor` no more often than ``VRMLoadingOptions/progressUpdateInterval``, so it is safe to update SwiftUI state from inside it.

```swift
import VRMMetalKit
import Metal

let device = MTLCreateSystemDefaultDevice()!

let options = VRMLoadingOptions(
    progressCallback: { progress in
        // Runs on MainActor. `percentage` is 0...100.
        print("Loading: \(progress.percentage)% — \(progress.currentPhase.rawValue)")
    },
    progressUpdateInterval: 0.1,
    enableCancellation: true,
    optimizations: .default
)

let loadTask = Task {
    try await VRMModel.load(from: modelURL, device: device, options: options)
}

// To cancel from elsewhere (e.g. a Cancel button):
//     loadTask.cancel()
// The loader throws `VRMError.loadingCancelled` at the next phase boundary.

let model = try await loadTask.value
```

The ``VRMLoadingProgress`` value passed in carries both per-phase fields (``VRMLoadingProgress/currentPhase``, ``VRMLoadingProgress/phaseProgress``) and an aggregated ``VRMLoadingProgress/overallProgress`` weighted by ``VRMLoadingPhase/weight``. Textures dominate the budget at 34% of the total.

## Version detection

Detection is automatic. Loading a VRM 0.x `.vrm` file works without any flag — the internal `VRMExtensionParser` inspects `extensions.VRMC_vrm` then falls back to `extensions.VRM`, and the rest of the pipeline branches on the result. You do not call the parser yourself. For the material-side caveats when targeting 0.x assets, see <doc:MigratingFromVRM0>.

## Error handling

All loader failures throw ``VRMError``, which conforms to `LocalizedError` so `errorDescription` is suitable for direct display. Most cases are recoverable at the UI level (invalid file, missing required extension, unsupported VRM version — show the user a message and move on). `VRMError.loadingCancelled` is the expected cooperative cancellation throw and should be treated as a non-error in your UI. Out-of-memory and I/O failures bubble up as the underlying `Foundation` errors and warrant aborting the load entirely.

## Topics

### Loading entry points

- ``VRMMetalKit/VRMMetalKit``
- ``VRMModel``
- ``VRMModel/load(from:device:options:)``

### Configuration

- ``VRMLoadingOptions``
- ``VRMLoadingProgress``
- ``VRMLoadingPhase``
- ``VRMLoadingOptimization``

### Errors

- ``VRMError``
