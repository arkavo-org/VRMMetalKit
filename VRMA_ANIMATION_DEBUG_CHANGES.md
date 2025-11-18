# VRMA Animation Debugging Changes

## Summary

This document describes the changes made to `VRMAnimationLoader.swift` to address animation playback differences between VRMMetalKit and UniVRM.

## Critical Issues Addressed

### 1. Rest Pose Retargeting (CRITICAL) ✅

**Problem:** VRMMetalKit was applying rest pose retargeting to VRMA animations, but UniVRM does NOT do this for VRMA files. VRMA animations are designed to be applied directly to the target model without retargeting.

**Solution:** Added `applyRetargeting` parameter to `loadVRMA()` with default value `false`:

```swift
public static func loadVRMA(
    from url: URL,
    model: VRMModel? = nil,
    applyRetargeting: Bool = false  // NEW: Default false for VRMA
) throws -> AnimationClip
```

**Behavior:**
- `applyRetargeting = false` (default): Animation data is applied directly without retargeting
- `applyRetargeting = true`: Applies delta-based retargeting (for generic glTF animations)

**Impact:** This is the most likely cause of animation differences and should make VRMA playback identical to UniVRM.

---

### 2. Coordinate System Conversion (HIGH PRIORITY) ✅

**Problem:** Unity uses left-handed coordinate system (Y-up), while Metal uses right-handed (Y-up). UniVRM inverts the X-axis during import to handle this.

**Solution:** Added `convertCoordinateSystem` parameter with default value `false`:

```swift
public static func loadVRMA(
    from url: URL,
    model: VRMModel? = nil,
    applyRetargeting: Bool = false,
    convertCoordinateSystem: Bool = false  // NEW: Default false
) throws -> AnimationClip
```

**Conversion Function:**
```swift
/// Converts quaternion from Unity left-handed (Y-up) to Metal right-handed (Y-up)
/// Inverts X-axis, mirroring rotations across YZ plane
private func convertUnityToMetalRotation(_ q: simd_quatf) -> simd_quatf {
    return simd_quatf(ix: -q.imag.x, iy: q.imag.y, iz: q.imag.z, r: q.real)
}
```

**Behavior:**
- `convertCoordinateSystem = false` (default): Use animation data as-is
- `convertCoordinateSystem = true`: Convert Unity left-handed → Metal right-handed

**Note:** Most VRMA files should already be in the correct coordinate system, so this defaults to `false`. Enable only if animations are mirrored or moving in the opposite direction.

---

### 3. Comprehensive Debug Logging ✅

Added detailed logging for debugging animation issues. Enable with build flags:

```bash
swift build -Xswiftc -DVRM_METALKIT_ENABLE_DEBUG_ANIMATION
swift build -Xswiftc -DVRM_METALKIT_ENABLE_DEBUG_LOADER
```

**Log Categories:**

**[RETARGET]** - Rest pose retargeting status
```
[RETARGET] NO retargeting - using animation data directly
[RETARGET]   Animation rest: simd_quatf(...)
[RETARGET]   Model rest: simd_quatf(...)
```

**[COORD]** - Coordinate system conversion
```
[COORD] Converting Unity left-handed → Metal right-handed (inverting X-axis)
[COORD] Animation rotation (raw): simd_quatf(...)
[COORD] After conversion: simd_quatf(...)
```

**[INTERP]** - Quaternion interpolation (SLERP shortest path)
```
[INTERP] Quaternion dot product: -0.345
[INTERP] Using shortest path (negating q1)
```

---

## Quaternion SLERP (Already Correct) ✅

The existing SLERP implementation correctly handles the shortest path:

```swift
let dot = simd_dot(q0.vector, q1.vector)
if dot < 0 {
    q1 = simd_quatf(vector: -q1.vector)  // Take shortest path
}
return simd_normalize(simd_slerp(q0, q1, frac))
```

This was already implemented correctly and no changes were needed.

---

## Usage Guide

### Default Usage (Recommended for VRMA)

```swift
// Load VRMA with no retargeting and no coordinate conversion
let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: vrmModel)
```

This should produce identical results to UniVRM.

### Debug a Specific Issue

**If animations are mirrored/reversed:**
```swift
let clip = try VRMAnimationLoader.loadVRMA(
    from: vrmaURL,
    model: vrmModel,
    convertCoordinateSystem: true  // Try coordinate conversion
)
```

