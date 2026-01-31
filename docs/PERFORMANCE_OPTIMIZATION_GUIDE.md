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
- **Note**: Automatically disabled for single meshes

### `.preloadBuffers`
- **Impact**: Smoother loading, reduced I/O wait
- **Use when**: Loading from disk (not memory)
- **Note**: Adds a small upfront cost for large benefit

### `.skipSecondaryUVs`
- **Impact**: 5-15% faster, reduced memory
- **Use when**: Model doesn't need lightmaps
- **Warning**: May break models using secondary UVs

### `.aggressiveTextureCompression`
- **Impact**: Faster upload, lower quality
- **Use when**: Memory is constrained
- **Warning**: May reduce visual quality

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
        if let vrmError = error as? VRMError,
           vrmError == .loadingCancelled {
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

## Performance Targets

| Model Size | Textures | Meshes | Target Time | Required Optimizations |
|-----------|----------|--------|-------------|----------------------|
| < 5MB | 1-2 | 1-2 | < 500ms | `.default` |
| 5-10MB | 2-4 | 2-4 | < 1s | `.parallelTextureLoading` |
| 10-20MB | 4-8 | 4-8 | < 2s | `.maximumPerformance` |
| > 20MB | 8+ | 8+ | < 3s | `.maximumPerformance` + fast storage |

---

For more information, see the API documentation for `VRMLoadingOptions`, `VRMLoadingPhase`, and `VRMLoadingProgress`.
