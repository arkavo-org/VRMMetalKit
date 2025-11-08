# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

VRMMetalKit is a high-performance Swift Package for loading and rendering VRM 1.0 avatars using Apple's Metal framework. Supports macOS 14+ and iOS 17+, built with Swift 6.2.

## Build & Test Commands

### Basic Operations
```bash
# Build the package
swift build

# Run all tests
swift test

# Run a specific test
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

### Check for Warnings
```bash
swift build --build-tests 2>&1 | tee build.log && ! grep -i "warning:" build.log
```

## Architecture

### Module Structure

The codebase is organized into logical subsystems:

**Core/** - Foundational types and model representation
- `VRMModel.swift`: Central model class holding all VRM/glTF data, nodes, meshes, materials
- `VRMTypes.swift`: VRM specification types (VRMHumanoid, VRMMeta, VRMExpressions, etc.)
- `StrictMode.swift`: Three-level validation system (.off, .warn, .fail) with ResourceIndices contract
- `VRMLogger.swift`: Conditional compilation logging (zero overhead in production)

**Loader/** - Parsing and asset loading
- `GLTFParser.swift`: Main glTF/GLB binary parsing
- `VRMExtensionParser.swift`: VRM extension extraction (VRMC_vrm, VRMC_springBone, VRMC_node_constraint)
- `BufferLoader.swift`: Binary buffer data loading and accessor handling
- `TextureLoader.swift`: Image loading and Metal texture creation

**Renderer/** - GPU rendering pipeline
- `VRMRenderer.swift`: Main renderer with triple-buffered uniforms, dual pipeline states (skinned/non-skinned)
- `VRMRenderer+Pipeline.swift`: Pipeline state creation for different alpha modes (opaque, blend, wireframe)
- `VRMGeometry.swift`: Mesh and primitive data structures
- `CharacterPrioritySystem.swift`: Z-sorting for layered rendering
- `SpriteCacheSystem.swift`: Texture atlas caching for 2D mode

**Shaders/** - GPU shader implementations
- `MToonShader.swift`: MToon shader (VRM standard NPR shader) with matcap, rim lighting, outlines
- `SkinnedShader.swift`: Skeletal animation vertex shader
- `Toon2DShader.swift` / `Toon2DSkinnedShader.swift`: 2.5D cel-shaded rendering mode
- `SpriteShader.swift`: 2D sprite rendering for UI/avatars
- `MorphTargetCompute.metal`: GPU compute for blend shape morphs (8+ targets)
- `SpringBone*.metal`: Physics compute shaders (Predict, Distance, Collision, Kinematic)
- `DebugShaders.metal`: Wireframe and debug visualization

**Animation/** - Animation and deformation systems
- `AnimationPlayer.swift`: Playback controller with looping, speed control, root motion
- `VRMAnimationLoader.swift`: VRMA file loading with intelligent humanoid bone retargeting
- `VRMSkinning.swift`: Skeletal animation with up to 256 joints
- `VRMMorphTargets.swift`: Blend shape system with GPU acceleration
- `VRMLookAtController.swift`: Eye/head tracking system
- `AnimationLibrary.swift`: Animation clip management

**SpringBone Physics** - GPU-accelerated physics simulation
- `SpringBoneComputeSystem.swift`: Main XPBD physics loop at fixed 120Hz substeps
- `SpringBoneSkinningSystem.swift`: Integration with skeletal animation
- `SpringBoneBuffers.swift`: GPU buffer management for physics state
- `SpringBoneDebug.swift`: Visualization and debugging utilities
- Compute shaders: `SpringBoneKinematic.metal`, `SpringBonePredict.metal`, `SpringBoneDistance.metal`

**Builder/** - Programmatic model creation
- `VRMBuilder.swift`: Fluent API for creating VRM models from code
- `CharacterRecipe.swift`: Character templates and presets
- `GLTFDocumentBuilder.swift`: Low-level glTF construction
- `VRMModel+Serialization.swift`: Binary .vrm export

**Performance/** - Metrics and profiling
- `PerformanceMetrics.swift`: Frame time tracking (avg, p50, p95, p99), GPU time, draw calls, triangles, state changes

**Debug/**
- `VRMDebugRenderer.swift`: Visualization for bones, bounding boxes, normals

**ARKit/** - ARKit integration for face and body tracking (Phase 2 & 3 complete)
- `ARKitTypes.swift`: ARKit data structures (face blend shapes, body skeleton, metadata sources)
- `ARKitMapper.swift`: Mapping ARKit shapes/joints to VRM expressions/bones (configurable formulas and presets)
- `SmoothingFilters.swift`: EMA, Kalman, and windowed-average filters for reducing jitter
- `ARKitFaceDriver.swift`: Primary API for driving VRM expressions from ARKit face tracking
- `ARKitBodyDriver.swift`: Primary API for driving VRM skeleton from ARKit body tracking (NEW in Phase 3)

### Key Design Patterns

**Triple-Buffered Uniforms**: Renderer maintains 3 frames of uniform buffers to eliminate CPU-GPU sync stalls. Index cycles 0→1→2→0 each frame.

**Dual Pipeline Architecture**: Separate pipeline states for skinned vs non-skinned geometry, avoiding branch overhead in shaders. Alpha modes (opaque/blend) use different pipeline states.

**GPU Compute for Morphs**: When 8+ morph targets are active, switches from CPU blending to GPU compute shaders for efficiency.

**XPBD SpringBone Physics**: Extended Position-Based Dynamics running at fixed 120Hz substeps for stability. All simulation happens in Metal compute shaders for parallelism.

**Strict Resource Index Contract**: `StrictMode.swift` defines canonical buffer/texture indices (ResourceIndices) to prevent binding conflicts. Enforced in StrictMode validation.

**Conditional Logging**: All debug logs wrapped in `#if VRM_METALKIT_ENABLE_LOGS` etc. Zero runtime cost when disabled.

