# VRMMetalKit Performance Optimization Guide

This guide explains how to use the performance optimizations in VRMMetalKit to achieve sub-2-second loading for 20MB VRM files.

## Quick Start

### Maximum Performance (Recommended)

```swift
import VRMMetalKit

// Load with all optimizations enabled
let options = VRMLoadingOptions(optimizations: .maximumPerformance)

let model = try await VRMModel.load(
    from: modelURL,
    device: metalDevice,
    options: options
)
```

### With Progress Tracking

```swift
let options = VRMLoadingOptions(
    progressCallback: { progress in
        print("Loading: \(progress.percentage)% - \(progress.currentPhase.rawValue)")
        print("  Items: \(progress.itemsCompleted)/\(progress.totalItems)")
        print("  Elapsed: \(progress.elapsedTime)s")
        if let remaining = progress.estimatedTimeRemaining {
            print("  ETA: \(remaining)s")
        }
    },
    progressUpdateInterval: 0.1,  // Update every 100ms
    optimizations: .maximumPerformance
)

let model = try await VRMModel.load(from: modelURL, options: options)
```

## Optimization Levels

### 1. `.default` - Basic Optimizations
```swift
let options = VRMLoadingOptions.default
// Includes: .skipVerboseLogging, .parallelTextureDecoding
```
**Best for**: Development, debugging, small models (<5MB)

### 2. `.maximumPerformance` - All Optimizations
```swift
let options = VRMLoadingOptions(optimizations: .maximumPerformance)
// Includes all available optimizations
```
**Best for**: Production, large models (>10MB), VR/AR applications

### 3. Custom Optimization Mix
```swift
let options = VRMLoadingOptions(
    optimizations: [
        .skipVerboseLogging,
        .parallelTextureLoading,
        .parallelMeshLoading,
        .preloadBuffers
    ]
)
```
**Best for**: Fine-tuning for specific model types

## Individual Optimizations

### `.skipVerboseLogging`
- **Impact**: 5-10% faster (due to reduced I/O)
- **Use when**: You don't need detailed loading logs
- **Note**: Errors are still logged

### `.parallelTextureLoading`
- **Impact**: 3-4x faster texture loading
- **Use when**: Model has 2+ textures
- **Note**: Automatically disabled for single textures

### `.parallelMeshLoading`
- **Impact**: 2-4x faster mesh loading
- **Use when**: Model has 2+ meshes
- **Note**: Automatically disabled for single meshes. Primitive decodes are
  capped by a global limiter sized to `activeProcessorCount` on *every* load,
  parallel or serial, so peak decode memory stays bounded regardless of mesh
  count; this flag only controls whether meshes themselves load concurrently.

### `.parallelMaterialLoading`
- **Impact**: Faster material conversion on multi-material models
- **Use when**: Model has 2+ materials
- **Note**: Automatically disabled for single materials

### `.preloadBuffers`
- **Impact**: Smoother loading, reduced I/O wait
- **Use when**: Loading from disk (not memory)
- **Note**: Adds a small upfront cost for large benefit

### `.skipSecondaryUVs`
- **Status**: Reserved, currently no effect. The mesh loader only reads
  `TEXCOORD_0`, so there is no secondary-UV cost to skip yet.
- **Warning**: Do not rely on this flag until it is wired up.

### `.parallelTextureDecoding`
- **Status**: Reserved, currently no effect. Included in `.default` for
  forward compatibility; texture decoding parallelism today comes from
  `.parallelTextureLoading`.

### `.lazyTextureLoading`
- **Status**: Reserved, currently no effect. All referenced textures load
  eagerly; there is no on-demand path yet.

### `.aggressiveTextureCompression`
- **Impact**: ~4× less GPU texture bandwidth (BC7 at 8 bpp vs RGBA8). Load CPU goes up.
- **Use when**: GPU texture cache is the limiter (crowd, 1024², battery).
- **Warning**: Pixel-near, not bit-identical. Color textures only; mean AE ≤ 3/255. Linear maps stay RGBA8. No-ops if the device cannot sample BC.

## Performance by Model Type

### Small Models (< 5MB, 1-2 textures, 1-2 meshes)
```swift
let options = VRMLoadingOptions(
    optimizations: .default
)
// Expected: 200-500ms
```

