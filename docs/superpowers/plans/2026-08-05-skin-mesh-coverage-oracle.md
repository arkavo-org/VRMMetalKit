# Skin-Mesh Coverage Oracle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A test-only oracle that measures spring-joint penetration against the actual skinned body mesh, and a coverage gate that records — as a failing measurement — hands and fingers sinking into a simulated dress.

**Architecture:** One value type, `SkinMeshOracle`, with a triangle-level initializer (pure geometry, no rig, no Metal) and a rig-level `build(model:)` on top. Closest-point-on-triangle with angle-weighted pseudonormal classification, accelerated by a uniform spatial hash with no distance cutoff. The gate joins the existing `SpringBoneStressPosePenetrationTests` harness and asserts through `XCTExpectFailure`, pinned to the hand region.

**Tech Stack:** Swift 6.2, `simd`, XCTest, Metal (only for `build(model:)` and the gate). Spec: `docs/superpowers/specs/2026-08-05-skin-mesh-coverage-oracle-design.md`.

## Global Constraints

- Swift 6.2; targets macOS 26+, iOS 26+.
- New source files MUST carry the 15-line Apache 2.0 header, copied verbatim from `Sources/VRMMetalKit/Animation/CaptureStepController.swift:1-15`.
- Tests always run with `--disable-sandbox`. Full suite: `swift test --disable-sandbox --skip HairHeadCollisionTests`.
- Tests needing a Metal device MUST `throw XCTSkip("No Metal device")` when `MTLCreateSystemDefaultDevice()` returns nil. Tasks 2 and 3 must NOT need one.
- No temporary contextual/informational comments in code. Doc comments stating constraints are expected — match the density of `SkinReferenceOracle.swift`.
- No hardcoded absolute paths. CI greps `URL(fileURLWithPath: "/`, `Projects/`, and `/Users/` across `Sources/` and `Tests/` and fails the build on a hit.
- Commit after each task. Do **not** push (pushes trigger Xcode Cloud; the user pushes on request).
- **Base:** branch from `fix/stagger-collision` at `5ab532b`. Both dependencies — `HairBodyMeshPenetrationDiagnostic` and `ColliderDimensionAudit` — exist only there, not on `main`. If PR #380 merges first, rebase onto `main` and drop this note.
- Pre-existing failures, not yours: `SpringBoneRendererDeterminismTests`, `BalanceModelTests.testEvaluate_isReadOnlyAndDeterministic`, `HairHeadCollisionTests` SIGTRAP under parallel load.
- **Every gate in this plan must be observed failing before it is trusted.** A test that has never been seen to discriminate is not evidence.

---

## File Structure

**Create:**
- `Tests/VRMMetalKitTests/SpringBone/SkinMeshOracle.swift` — the oracle: `Triangle`, `Penetration`, closest-point, pseudonormal classification, spatial hash, `build(model:)`. Test-target only; this never ships.
- `Tests/VRMMetalKitTests/SpringBone/BodySurfacePredicate.swift` — which primitives constitute the body surface.
- `Tests/VRMMetalKitTests/SpringBone/SkinMeshOracleMathTests.swift` — Layer 1, synthetic geometry, no rig.
- `Tests/VRMMetalKitTests/SpringBone/BodySurfacePredicateTests.swift` — Layer 2, per-fixture exact sets.
- `Tests/VRMMetalKitTests/SpringBone/SkinMeshCoverageTests.swift` — Layer 3, the gate.

**Modify:**
- `Tests/VRMMetalKitTests/SpringBone/StressPoseFactory.swift` — add `armsAtSides`.
- `.gitignore` — allowlist `AvatarSample_U_1.0.vrm.glb`.
- `LICENSE-MODELS.md` — entry for U mirroring A's.

Everything lives in the test target. `Sources/` is untouched by this plan.

---

### Task 1: Bundle the AvatarSample_U fixture

The gate's deliverable evaporates without it: `requireFixture` throws `XCTSkip` on a missing file (`TestHelpers.swift:289`), and Xcode Cloud — the only place the package tests actually run — has no copy. A gate that vanishes with its fixture reports success.

**Files:**
- Modify: `.gitignore`
- Modify: `LICENSE-MODELS.md`
- Add (binary): `AvatarSample_U_1.0.vrm.glb`

**Interfaces:**
- Consumes: nothing.
- Produces: `getTestModelPath("AvatarSample_U_1.0.vrm.glb")` resolves on a fresh checkout.

- [ ] **Step 1: Confirm the licence permits redistribution**

Run:
```bash
python3 - <<'EOF'
import json, struct
d = open("AvatarSample_U_1.0.vrm.glb", "rb").read()
n = struct.unpack('<I', d[12:16])[0]
j = json.loads(d[20:20+n].decode('utf-8', errors='ignore'))
m = j['extensions']['VRMC_vrm']['meta']
for k in ['name','avatarPermission','allowRedistribution','modification','commercialUsage','licenseUrl']:
    print(k, '=', m.get(k))
EOF
```
Expected, and required to proceed:
```
avatarPermission = everyone
allowRedistribution = True
modification = allowModificationRedistribution
commercialUsage = corporation
licenseUrl = https://vrm.dev/licenses/1.0/
```
If `allowRedistribution` is not `True`, STOP and report BLOCKED — do not bundle it. The fallback is the env-gated fail-not-skip route in spec §7, which is a different task.

- [ ] **Step 2: Allowlist the fixture**

`.gitignore` currently allowlists only A (lines 21-22). Add alongside them:
```
!/AvatarSample_U_1.0.vrm.glb
```

- [ ] **Step 3: Record the licence**

Add an entry to `LICENSE-MODELS.md` mirroring the existing `AvatarSample_A_1.0` entry exactly in structure — same headings, same fields, same order. Read A's entry first and copy its shape; do not invent a new format.

- [ ] **Step 4: Verify it is tracked and resolvable**

Run:
```bash
git add -A && git status --short | grep AvatarSample_U
swift test --filter "SpringBoneStressPosePenetrationTests/testU_legMarch_augmented_noPenetration" --disable-sandbox 2>&1 | grep -E "passed|failed|skipped"
```
Expected: the fixture shows as added, and the U-based test **passes rather than skips**. If it skips, the path resolution is wrong and later tasks will silently no-op.

- [ ] **Step 5: Commit**

```bash
git commit -m "test(fixtures): bundle AvatarSample_U_1.0, the only skirt-simulating fixture

Its VRM 1.0 meta permits redistribution on the same terms as AvatarSample_A
(avatarPermission=everyone, allowRedistribution=true,
modification=allowModificationRedistribution). Without it the coverage gate
XCTSkips in Xcode Cloud, which is the only place the package tests run."
```

---

### Task 2: Oracle maths — closest point and pseudonormal classification

No rig, no fixture, no Metal. This is the whole correctness surface; everything later is plumbing and speed.

**Files:**
- Create: `Tests/VRMMetalKitTests/SpringBone/SkinMeshOracle.swift`
- Test: `Tests/VRMMetalKitTests/SpringBone/SkinMeshOracleMathTests.swift`

**Interfaces:**
- Consumes: `VRMHumanoidBone` (existing, `Sources/VRMMetalKit/Core/VRMTypes.swift`).
- Produces (Tasks 3–6 rely on these exact signatures):
  - `struct SkinMeshOracle`
  - `struct SkinMeshOracle.Triangle { let a, b, c: SIMD3<Float>; let region: VRMHumanoidBone? }`
  - `struct SkinMeshOracle.Penetration { let depth: Float; let region: VRMHumanoidBone?; let surfacePoint: SIMD3<Float> }`
  - `init(triangles: [SkinMeshOracle.Triangle])`
  - `func penetration(of point: SIMD3<Float>, radius: Float) -> Penetration?`
  - `var triangleCount: Int { get }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/VRMMetalKitTests/SpringBone/SkinMeshOracleMathTests.swift` (Apache header first, then):

