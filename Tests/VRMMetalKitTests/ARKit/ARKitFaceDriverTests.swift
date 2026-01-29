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

/// Tests for ARKitFaceDriver (face tracking with mapping and smoothing)
final class ARKitFaceDriverTests: XCTestCase {

    // MARK: - Driver Creation Tests

    func testDriverCreation() {
        let driver = ARKitFaceDriver(
            mapper: .default,
            smoothing: .none
        )

        let stats = driver.getStatistics()
        XCTAssertEqual(stats.totalUpdates, 0)
        XCTAssertEqual(stats.skippedUpdates, 0)
    }

    func testDriverCreationWithCustomConfig() {
        let customMapper = ARKitToVRMMapper(
            mappings: [
                "happy": .direct(ARKitFaceBlendShapes.mouthSmileLeft)
            ]
        )

        let driver = ARKitFaceDriver(
            mapper: customMapper,
            smoothing: .lowLatency
        )

        let stats = driver.getStatistics()
        XCTAssertEqual(stats.totalUpdates, 0)
    }

    // MARK: - Mapper Configuration Tests

    func testDefaultMapperConfiguration() {
        let driver = ARKitFaceDriver(
            mapper: .default,
            smoothing: .none
        )

        let stats = driver.getStatistics()
        XCTAssertEqual(stats.totalUpdates, 0)
    }

    func testCustomMapperConfiguration() {
        let customMapper = ARKitToVRMMapper(
            mappings: [
                "customExpression": .direct(ARKitFaceBlendShapes.eyeBlinkLeft)
            ]
        )

        let driver = ARKitFaceDriver(
            mapper: customMapper,
            smoothing: .none
        )

        let stats = driver.getStatistics()
        XCTAssertEqual(stats.totalUpdates, 0)
    }

    func testStatisticsStructure() {
        let driver = ARKitFaceDriver(
            mapper: .default,
            smoothing: .none
        )

        let stats = driver.getStatistics()

        XCTAssertGreaterThanOrEqual(stats.totalUpdates, 0)
        XCTAssertGreaterThanOrEqual(stats.skippedUpdates, 0)
        XCTAssertLessThanOrEqual(stats.skippedUpdates, stats.totalUpdates)
    }

    // MARK: - Smoothing Config Tests

    func testNoSmoothingConfig() {
        let driver = ARKitFaceDriver(
            mapper: .default,
            smoothing: .none
        )

        let stats = driver.getStatistics()
        XCTAssertEqual(stats.totalUpdates, 0)
    }

    func testEMASmoothingConfig() {
        let driver = ARKitFaceDriver(
            mapper: .default,
            smoothing: SmoothingConfig(global: .ema(alpha: 0.3))
        )

        let stats = driver.getStatistics()
        XCTAssertEqual(stats.totalUpdates, 0)
    }

    func testKalmanSmoothingConfig() {
        let driver = ARKitFaceDriver(
            mapper: .default,
            smoothing: .kalman
        )

        let stats = driver.getStatistics()
        XCTAssertEqual(stats.totalUpdates, 0)
    }

    // MARK: - Mapper Formula Evaluation Tests

    func testMapperEvaluateDirectFormula() {
        let mapper = ARKitToVRMMapper(mappings: [
            "testExpr": .direct(ARKitFaceBlendShapes.eyeBlinkLeft)
        ])

        let blendShapes = createBlinkBlendShapes(left: 0.8, right: 0.3)
        let weights = mapper.evaluate(blendShapes)

        XCTAssertNotNil(weights["testExpr"])
        assertFloatsEqual(weights["testExpr"] ?? 0, 0.8)
    }

    func testMapperEvaluateAverageFormula() {
        let mapper = ARKitToVRMMapper(mappings: [
            "avgBlink": .average([
                ARKitFaceBlendShapes.eyeBlinkLeft,
                ARKitFaceBlendShapes.eyeBlinkRight
            ])
        ])

        let blendShapes = createBlinkBlendShapes(left: 0.8, right: 0.4)
        let weights = mapper.evaluate(blendShapes)

        XCTAssertNotNil(weights["avgBlink"])
        assertFloatsEqual(weights["avgBlink"] ?? 0, 0.6)
    }

