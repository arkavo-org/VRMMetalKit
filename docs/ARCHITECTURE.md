# VRMMetalKit Architecture

This document describes the architecture, module structure, design patterns, and data flows in VRMMetalKit.

## Project Overview

VRMMetalKit is a high-performance Swift Package for loading and rendering VRM 1.0 avatars using Apple's Metal framework. Supports macOS 26+ and iOS 26+, built with Swift 6.2.

## Module Structure

The codebase is organized into logical subsystems:

### Core/
Foundational types and model representation

- **VRMModel.swift**: Central model class holding all VRM/glTF data, nodes, meshes, materials
- **VRMTypes.swift**: VRM specification types (VRMHumanoid, VRMMeta, VRMExpressions, etc.)
- **StrictMode.swift**: Three-level validation system (.off, .warn, .fail) with ResourceIndices contract
- **VRMLogger.swift**: Conditional compilation logging (zero overhead in production)

### Loader/
Parsing and asset loading

- **GLTFParser.swift**: Main glTF/GLB binary parsing
- **VRMExtensionParser.swift**: VRM extension extraction (VRMC_vrm, VRMC_springBone, VRMC_node_constraint)
- **BufferLoader.swift**: Binary buffer data loading and accessor handling
- **TextureLoader.swift**: Image loading and Metal texture creation

### Renderer/
GPU rendering pipeline

- **VRMRenderer.swift**: Main renderer with triple-buffered uniforms, dual pipeline states (skinned/non-skinned)
- **VRMRenderer+Pipeline.swift**: Pipeline state creation for different alpha modes (opaque, blend, wireframe)
- **VRMGeometry.swift**: Mesh and primitive data structures
- **CharacterPrioritySystem.swift**: Z-sorting for layered rendering
- **SpriteCacheSystem.swift**: Texture atlas caching for 2D mode

### Shaders/
GPU shader implementations

- **MToonShader.swift**: MToon shader (VRM standard NPR shader) with matcap, rim lighting, outlines
- **SkinnedShader.swift**: Skeletal animation vertex shader
- **Toon2DShader.swift** / **Toon2DSkinnedShader.swift**: 2.5D cel-shaded rendering mode
- **SpriteShader.swift**: 2D sprite rendering for UI/avatars
- **MorphTargetCompute.metal**: GPU compute for blend shape morphs (8+ targets)
- **SpringBone*.metal**: Physics compute shaders (Predict, Distance, Collision, Kinematic)
- **DebugShaders.metal**: Wireframe and debug visualization

### Animation/
Animation and deformation systems

- **AnimationPlayer.swift**: Playback controller with looping, speed control, root motion
- **VRMAnimationLoader.swift**: VRMA file loading with intelligent humanoid bone retargeting
- **VRMSkinning.swift**: Skeletal animation with up to 256 joints
- **VRMMorphTargets.swift**: Blend shape system with GPU acceleration
- **VRMLookAtController.swift**: Eye/head tracking system
- **AnimationLibrary.swift**: Animation clip management

### SpringBone/
GPU-accelerated physics simulation

- **SpringBoneComputeSystem.swift**: Main XPBD physics loop at fixed 120Hz substeps
- **SpringBoneSkinningSystem.swift**: Integration with skeletal animation
- **SpringBoneBuffers.swift**: GPU buffer management for physics state
- **SpringBoneDebug.swift**: Visualization and debugging utilities
- Compute shaders: **SpringBoneKinematic.metal**, **SpringBonePredict.metal**, **SpringBoneDistance.metal**

### Builder/
Programmatic model creation

- **VRMBuilder.swift**: Fluent API for creating VRM models from code
- **CharacterRecipe.swift**: Character templates and presets
- **GLTFDocumentBuilder.swift**: Low-level glTF construction
- **VRMModel+Serialization.swift**: Binary .vrm export

### Performance/
Metrics and profiling

- **PerformanceMetrics.swift**: Frame time tracking (avg, p50, p95, p99), GPU time, draw calls, triangles, state changes

### Debug/
Debugging and visualization

