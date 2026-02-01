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

// MARK: - Quaternion Assertions

/// Assert two quaternions are equal, handling double-cover (q == -q represents same rotation)
func assertQuaternionsEqual(
    _ q1: simd_quatf,
    _ q2: simd_quatf,
    tolerance: Float = 0.001,
    file: StaticString = #file,
    line: UInt = #line
) {
    let dot = abs(simd_dot(q1.vector, q2.vector))
    XCTAssertGreaterThan(
        dot,
        1.0 - tolerance,
        "Quaternions not equal: \(q1) vs \(q2) (dot=\(dot))",
        file: file,
        line: line
    )
}

/// Assert quaternion is approximately identity
func assertQuaternionIsIdentity(
    _ q: simd_quatf,
    tolerance: Float = 0.001,
    file: StaticString = #file,
    line: UInt = #line
) {
    let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    assertQuaternionsEqual(q, identity, tolerance: tolerance, file: file, line: line)
}

// MARK: - ARKit Mock Data Creators

/// Create mock ARKit face blend shapes with specified values
func createMockBlendShapes(
    timestamp: TimeInterval = Date().timeIntervalSinceReferenceDate,
    shapes: [String: Float]
) -> ARKitFaceBlendShapes {
    return ARKitFaceBlendShapes(timestamp: timestamp, shapes: shapes)
}

/// Create blink blend shapes for testing
func createBlinkBlendShapes(
    left: Float,
    right: Float,
    timestamp: TimeInterval = Date().timeIntervalSinceReferenceDate
) -> ARKitFaceBlendShapes {
    return createMockBlendShapes(timestamp: timestamp, shapes: [
        ARKitFaceBlendShapes.eyeBlinkLeft: left,
        ARKitFaceBlendShapes.eyeBlinkRight: right
    ])
}

/// Create smile/happy blend shapes for testing
func createSmileBlendShapes(
    intensity: Float,
    timestamp: TimeInterval = Date().timeIntervalSinceReferenceDate
) -> ARKitFaceBlendShapes {
    return createMockBlendShapes(timestamp: timestamp, shapes: [
        ARKitFaceBlendShapes.mouthSmileLeft: intensity,
        ARKitFaceBlendShapes.mouthSmileRight: intensity,
        ARKitFaceBlendShapes.cheekSquintLeft: intensity * 0.3,
        ARKitFaceBlendShapes.cheekSquintRight: intensity * 0.3
    ])
}

/// Create sad blend shapes for testing
func createSadBlendShapes(
    intensity: Float,
    timestamp: TimeInterval = Date().timeIntervalSinceReferenceDate
) -> ARKitFaceBlendShapes {
    return createMockBlendShapes(timestamp: timestamp, shapes: [
        ARKitFaceBlendShapes.browInnerUp: intensity * 0.5,
        ARKitFaceBlendShapes.mouthFrownLeft: intensity,
        ARKitFaceBlendShapes.mouthFrownRight: intensity
    ])
}

/// Create angry blend shapes for testing
func createAngryBlendShapes(
    intensity: Float,
    timestamp: TimeInterval = Date().timeIntervalSinceReferenceDate
) -> ARKitFaceBlendShapes {
    return createMockBlendShapes(timestamp: timestamp, shapes: [
        ARKitFaceBlendShapes.browDownLeft: intensity,
        ARKitFaceBlendShapes.browDownRight: intensity,
        ARKitFaceBlendShapes.mouthFrownLeft: intensity * 0.5,
        ARKitFaceBlendShapes.mouthFrownRight: intensity * 0.5
    ])
}

/// Create surprised blend shapes for testing
func createSurprisedBlendShapes(
    intensity: Float,
    timestamp: TimeInterval = Date().timeIntervalSinceReferenceDate
) -> ARKitFaceBlendShapes {
    return createMockBlendShapes(timestamp: timestamp, shapes: [
        ARKitFaceBlendShapes.browInnerUp: intensity,
        ARKitFaceBlendShapes.browOuterUpLeft: intensity * 0.5,
        ARKitFaceBlendShapes.browOuterUpRight: intensity * 0.5,
        ARKitFaceBlendShapes.eyeWideLeft: intensity,
        ARKitFaceBlendShapes.eyeWideRight: intensity
    ])
}

// MARK: - Mock Expression Controller

/// Mock expression controller for testing that records applied weights
final class MockExpressionController {
    var appliedPresetWeights: [VRMExpressionPreset: Float] = [:]
    var appliedCustomWeights: [String: Float] = [:]
    var setWeightCallCount = 0

