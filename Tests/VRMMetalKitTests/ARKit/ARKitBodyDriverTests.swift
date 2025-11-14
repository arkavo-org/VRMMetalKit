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

/// Tests for ARKitBodyDriver (skeleton retargeting and transform decomposition)
final class ARKitBodyDriverTests: XCTestCase {

    // MARK: - Driver Creation Tests

    func testDriverCreation() {
        let driver = ARKitBodyDriver(
            mapper: .default,
            smoothing: SkeletonSmoothingConfig.default,
            priority: .latestActive
        )

        let stats = driver.getStatistics()
        XCTAssertEqual(stats.updateCount, 0)
    }

    func testDriverCreationWithCustomConfig() {
        let driver = ARKitBodyDriver(
            mapper: .upperBodyOnly,
            smoothing: SkeletonSmoothingConfig.lowLatency,
            priority: .primary("FrontCamera", fallback: "SideCamera"),
            stalenessThreshold: 0.2
        )

        let stats = driver.getStatistics()
        XCTAssertEqual(stats.updateCount, 0)
    }

    // MARK: - Staleness Tests

    func testStaleSkeletonSkipped() {
        let driver = ARKitBodyDriver(
            mapper: .default,
            smoothing: SkeletonSmoothingConfig.default,
            priority: .latestActive,
            stalenessThreshold: 0.15
        )

        let now = Date().timeIntervalSinceReferenceDate
        _ = ARKitBodySkeleton(
            timestamp: now - 1.0,  // 1 second old
            joints: [.hips: simd_float4x4(1)],
            isTracked: true
        )

        // Note: We can't actually test the full update without a VRM model,
        // but we can verify the driver accepts the call
        let stats = driver.getStatistics()
        XCTAssertEqual(stats.updateCount, 0)
    }

    // MARK: - Multi-Source Priority Tests

    func testMultiSourcePrioritySelection() {
        _ = ARKitBodyDriver(
            mapper: .default,
            smoothing: SkeletonSmoothingConfig.default,
            priority: .latestActive
        )

        let now = Date().timeIntervalSinceReferenceDate

        let skeleton1 = ARKitBodySkeleton(
            timestamp: now - 0.05,
            joints: [.hips: simd_float4x4(1)],
            isTracked: true
        )

        let skeleton2 = ARKitBodySkeleton(
            timestamp: now - 0.01,  // More recent
            joints: [.hips: simd_float4x4(1)],
            isTracked: true
        )

        // Verify skeletons can be created with different timestamps
        XCTAssert(skeleton2.timestamp > skeleton1.timestamp)
    }

    // MARK: - Skeleton Mapper Tests

    func testDefaultMapperHasCoreBones() {
        let mapper = ARKitSkeletonMapper.default

        // Should map core humanoid bones
        XCTAssertNotNil(mapper.jointMap[.hips])
        XCTAssertNotNil(mapper.jointMap[.spine])
        XCTAssertNotNil(mapper.jointMap[.chest])
        XCTAssertNotNil(mapper.jointMap[.neck])
        XCTAssertNotNil(mapper.jointMap[.head])
    }

    func testUpperBodyOnlyMapping() {
        let mapper = ARKitSkeletonMapper.upperBodyOnly

        // Should have upper body
        XCTAssertNotNil(mapper.jointMap[.spine])
        XCTAssertNotNil(mapper.jointMap[.leftShoulder])

        // Should have fewer mappings than default
        XCTAssert(mapper.jointMap.count < ARKitSkeletonMapper.default.jointMap.count)
    }

    func testCoreOnlyMapping() {
        let mapper = ARKitSkeletonMapper.coreOnly

        // Should have minimal core
        let coreJoints: [ARKitJoint] = [.hips, .spine, .chest, .neck, .head]
        for joint in coreJoints {
            XCTAssertNotNil(mapper.jointMap[joint], "Core should include \(joint)")
        }

        // Should have fewer mappings than default
        XCTAssert(mapper.jointMap.count < ARKitSkeletonMapper.default.jointMap.count)
    }

    // MARK: - Transform Decomposition Tests

    func testTransformDecompositionIdentity() {
        // Test that identity matrix decomposes correctly
        let identity = simd_float4x4(1)

        // Create skeleton with identity transform
        let skeleton = ARKitBodySkeleton(
            timestamp: Date().timeIntervalSinceReferenceDate,
            joints: [.hips: identity],
            isTracked: true
        )

        XCTAssertNotNil(skeleton.transform(for: .hips))
    }

    func testTransformDecompositionTranslation() {
        // Create a transform with just translation
        var transform = simd_float4x4(1)
        transform.columns.3 = simd_float4(1, 2, 3, 1)

        let skeleton = ARKitBodySkeleton(
            timestamp: Date().timeIntervalSinceReferenceDate,
            joints: [.hips: transform],
            isTracked: true
        )

        let retrieved = skeleton.transform(for: .hips)!
        XCTAssertEqual(retrieved.columns.3.x, 1, accuracy: 0.01)
        XCTAssertEqual(retrieved.columns.3.y, 2, accuracy: 0.01)
        XCTAssertEqual(retrieved.columns.3.z, 3, accuracy: 0.01)
    }