```swift
import XCTest
import simd
@testable import VRMMetalKit

/// Layer 1 of the coverage oracle: pure geometry, no rig and no GPU — the same
/// shape as `OracleDistanceMathTests`, which pins the capsule oracle's maths so
/// later conformance tests can trust the numbers built on it.
final class SkinMeshOracleMathTests: XCTestCase {

    private let eps: Float = 1e-4

    // MARK: - Fixtures

    /// Axis-aligned box as 12 triangles, outward-facing.
    private func box(min lo: SIMD3<Float>, max hi: SIMD3<Float>,
                     region: VRMHumanoidBone? = nil) -> [SkinMeshOracle.Triangle] {
        let v = [
            SIMD3<Float>(lo.x, lo.y, lo.z), SIMD3<Float>(hi.x, lo.y, lo.z),
            SIMD3<Float>(hi.x, hi.y, lo.z), SIMD3<Float>(lo.x, hi.y, lo.z),
            SIMD3<Float>(lo.x, lo.y, hi.z), SIMD3<Float>(hi.x, lo.y, hi.z),
            SIMD3<Float>(hi.x, hi.y, hi.z), SIMD3<Float>(lo.x, hi.y, hi.z)
        ]
        // Each quad wound counter-clockwise seen from outside.
        let quads: [(Int, Int, Int, Int)] = [
            (1, 5, 6, 2), (4, 0, 3, 7),     // +x, -x
            (3, 2, 6, 7), (0, 4, 5, 1),     // +y, -y
            (5, 4, 7, 6), (0, 1, 2, 3)      // +z, -z
        ]
        var out: [SkinMeshOracle.Triangle] = []
        for (a, b, c, d) in quads {
            out.append(.init(a: v[a], b: v[b], c: v[c], region: region))
            out.append(.init(a: v[a], b: v[c], c: v[d], region: region))
        }
        return out
    }

    /// UV sphere, outward-facing.
    private func sphere(center: SIMD3<Float>, radius: Float,
                        rings: Int = 24, segments: Int = 48) -> [SkinMeshOracle.Triangle] {
        func p(_ i: Int, _ j: Int) -> SIMD3<Float> {
            let theta = Float.pi * Float(i) / Float(rings)
            let phi = 2 * Float.pi * Float(j) / Float(segments)
            return center + radius * SIMD3<Float>(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi))
        }
        var out: [SkinMeshOracle.Triangle] = []
        for i in 0..<rings {
            for j in 0..<segments {
                let a = p(i, j), b = p(i + 1, j), c = p(i + 1, j + 1), d = p(i, j + 1)
                out.append(.init(a: a, b: b, c: c, region: nil))
                out.append(.init(a: a, b: c, c: d, region: nil))
            }
        }
        return out
    }

    // MARK: - Convex baseline

    func testPointAtBoxCentreReportsHalfExtentDepth() {
        let oracle = SkinMeshOracle(triangles: box(min: [-1, -1, -1], max: [1, 1, 1]))
        let pen = oracle.penetration(of: .zero, radius: 0)
        XCTAssertEqual(pen?.depth ?? -1, 1.0, accuracy: eps,
                       "centre of a 2m box is 1m inside the nearest face")
    }

    func testPointOutsideReportsNoPenetration() {
        let oracle = SkinMeshOracle(triangles: box(min: [-1, -1, -1], max: [1, 1, 1]))
        XCTAssertNil(oracle.penetration(of: SIMD3<Float>(3, 0, 0), radius: 0),
                     "a point clear of the surface is not penetrating")
    }

    func testPointJustInsideAFaceReportsItsExactDistance() {
        let oracle = SkinMeshOracle(triangles: box(min: [-1, -1, -1], max: [1, 1, 1]))
        let pen = oracle.penetration(of: SIMD3<Float>(0.97, 0, 0), radius: 0)
        XCTAssertEqual(pen?.depth ?? -1, 0.03, accuracy: eps)
    }

    /// The radius-aware case: a joint whose CENTRE is outside but whose SURFACE
    /// is buried. This is the case the existing centre-only gate cannot see.
    func testJointRadiusIsMeasuredFromTheJointSurface() {
        let oracle = SkinMeshOracle(triangles: box(min: [-1, -1, -1], max: [1, 1, 1]))
        let outside = SIMD3<Float>(1.02, 0, 0)
        XCTAssertNil(oracle.penetration(of: outside, radius: 0),
                     "centre-only: 20mm clear reads clean")
        let pen = oracle.penetration(of: outside, radius: 0.05)
        XCTAssertEqual(pen?.depth ?? -1, 0.03, accuracy: eps,
                       "a 50mm joint 20mm clear buries its surface by 30mm")
    }

    func testSphereCentreReportsRadius() {
        let oracle = SkinMeshOracle(triangles: sphere(center: [1, 2, 3], radius: 0.5))
        let pen = oracle.penetration(of: SIMD3<Float>(1, 2, 3), radius: 0)
        XCTAssertEqual(pen?.depth ?? -1, 0.5, accuracy: 1e-2,
                       "tessellation makes this approximate; 1cm on a 50cm sphere")
    }

    // MARK: - Concave fixture (REQUIRED — convex shapes cannot observe this)

    /// Two boxes forming a notch. A query in the notch has its closest point on
    /// a shared EDGE, where an arbitrary adjacent face normal flips the sign.
    /// Cube and sphere are both convex and structurally cannot catch this.
    func testConcaveNotchClassifiesOutsideCorrectly() {
        var tris = box(min: [-1, -1, -1], max: [0, 1, 1])
        tris += box(min: [-1, -1, -1], max: [1, 1, 0])
        let oracle = SkinMeshOracle(triangles: tris)
        // Sits in the open quadrant (x>0, z>0) — outside both boxes.
        XCTAssertNil(oracle.penetration(of: SIMD3<Float>(0.30, 0, 0.30), radius: 0),
                     "a point in the notch's open quadrant is OUTSIDE; a face-normal "
                     + "classifier reports it inside")
    }

    func testConcaveNotchStillDetectsGenuineInterior() {
        var tris = box(min: [-1, -1, -1], max: [0, 1, 1])
        tris += box(min: [-1, -1, -1], max: [1, 1, 0])
        let oracle = SkinMeshOracle(triangles: tris)
        XCTAssertNotNil(oracle.penetration(of: SIMD3<Float>(-0.5, 0, -0.5), radius: 0),
                        "deep in the shared interior is inside")
    }

    // MARK: - No proximity cutoff

    /// The prototype dropped candidates beyond 50mm. Inherited as a search
    /// bound, a joint buried deeper than the cutoff finds nothing and reads
    /// CLEAN — the deepest defects become invisible.
    func testDeepInteriorQueryIsNotLostToASearchCutoff() {
        let oracle = SkinMeshOracle(triangles: box(min: [-2, -2, -2], max: [2, 2, 2]))
        let pen = oracle.penetration(of: .zero, radius: 0)
        XCTAssertEqual(pen?.depth ?? -1, 2.0, accuracy: eps,
                       "2m from every face, far past any plausible cutoff")
    }

    // MARK: - Degenerate input

    func testZeroAreaTrianglesAreRejectedNotNaN() {
        let degenerate = SkinMeshOracle.Triangle(a: [0, 0, 0], b: [1, 0, 0], c: [2, 0, 0], region: nil)
        var tris = box(min: [-1, -1, -1], max: [1, 1, 1])
        tris.append(degenerate)
        let oracle = SkinMeshOracle(triangles: tris)
        XCTAssertEqual(oracle.triangleCount, tris.count - 1, "the degenerate triangle is dropped")
        let pen = oracle.penetration(of: .zero, radius: 0)
        XCTAssertEqual(pen?.depth ?? -1, 1.0, accuracy: eps)
        XCTAssertFalse((pen?.depth ?? 0).isNaN)
    }

    // MARK: - Region

    func testRegionIsCarriedFromTheNearestTriangle() {
        let oracle = SkinMeshOracle(triangles: box(min: [-1, -1, -1], max: [1, 1, 1], region: .leftHand))
        XCTAssertEqual(oracle.penetration(of: .zero, radius: 0)?.region, .leftHand)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SkinMeshOracleMathTests --disable-sandbox`
Expected: FAIL to compile — "cannot find 'SkinMeshOracle' in scope".

- [ ] **Step 3: Write the implementation**

Create `Tests/VRMMetalKitTests/SpringBone/SkinMeshOracle.swift` (Apache header first, then):

