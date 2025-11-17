# Development Guide

This guide covers development workflows, build commands, testing patterns, and contribution guidelines for VRMMetalKit.

## Build & Test Commands

### Basic Operations

```bash
# Build the package
swift build

# Run all tests
swift test

# Run a specific test suite
swift test --filter VRMCreatorSimpleTests

# Build in release mode
swift build --configuration release
```

### Debug Builds with Conditional Logging

```bash
# Enable general debug logging
swift build -Xswiftc -DVRM_METALKIT_ENABLE_LOGS

# Enable animation debugging
swift build -Xswiftc -DVRM_METALKIT_ENABLE_DEBUG_ANIMATION

# Enable physics debugging
swift build -Xswiftc -DVRM_METALKIT_ENABLE_DEBUG_PHYSICS

# Enable loader debugging
swift build -Xswiftc -DVRM_METALKIT_ENABLE_DEBUG_LOADER

# Combine multiple flags
swift build -Xswiftc -DVRM_METALKIT_ENABLE_LOGS -Xswiftc -DVRM_METALKIT_ENABLE_DEBUG_ANIMATION
```

**Important**: Always omit these flags for release builds to ensure zero overhead.

### Check for Warnings

```bash
swift build --build-tests 2>&1 | tee build.log && ! grep -i "warning:" build.log
```

This command is **required** before creating any PR.

---

## Metal Shader Development

### Shader Compilation

Metal shaders are excluded from SPM compilation (see `Package.swift` exclude list) and must be pre-compiled to `.metallib`:

```bash
# Compile all shaders at once (recommended)
make shaders

# Clean temporary build files
make clean

# List functions in compiled metallib
make list-functions
```

The Makefile compiles all `.metal` files in `Sources/VRMMetalKit/Shaders/` into `VRMMetalKitShaders.metallib` in `Sources/VRMMetalKit/Resources/`.

**Current shaders:**
- **Rendering:** MToonShader.metal, SkinnedShader.metal, Toon2DShader.metal, Toon2DSkinnedShader.metal, SpriteShader.metal
- **Compute:** MorphTargetCompute.metal, MorphAccumulate.metal
- **Physics:** SpringBonePredict.metal, SpringBoneDistance.metal, SpringBoneCollision.metal, SpringBoneKinematic.metal
- **Debug:** DebugShaders.metal

### Pipeline Caching

VRMRenderer uses `VRMPipelineCache` to eliminate runtime shader compilation (50-100x faster):

```swift
// Load precompiled shader library (cached globally)
let library = try VRMPipelineCache.shared.getLibrary(device: device)

// Create cached pipeline state
let pipelineState = try VRMPipelineCache.shared.getPipelineState(
    device: device,
    descriptor: pipelineDescriptor,
    key: "mtoon_opaque"  // Unique cache key
)
```

**Performance:**
- First renderer: ~1-2ms (load metallib once)
- Subsequent renderers: ~0.1ms (cache hit)
- No runtime shader compilation in production

See [SHADERS.md](SHADERS.md) for detailed shader documentation.

---

## Testing Patterns

### Test Data Location

Test models and assets live in `Tests/VRMMetalKitTests/TestData/`

### Test Categories

- `VRMMetalKitTests.swift` - Basic smoke tests
- `ExpressionTests.swift` - VRMExpressions and morph targets
- `VRMCreatorSimpleTests.swift` - VRMBuilder API tests
- `Toon2DMaterialLayoutTests.swift` - 2.5D rendering mode
- `VRMRendererTests.swift` - Renderer configuration and lighting
- `ARKit/*Tests.swift` - ARKit integration tests

### Writing Tests

```swift
import XCTest
@testable import VRMMetalKit

final class MyTests: XCTestCase {
    var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    func testFeature() throws {
        // Test implementation
        let renderer = VRMRenderer(device: device)
        // ... assertions
    }
}
```

### Test Requirements

- All new public APIs must have unit tests
- All tests must pass before creating PR
- Use descriptive test names: `testFeatureDoesExpectedBehavior`
- Include edge cases and error conditions

---

## Common Development Workflows

### Adding a New VRM Extension

