# VRMRenderer Strict Mode

## Overview

Strict Mode is a comprehensive validation system that transforms silent rendering failures into loud, fail-fast errors. This helps catch issues like missing pipeline states, uniform mismatches, and invalid draw calls early in development.

## Problem Statement

Previously, the renderer had numerous fallback behaviors that masked bugs:
- PSO/function lookup failures returned nil and rendered white
- Missing/bad bindings produced blank frames without crashes
- Uniform layout mismatches went unnoticed
- Zero draw calls produced empty frames silently

## Solution

Strict Mode provides three validation levels:

### Levels

#### `off` (default)
- Current behavior with soft fallbacks
- Logs errors but continues rendering
- Maintains backward compatibility

#### `warn`
- No fallbacks - logs all violations
- Marks frames as invalid
- Continues rendering for debugging

#### `fail`
- Throws/aborts on first violation
- Command buffer errors escalate
- Perfect for CI/testing

## Usage

### Command Line
```bash
# Default (off)
./VRMPlayground model.vrm

# Warning mode
./VRMPlayground --strict warn model.vrm

# Fail-fast mode (recommended for CI)
./VRMPlayground --strict fail model.vrm
```

### Programmatic
```swift
// Create renderer with strict mode
let config = RendererConfig(strict: .fail)
let renderer = VRMRenderer(device: device, config: config)
```

## What Strict Mode Validates

### 1. Shader/PSO Creation
- Missing vertex/fragment/compute functions
- Pipeline state creation failures
- Depth stencil state creation
- Pixel format mismatches

### 2. Uniform Layout Validation
- Swift struct size vs Metal struct size
- Buffer size requirements
- Correct stride usage in setBytes calls

### 3. Resource Index Contract
- Buffer index conflicts
- Texture index conflicts
- Validates against ResourceIndices constants

### 4. Command Buffer Errors
- Completion handler checks status
- Escalates errors based on strict level
- Metal validation layers in debug

### 5. Frame Validation
- Minimum draw calls per frame
- Detects all-white frames (luma ≈ 1.0)
- Zero vertices/indices detection

### 6. Vertex Attributes
- Format validation (JOINTS_0, WEIGHTS_0)
- Stride/offset calculations
- Buffer size requirements

## Error Messages

Strict Mode provides detailed, actionable error messages:

```
❌ [StrictMode] Missing vertex function 'mtoon_vertex' in shader library
❌ [StrictMode] Uniform struct size mismatch for MToonMaterial: Swift=144 bytes, Metal=152 bytes
❌ [StrictMode] Buffer index 3 conflict: existing=jointMatrices, new=morphWeights
❌ [StrictMode] No draw calls in frame (expected >= 1)
❌ [StrictMode] Frame is all white (luma=0.99)
```

## Implementation Details

### Key Files
- `Core/StrictMode.swift` - Core validation infrastructure
- `Renderer/VRMRenderer.swift` - Integration points
- `VRMPlayground/AppDelegate.swift` - CLI parsing

### ResourceIndices
Single source of truth for all buffer/texture indices:
```swift
public struct ResourceIndices {
    // Vertex buffers
    public static let vertexBuffer = 0
    public static let uniformsBuffer = 1
    public static let jointMatricesBuffer = 3
    public static let morphedPositionsBuffer = 21

    // Fragment buffers
    public static let materialUniforms = 0

    // Textures
    public static let baseColorTexture = 0
    // ... etc
}
```

## Testing

Run the test suite:
```bash
./test_strict_mode.sh /path/to/model.vrm
```

## CI Integration

Always use `--strict fail` in CI:
```yaml
- name: Test VRM Rendering
  run: |
    swift build --configuration release
    .build/release/VRMPlayground --strict fail test.vrm
```

## Migration Guide

1. **Existing code** - No changes needed, defaults to `off`
2. **Development** - Use `warn` to identify issues
3. **Production** - Use `fail` in tests/CI
4. **Debugging** - `warn` shows all issues without stopping

## Benefits

1. **Early Detection** - Catches issues at the source
2. **Clear Errors** - Detailed messages with exact problems
3. **CI Safety** - Prevents broken renders from merging
4. **Better Debugging** - No more silent white models
5. **Maintained Compatibility** - Opt-in system, old code works

## Future Enhancements

- [ ] Headless probe integration for automated testing
- [ ] Performance impact metrics per validation
- [ ] Custom validation hooks for specific models
- [ ] Visual diff testing with strict mode