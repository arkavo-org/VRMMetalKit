# Issue #35: Renderer Shader Compilation - Implementation Guide

## 1. Branch Creation Instructions ✅

**Branch created:** `fix/issue-35-shader-compilation`

```bash
cd VRMMetalKit
git checkout main
git pull origin main
git checkout -b fix/issue-35-shader-compilation
```

## 2. Problem Analysis

### Current State

**The Problem:**
- Every time a `VRMRenderer` is created, it compiles shaders from source using `device.makeLibrary(source:options:)`
- This happens at **6 different locations** in `VRMRenderer+Pipeline.swift`:
  - Line 133: MToon shader (752 lines of Metal code)
  - Line 266: MToon skinned shader
  - Line 286: MToon library (duplicate)
  - Line 402: Toon2D shader (453 lines)
  - Line 524: Toon2D skinned shader (411 lines)
  - Line 655: Sprite shader (284 lines)

**Performance Impact:**
- Runtime shader compilation takes **tens of milliseconds** per renderer creation
- On iOS: Even slower due to memory constraints and thermal throttling
- Multiple renderer instances: Each recompiles the same shaders
- Total shader source: ~2,177 lines of Metal code compiled every time

**Why This Happens:**
```swift
// Current code in VRMRenderer+Pipeline.swift:133
let library = try device.makeLibrary(source: MToonShader.shaderSource, options: nil)
```

The shader source is embedded as a 478-line string literal in `MToonShader.swift` (lines 24-502).

### Working Example

**SpringBoneComputeSystem** already does this correctly:
```swift
// SpringBoneComputeSystem.swift:104-111
guard let url = Bundle.module.url(forResource: "VRMMetalKitShaders", withExtension: "metallib") else {
    throw SpringBoneError.failedToLoadShaders
}
library = try device.makeLibrary(URL: url)
```

The precompiled `VRMMetalKitShaders.metallib` (104KB) contains:
- SpringBone compute kernels
- Morph target compute shaders
- Debug shaders

**But it's missing:** MToon, Toon2D, and Sprite rendering shaders!

## 3. Implementation Plan

### Phase 1: Extract Shader Sources to .metal Files

**Files to Create:**

1. **`Sources/VRMMetalKit/Shaders/MToonShader.metal`**
   - Extract lines 24-502 from `MToonShader.swift`
   - Contains: `mtoon_vertex`, `mtoon_fragment`, `mtoon_vertex_skinned`, `mtoon_fragment_skinned`

2. **`Sources/VRMMetalKit/Shaders/Toon2DShader.metal`**
   - Extract shader source from `Toon2DShader.swift`
   - Contains: `toon2d_vertex`, `toon2d_fragment`

3. **`Sources/VRMMetalKit/Shaders/Toon2DSkinnedShader.metal`**
   - Extract shader source from `Toon2DSkinnedShader.swift`
   - Contains: `toon2d_vertex_skinned`, `toon2d_fragment_skinned`

4. **`Sources/VRMMetalKit/Shaders/SpriteShader.metal`**
   - Extract shader source from `SpriteShader.swift`
   - Contains: `sprite_vertex`, `sprite_fragment`

**Action Items:**
```bash
# Extract MToon shader
cd VRMMetalKit
sed -n '25,501p' Sources/VRMMetalKit/Shaders/MToonShader.swift | \
    sed 's/^    //' > Sources/VRMMetalKit/Shaders/MToonShader.metal

# Similar for other shaders (will provide exact commands)
```

### Phase 2: Update Package.swift

**Current exclusions:**
```swift
exclude: [
    "Shaders/MorphTargetCompute.metal",
    "Shaders/MorphAccumulate.metal",
    "Shaders/SpringBonePredict.metal",
    "Shaders/SpringBoneDistance.metal",
    "Shaders/SpringBoneCollision.metal",
    "Shaders/SpringBoneKinematic.metal",
    "Shaders/DebugShaders.metal"
]
```

**Add new exclusions:**
```swift
exclude: [
    // Existing...
    "Shaders/MToonShader.metal",
    "Shaders/Toon2DShader.metal",
    "Shaders/Toon2DSkinnedShader.metal",
    "Shaders/SpriteShader.metal"
]
```

### Phase 3: Recompile metallib

**Build command:**
```bash
# Compile all .metal files into metallib
xcrun metal -c Sources/VRMMetalKit/Shaders/*.metal -o /tmp/shaders.air
xcrun metallib /tmp/shaders.air -o Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib
```

**Verify functions:**
```bash
xcrun metal-objdump -macho -function-list Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib
```

### Phase 4: Create Pipeline Cache Manager

**New file:** `Sources/VRMMetalKit/Renderer/VRMPipelineCache.swift`

