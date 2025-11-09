# ARKit Integration Examples

This directory contains working code examples for integrating VRMMetalKit's ARKit face and body tracking with ArkavoCreator.

## Examples Overview

### 1. BasicIntegration.swift
**Minimal single-camera integration**

- Simplest possible setup
- Single camera source (iPhone or iPad)
- Default configuration
- Good starting point for new integrations

**Key Concepts**:
- Driver initialization
- Camera event handling
- Data extraction from events
- World transform updates

### 2. MultiCameraIntegration.swift
**Multi-camera with priority strategies**

- Handle multiple Continuity Cameras simultaneously
- Different priority strategies (primary/fallback, latest-active, highest-confidence)
- Source management and staleness detection
- Scenario-specific configurations (desk, performance capture)

**Key Concepts**:
- Multi-source updates
- Priority strategies
- Stale source cleanup
- Active source tracking

### 3. CustomMappingExample.swift
**Custom expression and skeleton mapping**

- Subtle expressions (50% strength)
- Exaggerated expressions (150% strength)
- Custom expressions (wink, etc.)
- Speech-optimized mapping
- Minimal mapping for performance
- Desk scenario with finger tracking

**Key Concepts**:
- Expression mapping formulas
- Skeleton joint mapping
- Per-expression smoothing
- Complete driver configurations

### 4. PerformanceMonitoring.swift
**Statistics and profiling**

- Timing measurements
- Statistics tracking
- Performance benchmarking
- Smoothing configuration comparison
- Performance grading

**Key Concepts**:
- Update time measurement
- Percentile calculations (p50, p95, p99)
- Skip rate monitoring
- Configuration comparison

### 5. RecordingPlayback.swift
**Recording sessions for testing**

- Record ARKit tracking sessions to JSON
- Playback at custom frame rates
- Playback with original timing
- Session metadata

**Key Concepts**:
- Codable ARKit types
- Session recording
- Offline playback
- Test data generation

## Quick Start

### 1. Choose an Example

Start with **BasicIntegration.swift** for single camera, or **MultiCameraIntegration.swift** for multiple cameras.

### 2. Adapt to Your Event Structure

The examples use a placeholder `CameraMetadataEvent` type. Replace with your actual type:

```swift
// Example placeholder in BasicIntegration.swift:
struct CameraMetadataEvent {
    let timestamp: TimeInterval
    let arkit: ARKitData?

    struct ARKitData {
        let faceBlendShapes: [String: Float]?
        let bodyJoints: [ARKitJoint: simd_float4x4]?
        let bodyTrackingConfidence: Float
    }
}

// Replace with your actual type:
func extractFaceBlendShapes(from event: YourCameraMetadataEvent) -> ARKitFaceBlendShapes? {
    guard let shapes = event.yourARKitProperty?.faceBlendShapes else { return nil }

    return ARKitFaceBlendShapes(
        timestamp: event.timestamp,
        shapes: shapes
    )
}
```

### 3. Initialize Drivers

```swift
// Use example configuration or customize
let faceDriver = ARKitFaceDriver(
    mapper: .default,
    smoothing: .default
)

let bodyDriver = ARKitBodyDriver(
    mapper: .default,
    smoothing: .default,
    priority: .latestActive
)
```

### 4. Connect to Your Camera Events

```swift
// In your camera event handler
func onCameraMetadata(_ event: YourCameraMetadataEvent) {
    if let faceData = extractFaceData(from: event) {
        faceDriver.update(
            blendShapes: faceData,
            controller: vrmModel.expressionController
        )
    }

    if let bodyData = extractBodyData(from: event) {
        bodyDriver.update(
            skeleton: bodyData,
            nodes: vrmModel.nodes,
            humanoid: vrmModel.vrm?.humanoid
        )
    }
}
```

## Common Patterns

### Pattern 1: VTuber (Face Only)

```swift
import VRMMetalKit

let faceDriver = ARKitFaceDriver(
    mapper: .default,
    smoothing: .smooth  // Smooth for streaming
)

// In your event handler:
func onCameraMetadata(_ event: CameraMetadataEvent) {
    if let face = extractFaceData(from: event) {
        faceDriver.update(
            blendShapes: face,
            controller: vrmModel.expressionController
        )
    }
}
```

### Pattern 2: Desk Worker (Upper Body + Hands)

```swift
import VRMMetalKit

let bodyDriver = ARKitBodyDriver(
    mapper: .upperBodyOnly,  // No leg tracking
    smoothing: .default,
    priority: .latestActive
)

// In your event handler:
func onCameraMetadata(_ event: CameraMetadataEvent) {
    if let body = extractBodyData(from: event) {
        bodyDriver.update(
            skeleton: body,
            nodes: vrmModel.nodes,
            humanoid: vrmModel.vrm?.humanoid
        )
    }
}
```