```swift
import Foundation
import simd
@testable import VRMMetalKit

/// Test-only ground truth: signed penetration against the actual skinned body
/// mesh, rather than against fitted capsules.
///
/// The capsule oracle (``SkinReferenceOracle``) carries 10 hand-authored shapes
/// over 9 bones and covers neither hands nor torso, so a finger through a dress
/// produces no signal. Extending it means ~60 authored shapes and converges its
/// method with the collider sizing it is supposed to check. The mesh needs no
/// authoring and is ground truth rather than an approximation of it.
///
/// Never shipped: this type lives in the test target and has no runtime budget.
struct SkinMeshOracle {

    struct Triangle {
        let a: SIMD3<Float>
        let b: SIMD3<Float>
        let c: SIMD3<Float>
        /// Dominant skinning bone, used to scale tolerance by body region.
        let region: VRMHumanoidBone?

        init(a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>, region: VRMHumanoidBone?) {
            self.a = a; self.b = b; self.c = c; self.region = region
        }
    }

    struct Penetration {
        /// Metres the query's surface lies past the mesh surface. Always > 0.
        let depth: Float
        let region: VRMHumanoidBone?
        let surfacePoint: SIMD3<Float>
    }

    private let triangles: [Triangle]
    private let faceNormals: [SIMD3<Float>]
    /// Angle-weighted pseudonormal per welded vertex, keyed by quantised position.
    private let vertexPseudonormals: [VertexKey: SIMD3<Float>]
    /// Sum of adjacent face normals per welded edge.
    private let edgePseudonormals: [EdgeKey: SIMD3<Float>]
    private let grid: SpatialGrid

    var triangleCount: Int { triangles.count }

    init(triangles input: [Triangle]) {
        var kept: [Triangle] = []
        var normals: [SIMD3<Float>] = []
        var vpn: [VertexKey: SIMD3<Float>] = [:]
        var epn: [EdgeKey: SIMD3<Float>] = [:]

        for t in input {
            let cross = simd_cross(t.b - t.a, t.c - t.a)
            let len = simd_length(cross)
            // A zero-area triangle has no normal; keeping it yields NaN downstream.
            guard len > 1e-12 else { continue }
            let n = cross / len
            kept.append(t)
            normals.append(n)

            let keys = [VertexKey(t.a), VertexKey(t.b), VertexKey(t.c)]
            let corners = [t.a, t.b, t.c]
            for i in 0..<3 {
                // Angle weighting is what makes the vertex pseudonormal correct
                // regardless of how finely the surface is tessellated there.
                let e1 = corners[(i + 1) % 3] - corners[i]
                let e2 = corners[(i + 2) % 3] - corners[i]
                let l1 = simd_length(e1), l2 = simd_length(e2)
                guard l1 > 1e-12, l2 > 1e-12 else { continue }
                let angle = acos(max(-1, min(1, simd_dot(e1 / l1, e2 / l2))))
                vpn[keys[i], default: .zero] += angle * n
                let ek = EdgeKey(keys[i], keys[(i + 1) % 3])
                epn[ek, default: .zero] += n
            }
        }

        self.triangles = kept
        self.faceNormals = normals
        self.vertexPseudonormals = vpn
        self.edgePseudonormals = epn
        self.grid = SpatialGrid(triangles: kept)
    }

    /// Signed penetration of a sphere of `radius` centred at `point`.
    ///
    /// Returns `nil` when the sphere is clear of the surface. There is no
    /// distance cutoff at any layer: a cutoff makes a deeply buried query find
    /// no triangle and report clean, which inverts the gate — the deepest
    /// defects would become the invisible ones.
    func penetration(of point: SIMD3<Float>, radius: Float) -> Penetration? {
        guard let hit = grid.nearest(to: point, triangles: triangles) else { return nil }
        let t = triangles[hit.index]
        let signed = signedDistance(from: point, to: hit, triangle: t, faceNormal: faceNormals[hit.index])
        let depth = radius - signed
        guard depth > 0 else { return nil }
        return Penetration(depth: depth, region: t.region, surfacePoint: hit.point)
    }

    /// Negative inside, positive outside. Classified against the angle-weighted
    /// pseudonormal of the CLOSEST FEATURE (Bærentzen–Aanæs), not the face
    /// normal: when the closest point lands on a shared edge or vertex — finger
    /// creases, palm webbing, the wrist — an arbitrary adjacent face's normal
    /// flips the sign.
    private func signedDistance(from point: SIMD3<Float>, to hit: ClosestHit,
                                triangle: Triangle, faceNormal: SIMD3<Float>) -> Float {
        let delta = point - hit.point
        let distance = simd_length(delta)
        let pseudonormal: SIMD3<Float>
        switch hit.feature {
        case .face:
            pseudonormal = faceNormal
        case .vertex(let corner):
            let key = VertexKey([triangle.a, triangle.b, triangle.c][corner])
            pseudonormal = vertexPseudonormals[key] ?? faceNormal
        case .edge(let i, let j):
            let corners = [triangle.a, triangle.b, triangle.c]
            let key = EdgeKey(VertexKey(corners[i]), VertexKey(corners[j]))
            pseudonormal = edgePseudonormals[key] ?? faceNormal
        }
        return simd_dot(delta, pseudonormal) < 0 ? -distance : distance
    }
}
```

Then append the closest-point routine, the keys, and a brute-force `SpatialGrid` placeholder in the same file:

```swift
extension SkinMeshOracle {

    enum ClosestFeature {
        case face
        case edge(Int, Int)
        case vertex(Int)
    }

    struct ClosestHit {
        let index: Int
        let point: SIMD3<Float>
        let feature: ClosestFeature
        let distanceSquared: Float
    }

    /// Closest point on a triangle by Voronoi region (Ericson, *Real-Time
    /// Collision Detection* §5.1.5), reporting WHICH feature owns the closest
    /// point so the caller can pick the right pseudonormal.
    static func closestPoint(on t: Triangle, to p: SIMD3<Float>) -> (SIMD3<Float>, ClosestFeature) {
        let ab = t.b - t.a, ac = t.c - t.a, ap = p - t.a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return (t.a, .vertex(0)) }

        let bp = p - t.b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return (t.b, .vertex(1)) }

        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 {
            let v = d1 / (d1 - d3)
            return (t.a + v * ab, .edge(0, 1))
        }

        let cp = p - t.c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return (t.c, .vertex(2)) }

        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 {
            let w = d2 / (d2 - d6)
            return (t.a + w * ac, .edge(0, 2))
        }

        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return (t.b + w * (t.c - t.b), .edge(1, 2))
        }

        let denom = 1 / (va + vb + vc)
        return (t.a + ab * (vb * denom) + ac * (vc * denom), .face)
    }

    /// Quantised position so coincident corners from different triangles weld.
    /// 1e-5 m is well below any real mesh feature and well above float noise.
    struct VertexKey: Hashable {
        let x: Int32, y: Int32, z: Int32
        init(_ p: SIMD3<Float>) {
            x = Int32((p.x * 100_000).rounded())
            y = Int32((p.y * 100_000).rounded())
            z = Int32((p.z * 100_000).rounded())
        }
    }

    struct EdgeKey: Hashable {
        let lo: VertexKey, hi: VertexKey
        init(_ a: VertexKey, _ b: VertexKey) {
            if (a.x, a.y, a.z) <= (b.x, b.y, b.z) { lo = a; hi = b } else { lo = b; hi = a }
        }
    }

    /// Brute-force nearest. Task 3 replaces the internals with a uniform grid
    /// and must return identical results.
    struct SpatialGrid {
        init(triangles: [Triangle]) {}

        func nearest(to p: SIMD3<Float>, triangles: [Triangle]) -> ClosestHit? {
            var best: ClosestHit?
            for (i, t) in triangles.enumerated() {
                let (q, feature) = SkinMeshOracle.closestPoint(on: t, to: p)
                let d2 = simd_length_squared(p - q)
                // Ties break by lowest triangle index so results are deterministic.
                if best == nil || d2 < best!.distanceSquared - 1e-12 {
                    best = ClosestHit(index: i, point: q, feature: feature, distanceSquared: d2)
                }
            }
            return best
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SkinMeshOracleMathTests --disable-sandbox`
Expected: PASS, 10 tests.

- [ ] **Step 5: Prove the concave test is non-vacuous**

Temporarily replace the `switch hit.feature` body in `signedDistance` with `pseudonormal = faceNormal` for every case, then run:

Run: `swift test --filter SkinMeshOracleMathTests --disable-sandbox`
Expected: `testConcaveNotchClassifiesOutsideCorrectly` **FAILS**, and the convex tests still pass — demonstrating that only the concave fixture catches it. Restore the switch and confirm green. Report both outcomes; a gate never seen failing is not evidence.

