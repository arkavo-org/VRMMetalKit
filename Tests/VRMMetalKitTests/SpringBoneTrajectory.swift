// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import XCTest
import simd

/// One row from a `--dump-bones` CSV produced by `VRMVideoRenderer`. Each row
/// captures a single bone at a single frame, along with its parent's world
/// position and the rigid-follow expectation (where the bone *would* sit if it
/// followed its parent perfectly without any physics lag).
struct TrajectorySample: Equatable {
    let frame: Int
    let time: Double
    let bone: String
    /// World position of the bone after physics.
    let world: SIMD3<Float>
    /// World position of the bone's parent (or = world if no parent).
    let parent: SIMD3<Float>
    /// Rigid-follow expectation: parent.worldMatrix * (initialTranslation, 1).
    let rigid: SIMD3<Float>
}

extension TrajectorySample {

    /// Parse a CSV file produced by `VRMVideoRenderer --dump-bones`.
    static func parseCSV(at path: String) throws -> [TrajectorySample] {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        return try parseCSV(content: content)
    }

    static func parseCSV(content: String) throws -> [TrajectorySample] {
        var samples: [TrajectorySample] = []
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        for (index, raw) in lines.enumerated() {
            // Skip header row.
            if index == 0, raw.hasPrefix("frame,") { continue }
            let fields = raw.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 12,
                  let frame = Int(fields[0]),
                  let time = Double(fields[1]) else { continue }
            let bone = String(fields[2])
            let nums = fields[3..<12].compactMap { Float($0) }
            guard nums.count == 9 else { continue }
            samples.append(TrajectorySample(
                frame: frame,
                time: time,
                bone: bone,
                world: SIMD3(nums[0], nums[1], nums[2]),
                parent: SIMD3(nums[3], nums[4], nums[5]),
                rigid: SIMD3(nums[6], nums[7], nums[8])
            ))
        }
        return samples
    }
}

/// Asserts that the named bone deviates from its rigid-follow expectation by at
/// least `minLagDegrees` of angular offset (relative to its parent) at some
/// point during `window`. Used to verify that inertia compensation actually
/// engages during fast motion — without compensation, the bone tracks rigid
/// follow exactly and the lag is ~0°.
func assertLagDuringFastMotion(
    samples: [TrajectorySample],
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
/// trajectory decays — RMS of the last third of the window must be < the
/// `minDecayRatio` × RMS of the first third. The decay check is what
/// distinguishes flutter (sustained low-amplitude oscillation) from real
/// damped settling.
func assertNoFlutter(
    samples: [TrajectorySample],
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
        "expected < \(minDecayRatio). Sustained oscillation suggests flutter.",
        file: file, line: line
    )
}