    func setExpressionWeight(_ preset: VRMExpressionPreset, weight: Float) {
        appliedPresetWeights[preset] = weight
        setWeightCallCount += 1
    }

    func setCustomExpressionWeight(_ name: String, weight: Float) {
        appliedCustomWeights[name] = weight
        setWeightCallCount += 1
    }

    func reset() {
        appliedPresetWeights.removeAll()
        appliedCustomWeights.removeAll()
        setWeightCallCount = 0
    }

    func weight(for preset: VRMExpressionPreset) -> Float {
        return appliedPresetWeights[preset] ?? 0
    }

    func customWeight(for name: String) -> Float {
        return appliedCustomWeights[name] ?? 0
    }
}

// MARK: - Test Animation Helpers

/// Create a simple animation clip with a single bone rotation
func createSimpleRotationClip(
    bone: VRMHumanoidBone,
    duration: Float = 1.0,
    angle: Float = Float.pi / 4,
    axis: SIMD3<Float> = SIMD3<Float>(0, 1, 0)
) -> AnimationClip {
    var clip = AnimationClip(duration: duration)
    let track = JointTrack(
        bone: bone,
        rotationSampler: { time in
            let progress = time / duration
            let currentAngle = angle * progress
            return simd_quatf(angle: currentAngle, axis: axis)
        }
    )
    clip.addJointTrack(track)
    return clip
}

/// Create an animation clip with multiple bone rotations
func createMultiBoneRotationClip(
    bones: [VRMHumanoidBone],
    duration: Float = 1.0,
    angle: Float = Float.pi / 4
) -> AnimationClip {
    var clip = AnimationClip(duration: duration)
    for (index, bone) in bones.enumerated() {
        let phaseOffset = Float(index) * 0.5
        let track = JointTrack(
            bone: bone,
            rotationSampler: { time in
                let progress = (time + phaseOffset) / duration
                let currentAngle = angle * sin(progress * Float.pi)
                return simd_quatf(angle: currentAngle, axis: SIMD3<Float>(0, 1, 0))
            }
        )
        clip.addJointTrack(track)
    }
    return clip
}

// MARK: - Test Model Path Helpers

/// Get the project root directory for test files
/// Uses environment variable VRM_TEST_MODELS_PATH if set, otherwise falls back to auto-detection
func getProjectRoot(filePath: String = #file) -> String {
    // First, check for environment variable
    if let envPath = ProcessInfo.processInfo.environment["VRM_TEST_MODELS_PATH"] {
        return envPath
    }
    
    // Auto-detect from package structure
    let fileManager = FileManager.default
    let candidates: [String?] = [
        ProcessInfo.processInfo.environment["PROJECT_ROOT"],
        ProcessInfo.processInfo.environment["SRCROOT"],
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path,
        fileManager.currentDirectoryPath
    ]
    
    for candidate in candidates.compactMap({ $0 }) {
        let packagePath = "\(candidate)/Package.swift"
        if fileManager.fileExists(atPath: packagePath) {
            return candidate
        }
    }
    return fileManager.currentDirectoryPath
}

/// Get path to a test model file
/// Checks VRM_TEST_MODELS_PATH environment variable first, then falls back to project root
func getTestModelPath(_ filename: String) -> String {
    // First check environment variable for test models directory
    if let envPath = ProcessInfo.processInfo.environment["VRM_TEST_MODELS_PATH"] {
        let envFilePath = "\(envPath)/\(filename)"
        if FileManager.default.fileExists(atPath: envFilePath) {
            return envFilePath
        }
    }
    
    // Fall back to project root
    return "\(getProjectRoot())/\(filename)"
}

// MARK: - Float Comparison Helpers

/// Assert floats are approximately equal
func assertFloatsEqual(
    _ a: Float,
    _ b: Float,
    tolerance: Float = 0.001,
    message: String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    let diff = abs(a - b)
    XCTAssertLessThanOrEqual(
        diff,
        tolerance,
        "Floats not equal: \(a) vs \(b) (diff=\(diff)) \(message)",
        file: file,
        line: line
    )
}

/// Assert float is within range
func assertFloatInRange(
    _ value: Float,
    min: Float,
    max: Float,
    file: StaticString = #file,
    line: UInt = #line
) {
    XCTAssertGreaterThanOrEqual(value, min, "Value \(value) below minimum \(min)", file: file, line: line)
    XCTAssertLessThanOrEqual(value, max, "Value \(value) above maximum \(max)", file: file, line: line)
}
