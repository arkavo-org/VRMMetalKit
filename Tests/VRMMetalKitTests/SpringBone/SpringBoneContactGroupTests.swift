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

final class SpringBoneContactGroupTests: XCTestCase {
    @MainActor private func participant(_ device: MTLDevice) async throws -> (VRMModel, SpringBoneComputeSystem) {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        model.updateNodeTransforms()
        try model.initializeSpringBoneGPUSystem(device: device)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)
        return (model, system)
    }

    /// §8.1 full form: a participant with an EMPTY partner set (present-but-empty
    /// foreign) is bit-identical to a non-participant (foreign absent).
    @MainActor func testEmptyGroupIsBitIdenticalToNonParticipant() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        func run(inGroup: Bool) async throws -> [SIMD3<Float>] {
            let (model, system) = try await participant(device)
            let group = SpringBoneContactGroup()
            if inGroup { group.add(system: system, model: model) }  // alone => union-minus-self is empty
            for _ in 0..<30 {
                if inGroup { group.exchange() }
                system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
                system.waitForPendingFrame()
            }
            return model.springBoneBuffers?.getCurrentPositions() ?? []
        }
        let solo = try await run(inGroup: false)
        let grouped = try await run(inGroup: true)
        XCTAssertEqual(solo.count, grouped.count)
        for i in solo.indices { XCTAssertEqual(solo[i], grouped[i], "empty group must not perturb bone \(i)") }
    }

    /// Two participants: each yields to the other's body (mutual). Assert at
    /// least one avatar's joints move relative to a solo run.
    @MainActor func testTwoParticipantsYieldToEachOther() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let (modelA, sysA) = try await participant(device)
        let (modelB, sysB) = try await participant(device)
        // Overlap the avatars: translate B's root node(s) onto A so their
        // bodies intersect. `VRMModel` has no single `rootNode`/`localPosition`
        // convenience; the project's node-translation idiom (see
        // `ARKitBodyDriver.cachedRootNodes`, `VRMModel.updateNodeTransforms()`)
        // is to mutate `VRMNode.translation` on the parentless nodes, then call
        // `updateNodeTransforms()` to propagate world matrices.
        for root in modelB.nodes where root.parent == nil {
            root.translation += SIMD3<Float>(0.1, 0, 0)
        }
        modelB.updateNodeTransforms()

        // Solo baseline for A (no partner).
        let (modelASolo, sysASolo) = try await participant(device)
        for _ in 0..<30 {
            sysASolo.update(model: modelASolo, deltaTime: 1.0 / 60.0, commandBuffer: nil)
            sysASolo.waitForPendingFrame()
        }
        let aSolo = modelASolo.springBoneBuffers?.getCurrentPositions() ?? []

        let group = SpringBoneContactGroup()
        group.add(system: sysA, model: modelA)
        group.add(system: sysB, model: modelB)
        for _ in 0..<30 {
            group.exchange()
            sysA.update(model: modelA, deltaTime: 1.0 / 60.0, commandBuffer: nil)
            sysA.waitForPendingFrame()
            sysB.update(model: modelB, deltaTime: 1.0 / 60.0, commandBuffer: nil)
            sysB.waitForPendingFrame()
        }
        let aGrouped = modelA.springBoneBuffers?.getCurrentPositions() ?? []
        var moved = false
        for i in aSolo.indices where i < aGrouped.count {
            if simd_distance(aSolo[i], aGrouped[i]) > 1e-3 { moved = true; break }
        }
        XCTAssertTrue(moved, "A's joints must react to B's body colliders")
    }
}