**Error Context Design**: All errors implement `LocalizedError` with LLM-friendly messages including file paths, indices, available options, suggestions, and VRM spec links.

### Critical File Interactions

1. **Model Loading Flow**: `GLTFParser` → `BufferLoader` + `TextureLoader` → `VRMExtensionParser` → `VRMModel`
2. **Rendering Flow**: `VRMRenderer` → `VRMRenderer+Pipeline` (PSO setup) → `MToonShader`/`SkinnedShader` → GPU
3. **Animation Flow**: `VRMAnimationLoader` → `AnimationPlayer` → `VRMSkinning` + `VRMMorphTargets` → `VRMModel.nodes` (updates world matrices)
4. **Physics Flow**: `SpringBoneComputeSystem` → compute shaders → `SpringBoneBuffers` → `SpringBoneSkinningSystem` → final joint matrices
5. **ARKit Face Tracking Flow**: `ARKitFaceBlendShapes` → `ARKitFaceDriver` → `ARKitToVRMMapper` + `SmoothingFilters` → `VRMExpressionController`
6. **ARKit Body Tracking Flow**: `ARKitBodySkeleton` → `ARKitBodyDriver` → `ARKitSkeletonMapper` + `SkeletonFilterManager` → `VRMNode` (TRS updates) → `updateWorldTransform()`

## ARKit Integration (Continuity Camera Support)

VRMMetalKit includes comprehensive ARKit integration for driving VRM avatars from iPhone/iPad face and body tracking via Continuity Camera, Wi-Fi, or NFC. Designed for ArkavoCreator multi-camera scenarios.

### Face Tracking (Phase 2 - Complete)

**Quick Start:**
```swift
// Initialize face driver
let faceDriver = ARKitFaceDriver(
    mapper: .default,        // Maps 52 ARKit shapes → 18 VRM expressions
    smoothing: .default      // EMA filtering for jitter reduction
)

// On receiving ARKit face data from CameraMetadataEvent
func onFaceTracking(_ blendShapes: ARKitFaceBlendShapes) {
    faceDriver.update(
        blendShapes: blendShapes,
        controller: vrmModel.expressionController
    )
}
```

**Key Components:**
- **ARKitFaceBlendShapes**: Container for all 52 ARKit blend shapes with timestamp and staleness detection
- **ARKitToVRMMapper**: Configurable formulas for mapping ARKit → VRM expressions
  - Presets: `.default`, `.simplified`, `.aggressive`
  - Formula types: `.direct`, `.average`, `.weighted`, `.max`, `.min`, `.custom`
  - Covers all 18 VRM expressions: emotions (happy/angry/sad/relaxed/surprised), visemes (aa/ih/ou/ee/oh), blink, gaze
