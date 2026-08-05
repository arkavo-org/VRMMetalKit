# Skin-Mesh Coverage Oracle — Design

**Date:** 2026-08-05
**Status:** Ratified (brainstorm complete); ready for planning.
**Issue:** #381, sub-project 1 of 4.

**Scope:** A test-only oracle that measures penetration against the **actual skinned body mesh** instead of hand-authored capsules, plus the coverage gate built on it. No runtime behaviour changes. Ships a *failing* measurement of a known visual defect — fingers and hands sinking into a simulated dress — so the later sub-projects have a number to move.

**Depends on:** `SpringBoneStressPosePenetrationTests` (the existing harness this gate joins — pose driving, offscreen render loop, `clothJointNodeIndices`), `StressPose` / `StressPoseFactory`, `HairBodyMeshPenetrationDiagnostic` (the prototype being promoted, on `fix/stagger-collision`), `ColliderDimensionAudit` (the sizing guard whose exemption table SP2 empties), and `AvatarSample_U_1.0.vrm.glb` as the only skirt-simulating fixture. Nothing here depends on runtime collider code, by design — see §1.

**Explicitly not shipped here:** collider sizing changes, per-finger colliders, hierarchical collision, chains for high-spread regions. Each of those is validated by this gate and specced separately.

---

## 1. Why the existing gate cannot see the defect

`SpringBoneStressPosePenetrationTests` measures simulated joints against `SkinReferenceOracle` — a hand-authored set of capsules and spheres committed as JSON per fixture. Both `avatar_a_skin_reference.json` and `avatar_u_skin_reference.json` contain **10 shapes across 9 bones**: head, left/right upper and lower arm, left/right upper and lower leg.

**No hands. No torso.** A skirt joint sitting inside a hand has no hand shape to be measured against, so a finger through a dress produces no signal at all. That is the exact failure the project wants to eliminate, and it is currently invisible.

Two further facts make extending the capsule oracle the wrong response:

- **It scales badly.** Per-finger ground truth is 30 bones × 2 fixtures = 60 hand-authored shapes, each needing a mitten-or-fingers judgement call.
- **It is losing its independence.** The oracle's value comes from being derived differently than the thing it checks: today it uses 70th-percentile perpendicular skin distance while the augmentor uses fraction-of-bone-length. Issue #381's sub-project 2 moves collider sizing to mesh measurement, converging both sides on one method. A coverage test whose ground truth is produced the same way as its subject confirms the technique, not the result.

The mesh itself has neither problem. It needs no authoring, it covers every body part the moment it exists, and it is ground truth rather than an approximation of it.

---

## 2. Architecture

One test-only type, built per posed frame:

```swift
struct SkinMeshOracle {
    /// Triangle-level init: the testable core, independent of any rig or Metal.
    init(triangles: [Triangle])
    /// Rig-level convenience: skins the body surface and calls the above.
    static func build(model: VRMModel) -> SkinMeshOracle?

    func penetration(of point: SIMD3<Float>, radius: Float) -> Penetration?
}

struct Triangle {
    let a, b, c: SIMD3<Float>        // world space
    let region: VRMHumanoidBone?     // dominant bone of the vertices, nil for synthetic
}

struct Penetration {
    let depth: Float                 // metres past the surface; > 0 means inside
    let region: VRMHumanoidBone?     // carried from the nearest triangle
    let surfacePoint: SIMD3<Float>
}
```

The two-level initializer matters for testability: the synthetic-geometry tests in §7 build an oracle from triangles directly, so the maths is verified with **no rig, no fixture and no Metal device**. Only `build(model:)` needs any of those.

Data flow per frame:

```
posed model
  → body-surface primitives (see §3)
  → LBS-skinned triangles in world space, from live node matrices
  → uniform spatial hash over triangle bounds
  → per simulated joint: nearest triangle → signed depth against the joint's SURFACE
  → worst depth, with its region and joint
```

**The prototype to promote.** `HairBodyMeshPenetrationDiagnostic` on branch `fix/stagger-collision` already does the core of this — it locates hair penetration into the skinned body mesh via the nearest skin vertex's normal, grouped by dominant bone. This design promotes that technique from scratch diagnostic to gate, with the three corrections in §4.

**What it does not touch.** `SkinReferenceOracle`, its two JSON fixtures, `SkinReferenceOracleIntegrityTests`, and every assertion calibrated against them stay exactly as they are. This is a new oracle for new assertions. No existing number moves.