1. **Define types** in `Core/VRMTypes.swift`
   ```swift
   public struct VRMMyExtension: Codable {
       public var myProperty: String
   }
   ```

2. **Add parsing logic** to `Loader/VRMExtensionParser.swift`
   ```swift
   if let myExt = json["VRMC_my_extension"] {
       model.myExtension = try decoder.decode(VRMMyExtension.self, from: myExt)
   }
   ```

3. **Store in VRMModel** (`Core/VRMModel.swift`)
   ```swift
   public var myExtension: VRMMyExtension?
   ```

4. **Add error messages** with VRM spec links
   ```swift
   case missingMyExtension(String)
   // Include: what, where, why, how to fix, spec URL
   ```

5. **Add tests** in `Tests/VRMMetalKitTests/`

### Adding a New Shader Feature

1. **Implement shader code** in `Shaders/`
   - `.swift` files for Swift interfaces
   - `.metal` files for GPU code

2. **If `.metal` file**: Add to exclude list in `Package.swift`
   ```swift
   exclude: [
       "Shaders/MyNewShader.metal"
   ]
   ```

3. **Compile to `.metallib`**
   ```bash
   make shaders
   ```

4. **Update pipeline creation** in `VRMRenderer+Pipeline.swift`
   ```swift
   let function = library.makeFunction(name: "my_shader_vertex")
   ```

5. **Add StrictMode validation** if needed
   ```swift
   // Validate new buffer/texture indices don't conflict
   ```

6. **Add tests** to verify shader compilation and rendering

### Adding a New Animation Feature

1. **Define data structures** in `Animation/` module
   ```swift
   public struct MyAnimationData {
       // Animation-specific data
   }
   ```

2. **Add VRMA parsing** to `VRMAnimationLoader.swift`
   ```swift
   if let animData = json["my_animation"] {
       // Parse and store
   }
   ```

3. **Integrate with AnimationPlayer** (`AnimationPlayer.swift`)
   ```swift
   public func applyMyAnimation(_ data: MyAnimationData) {
       // Apply to VRMModel
   }
   ```

4. **Test with debug flag**
   ```bash
   swift build -Xswiftc -DVRM_METALKIT_ENABLE_DEBUG_ANIMATION
   swift test --filter MyAnimationTests
   ```

### Modifying Uniforms Struct

**Critical**: Uniforms struct must match exactly between Swift and Metal (byte-for-byte).

1. **Update Swift struct** (`VRMRenderer.swift`)
   ```swift
   struct Uniforms {
       // Add new field with proper alignment (16-byte blocks)
       var myNewField_packed = SIMD4<Float>(0, 0, 0, 0)
   }
   ```

2. **Update size constant** (`StrictMode.swift`)
   ```swift
   public static let uniformsSize = 416  // Update to new size
   ```

3. **Update ALL Metal shaders**
   - `MToonShader.metal`
   - `SkinnedShader.metal`
   - `Toon2DShader.metal`
   - `Toon2DSkinnedShader.metal`

   ```metal
   struct Uniforms {
       // ... existing fields
       float4 myNewField;  // Must match Swift layout
   };
   ```

4. **Recompile shaders**
   ```bash
   make shaders
   ```

5. **Add validation test**
   ```swift
   func testUniformsStructSize() {
       let actualSize = MemoryLayout<Uniforms>.size
       let expectedSize = MetalSizeConstants.uniformsSize
       XCTAssertEqual(actualSize, expectedSize)
   }
   ```

---

## Character Builder System

VRMBuilder provides a fluent API for programmatic character creation:

```swift
let vrm = try VRMBuilder()
    .setSkeleton(.defaultHumanoid)
    .applyMorphs(["height": 1.15, "muscle_definition": 0.7])
    .setHairColor([0.35, 0.25, 0.15])
    .addExpressions([.happy, .sad, .blink])
    .build()

try vrm.serialize(to: URL(fileURLWithPath: "character.vrm"))
```

This is part of the "Game of Mods" character creator integration.

---

## Error Message Guidelines

All errors must implement `LocalizedError` with LLM-friendly messages.