- **SmoothingFilters**: Three filter types with per-expression configuration
  - EMA: ~3-5 CPU cycles, O(1) memory, alpha parameter for responsiveness/stability tradeoff
  - Kalman: ~15-20 cycles, optimal linear estimation with process/measurement noise tuning
  - WindowedAverage: Simple moving average over N frames
  - Presets: `.default`, `.lowLatency`, `.smooth`, `.kalman`, `.none`
- **ARKitFaceDriver**: Primary API with multi-source support and priority strategies
  - Source priorities: `.latestActive`, `.primary(id, fallback)`, `.weighted`, `.highestConfidence`
  - Automatic staleness detection (default 150ms threshold)
  - Statistics tracking (update count, skip rate, timing)

**Performance:**
- End-to-end latency: <2ms per frame (52 blend shapes → 18 expressions)
- Memory footprint: <5 KB for driver state and filters
- Throughput: Validated at 60 FPS and 120 FPS

### Body Tracking (Phase 3 - Complete)

**Quick Start:**
```swift
// Initialize body driver
let bodyDriver = ARKitBodyDriver(
    mapper: .default,        // Maps ARKit joints → VRM humanoid bones
    smoothing: .default,     // Separate position/rotation smoothing
    priority: .latestActive
)

// On receiving ARKit body skeleton
func onBodyTracking(_ skeleton: ARKitBodySkeleton) {
    bodyDriver.update(
        skeleton: skeleton,
        nodes: vrmModel.nodes,
        humanoid: vrmModel.vrm?.humanoid
    )
}
```

**Key Components:**
- **ARKitBodySkeleton**: Full skeleton (50+ joints) with 4×4 transform matrices
  - Codable for recording/playback
  - Staleness detection and confidence tracking
  - Subset extraction for partial skeleton support
- **ARKitSkeletonMapper**: Joint mapping with presets
  - `.default`: Full skeleton (torso, arms, legs, fingers)
  - `.upperBodyOnly`: Desk/seated scenarios
  - `.coreOnly`: Minimal tracking for performance
- **SkeletonFilterManager**: Per-joint smoothing
  - Position smoothing: EMA/Kalman/Windowed per-axis
  - Rotation smoothing: Currently per-component (TODO: SLERP for better quaternion interpolation)
  - Scale smoothing: Available but typically unused
- **ARKitBodyDriver**: Primary API with transform decomposition
  - Retargets ARKit 4×4 matrices to VRM TRS (translation/rotation/scale)
  - Multi-source support with same priority strategies as face tracking
  - Robust matrix decomposition using Gram-Schmidt orthogonalization
  - Automatic world transform propagation

**Performance:**
- Single-source update: ~50-100µs for full skeleton (50 joints)
- Transform decomposition: ~2µs per joint
- Smoothing overhead: ~0.5µs per joint (EMA), ~1µs (Kalman)
- Memory: <10 KB for filters and state

### Multi-Source & QoS

**Multi-Camera Example:**
```swift
// Face driver with primary/fallback strategy
let faceDriver = ARKitFaceDriver(
    mapper: .default,
    smoothing: .default,
    priority: .primary("iPhone15Pro", fallback: "iPad")
)

// Update from multiple sources
faceDriver.updateMulti(
    sources: [
        "iPhone15Pro": iphoneFaceData,
        "iPad": iPadFaceData
    ],
    controller: expressionController
)

// Body driver with latest-active strategy
let bodyDriver = ARKitBodyDriver(
    mapper: .upperBodyOnly,  // Desk scenario
    smoothing: .default,
    priority: .latestActive
)

bodyDriver.updateMulti(
    skeletons: [
        "FrontCamera": frontSkeletonData,
        "SideCamera": sideSkeletonData
    ],
    nodes: vrmModel.nodes,
    humanoid: vrmModel.vrm?.humanoid
)
```

**Priority Strategies:**
- `.latestActive`: Use most recent timestamp (good for automatic switching)
- `.primary(id, fallback)`: Prefer specific source with backup
- `.weighted([id: weight])`: Blend multiple sources (placeholder, deferred to Phase 4)
- `.highestConfidence`: Use source with best tracking quality

