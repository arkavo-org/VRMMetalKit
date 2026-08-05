# Skin-Mesh Coverage Oracle — Design

**Date:** 2026-08-05
**Status:** Ratified (brainstorm complete); five review blockers folded in 2026-08-05 (query set, pseudonormal classification, no proximity cutoff, fixture availability, predicate scope). Ready for planning.
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

**The runtime is less bare than "no hands" suggests, and that shapes the expected result.** `main`'s augmentor already ships lower-arm→hand capsules and palm spheres (`SpringBoneColliderAugmentor.swift:35,70,99`). Hands are covered at *palm* granularity, badly sized (3.0–3.8× authored, per `ColliderDimensionAudit`) but not absent. So the gate may well land **green at joint granularity while the render still shows finger-scale clipping**: a skirt joint can sit outside the palm sphere while the cloth *surface between* two joints passes through a finger.

The escalation is named now rather than discovered mid-slice-5: if joint-granularity queries come back clean on a pose that visibly clips, sample **K points along each parent→child joint segment** and run the same query at each. Same oracle, same tolerance, denser sampling. Slice 5 states which of the two it used and why.

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

The two-level initializer matters for testability: the synthetic-geometry tests in §9 build an oracle from triangles directly, so the maths is verified with **no rig, no fixture and no Metal device**. Only `build(model:)` needs any of those.

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

**Scope over materials, not over mesh names.** The prototype first selects the single mesh whose *name* contains `body`, then filters its primitives. That drops the Face mesh's `_SKIN` primitives entirely, and name-matching is exactly the fragile class this section exists to eliminate. The predicate ranges over **all meshes**, selecting primitives by material.

**Requirement:** a `BodySurfacePredicate` with its own test asserting, per fixture, the exact set of primitives included and excluded, by material name and vertex count. A material rename must fail that test rather than silently emptying the oracle (every joint reads clean) or flooding it (every joint reads penetrating).

The same test records two further properties per included primitive:

- **`primitiveType == .triangle`.** Strip topologies would otherwise be skipped in silence (`VRMGeometry.swift:173`), quietly shrinking the oracle.
- **Boundary-edge count.** A SKIN-only oracle is an *open* surface — eye sockets, and wherever VRoid deleted body geometry under garments (the same deletion the U leg-radius note works around). Signed classification is one-sided near an open boundary, so the count is recorded to make the openings visible rather than discovered as a mystery sign flip.

**Why SP1's target survives the openings:** hands are exposed geometry. They are not under a garment, so the body surface there is closed and the sign is well-defined exactly where this sub-project measures.

**Constraint — body surfaces only, never garments.** Beyond the self-penetration problem, a dress is a thin double-sided shell, and nearest-triangle-normal classification is unreliable on shells: the inside test depends on a consistent outward normal, which a garment surface does not reliably provide. The oracle covers closed body geometry. This is a property of the method, not a temporary limitation.

---

## 4. Corrections to the prototype

**Nearest triangle, classified by pseudonormal — not by face normal, and not by nearest vertex.** The prototype asks whether a point sits behind the nearest *vertex*'s normal, which misclassifies wherever tessellation is sparse. But a plain face normal is not the fix: when the closest point lands on a shared **edge or vertex** rather than a face interior — which is precisely what happens in concave creases, between fingers, at the palm webbing, at the wrist — the face normal of whichever adjacent triangle happens to be nearest flips the sign. The defect lives exactly where the naive classifier is unreliable.

The oracle computes the closest point on the nearest triangle by barycentric projection, then classifies against the **angle-weighted pseudonormal of the closest feature** (Bærentzen–Aanæs): face normal for a face-interior hit, angle-weighted average of adjacent faces for an edge or vertex hit. This is the standard signed-distance construction and is correct on concave geometry.

Using geometric face normals rather than authored vertex normals has a second benefit: it sidesteps the prototype's normal transform, which applies the upper-3×3 without the inverse-transpose and is therefore wrong under non-uniform scale.

**No proximity cutoff, at any layer.** The prototype drops candidates beyond 50 mm as a noise filter. Inherited into the spatial hash as a bounded search radius, that inverts the gate: a joint buried *deeper* than the cutoff finds no triangle and reads **clean**, making the worst defects the invisible ones. The search expands cells outward until a true nearest is found, with no distance gate, and ties broken deterministically by triangle index so slice 2's equivalence with brute force is exact rather than approximate.

