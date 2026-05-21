# Platform-Specific Precompiled Shaders — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship three precompiled `.metallib` slices (macOS FP32 / iOS device FP16 / iOS Simulator FP16) and route load sites through one platform-aware loader, so SPM clients get the right shader for their target without recompiling.

**Architecture:** Three SDK-specific metallibs are produced by an extended `Makefile`, copied into the VRMMetalKit SPM bundle, and selected at runtime by a new `VRMShaderLibraryLoader` using compile-time `#if` branches. Three existing call sites (`VRMPipelineCache`, `SpringBoneComputeSystem`, `VRMMorphTargets`) replace their inline `Bundle.module.url(...)` lookups with the loader, wrapping the loader's typed error in their existing error types to preserve API source compatibility.

**Tech Stack:** Swift 6.2 (strict concurrency), Metal, Apple `xcrun metal` / `metallib` toolchain, SwiftPM resources, XCTest.

**Spec:** `docs/superpowers/specs/2026-05-20-platform-specific-metallibs-design.md`

**Issue:** [#280](https://github.com/arkavo-org/VRMMetalKit/issues/280) (BLOCKING)

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `Makefile` | Modify | Split `shaders` into three SDK-specific targets + aggregate; extend `clean` |
| `Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib` | Regenerate | macOS FP32 slice (filename unchanged) |
| `Sources/VRMMetalKit/Resources/VRMMetalKitShaders_iOS.metallib` | Create | iphoneos FP16 slice |
| `Sources/VRMMetalKit/Resources/VRMMetalKitShaders_iOSSimulator.metallib` | Create | iphonesimulator FP16 slice |
| `Sources/VRMMetalKit/Renderer/VRMShaderLibraryLoader.swift` | Create | Compile-time-routed bundle library loader + typed error |
| `Sources/VRMMetalKit/Renderer/VRMPipelineCache.swift` | Modify | Replace inline lookup; wrap with `PipelineCacheError` |
| `Sources/VRMMetalKit/SpringBoneComputeSystem.swift` | Modify | Replace inline lookup in "Attempt 2"; keep default-library fallback |
| `Sources/VRMMetalKit/Animation/VRMMorphTargets.swift` | Modify | Replace inline lookup; keep default-library fallback |
| `Package.swift` | Modify | Add two new `.copy(...)` entries for iOS slices |
| `Tests/VRMMetalKitTests/VRMShaderLibraryLoaderTests.swift` | Create | Unit tests for slice-name routing, successful load, error description |

---

## Task 1: Extend the Makefile to build three SDK slices

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Replace the existing `shaders` target with three SDK-specific targets plus an aggregate.**

In `Makefile`, replace the block that currently reads:

```makefile
# Compile all Metal shaders into a single metallib.
# -Wall -Wextra enables the common clang warning classes; -Werror promotes
# them to hard errors so the CI Shaders job (and local `make shaders`)
# catches issues like unused functions, writable-buffer aliasing, and
# sign-compare bugs before they become harder to fix later.
shaders:
	@echo "🔨 Compiling Metal shaders..."
	@mkdir -p /tmp/vrm-shaders
	@for file in Sources/VRMMetalKit/Shaders/*.metal; do \
		echo "  Compiling $$file..."; \
		xcrun metal -Wall -Wextra -Werror -c $$file -o /tmp/vrm-shaders/$$(basename $$file .metal).air; \
	done
	@xcrun metallib /tmp/vrm-shaders/*.air -o Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib
	@echo "✅ Shaders compiled successfully"
	@echo "📦 Output: Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib"
	@ls -lh Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib
```

with:

```makefile
# Compile all VRM Metal shaders into three SDK-specific metallibs:
#   - macosx          (FP32, baseline; preserves PR #279's safe-default)
#   - iphoneos        (FP16, mobile double-rate payoff)
#   - iphonesimulator (FP16, simulator-native; fixes nil-pipeline error)
# -Wall -Wextra enables the common clang warning classes; -Werror promotes
# them to hard errors so the CI Shaders job (and local `make shaders`)
# catches issues like unused functions, writable-buffer aliasing, and
# sign-compare bugs before they become harder to fix later.
shaders: shaders-macos shaders-ios shaders-iossim
	@echo "✅ All shader slices built"

shaders-macos:
	@echo "🔨 Compiling macOS shaders (FP32)..."
	@mkdir -p /tmp/vrm-shaders-macos
	@for file in Sources/VRMMetalKit/Shaders/*.metal; do \
		echo "  Compiling $$file..."; \
		xcrun -sdk macosx metal -Wall -Wextra -Werror \
			-c $$file -o /tmp/vrm-shaders-macos/$$(basename $$file .metal).air; \
	done
	@xcrun -sdk macosx metallib /tmp/vrm-shaders-macos/*.air \
		-o Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib
	@echo "📦 Output: Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib"
	@ls -lh Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib

shaders-ios:
	@echo "🔨 Compiling iOS device shaders (FP16)..."
	@mkdir -p /tmp/vrm-shaders-ios
	@for file in Sources/VRMMetalKit/Shaders/*.metal; do \
		echo "  Compiling $$file..."; \
		xcrun -sdk iphoneos metal -Wall -Wextra -Werror \
			-mios-version-min=26.0 -DMTOON_USE_HALF_PRECISION=1 \
			-c $$file -o /tmp/vrm-shaders-ios/$$(basename $$file .metal).air; \
	done
	@xcrun -sdk iphoneos metallib /tmp/vrm-shaders-ios/*.air \
		-o Sources/VRMMetalKit/Resources/VRMMetalKitShaders_iOS.metallib
	@echo "📦 Output: Sources/VRMMetalKit/Resources/VRMMetalKitShaders_iOS.metallib"
	@ls -lh Sources/VRMMetalKit/Resources/VRMMetalKitShaders_iOS.metallib

shaders-iossim:
	@echo "🔨 Compiling iOS Simulator shaders (FP16)..."
	@mkdir -p /tmp/vrm-shaders-iossim
	@for file in Sources/VRMMetalKit/Shaders/*.metal; do \
		echo "  Compiling $$file..."; \
		xcrun -sdk iphonesimulator metal -Wall -Wextra -Werror \
			-mios-simulator-version-min=26.0 -DMTOON_USE_HALF_PRECISION=1 \
			-c $$file -o /tmp/vrm-shaders-iossim/$$(basename $$file .metal).air; \
	done
	@xcrun -sdk iphonesimulator metallib /tmp/vrm-shaders-iossim/*.air \
		-o Sources/VRMMetalKit/Resources/VRMMetalKitShaders_iOSSimulator.metallib
	@echo "📦 Output: Sources/VRMMetalKit/Resources/VRMMetalKitShaders_iOSSimulator.metallib"
	@ls -lh Sources/VRMMetalKit/Resources/VRMMetalKitShaders_iOSSimulator.metallib
```

Also update the `.PHONY` line near the top of the file to include the new targets. Find the existing line:

```makefile
.PHONY: help shaders gltf-shaders clean test docs docs-static
```

and replace with:

```makefile
.PHONY: help shaders shaders-macos shaders-ios shaders-iossim gltf-shaders clean test docs docs-static
```

Update the `help:` target's `shaders` line (currently `make shaders       - Compile VRMMetalKit Metal shaders into metallib`) to:

```makefile
	@echo "  make shaders       - Compile all three VRMMetalKit metallib slices (macOS / iOS / iOS Simulator)"
	@echo "  make shaders-macos - Compile only the macOS slice (FP32)"
	@echo "  make shaders-ios   - Compile only the iOS device slice (FP16)"
	@echo "  make shaders-iossim- Compile only the iOS Simulator slice (FP16)"
```

- [ ] **Step 2: Extend `make clean` to remove all three temp dirs.**

Find:

```makefile
clean:
	@echo "🗑️  Cleaning temporary files..."
	@rm -rf /tmp/vrm-shaders /tmp/gltf-shaders
	@echo "✅ Clean complete"
```

Replace with:

```makefile
clean:
	@echo "🗑️  Cleaning temporary files..."
	@rm -rf /tmp/vrm-shaders /tmp/vrm-shaders-macos /tmp/vrm-shaders-ios /tmp/vrm-shaders-iossim /tmp/gltf-shaders
	@echo "✅ Clean complete"
```

- [ ] **Step 3: Build all three slices and verify the resources exist.**

Run:

```bash
make shaders
```

Expected output (truncated):
```
🔨 Compiling macOS shaders (FP32)...
...
📦 Output: Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib
🔨 Compiling iOS device shaders (FP16)...
...
📦 Output: Sources/VRMMetalKit/Resources/VRMMetalKitShaders_iOS.metallib
🔨 Compiling iOS Simulator shaders (FP16)...
...
📦 Output: Sources/VRMMetalKit/Resources/VRMMetalKitShaders_iOSSimulator.metallib
✅ All shader slices built
```

Then verify:

```bash
ls -1 Sources/VRMMetalKit/Resources/*.metallib
```

Expected:
```
Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib
Sources/VRMMetalKit/Resources/VRMMetalKitShaders_iOS.metallib
Sources/VRMMetalKit/Resources/VRMMetalKitShaders_iOSSimulator.metallib
```

- [ ] **Step 4: Commit.**

```bash
git add Makefile Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib Sources/VRMMetalKit/Resources/VRMMetalKitShaders_iOS.metallib Sources/VRMMetalKit/Resources/VRMMetalKitShaders_iOSSimulator.metallib
git commit -m "build(shaders): split shader build into three SDK slices (macOS / iOS / iOS sim)

Issue #280
"
```

---

## Task 2: Register the new metallibs as SPM resources

**Files:**
- Modify: `Package.swift:84-86` (the `resources:` block in the `VRMMetalKit` target)

- [ ] **Step 1: Add the two new `.copy(...)` entries.**

Find:

```swift
            resources: [
                .copy("Resources/VRMMetalKitShaders.metallib")
            ],
```

Replace with:

```swift
            resources: [
                .copy("Resources/VRMMetalKitShaders.metallib"),
                .copy("Resources/VRMMetalKitShaders_iOS.metallib"),
                .copy("Resources/VRMMetalKitShaders_iOSSimulator.metallib")
            ],
```

- [ ] **Step 2: Verify SwiftPM sees all three resources.**

Run:

```bash
swift build 2>&1 | tail -20
```

Expected: build succeeds. SwiftPM resolves the three `.copy` entries — any missing file would produce a `error: invalid resource 'Resources/...': file not found` error.

- [ ] **Step 3: Commit.**

```bash
git add Package.swift
git commit -m "build(spm): register iOS device + simulator metallib resources

Issue #280
"
```

---

## Task 3: Scaffold the `VRMShaderLibraryLoader` API (signature only)

This is the TDD "make it compilable but unimplemented" step. Swift's `swift test --filter` compiles all test files, so the loader must exist as a type before tests referencing it can compile.

**Files:**
- Create: `Sources/VRMMetalKit/Renderer/VRMShaderLibraryLoader.swift`

- [ ] **Step 1: Create the file with type declarations and stub implementations.**

Create `Sources/VRMMetalKit/Renderer/VRMShaderLibraryLoader.swift` with:

```swift
//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation
import Metal

/// Failure modes raised by ``VRMShaderLibraryLoader`` while resolving the
/// platform-appropriate `.metallib` slice bundled with the SPM package.
public enum VRMShaderLibraryLoaderError: Error, LocalizedError {
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

/// Resolves and loads the platform-appropriate precompiled shader library
/// shipped inside the VRMMetalKit SPM bundle.
///
/// Three slices ship in `Sources/VRMMetalKit/Resources/`:
/// - `VRMMetalKitShaders.metallib` — macOS, FP32 (PR #279 safe default).
/// - `VRMMetalKitShaders_iOS.metallib` — iphoneos, FP16 (mobile double-rate).
/// - `VRMMetalKitShaders_iOSSimulator.metallib` — iphonesimulator, FP16.
///
/// visionOS / tvOS / macCatalyst currently fall through to the macOS slice;
/// when a real slice is added later, only ``bundledLibraryName`` changes.
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

    /// Loads the platform-appropriate metallib from `Bundle.module`.
    /// - Throws: ``VRMShaderLibraryLoaderError`` on missing or unreadable slice.
    static func loadBundledLibrary(device: MTLDevice) throws -> MTLLibrary {
        // Stub — implemented in a later task.
        throw VRMShaderLibraryLoaderError.shaderLibraryMissing(expected: bundledLibraryName)
    }
}
```

- [ ] **Step 2: Verify the package still builds.**

Run:

```bash
swift build 2>&1 | tail -10
```

Expected: build succeeds (the stub `throw` is reachable code but never warns).

- [ ] **Step 3: Commit the scaffold.**

```bash
git add Sources/VRMMetalKit/Renderer/VRMShaderLibraryLoader.swift
git commit -m "feat(renderer): scaffold VRMShaderLibraryLoader (API only)

Issue #280
"
```

---

## Task 4: Write the failing tests for `VRMShaderLibraryLoader`

**Files:**
- Create: `Tests/VRMMetalKitTests/VRMShaderLibraryLoaderTests.swift`

- [ ] **Step 1: Create the test file.**

Create `Tests/VRMMetalKitTests/VRMShaderLibraryLoaderTests.swift` with:

```swift
//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import XCTest
import Metal
@testable import VRMMetalKit

final class VRMShaderLibraryLoaderTests: XCTestCase {

    func testBundledLibraryNameMatchesCurrentTarget() {
        let name = VRMShaderLibraryLoader.bundledLibraryName

        #if os(iOS) && targetEnvironment(simulator)
        XCTAssertEqual(name, "VRMMetalKitShaders_iOSSimulator")
        #elseif os(iOS)
        XCTAssertEqual(name, "VRMMetalKitShaders_iOS")
        #else
        XCTAssertEqual(name, "VRMMetalKitShaders")
        #endif
    }

    func testLoadBundledLibrarySucceeds() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (likely headless CI)")
        }

        let library = try VRMShaderLibraryLoader.loadBundledLibrary(device: device)

        XCTAssertFalse(library.functionNames.isEmpty,
                       "Loaded library should expose at least one function")
    }

    func testErrorDescriptionIncludesSliceNameAndRebuildHint() {
        let missing = VRMShaderLibraryLoaderError.shaderLibraryMissing(
            expected: "VRMMetalKitShaders_iOS")
        let description = missing.errorDescription ?? ""

        XCTAssertTrue(description.contains("VRMMetalKitShaders_iOS"),
                      "Error description should name the missing slice")
        XCTAssertTrue(description.contains("make shaders"),
                      "Error description should hint at the rebuild command")
    }
}
```

- [ ] **Step 2: Run the new tests; expect the success path to fail.**

Run:

```bash
swift test --filter VRMShaderLibraryLoaderTests --disable-sandbox 2>&1 | tail -30
```

Expected:
- `testBundledLibraryNameMatchesCurrentTarget` — PASS (only reads the property).
- `testLoadBundledLibrarySucceeds` — FAIL with `VRMShaderLibraryLoaderError.shaderLibraryMissing` because the loader body is still the stub.
- `testErrorDescriptionIncludesSliceNameAndRebuildHint` — PASS (only inspects the enum case).

Confirm the FAIL reason in the output matches the stub error string ("VRMMetalKitShaders.metallib not found in package resources. Run `make shaders` to rebuild all platform slices.").

- [ ] **Step 3: Commit the failing test.**

```bash
git add Tests/VRMMetalKitTests/VRMShaderLibraryLoaderTests.swift
git commit -m "test(renderer): VRMShaderLibraryLoader red-phase tests

Issue #280
"
```

---

## Task 5: Implement `loadBundledLibrary` and make the tests pass

**Files:**
- Modify: `Sources/VRMMetalKit/Renderer/VRMShaderLibraryLoader.swift`

- [ ] **Step 1: Replace the stub body with the real implementation.**

In `Sources/VRMMetalKit/Renderer/VRMShaderLibraryLoader.swift`, find:

```swift
    static func loadBundledLibrary(device: MTLDevice) throws -> MTLLibrary {
        // Stub — implemented in a later task.
        throw VRMShaderLibraryLoaderError.shaderLibraryMissing(expected: bundledLibraryName)
    }
```

Replace with:

```swift
    static func loadBundledLibrary(device: MTLDevice) throws -> MTLLibrary {
        let name = bundledLibraryName
        guard let url = Bundle.module.url(forResource: name, withExtension: "metallib") else {
            throw VRMShaderLibraryLoaderError.shaderLibraryMissing(expected: name)
        }
        do {
            return try device.makeLibrary(URL: url)
        } catch {
            throw VRMShaderLibraryLoaderError.shaderLibraryLoadFailed(
                name: name, underlying: error)
        }
    }
```

- [ ] **Step 2: Run the loader tests; expect all three to pass.**

Run:

```bash
swift test --filter VRMShaderLibraryLoaderTests --disable-sandbox 2>&1 | tail -30
```

Expected: 3 tests, 3 passed (or 2 passed + 1 skipped if no Metal device).

- [ ] **Step 3: Commit.**

```bash
git add Sources/VRMMetalKit/Renderer/VRMShaderLibraryLoader.swift
git commit -m "feat(renderer): implement platform-routed shader library loader

Issue #280
"
```

---

## Task 6: Route `VRMPipelineCache` through the loader

**Files:**
- Modify: `Sources/VRMMetalKit/Renderer/VRMPipelineCache.swift:86-100`

- [ ] **Step 1: Replace the inline `Bundle.module` lookup with the loader call.**

In `Sources/VRMMetalKit/Renderer/VRMPipelineCache.swift`, find the block inside `getLibrary(device:)`:

```swift
            // Always load from packaged metallib for consistency
            // This ensures the same shaders are used regardless of app configuration
            guard let url = Bundle.module.url(forResource: "VRMMetalKitShaders",
                                             withExtension: "metallib") else {
                vrmLog("[VRMPipelineCache] ❌ VRMMetalKitShaders.metallib not found in package resources")
                throw PipelineCacheError.shaderLibraryNotFound
            }

            do {
                let library = try device.makeLibrary(URL: url)
                libraries[key] = library
                return library
            } catch {
                throw PipelineCacheError.shaderLibraryLoadFailed(error)
            }
```

Replace with:

```swift
            // Load the platform-appropriate metallib slice via the shared loader.
            do {
                let library = try VRMShaderLibraryLoader.loadBundledLibrary(device: device)
                libraries[key] = library
                return library
            } catch VRMShaderLibraryLoaderError.shaderLibraryMissing(let name) {
                vrmLog("[VRMPipelineCache] ❌ \(name).metallib not found in package resources")
                throw PipelineCacheError.shaderLibraryNotFound
            } catch VRMShaderLibraryLoaderError.shaderLibraryLoadFailed(_, let underlying) {
                throw PipelineCacheError.shaderLibraryLoadFailed(underlying)
            }
```

- [ ] **Step 2: Run all VRMPipelineCache-adjacent tests; expect them to pass.**

Run:

```bash
swift test --filter VRMPipelineCache --disable-sandbox 2>&1 | tail -30
swift test --filter MToonShaderGPUTests --disable-sandbox 2>&1 | tail -30
```

Expected: pass (or skip on headless CI). No new failures.

- [ ] **Step 3: Commit.**

```bash
git add Sources/VRMMetalKit/Renderer/VRMPipelineCache.swift
git commit -m "refactor(renderer): route VRMPipelineCache through VRMShaderLibraryLoader

Issue #280
"
```

---

## Task 7: Route `SpringBoneComputeSystem` through the loader

**Files:**
- Modify: `Sources/VRMMetalKit/SpringBoneComputeSystem.swift:204-218`

- [ ] **Step 1: Replace the "Attempt 2" inline lookup with a loader call.**

In `Sources/VRMMetalKit/SpringBoneComputeSystem.swift`, find:

```swift
        // Attempt 2: Load from VRMMetalKitShaders.metallib in package resources
        if library == nil {
            guard let url = Bundle.module.url(forResource: "VRMMetalKitShaders", withExtension: "metallib") else {
                vrmLog("[SpringBone] ❌ VRMMetalKitShaders.metallib not found in package resources")
                throw SpringBoneError.failedToLoadShaders
            }

            do {
                library = try device.makeLibrary(URL: url)
                vrmLog("[SpringBone] ✅ Loaded from VRMMetalKitShaders.metallib (Bundle.module)")
            } catch {
                vrmLog("[SpringBone] ❌ Failed to load metallib: \(error)")
                throw SpringBoneError.failedToLoadShaders
            }
        }
```

Replace with:

```swift
        // Attempt 2: Load the platform-appropriate metallib slice via the shared loader.
        if library == nil {
            do {
                library = try VRMShaderLibraryLoader.loadBundledLibrary(device: device)
                vrmLog("[SpringBone] ✅ Loaded from \(VRMShaderLibraryLoader.bundledLibraryName).metallib (Bundle.module)")
            } catch {
                vrmLog("[SpringBone] ❌ \(error.localizedDescription)")
                throw SpringBoneError.failedToLoadShaders
            }
        }
```

The default-library fallback (`Attempt 1`) and the subsequent `guard let library = library` block stay unchanged.

- [ ] **Step 2: Run SpringBone tests; expect them to pass.**

Run:

```bash
swift test --filter SpringBone --disable-sandbox 2>&1 | tail -30
```

Expected: pass (or skip on headless CI). No new failures.

- [ ] **Step 3: Commit.**

```bash
git add Sources/VRMMetalKit/SpringBoneComputeSystem.swift
git commit -m "refactor(physics): route SpringBoneComputeSystem through VRMShaderLibraryLoader

Issue #280
"
```

---

## Task 8: Route `VRMMorphTargets` through the loader

**Files:**
- Modify: `Sources/VRMMetalKit/Animation/VRMMorphTargets.swift:148-169`

- [ ] **Step 1: Replace the inline lookup, keep the default-library fallback.**

In `Sources/VRMMetalKit/Animation/VRMMorphTargets.swift`, find:

```swift
    private func setupComputePipeline() throws {
        // Try to load compute pipeline from compiled Metal library
        // First try package resources (Bundle.module), then fall back to default library
        var library: MTLLibrary?

        // Try package bundle first (for SPM packages)
        if let url = Bundle.module.url(forResource: "VRMMetalKitShaders", withExtension: "metallib"),
           let packageLib = try? device.makeLibrary(URL: url) {
            library = packageLib
            vrmLog("[VRMMorphTargetSystem] Using package Metal library (Bundle.module)")
        } else if let defaultLib = device.makeDefaultLibrary() {
            library = defaultLib
            vrmLog("[VRMMorphTargetSystem] Using default Metal library")
        }

        // Fail fast if no library available
        guard let validLibrary = library else {
            throw VRMMorphTargetError.failedToCreateComputePipeline(
                "No Metal shader library available. " +
                "Ensure VRMMetalKitShaders.metallib is included in the app bundle."
            )
        }
```

Replace with:

```swift
    private func setupComputePipeline() throws {
        // Try to load compute pipeline from compiled Metal library.
        // First try the platform-appropriate metallib slice via the shared
        // loader, then fall back to the device's default library.
        var library: MTLLibrary?

        if let packageLib = try? VRMShaderLibraryLoader.loadBundledLibrary(device: device) {
            library = packageLib
            vrmLog("[VRMMorphTargetSystem] Using package Metal library (\(VRMShaderLibraryLoader.bundledLibraryName))")
        } else if let defaultLib = device.makeDefaultLibrary() {
            library = defaultLib
            vrmLog("[VRMMorphTargetSystem] Using default Metal library")
        }

        // Fail fast if no library available
        guard let validLibrary = library else {
            throw VRMMorphTargetError.failedToCreateComputePipeline(
                "No Metal shader library available. " +
                "Ensure VRMMetalKitShaders metallib slices are bundled (run `make shaders`)."
            )
        }
```

The rest of the function (`makeFunction(name: "morph_accumulate_positions")` and pipeline creation) stays unchanged.

- [ ] **Step 2: Run morph target tests; expect them to pass.**

Run:

```bash
swift test --filter Morph --disable-sandbox 2>&1 | tail -30
```

Expected: pass (or skip on headless CI). No new failures.

- [ ] **Step 3: Commit.**

```bash
git add Sources/VRMMetalKit/Animation/VRMMorphTargets.swift
git commit -m "refactor(animation): route VRMMorphTargetSystem through VRMShaderLibraryLoader

Issue #280
"
```

---

## Task 9: Full test suite + visual sanity render

**Files:**
- (No source changes; verification only)
- Output: `AvatarSample_A.png` regenerated for visual diff (per project convention)

- [ ] **Step 1: Run the full test suite in parallel.**

Run:

```bash
swift test --parallel --num-workers 14 -j 16 --disable-sandbox 2>&1 | tail -40
```

Expected: all tests pass (or skip on headless CI). No new failures introduced by this change. If any test fails, stop and diagnose — do not proceed.

- [ ] **Step 2: Regenerate the AvatarSample_A.png sanity render.**

Run:

```bash
swift run VRMRender --output AvatarSample_A.png 2>&1 | tail -10
```

(If the renderer needs a model path argument, follow the project's existing invocation pattern — check the most recent PR that touched `AvatarSample_A.png` for the exact command.)

Expected: render completes, produces a PNG, no rendering warnings about missing pipelines. Visually compare against the previous `AvatarSample_A.png` — should be identical (no shading regression).

- [ ] **Step 3: Stage the regenerated PNG only if it visibly matches the prior render.**

If the PNG matches:

```bash
git add AvatarSample_A.png
git commit -m "chore(samples): regenerate AvatarSample_A.png sanity render (#280)"
```

If the PNG differs visibly, stop and diagnose — the loader change should not alter rendered output on macOS (same slice, same shaders).

---

## Task 10: Open the PR

**Files:** (none)

- [ ] **Step 1: Push the branch.**

Confirm with the user before pushing (per the project's push-sparingly convention). When approved:

```bash
git push -u origin $(git branch --show-current)
```

- [ ] **Step 2: Create the PR.**

```bash
gh pr create --title "feat(shaders): distribute platform-specific precompiled metallibs (#280)" --body "$(cat <<'EOF'
## Summary
- Splits the shader build into three SDK slices: `VRMMetalKitShaders.metallib` (macOS FP32), `VRMMetalKitShaders_iOS.metallib` (iphoneos FP16), `VRMMetalKitShaders_iOSSimulator.metallib` (iphonesimulator FP16).
- New `VRMShaderLibraryLoader` selects the right slice at compile time via `#if` and loads it from `Bundle.module`; `VRMPipelineCache`, `SpringBoneComputeSystem`, and `VRMMorphTargets` all route through it.
- Unblocks PR #279's mobile FP16 perf win for SPM clients without local recompilation and fixes the iOS Simulator nil-pipeline error.

Closes #280

## Test plan
- [ ] `make shaders` produces all three metallibs locally
- [ ] `swift test --parallel --num-workers 14 -j 16 --disable-sandbox` passes
- [ ] New `VRMShaderLibraryLoaderTests` (3 tests) pass on macOS
- [ ] AvatarSample_A.png sanity render unchanged
- [ ] Manual verification on iOS Simulator: app links and renders without nil-pipeline errors

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL returned by `gh`. Hand the URL back to the user.

---

## Self-Review

**Spec coverage:**
- Resources (3 slices, names, FP flags) → Task 1 (Makefile) + Task 2 (Package.swift).
- Loader (signature, compile-time routing, typed error) → Tasks 3 & 5.
- Callsite refactor (3 sites, preserve external errors) → Tasks 6, 7, 8.
- Tests (3 cases) → Tasks 4 & 5.
- Makefile (aggregate + per-SDK) → Task 1.
- CI flow note → captured in Task 9 (full test run); CI matrix change deferred per spec ("out of scope for this PR but flagged for follow-up").
- Acceptance criteria → all map to Tasks 1, 2, 5, 9, 10.

**Placeholder scan:** No TBDs, no "appropriate error handling", every code-changing step has the actual code shown. The "follow your existing invocation pattern" hint in Task 9 Step 2 is genuinely ambiguous in the project (multiple invocation paths exist) — kept as a brief escape hatch since the regeneration command isn't part of the work being shipped.

**Type consistency:**
- `VRMShaderLibraryLoader` used identically in Tasks 3, 5, 6, 7, 8.
- `VRMShaderLibraryLoaderError.shaderLibraryMissing(expected:)` and `.shaderLibraryLoadFailed(name:underlying:)` named consistently across loader, tests, and `VRMPipelineCache` catch arms.
- `bundledLibraryName` referenced by name in Tasks 3, 4 (test), 7, 8 — all consistent.
- `PipelineCacheError.shaderLibraryNotFound` and `.shaderLibraryLoadFailed(_:)` reused verbatim from the existing enum (not redefined).