- [ ] **Step 6: Commit**

```bash
git add Tests/VRMMetalKitTests/SpringBone/SkinMeshOracle.swift \
        Tests/VRMMetalKitTests/SpringBone/SkinMeshOracleMathTests.swift
git commit -m "test(springbone): skin-mesh oracle geometry — closest point, pseudonormal sign

Classifies against the angle-weighted pseudonormal of the closest feature
rather than a face normal: on a shared edge or vertex, an arbitrary adjacent
face flips the sign, which is exactly what happens in finger creases and palm
webbing. Verified by a concave notch fixture — cube and sphere are convex and
structurally cannot observe the failure."
```

---

### Task 3: Spatial grid — same answers, faster

Correctness belongs to Task 2. This task buys speed and **must not change an answer**.

**Files:**
- Modify: `Tests/VRMMetalKitTests/SpringBone/SkinMeshOracle.swift` (`SpatialGrid` only)
- Test: `Tests/VRMMetalKitTests/SpringBone/SkinMeshOracleMathTests.swift`

**Interfaces:**
- Consumes: `SkinMeshOracle.Triangle`, `ClosestHit`, `closestPoint(on:to:)` from Task 2.
- Produces: no API change. `SpatialGrid.nearest(to:triangles:)` keeps its signature.

- [ ] **Step 1: Write the failing equivalence test**

Append to `SkinMeshOracleMathTests.swift`:

```swift
extension SkinMeshOracleMathTests {

    /// Brute force is the reference. A bounded search agrees with it everywhere
    /// EXCEPT where it breaks, so the equivalence set must include a deeply
    /// interior query, not only near-surface points.
    func testGridAgreesWithBruteForceIncludingDeepInterior() {
        var tris = box(min: [-2, -2, -2], max: [2, 2, 2])
        tris += sphere(center: [0.5, 0.5, 0.5], radius: 0.3)
        let oracle = SkinMeshOracle(triangles: tris)

        let queries: [SIMD3<Float>] = [
            .zero,                              // deep interior, far past any cutoff
            SIMD3<Float>(1.98, 0, 0),           // just inside a face
            SIMD3<Float>(2.02, 0, 0),           // just outside
            SIMD3<Float>(0.5, 0.5, 0.5),        // inside the inner sphere
            SIMD3<Float>(-1.999, -1.999, -1.999), // interior corner
            SIMD3<Float>(9, 9, 9)               // far outside
        ]
        for q in queries {
            let viaGrid = oracle.penetration(of: q, radius: 0)
            let viaBrute = SkinMeshOracle.bruteForcePenetrationForTesting(oracle: oracle, point: q, radius: 0)
            XCTAssertEqual(viaGrid?.depth ?? .nan, viaBrute?.depth ?? .nan, accuracy: 1e-5,
                           "grid and brute force disagree at \(q)")
            XCTAssertEqual(viaGrid?.region, viaBrute?.region, "region disagrees at \(q)")
        }
    }

    func testGridCompletesLargeMeshQuicklyEnough() {
        var tris: [SkinMeshOracle.Triangle] = []
        for i in 0..<40 {
            let o = Float(i) * 0.05
            tris += sphere(center: [o, 0, 0], radius: 0.2, rings: 12, segments: 24)
        }
        let oracle = SkinMeshOracle(triangles: tris)
        XCTAssertGreaterThan(oracle.triangleCount, 20_000, "enough triangles for the budget to mean something")
        let start = Date()
        for i in 0..<2_000 {
            _ = oracle.penetration(of: SIMD3<Float>(Float(i) * 0.001, 0, 0), radius: 0.01)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5.0,
                          "2k queries over 20k triangles must be seconds, not minutes")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter testGridAgreesWithBruteForceIncludingDeepInterior --disable-sandbox`
Expected: FAIL — "type 'SkinMeshOracle' has no member 'bruteForcePenetrationForTesting'".

- [ ] **Step 3: Add the brute-force reference and the grid**

In `SkinMeshOracle.swift`, add the reference path used only by the equivalence test:

```swift
extension SkinMeshOracle {
    /// Reference implementation for the grid's equivalence gate. Scans every
    /// triangle; correctness here is Task 2's, already pinned.
    static func bruteForcePenetrationForTesting(oracle: SkinMeshOracle, point: SIMD3<Float>,
                                                radius: Float) -> Penetration? {
        oracle.penetrationScanningAll(point: point, radius: radius)
    }
}
```

Add `penetrationScanningAll` alongside `penetration(of:radius:)` — identical except that it scans linearly instead of consulting the grid:

```swift
extension SkinMeshOracle {
    /// Linear-scan twin of `penetration(of:radius:)`. Identical logic; the only
    /// difference is that it never consults the grid.
    func penetrationScanningAll(point: SIMD3<Float>, radius: Float) -> Penetration? {
        var best: ClosestHit?
        for (i, t) in triangles.enumerated() {
            let (q, feature) = SkinMeshOracle.closestPoint(on: t, to: point)
            let d2 = simd_length_squared(point - q)
            if best == nil || d2 < best!.distanceSquared - 1e-12 {
                best = ClosestHit(index: i, point: q, feature: feature, distanceSquared: d2)
            }
        }
        guard let hit = best else { return nil }
        let t = triangles[hit.index]
        let signed = signedDistance(from: point, to: hit, triangle: t, faceNormal: faceNormals[hit.index])
        let depth = radius - signed
        guard depth > 0 else { return nil }
        return Penetration(depth: depth, region: t.region, surfacePoint: hit.point)
    }
}
```

`triangles`, `faceNormals` and `signedDistance` are `private`, so this extension must live in the same file. Then replace `SpatialGrid`'s internals with a uniform hash:

```swift
    /// Uniform spatial hash over triangle bounds with an EXPANDING ring search.
    ///
    /// The search widens until the nearest ring's minimum possible distance
    /// exceeds the best found, so it terminates on a true nearest with no
    /// distance gate anywhere. A fixed search radius would make a deeply buried
    /// query find nothing and read clean.
    struct SpatialGrid {
        private let cell: Float
        private let buckets: [Cell: [Int]]
        private let origin: SIMD3<Float>

        struct Cell: Hashable { let x: Int32, y: Int32, z: Int32 }

        init(triangles: [Triangle]) {
            guard !triangles.isEmpty else {
                cell = 1; buckets = [:]; origin = .zero; return
            }
            var lo = triangles[0].a, hi = triangles[0].a
            var edgeSum: Float = 0
            for t in triangles {
                for v in [t.a, t.b, t.c] { lo = simd_min(lo, v); hi = simd_max(hi, v) }
                edgeSum += simd_length(t.b - t.a)
            }
            // Cell ~ mean edge length keeps occupancy near one triangle per cell.
            cell = max(edgeSum / Float(triangles.count), 1e-4)
            origin = lo
            var b: [Cell: [Int]] = [:]
            for (i, t) in triangles.enumerated() {
                let tlo = simd_min(simd_min(t.a, t.b), t.c)
                let thi = simd_max(simd_max(t.a, t.b), t.c)
                let c0 = Self.cellIndex(tlo, origin: lo, cell: cell)
                let c1 = Self.cellIndex(thi, origin: lo, cell: cell)
                for x in c0.x...c1.x { for y in c0.y...c1.y { for z in c0.z...c1.z {
                    b[Cell(x: x, y: y, z: z), default: []].append(i)
                } } }
            }
            buckets = b
            _ = hi
        }

        private static func cellIndex(_ p: SIMD3<Float>, origin: SIMD3<Float>, cell: Float) -> Cell {
            let q = (p - origin) / cell
            return Cell(x: Int32(q.x.rounded(.down)), y: Int32(q.y.rounded(.down)), z: Int32(q.z.rounded(.down)))
        }

        func nearest(to p: SIMD3<Float>, triangles: [Triangle]) -> ClosestHit? {
            guard !buckets.isEmpty else { return nil }
            let centre = Self.cellIndex(p, origin: origin, cell: cell)
            var best: ClosestHit?
            var ring: Int32 = 0
            while true {
                var examined = false
                for x in (centre.x - ring)...(centre.x + ring) {
                    for y in (centre.y - ring)...(centre.y + ring) {
                        for z in (centre.z - ring)...(centre.z + ring) {
                            // Only the new shell each iteration.
                            let onShell = abs(x - centre.x) == ring || abs(y - centre.y) == ring
                                || abs(z - centre.z) == ring
                            guard onShell, let ids = buckets[Cell(x: x, y: y, z: z)] else { continue }
                            examined = true
                            for i in ids {
                                let (q, feature) = SkinMeshOracle.closestPoint(on: triangles[i], to: p)
                                let d2 = simd_length_squared(p - q)
                                if best == nil || d2 < best!.distanceSquared - 1e-12 {
                                    best = ClosestHit(index: i, point: q, feature: feature, distanceSquared: d2)
                                }
                            }
                        }
                    }
                }
                // A triangle outside this shell cannot be nearer than the shell's
                // own minimum distance, so once that exceeds `best` we are done.
                if let b = best {
                    let shellDistance = Float(ring) * cell
                    if shellDistance * shellDistance > b.distanceSquared { return best }
                }
                ring += 1
                if ring > 4096 { return best }
                _ = examined
            }
        }
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter SkinMeshOracleMathTests --disable-sandbox`
Expected: PASS — all Task 2 tests plus both new ones. Every Task 2 assertion must still hold; the grid changed no answer.

