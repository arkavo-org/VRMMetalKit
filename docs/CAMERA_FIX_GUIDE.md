# Camera Position Fix for VRM Models

## Problem
VRM models appear backward (showing back instead of front) because the camera is positioned incorrectly relative to the model's forward direction.

## glTF/VRM Coordinate System

According to glTF 2.0 specification:
- **Right-handed coordinate system**
- **+Y** = Up
- **+Z** = Forward (front of model faces this direction)
- **-X** = Right

```
        +Y (Up)
         |
         |
         |
         +-------- +X (Left)
        /
       /
      +Z (Forward - model faces this way)
```

## The Issue

If the camera is positioned at `(0, 1.5, 3)` (positive Z), it's BEHIND the model, looking at the model's back.

## Solution for Muse App

### Option 1: Fix Camera Position (Recommended)

**Location**: `Muse/Muse/Camera/OrbitCamera.swift`

**Change the camera initialization:**

```swift
// BEFORE (Wrong - camera behind model)
let cameraPosition = SIMD3<Float>(0, 1.5, 3)

// AFTER (Correct - camera in front of model)
let cameraPosition = SIMD3<Float>(0, 1.5, -3)
```

**Or in camera preset:**

```swift
// In CameraPresets.swift
public static let bust = CameraPreset(
    distance: 1.5,
    // ... other properties ...
)

// The distance should be NEGATIVE to place camera at -Z
// Or the camera calculation should use -distance for Z coordinate
```

### Option 2: Rotate Model Root 180° Around Y

**Location**: `Muse/Muse/Renderer.swift`

**Add after model loads:**

```swift
private func loadVRMModel() async {
    // ... existing model loading code ...
    
    do {
        let loadedModel = try await VRMModel.load(from: modelURL, device: device)
        self.model = loadedModel
        
        // FIX: Rotate model 180° around Y-axis to face camera
        // This is needed because glTF models face +Z, but our camera is at +Z
        for (index, node) in loadedModel.nodes.enumerated() where node.parent == nil {
            // Apply 180° rotation around Y-axis to root nodes
            let rotation180Y = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
            
            // Combine with existing rotation
            node.rotation = simd_normalize(rotation180Y * node.rotation)
            node.updateLocalMatrix()
        }
        
        // Update world transforms after rotation
        for node in loadedModel.nodes where node.parent == nil {
            node.updateWorldTransform()
        }
        
        // ... rest of existing code ...
    }
}
```

## Testing the Fix

### Expected Results After Fix:

✅ **Model faces camera** (front visible, not back)
✅ **Arms in natural position** (not raised)
✅ **Legs move naturally** (no crossing or clipping)
✅ **Symmetric poses** (left/right correct)
✅ **Animations play correctly** (no distortion)

### Test Procedure:

1. Apply one of the fixes above
2. Build and run Muse app
3. Load a VRM model
4. Verify:
   - Model's front is visible
   - Character faces the camera
   - Animations play naturally
   - No leg crossing or clipping

## Why This Works

1. **Preserves Quaternion Validity**: Uses proper rotation math, not component negation
2. **Follows glTF Spec**: Respects the coordinate system definition
3. **Maintains Animation Integrity**: Doesn't corrupt bone rotations
4. **Simple and Clean**: Fixes the issue at the right level (camera/model orientation)

## Implementation Priority

**Recommended approach:**
1. Try Option 1 (camera position) first - it's cleaner
2. If camera position can't be changed, use Option 2 (model rotation)
3. Test with multiple VRM models to ensure consistency

## Additional Notes

- This fix works for ALL VRM models (they all follow glTF spec)
- No changes needed to VRMMetalKit animation code
- No changes needed to VRMA files
- The issue was in the viewer setup, not the data