# ARKit Integration Guide for ArkavoCreator

This guide walks you through integrating VRMMetalKit's ARKit face and body tracking pipeline into ArkavoCreator for real-time VRM avatar animation using Continuity Camera.

## Quick Start (5 Minutes)

### Minimal Working Example

```swift
import VRMMetalKit

class QuickStartIntegration {
    let faceDriver: ARKitFaceDriver
    let bodyDriver: ARKitBodyDriver
    var vrmModel: VRMModel?

    init() {
        // Initialize drivers with defaults
        faceDriver = ARKitFaceDriver(
            mapper: .default,        // All 18 VRM expressions
            smoothing: .default      // Balanced latency/stability
        )

        bodyDriver = ARKitBodyDriver(
            mapper: .default,        // Full skeleton
            smoothing: .default,
            priority: .latestActive
        )
    }

    func onCameraMetadata(_ event: CameraMetadataEvent) {
        guard let vrm = vrmModel else { return }

        // Extract ARKit data from your CameraMetadataEvent
        if let faceData = extractFaceBlendShapes(from: event) {
            faceDriver.update(
                blendShapes: faceData,
                controller: vrm.expressionController
            )
        }

        if let bodyData = extractBodySkeleton(from: event) {
            bodyDriver.update(
                skeleton: bodyData,
                nodes: vrm.nodes,
                humanoid: vrm.vrm?.humanoid
            )
        }
    }

    // Helper to convert your event data to ARKit types
    private func extractFaceBlendShapes(from event: CameraMetadataEvent) -> ARKitFaceBlendShapes? {
        // Map your event's blend shape data to ARKitFaceBlendShapes
        guard let shapes = event.faceBlendShapes else { return nil }

        return ARKitFaceBlendShapes(
            timestamp: event.timestamp,
            shapes: shapes  // Dictionary<String, Float> of 52 ARKit shapes
        )
    }

    private func extractBodySkeleton(from event: CameraMetadataEvent) -> ARKitBodySkeleton? {
        // Map your event's skeleton data to ARKitBodySkeleton
        guard let joints = event.bodyJoints else { return nil }

        return ARKitBodySkeleton(
            timestamp: event.timestamp,
            joints: joints,  // Dictionary<ARKitJoint, simd_float4x4>
            isTracked: event.bodyTrackingConfidence > 0.5
        )
    }
}
```

### Expected Results

- **Face expressions**: Avatar should react to facial expressions within 1-2 frames (~16-33ms)
- **Body motion**: Skeleton should mirror body movements with minimal lag
- **Performance**: <2ms overhead per frame for both face and body updates
- **Smoothing**: Natural motion without excessive jitter or lag

### Troubleshooting Common Issues

| Issue | Check | Solution |
|-------|-------|----------|
| Expressions not updating | `vrmModel.expressionController` exists? | Ensure VRM model has expression controller |
| Skeleton not animating | `vrmModel.vrm?.humanoid` exists? | Verify VRM has humanoid bone mapping |
| Jittery motion | Smoothing too low? | Increase smoothing: `.smooth` preset |
| Laggy response | Smoothing too high? | Decrease smoothing: `.lowLatency` preset |
| High CPU usage | Using Kalman filter? | Switch to `.ema(alpha: 0.3)` for performance |

## Architecture Overview

### Data Flow

```
┌──────────────────┐
│  iPhone/iPad     │
│  ARKit Session   │
└────────┬─────────┘
         │ ARKit face blend shapes (52)
         │ ARKit body skeleton (50+ joints)
         │
         ▼
┌──────────────────────┐
│ Continuity Camera /  │
│ Network Transport    │
└────────┬─────────────┘
         │
         ▼
┌──────────────────────┐
│ CameraMetadataEvent  │ ◄─── Your existing infrastructure
└────────┬─────────────┘
         │
         ├──────────────────┐
         │                  │
         ▼                  ▼
┌────────────────┐   ┌──────────────────┐
│ ARKitFaceDriver│   │ ARKitBodyDriver  │
│                │   │                  │
│ • Mapping      │   │ • Retargeting    │
│ • Smoothing    │   │ • Transform      │
│ • Multi-source │   │ • Multi-source   │
└────────┬───────┘   └────────┬─────────┘
         │                    │
         ▼                    ▼
┌────────────────────┐   ┌─────────────┐
│ VRMExpression      │   │ VRMNode     │
│ Controller         │   │ (skeleton)  │
│                    │   │             │
│ 18 expressions     │   │ TRS updates │
└────────┬───────────┘   └────────┬────┘
         │                        │
         └───────────┬────────────┘
                     ▼
            ┌────────────────┐
            │   VRM Model    │
            │   Rendering    │
            └────────────────┘
```

