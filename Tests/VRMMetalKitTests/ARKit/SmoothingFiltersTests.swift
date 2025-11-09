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

/// Tests for smoothing filters (EMA, Kalman, Windowed, SLERP)
final class SmoothingFiltersTests: XCTestCase {

    // MARK: - EMA Filter Tests

    func testEMAFilterBasicSmoothing() {
        var filter = config.filter(for: "test")
        var impl = filter.makeFilter()

        // First value should pass through
        let first = impl.update(1.0)
        XCTAssertEqual(first, 1.0, accuracy: 0.001)

        // Second value should be smoothed (alpha = 0.3)
        // smoothed = 0.3 * 0.0 + 0.7 * 1.0 = 0.7
        let second = impl.update(0.0)
        XCTAssertEqual(second, 0.7, accuracy: 0.001)
    }

    func testEMAFilterConvergence() {
        let config = SmoothingConfig(global: .ema(alpha: 0.3))
        var filter = config.filter(for: "test").makeFilter()

        // Feed constant value and check convergence
        for _ in 0..<100 {
            _ = filter.update(1.0)
        }

        let result = filter.update(1.0)
        XCTAssertEqual(result, 1.0, accuracy: 0.001)
    }

    func testEMAFilterReset() {
        let config = SmoothingConfig(global: .ema(alpha: 0.5))
        var filter = config.filter(for: "test").makeFilter()

        _ = filter.update(1.0)
        _ = filter.update(0.5)

        filter.reset()

        // After reset, first value should pass through
        let first = filter.update(0.8)
        XCTAssertEqual(first, 0.8, accuracy: 0.001)
    }

    func testEMAFilterAlphaRange() {
        // Alpha = 1.0 (no smoothing, instant response)
        let config1 = SmoothingConfig(global: .ema(alpha: 1.0))
        var filter1 = config1.filter(for: "test").makeFilter()
        _ = filter1.update(1.0)
        let result1 = filter1.update(0.0)
        XCTAssertEqual(result1, 0.0, accuracy: 0.001)

        // Alpha = 0.0 (maximum smoothing, no update)
        let config0 = SmoothingConfig(global: .ema(alpha: 0.0))
        var filter0 = config0.filter(for: "test").makeFilter()
        _ = filter0.update(1.0)
        let result0 = filter0.update(0.0)
        XCTAssertEqual(result0, 1.0, accuracy: 0.001)
    }

    // MARK: - Kalman Filter Tests

    func testKalmanFilterBasicSmoothing() {
        let config = SmoothingConfig(global: .kalman(processNoise: 0.01, measurementNoise: 0.1))
        var filter = config.filter(for: "test").makeFilter()

        // First value initializes
        let first = filter.update(1.0)
        XCTAssertEqual(first, 1.0, accuracy: 0.001)

        // Subsequent values should be smoothed
        let second = filter.update(0.5)
        XCTAssert(second > 0.5 && second < 1.0, "Kalman should smooth between values")
    }

    func testKalmanFilterNoiseSensitivity() {
        // High measurement noise = more smoothing
        let smoothConfig = SmoothingConfig(global: .kalman(processNoise: 0.01, measurementNoise: 1.0))
        var smoothFilter = smoothConfig.filter(for: "test").makeFilter()

        // Low measurement noise = less smoothing
        let responsiveConfig = SmoothingConfig(global: .kalman(processNoise: 0.01, measurementNoise: 0.01))
        var responsiveFilter = responsiveConfig.filter(for: "test").makeFilter()

        _ = smoothFilter.update(1.0)
        _ = responsiveFilter.update(1.0)

        let smooth = smoothFilter.update(0.0)
        let responsive = responsiveFilter.update(0.0)

        // Responsive filter should move more toward new value
        XCTAssert(responsive < smooth, "Low measurement noise should be more responsive")
    }

    // MARK: - Windowed Average Filter Tests

    func testWindowedAverageBasic() {
        let config = SmoothingConfig(global: .windowed(size: 3))
        var filter = config.filter(for: "test").makeFilter()

        XCTAssertEqual(filter.update(1.0), 1.0, accuracy: 0.001)  // [1.0] -> 1.0
        XCTAssertEqual(filter.update(2.0), 1.5, accuracy: 0.001)  // [1.0, 2.0] -> 1.5
        XCTAssertEqual(filter.update(3.0), 2.0, accuracy: 0.001)  // [1.0, 2.0, 3.0] -> 2.0
        XCTAssertEqual(filter.update(4.0), 3.0, accuracy: 0.001)  // [2.0, 3.0, 4.0] -> 3.0
    }

