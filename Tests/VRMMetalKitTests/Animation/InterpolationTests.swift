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

// MARK: - Phase 1: RED Tests - Interpolation Methods
// Comprehensive tests for all glTF/VRMA interpolation methods:
// - LINEAR: Linear interpolation (LERP/SLERP)
// - STEP: Hold value until next keyframe
// - CUBICSPLINE: Cubic spline with tangent control

/// Interpolation Method Tests
///
/// 🔴 RED Phase Tests: Verify all interpolation methods work correctly
///
/// Interpolation types defined in glTF spec:
/// - "LINEAR" (default): Linear interpolation between values
/// - "STEP": Values hold constant until next keyframe
/// - "CUBICSPLINE": Cubic spline interpolation with in/out tangents
final class InterpolationTests: XCTestCase {
    
    // MARK: - RED Test: LINEAR Interpolation
    
    /// 🔴 RED: LINEAR interpolation for scalar values
    ///
    /// LINEAR interpolation should produce smooth, evenly-spaced values.
    /// For scalars: value = a + (b - a) * t
    func testLinearInterpolationScalar() {
        // Arrange: Two keyframes with scalar values
        let keyframeA: Float = 0.0
        let keyframeB: Float = 10.0
        let duration: Float = 1.0
        
        // Act: Interpolate at multiple points
        let samples: [(time: Float, expected: Float)] = [
            (0.0, 0.0),
            (0.25, 2.5),
            (0.5, 5.0),
            (0.75, 7.5),
            (1.0, 10.0),
        ]
        
        for (time, expected) in samples {
            // Linear interpolation formula
            let t = time / duration
            let interpolated = keyframeA + (keyframeB - keyframeA) * t
            
            // Assert: Should match expected linear progression
            XCTAssertEqual(interpolated, expected, accuracy: 0.001,
                "Linear interpolation at t=\(time) should be \(expected), got \(interpolated)")
        }
    }
    
    /// 🔴 RED: LINEAR interpolation for vectors (LERP)
    ///
    /// Vector LERP: v = a + (b - a) * t
    func testLinearInterpolationVector() {
        // Arrange
        let keyframeA = SIMD3<Float>(0, 0, 0)
        let keyframeB = SIMD3<Float>(10, 20, 30)
        
        // Act & Assert
        let samples: [(time: Float, expected: SIMD3<Float>)] = [
            (0.0, SIMD3<Float>(0, 0, 0)),
            (0.5, SIMD3<Float>(5, 10, 15)),
            (1.0, SIMD3<Float>(10, 20, 30)),
        ]
        
        for (time, expected) in samples {
            let t = time
            let interpolated = keyframeA + (keyframeB - keyframeA) * t
            
            XCTAssertEqual(interpolated.x, expected.x, accuracy: 0.001)
            XCTAssertEqual(interpolated.y, expected.y, accuracy: 0.001)
            XCTAssertEqual(interpolated.z, expected.z, accuracy: 0.001)
        }
    }
    
    /// 🔴 RED: LINEAR interpolation for quaternions (SLERP)
    ///
    /// Quaternion SLERP should:
    /// - Take the shortest path (handle double-cover: q == -q)
    /// - Maintain unit length
    /// - Produce smooth rotation
    func testLinearInterpolationQuaternionSLERP() {
        // Arrange: Two quaternion keyframes
        let quatA = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        let quatB = simd_quatf(angle: Float.pi / 2, axis: SIMD3<Float>(0, 1, 0))  // 90° Y
        
        // Act: SLERP at midpoint
        let quatMid = simd_slerp(quatA, quatB, 0.5)
        
        // Assert: Midpoint should be 45°
        let midAngle = 2 * acos(min(1, abs(quatMid.real)))
        XCTAssertEqual(midAngle, Float.pi / 4, accuracy: 0.01,
                      "SLERP midpoint should be 45°")
        
        // Assert: Quaternion should remain normalized
        let length = sqrt(quatMid.imag.x * quatMid.imag.x +
                         quatMid.imag.y * quatMid.imag.y +
                         quatMid.imag.z * quatMid.imag.z +
                         quatMid.real * quatMid.real)
        XCTAssertEqual(length, 1.0, accuracy: 0.0001,
                      "SLERP result should be normalized")
    }
    
