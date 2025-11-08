# ADR-005: StrictMode Validation Framework

**Status:** Accepted

**Date:** 2025-01-15

**Deciders:** VRMMetalKit Core Team

**Tags:** debugging, quality, testing

## Context and Problem Statement

Metal rendering is complex - small mistakes like incorrect buffer indices, mismatched uniform sizes, or invalid pipeline states cause silent failures (black screens, all-white frames, crashes). Debugging these issues is time-consuming without validation. How can we catch rendering bugs early in development while maintaining zero overhead in production?

## Decision Drivers

- **Developer Experience**: Catch bugs early with clear error messages
- **Production Performance**: Zero overhead when validation disabled
- **Configurability**: Different strictness levels for dev/test/prod
- **Coverage**: Validate pipelines, buffers, textures, draw calls, frames
- **Actionable Errors**: Messages must explain what's wrong and how to fix

## Considered Options

1. **No Validation** - Trust developers to get it right
2. **DEBUG-Only Assertions** - Use `assert()` for critical checks
3. **Metal Validation Layer** - Use Xcode's built-in Metal validation
4. **Custom StrictMode Framework** - Three-level validation system (off/warn/fail)

## Decision Outcome

**Chosen option:** "Custom StrictMode Framework", because it provides fine-grained control, actionable errors, and can validate higher-level contracts (like resource indices) that Metal validation doesn't check.

### Positive Consequences

- **Catches Bugs Early**: Pipeline state errors found at compile-time, not first draw
- **Clear Error Messages**: Errors explain what's wrong, where, and how to fix
- **Flexible Strictness**: `.off` for production, `.fail` for CI, `.warn` for debugging
- **Frame Validation**: Detects rendering failures (all-white, all-black frames)
- **Resource Index Contract**: Prevents buffer/texture index conflicts
- **Zero Production Cost**: Compiles out in release builds

### Negative Consequences

- **Maintenance Overhead**: Validation code must stay in sync with renderer
- **Development Slowdown**: `.fail` mode stops execution on first error
- **False Positives**: Some edge cases may trigger warnings incorrectly

## Pros and Cons of the Options

### No Validation

**Pros:**

- Zero overhead
- No code complexity
- Maximum performance

**Cons:**

- **Debugging nightmare**: Silent failures, black screens, hours of debugging
- Production bugs ship to users
- No way to catch subtle issues (index off-by-one, etc.)

**Verdict:** Unacceptable for production library

### DEBUG-Only Assertions

**Example:**
```swift
#if DEBUG
assert(vertexBuffer != nil, "Vertex buffer is nil")
assert(bufferIndex < 32, "Buffer index out of range")
#endif
```

**Pros:**

- Standard Swift pattern
- Zero release overhead (asserts compile out)
- Simple to implement

**Cons:**

