# Procedural Balance Model — Design

**Date:** 2026-07-05
**Status:** Design approved; read-only sensor, first increment toward procedural staggering.
**Scope:** A pure, read-only sensor that, given a VRM model's current pose, computes its center of mass, its base of support (the foot support polygon), and a margin-of-stability metric. **No behavior change** — this increment is the sensor only, approved on unit tests, not a render.

**Depends on:** the VRM humanoid skeleton (`VRMModel`, `VRMHumanoidBone`, node world transforms). No Metal, no spring bones, no animation-layer plumbing.

---

## 1. Where this sits — the north star and this increment

**North star (agreed, not built here):** two colliding avatars *stagger and react to gravity while trying to stay upright*, done **fully procedurally / kinematically** — no rigid-body engine, no ragdoll. Gravity reaction is eased restoring curves, not real momentum. This stays inside the existing unidirectional pipeline (`kinematic animation → IK layers → secondary physics`) and animation-quality priorities, extending — not replacing — the shipped postural-yield layer (which is already the "torso stays upright" primitive).

**Decomposition (each its own spec → plan → build):**
1. **Balance model** — read-only sensor: CoM, support polygon, margin-of-stability. ← *this spec*
2. **Recovery stepping** — when the CoM leaves support, release a foot and re-plant it toward the CoM (also fixes the crowd moonwalk). Consumes the balance model.
3. **Collision → stagger impulse** — cross-avatar contact penetration becomes an eased horizontal shove on the root, which stepping + postural lean react to.
4. **Upright recovery** — ease the root/torso back to vertical after a stagger.

This increment is deliberately the smallest, safest foundation every later increment reads. It has **no consumers yet** and changes no rendered output; its value is a correct, well-tested sensor.

---

## 2. Placement & shape

A pure value-type `BalanceModel` in `Sources/VRMMetalKit/Animation/BalanceModel.swift` — Metal-free, mutates nothing, reads only humanoid node world positions (via `updateNodeTransforms`-populated `worldPosition`). One composed entry point plus separately-testable pure statics:

```swift
public enum BalanceModel {
    public enum Foot: Sendable { case left, right }

    /// Full balance state for the model's current pose.
    public static func evaluate(model: VRMModel,
                                groundY: Float = 0,
                                plantedFeet: Set<Foot> = [.left, .right]) -> BalanceState?

    // Pure, model-free helpers (each unit-testable in isolation):
    public static func centerOfMass(jointPositions: [VRMHumanoidBone: SIMD3<Float>]) -> SIMD3<Float>?
    public static func supportPolygon(footCorners: [SIMD2<Float>]) -> [SIMD2<Float>]
    public static func stabilityMargin(comGround: SIMD2<Float>, polygon: [SIMD2<Float>])
        -> (margin: Float, centroid: SIMD2<Float>)
}
```

`evaluate` returns `nil` when the model has no humanoid or lacks the minimum bones to define a CoM/support (documented below). `plantedFeet` is a parameter from day one (default both feet) so the later stepping increment can pass only the planted foot mid-step without an API change.

**Why split:** the geometry (weighted average, convex hull, point-in-polygon) is testable against synthetic inputs with no Metal device and no loaded model, so the bulk of the test suite is fast and deterministic; only the integration tests load a VRM.

---

## 3. Output — `BalanceState`

```swift
public struct BalanceState: Sendable {
    /// World-space center of mass.
    public let centerOfMass: SIMD3<Float>
    /// CoM projected to the ground plane (xz at `groundY`).
    public let comGround: SIMD2<Float>
    /// Base of support: xz convex hull of the planted feet's ground corners, CCW.
    public let supportPolygon: [SIMD2<Float>]
    /// Centroid of `supportPolygon`.
    public let supportCentroid: SIMD2<Float>
    /// Margin of stability: signed distance from `comGround` to the polygon boundary.
    /// `> 0` ⇒ CoM inside the base (stable), magnitude = distance to nearest edge.
    /// `< 0` ⇒ CoM outside (falling), magnitude = distance past the nearest edge.
    public let margin: Float
    /// Unit xz direction `normalize(comGround − supportCentroid)` — the direction of
    /// imbalance; a recovery step plants a foot along it. Zero when CoM ≈ centroid.
    public let imbalanceDirection: SIMD2<Float>
    /// Convenience: `margin > 0`.
    public var isBalanced: Bool { margin > 0 }
}
```

**Sign convention (fixed):** `margin` is the margin-of-stability — **positive inside** (larger = more stable), **negative outside** (falling). `imbalanceDirection` is what stepping and stagger consume; it is defined even when balanced (points from support centroid toward the CoM projection) so a consumer can always ask "which way is the CoM biased," and is the zero vector only when the CoM projects (near-)exactly onto the centroid.

