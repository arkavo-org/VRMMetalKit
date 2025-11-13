# Exact Code Modifications for Issue #35

This document contains the exact code changes needed to complete the shader compilation fix.
These changes should be applied on a macOS machine with Xcode after compiling the metallib.

## Step 1: Compile Shaders (macOS with Xcode required)

```bash
cd VRMMetalKit
make shaders
```

This will create/update `Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib`

## Step 2: Modify VRMRenderer+Pipeline.swift

### Modification 1: Line 128-133 (setupPipeline function)

**FIND:**
```swift
func setupPipeline() {
    // Use MToon shader for proper VRM rendering

    do {
        // Create library from MToon shader source
        let library = try device.makeLibrary(source: MToonShader.shaderSource, options: nil)
```

**REPLACE WITH:**
```swift
func setupPipeline() {
    // Use MToon shader for proper VRM rendering

    do {
        // Load precompiled shader library (50-100x faster than runtime compilation)
        let library = try VRMPipelineCache.shared.getLibrary(device: device)
```

### Modification 2: Line 195-200 (After creating opaqueDescriptor)

**FIND:**
```swift
let opaqueState = try device.makeRenderPipelineState(descriptor: opaqueDescriptor)
try strictValidator?.validatePipelineState(opaqueState, name: "mtoon_opaque_pipeline")
opaquePipelineState = opaqueState
```

**REPLACE WITH:**
```swift
// Use cached pipeline state for better performance
let opaqueState = try VRMPipelineCache.shared.getPipelineState(
    device: device,
    descriptor: opaqueDescriptor,
    key: "mtoon_opaque"
)
try strictValidator?.validatePipelineState(opaqueState, name: "mtoon_opaque_pipeline")
opaquePipelineState = opaqueState
```

### Modification 3: Around Line 210 (BLEND pipeline creation)

**FIND:**
```swift
let blendState = try device.makeRenderPipelineState(descriptor: blendDescriptor)
try strictValidator?.validatePipelineState(blendState, name: "mtoon_blend_pipeline")
blendPipelineState = blendState
```

**REPLACE WITH:**
```swift
// Use cached pipeline state for better performance
let blendState = try VRMPipelineCache.shared.getPipelineState(
    device: device,
    descriptor: blendDescriptor,
    key: "mtoon_blend"
)
try strictValidator?.validatePipelineState(blendState, name: "mtoon_blend_pipeline")
blendPipelineState = blendState
```

### Modification 4: Around Line 220 (MASK pipeline creation)

**FIND:**
```swift
let maskState = try device.makeRenderPipelineState(descriptor: maskDescriptor)
try strictValidator?.validatePipelineState(maskState, name: "mtoon_mask_pipeline")
maskPipelineState = maskState
```

**REPLACE WITH:**
```swift
// Use cached pipeline state for better performance
let maskState = try VRMPipelineCache.shared.getPipelineState(
    device: device,
    descriptor: maskDescriptor,
    key: "mtoon_mask"
)
try strictValidator?.validatePipelineState(maskState, name: "mtoon_mask_pipeline")
maskPipelineState = maskState
```

### Modification 5: Line 266 (setupSkinnedPipeline function)

**FIND:**
```swift
library = try device.makeLibrary(source: MToonSkinnedShader.source, options: nil)
```

**REPLACE WITH:**
```swift
// Load precompiled shader library (reuses cached library from setupPipeline)
library = try VRMPipelineCache.shared.getLibrary(device: device)
```

### Modification 6: Around Line 286 (setupOutlinePipeline function)

**FIND:**
```swift
let mtoonLibrary = try device.makeLibrary(source: MToonShader.shaderSource, options: nil)
```

**REPLACE WITH:**
```swift
// Load precompiled shader library (reuses cached library)
let mtoonLibrary = try VRMPipelineCache.shared.getLibrary(device: device)
```

### Modification 7: Line 402 (setupToon2DPipeline function)

**FIND:**
```swift
let library = try device.makeLibrary(source: Toon2DShader.shaderSource, options: nil)
```

**REPLACE WITH:**
```swift
// Load precompiled shader library
let library = try VRMPipelineCache.shared.getLibrary(device: device)
```