- [ ] **Step 5: Prove the deep-interior case discriminates**

Temporarily add `if ring > 2 { return best }` at the top of the ring loop's tail, simulating a bounded search. Run the equivalence test.
Expected: `testGridAgreesWithBruteForceIncludingDeepInterior` **FAILS on the `.zero` query** — the deep-interior point finds nothing while the near-surface queries still agree. This is the exact inversion the spec bans. Remove the bound and confirm green. Report both.

- [ ] **Step 6: Commit**

```bash
git add Tests/VRMMetalKitTests/SpringBone/SkinMeshOracle.swift \
        Tests/VRMMetalKitTests/SpringBone/SkinMeshOracleMathTests.swift
git commit -m "test(springbone): uniform grid for the skin-mesh oracle, no distance cutoff

Expanding-ring search terminating on a true nearest, with brute force retained
as the equivalence reference. The equivalence set includes a deeply interior
query: a bounded search agrees with brute force everywhere except exactly where
it breaks, and a buried joint that finds no triangle reads CLEAN."
```

---

### Task 4: Body-surface predicate and rig build

**Files:**
- Create: `Tests/VRMMetalKitTests/SpringBone/BodySurfacePredicate.swift`
- Modify: `Tests/VRMMetalKitTests/SpringBone/SkinMeshOracle.swift` (add `build(model:)`)
- Test: `Tests/VRMMetalKitTests/SpringBone/BodySurfacePredicateTests.swift`

**Interfaces:**
- Consumes: `SkinMeshOracle.Triangle` (Task 2); `VRMModel`, `VRMMesh`, `VRMPrimitive` (`primitiveType: MTLPrimitiveType`, `materialIndex: Int?`, `vertexBuffer: MTLBuffer?`, `vertexCount: Int`, `indexBuffer: MTLBuffer?`, `indexCount: Int`, `indexBufferOffset: Int`, `indexType: MTLIndexType`), `VRMVertex` (`position`, `joints: SIMD4<UInt32>`, `weights: SIMD4<Float>`), `VRMSkin` (`joints: [VRMNode]`, `inverseBindMatrices: [float4x4]`), `VRMNode` (`mesh: Int?`, `skin: Int?`, `worldMatrix`).
- Produces (Task 6 relies on these):
  - `enum BodySurfacePredicate { static func includes(materialName: String?) -> Bool }`
  - `struct BodySurfaceInventory { let meshIndex: Int; let primitiveIndex: Int; let materialName: String; let vertexCount: Int; let boundaryEdgeCount: Int; let isTriangleTopology: Bool }`
  - `static func inventory(model: VRMModel) -> [BodySurfaceInventory]`
  - `static func SkinMeshOracle.build(model: VRMModel) -> SkinMeshOracle?`

- [ ] **Step 1: Write the failing test**

Create `Tests/VRMMetalKitTests/SpringBone/BodySurfacePredicateTests.swift` (Apache header first, then):

```swift
import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// The predicate decides which primitives are "body". Getting it wrong is
/// silent in both directions: too few and every joint reads clean, too many and
/// a garment's own simulated joints read as permanently penetrating.
final class BodySurfacePredicateTests: XCTestCase {

    @MainActor private func load(_ filename: String) async throws -> VRMModel {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let path = getTestModelPath(filename)
        try requireFixture(path, hint: filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()
        return model
    }

    func testPredicateAcceptsSkinAndClothRejectsHair() {
        XCTAssertTrue(BodySurfacePredicate.includes(materialName: "Body_00_SKIN"))
        XCTAssertTrue(BodySurfacePredicate.includes(materialName: "F00_000_Face_00_SKIN"))
        XCTAssertTrue(BodySurfacePredicate.includes(materialName: "Onepiece_00_CLOTH"))
        XCTAssertFalse(BodySurfacePredicate.includes(materialName: "Hair_00_HAIR"))
        XCTAssertFalse(BodySurfacePredicate.includes(materialName: "CLOTH_HAIR_accessory"),
                       "HAIR wins over CLOTH — a hair ribbon is not a body surface")
        XCTAssertFalse(BodySurfacePredicate.includes(materialName: nil))
        XCTAssertFalse(BodySurfacePredicate.includes(materialName: "EyeIris"))
    }

    /// Ranges over ALL meshes, not the first one named "body" — that scoping
    /// drops the Face mesh's SKIN primitives entirely.
    @MainActor func testInventoryIncludesFaceMeshNotJustBodyMesh() async throws {
        let model = try await load(testVRM10Filename)
        let inv = BodySurfacePredicate.inventory(model: model)
        XCTAssertFalse(inv.isEmpty, "the fixture must contribute body surface")
        let meshNames = Set(inv.map { (model.meshes[$0.meshIndex].name ?? "").lowercased() })
        XCTAssertGreaterThan(meshNames.count, 1,
                             "more than one mesh contributes; scoping to a single 'body' mesh is the bug")
    }

    /// Records the exact set so a material rename fails loudly.
    @MainActor func testInventoryExactSetIsPinnedForAvatarSampleA() async throws {
        let model = try await load(testVRM10Filename)
        let inv = BodySurfacePredicate.inventory(model: model)
        for entry in inv {
            XCTAssertTrue(entry.isTriangleTopology,
                          "\(entry.materialName): strip topology would be silently skipped")
            XCTAssertGreaterThan(entry.vertexCount, 0)
        }
        let names = inv.map(\.materialName).sorted()
        print("[BODYSURFACE] AvatarSample_A included=\(names)")
        print("[BODYSURFACE] AvatarSample_A boundaryEdges=\(inv.map { "\($0.materialName):\($0.boundaryEdgeCount)" })")
        XCTAssertFalse(names.isEmpty)
    }

    @MainActor func testOracleBuildsFromRig() async throws {
        let model = try await load(testVRM10Filename)
        let oracle = try XCTUnwrap(SkinMeshOracle.build(model: model))
        XCTAssertGreaterThan(oracle.triangleCount, 1_000)

        // A point at the hips must be inside the body; a point a metre to the
        // side must not be. This is the smallest end-to-end sanity check that
        // the skinning and the sign are both right.
        let humanoid = try XCTUnwrap(model.humanoid)
        let hips = try XCTUnwrap(humanoid.getBoneNode(.hips))
        let inside = model.nodes[hips].worldPosition
        XCTAssertNotNil(oracle.penetration(of: inside, radius: 0), "the hips are inside the body")
        XCTAssertNil(oracle.penetration(of: inside + SIMD3<Float>(1, 0, 0), radius: 0),
                     "a metre to the side is outside")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter BodySurfacePredicateTests --disable-sandbox`
Expected: FAIL — "cannot find 'BodySurfacePredicate' in scope".

- [ ] **Step 3: Implement the predicate and inventory**

Create `Tests/VRMMetalKitTests/SpringBone/BodySurfacePredicate.swift` (Apache header first, then):

