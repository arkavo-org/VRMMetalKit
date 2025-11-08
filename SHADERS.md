# Metal Shader Compilation Guide

This document explains how Metal shaders are compiled and distributed in VRMMetalKit.

## Overview

VRMMetalKit uses Metal shaders for GPU-accelerated rendering and physics. The shader source files (`.metal`) are excluded from Swift Package Manager compilation and must be pre-compiled into a `.metallib` library for distribution.

## Shader Files

The following Metal shaders are included in VRMMetalKit:

| Shader File | Purpose | Type |
|------------|---------|------|
| `MorphTargetCompute.metal` | Blend shape morphing (8+ targets) | Compute |
| `MorphAccumulate.metal` | Morph target accumulation | Compute |
| `SpringBonePredict.metal` | XPBD physics prediction step | Compute |
| `SpringBoneDistance.metal` | Physics distance constraints | Compute |
| `SpringBoneCollision.metal` | Sphere/capsule colliders | Compute |
| `SpringBoneKinematic.metal` | Kinematic bone updates | Compute |
| `DebugShaders.metal` | Wireframe and debug visualization | Vertex/Fragment |

All shader source files are located in `Sources/VRMMetalKit/Shaders/`.

## Why Pre-compilation?

Swift Package Manager doesn't automatically compile Metal shaders. Pre-compiling offers several advantages:

1. **Faster Runtime Loading**: Compiled shaders load instantly vs. runtime compilation
2. **Compile-Time Validation**: Catch shader syntax errors during build
3. **Smaller Distribution**: Binary `.metallib` is more compact than source
4. **Consistent Behavior**: Same shader code across all platforms

## Compilation Methods

### Method 1: Automated Script (Recommended)

Use the provided compilation script:

```bash
# Compile for macOS (default)
./compile-shaders.sh

# Compile for iOS
COMPILE_FOR_IOS=1 ./compile-shaders.sh
```

The script will:
1. Compile each `.metal` file to `.air` (intermediate format)
2. Link all `.air` files into `VRMMetalKitShaders.metallib`
3. Place the library in `Sources/VRMMetalKit/Resources/`
4. Clean up intermediate files

### Method 2: Manual Command Line

For manual compilation:

```bash
# Step 1: Compile each shader to .air
xcrun -sdk macosx metal -c \
    Sources/VRMMetalKit/Shaders/MorphTargetCompute.metal \
    -o MorphTargetCompute.air \
    -std=metal3.0

xcrun -sdk macosx metal -c \
    Sources/VRMMetalKit/Shaders/SpringBonePredict.metal \
    -o SpringBonePredict.air \
    -std=metal3.0

# ... repeat for all shaders ...

# Step 2: Link all .air files into a single library
xcrun -sdk macosx metallib \
    *.air \
    -o Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib

# Step 3: Clean up intermediate files
rm *.air
```

### Method 3: Xcode Build Phase

For Xcode-based projects:

1. Select your target in Xcode
2. Go to **Build Phases**
3. Add a new **Run Script Phase**
4. Add this script:

```bash
# Metal Shader Compilation
SHADER_DIR="${PROJECT_DIR}/Sources/VRMMetalKit/Shaders"
RESOURCE_DIR="${PROJECT_DIR}/Sources/VRMMetalKit/Resources"
OUTPUT_LIB="VRMMetalKitShaders.metallib"

# Compile shaders
cd "${SHADER_DIR}"
xcrun -sdk macosx metal -c *.metal -std=metal3.0
xcrun -sdk macosx metallib *.air -o "${RESOURCE_DIR}/${OUTPUT_LIB}"
rm *.air

echo "✅ Metal shaders compiled successfully"
```

5. Move the script phase to run **before** "Compile Sources"

## Runtime Shader Loading

VRMMetalKit uses a two-tier fallback strategy for loading shaders:

### 1. Default Library (Preferred)

```swift
// Try to load from the default Metal library
var library = device.makeDefaultLibrary()
```

When shaders are compiled into your app bundle, they're available in the default library.

### 2. Package Bundle (Fallback)

```swift
// Fall back to the compiled .metallib in the package
if library == nil {
    let url = Bundle.module.url(
        forResource: "VRMMetalKitShaders",
        withExtension: "metallib"
    )!
    library = try device.makeLibrary(URL: url)
}
```

This loads the pre-compiled `.metallib` from the Swift package resources.

### 3. Inline Source (Emergency Fallback)

For critical shaders (like morph accumulation), VRMMetalKit includes inline source code as a last resort:

```swift
// Emergency fallback: compile from inline source
let source = """
#include <metal_stdlib>
kernel void morph_accumulate(...) { ... }
"""
let library = try device.makeLibrary(source: source, options: nil)
```

