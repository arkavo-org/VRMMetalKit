# VRMMetalKit ARKit Integration - Implementation Plan

## Overview

This document outlines the implementation plan for adding ARKit face and body tracking support to VRMMetalKit to enable Continuity Multi-Camera capture for ArkavoCreator.

## Current State Analysis

### Existing Components
- ✅ `VRMExpressionController` - Controls facial expressions via presets (happy, blink, lookLeft, etc.)
- ✅ `VRMExpressionPreset` - 18 expression presets (emotions, visemes, gaze, blink)
- ✅ `VRMHumanoidBone` - 55 humanoid bones (required + optional)
- ✅ `AnimationPlayer` - Drives bone animations via `JointTrack`
- ✅ `VRMModel` - Core model with nodes, meshes, materials
- ❌ No ARKit support
- ❌ No multi-source metadata handling
- ❌ No timestamp/QoS management
- ❌ No smoothing/filtering infrastructure

## Architecture Design

### Module Structure

```
Sources/VRMMetalKit/
├── ARKit/                          # NEW: ARKit integration module
│   ├── ARKitTypes.swift           # ARKit data models (blend shapes, skeleton)
│   ├── ARKitFaceDriver.swift      # Face tracking → VRM expressions
│   ├── ARKitBodyDriver.swift      # Body tracking → VRM skeleton
│   ├── ARKitMapper.swift          # Configurable mapping tables
│   ├── SmoothingFilters.swift     # EMA, Kalman, windowed averaging
│   ├── MetadataSource.swift       # Multi-source handling
│   └── QoSController.swift        # Timestamp/jitter management
└── ...
```

### Data Flow

```
Remote Device (iPhone/iPad)
    ↓
ARKit Face/Body Tracking
    ↓
CameraMetadataEvent (ArkavoRecorder)
    ↓
Transport (USB-C, Wi-Fi, NFC)
    ↓
ArkavoCreator (macOS)
    ↓
ARKitFaceDriver / ARKitBodyDriver
    ↓
SmoothingFilters (EMA, Kalman)
    ↓
VRMExpressionController / AnimationPlayer
    ↓
VRMMetalKit Renderer
```

## Phase 1: Data Models & Types (Week 1)

### 1.1 ARKit Data Models

Create transport-agnostic data types for ARKit metadata:

```swift
// ARKitTypes.swift

/// Face blend shape data from ARKit
public struct ARKitFaceBlendShapes: Sendable {
    public let timestamp: TimeInterval
    public let shapes: [String: Float]  // ARKit keys → weights (0-1)

    // Standard ARKit keys (52 blend shapes)
    public static let eyeBlinkLeft = "eyeBlinkLeft"
    public static let eyeBlinkRight = "eyeBlinkRight"
    public static let jawOpen = "jawOpen"
    // ... all 52 ARKit blend shapes
}

/// Body skeleton data from ARKit
public struct ARKitBodySkeleton: Sendable {
    public let timestamp: TimeInterval
    public let joints: [ARKitJoint: simd_float4x4]  // Joint → world transform
    public let isTracked: Bool  // Is body currently tracked?
}

public enum ARKitJoint: String, CaseIterable {
    case root, hips, spine, chest, neck, head
    case leftShoulder, leftUpperArm, leftLowerArm, leftHand
    case rightShoulder, rightUpperArm, rightLowerArm, rightHand
    case leftUpperLeg, leftLowerLeg, leftFoot
    case rightUpperLeg, rightLowerLeg, rightFoot
    // ... complete ARKit skeleton
}
```

### 1.2 Metadata Source Protocol

```swift
/// Represents a source of AR metadata (face, body, or both)
public protocol ARMetadataSource: Sendable {
    var sourceID: UUID { get }
    var name: String { get }
    var lastUpdate: TimeInterval { get }
    var isActive: Bool { get }  // Not stale (< 150ms)
}

public final class ARFaceSource: ARMetadataSource {
    public let sourceID: UUID
    public let name: String
    public private(set) var lastUpdate: TimeInterval
    public var isActive: Bool { CACurrentMediaTime() - lastUpdate < 0.15 }

    public func update(blendShapes: ARKitFaceBlendShapes)
}

public final class ARBodySource: ARMetadataSource {
    // Similar structure
}
```

