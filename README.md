# VRMMetalKit

A high-performance Swift Package for loading and rendering VRM 1.0 avatars using Apple's Metal framework.

[![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%2026%2B%20%7C%20iOS%2026%2B-blue.svg)](https://developer.apple.com)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Models License](https://img.shields.io/badge/Models-VPL%201.0-green.svg)](LICENSE-MODELS.md)

## Features
check
✨ **VRM 1.0 Specification Support**
- Full VRM 1.0 (VRMC_vrm) and VRM 0.0 fallback support
- MToon shader implementation with all features
- 55 humanoid bones (required + optional)
- 18 facial expressions (emotions, visemes, gaze)
- First-person view annotations
- Complete metadata and licensing support

🎭 **Best-in-Class Animation System**
- VRMA (VRM Animation) loader with intelligent retargeting
- Humanoid bone mapping with three-tier fallback system
- Non-humanoid node animation (hair, accessories, clothing)
- Rest pose retargeting with quaternion delta computation
- AnimationPlayer with looping, speed control, and root motion

⚙️ **GPU-Accelerated Physics**
- SpringBone system with XPBD (Extended Position-Based Dynamics)
- Metal compute shaders for parallel physics simulation
- Fixed 120Hz substep simulation for stability
- Sphere and capsule collider support
- Configurable gravity, wind, drag, and stiffness

🎨 **Advanced Rendering**
- MToon shader with proper NPR (Non-Photorealistic Rendering)
- Matcap, rim lighting, and outline rendering
- Morph target support with GPU compute acceleration
- Skinning with up to 256 joints per skin
- Triple-buffered uniforms for smooth rendering

📊 **Performance & Debugging**
- Built-in performance metrics tracking
- StrictMode validation system with three levels
- Conditional debug logging (zero overhead when disabled)
- Comprehensive error handling and reporting

## Installation

### Swift Package Manager

Add VRMMetalKit to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/arkavo-org/VRMMetalKit", from: "0.1.0")
]
```

Or in Xcode: **File → Add Package Dependencies** and enter the repository URL.

## Quick Start

### Basic Setup

```swift
import VRMMetalKit
import Metal
import MetalKit

// 1. Create Metal device and renderer
let device = MTLCreateSystemDefaultDevice()!
let renderer = VRMRenderer(device: device)

// 2. Load a VRM model
let modelURL = Bundle.main.url(forResource: "avatar", withExtension: "vrm")!
let model = try await VRMModel.load(from: modelURL, device: device)

// 3. Load the model into the renderer
renderer.loadModel(model)

// 4. Set up camera
renderer.projectionMatrix = perspective(fov: 45, aspect: 16/9, near: 0.1, far: 100)
renderer.viewMatrix = lookAt(eye: [0, 1.5, 3], center: [0, 1, 0], up: [0, 1, 0])

// 5. Render in MTKView delegate
func draw(in view: MTKView) {
    guard let commandBuffer = commandQueue.makeCommandBuffer(),
          let renderPassDescriptor = view.currentRenderPassDescriptor else {
        return
    }

    renderer.draw(in: view, commandBuffer: commandBuffer,
                  renderPassDescriptor: renderPassDescriptor)

    commandBuffer.present(view.currentDrawable!)
    commandBuffer.commit()
}
```

### Loading VRMA Animations

```swift
// Load animation
let animURL = Bundle.main.url(forResource: "dance", withExtension: "vrma")!
let clip = try VRMAnimationLoader.loadVRMA(from: animURL, model: model)

// Create animation player
let player = AnimationPlayer()
player.load(clip)
player.isLooping = true
player.speed = 1.0

// Update in render loop
player.update(deltaTime: Float(1.0 / 60.0), model: model)
```

### Using SpringBone Physics

```swift
// Initialize GPU SpringBone system
try model.initializeSpringBoneGPUSystem(device: device)

// Physics is automatically updated during rendering
// Configure global parameters:
if let springBoneParams = model.springBoneGlobalParams {
    springBoneParams.gravity = SIMD3<Float>(0, -9.8, 0)
    springBoneParams.windAmplitude = 0.5
    springBoneParams.windDirection = SIMD3<Float>(1, 0, 0)
}