This ensures the library always functions, even if shader compilation was skipped.

## Verifying Shader Compilation

After compiling shaders, verify they're correct:

```bash
# List all functions in the library
xcrun -sdk macosx metal-nm Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib

# Expected output (kernel functions):
# _morph_accumulate_positions
# _spring_bone_predict
# _spring_bone_distance_constraint
# _spring_bone_collision
# _spring_bone_kinematic
# ... etc
```

## Troubleshooting

### Error: "Shader function 'xxx' not found"

**Cause**: The `.metallib` is missing or was not compiled correctly.

**Solution**:
1. Run `./compile-shaders.sh`
2. Verify `Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib` exists
3. Check that `Package.swift` includes the Resources directory

### Error: "Failed to create Metal library"

**Cause**: Shader syntax error or incompatible Metal version.

**Solution**:
1. Compile manually to see detailed error messages:
   ```bash
   xcrun -sdk macosx metal -c Sources/VRMMetalKit/Shaders/MorphTargetCompute.metal -std=metal3.0
   ```
2. Fix any syntax errors
3. Ensure Metal 3.0 is supported (macOS 13+, iOS 16+)

### Warning: "Metal language version 3.0 is not supported"

**Cause**: Running on older OS versions.

**Solution**: Metal 3.0 requires macOS 13+ / iOS 16+. For older OS support, change `-std=metal3.0` to `-std=metal2.4` in the compilation script.

### Shader Functions Not Found at Runtime

**Cause**: Function names may not match between code and shaders.

**Solution**: Verify function names:
```bash
# List functions in compiled library
xcrun metal-nm Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib | grep kernel

# Check source code references
grep -r "makeFunction(name:" Sources/VRMMetalKit/
```

## CI/CD Integration

### GitHub Actions

Add shader compilation to your CI workflow:

```yaml
name: Build and Test

on: [push, pull_request]

jobs:
  build:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v3

      - name: Compile Metal Shaders
        run: ./compile-shaders.sh

      - name: Verify shader compilation
        run: |
          if [ ! -f Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib ]; then
            echo "❌ Shader compilation failed"
            exit 1
          fi

      - name: Build
        run: swift build -v

      - name: Test
        run: swift test -v
```

### Pre-commit Hook

Automatically compile shaders before committing:

```bash
# .git/hooks/pre-commit
#!/bin/bash
./compile-shaders.sh
git add Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib
```

## Shader Development Workflow

1. **Edit** shader source in `Sources/VRMMetalKit/Shaders/*.metal`
2. **Compile** using `./compile-shaders.sh`
3. **Test** with `swift test` or run your app
4. **Commit** both source and compiled `.metallib`

## Distribution Checklist

Before releasing VRMMetalKit:

- [ ] All shaders compile without errors
- [ ] `VRMMetalKitShaders.metallib` exists in `Sources/VRMMetalKit/Resources/`
- [ ] `.metallib` file is tracked in git
- [ ] `Package.swift` includes `.process("Resources")`
- [ ] CI validates shader compilation
- [ ] README mentions shader compilation requirements

## Platform-Specific Notes

### macOS

- Requires Xcode Command Line Tools: `xcode-select --install`
- Metal 3.0 requires macOS 13 Ventura or later
- Shaders compile for Apple Silicon and Intel Macs

### iOS

- Set `COMPILE_FOR_IOS=1` when compiling
- Requires iOS SDK: `xcode-select -p`
- Metal 3.0 requires iOS 16 or later

### Linux

**Metal shaders cannot be compiled on Linux.** VRMMetalKit is macOS/iOS only due to Metal framework dependency.

## Advanced: Shader Debugging

### Metal Debugger in Xcode

1. Run your app from Xcode
2. Click the Metal frame capture button (camera icon)
3. Inspect shader execution, GPU timings, and resources

### Metal System Trace

Profile shader performance with Instruments:

```bash
# Launch Instruments Metal System Trace
open -a Instruments
```

1. Select "Metal System Trace" template
2. Record your app's rendering
3. Analyze GPU time per shader

### Shader Compiler Warnings

Enable all warnings during compilation:

```bash
xcrun -sdk macosx metal -c shader.metal -Wall -Wextra -Wpedantic
```

## Resources

- [Metal Shading Language Specification](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf)
- [Metal Best Practices Guide](https://developer.apple.com/documentation/metal/metal_best_practices_guide)
- [Metal Debugging Tools](https://developer.apple.com/documentation/metal/developing_and_debugging_metal_shaders)

## Questions?

If you encounter shader compilation issues not covered here, please open an issue on GitHub with:
- Your macOS/Xcode version
- Complete error output from the compilation script
- The specific shader file causing problems
