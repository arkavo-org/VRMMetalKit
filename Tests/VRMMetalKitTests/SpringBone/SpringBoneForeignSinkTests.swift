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

final class SpringBoneForeignSinkTests: XCTestCase {
    @MainActor private func loadedSystem(_ device: MTLDevice) async throws -> (VRMModel, SpringBoneComputeSystem) {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        model.updateNodeTransforms()
        try model.initializeSpringBoneGPUSystem(device: device)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)
        return (model, system)
    }

    /// A foreign sphere overlapping a hair joint must push it (foreign colliders
    /// actually collide once injected).
    @MainActor func testInjectedForeignSpherePushesBones() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let (model, system) = try await loadedSystem(device)
        // Settle a few frames with no foreign colliders.
        for _ in 0..<10 {
            system.setForeignColliders(ForeignColliderSnapshot())
            system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
            system.waitForPendingFrame()
        }
        let settled = model.springBoneBuffers?.getCurrentPositions() ?? []
        // Inject a large foreign sphere at the avatar's centroid so many joints
        // overlap it; run more frames.
        let centroid = settled.reduce(SIMD3<Float>(0,0,0), +) / Float(max(settled.count, 1))
        let big = SphereCollider(center: centroid, radius: 0.5, groupIndex: 0)
        for _ in 0..<20 {
            system.setForeignColliders(ForeignColliderSnapshot(spheres: [big], capsules: []))
            system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
            system.waitForPendingFrame()
        }
        let pushed = model.springBoneBuffers?.getCurrentPositions() ?? []
        var moved = false
        for i in settled.indices where i < pushed.count {
            if simd_distance(settled[i], pushed[i]) > 1e-3 { moved = true; break }
        }
        XCTAssertTrue(moved, "at least one joint must be pushed by the injected foreign sphere")
    }

    /// Replace-or-clear: after clearing, the tail must hold zero active foreign
    /// (a departed partner leaves no ghost collider). Design §4.1.
    @MainActor func testClearLeavesZeroActiveForeign() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let (model, system) = try await loadedSystem(device)
        let s = SphereCollider(center: .zero, radius: 0.3, groupIndex: 0)
        system.setForeignColliders(ForeignColliderSnapshot(spheres: [s], capsules: []))
        system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
        system.waitForPendingFrame()
        XCTAssertEqual(system.activeForeignSpheres, 1)
        // Clear (empty snapshot) — must zero the active count, not keep the last.
        system.setForeignColliders(ForeignColliderSnapshot())
        system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
        system.waitForPendingFrame()
        XCTAssertEqual(system.activeForeignSpheres, 0)
    }

    /// Over-capacity injection is clamped, not silently dropped without notice.
    @MainActor func testOverCapacityClampsToReservedSlots() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let (model, system) = try await loadedSystem(device)
        let cap = VRMConstants.Physics.maxContactPartners * VRMConstants.Physics.foreignSphereSlotsPerPartner
        let many = (0..<(cap + 5)).map { _ in SphereCollider(center: .zero, radius: 0.1, groupIndex: 0) }
        system.setForeignColliders(ForeignColliderSnapshot(spheres: many, capsules: []))
        system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
        system.waitForPendingFrame()
        XCTAssertEqual(system.activeForeignSpheres, cap, "clamped to reserved sphere slots")
    }

    /// Carried-forward requirement (Task 4 review): `warmupPhysics` is a second
    /// physics entry point with its own local `params`. It must not ignore
    /// foreign colliders already injected via `setForeignColliders` + `update`
    /// — the uploaded `numSpheres` must include the active foreign count, the
    /// same way `update()` computes it (design consistency-by-construction).
    @MainActor func testWarmupHonorsActiveForeignSphereCount() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let (model, system) = try await loadedSystem(device)
        let buffers = try XCTUnwrap(model.springBoneBuffers)

        let s = SphereCollider(center: .zero, radius: 0.3, groupIndex: 0)
        system.setForeignColliders(ForeignColliderSnapshot(spheres: [s], capsules: []))
        system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
        system.waitForPendingFrame()
        XCTAssertEqual(system.activeForeignSpheres, 1, "sink must have written the foreign tail before warmup runs")

        system.warmupPhysics(model: model, steps: 2)

        // activeForeignSpheres must survive warmup unreset (it's set by the sink,
        // not warmup, and warmup must not silently drop the foreign contribution).
        XCTAssertEqual(system.activeForeignSpheres, 1, "warmup must not reset the active foreign count")

        let uploadedNumSpheres = try XCTUnwrap(system.globalParamsBuffer)
            .contents().load(fromByteOffset: 56, as: UInt32.self)
        XCTAssertEqual(uploadedNumSpheres, UInt32(buffers.numSpheres + system.activeForeignSpheres),
            "warmup's uploaded numSpheres must include the active foreign count, matching update()'s expression")
    }

    /// Model-reload boundary (review follow-up): the compute system is
    /// constructed once per `VRMRenderer` and reused across `loadModel()`
    /// calls. `populateSpringBoneData` must reset the foreign sink so a
    /// freshly populated model never inherits a stale, wrong-world-space
    /// foreign set from the previously loaded model (design §4.1's
    /// replace-or-clear contract applies across model boundaries too).
    @MainActor func testPopulateResetsForeignStateAcrossModelReload() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let (modelA, system) = try await loadedSystem(device)

        let s = SphereCollider(center: .zero, radius: 0.3, groupIndex: 0)
        system.setForeignColliders(ForeignColliderSnapshot(spheres: [s], capsules: []))
        system.update(model: modelA, deltaTime: 1.0 / 60.0, commandBuffer: nil)
        system.waitForPendingFrame()
        XCTAssertGreaterThan(system.activeForeignSpheres, 0,
            "sanity check: avatar A's foreign sphere must be active before the reload")

        // Reuse the SAME compute system for a second model load, as
        // VRMRenderer does across loadModel() calls.
        let path = getTestVRM10ModelPath()
        try requireFixture(path, hint: testVRM10Filename)
        let modelB = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        modelB.updateNodeTransforms()
        try modelB.initializeSpringBoneGPUSystem(device: device)
        try system.populateSpringBoneData(model: modelB)

        // No setForeignColliders call for modelB — if the sink carried A's
        // state forward, this would still report the stale active count.
        system.update(model: modelB, deltaTime: 1.0 / 60.0, commandBuffer: nil)
        system.waitForPendingFrame()
        XCTAssertEqual(system.activeForeignSpheres, 0,
            "avatar A's foreign colliders must not carry into freshly populated avatar B")
    }
}