- **VRMDebugRenderer.swift**: Visualization for bones, bounding boxes, normals

### ARKit/
ARKit integration for face and body tracking

- **ARKitTypes.swift**: ARKit data structures (face blend shapes, body skeleton, metadata sources)
- **ARKitMapper.swift**: Mapping ARKit shapes/joints to VRM expressions/bones (configurable formulas and presets)
- **SmoothingFilters.swift**: EMA, Kalman, and windowed-average filters for reducing jitter
- **ARKitFaceDriver.swift**: Primary API for driving VRM expressions from ARKit face tracking
- **ARKitBodyDriver.swift**: Primary API for driving VRM skeleton from ARKit body tracking

See [ARKitIntegration.md](ARKitIntegration.md) for detailed ARKit documentation.

---

## Key Design Patterns

### Triple-Buffered Uniforms
Renderer maintains 3 frames of uniform buffers to eliminate CPU-GPU sync stalls. Index cycles 0→1→2→0 each frame.

```swift
// VRMRenderer.swift
currentUniformBufferIndex = (currentUniformBufferIndex + 1) % maxBufferedFrames
let uniformsBuffer = uniformsBuffers[currentUniformBufferIndex]
```

### Dual Pipeline Architecture
Separate pipeline states for skinned vs non-skinned geometry, avoiding branch overhead in shaders. Alpha modes (opaque/blend) use different pipeline states.

**Benefits:**
- No dynamic branching in vertex shaders
- Optimized vertex layouts per pipeline
- Separate PSO compilation for faster switches

### GPU Compute for Morphs
When 8+ morph targets are active, switches from CPU blending to GPU compute shaders for efficiency.

**Threshold logic:**
```swift
if morphTargetCount >= 8 {
    useMorphCompute = true  // GPU compute shader
} else {
    useMorphCompute = false // CPU blending
}
```

### XPBD SpringBone Physics
Extended Position-Based Dynamics running at fixed 120Hz substeps for stability. All simulation happens in Metal compute shaders for parallelism.

**Physics loop:**
1. `SpringBoneKinematic.metal` - Update kinematic constraints
2. `SpringBonePredict.metal` - Predict positions with gravity/wind
3. `SpringBoneDistance.metal` - Solve distance constraints (XPBD)
4. `SpringBoneCollision.metal` - Resolve collisions
5. Integrate back into skeletal animation

### Strict Resource Index Contract
`StrictMode.swift` defines canonical buffer/texture indices (ResourceIndices) to prevent binding conflicts. Enforced in StrictMode validation.

```swift
public struct ResourceIndices {
    // Vertex shader buffer indices
    public static let vertexBuffer = 0
    public static let uniformsBuffer = 1
    public static let skinDataBuffer = 2
    // Fragment shader texture indices
    public static let baseColorTexture = 0
    public static let normalTexture = 1
    // ... etc
}
```

**Validation:**
- Compile-time constants prevent accidental conflicts
- StrictMode.fail enforces usage in development
- Runtime checks in StrictMode.warn for production debugging

### Conditional Logging
All debug logs wrapped in `#if VRM_METALKIT_ENABLE_LOGS` etc. Zero runtime cost when disabled.

```swift
#if VRM_METALKIT_ENABLE_LOGS
vrmLog("Loading VRM model from \(url)")
#endif
```

**Debug flags:**
- `VRM_METALKIT_ENABLE_LOGS` - General logging
- `VRM_METALKIT_ENABLE_DEBUG_ANIMATION` - Animation retargeting details
- `VRM_METALKIT_ENABLE_DEBUG_PHYSICS` - SpringBone simulation
- `VRM_METALKIT_ENABLE_DEBUG_LOADER` - VRMA file parsing

### Error Context Design
All errors implement `LocalizedError` with LLM-friendly messages including file paths, indices, available options, suggestions, and VRM spec links.

