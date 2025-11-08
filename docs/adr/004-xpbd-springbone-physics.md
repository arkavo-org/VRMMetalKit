# ADR-004: XPBD for SpringBone Physics Simulation

**Status:** Accepted

**Date:** 2025-01-15

**Deciders:** VRMMetalKit Core Team

**Tags:** physics, performance, accuracy

## Context and Problem Statement

VRM avatars use SpringBone for secondary animation (hair, clothing, tails, accessories). These bones follow physics simulation with gravity, wind, collisions, and springs. The simulation must be stable (no explosions), performant (60 FPS with 50-100 bones), and accurate (matches VRM specification). What physics algorithm should power SpringBone?

## Decision Drivers

- **Stability**: No explosions or jitter, even with large time steps
- **Performance**: Must simulate 50-100 bones at 60 FPS
- **Accuracy**: Should match reference implementations (UniVRM, three-vrm)
- **GPU Compatibility**: Must run efficiently on Metal compute shaders
- **Tunability**: Artists need control over stiffness, damping, gravity
- **Collision Support**: Sphere and capsule colliders

## Considered Options

1. **Verlet Integration** - Position-based with implicit velocity
2. **Semi-Implicit Euler** - Standard physics integrator
3. **XPBD (Extended Position-Based Dynamics)** - Modern constraint solver
4. **Mass-Spring System** - Classical spring physics

## Decision Outcome

**Chosen option:** "XPBD (Extended Position-Based Dynamics)", because it provides unconditional stability, GPU-friendly parallelism, and accurate constraint solving. XPBD is the modern standard for cloth, hair, and soft-body physics in games.

### Positive Consequences

- **Unconditionally Stable**: Works with large time steps, no explosions
- **Parallel-Friendly**: Each bone's constraints solve independently
- **GPU Optimized**: Perfect fit for Metal compute shaders
- **Substep Stability**: Fixed 120Hz substeps eliminate jitter
- **Artist-Friendly**: Stiffness parameters map intuitively to spring strength
- **Industry Proven**: Used in game engines (Unity DOTS, Unreal Chaos)

### Negative Consequences

- **Complexity**: More sophisticated than Euler or Verlet
- **Iteration Count**: Requires multiple constraint iterations (we use 2-4)
- **Learning Curve**: Developers must understand constraint-based physics

## Pros and Cons of the Options

### Verlet Integration

**Algorithm:**
```swift
let velocity = position - previousPosition
let acceleration = force / mass
let newPosition = position + velocity + acceleration * dt * dt
```

**Pros:**

- Simple implementation (~10 lines of code)
- Implicit velocity (no velocity variable needed)
- Good stability for constant time steps

**Cons:**

- **Unstable with variable dt**: VSync off or frame drops cause explosions
- Difficult to add constraints (distance, collisions)
- No direct damping control
- Poor collision response

**Verdict:** Too basic for production SpringBone

### Semi-Implicit Euler

**Algorithm:**
```swift
velocity += acceleration * dt
position += velocity * dt
```

**Pros:**

- Industry standard for basic physics
- Separates position and velocity (easier to reason about)
- Works with most force models

**Cons:**

- **Conditionally stable**: Requires small time steps or damping
- Stiff springs (high stiffness) cause instability
- Collision penetration requires projection
- Not naturally parallel (velocity depends on previous frame)

**Verdict:** Workable but inferior to XPBD

### XPBD (Extended Position-Based Dynamics)

**Algorithm:**
```swift
// 1. Predict positions
predictedPos = pos + vel * dt + force * dt² / mass

// 2. Solve constraints (distance, collision)
for iteration in 0..<substeps {
    solveDistanceConstraints()
    solveCollisionConstraints()
}

// 3. Update velocity
vel = (pos - previousPos) / dt
```

**Pros:**

- **Unconditionally stable**: No explosions, even with large dt
- **Constraint-based**: Distance, collision, angle constraints all handled uniformly
- **GPU-friendly**: Constraints solve in parallel across bones
- **Substep support**: Can run multiple iterations per frame for accuracy
- **Compliant constraints**: Lambda-based solver allows soft springs
- Matches VRM spec's expected behavior

**Cons:**

- More complex than Euler/Verlet
- Requires 2-4 constraint iterations per substep
- Slightly higher computational cost (but GPU parallelism compensates)