### Component Responsibilities

#### ARKitFaceDriver
- **Input**: ARKitFaceBlendShapes (52 blend shapes from ARKit)
- **Output**: Updates to VRMExpressionController (18 VRM expressions)
- **Features**:
  - Configurable mapping formulas (direct, average, weighted, max, min, custom)
  - Per-expression smoothing (EMA, Kalman, Windowed)
  - Multi-source priority strategies
  - Staleness detection (default 150ms threshold)
- **Performance**: ~50-100µs per update

#### ARKitBodyDriver
- **Input**: ARKitBodySkeleton (50+ joints with 4×4 transforms)
- **Output**: Updates to VRMNode transforms (translation, rotation, scale)
- **Features**:
  - Skeleton retargeting (ARKit joints → VRM humanoid bones)
  - Transform decomposition (matrix → TRS)
  - Per-joint smoothing (separate position/rotation filters)
  - Multi-source priority strategies
- **Performance**: ~50-100µs for full skeleton

#### ARKitToVRMMapper
- Maps 52 ARKit blend shapes → 18 VRM expressions
- Presets: `.default`, `.simplified`, `.aggressive`
- Customizable per-expression formulas

#### ARKitSkeletonMapper
- Maps ARKit joints → VRM humanoid bones
- Presets: `.default`, `.upperBodyOnly`, `.coreOnly`
- Customizable joint mappings

### Thread Safety

All ARKit driver types are thread-safe (`Sendable` conformance):

```swift
// Safe to call from any thread
DispatchQueue.global().async {
    faceDriver.update(blendShapes: data, controller: controller)
}

// Safe to update from multiple camera threads
cameraQueue1.async { faceDriver.update(...) }
cameraQueue2.async { faceDriver.update(...) }
```

**Important**: VRMExpressionController and VRMNode updates should happen on the main thread or a dedicated rendering thread.

### Performance Characteristics

| Component | Latency | Memory | Throughput |
|-----------|---------|--------|------------|
| ARKitFaceDriver | <1ms | <5 KB | 120+ FPS |
| ARKitBodyDriver | <2ms | <10 KB | 120+ FPS |
| EMA Smoothing | ~3-5 CPU cycles | O(1) | Unlimited |
| Kalman Smoothing | ~15-20 CPU cycles | O(1) | Unlimited |
| Total Pipeline | <2ms end-to-end | <15 KB | 60-120 FPS |

## Step-by-Step Integration

### 1. Add VRMMetalKit Dependency

**Swift Package Manager** (Package.swift):
```swift
dependencies: [
    .package(url: "https://github.com/arkavo-org/VRMMetalKit.git", from: "1.0.0")
]
```

**Xcode** (File → Add Package Dependencies):
```
https://github.com/arkavo-org/VRMMetalKit.git
```

### 2. Initialize Face and Body Drivers

```swift
import VRMMetalKit

class ARKitIntegration {
    let faceDriver: ARKitFaceDriver
    let bodyDriver: ARKitBodyDriver

    init() {
        // Face driver with default mapper (all 18 expressions)
        faceDriver = ARKitFaceDriver(
            mapper: .default,
            smoothing: .default  // EMA with alpha=0.3
        )

        // Body driver with full skeleton
        bodyDriver = ARKitBodyDriver(
            mapper: .default,
            smoothing: .default,
            priority: .latestActive
        )
    }
}
```

### 3. Hook Up CameraMetadataEvent Handlers