---

## 3. The body-surface predicate

The single most failure-prone decision, and therefore a named, separately tested function rather than an inline `guard`.

The oracle must contain **surfaces that simulated cloth should be pushed out of**, and must exclude **surfaces that are themselves simulated**. Including a garment whose own joints are simulated makes those joints trivially "inside" it, and the gate fires on every frame for a non-defect.

The prototype's inline rule is `material name contains SKIN or CLOTH, and does not contain HAIR`. That is a reasonable start but is an unverified guess about two specific fixtures.

**Requirement:** a `BodySurfacePredicate` with its own test asserting, per fixture, the exact set of primitives included and excluded, by material name and vertex count. A material rename must fail that test rather than silently emptying the oracle (every joint reads clean) or flooding it (every joint reads penetrating).

**Constraint — body surfaces only, never garments.** Beyond the self-penetration problem, a dress is a thin double-sided shell, and nearest-triangle-normal classification is unreliable on shells: the inside test depends on a consistent outward normal, which a garment surface does not reliably provide. The oracle covers closed body geometry. This is a property of the method, not a temporary limitation.

---

## 4. Corrections to the prototype

**Nearest triangle, not nearest vertex.** The prototype asks whether a point sits behind the nearest *vertex*'s normal. That misclassifies near concavities and wherever tessellation is sparse — and fingers are exactly where geometry gets thin and small. The oracle computes the closest point on the nearest *triangle* by barycentric projection and classifies against the face normal.

**Measure the joint's surface, not its centre.** Spring joints carry `hitRadius`. The existing gate tests centres, so a joint 5 mm outside the skin with a 15 mm radius reads clean while the cloth surface is visibly buried. `penetration(of:radius:)` takes the radius and measures against the joint's surface. For fingers this is the difference between seeing the defect and not.

**Spatial acceleration.** Naive nearest-triangle is ~250 joints × ~25k skin vertices × 90 frames per fixture per pose — hundreds of millions of evaluations. A uniform spatial hash over triangle bounds, rebuilt per frame, reduces each query to a handful of cells. There is no realtime budget here; this code never ships. The target is seconds per gate run, not minutes.

---

## 5. Region-scaled tolerance

The existing gate uses a flat 5 mm (`penetrationTolerance`). That is larger than a fingertip's protrusion through cloth, so a flat 5 mm would blind the case this work exists to catch.

Tolerance is per region, where **region is the `VRMHumanoidBone` carried on the nearest triangle** — the dominant skinning bone of its vertices, as returned in `Penetration.region`:

| region | bones | tolerance | rationale |
|---|---|---|---|
| hands and fingers | `{left,right}Hand` and all 30 finger bones (`*Thumb*`, `*Index*`, `*Middle*`, `*Ring*`, `*Little*`) | 1 mm | finger radii are ~10–15 mm; 5 mm is a third of a finger and reads as a hand inside the garment |
| all other body regions | everything else, including `nil` region | 5 mm | matches the existing gate, so numbers stay comparable |

A triangle whose vertices disagree on dominant bone takes the majority; a tie takes the tighter tolerance, since under-reporting a penetration is the failure mode that matters here.

Each value is stated with its derivation in code. A threshold chosen for roundness is how the previous drift gate ended up set at twice its own maximum failure signal — passing unconditionally while appearing to guard.

---

## 6. The missing pose

`StressPose` currently offers `lookUp`, `armsRaised`, `armsCrossed`, `seatedDeepFlexion`. None places the hands at the sides, which is the reported visual: an avatar standing with her hands at her sides, fingers inside the dress.

Add `armsAtSides` to `StressPose` and `StressPoseFactory`. Fixture is `AvatarSample_U_1.0.vrm.glb`, the only fixture that simulates a skirt:

| fixture | spring chains |
|---|---|
| AvatarSample_A | Bust 6, Hair 31, Hood 3, HoodString 6 — **no skirt** |
| AvatarSample_U | **Skirt 120**, Sleeve 60, TopsUpperArm 20, Hair 35, Bust 6, CatEar 6, CatTail 10 |

`AvatarSample_U` is promoted from limb fixture to first-class coverage fixture.

---

## 7. Testing