**Staleness Detection:**
- Configurable threshold (default 150ms)
- Automatic skip when data is stale to avoid avatar popping
- Per-source tracking of last update time

### Data Structures & Transport

**ARMetadataSource Protocol:**
```swift
protocol ARMetadataSource: Sendable {
    var sourceID: UUID { get }
    var name: String { get }           // "iPhone 15 Pro", "iPad Side Camera"
    var lastUpdate: TimeInterval { get }
    var isActive: Bool { get }         // !stale
    var metadata: [String: String] { get } // Device model, connection type, etc.
}
```

**Concrete Sources:**
- `ARFaceSource`: Face-only tracking
- `ARBodySource`: Body-only tracking
- `ARCombinedSource`: Face + body from same device

**Recording & Playback:**
All ARKit types are `Codable` for test harness and debugging:
```swift
// Record session
let faceData: [ARKitFaceBlendShapes] = recordingSession.faceFrames
let bodyData: [ARKitBodySkeleton] = recordingSession.bodyFrames
try JSONEncoder().encode(faceData).write(to: faceRecordingURL)

// Playback in tests
let recorded = try JSONDecoder().decode([ARKitFaceBlendShapes].self, from: data)
for frame in recorded {
    faceDriver.update(blendShapes: frame, controller: controller)
}
```

### Customization & Tuning

**Custom Expression Mappings:**
```swift
var mapper = ARKitToVRMMapper.default
// Override happy expression to be more subtle
mapper.mappings["happy"] = .weighted([
    (ARKitFaceBlendShapes.mouthSmileLeft, Float(0.3)),   // Reduced from 0.4
    (ARKitFaceBlendShapes.mouthSmileRight, Float(0.3)),
    (ARKitFaceBlendShapes.cheekSquintLeft, Float(0.05)), // Reduced from 0.1
    (ARKitFaceBlendShapes.cheekSquintRight, Float(0.05))
])

// Add custom expression with closure
mapper.mappings["wink"] = .custom { shapes in
    let leftBlink = shapes.weight(for: ARKitFaceBlendShapes.eyeBlinkLeft)
    let rightBlink = shapes.weight(for: ARKitFaceBlendShapes.eyeBlinkRight)
    // Wink = one eye closed, other open
    return max(leftBlink * (1 - rightBlink), rightBlink * (1 - leftBlink))
}
```

**Custom Smoothing:**
```swift
var config = SmoothingConfig.default
// No smoothing for blinks (instant response)
config.perExpression["blink"] = .none
config.perExpression["blinkLeft"] = .none
config.perExpression["blinkRight"] = .none

// Heavy smoothing for mouth (reduce speech jitter)
config.perExpression["aa"] = .ema(alpha: 0.2)  // 0.2 = more smoothing
config.perExpression["ih"] = .ema(alpha: 0.2)

let faceDriver = ARKitFaceDriver(mapper: .default, smoothing: config)
```

**Custom Skeleton Mapping:**
```swift
// Map only upper body for seated avatar
var mapper = ARKitSkeletonMapper.upperBodyOnly
// Add custom finger mapping
mapper.jointMap[.leftHandThumb1] = "leftThumbProximal"
mapper.jointMap[.leftHandIndex1] = "leftIndexProximal"

let bodyDriver = ARKitBodyDriver(mapper: mapper, smoothing: .default)
```

### Testing & Debugging

**Unit Test Structure:**
```bash
Tests/VRMMetalKitTests/ARKit/
├── ARKitTypesTests.swift          # Serialization, staleness, subsets
├── ARKitMapperTests.swift         # Formula evaluation, all presets
├── SmoothingFiltersTests.swift    # EMA, Kalman, Windowed with known inputs
├── ARKitFaceDriverTests.swift     # Single/multi-source, priorities
└── ARKitBodyDriverTests.swift     # Skeleton retargeting, transform decomposition
```

**Sample Test Data:**
Create test recordings in `Tests/VRMMetalKitTests/TestData/ARKit/`:
- `face_neutral_60fps.json`: Neutral face for 5 seconds
- `face_expressions_sequence.json`: Cycle through all emotions
- `body_walk_cycle.json`: Walking animation skeleton data
- `body_seated_typing.json`: Upper body desk scenario

