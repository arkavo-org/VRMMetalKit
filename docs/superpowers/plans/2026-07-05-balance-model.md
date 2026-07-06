# Balance Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a pure, read-only balance sensor that computes a VRM avatar's center of mass, foot support polygon, and margin-of-stability from its current pose.

**Architecture:** One Metal-free value-type module `BalanceModel` composed of pure statics (weighted-segment CoM with parent-fold mass redistribution, convex-hull support polygon, point-in-polygon stability margin) plus a model-reading `evaluate` that assembles a `BalanceState`. No behavior change, no mutation — the deliverable is the sensor and its tests.

**Tech Stack:** Swift 6.2, `simd`, XCTest. No Metal in the module itself; integration tests load a VRM via a Metal device.

## Global Constraints

- Swift 6.2; targets macOS 26+, iOS 26+.
- New source files MUST carry the Apache 2.0 header (copy from any file in `Sources/VRMMetalKit/`).
- The module is pure: no Metal, no GPU, no mutation of the model. `evaluate` only reads `node.worldPosition` / `node.worldMatrix`.
- Tests run with `--disable-sandbox`. Model-loading tests require a Metal device and `throw XCTSkip` when absent (pattern: `guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }`).
- Sign convention (fixed): `margin > 0` ⇒ CoM inside the base of support (stable); `< 0` ⇒ outside (falling).
- Test fixture: use the repo helpers `getTestVRM10ModelPath()` + `try requireFixture(path, hint: testVRM10Filename)` and load with `VRMModel.load(from:device:options:)`, then `model.updateNodeTransforms()` — the established pattern in `Tests/VRMMetalKitTests/Animation/PosturalContactLayerTests.swift`.

---

## File Structure

- **Create** `Sources/VRMMetalKit/Animation/BalanceModel.swift` — the entire module: `BalanceModel` enum (statics + mass tables), `BalanceModel.Foot`, `BalanceState`. Built up across Tasks 1–5.
- **Create** `Tests/VRMMetalKitTests/Animation/BalanceModelTests.swift` — all tests, added to across Tasks 1–5.

One source file, one responsibility (balance sensing); it stays well under a few hundred lines.

---

### Task 1: Center of mass — mass table, parent-fold redistribution, weighted CoM

**Files:**
- Create: `Sources/VRMMetalKit/Animation/BalanceModel.swift`
- Test: `Tests/VRMMetalKitTests/Animation/BalanceModelTests.swift`

**Interfaces:**
- Produces:
  - `enum BalanceModel` with `static let massFractions: [VRMHumanoidBone: Float]`
  - `static let foldParent: [VRMHumanoidBone: VRMHumanoidBone]`
  - `static func effectiveFractions(present: Set<VRMHumanoidBone>) -> [VRMHumanoidBone: Float]`
  - `static func centerOfMass(jointPositions: [VRMHumanoidBone: SIMD3<Float>]) -> SIMD3<Float>?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/VRMMetalKitTests/Animation/BalanceModelTests.swift`:

