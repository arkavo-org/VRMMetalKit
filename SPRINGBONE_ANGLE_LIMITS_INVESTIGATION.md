# SpringBone Angle Limits Investigation Report

**Issue:** #67 - Verify VRMMetalKit's XPBD SpringBone physics implementation of angle limits
**Date:** 2025-11-18
**Status:** ❌ **Not Implemented** (and NOT required by VRM specification)

## Executive Summary

VRMMetalKit's XPBD-based SpringBone physics **does not implement angle limits** (pitch/yaw constraints). However, this is **compliant with the official VRM specification** as angle limits are **not part of VRM 1.0 or VRM 0.0 specifications**.

Angle limits appear to be a **UniVRM-specific extension** not required for VRM compliance.

## Detailed Findings

### 1. VRMMetalKit Implementation Status

#### ❌ No Angle Limit Support

**Data Structures** (`Sources/VRMMetalKit/Core/VRMTypes.swift:378-389`):
```swift
public struct VRMSpringJoint {
    public var node: Int
    public var hitRadius: Float = 0.0
    public var stiffness: Float = 1.0
    public var gravityPower: Float = 0.0
    public var gravityDir: SIMD3<Float> = [0, -1, 0]
    public var dragForce: Float = 0.4
    // ❌ No pitch field
    // ❌ No yaw field
    // ❌ No anglelimitType field
}
```

**GPU Parameters** (all `SpringBone*.metal` shaders):
```metal
struct BoneParams {
    float stiffness;
    float drag;
    float radius;
    uint parentIndex;
    float gravityPower;
    float3 gravityDir;
    // ❌ No pitch
    // ❌ No yaw
    // ❌ No angle limit fields
}
```

**Constraint System** (`SpringBoneComputeSystem.swift`, `SpringBoneDistance.metal`):
- ✅ Distance constraints (prevent over-stretching)
- ✅ Sphere collision detection
- ✅ Capsule collision detection
- ✅ Gravity and drag forces
- ❌ No angle limit constraints

**Extension Parser** (`VRMExtensionParser.swift`):
- No parsing of angle limit fields from VRM files
- Only parses: hitRadius, stiffness, gravityPower, gravityDir, dragForce

### 2. VRM Specification Compliance

#### VRM 1.0 Specification (VRMC_springBone-1.0)

**Official Parameters:**
- `hitRadius` - Collision detection radius
- `stiffness` - Rigidity/resistance to deformation
- `gravityPower` - Strength of gravity effect
- `gravityDir` - Direction of gravity influence (normalized vector)
- `dragForce` - Resistance to motion

**Status:** ❌ **No angle limits in specification**

**Source:** https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_springBone-1.0/README.md

#### VRM 0.0 Specification

**Official Parameters:**
- `center` - Reference node for spring bone center
- `dragForce` - Resistance to motion
- `gravityDir` - Direction of gravity influence
- `gravityPower` - Strength of gravity effect
- `hitRadius` - Collision detection radius
- `stiffness` - Rigidity

**Status:** ❌ **No angle limits in specification**

**Source:** https://github.com/vrm-c/vrm-specification/blob/master/specification/0.0/README.md

### 3. UniVRM Implementation (Reference Only)

UniVRM appears to have angle limit fields in `VRM10SpringBoneJoint.cs`:
```csharp
[SerializeField, Range(0, Mathf.PI)]
public float m_pitch = Mathf.PI;

[SerializeField, Range(0, Mathf.PI / 2)]
public float m_yaw = 0;

public UniGLTF.SpringBoneJobs.AnglelimitTypes m_anglelimitType;
```

**Analysis:** These fields are **not documented in the official VRM specification** and appear to be a **UniVRM-specific extension**.

### 4. XPBD vs Verlet Integration Differences

VRMMetalKit uses **XPBD** (Extended Position-Based Dynamics) while UniVRM uses **Verlet integration**:

#### XPBD Approach (VRMMetalKit)
- Position-based constraint solving
- Fixed timestep (120Hz substeps by default)
- Constraints: distance, collision
- Natural motion through physics simulation
- **Could theoretically add angle constraints** as additional constraint passes

#### Verlet Approach (UniVRM)
- Velocity-based integration
- Explicit angle limiting after position update
- Angle limits enforce cone constraints around parent bone
- **More straightforward to add explicit angle clamps**