**Statistics & Profiling:**
```swift
// Get performance stats
let faceStats = faceDriver.getStatistics()
print("Face updates: \(faceStats.updateCount), skip rate: \(faceStats.skipRate)")

let bodyStats = bodyDriver.getStatistics()
print("Body updates: \(bodyStats.updateCount), latency: \(bodyStats.lastUpdateTime)")

// Reset for clean profiling
faceDriver.resetStatistics()
bodyDriver.resetStatistics()
```

### Remaining Work (Future Phases)

**Phase 4: QoS & Advanced Features** (deferred)
- `QoSController`: Timestamp interpolation for jitter handling
- `ARMetadataSourceManager`: Centralized multi-source management
- Weighted blending of skeleton transforms (complex, needs quaternion SLERP)
- Adaptive staleness thresholds based on connection quality
- Proper SLERP-based rotation smoothing (marked TODO in `SkeletonFilterManager.updateRotation`)

**Phase 5: Comprehensive Testing** (in progress)
- Full unit test suite for all ARKit components (planned)
- Integration tests with real VRM models
- Performance regression tests
- Sample test recordings

**Phase 6: Documentation** (in progress)
- ArkavoCreator integration guide
- Multi-camera setup patterns
- Performance tuning recommendations

### Implementation Status

✅ **Complete:**
- ARKit data types and metadata sources
- Face tracking with mapping, smoothing, and multi-source support
- Body tracking with skeleton retargeting and transform decomposition
- Multi-source priority strategies
- Codable support for recording/playback
- Thread-safe APIs with statistics tracking

🔄 **In Progress:**
- Comprehensive test suite
- SLERP quaternion smoothing
- Full documentation and examples

⏸️ **Deferred:**
- QoS controller with timestamp interpolation
- Weighted skeleton blending
- Adaptive thresholds

## StrictMode Validation System

VRMMetalKit includes a three-level validation system to catch rendering bugs early:

### Levels
- `.off` (default): Soft fallbacks, logs only
- `.warn`: Log all violations, mark frame invalid, continue rendering
- `.fail`: Throw/abort on first violation (recommended for CI)

### Usage
```swift
// Development: catch issues early
let config = RendererConfig(strict: .fail)
let renderer = VRMRenderer(device: device, config: config)

// Production: log but continue
let config = RendererConfig(strict: .warn)
```

### What It Validates
- Pipeline state creation (vertex/fragment functions, PSO compilation)
- Uniform struct size matching between Swift and Metal
- Buffer/texture index conflicts (validates against ResourceIndices)
- Draw call sanity (zero vertices/indices, index bounds)
- Frame validation (all-white detection, minimum draw calls)

See `STRICT_MODE.md` for complete documentation.

## Conditional Debug Logging

Debug logs are compiled out in production builds:

- `VRM_METALKIT_ENABLE_LOGS`: General logging
- `VRM_METALKIT_ENABLE_DEBUG_ANIMATION`: Animation retargeting details
- `VRM_METALKIT_ENABLE_DEBUG_PHYSICS`: SpringBone simulation
- `VRM_METALKIT_ENABLE_DEBUG_LOADER`: VRMA file parsing

Always omit these flags for release builds to ensure zero overhead.

## Dual Licensing Structure

**Source Code**: Apache License 2.0 (all `.swift`, `.metal` files)
**VRM Models**: VRM Platform License 1.0 (model-specific, check metadata)

All new source files must include Apache 2.0 header (verified in PR checks).

## Testing Patterns

### Test Data Location
Test models and assets live in `Tests/VRMMetalKitTests/TestData/`

### Test Categories
- `VRMMetalKitTests.swift`: Basic smoke tests
- `ExpressionTests.swift`: VRMExpressions and morph targets
- `VRMCreatorSimpleTests.swift`: VRMBuilder API tests
- `Toon2DMaterialLayoutTests.swift`: 2.5D rendering mode

### Writing Tests
```swift
import XCTest
@testable import VRMMetalKit

final class MyTests: XCTestCase {
    func testFeature() throws {
        let device = MTLCreateSystemDefaultDevice()!
        // Test implementation
    }
}
```

## Metal Shader Development

