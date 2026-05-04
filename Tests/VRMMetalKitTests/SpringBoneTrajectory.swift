// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import XCTest
import simd
@testable import VRMMetalKit

/// Test-side assertion helpers that consume `BoneTrajectoryDumper.Sample`
/// arrays — either parsed from a CSV or collected directly in-memory by the
/// dumper running alongside the simulation. The parser lives on
/// `BoneTrajectoryDumper` itself so there is one canonical sample type.

/// Asserts that the named bone deviates from its rigid-follow expectation by
/// at least `minLagDegrees` of angular offset (relative to its parent) at some
/// point during `window`. Used to verify that inertia compensation actually
/// engages during fast motion — without compensation, the bone tracks rigid
/// follow exactly and the lag is ~0°.
func assertLagDuringFastMotion(
    samples: [BoneTrajectoryDumper.Sample],
    bone: String,
    window: Range<Int>,
    minLagDegrees: Float,
    file: StaticString = #file,
    line: UInt = #line
) {
    let inWindow = samples.filter { $0.bone == bone && window.contains($0.frame) }
    guard !inWindow.isEmpty else {
        XCTFail("No samples found for bone '\(bone)' in frames \(window).",
                file: file, line: line)
        return
    }

    var maxLagDegrees: Float = 0
    var observedAt: Int = -1
    for sample in inWindow {
        let actualVec = sample.world - sample.parent
        let expectVec = sample.rigid - sample.parent
        let actLen = simd_length(actualVec)
        let expLen = simd_length(expectVec)
        guard actLen > 1e-6, expLen > 1e-6 else { continue }
        let cosAngle = max(-1.0, min(1.0, simd_dot(actualVec / actLen, expectVec / expLen)))
        let degrees = acos(cosAngle) * 180.0 / Float.pi
        if degrees > maxLagDegrees {
            maxLagDegrees = degrees
            observedAt = sample.frame
        }
    }

    XCTAssertGreaterThanOrEqual(
        maxLagDegrees, minLagDegrees,
        "Bone '\(bone)' max angular lag during frames \(window) was " +
        "\(maxLagDegrees)° (peak at frame \(observedAt)); expected ≥ " +
        "\(minLagDegrees)°. The bone is following its parent too rigidly — " +
        "inertia compensation may not be engaging.",
        file: file, line: line
    )
}

/// Asserts that during a settled (post-motion) window, the bone's RMS
/// world-position deviation from the window mean is below `maxRMS`, AND the
/// trajectory decays — RMS of the last third of the window must be <
/// `minDecayRatio` × RMS of the first third. The decay check is what
/// distinguishes flutter (sustained or growing low-amplitude oscillation)
/// from real damped settling.
func assertNoFlutter(
    samples: [BoneTrajectoryDumper.Sample],
    bone: String,
    settledWindow: Range<Int>,
    maxRMS: Float,
    minDecayRatio: Float,
    file: StaticString = #file,
    line: UInt = #line
) {
    let inWindow = samples
        .filter { $0.bone == bone && settledWindow.contains($0.frame) }
        .sorted { $0.frame < $1.frame }
    guard inWindow.count >= 9 else {
        XCTFail("Settled window for bone '\(bone)' has only \(inWindow.count) " +
                "samples; need ≥ 9 to compute decay over thirds.",
                file: file, line: line)
        return
    }

    let positions = inWindow.map { $0.world }
    let mean = positions.reduce(SIMD3<Float>.zero, +) / Float(positions.count)
    let deviations = positions.map { $0 - mean }
    let totalRMS = sqrt(
        deviations.reduce(Float(0)) { $0 + simd_length_squared($1) } / Float(deviations.count)
    )

    XCTAssertLessThan(
        totalRMS, maxRMS,
        "Bone '\(bone)' RMS deviation in settled window \(settledWindow) was " +
        "\(totalRMS) m; expected < \(maxRMS) m.",
        file: file, line: line
    )

    let thirdSize = inWindow.count / 3
    let firstThird = Array(deviations[0..<thirdSize])
    let lastThird = Array(deviations[(deviations.count - thirdSize)..<deviations.count])
    let firstRMS = sqrt(
        firstThird.reduce(Float(0)) { $0 + simd_length_squared($1) } / Float(firstThird.count)
    )
    let lastRMS = sqrt(
        lastThird.reduce(Float(0)) { $0 + simd_length_squared($1) } / Float(lastThird.count)
    )
    let ratio = firstRMS > 1e-6 ? (lastRMS / firstRMS) : 0

    XCTAssertLessThan(
        ratio, minDecayRatio,
        "Bone '\(bone)' did not decay within settled window: first-third " +
        "RMS = \(firstRMS), last-third RMS = \(lastRMS), ratio = \(ratio); " +
        "expected < \(minDecayRatio). Sustained or growing oscillation suggests flutter.",
        file: file, line: line
    )
}