**If you're loading a generic glTF animation (not VRMA):**
```swift
let clip = try VRMAnimationLoader.loadVRMA(
    from: animURL,
    model: vrmModel,
    applyRetargeting: true  // Enable retargeting for generic animations
)
```

### Enable Debug Logging

Build with debug flags:
```bash
swift build -Xswiftc -DVRM_METALKIT_ENABLE_DEBUG_ANIMATION -Xswiftc -DVRM_METALKIT_ENABLE_DEBUG_LOADER
```

Then run your app/tests and check the console for detailed logs.

---

## Testing Recommendations

### 1. Compare Single Bone (Hips)

Focus on the hips bone and compare frame-by-frame with UniVRM:

```swift
let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
let player = AnimationPlayer()
player.load(clip)

for time in [0.0, 0.5, 1.0, 1.5, 2.0] {
    player.currentTime = time
    player.update(deltaTime: 0, model: model)

    if let hipsIndex = model.humanoid?.getBoneNode(.hips) {
        let hips = model.nodes[hipsIndex]
        print("[\(time)] Hips rotation: \(hips.rotation)")
        print("[\(time)] Hips translation: \(hips.translation)")
    }
}
```

### 2. Export Animation Data for Comparison

Create a test that exports animation samples to JSON:

```swift
func exportAnimationData(clip: AnimationClip, times: [Float]) -> [[String: Any]] {
    var frames: [[String: Any]] = []

    for time in times {
        var frame: [String: Any] = ["time": time]

        for track in clip.jointTracks {
            let (rot, trans, scale) = track.sample(at: time)
            frame["\(track.bone)_rotation"] = rot.map { [$0.imag.x, $0.imag.y, $0.imag.z, $0.real] }
            frame["\(track.bone)_translation"] = trans.map { [$0.x, $0.y, $0.z] }
        }

        frames.append(frame)
    }

    return frames
}
```

### 3. Visual Comparison

Record video of both VRMMetalKit and UniVRM playing the same animation and compare frame-by-frame.

---

## Expected Results

With `applyRetargeting = false` (default), VRMA animations should now be **identical** to UniVRM playback because:

1. ✅ No rest pose retargeting is applied (matches UniVRM behavior)
2. ✅ Quaternion SLERP uses shortest path (same as Unity)
3. ✅ Animation data is applied directly to bones

If there are still differences, enable debug logging and check:
- Whether coordinate system conversion is needed (`convertCoordinateSystem = true`)
- Whether the VRMA file itself is in the correct coordinate system
- Whether bone hierarchy/parent transforms are propagating correctly

---

## Files Modified

- `Sources/VRMMetalKit/Animation/VRMAnimationLoader.swift`
  - Added `applyRetargeting` parameter (default `false`)
  - Added `convertCoordinateSystem` parameter (default `false`)
  - Added `convertUnityToMetalRotation()` helper function
  - Added debug logging throughout
  - Updated `processHumanoidTrack()` and `processNonHumanoidTrack()` signatures
  - Updated `makeRotationSampler()` to support both flags

---

## Next Steps

1. **Test with real VRMA files**: Load actual VRMA animations and compare with UniVRM
2. **Enable debug logging**: Use the flags to see detailed information about retargeting and interpolation
3. **Compare specific bones**: Focus on hips, spine, and head for initial comparison
4. **Record test data**: Export animation samples from both systems for numerical comparison
5. **Adjust flags as needed**: Try different combinations of `applyRetargeting` and `convertCoordinateSystem`

---

## Contact Points in Code

**VRMMetalKit:**
- `VRMAnimationLoader.swift:52` - `loadVRMA()` function with new parameters
- `VRMAnimationLoader.swift:391` - `makeRotationSampler()` with retargeting logic
- `VRMAnimationLoader.swift:461` - `convertUnityToMetalRotation()` coordinate conversion
- `VRMAnimationLoader.swift:500` - Quaternion SLERP with shortest path

**UniVRM (for reference):**
- `VrmAnimationImporter.cs:27` - Coordinate system handling
- `VrmAnimationImporter.cs:200-250` - No retargeting for VRMA

---

*This document is based on the VRMA Animation Debugging Guide and addresses the critical and high-priority issues identified therein.*