### Modification 8: Around Line 450 (Toon2D pipeline state creation)

**FIND:**
```swift
let pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
```

**REPLACE WITH:**
```swift
// Use cached pipeline state
let pipelineState = try VRMPipelineCache.shared.getPipelineState(
    device: device,
    descriptor: pipelineDescriptor,
    key: "toon2d_\(alphaMode)"
)
```

### Modification 9: Line 524 (setupToon2DSkinnedPipeline function)

**FIND:**
```swift
let library = try device.makeLibrary(source: Toon2DSkinnedShader.shaderSource, options: nil)
```

**REPLACE WITH:**
```swift
// Load precompiled shader library
let library = try VRMPipelineCache.shared.getLibrary(device: device)
```

### Modification 10: Around Line 570 (Toon2D skinned pipeline state creation)

**FIND:**
```swift
let pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
```

**REPLACE WITH:**
```swift
// Use cached pipeline state
let pipelineState = try VRMPipelineCache.shared.getPipelineState(
    device: device,
    descriptor: pipelineDescriptor,
    key: "toon2d_skinned_\(alphaMode)"
)
```

### Modification 11: Line 655 (setupSpritePipeline function)

**FIND:**
```swift
let library = try device.makeLibrary(source: SpriteShader.shaderSource, options: nil)
```

**REPLACE WITH:**
```swift
// Load precompiled shader library
let library = try VRMPipelineCache.shared.getLibrary(device: device)
```

### Modification 12: Around Line 700 (Sprite pipeline state creation)

**FIND:**
```swift
let pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
```

**REPLACE WITH:**
```swift
// Use cached pipeline state
let pipelineState = try VRMPipelineCache.shared.getPipelineState(
    device: device,
    descriptor: pipelineDescriptor,
    key: "sprite"
)
```

## Step 3: Update Swift Shader Files

### 3.1 MToonShader.swift

**FIND (lines 24-502):**
```swift
public static let shaderSource = """
#include <metal_stdlib>
// ... 478 lines of Metal code ...
"""
```

**REPLACE WITH:**
```swift
// Shader source moved to MToonShader.metal
// Compiled into VRMMetalKitShaders.metallib for optimal performance
// This eliminates 50-100ms of runtime shader compilation per renderer instance

/// Vertex function name in metallib
public static let vertexFunctionName = "mtoon_vertex"

/// Fragment function name in metallib  
public static let fragmentFunctionName = "mtoon_fragment_v2"

/// Outline vertex function name
public static let outlineVertexFunctionName = "mtoon_outline_vertex"

/// Outline fragment function name
public static let outlineFragmentFunctionName = "mtoon_outline_fragment"

// Keep all the Swift helper structs and functions below...
```

### 3.2 Toon2DShader.swift

**FIND (lines 25-346):**
```swift
public static let shaderSource = """
// ... Metal code ...
"""
```

**REPLACE WITH:**
```swift
// Shader source moved to Toon2DShader.metal
// Compiled into VRMMetalKitShaders.metallib

/// Vertex function name in metallib
public static let vertexFunctionName = "vertex_main"

/// Fragment function name in metallib
public static let fragmentFunctionName = "fragment_main"

/// Outline vertex function name
public static let outlineVertexFunctionName = "outline_vertex"

/// Outline fragment function name
public static let outlineFragmentFunctionName = "outline_fragment"

// Keep Swift helper structs...
```

### 3.3 Toon2DSkinnedShader.swift

**FIND (lines 25-394):**
```swift
public static let shaderSource = """
// ... Metal code ...
"""
```

**REPLACE WITH:**
```swift
// Shader source moved to Toon2DSkinnedShader.metal
// Compiled into VRMMetalKitShaders.metallib

/// Vertex function name in metallib
public static let vertexFunctionName = "vertex_main"

/// Fragment function name in metallib
public static let fragmentFunctionName = "fragment_main"

// Keep Swift helper structs...
```

### 3.4 SpriteShader.swift

**FIND (lines 25-150):**
```swift
public static let shaderSource = """
// ... Metal code ...
"""
```

