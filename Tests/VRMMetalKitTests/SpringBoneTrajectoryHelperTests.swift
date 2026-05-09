// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import simd
@testable import VRMMetalKit

/// Sanity tests for the trajectory CSV parser and the lag/flutter assertion
/// helpers. These verify the helpers themselves, using synthetic trajectories
/// — no Metal, no rendering. Real trajectory-driven physics tests live in
/// separate files and depend on `BoneTrajectoryDumper` running alongside
/// `SpringBoneComputeSystem`.
final class SpringBoneTrajectoryHelperTests: XCTestCase {

    typealias Sample = BoneTrajectoryDumper.Sample

    // MARK: - Parser

    func testParseCSVRoundtrips() throws {
        let csv = """
        frame,time_s,bone,wx,wy,wz,px,py,pz,rx,ry,rz
        0,0.000000,Hair_L,0.100000,1.500000,0.000000,0.000000,1.500000,0.000000,0.100000,1.500000,0.000000
        1,0.033333,Hair_L,0.090000,1.490000,0.000000,0.000000,1.490000,0.000000,0.100000,1.490000,0.000000
        """
        let samples = BoneTrajectoryDumper.parseCSV(content: csv)
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].frame, 0)
        XCTAssertEqual(samples[0].bone, "Hair_L")
        XCTAssertEqual(samples[0].world.x, 0.1, accuracy: 1e-5)
        XCTAssertEqual(samples[1].time, 0.033333, accuracy: 1e-5)
        XCTAssertEqual(samples[1].rigid.x, 0.1, accuracy: 1e-5)
    }

    func testParseCSVSkipsMalformedRows() throws {
        let csv = """
        frame,time_s,bone,wx,wy,wz,px,py,pz,rx,ry,rz
        0,0.000000,Bone,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0
        notarow
        1,too,few,fields
        2,0.033333,Bone,0.1,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0
        """
        let samples = BoneTrajectoryDumper.parseCSV(content: csv)
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].frame, 0)
        XCTAssertEqual(samples[1].frame, 2)
    }

    // MARK: - assertLagDuringFastMotion

    func testAssertLagPassesWhenAngularOffsetExceedsThreshold() {
        // bone at origin, parent above at (0,1,0), rigid expectation at (0.5,0,0).
        // actual vec = (0,-1,0), expect vec = (0.5,-1,0). Angle ≈ atan(0.5) ≈ 26.57°.
        let samples = [
            Sample(frame: 30, time: 1.0, bone: "Hair",
                   world: SIMD3(0, 0, 0),
                   parent: SIMD3(0, 1, 0),
                   rigid: SIMD3(0.5, 0, 0))
        ]
        assertLagDuringFastMotion(
            samples: samples, bone: "Hair",
            window: 30..<31, minLagDegrees: 10
        )
    }

    func testAssertLagFailsWhenBoneTracksRigidFollow() {
        // actual == rigid → lag is 0°. Expect failure.
        let samples = [
            Sample(frame: 30, time: 1.0, bone: "Hair",
                   world: SIMD3(0.5, 0, 0),
                   parent: SIMD3(0, 1, 0),
                   rigid: SIMD3(0.5, 0, 0))
        ]
        XCTExpectFailure("Bone tracking rigid-follow exactly should fail the lag assertion") {
            assertLagDuringFastMotion(
                samples: samples, bone: "Hair",
                window: 30..<31, minLagDegrees: 5
            )
        }
    }

    func testAssertLagFailsWhenBoneIsAbsentFromWindow() {
        let samples = [
            Sample(frame: 0, time: 0.0, bone: "Hair",
                   world: .zero, parent: .zero, rigid: .zero)
        ]
        XCTExpectFailure("No samples in window should produce an explicit failure") {
            assertLagDuringFastMotion(samples: samples, bone: "Hair",
                                      window: 30..<60, minLagDegrees: 5)
        }
    }

    // MARK: - assertNoFlutter

    func testAssertNoFlutterPassesOnDampedDecay() {
        // Amplitude decays exponentially across the window.
        var samples: [Sample] = []
        for f in 100..<160 {
            let t = Float(f - 100)
            let amplitude = 0.001 * exp(-t * 0.1)  // decays from 0.001 to ~0.000025
            let osc = SIMD3<Float>(amplitude * sin(t * 0.5), 0, 0)
            samples.append(Sample(
                frame: f, time: Double(f) / 30.0, bone: "Hair",
                world: SIMD3(0, 1, 0) + osc,
                parent: SIMD3(0, 1.5, 0),
                rigid: SIMD3(0, 1, 0)
            ))
        }
        assertNoFlutter(samples: samples, bone: "Hair",
                        settledWindow: 100..<160,
                        maxRMS: 0.005, minDecayRatio: 0.5)
    }

    func testAssertNoFlutterFailsOnSustainedOscillation() {
        // Constant-amplitude oscillation: small RMS but no decay.
        var samples: [Sample] = []
        for f in 100..<160 {
            let t = Float(f - 100)
            let osc = SIMD3<Float>(0.001 * sin(t * 0.5), 0, 0)
            samples.append(Sample(
                frame: f, time: Double(f) / 30.0, bone: "Hair",
                world: SIMD3(0, 1, 0) + osc,
                parent: SIMD3(0, 1.5, 0),
                rigid: SIMD3(0, 1, 0)
            ))
        }
        XCTExpectFailure("Sustained oscillation should fail the decay-ratio check") {
            assertNoFlutter(samples: samples, bone: "Hair",
                            settledWindow: 100..<160,
                            maxRMS: 0.005, minDecayRatio: 0.5)
        }
    }

    // MARK: - assertSpringChainsStable

    func testAssertStablePassesOnSensibleTrajectory() {
        let samples = (0..<10).map { i in
            Sample(frame: i, time: Double(i) * 0.033, bone: "Hair",
                   world: SIMD3(0.05 * Float(i % 3), 1, 0),
                   parent: SIMD3(0, 1.05, 0),
                   rigid: SIMD3(0.05, 1, 0))
        }
        assertSpringChainsStable(samples: samples)
    }

    func testAssertStableFailsOnNaNPosition() {
        let samples = [
            Sample(frame: 0, time: 0, bone: "Hair",
                   world: SIMD3(0, 0.5, 0), parent: SIMD3(0, 1, 0), rigid: SIMD3(0, 0.5, 0)),
            Sample(frame: 1, time: 0.033, bone: "Hair",
                   world: SIMD3(.nan, 0.5, 0), parent: SIMD3(0, 1, 0), rigid: SIMD3(0, 0.5, 0))
        ]
        XCTExpectFailure("NaN world position should fail stability") {
            assertSpringChainsStable(samples: samples)
        }
    }

    func testAssertStableFailsOnExplodingLinkLength() {
        let samples = [
            Sample(frame: 0, time: 0, bone: "Hair",
                   world: SIMD3(0, 0.95, 0), parent: SIMD3(0, 1, 0), rigid: SIMD3(0, 0.95, 0)),
            Sample(frame: 1, time: 0.033, bone: "Hair",
                   world: SIMD3(7, 1, 0),  // link length = 7m
                   parent: SIMD3(0, 1, 0), rigid: SIMD3(0, 0.95, 0))
        ]
        XCTExpectFailure("Parent-bone distance > maxLinkLength should fail stability") {
            assertSpringChainsStable(samples: samples, maxLinkLength: 0.5)
        }
    }

    func testAssertStableFailsOnOutOfWorldBoundsPosition() {
        let samples = [
            Sample(frame: 0, time: 0, bone: "Hair",
                   world: SIMD3(50, 50, 50),  // way out of bounds
                   parent: SIMD3(50, 50, 50), rigid: SIMD3(50, 50, 50))
        ]
        XCTExpectFailure("World position outside ±maxAbsoluteCoordinate should fail") {
            assertSpringChainsStable(samples: samples, maxAbsoluteCoordinate: 10)
        }
    }

    func testAssertStableRespectsNamedBoneFilter() {
        // 'Bad' bone has NaN, but we only check 'Good' bone — should pass.
        let samples = [
            Sample(frame: 0, time: 0, bone: "Good",
                   world: SIMD3(0, 1, 0), parent: SIMD3(0, 1.05, 0), rigid: SIMD3(0, 1, 0)),
            Sample(frame: 0, time: 0, bone: "Bad",
                   world: SIMD3(.nan, 0, 0), parent: SIMD3(0, 0, 0), rigid: SIMD3(0, 0, 0))
        ]
        assertSpringChainsStable(samples: samples, bones: ["Good"])
    }

    func testAssertNoFlutterFailsOnLargeAmplitude() {
        var samples: [Sample] = []
        for f in 100..<160 {
            let t = Float(f - 100)
            let amplitude = 0.05 * exp(-t * 0.1)  // way above 0.005 m
            let osc = SIMD3<Float>(amplitude * sin(t * 0.5), 0, 0)
            samples.append(Sample(
                frame: f, time: Double(f) / 30.0, bone: "Hair",
                world: SIMD3(0, 1, 0) + osc,
                parent: SIMD3(0, 1.5, 0),
                rigid: SIMD3(0, 1, 0)
            ))
        }
        XCTExpectFailure("Amplitude exceeding maxRMS should fail the RMS check") {
            assertNoFlutter(samples: samples, bone: "Hair",
                            settledWindow: 100..<160,
                            maxRMS: 0.005, minDecayRatio: 0.5)
        }
    }
}