```swift
extension ARKitIntegration {
    func handleCameraMetadata(_ event: CameraMetadataEvent, vrm: VRMModel) {
        // Update face expressions
        if let faceData = extractFaceData(from: event) {
            faceDriver.update(
                blendShapes: faceData,
                controller: vrm.expressionController
            )
        }

        // Update body skeleton
        if let bodyData = extractBodyData(from: event) {
            bodyDriver.update(
                skeleton: bodyData,
                nodes: vrm.nodes,
                humanoid: vrm.vrm?.humanoid
            )
        }
    }

    private func extractFaceData(from event: CameraMetadataEvent) -> ARKitFaceBlendShapes? {
        guard let shapes = event.arkit?.faceBlendShapes else { return nil }

        return ARKitFaceBlendShapes(
            timestamp: event.timestamp,
            shapes: shapes
        )
    }

    private func extractBodyData(from event: CameraMetadataEvent) -> ARKitBodySkeleton? {
        guard let joints = event.arkit?.bodyJoints else { return nil }

        return ARKitBodySkeleton(
            timestamp: event.timestamp,
            joints: joints,
            isTracked: event.arkit?.bodyTrackingConfidence ?? 0 > 0.5
        )
    }
}
```

### 4. Configure Smoothing and Mapping

#### Custom Smoothing Configuration

```swift
// Low latency for responsive expressions (e.g., live performance)
let lowLatencyConfig = SmoothingConfig.lowLatency  // EMA alpha=0.5

// Smooth for stability (e.g., video recording)
let smoothConfig = SmoothingConfig.smooth  // EMA alpha=0.2

// Per-expression override
var customConfig = SmoothingConfig.default
customConfig.perExpression["blink"] = .none  // No smoothing for instant blink
customConfig.perExpression["blinkLeft"] = .none
customConfig.perExpression["blinkRight"] = .none
customConfig.perExpression["aa"] = .ema(alpha: 0.2)  // Heavy smoothing for speech

let faceDriver = ARKitFaceDriver(
    mapper: .default,
    smoothing: customConfig
)
```

#### Custom Expression Mapping

```swift
// Subtle expressions (50% strength)
var subtleMapper = ARKitToVRMMapper.default
for (expression, formula) in subtleMapper.mappings {
    if case .weighted(let components) = formula {
        let adjusted = components.map { (key, weight) in
            (key, weight * 0.5)
        }
        subtleMapper.mappings[expression] = .weighted(adjusted)
    }
}

// Custom wink expression
subtleMapper.mappings["wink"] = .custom { shapes in
    let leftBlink = shapes.weight(for: ARKitFaceBlendShapes.eyeBlinkLeft)
    let rightBlink = shapes.weight(for: ARKitFaceBlendShapes.eyeBlinkRight)
    return max(leftBlink * (1 - rightBlink), rightBlink * (1 - leftBlink))
}

let faceDriver = ARKitFaceDriver(
    mapper: subtleMapper,
    smoothing: .default
)
```

#### Custom Skeleton Mapping

```swift
// Upper body only for desk/seated scenario
let deskDriver = ARKitBodyDriver(
    mapper: .upperBodyOnly,
    smoothing: .default,
    priority: .latestActive
)

// Custom mapper with fingers
var customMapper = ARKitSkeletonMapper.upperBodyOnly
customMapper.jointMap[.leftHandThumb1] = "leftThumbProximal"
customMapper.jointMap[.leftHandIndex1] = "leftIndexProximal"
customMapper.jointMap[.leftHandMiddle1] = "leftMiddleProximal"
customMapper.jointMap[.leftHandRing1] = "leftRingProximal"
customMapper.jointMap[.leftHandLittle1] = "leftLittleProximal"
// ... repeat for right hand

let bodyDriver = ARKitBodyDriver(
    mapper: customMapper,
    smoothing: .default,
    priority: .latestActive
)
```

### 5. Verify Integration with Test Data

```swift
func testIntegration() {
    // Create test blend shapes
    let testShapes = ARKitFaceBlendShapes(
        timestamp: Date().timeIntervalSinceReferenceDate,
        shapes: [
            ARKitFaceBlendShapes.mouthSmileLeft: 0.8,
            ARKitFaceBlendShapes.mouthSmileRight: 0.8,
            ARKitFaceBlendShapes.eyeBlinkLeft: 0.0,
            ARKitFaceBlendShapes.eyeBlinkRight: 0.0
        ]
    )

    // Update face
    faceDriver.update(blendShapes: testShapes, controller: vrmModel.expressionController)

    // Verify "happy" expression is active
    let happyWeight = vrmModel.expressionController?.getWeight(for: "happy")
    assert(happyWeight ?? 0 > 0.5, "Happy expression should be active")

    // Check statistics
    let stats = faceDriver.getStatistics()
    print("Face updates: \(stats.totalUpdates), skipped: \(stats.skippedUpdates)")
}
```