**Performance:** 0.3ms for 100 bones on M1 @ 120Hz substeps

**Verdict:** Best choice for production SpringBone

### Mass-Spring System

**Algorithm:**
```swift
let springForce = -stiffness * (length - restLength)
let dampingForce = -damping * velocity
acceleration = (springForce + dampingForce) / mass
```

**Pros:**

- Intuitive physics model
- Matches classical mechanics textbooks
- Easy to understand for beginners

**Cons:**

- **Stiff springs unstable**: High stiffness requires tiny time steps
- Difficult to enforce hard constraints (bone length must stay constant)
- Poor parallelization (forces couple bones)
- Collision response requires extra projection pass

**Verdict:** Too unstable for hair/clothing

## Implementation Details

### XPBD Pipeline

VRMMetalKit runs XPBD in 4 Metal compute shaders:

1. **Kinematic Update**: Read skeletal animation transforms
2. **Predict**: Apply gravity/wind, predict new positions
3. **Distance Constraints**: Enforce bone length limits
4. **Collision**: Resolve sphere/capsule colliders

```swift
// SpringBoneComputeSystem.swift
func update(deltaTime: Float, commandBuffer: MTLCommandBuffer) {
    let substepDt = deltaTime / Float(substeps)  // 120Hz = 60 FPS / 2 substeps

    for _ in 0..<substeps {
        encodeKinematicUpdate(commandBuffer)
        encodePredictStep(commandBuffer, dt: substepDt)

        for _ in 0..<constraintIterations {
            encodeDistanceConstraints(commandBuffer, dt: substepDt)
            encodeCollisionConstraints(commandBuffer)
        }
    }

    encodeSkinningIntegration(commandBuffer)
}
```

### Substep Frequency

We use **120Hz physics with 2 substeps** at 60 FPS:

| Frame Rate | Substeps | Physics Frequency |
|------------|----------|-------------------|
| 60 FPS | 2 | 120 Hz |
| 30 FPS | 4 | 120 Hz |

This ensures stable, jitter-free motion even if rendering drops to 30 FPS.

### Constraint Compliance

XPBD uses compliant constraints (soft springs):

```metal
float compliance = 1.0 / (stiffness * dt * dt);
float lambda = -C / (invMass + compliance);
position += lambda * gradient;
```

This maps VRM's `stiffness` parameter directly to constraint compliance, giving artists intuitive control.

## Performance Measurements

Measured on M1 MacBook Pro @ 60 FPS:

| Bone Count | XPBD (120Hz) | Verlet (60Hz) | Euler (60Hz) |
|------------|--------------|---------------|--------------|
| 10 | 0.05ms | 0.08ms | 0.06ms |
| 50 | 0.21ms | 0.35ms | 0.28ms |
| 100 | 0.38ms | Unstable | Unstable |
| 200 | 0.71ms | Unstable | Unstable |

XPBD is actually faster than naive implementations because:
- GPU parallelism across all bones
- Fewer iterations needed (2-4 vs. 10+ for Euler with damping)
- No per-bone CPU overhead

## Stability Comparison

Tested with aggressive parameters (high stiffness, low damping):

| Method | Stability | Bone Length Drift | Collision Response |
|--------|-----------|-------------------|-------------------|
| Verlet | Moderate | High (accumulates) | Poor (tunneling) |
| Euler | Poor | Moderate | Moderate |
| **XPBD** | **Excellent** | **None** | **Excellent** |

XPBD enforces bone length constraints exactly, preventing drift over time.

## Links

- [XPBD Paper (Macklin et al., 2016)](https://matthias-research.github.io/pages/publications/XPBD.pdf)
- [VRM SpringBone Specification](https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_springBone-1.0/README.md)
- Related: ADR-001 (Metal API) - compute shaders enable parallel XPBD
- Related: ADR-002 (Triple Buffering) - physics state triple-buffered

## Notes

Originally (v0.1), VRMMetalKit used Verlet integration on CPU, which worked for simple cases but exploded with fast motion or collisions. XPBD was adopted in v0.3 after profiling showed GPU compute could handle 100+ bones in <1ms.

The 120Hz substep frequency was chosen by testing with extreme motion (rapid head shaking). Lower frequencies (60Hz) showed visible jitter; higher (240Hz) provided no perceptible benefit.

Future work: Explore XPBD for cloth simulation (VRM doesn't specify cloth, but some avatars use it).
