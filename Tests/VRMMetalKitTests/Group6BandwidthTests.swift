//
// Copyright 2026 Arkavo
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
import Metal
@testable import VRMMetalKit

/// Group 6: BC7 load flag (6a) + light-count specialization / debug fragment (6c).
/// 6b (split VRMVertex) is intentionally not in this slice.
final class Group6BandwidthTests: XCTestCase {

    func testAggressiveCompressionIsOffByDefault() {
        XCTAssertFalse(VRMLoadingOptimization.default.contains(.aggressiveTextureCompression))
        XCTAssertTrue(VRMLoadingOptimization.maximumPerformance.contains(.aggressiveTextureCompression))
    }

    func testLightCountUsesHighestOccupiedSlot() {
        XCTAssertEqual(MToonLightSpecialization.count(keyIntensity: 1, fillIntensity: 0, rimIntensity: 0), 1)
        XCTAssertEqual(MToonLightSpecialization.count(keyIntensity: 1, fillIntensity: 0.5, rimIntensity: 0), 2)
        XCTAssertEqual(MToonLightSpecialization.count(keyIntensity: 1, fillIntensity: 0, rimIntensity: 0.3), 3)
        XCTAssertEqual(MToonLightSpecialization.count(keyIntensity: 0, fillIntensity: 0, rimIntensity: 0), 1)
    }

    func testFunctionConstantKeyWritesLightCount() {
        var key = MToonFunctionConstantKey(lightCount: 1)
        XCTAssertEqual(key.lightCount, 1)
        XCTAssertFalse(key.debugVisualization)
        key.debugVisualization = true
        XCTAssertTrue(key.debugVisualization)
        let fallback = MToonFunctionConstantKey.fallback
        XCTAssertEqual(fallback.lightCount, MToonLightSpecialization.maxLights)
    }

    func testDebugFragmentExistsWithoutFunctionConstants() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        let library = try VRMPipelineCache.shared.getLibrary(device: device)
        XCTAssertNotNil(library.makeFunction(name: "mtoon_fragment_debug"))
        XCTAssertNotNil(try library.makeFunction(
            name: "mtoon_fragment_v2",
            constantValues: MToonFunctionConstantKey.fallback.makeFunctionConstantValues()))
    }
}