// Apply external forces
renderer.applySpringBoneForce(
    direction: SIMD3<Float>(1, 0, 0),
    strength: 5.0,
    duration: 0.5
)
```

## StrictMode Validation

VRMMetalKit includes a comprehensive validation system to catch rendering issues early during development.

### Validation Levels

```swift
public enum StrictLevel {
    case off    // Default - soft fallbacks, logs only
    case warn   // Log errors and mark frame invalid
    case fail   // Throw/abort on first violation
}
```

### Usage

```swift
// Development: Catch issues early
let config = RendererConfig(strict: .fail)
let renderer = VRMRenderer(device: device, config: config)

// Production: Log but continue
let config = RendererConfig(strict: .warn)

// Release: No validation overhead
let config = RendererConfig(strict: .off)
```

### What StrictMode Validates

**Pipeline Validation:**
- Shader function existence and compilation
- Pipeline state creation
- Depth stencil state configuration

**Uniform Validation:**
- Struct size matching between Swift and Metal
- Buffer size adequacy
- Index conflict detection

**Resource Validation:**
- Buffer index bounds checking
- Texture and sampler slot conflicts
- Vertex format correctness

**Draw Call Validation:**
- Zero vertex/index detection
- Index range bounds checking
- Minimum draw call requirements

**Frame Validation:**
- Command buffer completion status
- Frame content validation (all-white/all-black detection)
- Draw call count verification

### Example: Debug Specific Primitives

```swift
// Render only a specific mesh for debugging
config.renderFilter = .mesh("face.baked")

// Render only first N draw calls
config.drawUntil = 5

// Render only draw call K
config.drawOnlyIndex = 3

// Test with identity joint matrices
config.testIdentityPalette = 0  // Test skin 0
```

### Resource Index Contract

VRMMetalKit enforces a strict contract for buffer and texture indices to prevent conflicts:

```swift
// Vertex shader buffer indices (defined in StrictMode.swift)
ResourceIndices.vertexBuffer           // 0
ResourceIndices.uniformsBuffer         // 1
ResourceIndices.skinDataBuffer         // 2
ResourceIndices.jointMatricesBuffer    // 3
ResourceIndices.morphWeightsBuffer     // 4
ResourceIndices.morphPositionDeltas    // 5-12 (8 slots)
ResourceIndices.morphNormalDeltas      // 13-20 (8 slots)

// Fragment shader texture indices
ResourceIndices.baseColorTexture       // 0
ResourceIndices.shadeTexture           // 1
ResourceIndices.normalTexture          // 2
ResourceIndices.emissiveTexture        // 3
ResourceIndices.matcapTexture          // 4
ResourceIndices.rimMultiplyTexture     // 5
```

## Performance Monitoring

VRMMetalKit includes built-in performance tracking with comprehensive metrics.

### Enable Performance Tracking

```swift
// Create tracker
renderer.performanceTracker = PerformanceTracker()

// Get metrics after rendering
if let metrics = renderer.getPerformanceMetrics() {
    print("FPS: \(metrics.fps)")
    print("Frame Time (avg): \(metrics.frameTimeAvgMs)ms")
    print("Frame Time (p95): \(metrics.frameTimeP95Ms)ms")
    print("GPU Time (p95): \(metrics.gpuTimeP95Ms)ms")
    print("Draw Calls: \(metrics.drawCalls)")
    print("Triangles: \(metrics.triangleCount)")
    print("State Changes: \(metrics.stateChanges)")
    print("Morph Computes: \(metrics.morphComputes)")
}

// Reset accumulated stats
renderer.resetPerformanceMetrics()
```

### Available Metrics

- **Frame Times:** avg, min, max, p50, p95, p99
- **GPU Time:** p95 percentile
- **Draw Statistics:** draw calls, triangles, vertices
- **State Changes:** pipeline, texture, buffer bindings
- **Compute Dispatches:** morph target computations
- **Memory:** allocated and peak usage

## Debug Logging

VRMMetalKit uses conditional compilation flags for zero-overhead debug logging.

### Available Flags

| Flag | Purpose | Use Case |
|------|---------|----------|
| `VRM_METALKIT_ENABLE_LOGS` | General logs | Basic debugging |
| `VRM_METALKIT_ENABLE_DEBUG_ANIMATION` | Animation system | Animation retargeting issues |
| `VRM_METALKIT_ENABLE_DEBUG_PHYSICS` | SpringBone physics | Physics simulation debugging |
| `VRM_METALKIT_ENABLE_DEBUG_LOADER` | VRMA loading | Import/parsing issues |

### Enable During Development

**Swift Package Manager:**
```bash
swift build -Xswiftc -DVRM_METALKIT_ENABLE_LOGS
swift build -Xswiftc -DVRM_METALKIT_ENABLE_DEBUG_ANIMATION
```

**Xcode:**
1. Select your target
2. Build Settings → Swift Compiler - Custom Flags
3. Add to "Other Swift Flags":
   - `-DVRM_METALKIT_ENABLE_LOGS`
   - `-DVRM_METALKIT_ENABLE_DEBUG_ANIMATION`

### Disable for Production

Simply omit the flags and all logging code is compiled out with zero runtime cost.

## Advanced Features

### Bounding Box Calculation

```swift
// Calculate AABB from vertex data
let (min, max) = model.calculateBoundingBox()