## Advanced Topics

### Multi-Camera Scenarios

ArkavoCreator supports multiple Continuity Cameras simultaneously. Use priority strategies to control which camera's data is used:

#### Priority Strategies

**1. Latest Active** (Use most recent data)
```swift
let bodyDriver = ARKitBodyDriver(
    mapper: .default,
    smoothing: .default,
    priority: .latestActive  // Automatically use newest data
)

// Update from multiple sources
var sources: [String: ARKitBodySkeleton] = [:]
sources["iPhone"] = iphoneSkeletonData
sources["iPad"] = iPadSkeletonData

bodyDriver.updateMulti(
    skeletons: sources,
    nodes: vrmModel.nodes,
    humanoid: vrmModel.vrm?.humanoid
)
```

**2. Primary with Fallback** (Prefer specific camera)
```swift
let faceDriver = ARKitFaceDriver(
    mapper: .default,
    smoothing: .default,
    priority: .primary("iPhone15Pro", fallback: "iPad")  // Prefer iPhone, fallback to iPad
)

var sources: [String: ARKitFaceBlendShapes] = [:]
sources["iPhone15Pro"] = iphoneFaceData
sources["iPad"] = iPadFaceData

faceDriver.updateMulti(
    sources: sources,
    controller: vrmModel.expressionController
)
```

**3. Highest Confidence** (Use best tracking quality)
```swift
let bodyDriver = ARKitBodyDriver(
    mapper: .default,
    smoothing: .default,
    priority: .highestConfidence  // Use source with best tracking
)
```

**4. Weighted Blending** (Combine multiple sources - planned)
```swift
// Future feature: blend skeleton transforms
let bodyDriver = ARKitBodyDriver(
    mapper: .default,
    smoothing: .default,
    priority: .weighted([
        "FrontCamera": 0.7,
        "SideCamera": 0.3
    ])
)
```

#### Multi-Camera Example

```swift
class MultiCameraIntegration {
    let faceDriver: ARKitFaceDriver
    let bodyDriver: ARKitBodyDriver

    private var faceSources: [String: ARKitFaceBlendShapes] = [:]
    private var bodySources: [String: ARKitBodySkeleton] = [:]

    init() {
        faceDriver = ARKitFaceDriver(
            mapper: .default,
            smoothing: .default,
            priority: .primary("iPhone15Pro", fallback: "iPad")
        )

        bodyDriver = ARKitBodyDriver(
            mapper: .default,
            smoothing: .default,
            priority: .latestActive
        )
    }

    func onCameraMetadata(sourceID: String, event: CameraMetadataEvent, vrm: VRMModel) {
        // Collect data from all sources
        if let faceData = extractFaceData(from: event) {
            faceSources[sourceID] = faceData
        }

        if let bodyData = extractBodyData(from: event) {
            bodySources[sourceID] = bodyData
        }

        // Update with multi-source
        faceDriver.updateMulti(
            sources: faceSources,
            controller: vrm.expressionController
        )

        bodyDriver.updateMulti(
            skeletons: bodySources,
            nodes: vrm.nodes,
            humanoid: vrm.vrm?.humanoid
        )

        // Clean up stale sources
        cleanStale sources(threshold: 0.5)  // 500ms timeout
    }

    private func cleanStaleSources(threshold: TimeInterval) {
        let now = Date().timeIntervalSinceReferenceDate

        faceSources = faceSources.filter { _, data in
            now - data.timestamp < threshold
        }

        bodySources = bodySources.filter { _, data in
            now - data.timestamp < threshold
        }
    }
}
```

### Performance Tuning

#### Measuring Performance

```swift
class PerformanceMonitor {
    let faceDriver: ARKitFaceDriver
    let bodyDriver: ARKitBodyDriver

    func measureUpdateTime() {
        let start = DispatchTime.now()

        faceDriver.update(blendShapes: testData, controller: controller)

        let end = DispatchTime.now()
        let nanos = end.uptimeNanoseconds - start.uptimeNanoseconds
        let ms = Double(nanos) / 1_000_000

        print("Face update: \(ms)ms")
    }

    func printStatistics() {
        let faceStats = faceDriver.getStatistics()
        let bodyStats = bodyDriver.getStatistics()

        print("Face: \(faceStats.totalUpdates) updates, \(faceStats.skipRate * 100)% skip rate")
        print("Body: \(bodyStats.updateCount) updates, last at \(bodyStats.lastUpdateTime)s")
    }

    func resetForProfiling() {
        faceDriver.resetStatistics()
        bodyDriver.resetStatistics()
    }
}
```