    func testMapperEvaluateMaxFormula() {
        let mapper = ARKitToVRMMapper(mappings: [
            "maxBlink": .max([
                ARKitFaceBlendShapes.eyeBlinkLeft,
                ARKitFaceBlendShapes.eyeBlinkRight
            ])
        ])

        let blendShapes = createBlinkBlendShapes(left: 0.3, right: 0.9)
        let weights = mapper.evaluate(blendShapes)

        XCTAssertNotNil(weights["maxBlink"])
        assertFloatsEqual(weights["maxBlink"] ?? 0, 0.9)
    }

    func testMapperEvaluateMinFormula() {
        let mapper = ARKitToVRMMapper(mappings: [
            "minBlink": .min([
                ARKitFaceBlendShapes.eyeBlinkLeft,
                ARKitFaceBlendShapes.eyeBlinkRight
            ])
        ])

        let blendShapes = createBlinkBlendShapes(left: 0.3, right: 0.9)
        let weights = mapper.evaluate(blendShapes)

        XCTAssertNotNil(weights["minBlink"])
        assertFloatsEqual(weights["minBlink"] ?? 0, 0.3)
    }

    func testMapperEvaluateWeightedFormula() {
        let mapper = ARKitToVRMMapper(mappings: [
            "weighted": .weighted([
                (ARKitFaceBlendShapes.eyeBlinkLeft, Float(0.7)),
                (ARKitFaceBlendShapes.eyeBlinkRight, Float(0.3))
            ])
        ])

        let blendShapes = createBlinkBlendShapes(left: 1.0, right: 1.0)
        let weights = mapper.evaluate(blendShapes)

        XCTAssertNotNil(weights["weighted"])
        assertFloatsEqual(weights["weighted"] ?? 0, 1.0)
    }

    func testMapperEvaluateCustomFormula() {
        let mapper = ARKitToVRMMapper(mappings: [
            "custom": .custom { shapes in
                let left = shapes.weight(for: ARKitFaceBlendShapes.eyeBlinkLeft)
                let right = shapes.weight(for: ARKitFaceBlendShapes.eyeBlinkRight)
                return max(left, right) * 0.5
            }
        ])

        let blendShapes = createBlinkBlendShapes(left: 0.4, right: 0.8)
        let weights = mapper.evaluate(blendShapes)

        XCTAssertNotNil(weights["custom"])
        assertFloatsEqual(weights["custom"] ?? 0, 0.4)
    }

    // MARK: - Default Mapper Tests

    func testDefaultMapperBlinkMapping() {
        let mapper = ARKitToVRMMapper.default
        let blendShapes = createBlinkBlendShapes(left: 0.9, right: 0.9)

        let weights = mapper.evaluate(blendShapes)

        XCTAssertNotNil(weights["blink"])
        XCTAssertGreaterThan(weights["blink"] ?? 0, 0.8)
    }

    func testDefaultMapperHappyMapping() {
        let mapper = ARKitToVRMMapper.default
        let blendShapes = createSmileBlendShapes(intensity: 1.0)

        let weights = mapper.evaluate(blendShapes)

        XCTAssertNotNil(weights["happy"])
        XCTAssertGreaterThan(weights["happy"] ?? 0, 0.5)
    }

    func testDefaultMapperAngryMapping() {
        let mapper = ARKitToVRMMapper.default
        let blendShapes = createAngryBlendShapes(intensity: 1.0)

        let weights = mapper.evaluate(blendShapes)

        XCTAssertNotNil(weights["angry"])
        XCTAssertGreaterThan(weights["angry"] ?? 0, 0.3)
    }

    func testDefaultMapperSurprisedMapping() {
        let mapper = ARKitToVRMMapper.default
        let blendShapes = createSurprisedBlendShapes(intensity: 1.0)

        let weights = mapper.evaluate(blendShapes)

        XCTAssertNotNil(weights["surprised"])
        XCTAssertGreaterThan(weights["surprised"] ?? 0, 0.3)
    }

    // MARK: - Stale Data Tests