```swift
❌ Missing Required Humanoid Bone: 'hips'

The VRM model in file '/path/to/model.vrm' is missing the required humanoid bone 'hips'.
Available bones: spine, chest, head, leftUpperArm, rightUpperArm

Suggestion: Ensure your 3D model has a bone for 'hips' and that it's properly mapped
in the VRM humanoid configuration.

VRM Spec: https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm-1.0/humanoid.md
```

---

## Critical Data Flows

### 1. Model Loading Flow
```
GLTFParser (binary parsing)
    ↓
BufferLoader (vertex/index data) + TextureLoader (images)
    ↓
VRMExtensionParser (VRMC_vrm, VRMC_springBone, etc.)
    ↓
VRMModel (complete model in memory)
```

### 2. Rendering Flow
```
VRMRenderer.render(view:)
    ↓
Update uniforms (camera, lights)
    ↓
VRMRenderer+Pipeline (select PSO based on material/skinning)
    ↓
MToonShader/SkinnedShader (vertex + fragment shaders)
    ↓
GPU rasterization
```

### 3. Animation Flow
```
VRMAnimationLoader (load .vrma file)
    ↓
AnimationPlayer (playback control)
    ↓
VRMSkinning (joint matrices) + VRMMorphTargets (blend shapes)
    ↓
VRMModel.nodes (update world transforms)
    ↓
Renderer uses updated transforms
```

### 4. Physics Flow
```
SpringBoneComputeSystem.update(deltaTime:)
    ↓
Compute shaders (Kinematic → Predict → Distance → Collision)
    ↓
SpringBoneBuffers (GPU state)
    ↓
SpringBoneSkinningSystem (integrate into joint matrices)
    ↓
Final joint matrices used for rendering
```

### 5. ARKit Face Tracking Flow
```
ARKitFaceBlendShapes (52 blend shapes from device)
    ↓
ARKitFaceDriver.update()
    ↓
ARKitToVRMMapper (configurable formulas)
    ↓
SmoothingFilters (EMA/Kalman/Windowed)
    ↓
VRMExpressionController (18 VRM expressions)
    ↓
Morph target weights updated
```

### 6. ARKit Body Tracking Flow
```
ARKitBodySkeleton (50+ joints, 4×4 matrices)
    ↓
ARKitBodyDriver.update()
    ↓
ARKitSkeletonMapper (joint mapping presets)
    ↓
SkeletonFilterManager (per-joint position/rotation smoothing)
    ↓
VRMNode (TRS updates)
    ↓
updateWorldTransform() (propagate to hierarchy)
```

---

## Performance Expectations

On Apple Silicon (M1/M2/M3):
- **60 FPS** for complex models (15K+ triangles, 8+ morphs, SpringBone physics)
- **120 FPS** for simple models (5K triangles, basic animation)
- **SpringBone**: 50-100 bones at 120Hz substeps with minimal overhead

Always profile with Instruments (Metal System Trace) for GPU bottlenecks.

### Performance Optimization Strategies

1. **Enable performance tracking:**
   ```swift
   renderer.performanceTracker = PerformanceTracker()
   let metrics = renderer.getPerformanceMetrics()
   ```

2. **Profile GPU vs CPU bottlenecks** using Instruments

3. **Consider optimization points:**
   - Morph compute threshold (8+ targets)
   - State change batching
   - Draw call count reduction
   - Texture atlas usage for 2D mode

---

## 2.5D Rendering Mode

VRMRenderer supports two rendering modes:
- `.standard` - Traditional 3D MToon rendering
- `.toon2D` - 2.5D cel-shaded with outlines, orthographic projection

```swift
renderer.renderingMode = .toon2D
renderer.orthoSize = 1.7  // Camera height in world units
renderer.toonBands = 3    // Number of cel-shading bands (1-5)
renderer.outlineWidth = 0.02
```

Implemented via `Toon2DShader.swift` and `CharacterPrioritySystem.swift` for layer sorting.

---

## Licensing

**Source Code**: Apache License 2.0 (all `.swift`, `.metal` files)
**VRM Models**: VRM Platform License 1.0 (model-specific, check metadata)

All new source files must include Apache 2.0 header (verified in PR checks).