**Measure the joint's surface, not its centre.** Spring joints carry `hitRadius`. The existing gate tests centres, so a joint 5 mm outside the skin with a 15 mm radius reads clean while the cloth surface is visibly buried. `penetration(of:radius:)` takes the radius and measures against the joint's surface. For fingers this is the difference between seeing the defect and not.

**Spatial acceleration.** The harness runs **150 frames at 30 fps and measures the settled second half — 75 frames** (`SpringBoneStressPosePenetrationTests.swift:43-44,139`). Naive nearest-triangle is then ~250 joints × ~25k skin triangles × 75 frames per fixture per pose, i.e. hundreds of millions of evaluations. A uniform spatial hash over triangle bounds, rebuilt per frame, reduces each query to a handful of cells. There is no realtime budget here; this code never ships. The target is seconds per gate run, not minutes.

---

## 5. Region-scaled tolerance

The existing gate uses a flat 5 mm (`penetrationTolerance`). That is larger than a fingertip's protrusion through cloth, so a flat 5 mm would blind the case this work exists to catch.

Tolerance is per region, where **region is the `VRMHumanoidBone` carried on the nearest triangle** — the dominant skinning bone of its vertices, as returned in `Penetration.region`:

| region | bones | tolerance | rationale |
|---|---|---|---|
| hands and fingers | `{left,right}Hand` and all 30 finger bones (`*Thumb*`, `*Index*`, `*Middle*`, `*Ring*`, `*Little*`) | 1 mm | see derivation below |
| all other body regions | everything else, including `nil` region | 5 mm | matches the existing gate, so numbers stay comparable |

A triangle whose vertices disagree on dominant bone takes the majority; a tie takes the tighter tolerance, since under-reporting a penetration is the failure mode that matters here.

**The 1 mm is derived, not asserted.** Slice 4 measures per-fixture finger radii with `SkinReferenceMeasureUtil`'s existing percentile method and cites the measurement in the constant. The working estimate is ~10–15 mm, which would make a flat 5 mm roughly a third of a finger, but an estimate is not a derivation — and this section exists because the previous drift threshold was picked for roundness and landed at twice its own maximum failure signal.

Each value is stated with its derivation in code. A threshold chosen for roundness is how the previous drift gate ended up set at twice its own maximum failure signal — passing unconditionally while appearing to guard.

---

## 6. The query set — which joints are asked, and which are never asked

"Every simulated joint" is wrong, and would make the gate useless on its first run.

**Bust chains are inside the chest by construction.** Both fixtures carry `Bust:6`. The instant the torso enters the oracle, those six joints report deep, persistent, entirely correct penetration — a guaranteed non-defect that swamps the millimetre-scale finger number this sub-project exists to surface.

**Tight chains turn resting contact into depth.** Sleeves hug the arm; the waistband sits against the torso. Radius-aware measurement (§4) converts any authored `hitRadius` exceeding true clearance into reported penetration. That is contact, not a defect.

**The query set is therefore explicit:**

- Start from the existing `clothJointNodeIndices` — springs named hair / skirt / hood / sleeve, chain roots exempt (`SpringBoneStressPosePenetrationTests.swift:57-79`).
- **Never Bust**, at any tier, for any pose.
- Report **per chain** as well as per region, so `Skirt` and `Sleeve` are separable in the output.
- Record contact-region baselines in the `XCTExpectFailure` message alongside the hand number, so a change in SP2/SP3 is attributable to the hand defect rather than to baseline drift in a resting-contact region.

The last point is what keeps the recorded failure meaningful: an assertion that merely fires is satisfied by *any* penetration anywhere. The message carries the region, the chain, the joint and the depth so the marker names a specific defect rather than a mood.

## 7. Where the gate executes, and the fixture it needs

`AvatarSample_U_1.0.vrm.glb` is **not in the repository**. `.gitignore` allowlists only `AvatarSample_A_{0.0,1.0}`, and `LICENSE-MODELS.md` documents only A. `requireFixture` throws `XCTSkip` on a missing file (`TestHelpers.swift:289`), so as specced, SP1's entire deliverable — and SP2/SP3's validation gate with it — degrades silently to a skip on any checkout but this machine.

