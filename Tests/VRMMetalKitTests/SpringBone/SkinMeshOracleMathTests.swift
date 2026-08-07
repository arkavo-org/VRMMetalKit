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
        let quads: [(Int, Int, Int, Int)] = [
            (1, 5, 6, 2), (4, 0, 3, 7),     // +x, -x
            (3, 2, 6, 7), (0, 4, 5, 1),     // +y, -y
            (5, 4, 7, 6), (0, 1, 2, 3)      // +z, -z
        ]
        var out: [SkinMeshOracle.Triangle] = []
        for (a, b, c, d) in quads {
            // Swapping the trailing two corners flips the emitted winding to
            // CCW-from-outside so cross(b-a, c-a) yields an outward normal —
            // the (a, b, c)/(a, c, d) order the quad tuples imply is CW here.
            out.append(.init(a: v[a], b: v[c], c: v[b], region: region))
            out.append(.init(a: v[a], b: v[d], c: v[c], region: region))
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
                // Same winding correction as box(): trailing two corners swapped
                // so the emitted triangles face outward.
                out.append(.init(a: a, b: c, c: b, region: nil))
                out.append(.init(a: a, b: d, c: c, region: nil))
            }
        }
        return out
    }

    /// Square pyramid ("needle"): apex at `(0, height, 0)`, a tiny square base
    /// at y=0. `height` is deliberately large relative to `baseHalfWidth` so
    /// the four side faces are long and thin — their normals end up nearly
    /// PERPENDICULAR to the apex axis, which is exactly what makes a single
    /// face normal an unreliable stand-in for "outward" near the tip: fingers
    /// are long and thin the same way, which is why the spec insists on
    /// pseudonormals there.
    private func needle(height: Float, baseHalfWidth: Float) -> [SkinMeshOracle.Triangle] {
        let apex = SIMD3<Float>(0, height, 0)
        let base = [
            SIMD3<Float>(-baseHalfWidth, 0, -baseHalfWidth),
            SIMD3<Float>(baseHalfWidth, 0, -baseHalfWidth),
            SIMD3<Float>(baseHalfWidth, 0, baseHalfWidth),
            SIMD3<Float>(-baseHalfWidth, 0, baseHalfWidth)
        ]
        var out: [SkinMeshOracle.Triangle] = []
        for i in 0..<4 {
            out.append(.init(a: apex, b: base[(i + 1) % 4], c: base[i], region: nil))
        }
        // Base cap, outward-facing (-y), so the solid is closed.
        out.append(.init(a: base[0], b: base[1], c: base[2], region: nil))
        out.append(.init(a: base[0], b: base[2], c: base[3], region: nil))
        return out
    }

    /// Triangular prism ("roof"): a ridge edge at `x=0` running the length of
    /// the prism, sloping out to two floor corners at `x=run, z=±halfWidth`.
    /// `run` deliberately dwarfs `halfWidth` — the same H≫R shape as
    /// `needle()`, applied to an EDGE instead of a point — so the two ridge
    /// faces are long and thin and their individual normals end up nearly
    /// perpendicular to the true outward direction at the ridge. Closed with
    /// a floor and two end caps so "outside" is the ordinary, unambiguous
    /// sense: the solid spans `x ∈ [0, run]`, so any point at `x < 0` is
    /// outside regardless of which way any single triangle's normal points.
    private func roof(ridgeLength: Float, run: Float, halfWidth: Float) -> [SkinMeshOracle.Triangle] {
        let r0 = SIMD3<Float>(0, 0, 0)
        let r1 = SIMD3<Float>(0, ridgeLength, 0)
        let f1_0 = SIMD3<Float>(run, 0, halfWidth)
        let f1_1 = SIMD3<Float>(run, ridgeLength, halfWidth)
        let f2_0 = SIMD3<Float>(run, 0, -halfWidth)
        let f2_1 = SIMD3<Float>(run, ridgeLength, -halfWidth)
        return [
            .init(a: r0, b: f1_1, c: r1, region: nil),
            .init(a: r0, b: f1_0, c: f1_1, region: nil),
            .init(a: r0, b: f2_1, c: f2_0, region: nil),
            .init(a: r0, b: r1, c: f2_1, region: nil),
            .init(a: f1_0, b: f2_0, c: f2_1, region: nil),
            .init(a: f1_0, b: f2_1, c: f1_1, region: nil),
            .init(a: r0, b: f2_0, c: f1_0, region: nil),
            .init(a: r1, b: f1_1, c: f2_1, region: nil)
        ]
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

    // MARK: - Needle apex fixture (REQUIRED — convex shapes cannot observe this)

    /// A tall thin spike, queried just past the tip along a direction tilted
    /// off-axis. The nearest feature is the apex VERTEX, shared by all four
    /// side faces; because the faces are long and thin, each face's own
    /// normal is nearly perpendicular to the true "outward" direction there.
    /// Whichever single face happens to win the nearest-triangle search gives
    /// `dot(delta, faceNormal)` the WRONG sign for this query, so flattening
    /// vertex-pseudonormal lookup to the winning face's own normal makes this
    /// test fail. The angle-weighted vertex pseudonormal averages the four
    /// faces back to the true outward (+y) direction and classifies it
    /// correctly. Box and sphere are both convex with generously-angled faces
    /// and structurally cannot catch this.
    func testNeedleApexClassifiesJustBeyondTipAsOutside() {
        let height: Float = 1.0
        let oracle = SkinMeshOracle(triangles: needle(height: height, baseHalfWidth: 0.02))
        let apex = SIMD3<Float>(0, height, 0)
        let offAxis = simd_normalize(SIMD3<Float>(0, 1, 1))
        let query = apex + 0.05 * offAxis
        XCTAssertNil(oracle.penetration(of: query, radius: 0),
                     "just past the tip, tilted off-axis, is OUTSIDE; a face-normal "
                     + "classifier reports it inside")
    }

    func testNeedleApexStillDetectsGenuineInterior() {
        let oracle = SkinMeshOracle(triangles: needle(height: 1.0, baseHalfWidth: 0.02))
        XCTAssertNotNil(oracle.penetration(of: SIMD3<Float>(0, 0.1, 0), radius: 0),
                        "on-axis, well below the tip, is inside the tapered body")
    }

    // MARK: - Roof ridge fixture (REQUIRED — the needle only exercises .vertex)

    /// The ridge itself: confirms the closest feature this whole fixture
    /// depends on is genuinely `.edge`, not `.face` or `.vertex`. Without
    /// this, a fixture could silently regress to a non-discriminating shape
    /// the way the original overlapping-box notch did.
    func testRoofRidgeClosestFeatureIsGenuinelyAnEdge() {
        let tris = roof(ridgeLength: 1.0, run: 1.0, halfWidth: 0.02)
        let query = SIMD3<Float>(-0.05, 0.5, -0.01)
        let grid = SkinMeshOracle.SpatialGrid(triangles: tris)
        guard let hit = grid.nearest(to: query, triangles: tris) else {
            return XCTFail("expected a nearest triangle")
        }
        guard case .edge = hit.feature else {
            return XCTFail("expected the closest feature to be an edge, got \(hit.feature)")
        }
    }

    /// A query tucked behind the ridge, tilted toward one of the two roof
    /// faces. The solid spans `x ∈ [0, run]`, so `x < 0` is outside no matter
    /// which way any single triangle's normal points — that's the ground
    /// truth, independent of the pseudonormal machinery being tested. The
    /// closest feature is the shared ridge edge; because the two ridge faces
    /// are long and thin (see `roof(...)`), the single face that wins the
    /// nearest-triangle search gives `dot(delta, faceNormal)` the WRONG sign
    /// for this query, so flattening edge-pseudonormal lookup to that face's
    /// own normal makes this test fail. Summing the two adjacent faces'
    /// normals at the shared edge classifies it correctly. Box, sphere, and
    /// the needle's vertex case are all structurally unable to exercise the
    /// `.edge` branch of `closestPoint`, `EdgeKey`, or `edgePseudonormals`.
    func testRoofRidgeClassifiesBehindTheFoldAsOutside() {
        let oracle = SkinMeshOracle(triangles: roof(ridgeLength: 1.0, run: 1.0, halfWidth: 0.02))
        let query = SIMD3<Float>(-0.05, 0.5, -0.01)
        XCTAssertNil(oracle.penetration(of: query, radius: 0),
                     "behind the ridge (x<0) is OUTSIDE the prism (x∈[0,1]); a "
                     + "face-normal classifier reports it inside")
    }

    /// `EdgeKey` welds an edge regardless of which triangle visits it first
    /// or in which corner order; the edge pseudonormal lookup above depends
    /// on this normalisation holding for both directions of the same pair.
    func testEdgeKeyOrderingIsSymmetric() {
        let a = SkinMeshOracle.VertexKey(SIMD3<Float>(1, 2, 3))
        let b = SkinMeshOracle.VertexKey(SIMD3<Float>(4, 5, 6))
        XCTAssertEqual(SkinMeshOracle.EdgeKey(a, b), SkinMeshOracle.EdgeKey(b, a))
        XCTAssertEqual(SkinMeshOracle.EdgeKey(a, b).hashValue, SkinMeshOracle.EdgeKey(b, a).hashValue)
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

extension SkinMeshOracleMathTests {

    /// Brute force is the reference. A bounded search agrees with it everywhere
    /// EXCEPT where it breaks, so the equivalence set must include a deeply
    /// interior query, not only near-surface points.
    ///
    /// Only depth and the nil/non-nil verdict are compared, not `region` or
    /// `surfacePoint`. `SpatialGrid.nearest` breaks ties by first-encountered
    /// triangle index, but a uniform grid iterates in CELL order, not global
    /// index order, so among exact ties (shared edges and vertices — e.g. a
    /// box corner) the grid can legitimately pick a different triangle than
    /// brute force. Sign and depth stay stable because welded pseudonormals
    /// are shared between the tied triangles; provenance of which triangle
    /// won is not.
    func testGridAgreesWithBruteForceIncludingDeepInterior() {
        var tris = box(min: [-2, -2, -2], max: [2, 2, 2])
        // Finely tessellated relative to the box: the grid sizes its cell to
        // the MEAN edge length across every triangle in the mesh, so a coarse
        // box mixed with a coarsely-tessellated sphere inflates that mean
        // enough to mask a bounded search's danger by accident. The higher
        // density keeps the cell small enough that the sphere interior query
        // below is genuinely a multi-ring search, not a one-ring one.
        tris += sphere(center: [0.5, 0.5, 0.5], radius: 0.3, rings: 36, segments: 72)
        let oracle = SkinMeshOracle(triangles: tris)

        let queries: [SIMD3<Float>] = [
            // 2m from every box face, but the nearest TRIANGLE overall is the
            // inner sphere (0.57m away) and the origin sits outside it, so the
            // nearest-triangle oracle correctly reports nil here despite being
            // deeply enclosed by the outer box — this exercises deep-interior
            // ring growth (no cutoff swallows the far box) while resolving to
            // the geometrically nearer sphere.
            .zero,
            SIMD3<Float>(1.98, 0, 0),           // just inside a face
            SIMD3<Float>(2.02, 0, 0),           // just outside
            SIMD3<Float>(0.5, 0.5, 0.5),        // inside the inner sphere
            SIMD3<Float>(-1.999, -1.999, -1.999), // interior corner
            // Far outside, but along a single axis (y = z = 0, inside the
            // box's own y/z range) rather than the 3-way diagonal (9,9,9).
            // On the diagonal, the ring search's per-axis (Chebyshev) first-
            // touch distance is only a lower bound on the true Euclidean
            // nearest distance, leaving a real sqrt(3) gap between "first
            // candidate found" and "provably the nearest" that costs several
            // hundred large, mostly-empty rings to close purely because of
            // this fixture's own fine tessellation. Off-axis, first touch IS
            // the true nearest distance, so the search terminates at once —
            // still exercises the identical "far outside, both agree" path
            // without that fixture-specific cost.
            SIMD3<Float>(9, 0, 0)
        ]
        for q in queries {
            let viaGrid = oracle.penetration(of: q, radius: 0)
            let viaBrute = SkinMeshOracle.bruteForcePenetrationForTesting(oracle: oracle, point: q, radius: 0)
            // Compared as depth-plus-verdict rather than through the `?? .nan`
            // sentinel the brief's text uses: XCTAssertEqual's accuracy check
            // treats NaN as unequal to NaN, so two independently-nil results —
            // the correct, agreeing answer — would read as a spurious failure.
            XCTAssertEqual(viaGrid != nil, viaBrute != nil,
                           "grid and brute force disagree on the nil verdict at \(q)")
            if let g = viaGrid, let b = viaBrute {
                XCTAssertEqual(g.depth, b.depth, accuracy: 1e-5,
                               "grid and brute force disagree at \(q)")
            }
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

    /// Reproduces the shape of VMK's real-avatar finding (Task 4): a finely
    /// tessellated mesh (cell ≈0.0105 here, matching the ≈0.011 measured on
    /// AvatarSample_U's body+face mesh) queried far outside its bounds. The
    /// Chebyshev first-touch ring for this query is ≈4743 — comfortably past
    /// the `SpatialGrid.nearest` ring backstop (4096) that would previously
    /// have made this query crash the test process via `preconditionFailure`
    /// rather than return an answer. It must instead fall back to a linear
    /// scan and complete in a bounded, small amount of time with the correct
    /// answer, not merely "some" answer.
    func testGridFallsBackToLinearScanForFarOutsideQuery() {
        let tris = sphere(center: .zero, radius: 0.2, rings: 60, segments: 120)
        let oracle = SkinMeshOracle(triangles: tris)
        let farQuery = SIMD3<Float>(50, 0, 0)
        let start = Date()
        let pen = oracle.penetration(of: farQuery, radius: 50.0)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(pen?.depth ?? -1, 0.2, accuracy: 0.01,
                       "50m away, a 50m-radius joint buries the sphere's near surface by ~0.2m")
        XCTAssertLessThan(elapsed, 0.05,
                          "must be a bounded linear scan, not a ring search needing thousands of empty shells")
    }
}