    func testWindowedAverageWindowSize() {
        let config = SmoothingConfig(global: .windowed(size: 5))
        var filter = config.filter(for: "test").makeFilter()

        // Fill window
        for i in 1...5 {
            _ = filter.update(Float(i))
        }

        // Average of [1, 2, 3, 4, 5] = 3.0
        XCTAssertEqual(filter.update(5.0), 3.8, accuracy: 0.001)  // [2, 3, 4, 5, 5]
    }

    // MARK: - Pass-Through Filter Tests

    func testPassThroughFilter() {
        let config = SmoothingConfig(global: .none)
        var filter = config.filter(for: "test").makeFilter()

        XCTAssertEqual(filter.update(1.0), 1.0)
        XCTAssertEqual(filter.update(0.5), 0.5)
        XCTAssertEqual(filter.update(0.0), 0.0)
    }

    // MARK: - Filter Manager Tests

    func testFilterManagerLazyCreation() {
        let config = SmoothingConfig.default
        let manager = FilterManager(config: config)

        let result = manager.update(key: "test", value: 1.0)
        XCTAssertEqual(result, 1.0, accuracy: 0.001)
    }

    func testFilterManagerPerKeyState() {
        let config = SmoothingConfig(global: .ema(alpha: 0.5))
        let manager = FilterManager(config: config)

        // Two keys should have independent state
        _ = manager.update(key: "key1", value: 1.0)
        _ = manager.update(key: "key2", value: 0.0)

        let result1 = manager.update(key: "key1", value: 0.0)
        let result2 = manager.update(key: "key2", value: 1.0)

        XCTAssertEqual(result1, 0.5, accuracy: 0.001)
        XCTAssertEqual(result2, 0.5, accuracy: 0.001)
    }

    func testFilterManagerReset() {
        let config = SmoothingConfig(global: .ema(alpha: 0.5))
        let manager = FilterManager(config: config)

        _ = manager.update(key: "test", value: 1.0)
        manager.reset(key: "test")

        // After reset, should pass through
        let result = manager.update(key: "test", value: 0.5)
        XCTAssertEqual(result, 0.5, accuracy: 0.001)
    }

    func testFilterManagerPrune() {
        let config = SmoothingConfig.default
        let manager = FilterManager(config: config)

        _ = manager.update(key: "keep", value: 1.0)
        _ = manager.update(key: "remove", value: 1.0)

        manager.prune(activeKeys: ["keep"])

        // After prune, "remove" filter should be recreated
        let result = manager.update(key: "remove", value: 0.5)
        XCTAssertEqual(result, 0.5, accuracy: 0.001)
    }

    // MARK: - Skeleton Filter Manager Tests

    func testSkeletonFilterPositionSmoothing() {
        let config = SkeletonSmoothingConfig(positionFilter: .ema(alpha: 0.5))
        let manager = SkeletonFilterManager(config: config)

        let pos1 = SIMD3<Float>(1, 1, 1)
        let pos2 = SIMD3<Float>(0, 0, 0)

        let result1 = manager.updatePosition(joint: "hips", position: pos1)
        XCTAssertEqual(result1, pos1)

        let result2 = manager.updatePosition(joint: "hips", position: pos2)
        XCTAssertEqual(result2.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(result2.y, 0.5, accuracy: 0.001)
        XCTAssertEqual(result2.z, 0.5, accuracy: 0.001)
    }

    func testSkeletonFilterRotationSLERP() {
        let config = SkeletonSmoothingConfig(rotationFilter: .ema(alpha: 0.5))
        let manager = SkeletonFilterManager(config: config)

        let identity = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        let rotated = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))

        // First rotation should pass through
        let result1 = manager.updateRotation(joint: "spine", rotation: identity)
        XCTAssertEqual(result1.angle, identity.angle, accuracy: 0.01)

        // Second rotation should be SLERP'd
        let result2 = manager.updateRotation(joint: "spine", rotation: rotated)

