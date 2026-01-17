# SpringBone Physics Guide

This guide covers the SpringBone physics system in VRMMetalKit, including collision group filtering, plane colliders, and constraint iteration tuning.

## Overview

VRMMetalKit uses GPU-accelerated XPBD (Extended Position-Based Dynamics) for hair, cloth, and accessory physics simulation. The system runs at 120Hz substeps on Metal compute shaders for stable, real-time performance.

---

## Collision Group Filtering

### What It Does

Collision groups let you control which colliders affect which spring bones. This is essential for realistic physics:

- **Hair** should collide with head/face colliders, not leg colliders
- **Skirts** should collide with leg colliders, not arm colliders
- **Accessories** can have their own dedicated colliders

### How It Works

Each spring chain has a `colliderGroups` array specifying which groups it interacts with. Each collider belongs to a collision group. At runtime, bones only collide with colliders in their assigned groups.

```
Spring Chain (hair) → colliderGroups: [0, 1]  → Collides with groups 0 and 1 only
Spring Chain (skirt) → colliderGroups: [2]    → Collides with group 2 only
```

### VRM File Setup

Collision groups are defined in the VRM file's `VRMC_springBone` extension:

```json
{
  "VRMC_springBone": {
    "colliders": [
      { "node": 5, "shape": { "sphere": { "radius": 0.05 } } },
      { "node": 6, "shape": { "sphere": { "radius": 0.04 } } },
      { "node": 10, "shape": { "capsule": { "radius": 0.08, "tail": [0, -0.3, 0] } } }
    ],
    "colliderGroups": [
      { "name": "head", "colliders": [0, 1] },
      { "name": "legs", "colliders": [2] }
    ],
    "springs": [
      {
        "name": "hair",
        "colliderGroups": [0],
        "joints": [...]
      },
      {
        "name": "skirt",
        "colliderGroups": [1],
        "joints": [...]
      }
    ]
  }
}
```

### Backward Compatibility

If a spring chain has no `colliderGroups` specified, it defaults to colliding with **all** colliders (mask = `0xFFFFFFFF`). Existing VRM files work unchanged.

### Performance Tip

Using collision groups improves performance by reducing unnecessary collision checks. A model with 50 bones and 20 colliders normally does 1000 collision tests. With proper grouping, this can drop to 200-300 tests.

---

## Plane Colliders

### What They Do

Plane colliders create infinite flat surfaces for collision. Common uses:

- **Floor planes** - prevent hair/cloth from clipping through the ground
- **Wall boundaries** - keep physics within bounds
- **Body planes** - simplified collision for torso/back

### Adding Plane Colliders Programmatically

Plane colliders aren't part of the standard VRM spec but can be added at runtime:

```swift
// Create a floor plane at Y=0
let floorPlane = PlaneCollider(
    point: SIMD3<Float>(0, 0, 0),      // Point on the plane
    normal: SIMD3<Float>(0, 1, 0),     // Normal pointing up
    groupIndex: 0                       // Collision group
)

// Add to the model's collider list
model.springBoneBuffers?.updatePlaneColliders([floorPlane])
```

### Plane Normal Direction

The normal defines which side of the plane is "solid":
- `normal: [0, 1, 0]` → Floor (prevents falling through)
- `normal: [0, -1, 0]` → Ceiling (prevents rising through)
- `normal: [0, 0, 1]` → Back wall
- `normal: [1, 0, 0]` → Side wall

### Use Cases

| Scenario | Plane Setup |
|----------|-------------|
| Character standing | Floor plane at feet level, normal up |
| Character against wall | Vertical plane behind character |
| Enclosed space | Multiple planes forming boundaries |

---

## Multi-Iteration Constraint Solving

### What It Does

XPBD constraint solving improves with multiple iterations. More iterations = stiffer constraints and better collision response, at the cost of GPU time.

### Configuration

The iteration count is set in `VRMConstants.Physics`:

```swift
public enum Physics {
    /// Number of XPBD constraint iterations per substep
    /// - 1: Fast, suitable for soft/bouncy physics
    /// - 2: Balanced (default), good for hair and light cloth
    /// - 3-4: Stiff, good for rigid accessories and tight cloth
    public static let constraintIterations: Int = 2
}
```

### When to Adjust