## Phase 2: Face Tracking Bridge (Week 1-2)

### 2.1 Blend Shape Mapper

Create configurable mapping from ARKit blend shapes to VRM expressions:

```swift
/// Maps ARKit blend shapes to VRM expression presets
public struct ARKitToVRMMapper: Sendable {
    public var mappings: [VRMExpressionPreset: BlendShapeFormula]

    public static let `default`: ARKitToVRMMapper
    public static func custom(mappings: [VRMExpressionPreset: BlendShapeFormula]) -> ARKitToVRMMapper
}

/// Formula to compute VRM expression weight from ARKit blend shapes
public enum BlendShapeFormula: Sendable {
    case direct(String)  // Direct 1:1 mapping
    case average([String])  // Average of multiple shapes
    case max([String])  // Max of multiple shapes
    case weighted([(String, Float)])  // Weighted sum
    case custom((ARKitFaceBlendShapes) -> Float)  // Custom function
}

// Example mappings:
// .blink → average([eyeBlinkLeft, eyeBlinkRight])
// .blinkLeft → direct(eyeBlinkLeft)
// .aa → weighted([(jawOpen, 0.7), (mouthFunnel, 0.3)])
```

### 2.2 Face Driver

```swift
/// Drives VRM facial expressions from ARKit face tracking
public final class ARKitFaceDriver: @unchecked Sendable {
    public let mapper: ARKitToVRMMapper
    public var smoothingConfig: SmoothingConfig
    private var smoothers: [VRMExpressionPreset: SmoothingFilter]

    public init(
        mapper: ARKitToVRMMapper = .default,
        smoothing: SmoothingConfig = .default
    )

    /// Update VRM expressions from ARKit blend shapes
    public func update(
        blendShapes: ARKitFaceBlendShapes,
        controller: VRMExpressionController
    )

    /// Batch update from multiple sources (merges/prioritizes)
    public func update(
        sources: [ARFaceSource],
        controller: VRMExpressionController,
        priority: SourcePriorityStrategy = .latestActive
    )
}
```

## Phase 3: Smoothing & Filtering (Week 2)

### 3.1 Smoothing Filters

```swift
/// Configurable smoothing for expression weights
public enum SmoothingFilter: Sendable {
    case none
    case ema(alpha: Float)  // Exponential moving average
    case kalman(processNoise: Float, measurementNoise: Float)
    case windowed(size: Int)  // Windowed averaging
}

public struct SmoothingConfig: Sendable {
    public var global: SmoothingFilter  // Default for all expressions
    public var perExpression: [VRMExpressionPreset: SmoothingFilter]  // Override per expression

    public static let `default` = SmoothingConfig(
        global: .ema(alpha: 0.3),
        perExpression: [
            .blink: .none,  // No smoothing for blinks (fast response)
            .blinkLeft: .none,
            .blinkRight: .none
        ]
    )

    public static let lowLatency = SmoothingConfig(global: .ema(alpha: 0.7))
    public static let smooth = SmoothingConfig(global: .ema(alpha: 0.1))
}
```

### 3.2 Filter Implementations

```swift
// SmoothingFilters.swift

/// Exponential Moving Average filter
final class EMAFilter {
    private var value: Float?
    private let alpha: Float

    func update(_ newValue: Float) -> Float {
        if let current = value {
            value = alpha * newValue + (1 - alpha) * current
        } else {
            value = newValue
        }
        return value!
    }
}

/// Kalman filter for smooth, responsive tracking
final class KalmanFilter {
    // Kalman state variables
    // Implementation based on 1D Kalman equations
}

/// Windowed averaging filter
final class WindowedFilter {
    private var window: [Float] = []
    private let size: Int

    func update(_ newValue: Float) -> Float {
        window.append(newValue)
        if window.count > size { window.removeFirst() }
        return window.reduce(0, +) / Float(window.count)
    }
}
```

## Phase 4: Body Tracking Integration (Week 2-3)

### 4.1 Skeleton Retargeting