```swift
import Metal

/// Global pipeline state cache to avoid recompiling shaders
/// Shared across all VRMRenderer instances
public final class VRMPipelineCache: @unchecked Sendable {
    public static let shared = VRMPipelineCache()
    
    private let lock = NSLock()
    private var libraries: [String: MTLLibrary] = [:]
    private var pipelineStates: [String: MTLRenderPipelineState] = [:]
    
    private init() {}
    
    /// Load or retrieve cached metallib
    func getLibrary(device: MTLDevice) throws -> MTLLibrary {
        return try lock.withLock {
            let key = "VRMMetalKitShaders"
            
            if let cached = libraries[key] {
                return cached
            }
            
            // Try loading from default library first (for development)
            if let defaultLib = device.makeDefaultLibrary() {
                libraries[key] = defaultLib
                return defaultLib
            }
            
            // Load from packaged metallib
            guard let url = Bundle.module.url(forResource: "VRMMetalKitShaders", 
                                             withExtension: "metallib") else {
                throw VRMError.shaderLibraryNotFound
            }
            
            let library = try device.makeLibrary(URL: url)
            libraries[key] = library
            return library
        }
    }
    
    /// Get or create cached pipeline state
    func getPipelineState(
        device: MTLDevice,
        descriptor: MTLRenderPipelineDescriptor,
        key: String
    ) throws -> MTLRenderPipelineState {
        return try lock.withLock {
            if let cached = pipelineStates[key] {
                return cached
            }
            
            let state = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelineStates[key] = state
            return state
        }
    }
    
    /// Clear cache (for testing or memory pressure)
    public func clearCache() {
        lock.withLock {
            libraries.removeAll()
            pipelineStates.removeAll()
        }
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
```

### Phase 5: Update VRMRenderer+Pipeline.swift

**Replace runtime compilation with cached loading:**

```swift
// OLD (Line 133):
let library = try device.makeLibrary(source: MToonShader.shaderSource, options: nil)

// NEW:
let library = try VRMPipelineCache.shared.getLibrary(device: device)
```

**Add pipeline state caching:**

```swift
// After creating pipeline descriptor
let pipelineKey = "mtoon_\(alphaMode)_\(isSkinned)"
let pipelineState = try VRMPipelineCache.shared.getPipelineState(
    device: device,
    descriptor: pipelineDescriptor,
    key: pipelineKey
)
```

**Apply to all 6 compilation sites:**
1. Line 133: MToon shader
2. Line 266: MToon skinned
3. Line 286: MToon (duplicate - can be removed)
4. Line 402: Toon2D
5. Line 524: Toon2D skinned
6. Line 655: Sprite shader

### Phase 6: Update Swift Shader Files

**Modify these files to remove embedded shader source:**

1. **`MToonShader.swift`** (752 lines → ~250 lines)
   - Remove `shaderSource` string literal (lines 24-502)
   - Keep only Swift helper structs and functions
   - Add deprecation notice

2. **`Toon2DShader.swift`** (453 lines → ~150 lines)
   - Remove shader source
   - Keep configuration helpers

3. **`Toon2DSkinnedShader.swift`** (411 lines → ~150 lines)
   - Remove shader source

4. **`SpriteShader.swift`** (284 lines → ~100 lines)
   - Remove shader source

**Example transformation:**

```swift
// BEFORE:
public class MToonShader {
    public static let shaderSource = """
    #include <metal_stdlib>
    // ... 478 lines of Metal code ...
    """
}

// AFTER:
public class MToonShader {
    // Shader source moved to MToonShader.metal
    // Compiled into VRMMetalKitShaders.metallib
    
    /// Vertex function name in metallib
    public static let vertexFunctionName = "mtoon_vertex"
    
    /// Fragment function name in metallib
    public static let fragmentFunctionName = "mtoon_fragment"
    
    // Keep Swift helper structs...
}
```

## 4. Best Practices

### Error Handling

```swift
// Graceful fallback for development
func loadShaderLibrary(device: MTLDevice) throws -> MTLLibrary {
    // Try precompiled metallib first (production)
    if let library = try? VRMPipelineCache.shared.getLibrary(device: device) {
        return library
    }
    
    // Fallback to runtime compilation (development only)
    #if DEBUG
    vrmLog("⚠️ [VRMRenderer] Falling back to runtime shader compilation (development mode)")
    return try device.makeLibrary(source: MToonShader.shaderSource, options: nil)
    #else
    throw VRMError.shaderLibraryNotFound
    #endif
}
```

### Logging and Debugging

```swift
// Add performance tracking
let startTime = CACurrentMediaTime()
let library = try VRMPipelineCache.shared.getLibrary(device: device)
let elapsed = (CACurrentMediaTime() - startTime) * 1000
vrmLog("[VRMRenderer] Shader library loaded in \(String(format: "%.2f", elapsed))ms")
```

### Performance Considerations

**Before (Runtime Compilation):**
- First renderer: ~50-100ms (compile all shaders)
- Second renderer: ~50-100ms (recompile everything)
- iOS: Even slower (thermal throttling)

**After (Precompiled + Cached):**
- First renderer: ~1-2ms (load metallib once)
- Second renderer: ~0.1ms (cache hit)
- iOS: Same fast performance