### Medium Models (5-15MB, 3-5 textures, 3-5 meshes)
```swift
let options = VRMLoadingOptions(
    optimizations: [
        .skipVerboseLogging,
        .parallelTextureLoading,
        .parallelMeshLoading
    ]
)
// Expected: 500ms-1.5s
```

### Large Models (> 15MB, 5+ textures, 5+ meshes)
```swift
let options = VRMLoadingOptions(
    optimizations: .maximumPerformance
)
// Expected: 1-2.5s (vs 3-5s without optimizations)
```

## Cancellation Support

All loading operations support Task cancellation:

```swift
let task = Task {
    let options = VRMLoadingOptions(
        progressCallback: { progress in
            print("\(progress.percentage)%")
        }
    )
    
    do {
        let model = try await VRMModel.load(from: url, options: options)
        // Use model...
    } catch {
        // Cancellation surfaces as either error: the loader's own checkpoints
        // throw `GLTFError.loadingCancelled`, while a cancel that lands inside
        // a primitive decode propagates Swift's `CancellationError` out of the
        // decode task group.
        if error is CancellationError {
            print("Loading was cancelled")
        } else if case GLTFError.loadingCancelled = error {
            print("Loading was cancelled")
        }
    }
}

// Cancel after 5 seconds if not complete
DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
    task.cancel()
}
```

## Performance Monitoring

### Built-in Metrics

```swift
let startTime = CFAbsoluteTimeGetCurrent()

let model = try await VRMModel.load(from: url, options: options)

let loadTime = CFAbsoluteTimeGetCurrent() - startTime
print("Total load time: \(loadTime)s")
```

### Detailed Phase Timing

```swift
let options = VRMLoadingOptions(
    progressCallback: { progress in
        if progress.currentPhase == .complete {
            print("Total time: \(progress.elapsedTime)s")
        }
    }
)
```

## Best Practices

### 1. Use `.maximumPerformance` in Production
```swift
// App startup
let options = VRMLoadingOptions(
    optimizations: .maximumPerformance,
    progressCallback: { progress in
        // Update UI progress bar
        DispatchQueue.main.async {
            self.progressView.progress = Float(progress.overallProgress)
        }
    }
)
```

### 2. Enable Cancellation for User-Initiated Loads
```swift
func loadModel(url: URL) {
    // Cancel any existing load
    currentLoadTask?.cancel()
    
    // Start new load
    currentLoadTask = Task {
        let model = try await VRMModel.load(
            from: url,
            options: VRMLoadingOptions(
                enableCancellation: true,
                optimizations: .maximumPerformance
            )
        )
        // Display model...
    }
}
```

### 3. Preload for Predictable Access
```swift
// Preload all buffers at app start
let options = VRMLoadingOptions(
    optimizations: [.preloadBuffers, .skipVerboseLogging]
)

// Then load models quickly
for url in modelURLs {
    let model = try await VRMModel.load(from: url, options: options)
}
```

### 4. Adjust Progress Update Interval
```swift
// For smooth UI updates (10 FPS)
let options = VRMLoadingOptions(
    progressUpdateInterval: 0.1,  // 100ms
    optimizations: .maximumPerformance
)

// For minimal overhead
let options = VRMLoadingOptions(
    progressUpdateInterval: 0.5,  // 500ms
    optimizations: .maximumPerformance
)
```

## Troubleshooting

### Loading Still Slow?

1. **Check file format**: `.vrm.glb` is 3x faster than `.vrm`
2. **Texture count**: Models with 10+ textures benefit most from parallel loading
3. **Disk speed**: SSD vs HDD makes a big difference for `.preloadBuffers`
4. **Memory pressure**: Enable `.aggressiveTextureCompression` if memory is tight

### Crashes During Loading?

1. **Reduce concurrency**: Some devices struggle with high parallelism
2. **Disable preloading**: Try without `.preloadBuffers`
3. **Check model validity**: Ensure VRM file is not corrupted

### Progress Callbacks Not Firing?

1. **Check interval**: Ensure `progressUpdateInterval` > 0
2. **Main thread**: Callbacks run on MainActor - check UI updates
3. **Small models**: Fast loads may only trigger 1-2 callbacks

## Example: Complete Loading Implementation