---

## 4. The three computations

### 4.1 Center of mass — weighted humanoid segment masses
`CoM = Σ(bone.worldPosition × massFraction) / Σ(massFraction over bones present)`.

- A static `[VRMHumanoidBone: Float]` table of Dempster-derived segment mass fractions: pelvis + trunk (`hips`, `spine`, `chest`, `upperChest`) ≈ 0.50 total, `head` ≈ 0.08, each `upperLeg` ≈ 0.10, each `lowerLeg` ≈ 0.045, each `foot` ≈ 0.015, each `upperArm` ≈ 0.027, each `lowerArm` ≈ 0.016, each `hand` ≈ 0.006, `neck` ≈ 0.015 (full table finalized in implementation; the raw fractions sum to ≈ 1.0 over a complete skeleton).
- **Renormalize over bones actually present**: missing optional bones (`upperChest`, `toes`, etc.) drop out and the denominator is the sum of present fractions, so the CoM is unbiased regardless of which optional bones a rig authored.
- **Joint positions** (the bone's `worldPosition`) are used as the segment proxy in v1. Using segment *midpoints* (between a joint and its child) is more physically accurate and is a noted future refinement; joint positions are adequate for lean/imbalance detection and simpler to test.
- Correctly shifts when the torso leans or a limb swings — the property "stay upright" depends on.
- Requires at least `hips`; returns `nil` if absent.

### 4.2 Support polygon — foot ground corners → convex hull
For each **planted** foot, contribute 4 ground corners (heel/toe × left/right), then convex-hull all corners:

- **heel** ≈ `foot` bone world position, ground-projected to `(x, z)`.
- **toe** ≈ `toes` bone world position (ground-projected) when the rig has toes; otherwise `foot + footForward × footLength`, where `footForward` is the normalized horizontal heel→toe direction derived from the foot bone's forward axis and `footLength` a small default (≈ 0.15 m).
- **width**: offset heel and toe by `± footHalfWidth` (≈ 0.04 m) perpendicular to `footForward`, giving 4 corners per foot.
- **Convex hull** via Andrew's monotone chain over all planted-foot corners (CCW). Two feet → a quadrilateral base; a single planted foot (mid-step, later increments) → still a real polygon because each foot has width.
- Requires at least one planted foot with a resolvable `foot` bone; returns `nil` support otherwise (⇒ `evaluate` returns `nil`).

### 4.3 Margin & imbalance direction
- `comGround = (centerOfMass.x, centerOfMass.z)`.
- `supportCentroid` = average of polygon vertices.
- **Point-in-polygon** (winding/`sign`-of-cross for a convex CCW hull) decides the sign; **distance from `comGround` to the nearest polygon edge** gives the magnitude. Inside ⇒ `+dist`, outside ⇒ `−dist`.
- `imbalanceDirection = normalize(comGround − supportCentroid)` (zero vector if the norm is ~0).

---

## 5. Testing (the deliverable)

**Pure geometry (no Metal, no model):**
- **CoM:** weighted average of a synthetic `[bone: position]` set equals the hand-computed result; renormalization holds when a bone is omitted.
- **Support polygon:** convex hull of known corner sets is correct (order, vertices); degenerate/collinear inputs don't crash.
- **Margin:** large-positive when `comGround` is the centroid; decreases monotonically as the CoM moves toward an edge; crosses to negative outside; magnitude equals the true distance to the boundary; `imbalanceDirection` points from centroid to CoM with the correct sign.

**With a loaded VRM (AvatarSample_U, headless):**
- Rest pose ⇒ CoM sits over the foot midpoint and `margin > 0` (balanced).
- Rotating the spine to lean the torso ⇒ `centerOfMass` shifts measurably in the lean direction and `margin` drops (proves the CoM tracks pose, not just hips).
- Displacing the CoM outside the base (extreme lean / moved root) ⇒ `margin < 0` with `imbalanceDirection` pointing toward the lean.
- `plantedFeet = [.left]` ⇒ support polygon shrinks to the left foot and the margin/geometry reflect the single-foot base.

**Purity:**
- `evaluate` called twice on the same pose ⇒ bit-identical `BalanceState`.
- Asserts the model's node transforms/rotations are unchanged after `evaluate` (read-only).

---

## 6. Non-goals / deferred

- **Any behavior** — no stepping, no stagger, no upright control, no rendered change. Sensor only.
- **Segment-midpoint CoM** — v1 uses joint positions; midpoint weighting is a future accuracy refinement.
- **Non-flat ground / per-foot ground height** — v1 assumes a single horizontal `groundY`.
- **Dynamic mass (held objects, morph-driven shape)** — fixed anthropomorphic fractions only.
- **Consuming the model** — stepping (increment 2) and stagger (increment 3) are separate specs.