#### Optimization Strategies

**1. Reduce Smoothing Overhead**
```swift
// Use simpler filters
let config = SmoothingConfig(global: .none)  // No smoothing (lowest overhead)
let config = SmoothingConfig(global: .ema(alpha: 0.3))  // EMA (~3-5 cycles)
// Avoid: .kalman (15-20 cycles)
```

**2. Partial Skeleton**
```swift
// Upper body only for desk scenarios (fewer joints = faster)
let bodyDriver = ARKitBodyDriver(
    mapper: .upperBodyOnly,  // ~20 joints vs ~50
    smoothing: .default,
    priority: .latestActive
)
```

**3. Increase Staleness Threshold**
```swift
// Skip stale data more aggressively
let faceDriver = ARKitFaceDriver(
    mapper: .default,
    smoothing: .default,
    priority: .latestActive,
    stalenessThreshold: 0.1  // 100ms instead of 150ms
)
```

**4. Batch Updates**
```swift
// Collect multiple frames, then update once
var batchedFaceData: [ARKitFaceBlendShapes] = []

func onCameraMetadata(_ event: CameraMetadataEvent) {
    if let faceData = extractFaceData(from: event) {
        batchedFaceData.append(faceData)
    }

    // Update every 2 frames (30 FPS instead of 60 FPS)
    if batchedFaceData.count >= 2 {
        let latest = batchedFaceData.last!
        faceDriver.update(blendShapes: latest, controller: controller)
        batchedFaceData.removeAll()
    }
}
```

### Recording and Playback

Recording ARKit data is useful for testing, debugging, and offline processing:

```swift
struct ARKitRecording: Codable {
    let faceFrames: [ARKitFaceBlendShapes]
    let bodyFrames: [ARKitBodySkeleton]
    let metadata: [String: String]
}

class ARKitRecorder {
    private var faceFrames: [ARKitFaceBlendShapes] = []
    private var bodyFrames: [ARKitBodySkeleton] = []
    private var isRecording = false

    func startRecording() {
        faceFrames.removeAll()
        bodyFrames.removeAll()
        isRecording = true
    }

    func record(face: ARKitFaceBlendShapes) {
        guard isRecording else { return }
        faceFrames.append(face)
    }

    func record(body: ARKitBodySkeleton) {
        guard isRecording else { return }
        bodyFrames.append(body)
    }

    func stopRecording(to url: URL) throws {
        isRecording = false

        let recording = ARKitRecording(
            faceFrames: faceFrames,
            bodyFrames: bodyFrames,
            metadata: [
                "recordedAt": ISO8601DateFormatter().string(from: Date()),
                "faceFrameCount": "\(faceFrames.count)",
                "bodyFrameCount": "\(bodyFrames.count)"
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(recording)
        try data.write(to: url)

        print("Recorded \(faceFrames.count) face frames, \(bodyFrames.count) body frames to \(url.path)")
    }

    func playback(from url: URL, at fps: Double = 60, onFrame: (ARKitFaceBlendShapes?, ARKitBodySkeleton?) -> Void) throws {
        let data = try Data(contentsOf: url)
        let recording = try JSONDecoder().decode(ARKitRecording.self, from: data)

        let frameDuration = 1.0 / fps
        let maxFrames = max(recording.faceFrames.count, recording.bodyFrames.count)

        for i in 0..<maxFrames {
            let face = i < recording.faceFrames.count ? recording.faceFrames[i] : nil
            let body = i < recording.bodyFrames.count ? recording.bodyFrames[i] : nil

            onFrame(face, body)

            // Sleep to maintain playback rate
            Thread.sleep(forTimeInterval: frameDuration)
        }
    }
}
```