```swift
import VRMMetalKit
import MetalKit

class ModelLoader: ObservableObject {
    @Published var progress: Double = 0
    @Published var currentPhase: String = ""
    @Published var isLoading: Bool = false
    
    private var loadTask: Task<VRMModel, Error>?
    
    func loadModel(from url: URL) async throws -> VRMModel {
        // Cancel existing load
        loadTask?.cancel()
        
        isLoading = true
        defer { isLoading = false }
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw VRMError.deviceNotSet(context: "ModelLoader")
        }
        
        let options = VRMLoadingOptions(
            progressCallback: { [weak self] progress in
                DispatchQueue.main.async {
                    self?.progress = progress.overallProgress
                    self?.currentPhase = progress.currentPhase.rawValue
                }
            },
            progressUpdateInterval: 0.05,  // 20 FPS updates
            enableCancellation: true,
            optimizations: .maximumPerformance
        )
        
        loadTask = Task {
            try await VRMModel.load(
                from: url,
                device: device,
                options: options
            )
        }
        
        return try await loadTask!.value
    }
    
    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }
}
```

## visionOS / CompositorServices

CompositorServices mixed immersion is the preferred *container* for a
visionOS avatar: layered or dedicated drawables, reverse-Z, stored depth,
transparent color clear (passthrough), no `waitUntilCompleted`. Enable
foveation (`isFoveationEnabled`, `maxRenderQuality = 1.0`) and bind the
drawable's rasterization rate map on every pass — a non-foveated
drawable smears thin line art. MSAA is host-owned: memoryless 4×
colour+depth resolving into the drawable with `depthResolveFilter =
.min` under reverse-Z; `RendererConfig.sampleCount = 4` only selects
the pipelines.

The preferred *submit* is `VRMRenderer.encodeCompositorViews` — one
simulation (morphs, SpringBone, skin palettes, inflight slot) and one
raster per eye. Calling `drawOffscreen` once per eye still works, but it
double-steps physics and burns two triple-buffer slots.

```swift
renderer.encodeCompositorViews(commandBuffer: commandBuffer, views: views)
drawable.encodePresent(commandBuffer: commandBuffer)
commandBuffer.commit()
```

Mac stand-in (does not replace `make bench-gate`):

```bash
make bench-visionos
# or
swift run -c release VRMBenchmark AvatarSample_U_1.0.vrm.glb \
  --mode visionos --visionos-submit preferred --vrma VRMA_01.vrma \
  --spring-bone --frames 200
```

`--visionos-submit host` is the older per-eye `drawOffscreen` path, kept
so the two can be compared on the same machine.

## Runtime (Frame-Rate) Optimizations

Loading flags only cover startup. These per-frame levers live in
`RendererConfig`, `VRMRenderer`, and the shared caches:

### Pipeline cache + on-disk archive
- Every pipeline state is built once via `VRMPipelineCache.shared` and
  keyed by shader pair, pixel format, sample count, and feature flags.
- First-launch compilation is the cold-start cost after loading. Opt in to
  the on-disk archive to persist it across launches (large win on mobile
  GPUs, negligible on desktop where the driver already caches):
```swift
var config = RendererConfig()
config.enablePipelineArchive = true  // default false; uses caches dir unless pipelineArchiveDirectory is set
let renderer = VRMRenderer(device: device, config: config)
```
- Limit: archive serialization is skipped on the simulator.

### MToon function constants (default on)
- `RendererConfig.enableMToonFunctionConstants` (default `true`) compiles
  per-material fragment variants that dead-strip unused texture samples and
  alpha-mode branches. Disabling forces a dynamic uniform-buffer fallback.
- Leave it on unless you are debugging shader variants; variant count grows
  with distinct material feature sets.

### Frustum culling (always on)
- The renderer builds a per-frame frustum from the view-projection matrix
  and trivial-rejects whole primitives (including MToon outline hulls) by
  world-space AABB. Culled draws are counted in
  `PerformanceTracker` as `culledDraws`, not `drawCalls`.
- Skinned primitives cull against a rest-pose AABB inflated by a fixed 50%
  (a quarter-extent margin per side, to absorb pose variance) and translated
  by hips displacement, so fast locomotion does not pop in and out at screen
  edges. The margin is constant: it does not grow with displacement.
- Whole-model early-out is also available before encoding:
  `model.isOutsideFrustum(_:modelMatrix:)`.

### Morph compute gating (always on)
- Morph accumulation runs on a GPU compute kernel capped at
  `VRMConstants.Rendering.maxActiveMorphs` (8) targets per dispatch;
  near-zero weights are filtered from the active set.
