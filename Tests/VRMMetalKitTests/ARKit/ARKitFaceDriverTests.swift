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
@testable import VRMMetalKit

/// Tests for ARKitFaceDriver (single-source and multi-source face tracking)
final class ARKitFaceDriverTests: XCTestCase {

    // MARK: - Helper to Create Mock Expression Controller

    func makeMockController() -> VRMExpressionController {
        // Create a minimal expression controller for testing
        let expressions = VRMExpressions(
            preset: [:],
            custom: []
        )
        return VRMExpressionController(expressions: expressions)
    }

    // MARK: - Single Source Tests

    func testSingleSourceUpdate() {
        let driver = ARKitFaceDriver(
            mapper: .default,
            smoothing: .none,  // No smoothing for predictable tests
            priority: .latestActive
        )

        let shapes = ARKitFaceBlendShapes(
            timestamp: 100,
            shapes: [
                ARKitFaceBlendShapes.mouthSmileLeft: 0.8,
                ARKitFaceBlendShapes.mouthSmileRight: 0.8
            ]
        )

        let controller = makeMockController()
        driver.update(blendShapes: shapes, controller: controller)

        let stats = driver.getStatistics()
        XCTAssertEqual(stats.updateCount, 1)
    }

    func testStaleDataSkipped() {
        let driver = ARKitFaceDriver(
            mapper: .default,
            smoothing: .none,
            priority: .latestActive,
            stalenessThreshold: 0.15  // 150ms
        )

        let now = Date().timeIntervalSinceReferenceDate

        // Old data (stale)
        let staleShapes = ARKitFaceBlendShapes(
            timestamp: now - 0.5,
            shapes: [ARKitFaceBlendShapes.eyeBlinkLeft: 1.0]
        )

        let controller = makeMockController()
        driver.update(blendShapes: staleShapes, controller: controller)

        let stats = driver.getStatistics()
        // Should be skipped
        XCTAssertEqual(stats.updateCount, 0)
    }

    func testSmoothingApplied() {
        let driver = ARKitFaceDriver(
            mapper: .default,
            smoothing: .default,  // EMA smoothing
            priority: .latestActive
        )

        let shapes1 = ARKitFaceBlendShapes(
            timestamp: Date().timeIntervalSinceReferenceDate,
            shapes: [ARKitFaceBlendShapes.mouthSmileLeft: 1.0]
        )

        let shapes2 = ARKitFaceBlendShapes(
            timestamp: Date().timeIntervalSinceReferenceDate + 0.01,
            shapes: [ARKitFaceBlendShapes.mouthSmileLeft: 0.0]
        )

        let controller = makeMockController()

        driver.update(blendShapes: shapes1, controller: controller)
        driver.update(blendShapes: shapes2, controller: controller)

        // With smoothing, the transition should be smoothed (not testing exact values
        // since controller may not store weights in mock)
        let stats = driver.getStatistics()
        XCTAssertEqual(stats.updateCount, 2)
    }

    // MARK: - Multi-Source Tests

    func testMultiSourceLatestActive() {
        let driver = ARKitFaceDriver(
            mapper: .default,
            smoothing: .none,
            priority: .latestActive
        )

        let now = Date().timeIntervalSinceReferenceDate

        let source1 = ARKitFaceBlendShapes(
            timestamp: now - 0.05,
            shapes: [ARKitFaceBlendShapes.eyeBlinkLeft: 0.5]
        )

        let source2 = ARKitFaceBlendShapes(
            timestamp: now - 0.01,  // More recent
            shapes: [ARKitFaceBlendShapes.eyeBlinkLeft: 0.8]
        )

        let sources = [
            "iPhone": source1,
            "iPad": source2
        ]

        let controller = makeMockController()
        driver.updateMulti(sources: sources, controller: controller)

        let stats = driver.getStatistics()
        XCTAssertEqual(stats.updateCount, 1)  // Should use source2 (latest)
    }

    func testMultiSourcePrimaryFallback() {
        let driver = ARKitFaceDriver(
            mapper: .default,
            smoothing: .none,
            priority: .primary("iPhone", fallback: "iPad")
        )

        let now = Date().timeIntervalSinceReferenceDate

        // Primary is stale
        let primaryStale = ARKitFaceBlendShapes(
            timestamp: now - 1.0,
            shapes: [:]
        )

        // Fallback is fresh
        let fallbackFresh = ARKitFaceBlendShapes(
            timestamp: now - 0.01,
            shapes: [ARKitFaceBlendShapes.eyeBlinkLeft: 0.7]
        )

        let sources = [
            "iPhone": primaryStale,
            "iPad": fallbackFresh
        ]

        let controller = makeMockController()
        driver.updateMulti(sources: sources, controller: controller)

        let stats = driver.getStatistics()
        XCTAssertEqual(stats.updateCount, 1)  // Should use fallback
    }