### Pattern 3: Full-Body Performance Capture

```swift
import VRMMetalKit

let faceDriver = ARKitFaceDriver(
    mapper: .aggressive,  // Amplified expressions
    smoothing: .lowLatency  // Responsive
)

let bodyDriver = ARKitBodyDriver(
    mapper: .default,  // Full skeleton
    smoothing: .lowLatency,
    priority: .highestConfidence  // Use best camera
)

// Multi-camera setup:
var faceSources: [String: ARKitFaceBlendShapes] = [:]
var bodySources: [String: ARKitBodySkeleton] = [:]

func onCameraMetadata(sourceID: String, event: CameraMetadataEvent) {
    if let face = extractFaceData(from: event) {
        faceSources[sourceID] = face
    }
    if let body = extractBodyData(from: event) {
        bodySources[sourceID] = body
    }

    faceDriver.updateMulti(sources: faceSources, controller: controller)
    bodyDriver.updateMulti(skeletons: bodySources, nodes: nodes, humanoid: humanoid)
}
```

## Testing Your Integration

### 1. Use Recording/Playback

Record a test session and play it back for reproducible testing:

```swift
// Record
let recorder = ARKitRecorder()
recorder.startRecording()
// ... capture frames ...
try recorder.stopRecording(to: URL(fileURLWithPath: "test_session.json"))

// Playback
try recorder.playback(from: URL(fileURLWithPath: "test_session.json")) { face, body in
    if let face = face {
        faceDriver.update(blendShapes: face, controller: controller)
    }
    if let body = body {
        bodyDriver.update(skeleton: body, nodes: nodes, humanoid: humanoid)
    }
}
```

### 2. Monitor Performance

Use PerformanceMonitor to track update times:

```swift
let monitor = ARKitPerformanceMonitor(
    faceDriver: faceDriver,
    bodyDriver: bodyDriver
)

// Measure updates
let faceTime = monitor.measureFaceUpdate(
    blendShapes: faceData,
    controller: controller
)

// Print periodic reports
Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
    monitor.printReport()
}
```

### 3. Check Statistics

Verify your integration is working correctly:

```swift
let stats = faceDriver.getStatistics()
print("Updates: \(stats.totalUpdates)")
print("Skipped: \(stats.skippedUpdates)")
print("Skip rate: \(stats.skipRate * 100)%")

// High skip rate (>10%) indicates:
// - Stale data (increase staleness threshold)
// - Network latency (check Continuity Camera connection)
// - Low input FPS (verify ARKit session settings)
```

## Troubleshooting

### Expression Not Updating

**Check**:
1. VRM model has expression controller
2. Blend shape keys match ARKitFaceBlendShapes constants
3. Data is not stale (check skip rate)

**Fix**:
```swift
guard let controller = vrmModel.expressionController else {
    print("ERROR: No expression controller")
    return
}

let stats = faceDriver.getStatistics()
if stats.skipRate > 0.1 {
    print("WARNING: High skip rate (\(stats.skipRate * 100)%)")
}
```

### Skeleton Not Updating

**Check**:
1. VRM model has humanoid mapping
2. Bone names match mapper expectations
3. World transforms are updating

**Fix**:
```swift
guard let humanoid = vrmModel.vrm?.humanoid else {
    print("ERROR: No humanoid mapping")
    return
}

// After body update:
for root in vrmModel.nodes.filter({ $0.parent == nil }) {
    root.updateWorldTransform(parentTransform: nil)
}
```

### Performance Issues

**Check**:
1. Update times with PerformanceMonitor
2. Smoothing configuration overhead
3. Skeleton complexity

**Fix**:
```swift
// Use simpler smoothing
let config = SmoothingConfig(global: .ema(alpha: 0.5))  // Faster than Kalman

// Use partial skeleton
let bodyDriver = ARKitBodyDriver(
    mapper: .upperBodyOnly,  // Fewer joints
    smoothing: config,
    priority: .latestActive
)
```

## Reference Documentation

For complete API documentation and integration guide, see:
- [ARKit Integration Guide](../../docs/ARKitIntegration.md)
- [ARKit Integration Status](../../ARKIT_INTEGRATION_STATUS.md)
- [ARKit Integration Plan](../../docs/ARKIT_INTEGRATION_PLAN.md)

## Support

Questions or issues? Open an issue at:
https://github.com/arkavo-org/VRMMetalKit/issues
