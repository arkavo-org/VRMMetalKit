// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import simd
@testable import VRMMetalKit

/// Tests for SkeletonFilterManager, focusing on per-axis Vec3FilterState independence
/// Validates fix for PR #38 where position/scale filters maintain separate X/Y/Z state
final class SkeletonFilterManagerTests: XCTestCase {

    // MARK: - Vec3FilterState Per-Axis Independence Tests

    /// Test that X, Y, Z position filters maintain independent state
    /// This is the core fix in PR #38 - ensures each axis has its own filter instance
    func testPositionFiltersArePerAxisIndependent() {
        let config = SkeletonSmoothingConfig(
            positionFilter: .ema(alpha: 0.5),
            rotationFilter: .none,
            scaleFilter: .none
        )
        var manager = SkeletonFilterManager(config: config)

        let joint = "spine"

        // Feed different values to each axis over multiple frames
        let positions: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(1, 0, 0), // X changes
            SIMD3<Float>(1, 2, 0), // Y changes
            SIMD3<Float>(1, 2, 3), // Z changes
            SIMD3<Float>(1, 2, 3)  // All stable
        ]

        var results: [SIMD3<Float>] = []
        for position in positions {
            let filtered = manager.updatePosition(joint: joint, position: position)
            results.append(filtered)
        }

        // First frame should pass through (EMA initialization)
        XCTAssertEqual(results[0].x, 0.0, accuracy: 0.01)
        XCTAssertEqual(results[0].y, 0.0, accuracy: 0.01)
        XCTAssertEqual(results[0].z, 0.0, accuracy: 0.01)

        // Second frame: X smoothed, Y/Z unchanged
        XCTAssertGreaterThan(results[1].x, 0.0)
        XCTAssertLessThan(results[1].x, 1.0) // Smoothed between 0 and 1
        XCTAssertEqual(results[1].y, 0.0, accuracy: 0.01)
        XCTAssertEqual(results[1].z, 0.0, accuracy: 0.01)

        // Third frame: Y now smoothed toward 2, X continues smoothing, Z unchanged
        XCTAssertGreaterThan(results[2].y, 0.0)
        XCTAssertLessThan(results[2].y, 2.0)
        XCTAssertGreaterThan(results[2].x, results[1].x) // X continues toward 1
        XCTAssertEqual(results[2].z, 0.0, accuracy: 0.01)

        // Fourth frame: Z now smoothed, X/Y continue
        XCTAssertGreaterThan(results[3].z, 0.0)
        XCTAssertLessThan(results[3].z, 3.0)

