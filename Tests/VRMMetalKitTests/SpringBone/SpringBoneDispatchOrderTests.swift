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

/// Guard for #452: a spring-bone substep must not depend on the order in
/// which the GPU runs the threads of one dispatch.
///
/// The per-bone kernels read the parent joint's state. A GPU runs the 32
/// lanes of a SIMD group in lockstep, but it may run separate SIMD groups in
/// any order. If a child reads a slot that its parent's thread rewrites in
/// the same dispatch, the child sees the old value on some runs and the new
/// one on others. That only shows up at SIMD-group boundaries, and only when
/// the GPU is busy, so a serial render never catches it.
///
/// `testSerializeBoneDispatches` forces the worst-case order every time: one
/// dispatch per bone, parent first. A race-free kernel gives the same bits
/// as the normal single dispatch.
final class SpringBoneDispatchOrderTests: XCTestCase {

    private var device: MTLDevice!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    func testSubstepIsIndependentOfIntraDispatchBoneOrder() throws {
        let parallel = try simulate(serialized: false)
        let serialized = try simulate(serialized: true)

        XCTAssertEqual(parallel.curr.count, serialized.curr.count)
        for bone in parallel.curr.indices {
            XCTAssertEqual(parallel.curr[bone], serialized.curr[bone],
                           "bonePosCurr[\(bone)] depends on the order the GPU runs the dispatch's threads")
            XCTAssertEqual(parallel.prev[bone], serialized.prev[bone],
                           "bonePosPrev[\(bone)] depends on the order the GPU runs the dispatch's threads")
        }
    }

    // MARK: - Helpers

    /// Builds a fresh chain, displaces every joint from its bind pose so the
    /// stiffness, inertia and distance terms all move each parent, and runs
    /// one synchronous frame (two 120 Hz substeps).
    private func simulate(serialized: Bool) throws -> (curr: [SIMD3<Float>], prev: [SIMD3<Float>]) {
        let boneCount = 8
        let model = try SpringBoneTestFixtures.makeVerticalChain(device: device, boneCount: boneCount)
        var spring = VRMSpring(name: "OrderChain")
        spring.joints = (0..<boneCount).map { SpringBoneTestFixtures.defaultJoint(node: $0) }
        var springBone = VRMSpringBone()
        springBone.springs = [spring]
        model.springBone = springBone

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: boneCount, numSpheres: 0, numCapsules: 0, numPlanes: 0)
        model.springBoneBuffers = buffers
        model.springBoneGlobalParams = SpringBoneTestFixtures.defaultGlobalParams(numBones: boneCount)

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)
        system.testSerializeBoneDispatches = serialized

        for bone in 1..<boneCount {
            let rest = SpringBoneTestFixtures.readBonePosition(model: model, boneIndex: bone)
            let swing = SIMD3<Float>(0.03 * Float(bone), 0.01, -0.02 * Float(bone))
            SpringBoneTestFixtures.seedBonePosition(buffers: buffers, boneIndex: bone,
                                                   curr: rest + swing,
                                                   prev: rest + swing * 0.5)
        }

        system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
        system.waitForPendingFrame()

        let prevBuffer = try XCTUnwrap(buffers.bonePosPrev)
        let prevPointer = prevBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: boneCount)
        return (SpringBoneTestFixtures.readBonePositions(model: model),
                Array(UnsafeBufferPointer(start: prevPointer, count: boneCount)))
    }
}
