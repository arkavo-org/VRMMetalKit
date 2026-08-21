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

/// Group 5: merged inverted-hull outline (`instance_id == 1`) plus the
/// outline pass must use `primitive.indexBufferOffset`, not `0`.
final class Group5OutlineMergeTests: XCTestCase {

    func testOutlineIndexOffsetFollowsPrimitive() {
        let primitive = VRMPrimitive()
        primitive.indexBufferOffset = 48
        XCTAssertEqual(MToonOutlineDraw.indexBufferOffset(for: primitive), 48)
        primitive.indexBufferOffset = 0
        XCTAssertEqual(MToonOutlineDraw.indexBufferOffset(for: primitive), 0)
    }

    func testHullIsDrawnAsInstanceOne() {
        XCTAssertEqual(MToonOutlineDraw.hullInstanceID, 1)
    }

    /// The merged hull and the dedicated outline pass must bind the *same*
    /// depth policy, and that policy must not write depth: a hull that writes
    /// depth at the material's sort position clips everything drawn after it
    /// inside the outline band.
    func testHullDepthPolicyIsSharedAndDoesNotWriteDepth() throws {
        XCTAssertEqual(MToonOutlineDraw.hullDepthStateKey, "blend")

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available on this host")
        }
        let renderer = VRMRenderer(device: device)
        XCTAssertNotNil(renderer.depthStencilStates[MToonOutlineDraw.hullDepthStateKey],
            "The hull depth state key must resolve to a real state, or the hull draw is skipped.")
        XCTAssertEqual(renderer.depthWriteByKey[MToonOutlineDraw.hullDepthStateKey], false,
            "The hull depth state must have depth writes disabled.")
        XCTAssertEqual(renderer.depthWriteByKey["opaque"], true,
            "Control: the opaque color state does write depth — that is what the hull must not inherit.")
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
