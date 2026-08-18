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
@testable import VRMMetalKit

/// Group 5: instanced inverted-hull outline (`instance_id == 1`) plus the
/// outline pass must use `primitive.indexBufferOffset`, not `0`.
final class Group5OutlineMergeTests: XCTestCase {

    func testOutlineIndexOffsetFollowsPrimitive() {
        let primitive = VRMPrimitive()
        primitive.indexBufferOffset = 48
        XCTAssertEqual(MToonOutlineDraw.indexBufferOffset(for: primitive), 48)
        primitive.indexBufferOffset = 0
        XCTAssertEqual(MToonOutlineDraw.indexBufferOffset(for: primitive), 0)
    }

    func testMergedDrawUsesTwoInstances() {
        XCTAssertEqual(MToonOutlineDraw.hullInstanceID, 1)
        XCTAssertEqual(MToonOutlineDraw.instanceCount(mergingOutline: true), 2)
        XCTAssertEqual(MToonOutlineDraw.instanceCount(mergingOutline: false), 1)
    }

    func testMergeRequiresEnabledSingleSidedOutline() {
        var mtoon = VRMMToonMaterial()
        mtoon.outlineWidthMode = .worldCoordinates
        mtoon.outlineWidthFactor = 0.02
        XCTAssertTrue(MToonOutlineDraw.shouldMerge(
            globalOutlineWidth: 0.02, mtoon: mtoon, isDoubleSided: false))
        XCTAssertFalse(MToonOutlineDraw.shouldMerge(
            globalOutlineWidth: 0, mtoon: mtoon, isDoubleSided: false))
        XCTAssertFalse(MToonOutlineDraw.shouldMerge(
            globalOutlineWidth: 0.02, mtoon: mtoon, isDoubleSided: true))
        mtoon.outlineWidthMode = .none
        XCTAssertFalse(MToonOutlineDraw.shouldMerge(
            globalOutlineWidth: 0.02, mtoon: mtoon, isDoubleSided: false))
        mtoon.outlineWidthMode = .worldCoordinates
        mtoon.outlineWidthFactor = 0
        XCTAssertFalse(MToonOutlineDraw.shouldMerge(
            globalOutlineWidth: 0.02, mtoon: mtoon, isDoubleSided: false))
        XCTAssertFalse(MToonOutlineDraw.shouldMerge(
            globalOutlineWidth: 0.02, mtoon: nil, isDoubleSided: false))
    }
}