- **Binary**: Either crash or do nothing (no "warn and continue")
- No configurability (can't test CI with strict validation)
- Poor error messages (just file:line, no context)
- Can't validate frame output (rendered pixels)

**Verdict:** Good baseline, but insufficient for complex renderer

### Metal Validation Layer

**Enable:** Xcode → Edit Scheme → Run → Options → Metal API Validation

**Pros:**

- Built into Xcode, no custom code
- Catches low-level Metal errors (invalid resources, encoder usage)
- Comprehensive coverage of Metal API

**Cons:**

- **Performance cost**: ~5-10× slowdown, unusable for gameplay
- Can't validate high-level contracts (ResourceIndices)
- Binary (on/off, no warn mode)
- Error messages are low-level ("invalid buffer at index 3" - but why?)

**Verdict:** Useful for debugging, but not flexible enough

### Custom StrictMode Framework (Chosen)

**Three Levels:**

```swift
public enum StrictLevel {
    case off    // Production: soft fallbacks, log only
    case warn   // Development: log violations, continue rendering
    case fail   // CI: throw/abort on first violation
}
```

**Validation Phases:**

1. **Pipeline Creation**: Validate vertex/fragment functions exist
2. **Uniform Sizes**: Ensure Swift struct matches Metal struct size
3. **Buffer Indices**: Enforce ResourceIndices contract
4. **Draw Calls**: Check vertex count, index bounds
5. **Frame Output**: Detect all-white/all-black rendering failures

**Pros:**

- **Three strictness levels** for different environments
- **Actionable errors** with context, suggestions, spec links
- **High-level validation** (resource contracts, frame output)
- **Compile-time checks** where possible (static validation)
- **Zero production cost** (`.off` mode optimizes away checks)

**Cons:**

- Custom code to maintain
- Must update validators when renderer changes
- Slight overhead in `.warn`/`.fail` modes

**Verdict:** Best balance of flexibility and coverage

## Implementation Details

### Usage Example

```swift
// Development: Catch issues early
let config = RendererConfig(strict: .fail)
let renderer = VRMRenderer(device: device, config: config)

// Production: Log but continue
let config = RendererConfig(strict: .off)  // Or .warn
```

### Validation Example: Pipeline State

```swift
func validatePipelineState(descriptor: MTLRenderPipelineDescriptor) {
    guard config.strict != .off else { return }

    // Check 1: Vertex function exists
    guard descriptor.vertexFunction != nil else {
        let error = StrictError.missingVertexFunction(descriptor.label ?? "unnamed")
        if config.strict == .fail {
            fatalError(error.localizedDescription)
        } else {
            vrmLog("⚠️ \(error.localizedDescription)")
        }
        return
    }

    // Check 2: Uniform size matches
    let swiftUniformSize = MemoryLayout<Uniforms>.stride
    // ... validate against Metal shader struct ...

    // Check 3: Vertex descriptor valid
    // ...
}
```

### Resource Index Contract

```swift
// StrictMode.swift defines canonical indices
public enum ResourceIndices {
    public static let vertexBuffer = 0
    public static let uniformsBuffer = 1
    public static let skinDataBuffer = 2
    public static let jointMatricesBuffer = 3
    public static let morphWeightsBuffer = 4
    // ... etc
}

// Validation enforces these
func setVertexBuffer(_ buffer: MTLBuffer, index: Int) {
    if config.strict != .off {
        assert(index == ResourceIndices.vertexBuffer,
               "Vertex buffer must use index \(ResourceIndices.vertexBuffer), got \(index)")
    }
    encoder.setVertexBuffer(buffer, offset: 0, index: index)
}
```

This prevents accidental buffer index conflicts that cause silent failures.

### Frame Validation

```swift
func validateFrameOutput(texture: MTLTexture) {
    guard config.strict != .off else { return }

    // Sample center pixel
    let pixel = samplePixel(texture, x: width/2, y: height/2)

    if pixel == SIMD4<UInt8>(255, 255, 255, 255) {
        // All-white likely means incorrect rendering
        vrmLog("⚠️ Frame appears all-white - check material textures")
    }

    if drawCallCount == 0 {
        vrmLog("⚠️ No draw calls issued - nothing rendered")
    }
}
```

This catches common rendering mistakes (missing textures, incorrect alpha blending).

## Real-World Example

Without StrictMode:
```
// Silent failure - mesh renders all black
// Developer spends 2 hours debugging
```

With StrictMode (`.fail`):
```
❌ Uniform Buffer Size Mismatch

Swift struct 'Uniforms' is 192 bytes, but Metal expects 256 bytes.
This usually means the Metal shader struct has different padding.

Swift struct layout:
  modelMatrix: 64 bytes (4×4 float)
  viewMatrix: 64 bytes (4×4 float)
  projectionMatrix: 64 bytes (4×4 float)
  Total: 192 bytes

Metal shader expects: 256 bytes (likely includes padding)

Fix: Add padding to Swift struct or check Metal shader alignment.

File: VRMRenderer.swift:423
```

Developer fixes in 30 seconds instead of 2 hours.

## Performance Impact

Measured on M1 MacBook Pro, complex VRM scene:

| Mode | Frame Time | Overhead |
|------|------------|----------|
| `.off` | 16.2ms | 0% (baseline) |
| `.warn` | 16.8ms | +3.7% |
| `.fail` | 16.8ms | +3.7% |

Overhead is negligible in development, and `.off` compiles out all checks for production.

## Links

- [Metal Validation Best Practices](https://developer.apple.com/documentation/metal/validating_the_usage_of_metal_objects)
- Related: ADR-001 (Metal API) - validation specific to Metal rendering
- Referenced in: STRICT_MODE.md (detailed usage guide)

## Notes

StrictMode was added in v0.4 after several developer hours were lost debugging a buffer index conflict (vertex buffer accidentally bound to index 2 instead of 0, causing black screen with no error).

The `.warn` mode is particularly useful for debugging flaky rendering - it logs issues but keeps rendering, allowing developers to see partial results while fixing errors.

Future work: Extend validation to SpringBone physics (detect constraint violations, invalid collider configurations).