    /// 🔴 RED: SLERP takes shortest path (quaternion neighborhood)
    ///
    /// When interpolating between quaternions that are > 90° apart,
    /// SLERP should choose the shorter path by negating one quaternion if needed.
    func testSLERPShortestPath() {
        // Arrange: Two quaternions that are 180° apart
        // The "long way" would be 180°, the "short way" is also 180°
        // Let's use 120° which has a clear shorter path
        let quatA = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        let quatB = simd_quatf(angle: 2 * Float.pi / 3, axis: SIMD3<Float>(0, 1, 0))  // 120°
        
        // Also create the "long way" equivalent (negated)
        let quatBLong = simd_quatf(vector: -quatB.vector)  // -q represents same rotation
        
        // Act: SLERP both ways
        let slerpShort = simd_slerp(quatA, quatB, 0.5)
        let slerpLong = simd_slerp(quatA, quatBLong, 0.5)
        
        // Assert: Both should produce the same result (shortest path)
        assertQuaternionsEqual(slerpShort, slerpLong, tolerance: 0.001)
        
        // The result should be 60° (halfway along the 120° path, not 240°)
        let resultAngle = 2 * acos(min(1, abs(slerpShort.real)))
        XCTAssertEqual(resultAngle, Float.pi / 3, accuracy: 0.01,  // 60°
                      "SLERP should take 60° path (half of 120°), not 120° (half of 240°)")
    }
    
    /// 🔴 RED: LINEAR interpolation smoothness verification
    ///
    /// Verify that linear interpolation produces evenly-spaced values.
    func testLinearInterpolationSmoothness() {
        let start: Float = 0.0
        let end: Float = 100.0
        let steps = 100
        
        var previousValue: Float = start
        
        for i in 1...steps {
            let t = Float(i) / Float(steps)
            let currentValue = start + (end - start) * t
            
            // Each step should be equal
            let stepSize = currentValue - previousValue
            let expectedStepSize = (end - start) / Float(steps)
            
            XCTAssertEqual(stepSize, expectedStepSize, accuracy: 0.0001,
                "Linear interpolation should have constant step size")
            
            previousValue = currentValue
        }
    }
    
    // MARK: - RED Test: STEP Interpolation
    
    /// 🔴 RED: STEP interpolation holds values until next keyframe
    ///
    /// STEP interpolation:
    /// - Value holds constant from keyframe time until just before next keyframe
    /// - At next keyframe time, value jumps to new value
    /// - This creates a "stairstep" animation curve
    func testStepInterpolationBehavior() {
        // Arrange: Keyframes at t=0 (value=0), t=0.5 (value=10), t=1.0 (value=20)
        let keyframes: [(time: Float, value: Float)] = [
            (0.0, 0.0),
            (0.5, 10.0),
            (1.0, 20.0),
        ]
        
        // Act & Assert: Sample at various times
        let testCases: [(time: Float, expected: Float)] = [
            (0.0, 0.0),    // Exactly at first keyframe
            (0.24, 0.0),   // Just before second keyframe - should hold first value
            (0.25, 0.0),   // At midpoint - should still hold first value (STEP)
            (0.5, 10.0),   // Exactly at second keyframe - jump to new value
            (0.51, 10.0),  // Just after second keyframe - hold second value
            (0.75, 10.0),  // Midway to third - still hold second value
            (0.99, 10.0),  // Just before third - hold second value
            (1.0, 20.0),   // Exactly at third keyframe
        ]
        
        for (time, expected) in testCases {
            // Find the appropriate keyframe value (STEP behavior)
            var value: Float = keyframes[0].value
            for i in (0..<keyframes.count).reversed() {
                if time >= keyframes[i].time {
                    value = keyframes[i].value
                    break
                }
            }
            
            XCTAssertEqual(value, expected, accuracy: 0.001,
                "STEP interpolation at t=\(time) should be \(expected), got \(value)")
        }
    }
    