**Layer 1 — oracle math on synthetic geometry.** A unit cube and a sphere constructed in code, no avatar and no fixture. A point at the centre reports depth ≈ radius; a point outside reports zero; a point just inside a face reports its exact distance; a query with a joint radius reports surface-relative depth. The oracle's correctness never depends on a rig being present, and these run without Metal.

**Layer 2 — body-surface predicate.** Per fixture, assert the exact included and excluded primitive sets by material name and vertex count (§3).

**Layer 3 — the coverage gate.** `AvatarSample_U`, `armsAtSides`, every simulated joint against the mesh oracle, reported per region.

**Layer 3 lands failing, and that is the deliverable.** SP1's job is to convert "her hands look like they are in the dress" into a depth, a region, and a joint name. SP2 and SP3 move that number; SP1 only makes it visible.

To record it without a red CI, the assertion is wrapped in `XCTExpectFailure` carrying the measured depth and a pointer to #381. This has a property a skip does not: **when the penetration is genuinely fixed, `XCTExpectFailure` itself fails** — "expected failure not observed" — forcing removal of the marker rather than leaving a stale pass behind. It is the same mechanism as `ColliderDimensionAudit`'s stale-exemption assertion.

**Non-vacuity.** Every assertion here must be observed failing before it is trusted. The oracle's synthetic tests are run against a deliberately wrong inside-test; the gate is run with the oracle emptied. A gate that has never been seen to fail is not evidence — this session produced three green-but-meaningless tests, and one collider fix that passed every test while visibly splaying the avatar's hair.

---

## 8. Decomposition (task-gated slices)

Each slice ends with a gate that can be observed failing before it is trusted. A slice is not done because its code exists; it is done because its gate has been seen to discriminate.

**Slice 1 — oracle maths, no rig.** `Triangle`, `init(triangles:)`, closest-point-on-triangle, signed classification, `penetration(of:radius:)`. Gate: synthetic cube and sphere (§7 layer 1), including the radius-aware case. Verified non-vacuous by running against a deliberately inverted inside-test. No Metal, no fixture.

**Slice 2 — spatial hash.** Acceleration over triangle bounds. Gate: identical results to slice 1's brute force on the same synthetic inputs, plus a runtime assertion that the gate completes in seconds on a real fixture. Correctness is slice 1's; this slice only buys speed and must not change an answer.

**Slice 3 — body-surface predicate + rig build.** `BodySurfacePredicate`, `build(model:)`, LBS skinning from live matrices. Gate: per-fixture assertion of the exact included and excluded primitive sets by material name and vertex count (§3). This is the slice where a material rename must fail loudly.

**Slice 4 — the pose.** `armsAtSides` in `StressPose` / `StressPoseFactory`. Gate: the posed rig places the hands beside the hips, asserted on wrist world position relative to the hip, not eyeballed.

**Slice 5 — the coverage gate.** Wire slices 1–4 into an assertion over `AvatarSample_U`'s simulated joints, reported per region. Gate: it produces a specific depth, region and joint for the hand-into-skirt defect, recorded via `XCTExpectFailure`. Verified non-vacuous by emptying the oracle, which must flip the expected failure to a pass and thereby fail the marker.

Slices 1 and 2 are independent of the rig and can be built and reviewed without any fixture present. Slice 5 depends on all four.

## 9. Acceptance

- `SkinMeshOracle` reports correct signed depth on synthetic geometry, verified in both directions.
- The body-surface predicate has an explicit per-fixture test.
- `armsAtSides` exists and poses `AvatarSample_U` with hands at the sides.
- The coverage gate reports a **specific depth, region and joint** for the hand/finger-into-skirt defect, recorded via `XCTExpectFailure`.
- Existing suites are untouched: `SpringBoneStressPosePenetrationTests`, `HairShoulder*`, `HairChest*`, `HairBreast*`, `SpringBoneColliderAugmentor*`, and the pipeline gates all keep their current numbers.
- `swift test --disable-sandbox` stays green.

## 10. Follow-on

Sub-project 2 (fidelity: retire the `*Fraction` constants, size from authored colliders and mesh, empty `ColliderDimensionAudit.knownOversized`) and sub-project 3 (hierarchical colliders and per-finger capsules tiered on `SpringBoneQuality`) both validate against this gate. Sub-project 4 (chains for high-spread regions — chest 3.00, upperArm 4.06, lowerArm 4.23 p95/p05) likely folds into 3.
