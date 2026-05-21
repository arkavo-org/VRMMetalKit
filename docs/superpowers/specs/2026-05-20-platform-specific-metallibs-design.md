# Platform-Specific Precompiled Shaders (macOS FP32 / iOS FP16)

**Status:** Approved — ready for implementation plan
**Issue:** [#280](https://github.com/arkavo-org/VRMMetalKit/issues/280) (BLOCKING)
**Related:** PR #279 (MToon FP16 demotion, opt-in)
**Date:** 2026-05-20

## Problem

`VRMMetalKit` ships a single `VRMMetalKitShaders.metallib` compiled for macOS with
`MTOON_USE_HALF_PRECISION=0` (FP32, per PR #279's safe-by-default decision). SPM
clients who consume the package on iOS therefore get FP32 shaders and miss the
~-43.8% GPU render time and +174 FPS mobile throughput win that PR #279
benchmarked. Worse, the macOS-compiled `.metallib` is rejected by the iOS
Simulator's Metal driver, producing nil-pipeline errors at runtime.

## Goal

Distribute platform-appropriate precompiled `.metallib` slices in the SPM
package so:

- macOS clients get FP32 (no regression vs PR #279 baseline).
- iOS device clients get FP16 (mobile perf payoff).
- iOS Simulator clients get a simulator-native `.metallib` (no nil pipelines).
- No client has to compile shaders themselves.

## Non-Goals

- visionOS / tvOS / macCatalyst native slices (they route to the macOS slice
  for now; can be added later by changing one function).
- GLTFMetalKit PBR shader slicing.
- Runtime fallback from one slice to another (missing slice = hard error).
- Changing PR #279's macOS FP32 default.

## Design

### 1. Resources

Three precompiled metallibs in `Sources/VRMMetalKit/Resources/`:

| File                                       | SDK              | Define                          |
|--------------------------------------------|------------------|---------------------------------|
| `VRMMetalKitShaders.metallib`              | `macosx`         | (none — FP32)                   |
| `VRMMetalKitShaders_iOS.metallib`          | `iphoneos`       | `MTOON_USE_HALF_PRECISION=1`    |
| `VRMMetalKitShaders_iOSSimulator.metallib` | `iphonesimulator`| `MTOON_USE_HALF_PRECISION=1`    |

The macOS filename is unchanged to preserve compatibility with any external
tooling that hard-references the path.

All three are listed in `Package.swift` under the `VRMMetalKit` target's
`resources:` block as separate `.copy(...)` entries. SPM does not apply
`condition: .when(platforms:...)` to `.copy` resources, so all three ship on
every platform; runtime selects one and ignores the others. Mobile bundle
overhead is two extra small metallibs — acceptable.

### 2. Loader

New file `Sources/VRMMetalKit/Renderer/VRMShaderLibraryLoader.swift`:

```swift
public enum VRMShaderLibraryLoaderError: LocalizedError {
    case shaderLibraryMissing(expected: String)
    case shaderLibraryLoadFailed(name: String, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .shaderLibraryMissing(let name):
            return "\(name).metallib not found in package resources. " +
                   "Run `make shaders` to rebuild all platform slices."
        case .shaderLibraryLoadFailed(let name, let err):
            return "Failed to load \(name).metallib: \(err.localizedDescription)"
        }
    }
}

enum VRMShaderLibraryLoader {
    /// Compile-time-selected slice name for the current build target.
    static var bundledLibraryName: String {
        #if os(iOS) && targetEnvironment(simulator)
        return "VRMMetalKitShaders_iOSSimulator"
        #elseif os(iOS)
        return "VRMMetalKitShaders_iOS"
        #else
        return "VRMMetalKitShaders"
        #endif
    }

    static func loadBundledLibrary(device: MTLDevice) throws -> MTLLibrary {
        let name = bundledLibraryName
        guard let url = Bundle.module.url(forResource: name,
                                          withExtension: "metallib") else {
            throw VRMShaderLibraryLoaderError.shaderLibraryMissing(expected: name)
        }
        do {
            return try device.makeLibrary(URL: url)
        } catch {
            throw VRMShaderLibraryLoaderError.shaderLibraryLoadFailed(
                name: name, underlying: error)
        }
    }
}
```

Properties:
- Pure value-type API; no Metal state held by the loader.
- Compile-time `#if` routing (no runtime branching cost).
- visionOS / tvOS / macCatalyst fall through the `#else` to the macOS slice;
  adding a real slice later means changing this one function.
- Hard-fails with a typed, LLM-friendly error matching the project's
  error-handling convention (what / where / how to fix).

### 3. Callsite Refactor

Three callsites currently open-code `Bundle.module.url(forResource: "VRMMetalKitShaders", ...)`:

- `Sources/VRMMetalKit/Renderer/VRMPipelineCache.swift:88`
- `Sources/VRMMetalKit/SpringBoneComputeSystem.swift:206`
- `Sources/VRMMetalKit/Animation/VRMMorphTargets.swift:154`

Each replaces its inline block with `try VRMShaderLibraryLoader.loadBundledLibrary(device:)`,
wrapping the result in its existing error type to preserve external API
source-compatibility (e.g. `PipelineCacheError.shaderLibraryNotFound` continues
to be what consumers of `VRMPipelineCache` see).

`SpringBoneComputeSystem.swift`'s existing two-attempt path (try bundle, then
fall back to runtime compile from `.metal` sources) is preserved — the loader
replaces only the bundle-lookup step.

### 4. Makefile

`make shaders` becomes an aggregate of three SDK-specific targets:

```makefile
.PHONY: shaders shaders-macos shaders-ios shaders-iossim

shaders: shaders-macos shaders-ios shaders-iossim
	@echo "✅ All shader slices built"

shaders-macos:
	@mkdir -p /tmp/vrm-shaders-macos
	@for file in Sources/VRMMetalKit/Shaders/*.metal; do \
		xcrun -sdk macosx metal -Wall -Wextra -Werror \
			-c $$file -o /tmp/vrm-shaders-macos/$$(basename $$file .metal).air; \
	done
	@xcrun -sdk macosx metallib /tmp/vrm-shaders-macos/*.air \
		-o Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib

shaders-ios:
	@mkdir -p /tmp/vrm-shaders-ios
	@for file in Sources/VRMMetalKit/Shaders/*.metal; do \
		xcrun -sdk iphoneos metal -Wall -Wextra -Werror \
			-mios-version-min=26.0 -DMTOON_USE_HALF_PRECISION=1 \
			-c $$file -o /tmp/vrm-shaders-ios/$$(basename $$file .metal).air; \
	done
	@xcrun -sdk iphoneos metallib /tmp/vrm-shaders-ios/*.air \
		-o Sources/VRMMetalKit/Resources/VRMMetalKitShaders_iOS.metallib

shaders-iossim:
	@mkdir -p /tmp/vrm-shaders-iossim
	@for file in Sources/VRMMetalKit/Shaders/*.metal; do \
		xcrun -sdk iphonesimulator metal -Wall -Wextra -Werror \
			-mios-simulator-version-min=26.0 -DMTOON_USE_HALF_PRECISION=1 \
			-c $$file -o /tmp/vrm-shaders-iossim/$$(basename $$file .metal).air; \
	done
	@xcrun -sdk iphonesimulator metallib /tmp/vrm-shaders-iossim/*.air \
		-o Sources/VRMMetalKit/Resources/VRMMetalKitShaders_iOSSimulator.metallib
```

`make clean` extended to remove all three temp dirs. The `gltf-shaders` target
is unchanged (no FP16 flag to switch on today).

Each SDK uses its own `/tmp/vrm-shaders-<sdk>/` temp dir so `.air` files from
different SDKs don't collide.

### 5. Package.swift

The `VRMMetalKit` target's `resources:` block:

```swift
resources: [
    .copy("Resources/VRMMetalKitShaders.metallib"),
    .copy("Resources/VRMMetalKitShaders_iOS.metallib"),
    .copy("Resources/VRMMetalKitShaders_iOSSimulator.metallib"),
],
```

If any slice is missing at SPM build time, SPM fails to find the resource —
loud, early error. Good.

### 6. Tests

New `Tests/VRMMetalKitTests/VRMShaderLibraryLoaderTests.swift`:

- `testBundledLibraryNameMatchesCurrentTarget` — pure-Swift assertion that
  `bundledLibraryName` returns the expected slice name for the host (no Metal
  device required).
- `testLoadBundledLibrarySucceeds` — needs `MTLCreateSystemDefaultDevice()`;
  skips on CI without a GPU (existing project pattern). Asserts the load
  returns a non-empty `MTLLibrary`. Catches missing/wrong-slice metallib on
  Mac CI; an iOS test run catches the iOS slice.
- `testErrorDescriptionShape` — asserts the typed error's `errorDescription`
  contains the slice name and a `make shaders` hint.

Existing `MToonShaderGPUTests` and `MSAAAlphaToCoverageTests` already exercise
shader output and will run against the iOS slice naturally on an iOS
simulator.

### 7. CI / Build Flow

- Local dev: `make shaders` builds all three; iterating on Mac you can still
  call `make shaders-macos` alone.
- `swift build` / `swift test` themselves don't compile shaders (unchanged).
- Recommendation: PR CI should run `make shaders` to verify all three xcrun
  invocations succeed even when no iOS simulator runs are scheduled. Out of
  scope for this PR but flagged for follow-up.

## Risks

- **Mac-only CI won't catch a broken iOS slice.** Mitigation: add `make shaders`
  to the PR CI matrix as a build-only check (follow-up issue).
- **Bundle size on mobile increases by ~2 small metallibs.** Acceptable given
  the FP16 perf payoff.
- **macCatalyst routes to macOS slice.** This is what happens today already
  (single-slice world); no regression. If Catalyst proves to want FP16, add a
  fourth slice and one `#elseif` branch in the loader.

## Acceptance Criteria

- `make shaders` produces three `.metallib` files in `Sources/VRMMetalKit/Resources/`.
- `swift build` succeeds on macOS with all three resources present.
- All existing tests pass on macOS.
- `VRMShaderLibraryLoaderTests` pass on macOS.
- iOS Simulator build of a consumer app loads the loader without nil-pipeline
  errors (manual verification at PR time).
- Issue #280 closed by the PR via `Closes #280`.