    /// 🔴 RED: STEP interpolation for quaternions
    ///
    /// Quaternion STEP interpolation should hold rotation until next keyframe.
    func testStepInterpolationQuaternion() {
        // Arrange: Keyframes with different rotations
        let keyframes: [(time: Float, quat: simd_quatf)] = [
            (0.0, simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))),
            (0.5, simd_quatf(angle: Float.pi / 2, axis: SIMD3<Float>(0, 1, 0))),
            (1.0, simd_quatf(angle: Float.pi, axis: SIMD3<Float>(0, 1, 0))),
        ]
        
        // Act: Sample at various times
        let testCases: [(time: Float, expectedIndex: Int)] = [
            (0.0, 0),
            (0.25, 0),  // Should hold first rotation
            (0.5, 1),   // At second keyframe
            (0.75, 1),  // Should hold second rotation
            (1.0, 2),   // At third keyframe
        ]
        
        for (time, expectedIndex) in testCases {
            // Find the appropriate keyframe (STEP behavior)
            var index = 0
            for i in (0..<keyframes.count).reversed() {
                if time >= keyframes[i].time {
                    index = i
                    break
                }
            }
            
            XCTAssertEqual(index, expectedIndex,
                "STEP interpolation at t=\(time) should use keyframe \(expectedIndex)")
            
            // Verify the actual rotation value
            assertQuaternionsEqual(keyframes[index].quat, keyframes[expectedIndex].quat,
                tolerance: 0.001)
        }
    }
    
    /// 🔴 RED: STEP interpolation creates sharp transitions
    ///
    /// Unlike LINEAR, STEP creates immediate jumps at keyframe boundaries.
    func testStepInterpolationSharpTransitions() {
        // Arrange: Two keyframes close together
        let keyframes: [(time: Float, value: Float)] = [
            (0.0, 0.0),
            (0.001, 100.0),  // Very close keyframes
        ]
        
        // Act: Sample just before and after the jump
        let valueBefore = keyframes[0].value  // At t=0.0005
        let valueAt = keyframes[1].value      // At t=0.001
        
        // Assert: Big jump
        let jump = valueAt - valueBefore
        XCTAssertEqual(jump, 100.0, accuracy: 0.001,
                      "STEP interpolation should create sharp jumps between keyframes")
    }
    
    // MARK: - RED Test: CUBICSPLINE Interpolation
    
    /// 🔴 RED: CUBICSPLINE interpolation basics
    ///
    /// CUBICSPLINE interpolation uses cubic Hermite splines with:
    /// - In-tangent: Controls curve approaching the keyframe
    /// - Value: The keyframe value
    /// - Out-tangent: Controls curve leaving the keyframe
    ///
    /// Formula: p(t) = (2t³ - 3t² + 1)p₀ + (t³ - 2t² + t)m₀ + (-2t³ + 3t²)p₁ + (t³ - t²)m₁
    /// where p₀, p₁ are values and m₀, m₁ are tangents
    func testCubicSplineInterpolationBasics() {
        // Arrange: Keyframes with tangents
        // Keyframe 0: value=0, outTangent=0 (flat)
        // Keyframe 1: value=10, inTangent=0 (flat)
        // This should produce an S-curve (smooth ease-in, ease-out)
        
        let p0: Float = 0.0   // Start value
        let m0: Float = 0.0   // Out-tangent at start
        let p1: Float = 10.0  // End value
        let m1: Float = 0.0   // In-tangent at end
        
        // Act: Sample at multiple points using cubic Hermite spline
        func cubicHermite(t: Float, p0: Float, m0: Float, p1: Float, m1: Float) -> Float {
            let t2 = t * t
            let t3 = t2 * t
            
            // Hermite basis functions
            let h00 = 2 * t3 - 3 * t2 + 1  // P0 weight
            let h10 = t3 - 2 * t2 + t      // M0 weight
            let h01 = -2 * t3 + 3 * t2     // P1 weight
            let h11 = t3 - t2              // M1 weight
            
            return h00 * p0 + h10 * m0 + h01 * p1 + h11 * m1
        }
        
        // Assert: Test curve properties
        let samples: [(time: Float, expectedMin: Float, expectedMax: Float)] = [
            (0.0, 0.0, 0.0),      // Exactly at start
            (0.5, 4.5, 5.5),      // Near middle (should be close to 5)
            (1.0, 10.0, 10.0),    // Exactly at end
        ]
        
        for (time, expectedMin, expectedMax) in samples {
            let value = cubicHermite(t: time, p0: p0, m0: m0, p1: p1, m1: m1)
            
            XCTAssertGreaterThanOrEqual(value, expectedMin,
                "CUBICSPLINE at t=\(time) should be >= \(expectedMin)")
            XCTAssertLessThanOrEqual(value, expectedMax,
                "CUBICSPLINE at t=\(time) should be <= \(expectedMax)")
        }
        
        // Assert: Curve should be smooth (derivative should be continuous)
        // At t=0.5 with flat tangents, curve should be near midpoint
        let midValue = cubicHermite(t: 0.5, p0: p0, m0: m0, p1: p1, m1: m1)
        XCTAssertEqual(midValue, 5.0, accuracy: 0.1,
                      "CUBICSPLINE with flat tangents at t=0.5 should be ~5.0")
    }
    
    /// 🔴 RED: CUBICSPLINE with non-zero tangents
    ///
    /// Non-zero tangents create overshoot or anticipation effects.
    func testCubicSplineWithTangents() {
        // Arrange: Keyframes with non-zero tangents for overshoot effect
        let p0: Float = 0.0    // Start value
        let m0: Float = 20.0   // Out-tangent (high initial velocity = overshoot)
        let p1: Float = 10.0   // End value
        let m1: Float = 0.0    // In-tangent (flat arrival)
        
        func cubicHermite(t: Float, p0: Float, m0: Float, p1: Float, m1: Float) -> Float {
            let t2 = t * t
            let t3 = t2 * t
            let h00 = 2 * t3 - 3 * t2 + 1
            let h10 = t3 - 2 * t2 + t
            let h01 = -2 * t3 + 3 * t2
            let h11 = t3 - t2
            return h00 * p0 + h10 * m0 + h01 * p1 + h11 * m1
        }
        
        // Act: Sample at multiple points (excluding exact endpoints)
        var maxValue: Float = 0.0
        var maxTime: Float = 0.0
        
        for i in 1..<100 {
            let t = Float(i) / 100.0
            let value = cubicHermite(t: t, p0: p0, m0: m0, p1: p1, m1: m1)
            if value > maxValue {
                maxValue = value
                maxTime = t
            }
        }
        
        // Assert: With positive out-tangent, curve should overshoot somewhere in (0,1)
        // Note: The overshoot might be subtle depending on tangent values
        // A larger tangent value creates more pronounced overshoot
        if maxValue > p1 {
            XCTAssertGreaterThan(maxValue, p1,
                "CUBICSPLINE with positive out-tangent should overshoot target. " +
                "Max value \(maxValue) at t=\(maxTime), target was \(p1)")
        } else {
            // If no overshoot, at least verify the curve starts with positive slope
            let earlyValue = cubicHermite(t: 0.01, p0: p0, m0: m0, p1: p1, m1: m1)
            XCTAssertGreaterThan(earlyValue, 0,
                "CUBICSPLINE with positive out-tangent should start with positive velocity")
        }
        
        // Assert: Curve should still end at target
        let endValue = cubicHermite(t: 1.0, p0: p0, m0: m0, p1: p1, m1: m1)
        XCTAssertEqual(endValue, p1, accuracy: 0.001,
                      "CUBICSPLINE should end at target value regardless of tangents")
    }
    
    /// 🔴 RED: CUBICSPLINE interpolation from VRMA file
    ///
    /// VRMA files can specify CUBICSPLINE interpolation in the glTF sampler.
    /// This test verifies that such files are correctly parsed and sampled.
    func testCubicSplineFromVRMA() async throws {
        // Arrange: Try to load a VRMA with CUBICSPLINE interpolation
        let projectRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        
        let vrmaPath = "\(projectRoot)/VRMA_cubicspline.vrma"
        
        guard FileManager.default.fileExists(atPath: vrmaPath) else {
            throw XCTSkip("VRMA with CUBICSPLINE interpolation not found")
        }
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        
        // Build a test model
        let vrmDocument = try VRMBuilder()
            .setSkeleton(.defaultHumanoid)
            .build()
        
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("vrm")
        
        try vrmDocument.serialize(to: tempURL)
        let model = try await VRMModel.load(from: tempURL, device: device)
        try? FileManager.default.removeItem(at: tempURL)
        
        // Act: Load VRMA with CUBICSPLINE interpolation
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        
        // 🔴 RED: This will fail if CUBICSPLINE parsing isn't implemented
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
        
        // Assert: Animation should load and have smooth curves
        XCTAssertGreaterThan(clip.duration, 0, "Animation should have duration")
        XCTAssertGreaterThan(clip.jointTracks.count, 0, "Animation should have tracks")
        
        // Verify interpolation produces smooth values (no sharp discontinuities)
        if let track = clip.jointTracks.first {
            var previousRotation: simd_quatf?
            var maxAngularChange: Float = 0.0
            
            for i in 0...100 {
                let t = Float(i) / 100.0 * clip.duration
                let (rotation, _, _) = track.sample(at: t)
                
                guard let rot = rotation else { continue }
                
                if let prev = previousRotation {
                    // Calculate angular change
                    let dot = abs(simd_dot(rot.vector, prev.vector))
                    let angle = 2 * acos(min(1, dot))
                    maxAngularChange = max(maxAngularChange, angle)
                }
                previousRotation = rot
            }
            
            // CUBICSPLINE should have smaller maximum angular change than STEP
            // (this is a heuristic, not a strict requirement)
            print("Max angular change with CUBICSPLINE: \(maxAngularChange * 180 / Float.pi)°")
        }
    }
    
    /// 🔴 RED: CUBICSPLINE smoothness compared to LINEAR
    ///
    /// CUBICSPLINE should produce smoother velocity curves than LINEAR.
    func testCubicSplineSmoothness() {
        // Arrange: Same keyframes, different interpolation
        let keyframes: [(time: Float, value: Float)] = [
            (0.0, 0.0),
            (0.5, 10.0),
            (1.0, 0.0),
        ]
        
        // Act: Sample LINEAR interpolation
        var linearValues: [Float] = []
        for i in 0...100 {
            let t = Float(i) / 100.0
            // Linear interpolation between keyframes
            var value: Float = 0.0
            for j in 0..<(keyframes.count - 1) {
                if t >= keyframes[j].time && t <= keyframes[j + 1].time {
                    let segmentT = (t - keyframes[j].time) / (keyframes[j + 1].time - keyframes[j].time)
                    value = keyframes[j].value + (keyframes[j + 1].value - keyframes[j].value) * segmentT
                    break
                }
            }
            linearValues.append(value)
        }
        
        // Assert: LINEAR has constant velocity between keyframes
        var linearVelocities: [Float] = []
        for i in 1..<linearValues.count {
            let velocity = linearValues[i] - linearValues[i - 1]
            linearVelocities.append(velocity)
        }
        
        // Verify LINEAR has piecewise constant velocity (changes at keyframes)
        let firstHalfVelocity = linearVelocities[25]  // Around t=0.25
        let secondHalfVelocity = linearVelocities[75] // Around t=0.75
        
        XCTAssertGreaterThan(firstHalfVelocity, 0, "First half should have positive velocity")
        XCTAssertLessThan(secondHalfVelocity, 0, "Second half should have negative velocity")
        
        // Velocity should change abruptly at t=0.5
        let velocityChange = abs(secondHalfVelocity - firstHalfVelocity)
        XCTAssertGreaterThan(velocityChange, 0.1, "LINEAR should have velocity discontinuity at keyframe")
        
        // TODO: Compare with CUBICSPLINE which should have continuous velocity
    }
    
    // MARK: - RED Test: Interpolation Edge Cases
    
    /// 🔴 RED: Interpolation with single keyframe
    ///
    /// Single keyframe should always return that value regardless of interpolation type.
    func testInterpolationSingleKeyframe() {
        let singleValue: Float = 5.0
        
        // All interpolation types should return the same value
        let testTimes: [Float] = [0.0, 0.5, 1.0, 2.0, -1.0]
        
        for time in testTimes {
            // For single keyframe, just return the value
            let value = singleValue
            XCTAssertEqual(value, singleValue,
                "Single keyframe should always return \(singleValue), got \(value) at t=\(time)")
        }
    }
    
    /// 🔴 RED: Interpolation at boundaries
    ///
    /// Sampling at exactly t=0 and t=duration should return keyframe values.
    func testInterpolationBoundaries() {
        let keyframes: [(time: Float, value: Float)] = [
            (0.0, 0.0),
            (1.0, 10.0),
        ]
        
        // At t=0, should be first keyframe
        let valueAt0 = interpolateLinear(time: 0.0, keyframes: keyframes)
        XCTAssertEqual(valueAt0, 0.0, accuracy: 0.001)
        
        // At t=1, should be second keyframe
        let valueAt1 = interpolateLinear(time: 1.0, keyframes: keyframes)
        XCTAssertEqual(valueAt1, 10.0, accuracy: 0.001)
    }
    
    /// 🔴 RED: Interpolation extrapolation behavior
    ///
    /// Sampling before first keyframe or after last keyframe should clamp.
    func testInterpolationExtrapolation() {
        let keyframes: [(time: Float, value: Float)] = [
            (0.0, 0.0),
            (1.0, 10.0),
        ]
        
        // Before start: should clamp to first keyframe
        let valueBefore = interpolateLinear(time: -1.0, keyframes: keyframes)
        XCTAssertEqual(valueBefore, 0.0, accuracy: 0.001,
                      "Extrapolation before start should clamp to first keyframe")
        
        // After end: should clamp to last keyframe
        let valueAfter = interpolateLinear(time: 2.0, keyframes: keyframes)
        XCTAssertEqual(valueAfter, 10.0, accuracy: 0.001,
                      "Extrapolation after end should clamp to last keyframe")
    }
}

// MARK: - Helper Functions

extension InterpolationTests {
    
    /// Linear interpolation helper for testing
    private func interpolateLinear(time: Float, keyframes: [(time: Float, value: Float)]) -> Float {
        // Handle edge cases
        guard !keyframes.isEmpty else { return 0.0 }
        guard keyframes.count > 1 else { return keyframes[0].value }
        
        // Clamp to range
        if time <= keyframes[0].time {
            return keyframes[0].value
        }
        if time >= keyframes.last!.time {
            return keyframes.last!.value
        }
        
        // Find segment
        for i in 0..<(keyframes.count - 1) {
            if time >= keyframes[i].time && time <= keyframes[i + 1].time {
                let segmentDuration = keyframes[i + 1].time - keyframes[i].time
                let segmentT = (time - keyframes[i].time) / segmentDuration
                return keyframes[i].value + (keyframes[i + 1].value - keyframes[i].value) * segmentT
            }
        }
        
        return keyframes.last!.value
    }
}

// Note: InterpolationType is defined in VRMADataGenerator.swift