```swift
/// Retargets ARKit skeleton to VRM humanoid bones
public struct ARKitSkeletonRetargeter {
    /// Mapping from ARKit joints to VRM humanoid bones
    public var jointMap: [ARKitJoint: VRMHumanoidBone]

    public static let `default`: ARKitSkeletonRetargeter

    /// Retarget ARKit skeleton to VRM model
    /// - Returns: JointTrack array for AnimationPlayer
    public func retarget(
        skeleton: ARKitBodySkeleton,
        model: VRMModel
    ) -> [JointTrack]
}
```

### 4.2 Body Driver

```swift
/// Drives VRM body animation from ARKit body tracking
public final class ARKitBodyDriver {
    public let retargeter: ARKitSkeletonRetargeter
    public var smoothingConfig: SkeletonSmoothingConfig

    /// Update VRM skeleton from ARKit body tracking
    public func update(
        skeleton: ARKitBodySkeleton,
        player: AnimationPlayer,
        model: VRMModel
    )

    /// Handle partial skeleton (e.g., upper body only)
    public func updatePartial(
        skeleton: ARKitBodySkeleton,
        joints: Set<ARKitJoint>,
        player: AnimationPlayer,
        model: VRMModel
    )
}
```

## Phase 5: Multi-Source Handling (Week 3)

### 5.1 Source Manager

```swift
/// Manages multiple AR metadata sources
public final class ARMetadataSourceManager {
    private var faceSources: [UUID: ARFaceSource] = [:]
    private var bodySources: [UUID: ARBodySource] = [:]

    public func register(faceSource: ARFaceSource)
    public func register(bodySource: ARBodySource)
    public func remove(sourceID: UUID)

    /// Get active sources (not stale)
    public var activeFaceSources: [ARFaceSource]
    public var activeBodySources: [ARBodySource]
}

public enum SourcePriorityStrategy {
    case latestActive  // Use most recent active source
    case merge(weights: [UUID: Float])  // Weighted merge of sources
    case primary(UUID)  // Use specific source, fallback to others
}
```

## Phase 6: QoS & Timestamp Management (Week 3)

### 6.1 QoS Controller

```swift
/// Manages quality-of-service for AR metadata streams
public final class ARMetadataQoSController {
    public var maxLatency: TimeInterval = 0.150  // 150ms
    public var interpolateOnJitter: Bool = true

    /// Check if metadata is fresh
    public func isFresh(timestamp: TimeInterval) -> Bool

    /// Interpolate between two metadata samples
    public func interpolate(
        from: ARKitFaceBlendShapes,
        to: ARKitFaceBlendShapes,
        progress: Float
    ) -> ARKitFaceBlendShapes

    /// Decide whether to pause updates (stale data)
    public func shouldPause(source: ARMetadataSource) -> Bool
}
```

## Phase 7: Testing Infrastructure (Week 4)

### 7.1 Metadata Recorder/Replayer

```swift
/// Records AR metadata for playback
public struct ARMetadataRecording: Codable {
    public var faceFrames: [ARKitFaceBlendShapes]
    public var bodyFrames: [ARKitBodySkeleton]
    public var duration: TimeInterval
}

public final class ARMetadataPlayer {
    public func load(from url: URL) throws -> ARMetadataRecording
    public func play(
        recording: ARMetadataRecording,
        faceDriver: ARKitFaceDriver?,
        bodyDriver: ARKitBodyDriver?,
        loop: Bool = false
    )
}
```

### 7.2 Test Harnesses

```swift
// Tests/VRMMetalKitTests/ARKit/ARKitFaceDriverTests.swift

final class ARKitFaceDriverTests: XCTestCase {
    func testBlendShapeMapping() {
        let mapper = ARKitToVRMMapper.default
        let blendShapes = ARKitFaceBlendShapes(
            timestamp: 0,
            shapes: ["eyeBlinkLeft": 1.0, "eyeBlinkRight": 1.0]
        )

        let controller = VRMExpressionController()
        let driver = ARKitFaceDriver(mapper: mapper)
        driver.update(blendShapes: blendShapes, controller: controller)

        // Verify blink expression was triggered
    }

    func testEMASmoothing() {
        // Test smoothing filters
    }

    func testStaleDataHandling() {
        // Test QoS controller
    }
}
```

## Phase 8: Documentation & Examples (Week 4)

### 8.1 Integration Guide

```markdown
# ARKit Integration Guide

## Quick Start

### Face Tracking

​```swift
import VRMMetalKit

