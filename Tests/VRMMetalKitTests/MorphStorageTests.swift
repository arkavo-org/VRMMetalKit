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
import Metal
@testable import VRMMetalKit

final class MorphStorageTests: XCTestCase {
    func testRenderingStorageDoesNotAllocateCompatibilityBuffers() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let primitive = VRMPrimitive()
        primitive.vertexCount = 2
        var target = VRMMorphTarget(name: "smile")
        target.positionDeltas = [SIMD3<Float>(1, 2, 3), SIMD3<Float>(4, 5, 6)]
        primitive.morphTargets = [target]
        primitive.createMorphTargetBuffers(device: device)

        XCTAssertEqual(primitive.legacyMorphBufferBytes, 0)
        let compute = try XCTUnwrap(primitive.morphPositionsSoA)
        let values = compute.contents().bindMemory(to: SIMD3<Float>.self, capacity: 2)
        XCTAssertEqual(values[0], SIMD3<Float>(1, 2, 3))
        XCTAssertEqual(values[1], SIMD3<Float>(4, 5, 6))

        let compatibility = try XCTUnwrap(primitive.morphPositionBuffers.first)
        XCTAssertEqual(primitive.legacyMorphBufferBytes, 2 * MemoryLayout<SIMD3<Float>>.stride)
        XCTAssertTrue(compatibility === primitive.morphPositionBuffers.first)
        XCTAssertEqual(compatibility.contents().bindMemory(to: SIMD3<Float>.self, capacity: 2)[1], values[1])
    }

    func testRebuildInvalidatesLazyStorageAndEmptyTargetsReleaseComputeStorage() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let primitive = VRMPrimitive()
        primitive.vertexCount = 1
        var target = VRMMorphTarget(name: "blink")
        target.positionDeltas = [SIMD3<Float>(1, 0, 0)]
        primitive.morphTargets = [target]
        primitive.createMorphTargetBuffers(device: device)
        target.positionDeltas = [SIMD3<Float>(2, 0, 0)]
        primitive.morphTargets = [target]
        let old = try XCTUnwrap(primitive.morphPositionBuffers.first)
        XCTAssertEqual(old.contents().load(as: SIMD3<Float>.self).x, 1)
        primitive.createMorphTargetBuffers(device: device)
        XCTAssertEqual(primitive.legacyMorphBufferBytes, 0)
        XCTAssertEqual(primitive.morphPositionBuffers.first?.contents().load(as: SIMD3<Float>.self).x, 2)
        primitive.morphTargets = []
        primitive.createMorphTargetBuffers(device: device)
        XCTAssertNil(primitive.morphPositionsSoA)
        XCTAssertTrue(primitive.morphPositionBuffers.isEmpty)
    }
}