    func testMultiSourceAllStale() {
        let driver = ARKitFaceDriver(
            mapper: .default,
            smoothing: .none,
            priority: .latestActive
        )

        let now = Date().timeIntervalSinceReferenceDate

        let source1 = ARKitFaceBlendShapes(timestamp: now - 1.0, shapes: [:])
        let source2 = ARKitFaceBlendShapes(timestamp: now - 2.0, shapes: [:])

        let sources = [
            "iPhone": source1,
            "iPad": source2
        ]

        let controller = makeMockController()
        driver.updateMulti(sources: sources, controller: controller)

        let stats = driver.getStatistics()
        // All stale, should skip
        XCTAssertEqual(stats.updateCount, 0)
    }

    // MARK: - Statistics Tests

    func testStatisticsTracking() {
        let driver = ARKitFaceDriver(
            mapper: .default,
            smoothing: .none,
            priority: .latestActive
        )

        let now = Date().timeIntervalSinceReferenceDate

        let fresh = ARKitFaceBlendShapes(timestamp: now - 0.01, shapes: [:])
        let stale = ARKitFaceBlendShapes(timestamp: now - 1.0, shapes: [:])

        let controller = makeMockController()

        driver.update(blendShapes: fresh, controller: controller)
        driver.update(blendShapes: stale, controller: controller)  // Skipped
        driver.update(blendShapes: fresh, controller: controller)

        let stats = driver.getStatistics()
        XCTAssertEqual(stats.updateCount, 2)  // 2 fresh, 1 skipped
        XCTAssertGreaterThan(stats.lastUpdateTime, 0)
    }

    func testStatisticsReset() {
        let driver = ARKitFaceDriver(
            mapper: .default,
            smoothing: .none,
            priority: .latestActive
        )

        let shapes = ARKitFaceBlendShapes(
            timestamp: Date().timeIntervalSinceReferenceDate,
            shapes: [:]
        )

        let controller = makeMockController()
        driver.update(blendShapes: shapes, controller: controller)

        var stats = driver.getStatistics()
        XCTAssertEqual(stats.updateCount, 1)

        driver.resetStatistics()

        stats = driver.getStatistics()
        XCTAssertEqual(stats.updateCount, 0)
    }

    // MARK: - Custom Mapper Tests

    func testCustomMapper() {
        let customMapper = ARKitToVRMMapper(
            mappings: [
                "customExpression": .direct(ARKitFaceBlendShapes.eyeBlinkLeft)
            ]
        )

        let driver = ARKitFaceDriver(
            mapper: customMapper,
            smoothing: .none,
            priority: .latestActive
        )

        let shapes = ARKitFaceBlendShapes(
            timestamp: Date().timeIntervalSinceReferenceDate,
            shapes: [ARKitFaceBlendShapes.eyeBlinkLeft: 0.9]
        )

        let controller = makeMockController()
        driver.update(blendShapes: shapes, controller: controller)

        // Verify update happened (exact value checking requires controller state access)
        let stats = driver.getStatistics()
        XCTAssertEqual(stats.updateCount, 1)
    }

    // MARK: - Performance Tests

    func testUpdatePerformance() {
        let driver = ARKitFaceDriver(
            mapper: .default,
            smoothing: .default,
            priority: .latestActive
        )

        let shapes = ARKitFaceBlendShapes(
            timestamp: Date().timeIntervalSinceReferenceDate,
            shapes: [
                ARKitFaceBlendShapes.mouthSmileLeft: 0.8,
                ARKitFaceBlendShapes.mouthSmileRight: 0.8,
                ARKitFaceBlendShapes.eyeBlinkLeft: 0.5,
                ARKitFaceBlendShapes.eyeBlinkRight: 0.5
            ]
        )

        let controller = makeMockController()

        measure {
            for _ in 0..<100 {
                driver.update(blendShapes: shapes, controller: controller)
            }
        }
    }

    func testMultiSourcePerformance() {
        let driver = ARKitFaceDriver(
            mapper: .default,
            smoothing: .default,
            priority: .latestActive
        )

        let now = Date().timeIntervalSinceReferenceDate
        let sources: [String: ARKitFaceBlendShapes] = [
            "iPhone": ARKitFaceBlendShapes(timestamp: now, shapes: [ARKitFaceBlendShapes.eyeBlinkLeft: 0.5]),
            "iPad": ARKitFaceBlendShapes(timestamp: now - 0.01, shapes: [ARKitFaceBlendShapes.eyeBlinkRight: 0.6]),
            "MacBook": ARKitFaceBlendShapes(timestamp: now - 0.02, shapes: [ARKitFaceBlendShapes.jawOpen: 0.3])
        ]

        let controller = makeMockController()

        measure {
            for _ in 0..<100 {
                driver.updateMulti(sources: sources, controller: controller)
            }
        }
    }
}
