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
///
/// Note: Full integration tests with VRMExpressionController require a complete VRM model,
/// which is complex to mock. These tests focus on driver creation, configuration, and API.
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

        // Verify driver was created with default mapper
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

        // Verify statistics structure
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
}