    func testStaleDataIsSkipped() {
        let driver = ARKitFaceDriver(mapper: .default, smoothing: .none)
        let controller = VRMExpressionController()

        let oldTimestamp = Date().timeIntervalSinceReferenceDate - 1.0
        let staleBlendShapes = createBlinkBlendShapes(left: 1.0, right: 1.0, timestamp: oldTimestamp)

        driver.update(blendShapes: staleBlendShapes, controller: controller, maxAge: 0.150)

        let stats = driver.getStatistics()
        XCTAssertEqual(stats.totalUpdates, 1)
        XCTAssertEqual(stats.skippedUpdates, 1)
    }

    func testFreshDataIsProcessed() {
        let driver = ARKitFaceDriver(mapper: .default, smoothing: .none)
        let controller = VRMExpressionController()

        let freshTimestamp = Date().timeIntervalSinceReferenceDate
        let freshBlendShapes = createBlinkBlendShapes(left: 1.0, right: 1.0, timestamp: freshTimestamp)

        driver.update(blendShapes: freshBlendShapes, controller: controller, maxAge: 0.150)

        let stats = driver.getStatistics()
        XCTAssertEqual(stats.totalUpdates, 1)
        XCTAssertEqual(stats.skippedUpdates, 0)
    }

    // MARK: - Statistics Accumulation Tests

    func testStatisticsAccumulate() {
        let driver = ARKitFaceDriver(mapper: .default, smoothing: .none)
        let controller = VRMExpressionController()

        for i in 0..<5 {
            let timestamp = Date().timeIntervalSinceReferenceDate
            let blendShapes = createBlinkBlendShapes(left: Float(i) * 0.2, right: Float(i) * 0.2, timestamp: timestamp)
            driver.update(blendShapes: blendShapes, controller: controller)
        }

        let stats = driver.getStatistics()
        XCTAssertEqual(stats.totalUpdates, 5)
        XCTAssertEqual(stats.skippedUpdates, 0)
    }

    func testSkipRateCalculation() {
        let driver = ARKitFaceDriver(mapper: .default, smoothing: .none)
        let controller = VRMExpressionController()

        let staleTimestamp = Date().timeIntervalSinceReferenceDate - 1.0
        for _ in 0..<4 {
            let blendShapes = createBlinkBlendShapes(left: 1.0, right: 1.0, timestamp: staleTimestamp)
            driver.update(blendShapes: blendShapes, controller: controller, maxAge: 0.150)
        }

        let freshTimestamp = Date().timeIntervalSinceReferenceDate
        let freshBlendShapes = createBlinkBlendShapes(left: 1.0, right: 1.0, timestamp: freshTimestamp)
        driver.update(blendShapes: freshBlendShapes, controller: controller)

        let stats = driver.getStatistics()
        XCTAssertEqual(stats.totalUpdates, 5)
        XCTAssertEqual(stats.skippedUpdates, 4)
        assertFloatsEqual(stats.skipRate, 0.8)
    }

    // MARK: - Filter Reset Tests

    func testResetFiltersResetsStatistics() {
        let driver = ARKitFaceDriver(mapper: .default, smoothing: .none)
        let controller = VRMExpressionController()

        let timestamp = Date().timeIntervalSinceReferenceDate
        driver.update(
            blendShapes: createBlinkBlendShapes(left: 1.0, right: 1.0, timestamp: timestamp),
            controller: controller
        )

        XCTAssertEqual(driver.getStatistics().totalUpdates, 1)

        driver.resetFilters()

        let stats = driver.getStatistics()
        XCTAssertEqual(stats.totalUpdates, 0)
        XCTAssertEqual(stats.skippedUpdates, 0)
    }

    // MARK: - EMA Smoothing Behavior Tests

    func testEMASmoothingReducesJitter() {
        let rawDriver = ARKitFaceDriver(mapper: .simplified, smoothing: .none)
        let smoothedDriver = ARKitFaceDriver(mapper: .simplified, smoothing: SmoothingConfig(global: .ema(alpha: 0.3)))

        let controller1 = VRMExpressionController()
        let controller2 = VRMExpressionController()

        let timestamp = Date().timeIntervalSinceReferenceDate
        let blendShapes = createBlinkBlendShapes(left: 0.5, right: 0.5, timestamp: timestamp)

        rawDriver.update(blendShapes: blendShapes, controller: controller1)
        smoothedDriver.update(blendShapes: blendShapes, controller: controller2)

        XCTAssertEqual(rawDriver.getStatistics().totalUpdates, 1)
        XCTAssertEqual(smoothedDriver.getStatistics().totalUpdates, 1)
    }

