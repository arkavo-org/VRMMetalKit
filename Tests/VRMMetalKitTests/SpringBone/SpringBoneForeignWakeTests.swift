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

/// F1 (cross-avatar collision final-review finding): on the async render path the
/// sleep gate skips the substep loop when every chain is asleep, and the wake
/// heuristics only look at THIS avatar's own motion — so a settled avatar never
/// reacts to a partner leaning in. Injecting foreign colliders must wake the
/// sleeping chains.
final class SpringBoneForeignWakeTests: XCTestCase {
    @MainActor func testForeignColliderInjectionWakesSleepingChains() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        model.updateNodeTransforms()
        try model.initializeSpringBoneGPUSystem(device: device)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)
        // Skip the startup settling window so chains can fall asleep quickly.
        model.springBoneGlobalParams?.settlingFrames = 0

        let queue = device.makeCommandQueue()!
        // Async path: passing a command buffer enables the sleep gate.
        func stepAsync() {
            let cb = queue.makeCommandBuffer()!
            system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: cb)
            cb.commit()
            cb.waitUntilCompleted()
        }

        // Settle at rest until the chains sleep.
        var asleep = false
        for _ in 0..<80 {
            stepAsync()
            if system.sleepingBoneCount > 0 { asleep = true; break }
        }
        XCTAssertTrue(asleep, "chains should fall asleep when the avatar is at rest on the async path")
        let sleepingBefore = system.sleepingBoneCount

        // A partner leans in: inject a foreign collider overlapping the sleeping chains.
        let positions = model.springBoneBuffers?.getCurrentPositions() ?? []
        XCTAssertFalse(positions.isEmpty)
        let centroid = positions.reduce(SIMD3<Float>(0, 0, 0), +) / Float(max(positions.count, 1))
        system.setForeignColliders(ForeignColliderSnapshot(
            spheres: [SphereCollider(center: centroid, radius: 0.5, groupIndex: 0)], capsules: []))

        // One more async frame: the foreign injection must WAKE the sleeping chains (F1).
        stepAsync()
        XCTAssertEqual(system.sleepingBoneCount, 0,
            "injecting a foreign collider must wake sleeping chains (F1); \(sleepingBefore) bones were asleep")
    }

    /// The wake is motion/change-driven, not "stay awake forever": once the foreign
    /// set is static and unchanged, chains are allowed to sleep again (having
    /// already deflected against it), so contact doesn't pin the whole crowd awake.
    @MainActor func testStaticForeignColliderLetsChainsResleep() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        model.updateNodeTransforms()
        try model.initializeSpringBoneGPUSystem(device: device)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)
        model.springBoneGlobalParams?.settlingFrames = 0

        let queue = device.makeCommandQueue()!
        // A fixed foreign collider well away from the bones: unchanging each frame.
        let farSphere = ForeignColliderSnapshot(
            spheres: [SphereCollider(center: SIMD3<Float>(10, 10, 10), radius: 0.05, groupIndex: 0)], capsules: [])
        func stepAsync() {
            system.setForeignColliders(farSphere)   // same snapshot every frame => no change
            let cb = queue.makeCommandBuffer()!
            system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: cb)
            cb.commit()
            cb.waitUntilCompleted()
        }

        var asleep = false
        for _ in 0..<80 {
            stepAsync()
            if system.sleepingBoneCount > 0 { asleep = true; break }
        }
        XCTAssertTrue(asleep, "a static, unchanging foreign collider must not pin chains awake forever")
    }

    /// A responseScale-only change (ghost → firm via `setContactResponseScale`:
    /// same count, same geometry, only the push strength changes) must still
    /// wake sleeping chains — the contact response changes even though no
    /// collider moved (subsystem 4).
    @MainActor func testForeignResponseScaleChangeWakesSleepingChains() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        model.updateNodeTransforms()
        try model.initializeSpringBoneGPUSystem(device: device)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)
        model.springBoneGlobalParams?.settlingFrames = 0

        let queue = device.makeCommandQueue()!
        // Ghost partner: fixed geometry, responseScale 0 — static, so chains may sleep.
        var ghost = SphereCollider(center: SIMD3<Float>(10, 10, 10), radius: 0.05, groupIndex: 0)
        ghost.responseScale = 0.0
        func stepAsync(_ sphere: SphereCollider) {
            system.setForeignColliders(ForeignColliderSnapshot(spheres: [sphere], capsules: []))
            let cb = queue.makeCommandBuffer()!
            system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: cb)
            cb.commit()
            cb.waitUntilCompleted()
        }

        var asleep = false
        for _ in 0..<80 {
            stepAsync(ghost)
            if system.sleepingBoneCount > 0 { asleep = true; break }
        }
        XCTAssertTrue(asleep, "a static ghost foreign collider must not pin chains awake")

        // Ghost → firm: identical geometry, only the push scale changes.
        var firm = ghost
        firm.responseScale = 1.0
        stepAsync(firm)
        XCTAssertEqual(system.sleepingBoneCount, 0,
            "a responseScale-only change must wake sleeping chains (ghost -> firm)")
    }
}