**Memory Impact:**
- Metallib size: ~104KB → ~150KB (adding rendering shaders)
- Runtime memory: Reduced (no compilation overhead)
- Pipeline cache: ~10KB per pipeline state

## 5. Testing Strategy

### Unit Tests

```swift
func testShaderLibraryLoading() throws {
    let device = MTLCreateSystemDefaultDevice()!
    let library = try VRMPipelineCache.shared.getLibrary(device: device)
    
    // Verify all expected functions exist
    XCTAssertNotNil(library.makeFunction(name: "mtoon_vertex"))
    XCTAssertNotNil(library.makeFunction(name: "mtoon_fragment"))
    XCTAssertNotNil(library.makeFunction(name: "toon2d_vertex"))
    XCTAssertNotNil(library.makeFunction(name: "sprite_vertex"))
}

func testPipelineCacheReuse() throws {
    let device = MTLCreateSystemDefaultDevice()!
    
    // Create two renderers
    let renderer1 = VRMRenderer(device: device)
    let renderer2 = VRMRenderer(device: device)
    
    // Second renderer should be much faster (cache hit)
    // Measure and verify
}
```

### Performance Tests

```swift
func testRendererCreationPerformance() throws {
    let device = MTLCreateSystemDefaultDevice()!
    
    measure {
        let renderer = VRMRenderer(device: device)
        // Should complete in <5ms with caching
    }
}
```

### Integration Tests

```swift
func testAllRenderingModesStillWork() throws {
    let device = MTLCreateSystemDefaultDevice()!
    let renderer = VRMRenderer(device: device)
    
    // Test MToon rendering
    // Test Toon2D rendering
    // Test sprite rendering
    // Test skinned vs static
    // Test all alpha modes (opaque, mask, blend)
}
```

## 6. Migration Path

### For Library Users

**No breaking changes!** The API remains identical:
```swift
// Still works exactly the same
let renderer = VRMRenderer(device: device)
```

### For Contributors

**Development workflow:**
1. Edit `.metal` files (not `.swift` shader sources)
2. Recompile metallib: `make shaders` (add Makefile target)
3. Test changes

**Makefile addition:**
```makefile
.PHONY: shaders
shaders:
	xcrun metal -c Sources/VRMMetalKit/Shaders/*.metal -o /tmp/shaders.air
	xcrun metallib /tmp/shaders.air -o Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib
	@echo "✅ Shaders compiled successfully"
```

## 7. Expected Results

### Performance Improvements

**Renderer Creation Time:**
- Before: 50-100ms (first instance), 50-100ms (subsequent)
- After: 1-2ms (first instance), 0.1ms (subsequent)
- **Improvement: 50-100x faster**

**App Launch Time:**
- Before: Noticeable delay when creating renderer
- After: Instant renderer creation

**Memory Usage:**
- Before: Temporary spike during compilation
- After: Flat, predictable memory usage

### Code Quality

**Lines of Code Reduction:**
- MToonShader.swift: 752 → ~250 lines (-502)
- Toon2DShader.swift: 453 → ~150 lines (-303)
- Toon2DSkinnedShader.swift: 411 → ~150 lines (-261)
- SpriteShader.swift: 284 → ~100 lines (-184)
- **Total reduction: ~1,250 lines**

**Maintainability:**
- Shader code in proper `.metal` files (syntax highlighting, tooling)
- Swift files contain only configuration/helpers
- Clear separation of concerns

## 8. Rollout Plan

### Phase 1: Preparation (Day 1)
- ✅ Create branch
- ✅ Analyze current implementation
- Extract shader sources to .metal files
- Update Package.swift exclusions

### Phase 2: Core Implementation (Day 1-2)
- Create VRMPipelineCache
- Update VRMRenderer+Pipeline.swift
- Recompile metallib
- Update Swift shader files

### Phase 3: Testing (Day 2)
- Unit tests for library loading
- Performance benchmarks
- Integration tests for all rendering modes
- Test on macOS and iOS

### Phase 4: Documentation (Day 2)
- Update CLAUDE.md
- Add inline comments
- Document performance improvements
- Update contributor guide

### Phase 5: PR and Review (Day 3)
- Create pull request
- Link to issue #35
- Include performance measurements
- Request review

## 9. Success Criteria

- [ ] All shaders load from precompiled metallib
- [ ] No runtime shader compilation in production
- [ ] Pipeline states cached and reused
- [ ] Renderer creation <5ms (first instance)
- [ ] Renderer creation <1ms (subsequent instances)
- [ ] All rendering modes work correctly
- [ ] Tests pass on macOS and iOS
- [ ] Code size reduced by ~1,250 lines
- [ ] Documentation updated

## 10. Risks and Mitigations

### Risk: Metallib not found in production
**Mitigation:** Add DEBUG fallback to runtime compilation

### Risk: Function names mismatch
**Mitigation:** Add validation in strict mode

### Risk: Breaking existing code
**Mitigation:** Comprehensive integration tests

### Risk: Platform-specific issues
**Mitigation:** Test on both macOS and iOS before merging