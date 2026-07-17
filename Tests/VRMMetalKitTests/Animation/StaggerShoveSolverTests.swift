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

/// Solver gates G1–G4 (design 2026-07-07 §6.1). Every gate carries the
/// discriminating counter-case the design names — a variant that must FAIL the
/// gate's criterion, proving the pass is not vacuous.
final class StaggerShoveSolverTests: XCTestCase {
    private let dt: Float = 1.0 / 60.0

    /// G1 — the rate cap binds: a fast-deepening penetration moves the offset by
    /// at most `velocityCap·dt` per frame. Counter-case: an effectively infinite
    /// cap lets the same input jump past that bound.
    func testG1_rateCapBinds_fastDeepeningPenetration() {
        var capped = StaggerShoveSolver(params: StaggerShoveParams(shoveGain: 6.0, velocityCap: 0.14))
        let before = capped.offset
        capped.update(depth: 1.0, pushDirXZ: SIMD2<Float>(1, 0), dt: dt)
        XCTAssertLessThanOrEqual(simd_length(capped.offset - before), 0.14 * dt + 1e-6,
                                 "per-frame move is capped at velocityCap·dt")

        var uncapped = StaggerShoveSolver(params: StaggerShoveParams(shoveGain: 6.0, velocityCap: 1e9))
        uncapped.update(depth: 1.0, pushDirXZ: SIMD2<Float>(1, 0), dt: dt)
        XCTAssertGreaterThan(simd_length(uncapped.offset), 0.14 * dt,
                             "uncapped variant exceeds the bound — the cap genuinely binds")
    }

    /// G2 — zero-on-separation (strict coupling, no momentum): after a contact
    /// ramp, holding depth = 0 decays the offset to zero within the rate-limited
    /// window, and it stays zero. Counter-case: a velocity-integrating variant
    /// coasts past separation and never returns to zero.
    func testG2_zeroOnSeparation_noMomentum() {
        var solver = StaggerShoveSolver(params: StaggerShoveParams(shoveGain: 6.0, velocityCap: 0.14))
        for _ in 0..<60 { solver.update(depth: 0.05, pushDirXZ: SIMD2<Float>(1, 0), dt: dt) }
        XCTAssertGreaterThan(simd_length(solver.offset), 0.01, "contact ramp built a real offset")

        let framesToZero = Int((simd_length(solver.offset) / (0.14 * dt)).rounded(.up)) + 1
        for _ in 0..<framesToZero { solver.update(depth: 0, pushDirXZ: .zero, dt: dt) }
        XCTAssertLessThanOrEqual(simd_length(solver.offset), 1e-5,
                                 "offset decays to zero within ⌈|offset|/(velocityCap·dt)⌉ frames")
        for _ in 0..<30 { solver.update(depth: 0, pushDirXZ: .zero, dt: dt) }
        XCTAssertLessThanOrEqual(simd_length(solver.offset), 1e-5, "and stays zero")

        var pos = SIMD2<Float>.zero
        var vel = SIMD2<Float>.zero
        for _ in 0..<60 {
            vel += 6.0 * 0.05 * SIMD2<Float>(1, 0) * dt
            pos += vel * dt
        }
        let atSeparation = pos
        for _ in 0..<framesToZero { pos += vel * dt }
        XCTAssertGreaterThan(simd_length(pos), simd_length(atSeparation),
                             "momentum variant coasts after separation")
        XCTAssertGreaterThan(simd_length(pos), 1e-5, "and retains a non-zero residual — the criterion discriminates")
    }

    /// G3 — no overshoot: under constant depth the offset converges monotonically
    /// to `shoveGain·depth·d̂` and never exceeds the target magnitude.
    /// Counter-case: an underdamped second-order integrator overshoots on the way in.
    func testG3_noOvershootAtTarget() {
        let params = StaggerShoveParams(shoveGain: 6.0, velocityCap: 0.14)
        var solver = StaggerShoveSolver(params: params)
        let depth: Float = 0.05
        let targetMag = params.shoveGain * depth
        var previous: Float = 0
        for _ in 0..<400 {
            solver.update(depth: depth, pushDirXZ: SIMD2<Float>(0, 1), dt: dt)
            let mag = simd_length(solver.offset)
            XCTAssertGreaterThanOrEqual(mag, previous - 1e-6, "monotone approach")
            XCTAssertLessThanOrEqual(mag, targetMag + 1e-5, "never exceeds the target magnitude")
            previous = mag
        }
        XCTAssertEqual(simd_length(solver.offset), targetMag, accuracy: 1e-4, "converged to shoveGain·depth")

        var pos: Float = 0, vel: Float = 0, peak: Float = 0
        for _ in 0..<400 {
            vel += (targetMag - pos) * 40 * dt
            pos += vel * dt
            peak = max(peak, pos)
        }
        XCTAssertGreaterThan(peak, targetMag + 1e-3,
                             "second-order variant overshoots — the criterion discriminates position-driven from ballistic")
    }

    /// G4 — direction: the converged offset points along pushDirXZ (away from the
    /// partner) across several orientations, including a non-unit input (the
    /// solver normalizes). Direct-measurement metric: rigor comes from orientation
    /// coverage + tight ε; a sign flip would read alignment ≈ −1. Degenerate
    /// direction yields a well-defined zero.
    func testG4_offsetPointsAlongPushDirection() {
        let directions: [SIMD2<Float>] = [
            SIMD2(1, 0), SIMD2(0, 1), SIMD2(-1, 0), SIMD2(0, -1),
            SIMD2(0.6, 0.8), SIMD2(-0.707, 0.707), SIMD2(3, 4),
        ]
        for dir in directions {
            var solver = StaggerShoveSolver(params: StaggerShoveParams(shoveGain: 6.0, velocityCap: 0.14))
            for _ in 0..<120 { solver.update(depth: 0.05, pushDirXZ: dir, dt: dt) }
            let mag = simd_length(solver.offset)
            XCTAssertGreaterThan(mag, 0.01, "offset built up for \(dir)")
            let alignment = simd_dot(solver.offset / mag, simd_normalize(dir))
            XCTAssertGreaterThan(alignment, 0.999, "offset points along pushDir for \(dir)")
        }

        var degenerate = StaggerShoveSolver(params: StaggerShoveParams(shoveGain: 6.0, velocityCap: 0.14))
        degenerate.update(depth: 0.05, pushDirXZ: .zero, dt: dt)
        XCTAssertEqual(degenerate.offset, .zero, "degenerate pushDir yields a well-defined zero target")
    }
}
