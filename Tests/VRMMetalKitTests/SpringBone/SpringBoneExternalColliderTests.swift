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

/// The external-collider sink is the public entry point for outside physics
/// sources (rigid-body props) to deflect an avatar's hair/cloth. It is an
/// INDEPENDENT second foreign source: it composes with the cross-avatar
/// coordinator's `setForeignColliders` (union at write time) so an avatar can
/// feel both other avatars' bodies and rigid props in the same frame, and it
/// works standalone with no contact group.
final class SpringBoneExternalColliderTests: XCTestCase {
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

    /// An external sphere overlapping a hair joint must push it (external
    /// colliders actually collide once injected — the channel-2 acceptance case).
    @MainActor func testInjectedExternalSpherePushesBones() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let (model, system) = try await loadedSystem(device)
        for _ in 0..<10 {
            system.setExternalColliders(ForeignColliderSnapshot())
            system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
            system.waitForPendingFrame()
        }
        let settled = model.springBoneBuffers?.getCurrentPositions() ?? []
        let centroid = settled.reduce(SIMD3<Float>(0, 0, 0), +) / Float(max(settled.count, 1))
        let big = SphereCollider(center: centroid, radius: 0.5, groupIndex: 0)
        for _ in 0..<20 {
            system.setExternalColliders(ForeignColliderSnapshot(spheres: [big], capsules: []))
            system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
            system.waitForPendingFrame()
        }
        let pushed = model.springBoneBuffers?.getCurrentPositions() ?? []
        var moved = false
        for i in settled.indices where i < pushed.count {
            if simd_distance(settled[i], pushed[i]) > 1e-3 { moved = true; break }
        }
        XCTAssertTrue(moved, "at least one joint must be pushed by the injected external sphere")
    }

    /// Replace-or-clear: after clearing, the external contribution to the active
    /// count returns to zero (a removed prop leaves no ghost collider).
    @MainActor func testClearLeavesZeroActiveExternal() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let (model, system) = try await loadedSystem(device)
        let s = SphereCollider(center: .zero, radius: 0.3, groupIndex: 0)
        system.setExternalColliders(ForeignColliderSnapshot(spheres: [s], capsules: []))
        system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
        system.waitForPendingFrame()
        XCTAssertEqual(system.activeForeignSpheres, 1)
        system.setExternalColliders(ForeignColliderSnapshot())
        system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
        system.waitForPendingFrame()
        XCTAssertEqual(system.activeForeignSpheres, 0)
    }

    /// Props AND crowd together (the driving requirement): the external sink and
    /// the cross-avatar coordinator's foreign sink are independent sources unioned
    /// into the reserved tail. Both counts must be present at once — neither drops
    /// the other while within the reserved budget.
    @MainActor func testExternalUnionsWithForeignSet() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let (model, system) = try await loadedSystem(device)
        let foreignSpheres = (0..<2).map { _ in SphereCollider(center: .zero, radius: 0.1, groupIndex: 0) }
        let foreignCapsules = [CapsuleCollider(p0: .zero, p1: SIMD3<Float>(0, 0.1, 0), radius: 0.05, groupIndex: 0)]
        let externalSpheres = [SphereCollider(center: SIMD3<Float>(0.2, 0, 0), radius: 0.1, groupIndex: 0)]
        let externalCapsules = (0..<2).map { _ in
            CapsuleCollider(p0: .zero, p1: SIMD3<Float>(0, 0.2, 0), radius: 0.05, groupIndex: 0)
        }
        system.setForeignColliders(ForeignColliderSnapshot(spheres: foreignSpheres, capsules: foreignCapsules))
        system.setExternalColliders(ForeignColliderSnapshot(spheres: externalSpheres, capsules: externalCapsules))
        system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
        system.waitForPendingFrame()
        XCTAssertEqual(system.activeForeignSpheres, foreignSpheres.count + externalSpheres.count,
            "active spheres must be the union of the cross-avatar and external sets")
        XCTAssertEqual(system.activeForeignCapsules, foreignCapsules.count + externalCapsules.count,
            "active capsules must be the union of the cross-avatar and external sets")
    }

    /// The dedicated external budget must not steal from the cross-avatar budget:
    /// a full nearest-K crowd load PLUS props must both fit (props never contend
    /// with a full crowd for tail slots).
    @MainActor func testExternalBudgetDoesNotContendWithFullCrowd() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let (model, system) = try await loadedSystem(device)
        let crowdSpheres = (0..<VRMConstants.Physics.maxContactPartners * VRMConstants.Physics.foreignSphereSlotsPerPartner)
            .map { _ in SphereCollider(center: .zero, radius: 0.05, groupIndex: 0) }
        let propSpheres = (0..<VRMConstants.Physics.externalColliderSphereSlots)
            .map { _ in SphereCollider(center: SIMD3<Float>(1, 0, 0), radius: 0.05, groupIndex: 0) }
        system.setForeignColliders(ForeignColliderSnapshot(spheres: crowdSpheres, capsules: []))
        system.setExternalColliders(ForeignColliderSnapshot(spheres: propSpheres, capsules: []))
        system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
        system.waitForPendingFrame()
        XCTAssertEqual(system.activeForeignSpheres, crowdSpheres.count + propSpheres.count,
            "a full crowd load plus the external budget must both fit without dropping either")
    }

    /// A settled/sleeping avatar must wake when an external collider penetrates on
    /// the async (sleep-gated) render path — else props silently no-op against idle
    /// avatars (mirrors F1 for the external source).
    @MainActor func testExternalColliderWakesSleepingChains() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let (model, system) = try await loadedSystem(device)
        model.springBoneGlobalParams?.settlingFrames = 0

        let queue = device.makeCommandQueue()!
        func stepAsync() {
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
        XCTAssertTrue(asleep, "chains should fall asleep when the avatar is at rest on the async path")
        let sleepingBefore = system.sleepingBoneCount

        let positions = model.springBoneBuffers?.getCurrentPositions() ?? []
        XCTAssertFalse(positions.isEmpty)
        let centroid = positions.reduce(SIMD3<Float>(0, 0, 0), +) / Float(max(positions.count, 1))
        system.setExternalColliders(ForeignColliderSnapshot(
            spheres: [SphereCollider(center: centroid, radius: 0.5, groupIndex: 0)], capsules: []))

        stepAsync()
        XCTAssertEqual(system.sleepingBoneCount, 0,
            "injecting an external collider must wake sleeping chains; \(sleepingBefore) bones were asleep")
    }

    /// A foreign/external collider that grows or shrinks in place — same centre,
    /// same count, only its radius changing — must wake settled chains, matching the
    /// authored-collider `collidersMoved` radius check (Gitar review: wake parity).
    @MainActor func testExternalColliderRadiusChangeWakesSleepingChains() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let (model, system) = try await loadedSystem(device)
        model.springBoneGlobalParams?.settlingFrames = 0

        let queue = device.makeCommandQueue()!
        // A far static external sphere: count stays 1 every frame, so ONLY a radius
        // (or centre) change can drive a wake — isolating the radius path.
        var sphere = SphereCollider(center: SIMD3<Float>(10, 10, 10), radius: 0.05, groupIndex: 0)
        func stepAsync() {
            system.setExternalColliders(ForeignColliderSnapshot(spheres: [sphere], capsules: []))
            let cb = queue.makeCommandBuffer()!
            system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: cb)
            cb.commit()
            cb.waitUntilCompleted()
        }

        var asleep = false
        for _ in 0..<120 {
            stepAsync()
            if system.sleepingBoneCount > 0 { asleep = true; break }
        }
        XCTAssertTrue(asleep, "chains should settle with a static external sphere present")

        // Change ONLY the radius (same centre, same count).
        sphere.radius = 0.5
        stepAsync()
        XCTAssertEqual(system.sleepingBoneCount, 0,
            "a radius-only change in an external collider must wake settled chains")
    }

    /// Model-reload boundary: the compute system is reused across `loadModel()`
    /// calls; `populateSpringBoneData` must reset the external sink so a freshly
    /// populated model never inherits a stale, wrong-world-space external set.
    @MainActor func testPopulateResetsExternalStateAcrossModelReload() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let (modelA, system) = try await loadedSystem(device)

        let s = SphereCollider(center: .zero, radius: 0.3, groupIndex: 0)
        system.setExternalColliders(ForeignColliderSnapshot(spheres: [s], capsules: []))
        system.update(model: modelA, deltaTime: 1.0 / 60.0, commandBuffer: nil)
        system.waitForPendingFrame()
        XCTAssertGreaterThan(system.activeForeignSpheres, 0,
            "sanity check: the external sphere must be active before the reload")

        let path = getTestVRM10ModelPath()
        try requireFixture(path, hint: testVRM10Filename)
        let modelB = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        modelB.updateNodeTransforms()
        try modelB.initializeSpringBoneGPUSystem(device: device)
        try system.populateSpringBoneData(model: modelB)

        system.update(model: modelB, deltaTime: 1.0 / 60.0, commandBuffer: nil)
        system.waitForPendingFrame()
        XCTAssertEqual(system.activeForeignSpheres, 0,
            "the previous model's external colliders must not carry into freshly populated avatar B")
    }

    /// Empty external set must be bit-identical to today's authored simulation
    /// (design §8.1) — reserving the external budget with zero injected colliders
    /// perturbs nothing.
    @MainActor func testEmptyExternalIsBitIdentical() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }

        func run(inject: Bool) async throws -> [SIMD3<Float>] {
            let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                options: VRMLoadingOptions(augmentSpringBoneColliders: true))
            model.updateNodeTransforms()
            try model.initializeSpringBoneGPUSystem(device: device)
            let system = try SpringBoneComputeSystem(device: device)
            try system.populateSpringBoneData(model: model)
            for _ in 0..<30 {
                if inject { system.setExternalColliders(ForeignColliderSnapshot()) }
                system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
                system.waitForPendingFrame()
            }
            return model.springBoneBuffers?.getCurrentPositions() ?? []
        }

        let baseline = try await run(inject: false)
        let empty = try await run(inject: true)
        XCTAssertEqual(baseline.count, empty.count)
        XCTAssertFalse(baseline.isEmpty)
        for i in baseline.indices {
            XCTAssertEqual(baseline[i], empty[i], "empty external set must be bit-identical at bone \(i)")
        }
    }
}
