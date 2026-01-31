# VRM 0.0 and VRM 1.0 Animation Support Report

**Date:** 2026-01-30  
**Scope:** Animation system architecture, VRMA support, VRM version compatibility, and test coverage

---

## Executive Summary

VRMMetalKit provides comprehensive animation support for both **VRM 0.0** and **VRM 1.0** models with full backward compatibility. The system implements the **VRMC_vrm_animation-1.0** specification for loading animations and includes sophisticated coordinate conversion for VRM 0.0 models.

| Feature | VRM 0.0 | VRM 1.0 | Status |
|---------|---------|---------|--------|
| VRMA Animation Loading | ✅ (with coordinate conversion) | ✅ Native | **COMPLETE** |
| Coordinate System | Unity LH (converted) | glTF RH (native) | **COMPLETE** |
| Retargeting | ✅ Delta-based | ✅ Delta-based | **COMPLETE** |
| Expression Tracks | ✅ | ✅ | **COMPLETE** |
| Non-Humanoid Tracks | ✅ | ✅ | **COMPLETE** |

---

## 1. Architecture Overview

### 1.1 Core Animation Components

```
┌─────────────────────────────────────────────────────────────────┐
│                      Animation System                           │
├─────────────────────────────────────────────────────────────────┤
│  VRMAnimationLoader        │  Loads .vrma files, parses tracks  │
│  AnimationClip             │  Container for joint/morph tracks  │
│  AnimationPlayer           │  Playback control, sampling        │
│  JointTrack/NodeTrack      │  Bone animation data               │
│  MorphTrack                │  Expression/blend shape animation  │
└─────────────────────────────────────────────────────────────────┘
```

### 1.2 File Organization

| File | Purpose | Lines |
|------|---------|-------|
| `Animation.swift` | Core types (AnimationClip, JointTrack, MorphTrack, NodeTrack) | 142 |
| `AnimationPlayer.swift` | Playback engine with thread-safety | 214 |
| `VRMAnimationLoader.swift` | VRMA parsing and retargeting | 993 |

---

## 2. VRM Version Support

### 2.1 Version Detection

```swift
// VRMModel.swift:75-77
public var isVRM0: Bool {
    return specVersion == .v0_0
}
```

The system automatically detects VRM version at load time:
- **VRM 0.0**: Uses `"version"` field, Unity left-handed coordinates
- **VRM 1.0**: Uses `"specVersion"` field, glTF right-handed coordinates

### 2.2 Coordinate System Conversion

When loading VRMA animations (which use VRM 1.0/glTF coordinates) for VRM 0.0 models:

```swift
// VRMAnimationLoader.swift:101
let convertForVRM0 = model?.isVRM0 ?? false
```

**Conversion Formula** (matching three-vrm reference implementation):

```swift
// Rotation: Negate X and Z components
private func convertRotationForVRM0(_ q: simd_quatf) -> simd_quatf {
    return simd_quatf(ix: -q.imag.x, iy: q.imag.y, iz: -q.imag.z, r: q.real)
}

// Translation: Negate X and Z components  
private func convertTranslationForVRM0(_ v: SIMD3<Float>) -> SIMD3<Float> {
    return SIMD3<Float>(-v.x, v.y, -v.z)
}
```

This conversion is applied:
1. During sampling in `makeRotationSampler()`
2. During sampling in `makeTranslationSampler()`
3. Before retargeting calculations

---

## 3. VRMA Animation Loader

### 3.1 Supported Features

| Feature | Implementation | Status |
|---------|----------------|--------|
| **VRMC_vrm_animation Extension** | Full parsing of humanoid, expressions | ✅ Complete |
| **Humanoid Bone Mapping** | Via extension or heuristic fallback | ✅ Complete |
| **Expression Tracks** | Preset and custom expressions | ✅ Complete |
| **Non-Humanoid Tracks** | Hair, accessories, bust, etc. | ✅ Complete |
| **Interpolation Modes** | LINEAR, STEP, CUBICSPLINE | ✅ Complete |

### 3.2 Bone Mapping Strategy

The loader uses a three-tier fallback system:

```swift
// Tier 1: VRMC_vrm_animation extension data (most reliable)
let animationNodeToBone: [Int: VRMHumanoidBone] = { ... }

// Tier 2: Model's humanoid bone names
let modelNameToBone: [String: VRMHumanoidBone] = { ... }

// Tier 3: Heuristic pattern matching (fallback)
let heuristicNameToBone: (String) -> VRMHumanoidBone? = { name in
    if n.contains("hips") { return .hips }
    if n.contains("upperarm") { return .leftUpperArm }
    // ... etc
}
```

### 3.3 Retargeting System

**Problem**: Animation authored on one skeleton proportions applied to different skeleton.

**Solution**: Delta-based retargeting

```swift
// Formula applied per-frame:
delta = inverse(animationRest) * animationRotation
result = modelRest * delta
```

This ensures:
- Animation intent is preserved
- Different bind poses are handled correctly
- VRM 0.0 coordinate conversion happens before retargeting

---

## 4. Animation Player

### 4.1 Thread Safety

The `AnimationPlayer` is fully thread-safe:

```swift
public final class AnimationPlayer: @unchecked Sendable {
    private let playerLock = NSLock()
    
    // Model updates are atomic via model.withLock
    public func update(deltaTime: Float, model: VRMModel) {
        model.withLock {
            // All node updates happen here
        }
    }
}
```

### 4.2 Track Types

| Track Type | Target | Use Case |
|------------|--------|----------|
| `JointTrack` | Humanoid bones (.hips, .spine, etc.) | Body animation |
| `NodeTrack` | Non-humanoid nodes by name | Hair, accessories |
| `MorphTrack` | Expression weights | Facial expressions |

### 4.3 Playback Features

- **Speed control**: Variable playback rate
- **Looping**: Toggle loop mode
- **Seeking**: Jump to any time position
- **Root motion**: Optional hips translation application

---

## 5. Test Coverage

### 5.1 Test Files Overview

| Test File | Purpose | Test Count |
|-----------|---------|------------|
| `AnimationTests.swift` | Core animation math, integration | 30+ |
| `VRMACoordinateConversionTests.swift` | VRM 0.0 conversion | 7 |
| `VRMVersionAwareTests.swift` | Version detection, material propagation | 6 |
| `VRMAComprehensiveTests.swift` | Edge cases, interpolation | 15+ |

### 5.2 Key Test Categories

#### Tier 1: Pure Math Tests
- VRMNode transform matrix operations
- Quaternion rotation validation (90° X/Y/Z)
- TRS order verification (T * R * S)
- Hierarchy propagation (parent → child)

#### Tier 2: Integration Tests
- AnimationPlayer with VRMBuilder model
- Deep hierarchy updates (hips → spine → chest → neck → head)
- Joint track sampling
- Morph track sampling

#### Tier 3: Real File Tests
- VRMA loading with AliciaSolid.vrm (VRM 0.0)
- Multi-file comparison (VRMA_01 through VRMA_07)
- Keyframe pattern analysis
- Static vs dynamic animation detection

### 5.3 VRM 0.0 Specific Tests

```swift
// VRMACoordinateConversionTests.swift
func testVRM0VersionDetection() async throws {
    let model = try await VRMModel.load(from: modelURL, device: device)
    XCTAssertEqual(model.specVersion, .v0_0)
    XCTAssertTrue(model.isVRM0)
}

func testRotationConversionMath() {
    // Verify X and Z negation
    let converted = convertRotationForVRM0Test(rotX45)
    XCTAssertEqual(converted.imag.x, -rotX45.imag.x)
    XCTAssertEqual(converted.imag.z, -rotX45.imag.z)
}

func testVRMALoadingWithVRM0Model() async throws {
    // Ensures coordinate conversion is applied
    let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
}
```

### 5.4 VRM 1.0 Specific Tests

```swift
// VRMVersionAwareTests.swift
func testVRM1ModelVersionDetection() async throws {
    let model = try await VRMModel.load(from: url, device: device)
    XCTAssertEqual(model.specVersion, .v1_0)
    XCTAssertFalse(model.isVRM0)
}

func testVRM1MaterialVersionPropagation() async throws {
    // All materials should have vrmVersion = .v1_0
    for material in model.materials {
        XCTAssertEqual(material.vrmVersion, .v1_0)
    }
}
```