**REPLACE WITH:**
```swift
// Shader source moved to SpriteShader.metal
// Compiled into VRMMetalKitShaders.metallib

/// Vertex function name in metallib
public static let vertexFunctionName = "sprite_vertex"

/// Instanced vertex function name
public static let instancedVertexFunctionName = "sprite_instanced_vertex"

/// Fragment function name in metallib
public static let fragmentFunctionName = "sprite_fragment"

/// Premultiplied alpha fragment function name
public static let premultipliedFragmentFunctionName = "sprite_premultiplied_fragment"

// Keep Swift helper structs...
```

### 3.5 SkinnedShader.swift

**FIND (lines 21-276):**
```swift
public static let source = """
// ... Metal code ...
"""
```

**REPLACE WITH:**
```swift
// Shader source moved to SkinnedShader.metal
// Compiled into VRMMetalKitShaders.metallib

/// Vertex function name in metallib
public static let vertexFunctionName = "mtoon_vertex_skinned"

/// Fragment function name in metallib
public static let fragmentFunctionName = "mtoon_fragment_skinned"

// Keep Swift helper structs...
```

## Step 4: Add Development Fallback (Optional)

For development convenience, you can add a fallback to runtime compilation in DEBUG mode.

Add this helper function to VRMPipelineCache.swift:

```swift
#if DEBUG
/// Fallback to runtime compilation for development (when metallib is not available)
func getLibraryWithFallback(device: MTLDevice, source: String) throws -> MTLLibrary {
    do {
        return try getLibrary(device: device)
    } catch {
        vrmLog("⚠️ [VRMPipelineCache] Falling back to runtime compilation (development mode)")
        return try device.makeLibrary(source: source, options: nil)
    }
}
#endif
```

Then in VRMRenderer+Pipeline.swift, you can use:

```swift
#if DEBUG
let library = try VRMPipelineCache.shared.getLibraryWithFallback(
    device: device,
    source: MToonShader.shaderSource
)
#else
let library = try VRMPipelineCache.shared.getLibrary(device: device)
#endif
```

## Step 5: Verify Changes

After making all modifications:

1. **Build the project:**
   ```bash
   swift build
   ```

2. **Run tests:**
   ```bash
   swift test
   ```

3. **Verify metallib contains all functions:**
   ```bash
   make list-functions
   ```

4. **Check for compilation errors:**
   - All references to `.shaderSource` should be removed
   - All `makeLibrary(source:)` calls should be replaced
   - All `makeRenderPipelineState` calls should use cache

## Step 6: Performance Testing

Add this test to verify performance improvement:

```swift
func testRendererCreationPerformance() throws {
    let device = MTLCreateSystemDefaultDevice()!
    
    // Clear cache to simulate first run
    VRMPipelineCache.shared.clearCache()
    
    // Measure first renderer creation
    let start1 = CACurrentMediaTime()
    let renderer1 = VRMRenderer(device: device)
    let elapsed1 = (CACurrentMediaTime() - start1) * 1000
    
    // Measure second renderer creation (should be much faster)
    let start2 = CACurrentMediaTime()
    let renderer2 = VRMRenderer(device: device)
    let elapsed2 = (CACurrentMediaTime() - start2) * 1000
    
    print("First renderer: \(elapsed1)ms")
    print("Second renderer: \(elapsed2)ms")
    print("Speedup: \(elapsed1 / elapsed2)x")
    
    // Second renderer should be at least 10x faster
    XCTAssertLessThan(elapsed2, elapsed1 / 10)
}
```

## Expected Results

- **First renderer creation:** 1-2ms (down from 50-100ms)
- **Second renderer creation:** 0.1ms (down from 50-100ms)
- **Code reduction:** ~1,250 lines removed
- **Metallib size:** ~150KB (up from 104KB)

## Troubleshooting

### Issue: "Function not found in library"
**Solution:** Verify function names match between .metal files and Swift code

### Issue: "metallib not found"
**Solution:** Ensure `make shaders` was run and metallib is in Resources/

### Issue: "Compilation errors in .metal files"
**Solution:** Check for syntax errors, missing includes, or type mismatches

### Issue: "Tests fail after changes"
**Solution:** Verify all rendering modes still work, check pipeline state keys are unique