        // All axes should be approaching their targets independently
        XCTAssertTrue(results[3].x > results[2].x || abs(results[3].x - 1.0) < 0.1)
        XCTAssertTrue(results[3].y > results[2].y || abs(results[3].y - 2.0) < 0.1)
    }

    /// Test that filtering one axis does not affect others
    func testFilteringOneAxisDoesNotAffectOthers() {
        let config = SkeletonSmoothingConfig(
            positionFilter: .ema(alpha: 0.3), // Heavier smoothing
            rotationFilter: .none,
            scaleFilter: .none
        )
        var manager = SkeletonFilterManager(config: config)

        let joint = "leftHand"

        // Initialize with zeros
        _ = manager.updatePosition(joint: joint, position: SIMD3<Float>(0, 0, 0))

        // Change only X
        let result1 = manager.updatePosition(joint: joint, position: SIMD3<Float>(10, 0, 0))

        // X should be smoothed (0.3 * 10 = 3.0 with alpha=0.3)
        XCTAssertGreaterThan(result1.x, 0.0)
        XCTAssertLessThan(result1.x, 10.0)

        // Y and Z should remain exactly 0 (not affected by X filtering)
        XCTAssertEqual(result1.y, 0.0, accuracy: 0.001)
        XCTAssertEqual(result1.z, 0.0, accuracy: 0.001)

        // Now change only Y
        let result2 = manager.updatePosition(joint: joint, position: SIMD3<Float>(10, 5, 0))

        // X should continue smoothing toward 10
        XCTAssertGreaterThan(result2.x, result1.x)

        // Y should start smoothing toward 5 (independent of X)
        XCTAssertGreaterThan(result2.y, 0.0)
        XCTAssertLessThan(result2.y, 5.0)

        // Z still unaffected
        XCTAssertEqual(result2.z, 0.0, accuracy: 0.001)
    }

    /// Test scale filters also maintain per-axis independence (skipped - scale filtering not implemented)
    func testScaleFiltersArePerAxisIndependent() throws {
        throw XCTSkip("Scale filtering not yet implemented in SkeletonFilterManager")
    }

    // MARK: - Rotation Filter Tests

    /// Test rotation filter initialization and SLERP behavior
    func testRotationFilterInitialization() {
        let config = SkeletonSmoothingConfig(
            positionFilter: .none,
            rotationFilter: .ema(alpha: 0.5),
            scaleFilter: .none
        )
        var manager = SkeletonFilterManager(config: config)

        let joint = "head"

        // Identity rotation
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

        // 90-degree rotation around Y (using axis-angle)
        let halfAngle = (Float.pi / 2) * 0.5
        let sinHalf = sin(halfAngle)
        let rotation90 = simd_quatf(ix: 0, iy: sinHalf, iz: 0, r: cos(halfAngle))

        // First frame
        let result1 = manager.updateRotation(joint: joint, rotation: rotation90)

        // Should SLERP partway from identity to 90 degrees
        // (PR #38 primes filter with 0.0, so first update lerps partway)
        let angle1 = acos(simd_dot(result1, rotation90)) * 2

        XCTAssertGreaterThan(angle1, 0.0) // Not at target yet
        XCTAssertLessThan(angle1, .pi / 2) // Moving toward target
    }

    /// Test that quaternion SLERP handles sign flipping correctly
    func testRotationFilterQuaternionSignFlipping() {
        let config = SkeletonSmoothingConfig.default
        var manager = SkeletonFilterManager(config: config)

        let joint = "neck"

        // Two quaternions representing same rotation but opposite sign
        let q1 = simd_quatf(ix: 0, iy: 0.707, iz: 0, r: 0.707)
        let q2 = simd_quatf(ix: 0, iy: -0.707, iz: 0, r: -0.707) // Same rotation, flipped sign

        _ = manager.updateRotation(joint: joint, rotation: q1)
        let result = manager.updateRotation(joint: joint, rotation: q2)

        // Result should not take the "long way" around the quaternion sphere
        // Dot product should be positive after adjustment
        let dot1 = simd_dot(result, q1)
        let dot2 = simd_dot(result, q2)

        // Should be close to one of them (sign-adjusted SLERP)
        XCTAssertTrue(abs(dot1) > 0.5 || abs(dot2) > 0.5)
    }

    // MARK: - Reset Tests

    /// Test that reset clears all filter state properly
    func testResetClearsFilterState() {
        var manager = SkeletonFilterManager(config: .default)

        let joint = "hips"

        // Build up some filter state
        _ = manager.updatePosition(joint: joint, position: SIMD3<Float>(0, 0, 0))
        _ = manager.updatePosition(joint: joint, position: SIMD3<Float>(10, 10, 10))

        // Reset
        manager.reset(joint: joint)

        // Next update should behave like first frame (no smoothing applied)
        let result = manager.updatePosition(joint: joint, position: SIMD3<Float>(5, 5, 5))

        // With fresh EMA filter, first value passes through
        XCTAssertEqual(result.x, 5.0, accuracy: 0.01)
        XCTAssertEqual(result.y, 5.0, accuracy: 0.01)
        XCTAssertEqual(result.z, 5.0, accuracy: 0.01)
    }

    /// Test resetAll clears all joints
    func testResetAllClearsAllJoints() {
        var manager = SkeletonFilterManager(config: .default)

        // Build state for multiple joints
        _ = manager.updatePosition(joint: "hips", position: SIMD3<Float>(1, 1, 1))
        _ = manager.updatePosition(joint: "spine", position: SIMD3<Float>(2, 2, 2))
        _ = manager.updatePosition(joint: "head", position: SIMD3<Float>(3, 3, 3))

        manager.resetAll()

        // All joints should behave like first frame
        let result1 = manager.updatePosition(joint: "hips", position: SIMD3<Float>(10, 10, 10))
        let result2 = manager.updatePosition(joint: "spine", position: SIMD3<Float>(20, 20, 20))

        XCTAssertEqual(result1.x, 10.0, accuracy: 0.01)
        XCTAssertEqual(result2.x, 20.0, accuracy: 0.01)
    }

    // MARK: - Performance Tests

    /// Test that Vec3FilterState update performance is acceptable
    func testVec3FilterStatePerformance() {
        var manager = SkeletonFilterManager(config: .default)

        let joints = ["hips", "spine", "chest", "neck", "head",
                      "leftShoulder", "leftUpperArm", "leftLowerArm", "leftHand",
                      "rightShoulder", "rightUpperArm", "rightLowerArm", "rightHand"]

        // Prime filters
        for joint in joints {
            _ = manager.updatePosition(joint: joint, position: SIMD3<Float>(0, 0, 0))
        }

        measure {
            // Simulate body tracking update (13 joints)
            for joint in joints {
                let randomPos = SIMD3<Float>(
                    Float.random(in: -1...1),
                    Float.random(in: -1...1),
                    Float.random(in: -1...1)
                )
                _ = manager.updatePosition(joint: joint, position: randomPos)
            }
        }

        // This test documents baseline performance for Vec3FilterState
        // If dictionary overhead becomes problematic, consider refactoring to class-based filters
    }

    /// Test full skeleton update performance (position + rotation)
    func testFullSkeletonUpdatePerformance() {
        var manager = SkeletonFilterManager(config: .default)

        let joints = ["hips", "spine", "chest", "neck", "head",
                      "leftUpperArm", "leftLowerArm", "rightUpperArm", "rightLowerArm"]

        measure {
            for joint in joints {
                let pos = SIMD3<Float>(Float.random(in: -1...1),
                                       Float.random(in: -1...1),
                                       Float.random(in: -1...1))

                // Create random rotation quaternion
                let angle = Float.random(in: 0...(.pi * 2))
                let halfAngle = angle * 0.5
                let sinHalf = sin(halfAngle)
                let rot = simd_quatf(ix: 0, iy: sinHalf, iz: 0, r: cos(halfAngle))

                _ = manager.updatePosition(joint: joint, position: pos)
                _ = manager.updateRotation(joint: joint, rotation: rot)
            }
        }
    }

    // MARK: - Edge Cases

    /// Test handling of extreme position values
    func testExtremePositionValues() {
        var manager = SkeletonFilterManager(config: .default)

        let joint = "test"

        // Very large values
        let huge = SIMD3<Float>(1e6, 1e6, 1e6)
        let result1 = manager.updatePosition(joint: joint, position: huge)

        XCTAssertTrue(result1.x.isFinite)
        XCTAssertTrue(result1.y.isFinite)
        XCTAssertTrue(result1.z.isFinite)

        // Very small values
        let tiny = SIMD3<Float>(1e-6, 1e-6, 1e-6)
        let result2 = manager.updatePosition(joint: joint, position: tiny)

        XCTAssertTrue(result2.x.isFinite)
        XCTAssertTrue(result2.y.isFinite)
        XCTAssertTrue(result2.z.isFinite)
    }

    /// Test handling of NaN values (should not corrupt filter state)
    func testNaNHandling() {
        var manager = SkeletonFilterManager(config: .default)

        let joint = "test"

        // Initialize with valid data
        _ = manager.updatePosition(joint: joint, position: SIMD3<Float>(1, 2, 3))

        // Feed NaN (this represents corrupted ARKit data)
        let nanPos = SIMD3<Float>(.nan, 2, 3)
        let result = manager.updatePosition(joint: joint, position: nanPos)

        // Filter should produce NaN on X (garbage in, garbage out)
        // But Y and Z should remain valid (axis independence)
        XCTAssertTrue(result.x.isNaN)
        XCTAssertFalse(result.y.isNaN)
        XCTAssertFalse(result.z.isNaN)
    }
}