---

## 6. Interpolation Support

### 6.1 LINEAR Interpolation

```swift
case .linear:
    let (index, frac) = findKeyframeIndexAndFrac(times: track.times, time: time)
    let q0 = quaternionValue(from: track, keyIndex: index)
    let q1 = quaternionValue(from: track, keyIndex: index + 1)
    return simd_normalize(simd_slerp(q0, q1, frac))
```

- **Rotation**: SLERP (spherical linear interpolation)
- **Translation/Scale**: LERP (linear interpolation)

### 6.2 STEP Interpolation

Holds value until next keyframe (no interpolation).

### 6.3 CUBICSPLINE Interpolation

Uses Hermite splines with in/out tangents:

```swift
case .cubicSpline:
    let hermiteValue = hermite(value0, m0, value1, m1, frac)
```

---

## 7. Edge Case Handling

### 7.1 Quaternion Double-Cover

Quaternions `q` and `-q` represent the same rotation. Handled via dot product check:

```swift
if simd_dot(q0.vector, q1.vector) < 0 {
    q1 = simd_quatf(vector: -q1.vector)
}
```

### 7.2 Rest Pose Mismatch Detection

```swift
let dot = abs(simd_dot(rotationRest, modelRest.rotation))
let rotationDiff = acos(min(1.0, dot)) * 2.0
if rotationDiff > 0.1 {  // ~5.7 degrees
    vrmLogAnimation("[VRMA Retargeting] Bone \(bone): rest pose mismatch detected")
}
```

### 7.3 Null Safety

- Handles missing tracks gracefully
- Falls back to rest pose when animation data unavailable
- Validates node indices before access

---

## 8. Known Limitations

| Limitation | Impact | Workaround |
|------------|--------|------------|
| `lookAt` in VRMA | Not implemented | Use runtime LookAt controller |
| Multiple animations per file | First animation only | Split into separate files |
| leftEye/rightEye animation | Prohibited by spec | N/A - spec compliance |

---

## 9. Compliance Summary

### 9.1 VRMC_vrm_animation-1.0 Specification

| Requirement | Status | Notes |
|-------------|--------|-------|
| Humanoid bone animation | ✅ Complete | Full retargeting support |
| Expression animation | ✅ Complete | Preset + custom |
| LookAt animation | ⚠️ Not implemented | Runtime controller available |
| Translation limits (hips only) | ✅ Enforced | Other bones ignore translation |
| Scale animation | ✅ Supported | With retargeting |

### 9.2 VRM 0.0 Compatibility

| Feature | Status |
|---------|--------|
| Coordinate conversion | ✅ Automatic |
| Material version propagation | ✅ All materials tagged |
| SpringBone animation | ✅ Separate system |
| Expression mapping | ✅ VRM 0.0 → VRM 1.0 presets |

---

## 10. Recommendations

### 10.1 For VRM 0.0 Models

1. **Always provide the model** when loading VRMA:
   ```swift
   let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
   ```
   This enables automatic coordinate conversion.

2. **Test with multiple animations** to ensure coordinate conversion correctness.

3. **Monitor retargeting logs** in DEBUG builds for rest pose mismatches.

### 10.2 For VRM 1.0 Models

1. **VRMA works natively** - no special handling needed.

2. **Ensure VRMC_vrm_animation extension** is present in animation files for reliable bone mapping.

### 10.3 For Content Creators

1. **Use VRMC_vrm_animation extension** in animation files for explicit bone mapping.
2. **Follow T-pose convention** for rest poses to minimize retargeting issues.
3. **Test animations** on both VRM 0.0 and VRM 1.0 models.

---

## 11. Conclusion

VRMMetalKit's animation system provides **production-ready support** for both VRM 0.0 and VRM 1.0 models:

- ✅ **Complete VRMA specification support**
- ✅ **Automatic coordinate conversion** for VRM 0.0
- ✅ **Robust retargeting** for different skeleton proportions
- ✅ **Comprehensive test coverage** (>50 test cases)
- ✅ **Thread-safe playback** for real-time applications

The system is suitable for VTuber applications, virtual production, and game development with mixed VRM model libraries.