```swift
//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import XCTest
import Metal
import simd
@testable import VRMMetalKit

final class BalanceModelTests: XCTestCase {

    // MARK: - Task 1: Center of mass

    func testMassFractionsSumToApproximatelyOne() {
        let total = BalanceModel.massFractions.values.reduce(0, +)
        XCTAssertEqual(total, 1.0, accuracy: 0.02, "segment fractions should sum to ~1.0")
    }

    func testCenterOfMassIsTheWeightedAverage() {
        // Two bones only, known fractions, known positions → hand-computed CoM.
        let joints: [VRMHumanoidBone: SIMD3<Float>] = [
            .hips: SIMD3<Float>(0, 1, 0),
            .head: SIMD3<Float>(0, 2, 0),
        ]
        let com = try! XCTUnwrap(BalanceModel.centerOfMass(jointPositions: joints))
        let fH = BalanceModel.massFractions[.hips]!
        let fHead = BalanceModel.massFractions[.head]!
        let expectedY = (1 * fH + 2 * fHead) / (fH + fHead)
        XCTAssertEqual(com.y, expectedY, accuracy: 1e-5)
        XCTAssertEqual(com.x, 0, accuracy: 1e-6)
    }

    func testCenterOfMassNilWhenHipsMissingOrSingleBone() {
        XCTAssertNil(BalanceModel.centerOfMass(jointPositions: [.head: .zero]),
                     "no hips ⇒ nil")
        XCTAssertNil(BalanceModel.centerOfMass(jointPositions: [.hips: .zero]),
                     "hips-only (bare point) ⇒ nil")
    }

    /// Parent-fold (design §4.1): dropping a SPLIT trunk bone folds its mass into the
    /// nearest present ancestor in-region, so limb fractions and the trunk total are
    /// invariant to trunk subdivision. A global renormalize would instead inflate the
    /// limbs — this test pins the difference.
    func testEffectiveFractions_upperChestFoldsIntoChest_limbsUnchanged() {
        let all = Set(BalanceModel.massFractions.keys)
        let full = BalanceModel.effectiveFractions(present: all)
        let noUC = BalanceModel.effectiveFractions(present: all.subtracting([.upperChest]))

        // upperChest's mass moved onto chest…
        XCTAssertEqual(noUC[.chest] ?? 0,
                       (full[.chest] ?? 0) + (BalanceModel.massFractions[.upperChest] ?? 0),
                       accuracy: 1e-6)
        // …limbs are untouched (a global renormalize would raise these)…
        XCTAssertEqual(noUC[.leftUpperLeg] ?? 0, full[.leftUpperLeg] ?? 0, accuracy: 1e-6)
        XCTAssertEqual(noUC[.rightUpperArm] ?? 0, full[.rightUpperArm] ?? 0, accuracy: 1e-6)
        // …and the trunk keeps its total.
        let trunk: [VRMHumanoidBone] = [.hips, .spine, .chest, .upperChest]
        let fullTrunk = trunk.reduce(Float(0)) { $0 + (full[$1] ?? 0) }
        let noUCTrunk = trunk.reduce(Float(0)) { $0 + (noUC[$1] ?? 0) }
        XCTAssertEqual(noUCTrunk, fullTrunk, accuracy: 1e-6)
    }

    /// Same property at the CoM level: with all trunk bones coincident at the origin
    /// and limbs offset, subdividing the trunk cannot move the CoM under parent-fold
    /// (it would under a global renormalize, which rescales the limbs).
    func testCenterOfMass_invariantToTrunkSubdivision() {
        var withUC: [VRMHumanoidBone: SIMD3<Float>] = [
            .hips: .zero, .spine: .zero, .chest: .zero, .upperChest: .zero,
            .leftUpperLeg: SIMD3<Float>(1, 0, 0), .rightUpperLeg: SIMD3<Float>(1, 0, 0),
            .leftUpperArm: SIMD3<Float>(1, 0, 0), .rightUpperArm: SIMD3<Float>(1, 0, 0),
            .head: .zero,
        ]
        let comWith = try! XCTUnwrap(BalanceModel.centerOfMass(jointPositions: withUC))
        withUC.removeValue(forKey: .upperChest)
        let comWithout = try! XCTUnwrap(BalanceModel.centerOfMass(jointPositions: withUC))
        XCTAssertEqual(simd_distance(comWith, comWithout), 0, accuracy: 1e-6,
                       "trunk subdivision must not move the CoM (parent-fold)")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BalanceModelTests --disable-sandbox`
Expected: FAIL — `cannot find 'BalanceModel' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/VRMMetalKit/Animation/BalanceModel.swift`:

```swift
//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation
import simd

/// Pure, read-only balance sensor (design: 2026-07-05-balance-model-design.md):
/// weighted-segment center of mass, foot support polygon, and margin of stability.
/// Metal-free and non-mutating — the foundation the later procedural staggering
/// increments (recovery stepping, collision stagger, upright recovery) read.
public enum BalanceModel {

    // MARK: - Center of mass

    /// Dempster-derived segment mass fractions, grouped by body region. Summed over a
    /// complete skeleton the fractions are ≈ 1.0; the final normalize in
    /// ``centerOfMass(jointPositions:)`` absorbs the rounding and any absent region.
    public static let massFractions: [VRMHumanoidBone: Float] = [
        // Trunk ≈ 0.50
        .hips: 0.14, .spine: 0.14, .chest: 0.11, .upperChest: 0.11,
        // Head / neck ≈ 0.085
        .neck: 0.015, .head: 0.07,
        // Arms ≈ 0.049 each
        .leftUpperArm: 0.027, .leftLowerArm: 0.016, .leftHand: 0.006,
        .rightUpperArm: 0.027, .rightLowerArm: 0.016, .rightHand: 0.006,
        // Legs ≈ 0.16 each
        .leftUpperLeg: 0.10, .leftLowerLeg: 0.045, .leftFoot: 0.015,
        .rightUpperLeg: 0.10, .rightLowerLeg: 0.045, .rightFoot: 0.015,
    ]

    /// Where a bone's mass folds when the bone is absent: its nearest coarser ancestor
    /// **within the same body region** (design §4.1). Region roots (`hips`, `head`,
    /// each `upperArm`/`upperLeg`) have no entry — their mass, if the root itself is
    /// absent, drops out and the CoM normalize rescales what remains (the safe guard).
    public static let foldParent: [VRMHumanoidBone: VRMHumanoidBone] = [
        .upperChest: .chest, .chest: .spine, .spine: .hips,   // trunk chain → hips
        .neck: .head,                                          // head/neck region → head
        .leftHand: .leftLowerArm, .leftLowerArm: .leftUpperArm,
        .rightHand: .rightLowerArm, .rightLowerArm: .rightUpperArm,
        .leftFoot: .leftLowerLeg, .leftLowerLeg: .leftUpperLeg,
        .rightFoot: .rightLowerLeg, .rightLowerLeg: .rightUpperLeg,
    ]

    /// Effective mass fractions after parent-folding absent bones onto their nearest
    /// present in-region ancestor. Keys are a subset of `present`.
    public static func effectiveFractions(present: Set<VRMHumanoidBone>) -> [VRMHumanoidBone: Float] {
        var eff: [VRMHumanoidBone: Float] = [:]
        for (bone, frac) in massFractions {
            var target: VRMHumanoidBone? = bone
            while let t = target, !present.contains(t) { target = foldParent[t] }
            if let t = target { eff[t, default: 0] += frac }
        }
        return eff
    }

    /// Weighted-segment center of mass from humanoid joint world positions. `nil`
    /// unless `hips` and at least one further bone are present (a CoM is never a bare
    /// point). Shifts with torso lean AND limb swing — the property staggering needs.
    public static func centerOfMass(jointPositions joints: [VRMHumanoidBone: SIMD3<Float>]) -> SIMD3<Float>? {
        guard joints[.hips] != nil, joints.count >= 2 else { return nil }
        let eff = effectiveFractions(present: Set(joints.keys))
        var sum = SIMD3<Float>(repeating: 0)
        var total: Float = 0
        for (bone, frac) in eff {
            guard let p = joints[bone] else { continue }
            sum += p * frac
            total += frac
        }
        guard total > 0 else { return nil }
        return sum / total
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BalanceModelTests --disable-sandbox`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/VRMMetalKit/Animation/BalanceModel.swift Tests/VRMMetalKitTests/Animation/BalanceModelTests.swift
git commit -m "feat(balance): weighted-segment CoM with parent-fold mass redistribution"
```

---

### Task 2: Support polygon — convex hull of foot corners

**Files:**
- Modify: `Sources/VRMMetalKit/Animation/BalanceModel.swift`
- Test: `Tests/VRMMetalKitTests/Animation/BalanceModelTests.swift`

**Interfaces:**
- Consumes: `enum BalanceModel` (Task 1).
- Produces: `static func supportPolygon(footCorners: [SIMD2<Float>]) -> [SIMD2<Float>]` — CCW convex hull in the xz plane (`SIMD2.x` = world x, `SIMD2.y` = world z).

- [ ] **Step 1: Write the failing tests**

Append to `BalanceModelTests`:

```swift
    // MARK: - Task 2: Support polygon (convex hull)

    func testSupportPolygon_hullOfASquareIsThatSquare() {
        let square: [SIMD2<Float>] = [
            SIMD2<Float>(0, 0), SIMD2<Float>(1, 0),
            SIMD2<Float>(1, 1), SIMD2<Float>(0, 1),
            SIMD2<Float>(0.5, 0.5),   // interior point must be dropped
        ]
        let hull = BalanceModel.supportPolygon(footCorners: square)
        XCTAssertEqual(hull.count, 4, "interior point excluded")
        // Every hull vertex is a corner of the unit square.
        for v in hull {
            XCTAssertTrue((abs(v.x) < 1e-5 || abs(v.x - 1) < 1e-5) &&
                          (abs(v.y) < 1e-5 || abs(v.y - 1) < 1e-5))
        }
    }

    func testSupportPolygon_isCounterClockwise() {
        let hull = BalanceModel.supportPolygon(footCorners: [
            SIMD2<Float>(0, 0), SIMD2<Float>(2, 0), SIMD2<Float>(2, 2), SIMD2<Float>(0, 2),
        ])
        // Signed area of a CCW polygon is positive.
        var area: Float = 0
        for i in 0..<hull.count {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            area += a.x * b.y - b.x * a.y
        }
        XCTAssertGreaterThan(area, 0, "hull wound counter-clockwise")
    }

    func testSupportPolygon_collinearInputDoesNotCrash() {
        let line: [SIMD2<Float>] = [SIMD2<Float>(0, 0), SIMD2<Float>(1, 0), SIMD2<Float>(2, 0)]
        let hull = BalanceModel.supportPolygon(footCorners: line)
        XCTAssertLessThanOrEqual(hull.count, line.count)   // degenerate, but no trap
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BalanceModelTests --disable-sandbox`
Expected: FAIL — `type 'BalanceModel' has no member 'supportPolygon'`.

- [ ] **Step 3: Write the implementation**

Add to `BalanceModel` in `BalanceModel.swift`:

```swift
    // MARK: - Support polygon

    /// CCW convex hull (Andrew's monotone chain) of foot ground corners in the xz
    /// plane. Returns the input (≤2 unique points) unchanged for degenerate cases.
    public static func supportPolygon(footCorners: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let pts = footCorners.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard pts.count >= 3 else { return pts }

        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }

        var lower: [SIMD2<Float>] = []
        for p in pts {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [SIMD2<Float>] = []
        for p in pts.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper   // CCW
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BalanceModelTests --disable-sandbox`
Expected: PASS (8 tests total).

- [ ] **Step 5: Commit**

```bash
git add Sources/VRMMetalKit/Animation/BalanceModel.swift Tests/VRMMetalKitTests/Animation/BalanceModelTests.swift
git commit -m "feat(balance): convex-hull support polygon"
```

---

### Task 3: Stability margin — signed distance to the support boundary

**Files:**
- Modify: `Sources/VRMMetalKit/Animation/BalanceModel.swift`
- Test: `Tests/VRMMetalKitTests/Animation/BalanceModelTests.swift`

**Interfaces:**
- Consumes: `supportPolygon` (Task 2).
- Produces: `static func stabilityMargin(comGround: SIMD2<Float>, polygon: [SIMD2<Float>]) -> (margin: Float, centroid: SIMD2<Float>)` — `margin > 0` inside (distance to nearest edge), `< 0` outside (−distance past nearest edge).

- [ ] **Step 1: Write the failing tests**

Append to `BalanceModelTests`:

```swift
    // MARK: - Task 3: Stability margin

    private var unitSquare: [SIMD2<Float>] {
        // CCW unit square centered at origin, half-extent 1 (so edges at ±1).
        [SIMD2<Float>(-1, -1), SIMD2<Float>(1, -1), SIMD2<Float>(1, 1), SIMD2<Float>(-1, 1)]
    }

    func testMargin_positiveAtCentroidEqualsHalfExtent() {
        let (margin, centroid) = BalanceModel.stabilityMargin(comGround: .zero, polygon: unitSquare)
        XCTAssertEqual(centroid.x, 0, accuracy: 1e-6)
        XCTAssertEqual(centroid.y, 0, accuracy: 1e-6)
        XCTAssertEqual(margin, 1.0, accuracy: 1e-5, "centroid is 1.0 from every edge")
    }

    func testMargin_decreasesMonotonicallyTowardEdge() {
        let m0 = BalanceModel.stabilityMargin(comGround: SIMD2<Float>(0, 0), polygon: unitSquare).margin
        let m1 = BalanceModel.stabilityMargin(comGround: SIMD2<Float>(0.5, 0), polygon: unitSquare).margin
        let m2 = BalanceModel.stabilityMargin(comGround: SIMD2<Float>(0.9, 0), polygon: unitSquare).margin
        XCTAssertGreaterThan(m0, m1)
        XCTAssertGreaterThan(m1, m2)
        XCTAssertGreaterThan(m2, 0, "still inside")
    }

    func testMargin_negativeOutsideWithCorrectMagnitude() {
        let (margin, _) = BalanceModel.stabilityMargin(comGround: SIMD2<Float>(1.5, 0), polygon: unitSquare)
        XCTAssertEqual(margin, -0.5, accuracy: 1e-5, "0.5 past the +x edge")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BalanceModelTests --disable-sandbox`
Expected: FAIL — `type 'BalanceModel' has no member 'stabilityMargin'`.

- [ ] **Step 3: Write the implementation**

Add to `BalanceModel` in `BalanceModel.swift`:

```swift
    // MARK: - Stability margin

    /// Signed distance from `comGround` to the boundary of the (CCW) support polygon,
    /// with the polygon centroid. `margin > 0` inside (distance to nearest edge),
    /// `margin < 0` outside (−distance to nearest edge). Degenerate polygons (≤2
    /// vertices) return a negative margin (no stable base).
    public static func stabilityMargin(comGround p: SIMD2<Float>,
                                       polygon poly: [SIMD2<Float>]) -> (margin: Float, centroid: SIMD2<Float>) {
        let centroid = poly.isEmpty
            ? SIMD2<Float>(repeating: 0)
            : poly.reduce(SIMD2<Float>(repeating: 0), +) / Float(poly.count)
        guard poly.count >= 3 else { return (-simd_distance(p, centroid), centroid) }

        var inside = true
        var minDist = Float.greatestFiniteMagnitude
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let e = b - a
            // For a CCW polygon a point is inside when it is left of every edge.
            let side = e.x * (p.y - a.y) - e.y * (p.x - a.x)
            if side < 0 { inside = false }
            let len2 = simd_length_squared(e)
            let t = len2 > 1e-12 ? simd_clamp(simd_dot(p - a, e) / len2, 0, 1) : 0
            let closest = a + e * t
            minDist = min(minDist, simd_distance(p, closest))
        }
        return (inside ? minDist : -minDist, centroid)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BalanceModelTests --disable-sandbox`
Expected: PASS (11 tests total).

- [ ] **Step 5: Commit**

```bash
git add Sources/VRMMetalKit/Animation/BalanceModel.swift Tests/VRMMetalKitTests/Animation/BalanceModelTests.swift
git commit -m "feat(balance): margin-of-stability (signed distance to support boundary)"
```

---

### Task 4: Foot ground corners — `Foot` enum, `footForward` with sanity-checked fallback

**Files:**
- Modify: `Sources/VRMMetalKit/Animation/BalanceModel.swift`
- Test: `Tests/VRMMetalKitTests/Animation/BalanceModelTests.swift`

**Interfaces:**
- Consumes: `VRMModel`, `VRMHumanoidBone` (existing).
- Produces:
  - `enum BalanceModel.Foot: Sendable { case left, right }`
  - `static func footGroundCorners(model: VRMModel, foot: Foot, groundY: Float, footLength: Float = 0.15, halfWidth: Float = 0.04) -> [SIMD2<Float>]?` — 4 xz corners (heel±width, toe±width), or `nil` if the foot bone is absent.

- [ ] **Step 1: Write the failing test**

Append to `BalanceModelTests`:

```swift
    // MARK: - Task 4: Foot ground corners

    @MainActor func testFootGroundCorners_fourCornersSpanningTheFoot() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()

        let corners = try XCTUnwrap(BalanceModel.footGroundCorners(model: model, foot: .left, groundY: 0))
        XCTAssertEqual(corners.count, 4)
        // The four corners are not degenerate: they span a non-trivial area (a real foot).
        let hull = BalanceModel.supportPolygon(footCorners: corners)
        var area: Float = 0
        for i in 0..<hull.count {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            area += a.x * b.y - b.x * a.y
        }
        XCTAssertGreaterThan(abs(area) * 0.5, 1e-4, "one foot forms a real (non-degenerate) polygon")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BalanceModelTests/testFootGroundCorners_fourCornersSpanningTheFoot --disable-sandbox`
Expected: FAIL — `type 'BalanceModel' has no member 'footGroundCorners'`.

- [ ] **Step 3: Write the implementation**

Add to `BalanceModel` in `BalanceModel.swift`:

```swift
    // MARK: - Foot support corners

    /// Which foot a support contribution comes from.
    public enum Foot: Sendable { case left, right }

    /// The four ground corners (heel±width, toe±width) of `foot` in the xz plane, or
    /// `nil` when the foot bone is absent. `footForward` comes from the reliable
    /// skeletal heel→toe vector when the rig has toes; otherwise from a
    /// sanity-checked hips-forward fallback (VRM does not standardize a foot-forward
    /// local axis, so a per-bone axis guess would silently rotate the polygon).
    public static func footGroundCorners(model: VRMModel, foot: Foot, groundY: Float,
                                         footLength: Float = 0.15,
                                         halfWidth: Float = 0.04) -> [SIMD2<Float>]? {
        guard let humanoid = model.humanoid else { return nil }
        let footBone: VRMHumanoidBone = foot == .left ? .leftFoot : .rightFoot
        let toesBone: VRMHumanoidBone = foot == .left ? .leftToes : .rightToes
        guard let footIdx = humanoid.getBoneNode(footBone), footIdx < model.nodes.count else { return nil }

        let footPos = model.nodes[footIdx].worldPosition
        let heel = SIMD2<Float>(footPos.x, footPos.z)

        let toe: SIMD2<Float>
        let forward: SIMD2<Float>
        if let toesIdx = humanoid.getBoneNode(toesBone), toesIdx < model.nodes.count {
            let toesPos = model.nodes[toesIdx].worldPosition
            toe = SIMD2<Float>(toesPos.x, toesPos.z)
            let d = toe - heel
            forward = simd_length(d) > 1e-5 ? d / simd_length(d) : hipsForward(humanoid, model)
        } else {
            forward = hipsForward(humanoid, model)
            toe = heel + forward * footLength
        }

        let perp = SIMD2<Float>(-forward.y, forward.x)   // perpendicular in the xz plane
        return [
            heel + perp * halfWidth, heel - perp * halfWidth,
            toe + perp * halfWidth, toe - perp * halfWidth,
        ]
    }

    /// Rig-independent forward direction (hips local +Z projected to xz), the fallback
    /// when a foot has no toes bone. Defaults to +z if the hips axis is degenerate.
    private static func hipsForward(_ humanoid: VRMHumanoid, _ model: VRMModel) -> SIMD2<Float> {
        guard let hipsIdx = humanoid.getBoneNode(.hips), hipsIdx < model.nodes.count else {
            return SIMD2<Float>(0, 1)
        }
        let m = model.nodes[hipsIdx].worldMatrix
        let fz = SIMD2<Float>(m[2][0], m[2][2])          // world xz of the hips local +Z axis
        let len = simd_length(fz)
        return len > 1e-5 ? fz / len : SIMD2<Float>(0, 1)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter BalanceModelTests/testFootGroundCorners_fourCornersSpanningTheFoot --disable-sandbox`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/VRMMetalKit/Animation/BalanceModel.swift Tests/VRMMetalKitTests/Animation/BalanceModelTests.swift
git commit -m "feat(balance): foot ground corners with sanity-checked footForward"
```

---

### Task 5: `BalanceState` + `evaluate` — assembly and VRM integration tests

**Files:**
- Modify: `Sources/VRMMetalKit/Animation/BalanceModel.swift`
- Test: `Tests/VRMMetalKitTests/Animation/BalanceModelTests.swift`

**Interfaces:**
- Consumes: `centerOfMass`, `supportPolygon`, `stabilityMargin`, `footGroundCorners`, `Foot` (Tasks 1–4).
- Produces:
  - `public struct BalanceState: Sendable` with `centerOfMass: SIMD3<Float>`, `comGround: SIMD2<Float>`, `supportPolygon: [SIMD2<Float>]`, `supportCentroid: SIMD2<Float>`, `margin: Float`, `imbalanceDirection: SIMD2<Float>`, `var isBalanced: Bool`.
  - `static func evaluate(model: VRMModel, groundY: Float = 0, plantedFeet: Set<Foot> = [.left, .right]) -> BalanceState?`

- [ ] **Step 1: Write the failing tests**

Append to `BalanceModelTests`:

```swift
    // MARK: - Task 5: evaluate() integration

    @MainActor private func loadRig() async throws -> VRMModel {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()
        return model
    }

    @MainActor func testEvaluate_restPoseIsBalanced() async throws {
        let model = try await loadRig()
        let state = try XCTUnwrap(BalanceModel.evaluate(model: model))
        XCTAssertGreaterThan(state.margin, 0, "standing rest pose ⇒ CoM inside the base of support")
        XCTAssertTrue(state.isBalanced)
    }

    /// The discriminating test (design §5): swinging a LEG moves the CoM toward the
    /// leg's motion. Fails under a torso-only weighting; passes under weighted-segment.
    @MainActor func testEvaluate_comShiftsTowardASwungLeg() async throws {
        let model = try await loadRig()
        let humanoid = try XCTUnwrap(model.humanoid)
        let comBefore = try XCTUnwrap(BalanceModel.evaluate(model: model)).centerOfMass
        let footIdx = try XCTUnwrap(humanoid.getBoneNode(.leftFoot))
        let footBefore = model.nodes[footIdx].worldPosition

        // Swing the left leg out/up by rotating the upper leg, torso untouched.
        let upperLegIdx = try XCTUnwrap(humanoid.getBoneNode(.leftUpperLeg))
        model.nodes[upperLegIdx].rotation =
            simd_quatf(angle: 1.0, axis: SIMD3<Float>(1, 0, 0)) * model.nodes[upperLegIdx].rotation
        model.updateNodeTransforms()

        let comAfter = try XCTUnwrap(BalanceModel.evaluate(model: model)).centerOfMass
        let footAfter = model.nodes[footIdx].worldPosition

        let comMove = SIMD2<Float>(comAfter.x - comBefore.x, comAfter.z - comBefore.z)
        let legMove = SIMD2<Float>(footAfter.x - footBefore.x, footAfter.z - footBefore.z)
        XCTAssertGreaterThan(simd_length(comMove), 1e-4, "CoM tracks the limb (not torso-only)")
        XCTAssertGreaterThan(simd_dot(comMove, legMove), 0, "CoM shifted toward the swung leg")
    }

    @MainActor func testEvaluate_singlePlantedFootShrinksSupport() async throws {
        let model = try await loadRig()
        let both = try XCTUnwrap(BalanceModel.evaluate(model: model, plantedFeet: [.left, .right]))
        let left = try XCTUnwrap(BalanceModel.evaluate(model: model, plantedFeet: [.left]))
        func area(_ poly: [SIMD2<Float>]) -> Float {
            var a: Float = 0
            for i in 0..<poly.count { let p = poly[i], q = poly[(i + 1) % poly.count]; a += p.x * q.y - q.x * p.y }
            return abs(a) * 0.5
        }
        XCTAssertLessThan(area(left.supportPolygon), area(both.supportPolygon),
                          "one-foot base is smaller than two-foot base")
    }

    @MainActor func testEvaluate_isReadOnlyAndDeterministic() async throws {
        let model = try await loadRig()
        let hipsIdx = try XCTUnwrap(model.humanoid?.getBoneNode(.hips))
        let rotBefore = model.nodes[hipsIdx].rotation
        let a = try XCTUnwrap(BalanceModel.evaluate(model: model))
        let b = try XCTUnwrap(BalanceModel.evaluate(model: model))
        XCTAssertEqual(a.centerOfMass, b.centerOfMass, "deterministic")
        XCTAssertEqual(a.margin, b.margin)
        XCTAssertEqual(model.nodes[hipsIdx].rotation, rotBefore, "evaluate must not mutate the model")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BalanceModelTests --disable-sandbox`
Expected: FAIL — `cannot find type 'BalanceState'` / `no member 'evaluate'`.

- [ ] **Step 3: Write the implementation**

Add the `BalanceState` struct (top level, above `enum BalanceModel`) in `BalanceModel.swift`:

```swift
/// Read-only balance state for a model's current pose (design §3).
public struct BalanceState: Sendable {
    /// World-space center of mass.
    public let centerOfMass: SIMD3<Float>
    /// CoM projected to the ground plane (xz).
    public let comGround: SIMD2<Float>
    /// Base of support: xz convex hull of the planted feet's ground corners (CCW).
    public let supportPolygon: [SIMD2<Float>]
    /// Centroid of `supportPolygon`.
    public let supportCentroid: SIMD2<Float>
    /// Margin of stability: `> 0` inside the base (stable), `< 0` outside (falling).
    public let margin: Float
    /// Unit xz direction `normalize(comGround − supportCentroid)`; the zero vector is
    /// a valid answer meaning "centered, no imbalance" (`⇒ no step indicated`).
    public let imbalanceDirection: SIMD2<Float>
    /// `margin > 0`.
    public var isBalanced: Bool { margin > 0 }
}
```

Add `evaluate` to `BalanceModel`:

```swift
    // MARK: - Assembly

    /// Full balance state for `model`'s current pose. `nil` when the rig lacks the
    /// humanoid bones for a CoM or has no planted foot to form a support base.
    public static func evaluate(model: VRMModel, groundY: Float = 0,
                                plantedFeet: Set<Foot> = [.left, .right]) -> BalanceState? {
        guard let humanoid = model.humanoid else { return nil }

        var joints: [VRMHumanoidBone: SIMD3<Float>] = [:]
        for bone in massFractions.keys {
            if let idx = humanoid.getBoneNode(bone), idx < model.nodes.count {
                joints[bone] = model.nodes[idx].worldPosition
            }
        }
        guard let com = centerOfMass(jointPositions: joints) else { return nil }

        var corners: [SIMD2<Float>] = []
        for foot in [Foot.left, .right] where plantedFeet.contains(foot) {
            if let c = footGroundCorners(model: model, foot: foot, groundY: groundY) {
                corners.append(contentsOf: c)
            }
        }
        guard corners.count >= 3 else { return nil }

        let poly = supportPolygon(footCorners: corners)
        let comGround = SIMD2<Float>(com.x, com.z)
        let (margin, centroid) = stabilityMargin(comGround: comGround, polygon: poly)
        let d = comGround - centroid
        let imbalance = simd_length(d) > 1e-5 ? d / simd_length(d) : SIMD2<Float>(repeating: 0)

        return BalanceState(centerOfMass: com, comGround: comGround, supportPolygon: poly,
                            supportCentroid: centroid, margin: margin, imbalanceDirection: imbalance)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BalanceModelTests --disable-sandbox`
Expected: PASS (all BalanceModel tests, incl. the four integration tests).

- [ ] **Step 5: Full-suite sanity + commit**

Run: `swift build` (Expected: `Build complete!`)

```bash
git add Sources/VRMMetalKit/Animation/BalanceModel.swift Tests/VRMMetalKitTests/Animation/BalanceModelTests.swift
git commit -m "feat(balance): BalanceState + evaluate() with VRM integration tests"
```

---

## Self-Review

**Spec coverage:**
- §2 API (`evaluate`, pure statics, `plantedFeet` param, `nil` conditions) → Tasks 1–5. ✓
- §3 `BalanceState` (all fields, sign convention, zero `imbalanceDirection` meaning) → Task 5 struct + `testEvaluate_isReadOnly…` / integration. ✓
- §4.1 CoM weighted segments + **parent-fold** + minimum bones → Task 1 (`effectiveFractions`, `centerOfMass`, `testEffectiveFractions_…`, `testCenterOfMass_invariantToTrunkSubdivision`, `testCenterOfMassNilWhenHipsMissingOrSingleBone`). ✓
- §4.2 support polygon (foot corners, `footForward` skeletal/fallback, convex hull) → Tasks 2 & 4. ✓
- §4.3 margin + imbalance direction → Task 3 + Task 5 assembly. ✓
- §5 tests: pure geometry (Tasks 1–3), **limb-response discriminator** (`testEvaluate_comShiftsTowardASwungLeg`, Task 5), split-trunk stability (Task 1), single-foot (Task 5), purity/determinism (Task 5). ✓
- §6 non-goals (no behavior) → respected; module is read-only, no consumers.

**Placeholder scan:** none — every step has complete code and exact commands.

**Type consistency:** `BalanceModel`, `Foot`, `BalanceState`, and the static signatures (`effectiveFractions`, `centerOfMass`, `supportPolygon`, `stabilityMargin`, `footGroundCorners`, `evaluate`) are identical across the tasks that define and consume them. `SIMD2.y` consistently means world z throughout.