        // Result should be between identity and rotated (approximately pi/4)
        XCTAssert(result2.angle > 0.0 && result2.angle < .pi / 2)
    }

    func testSkeletonFilterQuaternionDoubleCover() {
        let config = SkeletonSmoothingConfig(rotationFilter: .ema(alpha: 0.5))
        let manager = SkeletonFilterManager(config: config)

        let q1 = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        let q2 = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        let q2Negated = simd_quatf(vector: -q2.vector)  // Same rotation, opposite hemisphere

        _ = manager.updateRotation(joint: "test", rotation: q1)

        // Both should produce similar results (shortest path)
        let result1 = manager.updateRotation(joint: "test", rotation: q2)

        manager.reset(joint: "test")
        _ = manager.updateRotation(joint: "test", rotation: q1)

        let result2 = manager.updateRotation(joint: "test", rotation: q2Negated)

        // Results should be similar (handling double-cover)
        XCTAssertEqual(result1.angle, result2.angle, accuracy: 0.1)
    }

    func testSkeletonFilterIndependentJoints() {
        let config = SkeletonSmoothingConfig.default
        let manager = SkeletonFilterManager(config: config)

        let pos1 = SIMD3<Float>(1, 0, 0)
        let pos2 = SIMD3<Float>(0, 1, 0)

        _ = manager.updatePosition(joint: "joint1", position: pos1)
        _ = manager.updatePosition(joint: "joint2", position: pos2)

        // Each joint should maintain independent state
        let result1 = manager.updatePosition(joint: "joint1", position: SIMD3<Float>(0, 0, 0))
        let result2 = manager.updatePosition(joint: "joint2", position: SIMD3<Float>(0, 0, 0))

        XCTAssertNotEqual(result1, result2)
    }

    func testSkeletonFilterReset() {
        let config = SkeletonSmoothingConfig.default
        let manager = SkeletonFilterManager(config: config)

        _ = manager.updatePosition(joint: "test", position: SIMD3<Float>(1, 1, 1))

        manager.reset(joint: "test")

        let result = manager.updatePosition(joint: "test", position: SIMD3<Float>(0.5, 0.5, 0.5))
        XCTAssertEqual(result, SIMD3<Float>(0.5, 0.5, 0.5))
    }

    func testSkeletonFilterResetAll() {
        let config = SkeletonSmoothingConfig.default
        let manager = SkeletonFilterManager(config: config)

        _ = manager.updatePosition(joint: "joint1", position: SIMD3<Float>(1, 0, 0))
        _ = manager.updatePosition(joint: "joint2", position: SIMD3<Float>(0, 1, 0))

        manager.resetAll()

        // After reset all, both should pass through
        let result1 = manager.updatePosition(joint: "joint1", position: SIMD3<Float>(0.5, 0.5, 0.5))
        let result2 = manager.updatePosition(joint: "joint2", position: SIMD3<Float>(0.5, 0.5, 0.5))

        XCTAssertEqual(result1, SIMD3<Float>(0.5, 0.5, 0.5))
        XCTAssertEqual(result2, SIMD3<Float>(0.5, 0.5, 0.5))
    }

    // MARK: - Configuration Presets Tests

    func testSmoothingConfigPresets() {
        // Test that presets can be created
        _ = SmoothingConfig.default
        _ = SmoothingConfig.lowLatency
        _ = SmoothingConfig.smooth
        _ = SmoothingConfig.kalman
        _ = SmoothingConfig.none
    }

    func testSkeletonSmoothingConfigPresets() {
        _ = SkeletonSmoothingConfig.default
        _ = SkeletonSmoothingConfig.lowLatency
        _ = SkeletonSmoothingConfig.smooth
    }

    func testPerExpressionOverride() {
        var config = SmoothingConfig.default
        config.perExpression["blink"] = .none

        let blinkFilter = config.filter(for: "blink")
        let otherFilter = config.filter(for: "happy")

        // Blink should be .none
        if case .none = blinkFilter {
            // Expected
        } else {
            XCTFail("Blink should use .none filter")
        }

        // Other should use global default
        if case .ema = otherFilter {
            // Expected
        } else {
            XCTFail("Other expressions should use global EMA filter")
        }
    }
}