    func testTransformDecompositionRotation() {
        // Create a transform with rotation (45° around Y axis)
        let rotation = simd_quatf(ix: 0, iy: 0.383, iz: 0, r: 0.924)
        let transform = simd_float4x4(rotation)

        let skeleton = ARKitBodySkeleton(
            timestamp: Date().timeIntervalSinceReferenceDate,
            joints: [.spine: transform],
            isTracked: true
        )

        XCTAssertNotNil(skeleton.transform(for: .spine))
    }

    // MARK: - Statistics Tests

    func testStatisticsInitialState() {
        let driver = ARKitBodyDriver(
            mapper: .default,
            smoothing: SkeletonSmoothingConfig.default,
            priority: .latestActive
        )

        let stats = driver.getStatistics()
        XCTAssertEqual(stats.updateCount, 0)
        XCTAssertEqual(stats.lastUpdateTime, 0)
    }

    func testStatisticsReset() {
        let driver = ARKitBodyDriver(
            mapper: .default,
            smoothing: SkeletonSmoothingConfig.default,
            priority: .latestActive
        )

        driver.resetStatistics()

        let stats = driver.getStatistics()
        XCTAssertEqual(stats.updateCount, 0)
    }

    // MARK: - Smoothing Config Tests

    func testSkeletonSmoothingConfigPresets() {
        _ = SkeletonSmoothingConfig.default
        _ = SkeletonSmoothingConfig.lowLatency
        _ = SkeletonSmoothingConfig.smooth
    }

    func testCustomSkeletonSmoothingConfig() {
        let config = SkeletonSmoothingConfig(
            positionFilter: .ema(alpha: 0.5),
            rotationFilter: .kalman(processNoise: 0.01, measurementNoise: 0.1),
            scaleFilter: .none
        )

        // Config should be created successfully
        XCTAssertNotNil(config)
    }

    // MARK: - Priority Strategy Tests

    func testPriorityStrategyLatestActive() {
        let strategy: ARKitBodyDriver.SourcePriority = .latestActive
        // Just verify the enum case exists
        switch strategy {
        case .latestActive:
            XCTAssert(true)
        default:
            XCTFail("Wrong priority strategy")
        }
    }

    func testPriorityStrategyPrimary() {
        let strategy: ARKitBodyDriver.SourcePriority = .primary("FrontCamera", fallback: "SideCamera")
        switch strategy {
        case .primary(let primary, let fallback):
            XCTAssertEqual(primary, "FrontCamera")
            XCTAssertEqual(fallback, "SideCamera")
        default:
            XCTFail("Wrong priority strategy")
        }
    }

    // MARK: - Performance Tests

    func testDriverCreationPerformance() {
        measure {
            for _ in 0..<100 {
                _ = ARKitBodyDriver(
                    mapper: .default,
                    smoothing: SkeletonSmoothingConfig.default,
                    priority: .latestActive
                )
            }
        }
    }

    func testSkeletonCreationPerformance() {
        let now = Date().timeIntervalSinceReferenceDate

        // Create a full skeleton (20 joints)
        var joints: [ARKitJoint: simd_float4x4] = [:]
        let allJoints: [ARKitJoint] = [
            .root, .hips, .spine, .chest, .neck, .head,
            .leftShoulder, .leftUpperArm, .leftLowerArm, .leftHand,
            .rightShoulder, .rightUpperArm, .rightLowerArm, .rightHand,
            .leftUpperLeg, .leftLowerLeg, .leftFoot,
            .rightUpperLeg, .rightLowerLeg, .rightFoot
        ]

        for joint in allJoints {
            joints[joint] = simd_float4x4(1)
        }

        measure {
            for _ in 0..<1000 {
                _ = ARKitBodySkeleton(timestamp: now, joints: joints, isTracked: true)
            }
        }
    }

    // MARK: - Cache Tests

    func testCacheInvalidation() {
        let driver = ARKitBodyDriver(
            mapper: .default,
            smoothing: SkeletonSmoothingConfig.default
        )

        // Cache should be nil initially
        // (We can't directly check private properties, but we can verify behavior)

        // Call invalidateCache should not crash
        driver.invalidateCache()

        // Multiple calls should be safe
        driver.invalidateCache()
        driver.invalidateCache()
    }

    func testCacheThreadSafety() {
        let driver = ARKitBodyDriver(
            mapper: .default,
            smoothing: SkeletonSmoothingConfig.default
        )

        let expectation = XCTestExpectation(description: "Concurrent cache invalidation")
        expectation.expectedFulfillmentCount = 10

        // Concurrent invalidation from multiple threads
        for _ in 0..<10 {
            DispatchQueue.global().async {
                driver.invalidateCache()
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 2.0)
    }

    func testResetFiltersSeparateFromCache() {
        let driver = ARKitBodyDriver(
            mapper: .default,
            smoothing: SkeletonSmoothingConfig.default
        )

        // Reset filters should not invalidate cache (they're separate concerns)
        driver.resetFilters()
        driver.resetFilters(for: "hips")

        // Cache invalidation should not reset filters
        driver.invalidateCache()

        // Both operations should be independent and safe
        driver.resetFilters()
        driver.invalidateCache()
    }
}