**Required components:**
1. **What** went wrong
2. **Where** (file path, line number, or index)
3. **Why** it happened
4. **How to fix** (actionable suggestion)
5. **VRM spec link** (when applicable)

**Example format:**
```swift
public var errorDescription: String? {
    """
    ❌ Missing Required Humanoid Bone: '\(boneName)'

    The VRM model in file '\(filePath)' is missing the required humanoid bone '\(boneName)'.
    Available bones: \(availableBones.joined(separator: ", "))

    Suggestion: Ensure your 3D model has a bone for '\(boneName)' and that it's properly mapped
    in the VRM humanoid configuration.

    VRM Spec: https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm-1.0/humanoid.md
    """
}
```

---

## CI/CD Pipeline

GitHub Actions workflows in `.github/workflows/`:

### build.yaml
Linux builds (Swift 6.2 container)
```bash
swift build -v
swift test -v
# Check for warnings
```

### pr-checks.yaml
PR validation
- Merge conflict detection
- File permissions check
- Apache License header verification
- Build and test

### release.yaml
Release automation
- Version tagging
- Changelog generation
- GitHub release creation

---

## Git Workflow

1. **Select a GitHub issue** or create a new one

2. **Create a feature branch**
   ```bash
   git checkout -b feature/description-issue-N
   ```

3. **Make changes** following code standards

4. **Test thoroughly**
   ```bash
   swift build
   swift test
   # Check for warnings
   swift build --build-tests 2>&1 | tee build.log; grep -i "warning:" build.log || echo "No warnings found"
   ```

5. **Commit with detailed message**
   ```bash
   git add -A
   git commit -m "Add feature X (issue #N)

   - Detailed change 1
   - Detailed change 2

   🤖 Generated with [Claude Code](https://claude.com/claude-code)

   Co-Authored-By: Claude <noreply@anthropic.com>"
   ```

6. **Push to remote**
   ```bash
   git push -u origin feature/description-issue-N
   ```

7. **Create PR**
   ```bash
   gh pr create --title "Add feature X" --body "..."
   ```

   **PR must reference the GitHub issue** (e.g., "Resolves #43")

---

## Code Style & Standards

### Swift

- Use Swift 6.2 features
- Follow Swift API Design Guidelines
- Use meaningful variable names
- Add doc comments for public APIs
- Use `@MainActor` for UI-related code
- Mark types as `Sendable` when thread-safe

### Metal Shaders

- Use descriptive function names
- Add comments for complex algorithms
- Align struct members to 16-byte boundaries
- Validate against Swift struct sizes

### Licensing

All new `.swift` and `.metal` files must include Apache 2.0 header:

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
```

Verified automatically in PR checks.

---

## Performance Optimization

### Enable Performance Tracking

```swift
renderer.performanceTracker = PerformanceTracker()
```

### Check Metrics

```swift
let metrics = renderer.getPerformanceMetrics()
print("Frame time: \(metrics.averageFrameTime)ms")
print("P99 frame time: \(metrics.p99FrameTime)ms")
print("Draw calls: \(metrics.drawCalls)")
print("Triangles: \(metrics.triangles)")
```

### Profiling

Use **Instruments** (Metal System Trace) to profile GPU bottlenecks:
1. Product → Profile (⌘I)
2. Select "Metal System Trace"
3. Record while rendering
4. Analyze GPU timeline for stalls, overdraw, shader cost

### Optimization Checklist

- [ ] Reduce draw calls (batch similar materials)
- [ ] Minimize state changes (sort by pipeline state)
- [ ] Use texture atlases for 2D mode
- [ ] Consider morph compute threshold (8+ targets → GPU)
- [ ] Profile SpringBone compute overhead
- [ ] Check triple-buffering is working (no CPU-GPU stalls)

See [PERFORMANCE_REPORT.md](PERFORMANCE_REPORT.md) for detailed performance analysis.

---

## Getting Help

- **Documentation**: Check `docs/` directory
- **Issue Tracker**: https://github.com/arkavo-org/VRMMetalKit/issues
- **VRM Specification**: https://github.com/vrm-c/vrm-specification
- **Metal Programming Guide**: https://developer.apple.com/metal/
