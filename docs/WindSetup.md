# Wind Setup Guide

This guide explains how to configure wind effects for VRM spring bones in apps using VRMMetalKit.

## Overview

VRMMetalKit's wind system provides natural, directional wind that affects hair and clothing spring bones. The system features:

- **Steady directional wind** with organic gust variations (not back-and-forth oscillation)
- **Per-bone wind influence** to exclude body physics from wind effects
- **Automatic detection** of body springs (breast/bosom) that shouldn't be affected by wind

---

## Basic Setup

### 1. Configure Wind Parameters

After loading a VRM model, configure wind through `springBoneGlobalParams`:

```swift
guard var params = model.springBoneGlobalParams else { return }

// Enable wind
params.windAmplitude = 60.0      // Strength (scaled for physics)
params.windFrequency = 2.0       // Gust variation speed
params.windDirection = simd_normalize(SIMD3<Float>(1, 0, 0.3))  // Direction
params.windPhase = 0.0           // Time accumulator (update each frame)

model.springBoneGlobalParams = params
```

### 2. Update Wind Phase Every Frame

**Critical**: You must increment `windPhase` each frame in your render loop. If `windPhase` stays at zero, `sin(0) = 0` and wind force will be zero.

```swift
// In your draw/render method
func draw(in view: MTKView) {
    let delta = Float(1.0 / 60.0)  // Or actual frame delta time

    if windEnabled, var params = model.springBoneGlobalParams {
        windTime += delta
        params.windPhase = windTime
        model.springBoneGlobalParams = params
    }

    // ... rest of rendering
}
```

---

## Parameter Reference

| Parameter | Type | Description | Typical Range |
|-----------|------|-------------|---------------|
| `windAmplitude` | Float | Wind force strength | 40-120 (after scaling) |
| `windFrequency` | Float | Gust variation speed | 1.5-3.0 |
| `windPhase` | Float | Time accumulator | Increment by `delta` each frame |
| `windDirection` | SIMD3<Float> | Normalized wind direction | Unit vector, e.g. `(1, 0, 0)` |

### Wind Direction Examples

```swift
// Wind from the left (character's perspective)
params.windDirection = simd_normalize(SIMD3<Float>(1, 0, 0))

// Wind from behind with slight leftward angle
params.windDirection = simd_normalize(SIMD3<Float>(0.3, 0, 1))

// Wind from front-right
params.windDirection = simd_normalize(SIMD3<Float>(-0.7, 0, -0.7))
```

---

## Amplitude Scaling

The physics shader multiplies wind force by `dtSub²` (approximately 0.00007 at 120Hz substeps). This means raw amplitude values need to be scaled up significantly for visible effects.

### Recommended Scaling

Map user-friendly UI values (1-10) to physics values (20-200):

```swift
// UI slider value (1-10 range)
let uiWindStrength: Float = 5.0

// Scale for physics engine
let physicsAmplitude = uiWindStrength * 20.0
params.windAmplitude = physicsAmplitude
```

| UI Value | Physics Amplitude | Effect |
|----------|-------------------|--------|
| 1 | 20 | Light breeze |
| 3 | 60 | Gentle wind |
| 5 | 100 | Moderate wind |
| 7 | 140 | Strong wind |
| 10 | 200 | Very strong wind |

---

## Wind Behavior

### Natural Gusts

The shader uses a multi-frequency sine combination for organic wind variation:

```metal
float gust1 = sin(frequency * time);
float gust2 = sin(frequency * time * 1.7 + 1.3);
float gust3 = sin(frequency * time * 0.5 + 2.7);
float gustFactor = 0.6 + 0.25 * gust1 + 0.1 * gust2 + 0.15 * gust3;
```

This produces:
- Wind always blowing in the configured direction (no reversal)
- Intensity varying between ~30% and ~120% of amplitude
- Natural, non-repetitive gust patterns

### Per-Bone Wind Influence

Each spring bone has a `windInfluence` factor (0.0 to 1.0):
- `1.0` = Full wind effect (hair, clothing, accessories)
- `0.0` = No wind effect (body physics)

### Automatic Body Physics Detection

VRMMetalKit derives `windInfluence` from each joint's `dragForce` property (a VRM standard field):

| dragForce | windInfluence | Example |
|-----------|---------------|---------|
| < 0.15 | 0.0 | Body physics (breast ~0.05) |
| 0.15 - 0.35 | 0.0 - 1.0 | Gradual transition |
| > 0.35 | 1.0 | Hair (~0.40), clothing |

This approach uses physics properties rather than spring names, making it:
- **Reliable**: Works with any VRM regardless of naming conventions
- **Physically correct**: `dragForce` represents air resistance - high drag catches wind, low drag doesn't
- **Smooth**: Gradual transition prevents harsh cutoffs

---

## Complete Implementation Example

```swift
class Renderer: NSObject, MTKViewDelegate {
    var model: VRMModel?

    // Wind state
    var windEnabled = false
    var windStrength: Float = 3.0  // UI value (1-10)
    var windDirection = SIMD3<Float>(1, 0, 0.3)
    private var windTime: Float = 0

    /// Call when wind settings change
    func updateWind() {
        guard let model = model,
              var params = model.springBoneGlobalParams else { return }

        if windEnabled {
            params.windAmplitude = windStrength * 20.0  // Scale for physics
            params.windDirection = simd_normalize(windDirection)
            params.windFrequency = 2.0
            params.windPhase = windTime
        } else {
            params.windAmplitude = 0
            windTime = 0  // Reset phase when disabled
        }

        model.springBoneGlobalParams = params
    }

    func draw(in view: MTKView) {
        guard let model = model else { return }

        let delta: Float = 1.0 / 60.0  // Or compute actual delta

        // Update wind phase each frame (critical!)
        if windEnabled, var params = model.springBoneGlobalParams {
            windTime += delta
            params.windPhase = windTime
            model.springBoneGlobalParams = params
        }

        // ... animation updates, rendering, etc.
    }
}
```

---

## Troubleshooting

### Wind Has No Effect

1. **Check `windPhase` is updating**: Must increment each frame
2. **Check `windAmplitude`**: Should be 40+ after scaling
3. **Check model has spring bones**: Not all VRM models have physics
4. **Verify `windInfluence`**: Body springs have 0.0 by design

### Wind Oscillates Back and Forth

This was the old behavior (pre-0.6.1). Update to latest VRMMetalKit for steady directional wind with gusts.

### Body Parts Affected by Wind

Wind influence is derived from `dragForce`. Body physics typically have low drag (~0.05) and are automatically excluded. If a spring is incorrectly affected by wind, check its `dragForce` value in the VRM file - values below 0.15 will have zero wind influence.

---

## Version History

- **0.6.1**: Natural gust pattern, per-bone wind influence, automatic body physics exclusion
- **0.6.0**: Basic wind support with sine oscillation