// Include animated transforms
let (min, max) = model.calculateBoundingBox(includeAnimated: true)

// For skinned models (uses skeleton)
let (min, max, center, size) = model.calculateSkinnedBoundingBox()
```

### Expression Control

```swift
// Manual expression control
let controller = renderer.expressionController
controller?.setExpressionWeight(.happy, weight: 1.0)
controller?.setExpressionWeight(.blink, weight: 0.5)
controller?.setCustomExpressionWeight("custom_smile", weight: 0.8)

// Or use AnimationPlayer for automated expressions
player.applyMorphWeights(to: controller)
```

### LookAt System

```swift
// Set look target
let lookAt = renderer.lookAtController
lookAt?.setTarget(SIMD3<Float>(0, 1.5, -2))
lookAt?.update(model: model)
```

### Material Inspection

```swift
// Generate material report
let report = renderer.generateMaterialReport()
print("Total materials: \(report.materials.count)")

for mat in report.materials {
    print("Material: \(mat.name)")
    print("  Alpha mode: \(mat.alphaMode)")
    print("  Textures: \(mat.textureCount)")
    if let mtoon = mat.mtoon {
        print("  MToon: shading=\(mtoon.shadingToonyFactor)")
    }
}
```

## Architecture

### Module Organization

```
VRMMetalKit/
├── Core/
│   ├── VRMModel.swift        # Main model class
│   ├── VRMTypes.swift         # VRM specification types
│   ├── VRMLogger.swift        # Conditional logging
│   └── StrictMode.swift       # Validation system
├── Loader/
│   ├── GLTFParser.swift       # glTF/GLB parsing
│   ├── BufferLoader.swift     # Binary data loading
│   ├── TextureLoader.swift    # Image loading
│   └── VRMExtensionParser.swift # VRM extension parsing
├── Renderer/
│   ├── VRMRenderer.swift      # Main renderer
│   ├── VRMRenderer+Pipeline.swift # Pipeline setup
│   ├── VRMGeometry.swift      # Mesh/primitive data
│   └── VRMDebugRenderer.swift # Debug visualization
├── Animation/
│   ├── AnimationPlayer.swift  # Playback controller
│   ├── VRMAnimationLoader.swift # VRMA import
│   ├── VRMSkinning.swift      # Skeletal animation
│   ├── VRMMorphTargets.swift  # Blend shapes
│   ├── VRMLookAtController.swift # Eye tracking
│   └── VRMSpringBoneSystem.swift # Physics
├── Shaders/
│   ├── MToonShader.swift      # MToon implementation
│   ├── SkinnedShader.swift    # Skinned vertex shader
│   ├── MorphTargetCompute.metal # Morph GPU compute
│   ├── SpringBone*.metal      # Physics compute shaders
│   └── DebugShaders.metal     # Debug visualization
└── Performance/
    └── PerformanceMetrics.swift # Metrics tracking