Two facts about where tests actually run:

- **No GitHub Actions workflow runs `swift test`** (codeql, docs, lint, shaders only).
- **Xcode Cloud does run the package tests.** PR #380's six `StageExtractionGateTests` failures came from there. So the gate would execute in CI — and skip, invisibly, in the one place that runs it.

**Resolution: bundle U.** Its VRM 1.0 meta permits redistribution on the same terms as A, verified from the file:

```
AvatarSample_U_1.0: avatarPermission=everyone, allowRedistribution=true,
                    modification=allowModificationRedistribution,
                    commercialUsage=corporation,
                    licenseUrl=https://vrm.dev/licenses/1.0/
AvatarSample_A_1.0: identical terms
```

Add the `.gitignore` allowlist entry and a `LICENSE-MODELS.md` entry mirroring A's. If bundling is refused for a reason outside the licence, the fallback is an explicit env flag under which **absence fails rather than skips** — a gate that vanishes when its fixture does is worse than no gate, because it reports success.

## 8. The missing pose

`StressPose` currently offers `lookUp`, `armsRaised`, `armsCrossed`, `seatedDeepFlexion`. None places the hands at the sides, which is the reported visual: an avatar standing with her hands at her sides, fingers inside the dress.

Add `armsAtSides` to `StressPose` and `StressPoseFactory`. Rest is T-pose, and `armsRaised` is ±90° about Z from horizontal, so arms-at-sides is roughly ∓75–80° Z adduction with a slight elbow bend. The finger pose is the fixture's rest pose — SP1 does not articulate fingers, it only needs them beside the skirt. Fixture is `AvatarSample_U_1.0.vrm.glb`, the only fixture that simulates a skirt:

| fixture | spring chains |
|---|---|
| AvatarSample_A | Bust 6, Hair 31, Hood 3, HoodString 6 — **no skirt** |
| AvatarSample_U | **Skirt 120**, Sleeve 60, TopsUpperArm 20, Hair 35, Bust 6, CatEar 6, CatTail 10 |

`AvatarSample_U` is promoted from limb fixture to first-class coverage fixture.

---

## 9. Testing

**Layer 1 — oracle math on synthetic geometry.** Built in code, no avatar and no fixture, no Metal.

- **Convex baseline** — unit cube and sphere. Centre reports depth ≈ radius; outside reports zero; just inside a face reports its exact distance; a radius-bearing query reports surface-relative depth.
- **Concave fixture, required** — two boxes forming a notch, so the closest point lands on a shared edge and on a vertex. A face-normal classifier flips sign here; the pseudonormal classifier (§4) does not. Cube and sphere are both convex and *structurally cannot* observe this failure — including only them would be the exact vacuity this section forbids, applied to itself.
- **Deep interior query** — a point far inside, past any plausible search radius, proving the absence of a proximity cutoff (§4).
- **Degenerate triangles** — zero-area skinned triangles are rejected by a cross-product epsilon rather than producing a NaN normal.

**Layer 2 — body-surface predicate.** Per fixture, assert the exact included and excluded primitive sets by material name and vertex count (§3).

**Layer 3 — the coverage gate.** `AvatarSample_U`, `armsAtSides`, every simulated joint against the mesh oracle, reported per region.

**Layer 3 lands failing, and that is the deliverable.** SP1's job is to convert "her hands look like they are in the dress" into a depth, a region, and a joint name. SP2 and SP3 move that number; SP1 only makes it visible.

To record it without a red CI, the assertion is wrapped in `XCTExpectFailure` carrying the measured depth and a pointer to #381. This has a property a skip does not: **when the penetration is genuinely fixed, `XCTExpectFailure` itself fails** — "expected failure not observed" — forcing removal of the marker rather than leaving a stale pass behind. It is the same mechanism as `ColliderDimensionAudit`'s stale-exemption assertion.