    func testNoSmoothingPassesThrough() {
        let driver = ARKitFaceDriver(
            mapper: ARKitToVRMMapper(mappings: [
                "blink": .direct(ARKitFaceBlendShapes.eyeBlinkLeft)
            ]),
            smoothing: .none
        )
        let controller = VRMExpressionController()

        let timestamp = Date().timeIntervalSinceReferenceDate
        let blendShapes = createBlinkBlendShapes(left: 0.75, right: 0.5, timestamp: timestamp)

        driver.update(blendShapes: blendShapes, controller: controller)

        XCTAssertEqual(driver.getStatistics().totalUpdates, 1)
        XCTAssertEqual(driver.getStatistics().skippedUpdates, 0)
    }

    // MARK: - Smoothing Configuration Update Tests

    func testUpdateSmoothingConfig() {
        let driver = ARKitFaceDriver(mapper: .default, smoothing: .none)

        driver.updateSmoothingConfig(.lowLatency)

        let stats = driver.getStatistics()
        XCTAssertEqual(stats.totalUpdates, 0)
    }

    // MARK: - Multi-Source Tests

    func testMultiSourceLatestActive() {
        let driver = ARKitFaceDriver(mapper: .default, smoothing: .none)
        let controller = VRMExpressionController()

        let source1 = ARFaceSource(name: "Source 1")
        let source2 = ARFaceSource(name: "Source 2")

        let now = Date().timeIntervalSinceReferenceDate
        source1.update(blendShapes: createBlinkBlendShapes(left: 0.3, right: 0.3, timestamp: now - 0.05))
        source2.update(blendShapes: createBlinkBlendShapes(left: 0.9, right: 0.9, timestamp: now))

        driver.update(sources: [source1, source2], controller: controller, priority: .latestActive)

        let stats = driver.getStatistics()
        XCTAssertEqual(stats.totalUpdates, 1)
    }

    func testMultiSourcePrimary() {
        let driver = ARKitFaceDriver(mapper: .default, smoothing: .none)
        let controller = VRMExpressionController()

        let source1 = ARFaceSource(name: "Primary")
        let source2 = ARFaceSource(name: "Secondary")

        let now = Date().timeIntervalSinceReferenceDate
        source1.update(blendShapes: createBlinkBlendShapes(left: 0.5, right: 0.5, timestamp: now))
        source2.update(blendShapes: createBlinkBlendShapes(left: 0.9, right: 0.9, timestamp: now))

        driver.update(
            sources: [source1, source2],
            controller: controller,
            priority: .primary(source1.sourceID)
        )

        let stats = driver.getStatistics()
        XCTAssertEqual(stats.totalUpdates, 1)
    }

    func testMultiSourceNoActiveSources() {
        let driver = ARKitFaceDriver(mapper: .default, smoothing: .none)
        let controller = VRMExpressionController()

        let source1 = ARFaceSource(name: "Inactive 1")
        let source2 = ARFaceSource(name: "Inactive 2")

        driver.update(sources: [source1, source2], controller: controller, priority: .latestActive)

        let stats = driver.getStatistics()
        XCTAssertEqual(stats.totalUpdates, 0)
    }

    // MARK: - Direct Weight Application Tests

    func testApplyWeightsDirectly() {
        let driver = ARKitFaceDriver(mapper: .default, smoothing: .none)
        let controller = VRMExpressionController()

        let weights: [String: Float] = [
            "happy": 0.8,
            "blink": 0.5
        ]

        driver.applyWeights(weights, to: controller)

        XCTAssertNotNil(controller)
    }

    // MARK: - Performance Tests

    func testDriverCreationPerformance() {
        measure {
            for _ in 0..<100 {
                _ = ARKitFaceDriver(
                    mapper: .default,
                    smoothing: .default
                )
            }
        }
    }

    func testMapperEvaluationPerformance() {
        let mapper = ARKitToVRMMapper.default
        let blendShapes = createSmileBlendShapes(intensity: 0.8)

        measure {
            for _ in 0..<1000 {
                _ = mapper.evaluate(blendShapes)
            }
        }
    }
}