// 1. Create face driver
let faceDriver = ARKitFaceDriver(
    mapper: .default,
    smoothing: .default
)

// 2. Update from ARKit metadata
func onCameraMetadata(_ event: CameraMetadataEvent) {
    guard let faceData = event.arFaceData else { return }

    let blendShapes = ARKitFaceBlendShapes(
        timestamp: event.timestamp,
        shapes: faceData.blendShapes
    )

    faceDriver.update(
        blendShapes: blendShapes,
        controller: vrmRenderer.expressionController
    )
}
​```

### Body Tracking

​```swift
let bodyDriver = ARKitBodyDriver(retargeter: .default)

func onBodyTracking(_ skeleton: ARKitBodySkeleton) {
    bodyDriver.update(
        skeleton: skeleton,
        player: animationPlayer,
        model: vrmModel
    )
}
​```

### Multi-Source Support

​```swift
let sourceManager = ARMetadataSourceManager()
let faceSource1 = ARFaceSource(name: "iPhone Front")
let faceSource2 = ARFaceSource(name: "iPad Side")

sourceManager.register(faceSource: faceSource1)
sourceManager.register(faceSource: faceSource2)

// Update from multiple sources
faceDriver.update(
    sources: sourceManager.activeFaceSources,
    controller: expressionController,
    priority: .latestActive
)
​```
```

## Implementation Timeline

### Week 1: Foundation
- [ ] Create ARKit module structure
- [ ] Implement ARKitTypes (blend shapes, skeleton)
- [ ] Implement MetadataSource protocol
- [ ] Create default ARKit → VRM mappings
- [ ] Basic ARKitFaceDriver implementation

### Week 2: Core Features
- [ ] Implement smoothing filters (EMA, Kalman, Windowed)
- [ ] Complete ARKitFaceDriver with smoothing
- [ ] Implement ARKitSkeletonRetargeter
- [ ] Implement ARKitBodyDriver
- [ ] Handle partial skeleton updates

### Week 3: Advanced Features
- [ ] ARMetadataSourceManager implementation
- [ ] Multi-source merging/prioritization
- [ ] QoS controller with timestamp management
- [ ] Jitter handling and interpolation
- [ ] Stale data detection and pausing

### Week 4: Testing & Docs
- [ ] ARMetadataRecording/Player for test harnesses
- [ ] Unit tests for all components
- [ ] Integration tests with sample recordings
- [ ] Integration guide documentation
- [ ] API reference documentation
- [ ] Sample code and examples

## Success Criteria

### Functional
- ✅ ARKit blend shapes → VRM expressions with <10ms latency
- ✅ ARKit skeleton → VRM humanoid with correct retargeting
- ✅ Support 2+ simultaneous metadata sources
- ✅ Smooth playback with EMA/Kalman filtering
- ✅ Graceful degradation when metadata is stale

### Performance
- ✅ Maintain 60 FPS on M3 Pro with full ARKit pipeline
- ✅ <1ms per-frame overhead for expression updates
- ✅ <2ms per-frame overhead for skeleton retargeting

### Compatibility
- ✅ Backward compatible (existing VRM users unaffected)
- ✅ Transport-agnostic (works with USB-C, Wi-Fi, NFC)
- ✅ Thread-safe (@MainActor compatible)

## Open Questions

1. **Blend Shape Coverage**: Should we support all 52 ARKit blend shapes or subset?
   - **Decision**: Start with complete 52, let mapper filter unused ones

2. **Skeleton Interpolation**: When body tracking is lost, should we:
   - Freeze last known pose?
   - Blend to neutral pose?
   - Switch to fallback animation?
   - **Decision**: Blend to neutral over 0.5s, allow configuration

3. **Multi-Source Merging**: How to merge conflicting face/body data?
   - **Decision**: Priority-based (latest active), with optional weighted merge

4. **Performance Budget**: Maximum acceptable overhead?
   - **Decision**: <3ms total (1ms face + 2ms body) on M3 Pro

## Next Steps

1. Create ARKit module structure
2. Implement ARKitTypes.swift with data models
3. Build ARKitFaceDriver with basic mapping
4. Add EMA smoothing filter
5. Test with synthetic blend shape data
6. Iterate based on ArkavoCreator integration feedback