**Non-vacuity.** Every assertion here must be observed failing before it is trusted. The oracle's synthetic tests are run against a deliberately wrong inside-test; the gate is run with the oracle emptied. A gate that has never been seen to fail is not evidence — this session produced three green-but-meaningless tests, and one collider fix that passed every test while visibly splaying the avatar's hair.

---

## 10. Decomposition (task-gated slices)

Each slice ends with a gate that can be observed failing before it is trusted. A slice is not done because its code exists; it is done because its gate has been seen to discriminate.

**Slice 1 — oracle maths, no rig.** `Triangle`, `init(triangles:)`, closest-point-on-triangle, signed classification, `penetration(of:radius:)`. Gate: synthetic cube and sphere (§9 layer 1), including the radius-aware case. Verified non-vacuous by running against a deliberately inverted inside-test. No Metal, no fixture.

**Slice 2 — spatial hash.** Acceleration over triangle bounds. Gate: identical results to slice 1's brute force on the same synthetic inputs — the equivalence set must include a **deeply interior** query (torso-centre class), not only near-surface points, since a bounded search radius agrees with brute force everywhere except exactly where it breaks — plus a runtime assertion that the gate completes in seconds on a real fixture. Correctness is slice 1's; this slice only buys speed and must not change an answer.

**Slice 3 — body-surface predicate + rig build.** `BodySurfacePredicate`, `build(model:)`, LBS skinning from live matrices. `build(model:)` asserts morph weights are zero — valid today because `StressPoseFactory.clip` emits joint tracks only, and a silent morph would move the surface out from under the oracle. Gate: per-fixture assertion of the exact included and excluded primitive sets by material name and vertex count (§3). This is the slice where a material rename must fail loudly.

**Slice 4 — the pose.** `armsAtSides` in `StressPose` / `StressPoseFactory`. Gate: the posed rig places the hands beside the hips, asserted on wrist world position relative to the hip, not eyeballed.

**Slice 5 — the coverage gate.** Wire slices 1–4 into an assertion over `AvatarSample_U`'s simulated joints, reported per region. Gate: it produces a specific depth, region and joint for the hand-into-skirt defect, recorded via `XCTExpectFailure` **pinned to the hand region** — an unpinned marker is satisfied by any penetration anywhere, including the resting-contact regions of §6. Verified non-vacuous by emptying the oracle, which must flip the expected failure to a pass and thereby fail the marker.

Slices 1 and 2 are independent of the rig and can be built and reviewed without any fixture present. Slice 5 depends on all four.

## 11. Acceptance

- `SkinMeshOracle` reports correct signed depth on synthetic geometry, verified in both directions.
- The body-surface predicate has an explicit per-fixture test.
- `armsAtSides` exists and poses `AvatarSample_U` with hands at the sides.
- The coverage gate reports a **specific depth, region and joint** for the hand/finger-into-skirt defect, recorded via `XCTExpectFailure`.
- Existing suites are untouched: `SpringBoneStressPosePenetrationTests`, `HairShoulder*`, `HairChest*`, `HairBreast*`, `SpringBoneColliderAugmentor*`, and the pipeline gates all keep their current numbers.
- `swift test --disable-sandbox` stays green, and the gate **executes rather than skips** wherever tests actually run (Xcode Cloud) — see §7.
- The `XCTExpectFailure` marker is pinned to the hand region and its message carries region, chain, joint, depth, and the contact-region baselines of §6.

## 12. Base and merge order

Both named dependencies — `HairBodyMeshPenetrationDiagnostic` and `ColliderDimensionAudit` — exist only on `fix/stagger-collision` (PR #380), not on `main`. SP1 must not start on a base that predates its own inputs. The plan pins one of: merge #380 first and branch from `main`, or branch from `fix/stagger-collision` and state the rebase. Bundling `AvatarSample_U_1.0.vrm.glb` (§7) lands on whichever base is chosen.

## 13. Follow-on

Sub-project 2 (fidelity: retire the `*Fraction` constants, size from authored colliders and mesh, empty `ColliderDimensionAudit.knownOversized`) and sub-project 3 (hierarchical colliders and per-finger capsules tiered on `SpringBoneQuality`) both validate against this gate. Sub-project 4 (chains for high-spread regions — chest 3.00, upperArm 4.06, lowerArm 4.23 p95/p05) likely folds into 3.