- `MorphComputeGate` fingerprints the expression weights each frame and
  reuses the resident morphed buffers when nothing changed, skipping the
  dispatch entirely. Static faces therefore cost no morph compute.

### SpringBone sleep gate (always on, async path)
- XPBD runs at a fixed 120 Hz substep cadence on a GPU compute kernel,
  capped at `maxSubstepsPerFrame` (10) per rendered frame.
- On the async (shared command-buffer) path, a chain that stays under
  `springBoneSleepThreshold` (default 1 mm/s) for
  `springBoneSleepDelayFrames` (default 5) sleeps and skips XPBD until root
  motion, collider motion, or a param change wakes it:
```swift
renderer.springBoneSleepThreshold = 0.004  // sleep sooner: 4 mm/s
renderer.springBoneSleepDelayFrames = 15   // but only after 15 settled frames
renderer.sleepingBoneCount  // performance readout; all-asleep skips the pipeline
```
- The `synchronousSpringBone` offline path never sleeps (deterministic).
  Set the threshold to `0` to keep every chain awake for A/B testing; no
  velocity is below zero, so nothing sleeps. The gate's own bookkeeping (the
  velocity snapshot, wake-mask scan, and flag upload) still runs.

### `skipPreDrawTransformUpdate`
- `drawCore` walks the node hierarchy once as a safety net before encoding.
  Hosts that already tick `AnimationPlayer.update` (which calls
  `model.updateNodeTransforms()`) every frame can opt out:
```swift
renderer.skipPreDrawTransformUpdate = true
```
- Saves one full hierarchy walk per instance per frame. The benchmark
  exposes this as `--skip-pre-draw`.

### Outlines
- `renderer.outlineWidth = 0` disables the entire inverted-hull outline pass,
  both the dedicated pass and the hull merged into the body draw (guarded per
  frame and per material via `outlineWidthMode` / `outlineWidthFactor`). Scale
  down rather than editing materials when profiling. The saving is mostly
  vertex-side: the hull re-skins every outlined vertex, while its fragments are
  front-culled and depth-tested against the already-drawn body, so only the
  silhouette rim shades.

### Crowd sprite cache
- `SpriteCacheSystem` pre-renders static or near-static poses to sprites
  (LRU-evicted by count and memory bytes) so background characters skip
  skinning, morphs, physics, and shading. Target use: 5+ characters at
  60 FPS via hybrid rendering with `CharacterPrioritySystem`.

### Depth prepass (experimental)
- `RendererConfig.enableDepthPrepass` (default `false`) renders a
  position-only prepass for early-Z rejection of occluded fragments in the
  main pass. It covers opaque, non-face geometry only: face materials are
  skipped by the prepass and keep their existing depth state in the main
  pass, so a face-heavy scene sees no early-Z benefit. Only a net win when
  opaque overdraw is high; measure with `make bench-gate` before enabling.

### Leave the quality divergences off unless wanted
- `dualQuaternionSkinning`, `alphaToCoverageForMASK`, `enableMaterialization`,
  and `synchronousSpringBone` each cost GPU/CPU or break reference parity
  (see `RendererConfig` docs). `synchronousSpringBone` adds one GPU/CPU sync
  per frame; fine for offline rendering, a fps hit at interactive rates.

### Measuring: `PerformanceTracker` + `VRMBenchmark`
```swift
renderer.performanceTracker = PerformanceTracker()
// ... run frames ...
let metrics = renderer.getPerformanceMetrics()  // fps, p50/p95/p99 frame time,
// sub-phases (morphSetup, springBone, renderItemBuild, commandEncode),
// drawCalls, culledDraws, sleepingBones, state changes, memory
```
- `make bench-gate` gates the build against `baselines/baseline.json`;
  `make bench-visionos` runs the stereo reverse-Z compositor bench
  (preferred vs host submit).

## Performance Targets

| Model Size | Textures | Meshes | Target Time | Required Optimizations |
|-----------|----------|--------|-------------|----------------------|
| < 5MB | 1-2 | 1-2 | < 500ms | `.default` |
| 5-10MB | 2-4 | 2-4 | < 1s | `.parallelTextureLoading` |
| 10-20MB | 4-8 | 4-8 | < 2s | `.maximumPerformance` |
| > 20MB | 8+ | 8+ | < 3s | `.maximumPerformance` + fast storage |

---

For more information, see the API documentation for `VRMLoadingOptions`, `VRMLoadingPhase`, and `VRMLoadingProgress`.