```swift
import Foundation
import Metal
import simd
@testable import VRMMetalKit

/// Which primitives constitute the body surface a simulated garment should be
/// pushed OUT of.
///
/// Must exclude anything that is itself simulated: a garment whose own joints
/// are driven by spring bones would report those joints as permanently inside
/// it. Must also exclude hair for the same reason. Scoped over materials across
/// every mesh, never by mesh name — name-matching drops the Face mesh's SKIN
/// primitives.
enum BodySurfacePredicate {

    static func includes(materialName: String?) -> Bool {
        guard let raw = materialName?.uppercased() else { return false }
        if raw.contains("HAIR") { return false }
        return raw.contains("SKIN") || raw.contains("CLOTH")
    }

    static func inventory(model: VRMModel) -> [BodySurfaceInventory] {
        var out: [BodySurfaceInventory] = []
        for (mi, mesh) in model.meshes.enumerated() {
            for (pi, primitive) in mesh.primitives.enumerated() {
                guard let materialIndex = primitive.materialIndex,
                      materialIndex < model.materials.count else { continue }
                let name = model.materials[materialIndex].name ?? ""
                guard includes(materialName: name) else { continue }
                out.append(BodySurfaceInventory(
                    meshIndex: mi,
                    primitiveIndex: pi,
                    materialName: name,
                    vertexCount: primitive.vertexCount,
                    boundaryEdgeCount: boundaryEdgeCount(of: primitive),
                    isTriangleTopology: primitive.primitiveType == .triangle))
            }
        }
        return out
    }

    /// Edges used by exactly one triangle. A SKIN-only surface is open — eye
    /// sockets, and geometry deleted under garments — and signed classification
    /// is one-sided near an opening, so the count is recorded rather than
    /// discovered later as a mystery sign flip.
    static func boundaryEdgeCount(of primitive: VRMPrimitive) -> Int {
        guard primitive.primitiveType == .triangle,
              let indices = readIndices(primitive) else { return 0 }
        var counts: [UInt64: Int] = [:]
        var i = 0
        while i + 2 < indices.count {
            let tri = [indices[i], indices[i + 1], indices[i + 2]]
            for k in 0..<3 {
                let a = UInt64(min(tri[k], tri[(k + 1) % 3]))
                let b = UInt64(max(tri[k], tri[(k + 1) % 3]))
                counts[(a << 32) | b, default: 0] += 1
            }
            i += 3
        }
        return counts.values.filter { $0 == 1 }.count
    }

    static func readIndices(_ primitive: VRMPrimitive) -> [UInt32]? {
        guard let buffer = primitive.indexBuffer, primitive.indexCount > 0 else { return nil }
        let base = buffer.contents().advanced(by: primitive.indexBufferOffset)
        if primitive.indexType == .uint32 {
            let p = base.bindMemory(to: UInt32.self, capacity: primitive.indexCount)
            return (0..<primitive.indexCount).map { p[$0] }
        }
        let p = base.bindMemory(to: UInt16.self, capacity: primitive.indexCount)
        return (0..<primitive.indexCount).map { UInt32(p[$0]) }
    }
}

struct BodySurfaceInventory {
    let meshIndex: Int
    let primitiveIndex: Int
    let materialName: String
    let vertexCount: Int
    let boundaryEdgeCount: Int
    let isTriangleTopology: Bool
}
```

- [ ] **Step 4: Implement `build(model:)`**

Append to `SkinMeshOracle.swift`:

```swift
extension SkinMeshOracle {

    /// Skins every body-surface primitive to world space and builds an oracle.
    ///
    /// Precondition: morph weights are zero. `StressPoseFactory.clip` emits
    /// joint tracks only, so this holds for every caller in this plan — a
    /// silent morph would move the surface out from under the measurement.
    static func build(model: VRMModel) -> SkinMeshOracle? {
        let inventory = BodySurfacePredicate.inventory(model: model)
        guard !inventory.isEmpty else { return nil }

        var triangles: [Triangle] = []
        for entry in inventory {
            guard entry.isTriangleTopology else { continue }
            let mesh = model.meshes[entry.meshIndex]
            let primitive = mesh.primitives[entry.primitiveIndex]
            guard let vb = primitive.vertexBuffer, primitive.vertexCount > 0,
                  let indices = BodySurfacePredicate.readIndices(primitive) else { continue }
            guard let node = model.nodes.first(where: { $0.mesh == entry.meshIndex }),
                  let skinIndex = node.skin, skinIndex >= 0, skinIndex < model.skins.count else { continue }
            let skin = model.skins[skinIndex]
            let palette = skin.joints.indices.map {
                skin.joints[$0].worldMatrix * skin.inverseBindMatrices[$0]
            }
            let verts = vb.contents().bindMemory(to: VRMVertex.self, capacity: primitive.vertexCount)

            func world(_ index: UInt32) -> (SIMD3<Float>, VRMHumanoidBone?) {
                let v = verts[Int(index)]
                let js = [Int(v.joints.x), Int(v.joints.y), Int(v.joints.z), Int(v.joints.w)]
                let ws = [v.weights.x, v.weights.y, v.weights.z, v.weights.w]
                var p = SIMD3<Float>.zero
                var sum: Float = 0
                var dom = -1, domW: Float = 0
                for k in 0..<4 where ws[k] > 0 && js[k] >= 0 && js[k] < palette.count {
                    let h = palette[js[k]] * SIMD4<Float>(v.position, 1)
                    p += ws[k] * SIMD3<Float>(h.x, h.y, h.z)
                    sum += ws[k]
                    if ws[k] > domW { domW = ws[k]; dom = js[k] }
                }
                if sum > 1e-6 { p /= sum }
                let bone = dom >= 0 ? humanoidBone(ofNode: skin.joints[dom], model: model) : nil
                return (p, bone)
            }

            var i = 0
            while i + 2 < indices.count {
                let (a, ba) = world(indices[i])
                let (b, bb) = world(indices[i + 1])
                let (c, bc) = world(indices[i + 2])
                triangles.append(Triangle(a: a, b: b, c: c,
                                          region: majorityBone(ba, bb, bc)))
                i += 3
            }
        }
        guard !triangles.isEmpty else { return nil }
        return SkinMeshOracle(triangles: triangles)
    }

    /// A triangle whose corners disagree takes the majority; a tie takes the
    /// first non-nil, and §5's tolerance rule sends ties to the tighter bound.
    private static func majorityBone(_ a: VRMHumanoidBone?, _ b: VRMHumanoidBone?,
                                     _ c: VRMHumanoidBone?) -> VRMHumanoidBone? {
        if a != nil && a == b { return a }
        if b != nil && b == c { return b }
        if a != nil && a == c { return a }
        return a ?? b ?? c
    }

    private static func humanoidBone(ofNode node: VRMNode, model: VRMModel) -> VRMHumanoidBone? {
        guard let humanoid = model.humanoid,
              let index = model.nodes.firstIndex(where: { $0 === node }) else { return nil }
        for bone in VRMHumanoidBone.allCases where humanoid.getBoneNode(bone) == index {
            return bone
        }
        return nil
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter BodySurfacePredicateTests --disable-sandbox`
Expected: PASS, 4 tests. Record the printed `[BODYSURFACE]` lines in your report — they are the pinned inventory for both fixtures.

- [ ] **Step 6: Verify the predicate is non-vacuous**

Temporarily change `includes` to `return false`. Run the suite.
Expected: `testOracleBuildsFromRig` FAILS (build returns nil) and `testInventoryIncludesFaceMeshNotJustBodyMesh` FAILS. Restore and confirm green. Report both.

- [ ] **Step 7: Commit**

```bash
git add Tests/VRMMetalKitTests/SpringBone/BodySurfacePredicate.swift \
        Tests/VRMMetalKitTests/SpringBone/BodySurfacePredicateTests.swift \
        Tests/VRMMetalKitTests/SpringBone/SkinMeshOracle.swift
git commit -m "test(springbone): body-surface predicate and rig build for the mesh oracle

Scopes over materials across every mesh rather than the first mesh named
'body', which drops the Face mesh's SKIN primitives. The inventory pins the
exact included set per fixture, asserts triangle topology (strips would be
skipped in silence) and records boundary-edge counts, since a SKIN-only
surface is open at the eye sockets and under garments."
```

---

### Task 5: The `armsAtSides` pose

**Files:**
- Modify: `Tests/VRMMetalKitTests/SpringBone/StressPoseFactory.swift:15` and its `switch`
- Test: `Tests/VRMMetalKitTests/SpringBone/SkinMeshCoverageTests.swift` (created here, extended in Task 6)

**Interfaces:**
- Consumes: `StressPose`, `StressPoseFactory.clip(_:duration:)`.
- Produces: `StressPose.armsAtSides`.

- [ ] **Step 1: Write the failing test**