**Both approaches can support angle limits**, but implementation differs:
- XPBD: Add as position constraint (requires iterative solving)
- Verlet: Add as rotation clamp (simpler, done post-integration)

## Conclusions

### ✅ VRMMetalKit is VRM-Compliant

VRMMetalKit correctly implements all **required** VRM 1.0 SpringBone parameters:
- ✅ hitRadius
- ✅ stiffness
- ✅ gravityPower
- ✅ gravityDir
- ✅ dragForce

### ❌ Angle Limits Are Not Implemented

VRMMetalKit does **not** implement angle limits because:
1. They are not part of the VRM 1.0 specification
2. They are not part of the VRM 0.0 specification
3. They appear to be a UniVRM-specific extension
4. No VRM files (conforming to spec) would contain these fields

### ⚠️ Compatibility Consideration

If users export VRM files from UniVRM with angle limits enabled, those limits will be **ignored** by VRMMetalKit. This may result in:
- More exaggerated springbone motion
- Hair/clothing moving beyond intended ranges
- Different visual appearance compared to UniVRM

## Recommendations

### Option 1: Document as Intentional (Recommended)

**Action:** Update documentation to clarify that VRMMetalKit is VRM 1.0 compliant and does not support UniVRM-specific extensions.

**Rationale:**
- Maintains clean spec compliance
- Avoids proprietary extensions
- XPBD physics may naturally constrain motion through proper parameter tuning
- Collision shapes can be used to limit motion ranges

### Option 2: Implement as Optional Extension

**Action:** Add angle limit support as an **optional, non-standard extension** for UniVRM compatibility.

**Implementation:**
1. Add optional fields to `VRMSpringJoint`:
   ```swift
   public var pitch: Float? = nil  // Range: [0, π]
   public var yaw: Float? = nil    // Range: [0, π/2]
   public var anglelimitType: VRMAngleLimitType? = nil
   ```

2. Extend GPU `BoneParams` struct (add to unused padding)

3. Add angle constraint pass in XPBD pipeline (after distance constraint)

4. Parse from VRM files if present (gracefully ignore if missing)

5. Clearly document as **non-standard extension**

**Effort:** Medium (3-5 days for complete implementation + testing)

**Risk:** Creates divergence from VRM specification

### Option 3: Alternative Approaches

Users can achieve similar constraint behavior using:
1. **Collision shapes** - Add capsule/sphere colliders to limit range of motion
2. **Stiffness tuning** - Higher stiffness reduces swing range
3. **Center bones** - Proper center configuration constrains motion
4. **Shorter rest lengths** - Limits maximum displacement

## Test Coverage

### Current Tests
- ✅ Basic SpringBone physics simulation
- ✅ Collision detection (spheres, capsules)
- ✅ Distance constraints
- ✅ Gravity and drag forces

### Missing Tests (if angle limits implemented)
- ❌ Pitch constraint enforcement
- ❌ Yaw constraint enforcement
- ❌ Angle limit types (cone, ellipse, etc.)
- ❌ Compatibility with UniVRM-exported models

## References

1. **VRM 1.0 SpringBone Spec:** https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_springBone-1.0/README.md
2. **VRM 0.0 Spec:** https://github.com/vrm-c/vrm-specification/blob/master/specification/0.0/README.md
3. **VRMMetalKit SpringBone Implementation:**
   - `Sources/VRMMetalKit/Core/VRMTypes.swift:378-389`
   - `Sources/VRMMetalKit/SpringBoneComputeSystem.swift`
   - `Sources/VRMMetalKit/Shaders/SpringBone*.metal`

## Code Locations Verified

✅ Checked all files mentioned in issue #67:
- `SpringBoneComputeSystem.swift` - No angle limit handling
- `SpringBone*.metal` - No angle limit constraints
- `VRMTypes.swift` - No pitch/yaw fields in VRMSpringJoint

## Next Steps

1. **Close issue #67** with findings documented
2. **Update README** or documentation to clarify VRM 1.0 compliance
3. **Optional:** Create new issue for UniVRM-specific extension support (if desired)
4. **Optional:** Add documentation on achieving angle-limit-like behavior using colliders

---

**Investigation completed by:** Claude Code
**Investigation date:** 2025-11-18
**Conclusion:** VRMMetalKit is VRM-compliant. Angle limits are a non-standard UniVRM extension.