| Material Type | Recommended Iterations |
|--------------|------------------------|
| Soft flowing hair | 1 |
| Normal hair/cloth | 2 (default) |
| Stiff ponytails | 3 |
| Rigid accessories | 3-4 |
| Tight-fitting cloth | 3-4 |

### Performance Impact

Each iteration adds ~25% GPU overhead to physics. At 120Hz substeps:

| Iterations | Dispatches/Substep | Relative Cost |
|------------|-------------------|---------------|
| 1 | 4-5 | 1.0x |
| 2 | 6-8 | 1.25x |
| 3 | 8-11 | 1.5x |
| 4 | 10-14 | 1.75x |

On Apple Silicon (M1+), even 4 iterations stays well under 1ms per frame.

---

## Tuning Physics Parameters

### Per-Joint Parameters

Each joint in a spring chain has tunable parameters:

| Parameter | Range | Effect |
|-----------|-------|--------|
| `stiffness` | 0.0-1.0 | Higher = snappier return to rest pose |
| `dragForce` | 0.0-1.0 | Higher = more air resistance, slower movement |
| `gravityPower` | 0.0-2.0 | Multiplier for gravity (0 = floaty, 1 = normal, 2 = heavy) |
| `gravityDir` | normalized | Direction of gravity for this joint |
| `hitRadius` | 0.0+ | Collision sphere radius around the bone |

### Hair vs Cloth Guidelines

**Hair (bouncy, responsive):**
```
stiffness: 0.8-1.0
dragForce: 0.2-0.4
gravityPower: 0.3-0.5
hitRadius: 0.02-0.05
```

**Cloth (heavy, flowing):**
```
stiffness: 0.3-0.6
dragForce: 0.5-0.8
gravityPower: 0.8-1.2
hitRadius: 0.05-0.1
```

**Rigid accessories (minimal movement):**
```
stiffness: 0.9-1.0
dragForce: 0.8-0.9
gravityPower: 0.1-0.3
hitRadius: 0.01-0.03
```

---

## Debugging Physics

### Enable Physics Logging

Build with the `VRM_METALKIT_ENABLE_DEBUG_PHYSICS` flag:

```bash
swift build -Xswiftc -DVRM_METALKIT_ENABLE_DEBUG_PHYSICS
```

This logs:
- Substep counts and timing
- Collision group assignments
- Bone position updates

### Common Issues

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| Hair clips through head | Missing collision group | Add head colliders to hair's `colliderGroups` |
| Physics explodes | `gravityPower` too high or `stiffness` too low | Reduce gravity, increase stiffness |
| Physics too stiff | Too many iterations or high `stiffness` | Reduce `constraintIterations` or `stiffness` |
| Hair floats up | `gravityDir` pointing wrong way | Ensure `gravityDir` is `[0, -1, 0]` |
| No physics movement | `gravityPower = 0` on all joints | Set `gravityPower` to at least 0.3 |

---

## API Reference

### Key Types

```swift
// Bone physics parameters
struct BoneParams {
    var stiffness: Float
    var drag: Float
    var radius: Float           // hitRadius
    var parentIndex: UInt32
    var gravityPower: Float
    var colliderGroupMask: UInt32  // Bitmask of collision groups
    var gravityDir: SIMD3<Float>
}

// Collider types
struct SphereCollider {
    var center: SIMD3<Float>
    var radius: Float
    var groupIndex: UInt32
}

struct CapsuleCollider {
    var p0: SIMD3<Float>
    var p1: SIMD3<Float>
    var radius: Float
    var groupIndex: UInt32
}

struct PlaneCollider {
    var point: SIMD3<Float>
    var normal: SIMD3<Float>
    var groupIndex: UInt32
}

// Collider shape enum (for VRM loading)
enum VRMColliderShape {
    case sphere(offset: SIMD3<Float>, radius: Float)
    case capsule(offset: SIMD3<Float>, radius: Float, tail: SIMD3<Float>)
    case plane(offset: SIMD3<Float>, normal: SIMD3<Float>)
}
```

### Constants

```swift
VRMConstants.Physics.substepRateHz        // 120.0 Hz
VRMConstants.Physics.maxSubstepsPerFrame  // 10
VRMConstants.Physics.constraintIterations // 2
VRMConstants.Physics.defaultGravity       // [0, -9.8, 0]
```
