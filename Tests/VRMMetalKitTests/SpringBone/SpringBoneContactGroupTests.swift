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
        XCTAssertFalse(solo.isEmpty)  // guard: bit-equality must not pass vacuously as 0==0
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

    /// Re-joining after a model reload must REPLACE the membership, not duplicate
    /// it: `VRMRenderer.springBoneComputeSystem` is created once per renderer and
    /// reused across `loadModel`, and the documented usage is "call
    /// `joinContactGroup` after `loadModel`" — so a reload re-adds the same
    /// system. A duplicate entry would inject the avatar's OWN colliders as
    /// foreign (self-collision) and keep the OLD model's ghost alive for partners.
    @MainActor func testRejoinAfterReloadReplacesMembership() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let (modelOld, system) = try await participant(device)
        let group = SpringBoneContactGroup()
        group.add(system: system, model: modelOld)   // join after first loadModel

        // Simulate loadModel on the same renderer: the compute system is reused
        // with a NEW model instance (moved far away so it is distinguishable),
        // and the documented usage re-joins the group afterwards.
        let (modelNew, _) = try await participant(device)
        for root in modelNew.nodes where root.parent == nil {
            root.translation += SIMD3<Float>(100, 0, 0)
        }
        modelNew.updateNodeTransforms()
        try system.populateSpringBoneData(model: modelNew)
        group.add(system: system, model: modelNew)   // re-join: replace, not duplicate

        // Single membership ⇒ alone in the group, union-minus-self is EMPTY. A
        // duplicate entry would inject the avatar's own colliders as foreign.
        group.exchange()
        system.update(model: modelNew, deltaTime: 1.0 / 60.0, commandBuffer: nil)
        system.waitForPendingFrame()
        XCTAssertEqual(system.activeForeignSpheres, 0,
            "re-join must not duplicate membership: own colliders injected as foreign (self-collision)")
        XCTAssertEqual(system.activeForeignCapsules, 0,
            "re-join must not duplicate membership: own colliders injected as foreign (self-collision)")

        // A partner sees only the NEW model's colliders — the OLD model leaves
        // no ghost. B stands where the old model was (origin), far from the new
        // one: with the ghost gone, nothing foreign overlaps B, so B is
        // bit-identical to a solo run (far foreign colliders contribute
        // nothing — foreign contact is discrete, design §8.1).
        let (modelB, sysB) = try await participant(device)
        let (modelBSolo, sysBSolo) = try await participant(device)
        group.add(system: sysB, model: modelB)
        for _ in 0..<30 {
            group.exchange()
            system.update(model: modelNew, deltaTime: 1.0 / 60.0, commandBuffer: nil)
            system.waitForPendingFrame()
            sysB.update(model: modelB, deltaTime: 1.0 / 60.0, commandBuffer: nil)
            sysB.waitForPendingFrame()
            sysBSolo.update(model: modelBSolo, deltaTime: 1.0 / 60.0, commandBuffer: nil)
            sysBSolo.waitForPendingFrame()
        }
        let bSolo = modelBSolo.springBoneBuffers?.getCurrentPositions() ?? []
        let bGrouped = modelB.springBoneBuffers?.getCurrentPositions() ?? []
        XCTAssertFalse(bSolo.isEmpty)
        XCTAssertEqual(bSolo.count, bGrouped.count)
        for i in bSolo.indices {
            XCTAssertEqual(bSolo[i], bGrouped[i], "the OLD model's ghost must not reach partner bone \(i)")
        }
    }
}