```

### Key Design Decisions

**Triple-Buffered Uniforms:** Eliminates CPU-GPU sync stalls ([ADR-002](docs/adr/002-triple-buffered-uniforms.md))

**GPU Compute for Morphs:** Handles 8+ morph targets efficiently ([ADR-003](docs/adr/003-gpu-compute-morph-targets.md))

**XPBD SpringBone:** Stable physics with fixed substeps at 120Hz ([ADR-004](docs/adr/004-xpbd-springbone-physics.md))

**Strict Resource Indices:** Prevents binding conflicts ([ADR-005](docs/adr/005-strictmode-validation.md))

**Conditional Logging:** Zero overhead in production ([ADR-006](docs/adr/006-conditional-compilation-logging.md))

**For detailed rationale and alternatives considered, see [Architecture Decision Records (ADRs)](docs/adr/README.md).**

## Thread Safety and Concurrency

**VRMMetalKit is NOT thread-safe by default.** All public classes are designed for single-threaded use, typically on the main thread.

### Key Points

- **VRMRenderer**, **VRMModel**, and **AnimationPlayer** are **NOT thread-safe**
- Some classes use `@unchecked Sendable` for async/await compatibility, but this does NOT mean they are thread-safe
- Metal command queues are thread-safe, but renderer state is not
- All mutations should happen on the main thread or a dedicated rendering thread

### Safe Pattern: Main Thread

```swift
// ✅ SAFE: Everything on main thread
func update(deltaTime: Float) {
    animationPlayer.update(deltaTime: deltaTime, model: model)
    renderer.render(model: model, in: metalView)
}
```

### Safe Pattern: Background Loading

```swift
// ✅ SAFE: Load on background, use on main
Task.detached {
    let model = try GLTFParser.loadVRM(from: url, device: device)

    await MainActor.run {
        self.model = model
        self.renderer.model = model
    }
}
```

### Unsafe Pattern: Concurrent Access

```swift
// ❌ UNSAFE: Don't access from multiple threads
DispatchQueue.global().async {
    renderer.outlineWidth = 2.0  // Data race!
}
```

**For detailed guidance, see [CONCURRENCY.md](CONCURRENCY.md).**

## Metal Shader Compilation

VRMMetalKit uses pre-compiled Metal shaders for optimal performance. Shaders are excluded from Swift Package Manager compilation and must be compiled separately.

### Quick Start

```bash
# Compile all Metal shaders
./compile-shaders.sh
```

The script compiles all `.metal` files in `Sources/VRMMetalKit/Shaders/` and creates `VRMMetalKitShaders.metallib` in `Sources/VRMMetalKit/Resources/`.

### Runtime Loading

VRMMetalKit automatically loads shaders with a three-tier fallback:

1. **Default library** (if shaders compiled into app)
2. **Package `.metallib`** (pre-compiled bundle)
3. **Inline source** (emergency fallback for critical shaders)

This ensures the library always functions, even if shader compilation was skipped.

### Verification

```bash
# Verify compiled library
xcrun metal-nm Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib
```

**For complete compilation instructions, CI integration, and troubleshooting, see [SHADERS.md](SHADERS.md).**

## Performance Tips

### Optimization Checklist

✅ **Disable debug logging** in production builds (omit compiler flags)

✅ **Use `.off` StrictMode** for release builds

✅ **Enable triple buffering** (enabled by default)

✅ **Batch state changes** (VRMRenderer does this automatically)

✅ **Use compute path for 8+ morph targets** (automatic)

✅ **Profile with Instruments** to identify bottlenecks

✅ **Consider LOD** for distant avatars (manual implementation needed)

### Expected Performance

On Apple Silicon (M1/M2/M3):
- **60 FPS** for complex VRM models (15K+ triangles, 8+ morphs)
- **120 FPS** for simple models (5K triangles, basic animation)
- **SpringBone:** 50-100 bones at 120Hz substeps with minimal overhead

## Error Handling

VRMMetalKit provides comprehensive, LLM-friendly error messages designed for the Game of Mods character creator.

### Error Types

All errors implement `LocalizedError` with detailed contextual information:

```swift
do {
    let model = try await VRMModel.load(from: url, device: device)
} catch let error as VRMError {
    // Error includes:
    // - Specific indices (meshIndex, textureIndex, etc.)
    // - File paths for context
    // - Actionable suggestions
    // - Links to specifications
    print(error.localizedDescription)
}
```

### Example Error Output

```
❌ Missing Required Humanoid Bone: 'hips'

The VRM model in file '/path/to/model.vrm' is missing the required humanoid bone 'hips'.
Available bones: spine, chest, head, leftUpperArm, rightUpperArm

Suggestion: Ensure your 3D model has a bone for 'hips' and that it's properly mapped
in the VRM humanoid configuration. Common bone names include: Hips, Spine, Chest, Neck,
Head, LeftUpperArm, RightUpperArm, etc.