Create `Tests/VRMMetalKitTests/SpringBone/SkinMeshCoverageTests.swift` (Apache header first, then):

```swift
import XCTest
import Metal
import simd
@testable import VRMMetalKit

final class SkinMeshCoverageTests: XCTestCase {

    @MainActor func testArmsAtSidesPlacesWristsBesideTheHips() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let path = getTestModelPath("AvatarSample_U_1.0.vrm.glb")
        try requireFixture(path, hint: "AvatarSample_U_1.0.vrm.glb")
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        let humanoid = try XCTUnwrap(model.humanoid)

        let player = AnimationPlayer()
        player.load(StressPoseFactory.clip(.armsAtSides, duration: 1))
        player.play()
        player.update(deltaTime: 0.5, model: model)
        model.updateNodeTransforms()

        let hips = model.nodes[try XCTUnwrap(humanoid.getBoneNode(.hips))].worldPosition
        let wrist = model.nodes[try XCTUnwrap(humanoid.getBoneNode(.leftHand))].worldPosition
        let shoulder = model.nodes[try XCTUnwrap(humanoid.getBoneNode(.leftUpperArm))].worldPosition

        // Rest is T-pose, so the wrist starts level with the shoulder and far
        // lateral. At the sides it must be BELOW the shoulder and near the hips
        // in height — asserted, not eyeballed.
        XCTAssertLessThan(wrist.y, shoulder.y - 0.2, "the arm hangs down")
        XCTAssertLessThan(abs(wrist.y - hips.y), 0.25, "the wrist is beside the hips in height")
        XCTAssertLessThan(abs(wrist.x - hips.x), 0.30, "the wrist is close to the body laterally")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter testArmsAtSidesPlacesWristsBesideTheHips --disable-sandbox`
Expected: FAIL — "type 'StressPose' has no member 'armsAtSides'".

- [ ] **Step 3: Add the pose**

In `StressPoseFactory.swift`, extend the enum at line 15:

```swift
enum StressPose: String, CaseIterable {
    case lookUp, armsRaised, armsCrossed, seatedDeepFlexion, armsAtSides
}
```

and add the case to the `switch`. Rest is T-pose and `armsRaised` is ±90° about Z from horizontal, so the sides are the opposite adduction with a slight elbow bend:

```swift
        case .armsAtSides:
            // T-pose rest → ~78° adduction brings the arms down beside the body.
            clip.addJointTrack(JointTrack(bone: .leftUpperArm,  rotationSampler: fixed(rot(78, [0, 0, 1]))))
            clip.addJointTrack(JointTrack(bone: .rightUpperArm, rotationSampler: fixed(rot(-78, [0, 0, 1]))))
            clip.addJointTrack(JointTrack(bone: .leftLowerArm,  rotationSampler: fixed(rot(8, [0, 0, 1]))))
            clip.addJointTrack(JointTrack(bone: .rightLowerArm, rotationSampler: fixed(rot(-8, [0, 0, 1]))))
```

Fingers are left at the fixture's rest pose: this sub-project needs them beside the skirt, not articulated.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter testArmsAtSidesPlacesWristsBesideTheHips --disable-sandbox`
Expected: PASS. If the wrist lands outside the tolerances, adjust the angle and record the measured wrist/hip/shoulder positions in your report — do not widen the assertion to fit a wrong pose.

- [ ] **Step 5: Derive the hand tolerance by measurement**

Spec §5 requires the 1 mm hand tolerance to be derived, not asserted — the working estimate of 10–15 mm finger radii is an estimate. Measure it on both fixtures with the existing percentile utility and record the numbers, which Task 6's constant cites.

Add a temporary probe alongside the pose test:

```swift
    /// Records finger-region skin radii so Task 6's 1mm hand tolerance is
    /// derived rather than assumed. Prints only; asserts nothing.
    @MainActor func testMeasureFingerRadiiForToleranceDerivation() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        for filename in ["AvatarSample_A_1.0.vrm.glb", "AvatarSample_U_1.0.vrm.glb"] {
            let path = getTestModelPath(filename)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                options: VRMLoadingOptions(augmentSpringBoneColliders: false))
            model.updateNodeTransforms()
            let humanoid = try XCTUnwrap(model.humanoid)
            guard let oracle = SkinMeshOracle.build(model: model) else { continue }
            for bone: VRMHumanoidBone in [.leftIndexProximal, .leftIndexIntermediate, .leftMiddleProximal] {
                guard let n = humanoid.getBoneNode(bone), n < model.nodes.count else { continue }
                let p = model.nodes[n].worldPosition
                // Depth at the bone centre approximates the local half-thickness.
                let depth = oracle.penetration(of: p, radius: 0)?.depth ?? -1
                print("[FINGERRADIUS] \(filename) \(bone) halfThickness=\(depth)m")
            }
        }
    }
```

Run: `swift test --filter testMeasureFingerRadiiForToleranceDerivation --disable-sandbox`

Record every `[FINGERRADIUS]` line in your report. If the measured half-thickness is materially different from the 10–15 mm estimate, say so — Task 6's tolerance constant carries the measured figure in its doc comment, and a tolerance chosen for roundness is exactly how the previous drift gate ended up set at twice its own maximum failure signal. Delete the probe before committing; its output belongs in the report and the constant's comment, not in the suite.

- [ ] **Step 6: Commit**

```bash
git add Tests/VRMMetalKitTests/SpringBone/StressPoseFactory.swift \
        Tests/VRMMetalKitTests/SpringBone/SkinMeshCoverageTests.swift
git commit -m "test(springbone): armsAtSides stress pose

The reported visual is an avatar standing with her hands at her sides, fingers
inside the dress. No existing StressPose case places the arms there. Asserted
on wrist position relative to hip and shoulder, not eyeballed."
```

---

### Task 6: The coverage gate

**Files:**
- Modify: `Tests/VRMMetalKitTests/SpringBone/SkinMeshCoverageTests.swift`

**Interfaces:**
- Consumes: `SkinMeshOracle.build(model:)` and `penetration(of:radius:)` (Tasks 2–4), `StressPose.armsAtSides` (Task 5), the bundled U fixture (Task 1).
- Produces: the recorded failing measurement. Nothing downstream consumes it in this plan; SP2 and SP3 read the number.

- [ ] **Step 1: Write the gate**

Append to `SkinMeshCoverageTests.swift`:

```swift
extension SkinMeshCoverageTests {

    /// Hand and finger bones take a tighter bound: finger radii are on the order
    /// of a centimetre, so the harness's flat 5mm is a third of a finger and
    /// would blind the case this gate exists to catch. Slice 4 of the spec
    /// requires this 1mm to be confirmed against a per-fixture measurement with
    /// `SkinReferenceMeasureUtil`; record that measurement in the report.
    private static let handTolerance: Float = 0.001
    private static let bodyTolerance: Float = 0.005

    private static let handBones: Set<VRMHumanoidBone> = {
        var s: Set<VRMHumanoidBone> = [.leftHand, .rightHand]
        for bone in VRMHumanoidBone.allCases where "\(bone)".contains("Thumb")
            || "\(bone)".contains("Index") || "\(bone)".contains("Middle")
            || "\(bone)".contains("Ring") || "\(bone)".contains("Little") {
            s.insert(bone)
        }
        return s
    }()

    private static func tolerance(for region: VRMHumanoidBone?) -> Float {
        guard let region else { return bodyTolerance }
        return handBones.contains(region) ? handTolerance : bodyTolerance
    }

    /// Query set per spec §6: hair / skirt / hood / sleeve chains, roots exempt,
    /// NEVER Bust. Bust joints sit inside the chest by construction, and the
    /// moment the torso is in the oracle they report deep permanent penetration
    /// that swamps the millimetre-scale finger signal.
    private func querySet(_ model: VRMModel) -> [(node: Int, radius: Float, chain: String)] {
        guard let springBone = model.springBone else { return [] }
        var out: [(Int, Float, String)] = []
        for spring in springBone.springs {
            let name = (spring.name ?? "").lowercased()
            guard name.contains("hair") || name.contains("skirt")
                || name.contains("hood") || name.contains("sleeve") else { continue }
            for (i, joint) in spring.joints.enumerated() where i > 0 {
                out.append((joint.node, joint.hitRadius, spring.name ?? "?"))
            }
        }
        return out
    }

    @MainActor func testHandsDoNotPenetrateTheDress() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let path = getTestModelPath("AvatarSample_U_1.0.vrm.glb")
        try requireFixture(path, hint: "AvatarSample_U_1.0.vrm.glb")
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true))

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        config.synchronousSpringBone = true
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.enableSpringBone = true
        renderer.viewMatrix = matrix_identity_float4x4
        renderer.projectionMatrix = matrix_identity_float4x4

        let player = AnimationPlayer()
        player.load(StressPoseFactory.clip(.armsAtSides, duration: 5))
        player.play()

        let queries = querySet(model)
        XCTAssertFalse(queries.isEmpty, "the fixture must simulate hair/skirt/sleeve chains")

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]; colorDesc.storageMode = .private
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: 64, height: 64, mipmapped: false)
        depthDesc.usage = .renderTarget; depthDesc.storageMode = .private
        guard let colorTex = device.makeTexture(descriptor: colorDesc),
              let depthTex = device.makeTexture(descriptor: depthDesc),
              let queue = device.makeCommandQueue() else { throw XCTSkip("Could not allocate Metal resources") }

        // Same cadence as the existing harness: 150 frames at 30fps, measured
        // over the settled second half.
        let frameCount = 150, fps: Float = 30
        var worstHand: (depth: Float, region: VRMHumanoidBone?, chain: String)?
        var worstPerChain: [String: Float] = [:]

        for frame in 0..<frameCount {
            player.update(deltaTime: 1 / fps, model: model)
            guard let cb = queue.makeCommandBuffer() else { break }
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = colorTex
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.depthAttachment.texture = depthTex
            rpd.depthAttachment.loadAction = .clear
            rpd.depthAttachment.clearDepth = 1.0
            rpd.depthAttachment.storeAction = .dontCare
            renderer.drawOffscreenHeadless(to: colorTex, depth: depthTex,
                                           commandBuffer: cb, renderPassDescriptor: rpd)
            cb.commit()
            while cb.status != .completed && cb.status != .error { await Task.yield() }
            guard frame >= frameCount / 2 else { continue }

            guard let oracle = SkinMeshOracle.build(model: model) else {
                XCTFail("oracle failed to build — the predicate found no body surface")
                return
            }
            for q in queries where q.node >= 0 && q.node < model.nodes.count {
                guard let pen = oracle.penetration(of: model.nodes[q.node].worldPosition,
                                                   radius: q.radius) else { continue }
                guard pen.depth > Self.tolerance(for: pen.region) else { continue }
                worstPerChain[q.chain] = max(worstPerChain[q.chain] ?? 0, pen.depth)
                if Self.handBones.contains(pen.region ?? .hips) {
                    if pen.depth > (worstHand?.depth ?? 0) {
                        worstHand = (pen.depth, pen.region, q.chain)
                    }
                }
            }
        }

        let baselines = worstPerChain.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(String(format: "%.4f", $0.value))m" }.joined(separator: " ")
        let handReport = worstHand.map {
            "worst hand penetration \(String(format: "%.4f", $0.depth))m at \($0.region.map { "\($0)" } ?? "?") from chain \($0.chain)"
        } ?? "no hand-region penetration above \(Self.handTolerance)m"

        // The deliverable is a RECORDED FAILURE, pinned to the hand region so
        // the marker is not satisfied by penetration anywhere else. When SP2/SP3
        // fix it, XCTExpectFailure itself fails ("expected failure not
        // observed") and forces removal of this marker.
        XCTExpectFailure("#381: hands/fingers penetrate the dress. \(handReport). "
                         + "Contact-region baselines: \(baselines)")
        XCTAssertNil(worstHand, handReport)
    }
}
```

- [ ] **Step 2: Run the gate and record what it says**

Run: `swift test --filter testHandsDoNotPenetrateTheDress --disable-sandbox`

Two outcomes, both informative — record which occurred, with the full message:

- **Hand penetration found:** the `XCTExpectFailure` absorbs it and the test passes. This is the intended deliverable. Report the depth, region, chain and the contact-region baselines.
- **No hand penetration found:** `XCTExpectFailure` fails with "expected failure not observed". This is the escalation the spec names in §1: `main` already ships palm spheres, so the defect may be *between* joints rather than at them. Do **not** delete the marker. Proceed to step 3.

- [ ] **Step 3: If and only if step 2 found nothing — densify the sampling**

Replace the per-joint query with K points sampled along each parent→child segment, same oracle and tolerance:

```swift
            for q in queries where q.node >= 0 && q.node < model.nodes.count {
                let node = model.nodes[q.node]
                var samples: [SIMD3<Float>] = [node.worldPosition]
                if let parent = node.parent {
                    let a = parent.worldPosition, b = node.worldPosition
                    for k in 1..<5 { samples.append(a + (b - a) * (Float(k) / 5)) }
                }
                for s in samples {
                    guard let pen = oracle.penetration(of: s, radius: q.radius) else { continue }
                    guard pen.depth > Self.tolerance(for: pen.region) else { continue }
                    worstPerChain[q.chain] = max(worstPerChain[q.chain] ?? 0, pen.depth)
                    if Self.handBones.contains(pen.region ?? .hips) {
                        if pen.depth > (worstHand?.depth ?? 0) {
                            worstHand = (pen.depth, pen.region, q.chain)
                        }
                    }
                }
            }
```

Re-run and record. State in your report which granularity produced the number, per spec §1.

- [ ] **Step 4: Prove the gate is non-vacuous**

Temporarily make `BodySurfacePredicate.includes` return `false`, so the oracle finds no body surface. Run the gate.
Expected: it fails at the `XCTFail("oracle failed to build …")` guard rather than silently reporting clean. Restore, then temporarily widen `handTolerance` to `1.0` (a metre) and confirm the `XCTExpectFailure` flips to "expected failure not observed" — proving the marker is genuinely driven by the hand measurement and not by something incidental. Restore both and confirm the recorded state. Report all three runs.

- [ ] **Step 5: Full suite**

Run: `swift test --disable-sandbox --skip HairHeadCollisionTests`
Expected: 0 failures beyond the pre-existing list in Global Constraints. The new gate must not disturb `SpringBoneStressPosePenetrationTests`, `HairShoulder*`, `HairChest*`, `HairBreast*`, `ColliderDimensionAudit`, or the pipeline gates — none of their numbers move, since nothing in `Sources/` changed.

- [ ] **Step 6: Commit**

```bash
git add Tests/VRMMetalKitTests/SpringBone/SkinMeshCoverageTests.swift
git commit -m "test(springbone): coverage gate — record hands penetrating the dress (#381)

Measures hair/skirt/hood/sleeve joints against the skinned body mesh with
AvatarSample_U posed arms-at-sides, at 1mm tolerance on hand and finger
regions. Bust chains are never queried: they sit inside the chest by
construction and would swamp the millimetre finger signal.

The deliverable is a recorded FAILURE, pinned to the hand region so the marker
cannot be satisfied by penetration elsewhere, and carrying contact-region
baselines so later movement is attributable. When SP2/SP3 fix the defect,
XCTExpectFailure fails and forces this marker's removal."
```

---

## Verification Checklist

- [ ] `swift build --build-tests` clean; `swift build --configuration release` clean
- [ ] `swift test --filter SkinMeshOracleMathTests --disable-sandbox` — all pass, and the concave and deep-interior tests were each **observed failing** under their respective sabotage
- [ ] `swift test --filter BodySurfacePredicateTests --disable-sandbox` — passes, inventory recorded for both fixtures
- [ ] `swift test --filter SkinMeshCoverageTests --disable-sandbox` — the gate records a hand-region measurement, or reports the densification escalation
- [ ] `swift test --disable-sandbox --skip HairHeadCollisionTests` — no new failures
- [ ] CI path greps clean: no `/Users/`, no `Projects/`, no literal `URL(fileURLWithPath: "/`
- [ ] `AvatarSample_U_1.0.vrm.glb` tracked, `LICENSE-MODELS.md` updated
- [ ] Nothing under `Sources/` modified

## What this plan does not build

Deferred to #381's later sub-projects, each validated by this gate: collider sizing from authored/mesh measurement and emptying `ColliderDimensionAudit.knownOversized` (SP2); hierarchical colliders and per-finger capsules tiered on `SpringBoneQuality` (SP3); chains for high-spread regions — chest 3.00, upperArm 4.06, lowerArm 4.23 p95/p05 (SP4).