**Usage Example**:
```swift
let recorder = ARKitRecorder()

// Start recording
recorder.startRecording()

// Record frames
func onCameraMetadata(_ event: CameraMetadataEvent) {
    if let face = extractFaceData(from: event) {
        recorder.record(face: face)
    }
    if let body = extractBodyData(from: event) {
        recorder.record(body: body)
    }
}

// Stop and save
try recorder.stopRecording(to: URL(fileURLWithPath: "session.json"))

// Playback later
try recorder.playback(from: URL(fileURLWithPath: "session.json")) { face, body in
    if let face = face {
        faceDriver.update(blendShapes: face, controller: controller)
    }
    if let body = body {
        bodyDriver.update(skeleton: body, nodes: nodes, humanoid: humanoid)
    }
}
```

### Debugging and Profiling

#### Enable Debug Logging

VRMMetalKit supports conditional debug logging (compile-time flags):

```bash
# Build with ARKit debug logging
swift build -Xswiftc -DVRM_METALKIT_ENABLE_LOGS -Xswiftc -DVRM_METALKIT_ENABLE_DEBUG_ANIMATION
```

**Important**: Never enable debug flags in production builds - they have runtime overhead.

#### Statistics Monitoring

```swift
// Monitor update rates and skip rates
let faceStats = faceDriver.getStatistics()
print("""
Face Driver Statistics:
- Total updates: \(faceStats.totalUpdates)
- Skipped updates: \(faceStats.skippedUpdates)
- Skip rate: \(faceStats.skipRate * 100)%
""")

let bodyStats = bodyDriver.getStatistics()
print("""
Body Driver Statistics:
- Update count: \(bodyStats.updateCount)
- Last update: \(bodyStats.lastUpdateTime)s ago
""")

// Reset statistics for clean profiling
faceDriver.resetStatistics()
bodyDriver.resetStatistics()
```

#### Instruments Profiling

Use Xcode Instruments to profile:

1. **Time Profiler**: Measure CPU usage of update calls
2. **Allocations**: Check memory overhead (<15 KB expected)
3. **System Trace**: Verify thread safety and contention

**Expected Profile**:
- `ARKitFaceDriver.update`: <1ms
- `ARKitBodyDriver.update`: <2ms
- `FilterManager.update`: <0.5ms per expression/joint

## Integration Checklist

### Pre-Integration
- [ ] VRMMetalKit added as dependency
- [ ] Access to CameraMetadataEvent with ARKit data
- [ ] VRM model loaded with expression controller
- [ ] Metal device available for rendering

### Basic Integration
- [ ] ARKitFaceDriver initialized
- [ ] ARKitBodyDriver initialized
- [ ] Connected to CameraMetadataEvent handler
- [ ] Face expressions update verified
- [ ] Skeleton updates verified
- [ ] Performance check: <2ms overhead measured

### Multi-Camera Setup
- [ ] Handle multiple camera sources
- [ ] Configure priority strategy (latestActive, primary, etc.)
- [ ] Test source switching (disconnect/reconnect)
- [ ] Verify no data corruption between sources
- [ ] Monitor staleness detection working

### Production Readiness
- [ ] Performance profiled with Instruments (60 FPS target)
- [ ] Memory profiled (<15 KB overhead confirmed)
- [ ] Error handling for missing data
- [ ] Statistics monitoring enabled
- [ ] User feedback for tracking quality
- [ ] Debug flags disabled in release builds

## Troubleshooting

### Expressions Not Updating

**Symptoms**: Avatar face is frozen or not reacting to expressions

**Checks**:
1. Verify CameraMetadataEvent contains ARKit blend shapes
   ```swift
   print("Blend shapes: \(event.arkit?.faceBlendShapes?.count ?? 0)")
   ```

2. Check expression controller exists
   ```swift
   guard let controller = vrmModel.expressionController else {
       print("ERROR: VRM model has no expression controller")
       return
   }
   ```

3. Check staleness threshold (data might be too old)
   ```swift
   let stats = faceDriver.getStatistics()
   print("Skip rate: \(stats.skipRate * 100)%")  // High skip rate = stale data
   ```

4. Verify mapping coverage
   ```swift
   let mapper = ARKitToVRMMapper.default
   print("Mapped expressions: \(mapper.mappings.keys.sorted())")
   ```

**Solutions**:
- Increase staleness threshold if network has high latency
- Check that blend shape keys match ARKitFaceBlendShapes constants
- Verify VRM model supports the expressions you're trying to drive

### Skeleton Not Updating

**Symptoms**: Avatar body is frozen or not following movements

