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
import simd
@testable import VRMMetalKit

final class SpringBoneForeignCapacityTests: XCTestCase {
    /// Reserving the foreign tail (with zero foreign injected) must not perturb
    /// the authored simulation by even a bit (design §8.1).
    @MainActor func testReservedTailZeroForeignIsBitIdentical() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }

        func run(reserve: Bool) async throws -> [SIMD3<Float>] {
            let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                options: VRMLoadingOptions(augmentSpringBoneColliders: true))
            model.updateNodeTransforms()
            // The reserve flag routes through initializeSpringBoneGPUSystem's
            // headroom (0 when !reserve, N when reserve).
            model.reservesForeignColliderTail = reserve
            try model.initializeSpringBoneGPUSystem(device: device)
            let system = try SpringBoneComputeSystem(device: device)
            try system.populateSpringBoneData(model: model)
            for _ in 0..<30 {
                system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
                system.waitForPendingFrame()
            }
            return model.springBoneBuffers?.getCurrentPositions() ?? []
        }

        let baseline = try await run(reserve: false)
        let reserved = try await run(reserve: true)
        XCTAssertEqual(baseline.count, reserved.count)
        XCTAssertFalse(baseline.isEmpty)
        for i in baseline.indices {
            XCTAssertEqual(baseline[i], reserved[i], "reserved tail with zero foreign must be bit-identical at bone \(i)")
        }
    }

    @MainActor func testCapacityExceedsActiveCountWhenReserved() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        model.updateNodeTransforms()
        model.reservesForeignColliderTail = true
        try model.initializeSpringBoneGPUSystem(device: device)
        let buffers = try XCTUnwrap(model.springBoneBuffers)
        XCTAssertGreaterThan(buffers.capsuleCapacity, buffers.numCapsules)
        XCTAssertGreaterThanOrEqual(buffers.sphereCapacity, buffers.numSpheres)
    }
}
