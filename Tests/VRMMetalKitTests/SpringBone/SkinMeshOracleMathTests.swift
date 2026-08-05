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
        // Each quad wound counter-clockwise seen from outside.
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
    /// `dot(delta, faceNormal)` the WRONG sign for this query — proven by the
    /// sabotage run in task-2-report.md — while the angle-weighted vertex
    /// pseudonormal averages the four faces back to the true outward (+y)
    /// direction and classifies it correctly. Box and sphere are both convex
    /// with generously-angled faces and structurally cannot catch this.
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