**Checks**:
1. Verify humanoid mapping exists
   ```swift
   guard let humanoid = vrmModel.vrm?.humanoid else {
       print("ERROR: VRM model has no humanoid mapping")
       return
   }
   print("Humanoid bones: \(humanoid.humanBones.keys.sorted())")
   ```

2. Check bone name mapping
   ```swift
   let mapper = ARKitSkeletonMapper.default
   for (arkitJoint, vrmBone) in mapper.jointMap {
       print("\(arkitJoint) → \(vrmBone)")
   }
   ```

3. Verify world transforms are updating
   ```swift
   // After body driver update:
   for node in vrmModel.nodes {
       node.updateWorldTransform(parentTransform: nil)
   }
   ```

**Solutions**:
- Use `.upperBodyOnly` mapper if VRM doesn't have leg bones
- Check that VRM bone names match mapper expectations
- Ensure `updateWorldTransform()` is called after skeleton updates

### Performance Issues

**Symptoms**: Frame rate drops, high CPU usage

**Checks**:
1. Profile with Instruments Time Profiler
2. Check filter overhead
   ```swift
   // Measure update time
   let start = DispatchTime.now()
   faceDriver.update(blendShapes: data, controller: controller)
   let end = DispatchTime.now()
   print("Update time: \((end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)ms")
   ```

3. Check smoothing configuration
   ```swift
   // Kalman is slower than EMA
   print("Using smoothing: \(faceDriver.smoothingConfig)")
   ```

**Solutions**:
- Use `.lowLatency` smoothing preset (EMA alpha=0.5)
- Switch from Kalman to EMA filters
- Use `.upperBodyOnly` mapper for body (fewer joints)
- Reduce update frequency (30 FPS instead of 60 FPS)

### Jittery Motion

**Symptoms**: Avatar movements are shaky or unstable

**Checks**:
1. Check input data quality
   ```swift
   print("ARKit confidence: \(event.arkit?.trackingConfidence ?? 0)")
   ```

2. Verify smoothing is enabled
   ```swift
   if case .none = faceDriver.smoothingConfig.global {
       print("WARNING: No smoothing enabled")
   }
   ```

3. Check network latency (Continuity Camera)
   ```swift
   let latency = Date().timeIntervalSinceReferenceDate - blendShapes.timestamp
   print("Data latency: \(latency * 1000)ms")
   ```

**Solutions**:
- Increase smoothing: use `.smooth` preset (EMA alpha=0.2)
- Switch to Kalman filter for better noise reduction
- Check network quality for Continuity Camera
- Verify ARKit session is running at 60 FPS

### High Skip Rate

**Symptoms**: Many updates being skipped (high `skipRate` in statistics)

**Checks**:
1. Check staleness threshold
   ```swift
   let stats = faceDriver.getStatistics()
   print("Skip rate: \(stats.skipRate * 100)%")
   ```

2. Measure data age
   ```swift
   let now = Date().timeIntervalSinceReferenceDate
   let age = now - blendShapes.timestamp
   print("Data age: \(age * 1000)ms")
   ```

**Solutions**:
- Increase staleness threshold for high-latency networks
- Check Continuity Camera connection quality
- Verify ARKit session frame rate
- Reduce network hops between camera and app

## Examples

See the `Examples/ARKitIntegration/` directory for complete, runnable examples:

- **BasicIntegration.swift**: Minimal single-camera integration
- **MultiCameraIntegration.swift**: Multi-camera with priority strategies
- **CustomMappingExample.swift**: Custom expression and skeleton mapping
- **PerformanceMonitoring.swift**: Statistics and profiling
- **RecordingPlayback.swift**: Recording sessions for testing

## Reference Documentation

- [ARKit Integration Status](../ARKIT_INTEGRATION_STATUS.md): Current implementation status
- [ARKit Integration Plan](ARKIT_INTEGRATION_PLAN.md): Technical design and architecture
- [VRM Specification](https://github.com/vrm-c/vrm-specification): VRM 1.0 spec
- [ARKit Face Tracking](https://developer.apple.com/documentation/arkit/tracking_and_visualizing_faces): Apple's ARKit documentation

## Support

For questions or issues:
- GitHub Issues: https://github.com/arkavo-org/VRMMetalKit/issues
- Email: support@arkavo.org
- Slack: #vrmmetalkit (ArkavoCreator workspace)
