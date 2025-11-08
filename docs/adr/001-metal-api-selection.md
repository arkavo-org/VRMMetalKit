# ADR-001: Use Metal API for GPU Rendering

**Status:** Accepted

**Date:** 2025-01-15

**Deciders:** VRMMetalKit Core Team

**Tags:** architecture, graphics, performance

## Context and Problem Statement

VRMMetalKit needs a high-performance graphics API to render VRM avatars on Apple platforms. The rendering pipeline must support advanced features like skeletal animation, morph targets, physics simulation, and NPR (non-photorealistic) shading. What graphics API should we use as the foundation of VRMMetalKit?

## Decision Drivers

- **Performance**: Need 60+ FPS for complex avatars with thousands of triangles
- **Platform Support**: Must run on macOS 14+ and iOS 17+
- **GPU Compute**: Required for physics simulation and morph target blending
- **Shader Flexibility**: Custom MToon shader implementation with rim lighting, matcap, outlines
- **Triple Buffering**: Efficient CPU-GPU pipelining to minimize stalls
- **Apple Ecosystem**: First-class integration with Apple platforms and tools

## Considered Options

1. **Metal** - Apple's modern GPU API
2. **OpenGL/OpenGL ES** - Cross-platform legacy API
3. **Vulkan via MoltenVK** - Cross-platform modern API with Metal translation layer
4. **SceneKit** - High-level 3D framework built on Metal

## Decision Outcome

**Chosen option:** "Metal", because it provides the best performance, lowest latency, and most direct GPU access on Apple platforms. It's the only API that meets all our requirements for compute shaders, triple buffering, and fine-grained control.

### Positive Consequences

- **Maximum Performance**: Direct GPU access with minimal driver overhead
- **Compute Shaders**: Native support for physics simulation (SpringBone XPBD)
- **Modern Design**: Resource heaps, argument buffers, unified memory architecture
- **Apple Integration**: Excellent Xcode debugging tools (Metal Debugger, Instruments)
- **Future-Proof**: Active development, new features each iOS/macOS release
- **Shader Language**: Metal Shading Language (MSL) is expressive and well-documented

### Negative Consequences

- **Platform Lock-In**: Metal only works on Apple platforms (macOS, iOS, tvOS)
- **No Cross-Platform**: Cannot port to Android, Windows, or Linux without rewrite
- **Learning Curve**: Metal-specific concepts (command buffers, encoders, pipeline states)
- **Shader Compilation**: Requires macOS for compiling `.metal` files to `.metallib`

## Pros and Cons of the Options

### Metal

**Pros:**

- Industry-leading performance on Apple Silicon (M1/M2/M3)
- Native compute shader support for physics and morphing
- Unified memory architecture reduces copies
- Triple-buffering built into command queue design
- Metal Performance Shaders (MPS) for common operations
- Excellent profiling with Instruments and Metal Debugger
- Active ecosystem and community

**Cons:**

- Apple platforms only - no cross-platform support
- Shaders must be compiled on macOS
- Steeper initial learning curve than high-level frameworks

### OpenGL/OpenGL ES

**Pros:**

- Cross-platform (macOS, iOS, Android, Windows, Linux)
- Mature ecosystem with extensive documentation
- Simpler shader compilation (GLSL can compile at runtime)

**Cons:**

- **Deprecated on Apple platforms** (macOS 10.14 removed updates)
- Lower performance than Metal (more driver overhead)
- Limited compute shader support (OpenGL 4.3+, not on iOS)
- No triple buffering without manual implementation
- Poor Apple Silicon optimization
- No future updates or bug fixes from Apple

### Vulkan via MoltenVK

**Pros:**

- Modern API with explicit control
- Cross-platform portability (Vulkan runs everywhere)
- MoltenVK translates to Metal on Apple platforms
- Compute shader support

**Cons:**

- Translation layer adds complexity and potential bugs
- Performance overhead from Vulkan→Metal translation
- More verbose API than Metal (more boilerplate code)
- Limited MoltenVK support on older macOS/iOS versions
- Extra dependency in the build chain

### SceneKit

**Pros:**

- High-level API, easier to learn
- Built-in animation, physics, and scene graph
- Native Apple framework, no external dependencies

**Cons:**

- **Insufficient control** for custom rendering (MToon shader, outlines)
- Cannot implement XPBD physics with custom compute shaders
- Performance overhead from scene graph and high-level abstractions
- Limited morph target support (no GPU acceleration)
- Black-box rendering makes debugging difficult

## Implementation Notes

### Triple-Buffered Uniforms

Metal's command queue design naturally supports triple buffering:

```swift
let commandQueue = device.makeCommandQueue()!
let bufferIndex = frameCount % 3  // Cycle 0→1→2→0

// Each frame gets its own uniform buffer
uniformBuffers[bufferIndex].contents().copyMemory(from: uniforms)
```

This eliminates CPU-GPU synchronization stalls, allowing rendering at maximum throughput.

### Compute Shaders

Metal compute shaders power two critical systems:

1. **Morph Targets**: GPU-accelerated blend shape blending for 8+ targets
2. **SpringBone Physics**: Parallel XPBD simulation at 120Hz substeps

Both would be impossible or inefficient with OpenGL ES or SceneKit.

### Shader Compilation

Metal shaders compile to `.metallib` via:

```bash
xcrun -sdk macosx metal -c shader.metal -o shader.air
xcrun -sdk macosx metallib shader.air -o shaders.metallib
```

This offline compilation ensures fast loading and consistent behavior.

## Links

- [Metal Programming Guide](https://developer.apple.com/documentation/metal)
- [Metal Best Practices](https://developer.apple.com/documentation/metal/metal_best_practices_guide)
- Related: ADR-002 (Triple-Buffered Uniforms)
- Related: ADR-003 (GPU Compute for Morph Targets)

## Notes

This decision was made early in the project (2024) and remains valid. The deprecation of OpenGL on macOS made Metal the only viable choice for long-term Apple platform support. The performance benefits have been validated - VRMMetalKit achieves 60 FPS for complex models (15K+ triangles, 50+ bones, 8+ morphs) on Apple Silicon.
