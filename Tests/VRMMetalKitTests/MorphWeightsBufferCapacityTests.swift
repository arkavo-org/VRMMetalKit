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

/// Pins the invariant that makes ``VRMConstants/Rendering/maxMorphTargets``
/// safe to raise (#385 took it 64 → 256).
///
/// The constant does double duty: it bounds the `morphIndex` an expression bind
/// may use, *and* it sizes the dense weights buffer those indices address. The
/// bound is only a memory-safety property while the two agree — a cap raised
/// without the buffer following would let an in-range bind write past the
/// allocation. Asserting the relationship rather than the literal value keeps
/// this meaningful when the cap is next tuned.
final class MorphWeightsBufferCapacityTests: XCTestCase {

    private var device: MTLDevice!

    override func setUp() async throws {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device not available") }
        device = d
    }

    /// The weights buffer must be able to hold a float for every addressable
    /// morph index.
    func testWeightsBufferCoversEveryAddressableMorphIndex() throws {
        let system = try VRMMorphTargetSystem(device: device)
        guard let buffer = system.getMorphWeightsBuffer() else {
            throw XCTSkip("Weights buffer not allocated")
        }

        let cap = VRMConstants.Rendering.maxMorphTargets
        let required = cap * MemoryLayout<Float>.stride
        XCTAssertGreaterThanOrEqual(
            buffer.length, required,
            "Weights buffer holds \(buffer.length / MemoryLayout<Float>.stride) floats but morph "
            + "indices up to \(cap - 1) are accepted. The cap and the buffer must be sized from "
            + "the same constant, or an in-range bind writes past the allocation.")
    }

    /// Writing at the highest in-range index must stay inside the buffer and
    /// land where the shader will read it.
    func testHighestInRangeIndexWritesInsideTheBuffer() throws {
        let system = try VRMMorphTargetSystem(device: device)
        guard let buffer = system.getMorphWeightsBuffer() else {
            throw XCTSkip("Weights buffer not allocated")
        }

        let cap = VRMConstants.Rendering.maxMorphTargets
        let lastIndex = cap - 1
        var weights = [Float](repeating: 0, count: cap)
        weights[lastIndex] = 0.75
        system.updateMorphWeights(weights)

        let stored = buffer.contents()
            .advanced(by: lastIndex * MemoryLayout<Float>.stride)
            .load(as: Float.self)
        XCTAssertEqual(
            stored, 0.75, accuracy: 1e-6,
            "Weight at the highest in-range morph index (\(lastIndex)) did not reach the buffer.")
    }
}