### Shader Compilation
Metal shaders are excluded from SPM compilation (see `Package.swift` exclude list) and must be pre-compiled to `.metallib`:

```bash
# Compile individual shader
xcrun -sdk macosx metal -c SpringBonePredict.metal -o SpringBonePredict.air

# Link to metallib
xcrun -sdk macosx metallib SpringBone*.air -o VRMMetalKitShaders.metallib
```

The compiled `.metallib` goes in `Sources/VRMMetalKit/Resources/`.

### Shader Loading Pattern
```swift
// 1. Try default library (if shaders compiled into app)
var library = device.makeDefaultLibrary()

// 2. Fallback to package .metallib
if library == nil {
    let url = Bundle.module.url(forResource: "VRMMetalKitShaders", withExtension: "metallib")!
    library = try device.makeLibrary(URL: url)
}

let function = library.makeFunction(name: "mtoon_vertex")!
```

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

## Common Development Workflows

### Adding a New VRM Extension
1. Define types in `Core/VRMTypes.swift`
2. Add parsing logic to `Loader/VRMExtensionParser.swift`
3. Store in `VRMModel` (Core/VRMModel.swift)
4. Update error messages with spec links

### Adding a New Shader Feature
1. Implement shader code in `Shaders/` (`.swift` for Swift, `.metal` for GPU)
2. Add to exclude list in `Package.swift` if `.metal`
3. Compile to `.metallib` and add to Resources
4. Update pipeline creation in `VRMRenderer+Pipeline.swift`
5. Add validation to StrictMode if needed

### Adding a New Animation Feature
1. Define data structures in `Animation/` module
2. Add VRMA parsing to `VRMAnimationLoader.swift`
3. Integrate with `AnimationPlayer.swift`
4. Test with debug flag: `swift build -Xswiftc -DVRM_METALKIT_ENABLE_DEBUG_ANIMATION`

### Performance Optimization
1. Enable performance tracking: `renderer.performanceTracker = PerformanceTracker()`
2. Check metrics: `renderer.getPerformanceMetrics()`
3. Profile GPU vs CPU bottlenecks
4. Consider: morph compute threshold, state change batching, draw call count

## CI/CD Pipeline

GitHub Actions workflows in `.github/workflows/`:

**build.yaml** - Linux builds (Swift 6.2 container)
```bash
swift build -v
swift test -v
# Check for warnings
```

**pr-checks.yaml** - PR validation
- Merge conflict detection
- File permissions check
- Apache License header verification
- Build and test

**release.yaml** - Release automation
- Version tagging
- Changelog generation
- GitHub release creation

## Performance Expectations

On Apple Silicon (M1/M2/M3):
- 60 FPS for complex models (15K+ triangles, 8+ morphs, SpringBone physics)
- 120 FPS for simple models (5K triangles, basic animation)
- SpringBone: 50-100 bones at 120Hz substeps with minimal overhead

Always profile with Instruments (Metal System Trace) for GPU bottlenecks.

## Error Message Philosophy

All errors are designed for LLM parsing in the "Game of Mods" character creator:

```swift
❌ Missing Required Humanoid Bone: 'hips'

The VRM model in file '/path/to/model.vrm' is missing the required humanoid bone 'hips'.
Available bones: spine, chest, head, leftUpperArm, rightUpperArm

Suggestion: Ensure your 3D model has a bone for 'hips' and that it's properly mapped
in the VRM humanoid configuration.

VRM Spec: https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm-1.0/humanoid.md
```

When adding errors, include: what went wrong, where (indices/paths), why, how to fix, and spec links.

## 2.5D Rendering Mode

VRMRenderer supports two rendering modes:
- `.standard`: Traditional 3D MToon rendering
- `.toon2D`: 2.5D cel-shaded with outlines, orthographic projection

Configure with:
```swift
renderer.renderingMode = .toon2D
renderer.orthoSize = 1.7  // Camera height in world units
renderer.toonBands = 3    // Number of cel-shading bands (1-5)
renderer.outlineWidth = 0.02
```

Implemented via `Toon2DShader.swift` and `CharacterPrioritySystem.swift` for layer sorting.
- after selecting a GitHub issue, create a branch.  After fixes, check format, git commit and push.  Create a PR that references the GitHub issue