VRM Spec: https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm-1.0/humanoid.md
```

### Error Categories

- **VRM Extension Errors:** Missing or invalid VRM extension data
- **Humanoid Bone Errors:** Missing required bones, with list of available bones
- **File Format Errors:** Invalid GLB/glTF format, JSON parsing issues
- **Buffer/Accessor Errors:** Missing buffer data, invalid accessors with size info
- **Texture Errors:** Missing textures, invalid image data, with URIs
- **Mesh/Geometry Errors:** Invalid mesh data, missing vertex attributes
- **Material Errors:** Invalid material properties or configurations

### Character Creator Integration

Errors are designed to be parsed by LLMs to provide guidance:

```swift
// LLM can extract:
// - What went wrong (error type)
// - Where it went wrong (indices, file paths)
// - Why it went wrong (reason)
// - How to fix it (suggestions + spec links)
```

## Troubleshooting

### Common Issues

**Model renders as solid color:**
- Check that textures loaded: `model.textures.forEach { print($0.mtlTexture != nil) }`
- Verify material has valid texture indices
- Enable StrictMode.warn to see validation errors

**Animation doesn't play:**
- Verify `player.isPlaying == true`
- Check that model has humanoid bone mappings
- Enable `VRM_METALKIT_ENABLE_DEBUG_ANIMATION` to see bone updates

**SpringBone doesn't move:**
- Call `model.initializeSpringBoneGPUSystem(device:)`
- Check `model.springBone != nil`
- Verify physics update is called each frame

**Face/eyes render incorrectly:**
- Check depth state configuration in StrictMode validation
- Verify material alpha modes are correct
- Use `config.renderFilter` to isolate specific meshes

**Performance issues:**
- Enable `performanceTracker` to identify bottlenecks
- Check draw call count (should be <100 for most models)
- Profile GPU time vs CPU time
- Consider disabling SpringBone for distant models

### Debug Techniques

```swift
// 1. Isolate specific draw calls
config.drawUntil = 10  // Only render first 10 primitives

// 2. Test without skinning
renderer.disableSkinning = true

// 3. Test without morphs
renderer.disableMorphs = true

// 4. Visualize wireframe
renderer.debugWireframe = true

// 5. Check material report
let report = renderer.generateMaterialReport()
print(report)

// 6. Validate index/accessor consistency
model.runIndexAccessorAudit()
```

## Contributing

Contributions are welcome! Please read our [Contributing Guidelines](CONTRIBUTING.md) and [Code of Conduct](CODE_OF_CONDUCT.md).

**Quick checklist:**
1. Follow existing code style and architecture
2. Add tests for new features
3. Update documentation
4. Add Apache 2.0 license headers to new files
5. Use descriptive commit messages
6. Submit pull requests against `main` branch

For security issues, see [SECURITY.md](SECURITY.md).

## Licensing

VRMMetalKit uses a **dual licensing structure** to clearly distinguish between code and content:

### Source Code - Apache License 2.0

All source code (`.swift`, `.metal` files) is licensed under the **Apache License 2.0**.

```
Copyright 2025 Arkavo

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

See [LICENSE](LICENSE) for the full Apache 2.0 license text.

### VRM Models and Assets - VPL 1.0

VRM model files (`.vrm`) and 3D avatar assets follow the **VRM Platform License 1.0** (VPL 1.0) as defined by the VRM Consortium.

Each VRM model contains its own licensing metadata:
- **Author attribution** (required)
- **Commercial use permissions** (varies per model)
- **Modification rights** (varies per model)
- **Redistribution terms** (varies per model)

See [LICENSE-MODELS.md](LICENSE-MODELS.md) for details on VRM Platform License 1.0.

**Key Point**: When using VRMMetalKit, you must comply with:
1. **Apache 2.0** for the library code
2. **VPL 1.0** and model-specific licenses for any VRM models you use

### Attribution

VRMMetalKit implements the [VRM specification](https://github.com/vrm-c/vrm-specification) developed by the VRM Consortium. The VRM specification is licensed under Creative Commons Attribution 4.0 International (CC BY 4.0).

See [NOTICE](NOTICE) for complete attribution information.

## Credits

**Developed by**: [Arkavo](https://arkavo.org)

**Based on**: [VRM Specification](https://github.com/vrm-c/vrm-specification) by the VRM Consortium

**Built with**: Apple's Metal framework for high-performance GPU rendering

## Version History

See [CHANGELOG.md](CHANGELOG.md) for detailed version history.

### 0.1.0 (Current - Initial Release)
- ✅ VRM 1.0 and VRMA animation support
- ✅ MToon shader with full feature set
- ✅ GPU-accelerated SpringBone physics
- ✅ Performance metrics and StrictMode validation
- ✅ Conditional debug logging
- ✅ Comprehensive documentation

---

**Questions?** Open an issue on GitHub

**Need help?** Check the troubleshooting section above