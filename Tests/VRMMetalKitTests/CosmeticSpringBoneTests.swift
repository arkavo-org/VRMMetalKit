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
import simd
@testable import VRMMetalKit

final class CosmeticSpringBoneTests: XCTestCase {

    // MARK: - Helpers

    private func makeHostModel(
        device: MTLDevice,
        withSpringBone: Bool = true,
        extraHostColliderGroups: Int = 0,
        hostSpringColliderGroups: [Int] = [],
        addEqualLengthSecondChain: Bool = false
    ) throws -> VRMModel {
        let gltf = try JSONDecoder().decode(
            GLTFDocument.self,
            from: Data(#"{"asset":{"version":"2.0"}}"#.utf8)
        )
        let meta = VRMMeta(licenseUrl: "https://vrm.dev/licenses/1.0/")
        let humanoid = VRMHumanoid()
        humanoid.humanBones[.hips] = VRMHumanoid.VRMHumanBone(node: 0)
        humanoid.humanBones[.chest] = VRMHumanoid.VRMHumanBone(node: 1)
        humanoid.humanBones[.head] = VRMHumanoid.VRMHumanBone(node: 2)

        let model = VRMModel(specVersion: .v1_0, meta: meta, humanoid: humanoid, gltf: gltf)
        model.device = device

        let hips = VRMNode(index: 0, name: "Hips", translation: SIMD3<Float>(0, 0.9, 0))
        let chest = VRMNode(index: 1, name: "Chest", translation: SIMD3<Float>(0, 0.4, 0))
        let head = VRMNode(index: 2, name: "Head", translation: SIMD3<Float>(0, 0.3, 0))

        // Chain A (3 joints hanging down from Head at x = -0.1)
        let a0 = VRMNode(index: 3, name: "HairA_0", translation: SIMD3<Float>(-0.1, 0.0, -0.1))
        let a1 = VRMNode(index: 4, name: "HairA_1", translation: SIMD3<Float>(0, -0.15, 0))
        let a2 = VRMNode(index: 5, name: "HairA_2", translation: SIMD3<Float>(0, -0.15, 0))

        chest.setParentOffline(hips); hips.children.append(chest)
        head.setParentOffline(chest); chest.children.append(head)
        a0.setParentOffline(head); head.children.append(a0)
        a1.setParentOffline(a0); a0.children.append(a1)
        a2.setParentOffline(a1); a1.children.append(a2)

        var nodes: [VRMNode] = [hips, chest, head, a0, a1, a2]

        if addEqualLengthSecondChain {
            let b0 = VRMNode(index: 6, name: "HairB_0", translation: SIMD3<Float>(0.1, 0.0, -0.1))
            let b1 = VRMNode(index: 7, name: "HairB_1", translation: SIMD3<Float>(0, -0.15, 0))
            let b2 = VRMNode(index: 8, name: "HairB_2", translation: SIMD3<Float>(0, -0.15, 0))
            b0.setParentOffline(head); head.children.append(b0)
            b1.setParentOffline(b0); b0.children.append(b1)
            b2.setParentOffline(b1); b1.children.append(b2)
            nodes.append(contentsOf: [b0, b1, b2])
        }

        hips.updateWorldTransform()
        model.nodes = nodes

        if withSpringBone {
            var sb = VRMSpringBone()
            // Host authored collider on Head (group 0) and Chest (group 1)
            sb.colliders = [
                VRMCollider(node: 2, shape: .sphere(offset: SIMD3<Float>(0, 0.05, 0), radius: 0.08)),
                VRMCollider(node: 1, shape: .sphere(offset: SIMD3<Float>(0, 0.0, 0), radius: 0.12)),
            ]
            sb.colliderGroups = [
                VRMColliderGroup(name: "HeadGroup", colliders: [0]),
                VRMColliderGroup(name: "ChestGroup", colliders: [1]),
            ]
            if extraHostColliderGroups > 0 {
                for g in 0..<extraHostColliderGroups {
                    sb.colliderGroups.append(VRMColliderGroup(name: "ExtraHost_\(g)", colliders: [0]))
                }
            }

            func makeChain(indices: [Int], name: String) -> VRMSpring {
                var sp = VRMSpring(name: name)
                sp.colliderGroups = hostSpringColliderGroups
                sp.joints = indices.map { idx in
                    var j = VRMSpringJoint(node: idx)
                    j.stiffness = 0.6
                    j.dragForce = 0.35
                    j.gravityPower = 0.8
                    j.gravityDir = SIMD3<Float>(0, -1, 0)
                    j.hitRadius = 0.02
                    return j
                }
                return sp
            }

            sb.springs = [makeChain(indices: [3, 4, 5], name: "HostHairA")]
            if addEqualLengthSecondChain {
                sb.springs.append(makeChain(indices: [6, 7, 8], name: "HostHairB"))
            }
            model.springBone = sb
            try model.initializeSpringBoneGPUSystem(device: device, augmentColliders: false)
        }

        model.finalizeModelLocalBounds()
        return model
    }

    /// Creates a reusable `VRMCosmeticAsset` carrying a 3-joint SpringBone ponytail
    /// and optional authored collider groups.
    private func makeSpringBoneCosmeticAsset(
        name: String = "Ponytail",
        colliderGroupCount: Int = 0,
        chainLength: Float = 0.14
    ) -> VRMCosmeticAsset {
        let root = VRMNode(index: 0, name: "\(name)_Root", translation: SIMD3<Float>(0, 0.05, -0.15))
        let mid = VRMNode(index: 1, name: "\(name)_Mid", translation: SIMD3<Float>(0, -chainLength, 0))
        let tip = VRMNode(index: 2, name: "\(name)_Tip", translation: SIMD3<Float>(0, -chainLength, 0))
        mid.setParentOffline(root); root.children.append(mid)
        tip.setParentOffline(mid); mid.children.append(tip)
        root.updateWorldTransform()

        var sb = VRMSpringBone()
        if colliderGroupCount > 0 {
            sb.colliders = [
                VRMCollider(node: 0, shape: .sphere(offset: SIMD3<Float>(0, 0, 0.05), radius: 0.05))
            ]
            sb.colliderGroups = (0..<colliderGroupCount).map {
                VRMColliderGroup(name: "\(name)_ColGrp_\($0)", colliders: [0])
            }
        }
        var sp = VRMSpring(name: "\(name)_Chain")
        sp.joints = [0, 1, 2].map { idx in
            var j = VRMSpringJoint(node: idx)
            j.stiffness = 0.5
            j.dragForce = 0.4
            j.gravityPower = 1.0
            j.gravityDir = SIMD3<Float>(0, -1, 0)
            j.hitRadius = 0.02
            return j
        }
        sb.springs = [sp]

        return VRMCosmeticAsset(
            name: name,
            specVersion: .v1_0,
            nodes: [root, mid, tip],
            meshes: [],
            materials: [],
            textures: [],
            skins: [],
            rootNodeIndices: [0],
            humanoid: nil,
            springBone: sb,
            faceLandmarks: nil,
            pbrFallbackMaterialIndices: [],
            estimatedBufferBytes: 1024
        )
    }

    // MARK: - 1. Survivor Trajectory Parity & Selective Warmup vs No-Swap Control

    func testMultiFrameSurvivorTrajectoryParityAndSelectiveWarmup() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }

        // Control avatar: never swaps anything
        let controlModel = try makeHostModel(device: device, withSpringBone: true)
        let controlSys = try SpringBoneComputeSystem(device: device)
        try controlSys.populateSpringBoneData(model: controlModel)

        // Subject avatar: identical start, then attaches a SpringBone ponytail mid-motion
        let subjectModel = try makeHostModel(device: device, withSpringBone: true)
        let subjectSys = try SpringBoneComputeSystem(device: device)
        try subjectSys.populateSpringBoneData(model: subjectModel)

        func stepBoth(headOffsetX: Float) {
            for (m, sys) in [(controlModel, controlSys), (subjectModel, subjectSys)] {
                m.nodes[2].translation = SIMD3<Float>(headOffsetX, 0.3, 0)
                m.updateNodeTransforms()
                sys.update(model: m, deltaTime: 1.0 / 60.0, commandBuffer: nil)
                sys.waitForPendingFrame()
                sys.writeBonesToNodes(model: m)
            }
        }

        // Drive both avatars through 8 frames of head sway so hair has live momentum
        for frame in 1...8 {
            stepBoth(headOffsetX: sin(Float(frame) * 0.35) * 0.12)
        }

        // Attach a SpringBone ponytail onto subject's head mid-motion and rebuild with selective warmup
        let ponytail = makeSpringBoneCosmeticAsset(name: "Ponytail", colliderGroupCount: 0)
        let handle = try subjectModel.attach(ponytail, to: .head)
        let preSwapSurvivorPos = subjectSys.activeLayout?.chains[0].jointNodes[2]?.worldPosition ?? .zero
        try subjectSys.rebuildSpringBoneData(model: subjectModel, warmupNewChainSteps: 12)

        // Selective warmup must NOT disturb surviving chain positions in GPU buffers
        let controlCurr = controlModel.springBoneBuffers!.getCurrentPositions()
        let subjectCurr = subjectModel.springBoneBuffers!.getCurrentPositions()
        XCTAssertEqual(subjectCurr.count, 6) // 3 host + 3 ponytail
        for i in 0..<3 {
            XCTAssertEqual(
                simd_distance(controlCurr[i], subjectCurr[i]),
                0.0,
                accuracy: 1e-4,
                "Surviving bone \(i) must be bit-preserved across selective warmup"
            )
        }
        _ = preSwapSurvivorPos

        // Continue stepping BOTH avatars for 6 more frames -> surviving host hair trajectory matches control!
        for frame in 9...14 {
            stepBoth(headOffsetX: sin(Float(frame) * 0.35) * 0.12)
            let cPos = controlModel.springBoneBuffers!.getCurrentPositions()
            let sPos = subjectModel.springBoneBuffers!.getCurrentPositions()
            for i in 0..<3 {
                XCTAssertLessThan(
                    simd_distance(cPos[i], sPos[i]),
                    1e-3,
                    "Frame \(frame) bone \(i) survivor trajectory drifted vs no-swap control"
                )
            }
        }

        // Detach ponytail -> back to 3 bones, surviving chain stays continuous
        subjectModel.detach(handle)
        try subjectSys.rebuildSpringBoneData(model: subjectModel, warmupNewChainSteps: 0)
        XCTAssertEqual(subjectModel.springBoneBuffers?.numBones, 3)
    }

    // MARK: - 2. Async Shared-Command-Buffer Generation Guard (Stale Handler Discarded)

    func testAsyncSharedCommandBufferGenerationGuardDiscardsStaleHandler() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal not available")
        }

        let model = try makeHostModel(device: device, withSpringBone: true)
        let sys = try SpringBoneComputeSystem(device: device)
        try sys.populateSpringBoneData(model: model)
        let gen0 = sys.physicsLayoutGeneration

        // Encode async SpringBone step on a shared command buffer WITHOUT committing yet
        let staleCB = try XCTUnwrap(queue.makeCommandBuffer())
        model.nodes[2].translation = SIMD3<Float>(0.08, 0.3, 0)
        model.updateNodeTransforms()
        sys.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: staleCB)

        // Now attach a ponytail and rebuild BEFORE staleCB even completes!
        let ponytail = makeSpringBoneCosmeticAsset(name: "AsyncTail")
        _ = try model.attach(ponytail, to: .head)
        try sys.rebuildSpringBoneData(model: model, warmupNewChainSteps: 4)
        let gen1 = sys.physicsLayoutGeneration
        XCTAssertGreaterThan(gen1, gen0)
        XCTAssertEqual(model.springBoneBuffers?.numBones, 6)

        // Now commit and wait on staleCB — its completion handler MUST be discarded cleanly!
        staleCB.commit()
        staleCB.waitUntilCompleted()

        // Verify new layout (6 bones) is intact and writeBonesToNodes succeeds with zero crash/corruption
        let nextCB = try XCTUnwrap(queue.makeCommandBuffer())
        sys.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nextCB)
        nextCB.commit()
        nextCB.waitUntilCompleted()
        sys.writeBonesToNodes(model: model)
        XCTAssertEqual(model.springBoneBuffers?.numBones, 6)
    }

    // MARK: - 3. Sleeping-Chain & Equal-Length-Root Preservation

    func testSleepingChainAndEqualLengthRootPreservation() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal not available")
        }

        let model = try makeHostModel(device: device, withSpringBone: true, addEqualLengthSecondChain: true)
        let sys = try SpringBoneComputeSystem(device: device)
        sys.sleepThreshold = 10.0 // High threshold so stationary chains fall asleep quickly
        sys.sleepDelayFrames = 2
        try sys.populateSpringBoneData(model: model)
        model.springBoneGlobalParams?.settlingFrames = 0

        // Run enough shared-CB frames for both equal-length host chains (HairA, HairB) to sleep
        for _ in 0..<6 {
            let cb = try XCTUnwrap(queue.makeCommandBuffer())
            sys.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: cb)
            cb.commit()
            cb.waitUntilCompleted()
        }
        XCTAssertEqual(sys.testChainAsleep, [true, true], "Both host chains should be asleep before swap")

        // Attach an equal-length 3-joint ponytail -> host chains 0 & 1 MUST remain asleep, new chain 2 awake!
        let ponytail = makeSpringBoneCosmeticAsset(name: "EqualLenTail", chainLength: 0.15)
        _ = try model.attach(ponytail, to: .head)
        try sys.rebuildSpringBoneData(model: model, warmupNewChainSteps: 4)

        XCTAssertEqual(sys.testChainAsleep, [true, true, false])
        // Verify GPU chainSleepBuffer matches restored sleep flags (1, 1, 0)
        XCTAssertEqual(sys.testChainSleepBufferFlags, [1, 1, 0])
    }

    // MARK: - 4. Bind-Pose Rest-Length Preservation While Animated

    func testBindPoseRestLengthPreservedWhenRebuiltUnderAnimation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }

        let model = try makeHostModel(device: device, withSpringBone: true)
        let sys = try SpringBoneComputeSystem(device: device)
        try sys.populateSpringBoneData(model: model)

        // Stretch live animated translation on HairA_1 far away from its 0.15m bind pose!
        model.nodes[4].translation = SIMD3<Float>(0, -0.60, 0)
        model.updateNodeTransforms()

        let ponytail = makeSpringBoneCosmeticAsset(name: "ClipTail")
        _ = try model.attach(ponytail, to: .head)
        try sys.rebuildSpringBoneData(model: model, warmupNewChainSteps: 0)

        let restPtr = try XCTUnwrap(model.springBoneBuffers?.restLengths)
            .contents().bindMemory(to: Float.self, capacity: 6)
        // HairA_1 (index 1) and HairA_2 (index 2) MUST keep their 0.15m bind-pose rest lengths!
        XCTAssertEqual(restPtr[1], 0.15, accuracy: 1e-4)
        XCTAssertEqual(restPtr[2], 0.15, accuracy: 1e-4)
    }

    // MARK: - 5. Foreign/External Colliders & Floor Plane Survival

    func testExternalForeignCollidersAndFloorPlaneSurviveRebuild() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }

        let model = try makeHostModel(device: device, withSpringBone: true)
        let sys = try SpringBoneComputeSystem(device: device)
        try sys.populateSpringBoneData(model: model)

        model.setFloorPlane(at: 0.05)
        let foreign = ForeignColliderSnapshot(
            spheres: [SphereCollider(center: SIMD3<Float>(0, 1.2, 0.2), radius: 0.1, groupMask: 1)],
            capsules: []
        )
        let external = ForeignColliderSnapshot(
            spheres: [SphereCollider(center: SIMD3<Float>(0.3, 1.1, 0.0), radius: 0.12, groupMask: 1)],
            capsules: []
        )
        sys.setForeignColliders(foreign)
        sys.setExternalColliders(external)

        let ponytail = makeSpringBoneCosmeticAsset(name: "Cape")
        _ = try model.attach(ponytail, to: .chest)
        try sys.rebuildSpringBoneData(model: model, warmupNewChainSteps: 2)

        // Floor plane survived
        XCTAssertEqual(model.springBoneBuffers?.numPlanes, 1)
        XCTAssertEqual(model.springBoneGlobalParams?.numPlanes, 1)

        // Foreign + external colliders survived and remain active on next update
        sys.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
        sys.waitForPendingFrame()
        XCTAssertEqual(sys.activeForeignSpheres, 2)
    }

    // MARK: - 6. Collider Group 29 Boundary, Overflow Error & Explicit Mask Isolation

    func testColliderGroup29BoundaryAndOverflowError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }

        // Host has 2 + 25 = 27 collider groups.
        let model = try makeHostModel(device: device, withSpringBone: true, extraHostColliderGroups: 25)
        let sys = try SpringBoneComputeSystem(device: device)
        try sys.populateSpringBoneData(model: model)

        // Cosmetic adds 2 groups -> total 29 (exact boundary -> MUST succeed!)
        let validCosmetic = makeSpringBoneCosmeticAsset(name: "TwoGroupProp", colliderGroupCount: 2)
        let h1 = try model.attach(validCosmetic, to: .head)
        try sys.rebuildSpringBoneData(model: model, warmupNewChainSteps: 0)
        XCTAssertEqual(sys.activeLayout?.totalAuthoredColliderGroups, 29)
        XCTAssertNotEqual(sys.activeLayout?.foreignColliderGroupIndex, 0xFFFFFFFF)

        // Second cosmetic adds 1 more group -> total 30 -> MUST throw colliderGroupLimitExceeded!
        let overflowCosmetic = makeSpringBoneCosmeticAsset(name: "OverflowProp", colliderGroupCount: 1)
        let h2 = try model.attach(overflowCosmetic, to: .chest)
        do {
            try sys.rebuildSpringBoneData(model: model, warmupNewChainSteps: 0)
            XCTFail("Expected VRMError.colliderGroupLimitExceeded at 30 authored groups")
        } catch VRMError.colliderGroupLimitExceeded(let limit, let observed) {
            XCTAssertEqual(limit, 29)
            XCTAssertEqual(observed, 30)
        }

        model.detach(h2)
        model.detach(h1)
    }

    func testExplicitColliderMasksHostEmptyGroupIsolationAndCosmeticBindings() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }

        // Host has 2 collider groups (bit 0 = Head, bit 1 = Chest); host spring has empty colliderGroups.
        let model = try makeHostModel(device: device, withSpringBone: true, hostSpringColliderGroups: [])
        let sys = try SpringBoneComputeSystem(device: device)
        try sys.populateSpringBoneData(model: model)

        // 1. Cosmetic with 1 own collider group (bit 2) and .cosmeticOnly
        let ownColCosmetic = makeSpringBoneCosmeticAsset(name: "OwnCol", colliderGroupCount: 1)
        _ = try model.attach(ownColCosmetic, to: .head, options: VRMAttachmentOptions(colliderBinding: .cosmeticOnly))

        // 2. Cosmetic with 0 own colliders and .cosmeticOnly -> mask MUST be 0 (never 0xFFFFFFFF!)
        let zeroColCosmetic = makeSpringBoneCosmeticAsset(name: "ZeroCol", colliderGroupCount: 0)
        _ = try model.attach(zeroColCosmetic, to: .head, options: VRMAttachmentOptions(colliderBinding: .cosmeticOnly))

        // 3. Cosmetic with .matchingHostRegions([.head]) -> includes host group 0 (Head), excludes group 1 (Chest)!
        let headRegionCosmetic = makeSpringBoneCosmeticAsset(name: "HeadOnly", colliderGroupCount: 0)
        _ = try model.attach(
            headRegionCosmetic,
            to: .head,
            options: VRMAttachmentOptions(colliderBinding: .matchingHostRegions([.head]))
        )

        // 4. Cosmetic with .hostGroupIndices([1]) -> includes host group 1 (Chest), excludes group 0 (Head)!
        let chestIndexCosmetic = makeSpringBoneCosmeticAsset(name: "ChestOnly", colliderGroupCount: 0)
        _ = try model.attach(
            chestIndexCosmetic,
            to: .chest,
            options: VRMAttachmentOptions(colliderBinding: .hostGroupIndices([1]))
        )

        try sys.rebuildSpringBoneData(model: model, warmupNewChainSteps: 0)
        let masks = sys.chainColliderMasks
        XCTAssertEqual(masks.count, 5)

        let cosmeticGroupBit: UInt32 = 1 << 2
        // Host chain (index 0): empty authored groups must NOT be blasted by cosmetic's bit 2!
        XCTAssertEqual(masks[0] & cosmeticGroupBit, 0, "Host empty-group chain must not collide with cosmetic colliders")
        XCTAssertNotEqual(masks[0] & 0b11, 0, "Host chain still collides with host groups 0 & 1")

        // OwnCol (.cosmeticOnly, 1 own group): strictly bit 2 only
        XCTAssertEqual(masks[1], cosmeticGroupBit)

        // ZeroCol (.cosmeticOnly, 0 own colliders): strictly 0 (NEVER 0xFFFFFFFF!)
        XCTAssertEqual(masks[2], 0)

        // HeadOnly (.matchingHostRegions([.head])): includes bit 0, excludes bit 1
        XCTAssertNotEqual(masks[3] & (1 << 0), 0)
        XCTAssertEqual(masks[3] & (1 << 1), 0)

        // ChestOnly (.hostGroupIndices([1])): includes bit 1, excludes bit 0
        XCTAssertEqual(masks[4] & (1 << 0), 0)
        XCTAssertNotEqual(masks[4] & (1 << 1), 0)
    }

    // MARK: - 7. No-Spring Host First Attachment & Clean Detach via VRMRenderer

    func testNoSpringHostFirstAttachmentAndDetachCleanup() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }

        let host = try makeHostModel(device: device, withSpringBone: false)
        XCTAssertNil(host.springBone)
        XCTAssertNil(host.springBoneBuffers)

        let renderer = VRMRenderer(device: device, config: RendererConfig(strict: .off))
        renderer.enableSpringBone = true
        renderer.loadModelWithoutWarmup(host)

        // Attach a SpringBone ponytail onto a host that had ZERO base SpringBones
        let ponytail = makeSpringBoneCosmeticAsset(name: "FirstHair")
        let handle = try host.attach(ponytail, to: .head)
        try renderer.commitSpringBoneChanges(warmupNewChainSteps: 6)

        XCTAssertEqual(host.springBoneBuffers?.numBones, 3)
        // Host synthetic colliders were synthesized and cached once from host-only skeleton
        XCTAssertNotNil(host.cachedHostSyntheticColliders)

        // Detach the last physics cosmetic -> buffers cleanly cleared
        host.detach(handle)
        try renderer.commitSpringBoneChanges(warmupNewChainSteps: 0)
        XCTAssertNil(host.springBoneBuffers)
    }

    // MARK: - 8. PR Review Regression: Cache Refresh Before Dynamic Rebuild

    func testCacheRefreshBeforeRebuildPreservesLayoutAndSurvivingChainContinuity() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }

        let model = try makeHostModel(device: device, withSpringBone: true)
        let sys = try SpringBoneComputeSystem(device: device)
        try sys.populateSpringBoneData(model: model)

        // Advance simulation several frames so host chain has live momentum and completed snapshot
        for _ in 0..<8 {
            sys.update(model: model, deltaTime: 1.0 / 60.0)
            sys.waitForPendingFrame()
        }

        // Inject distinctive live curr/prev velocity into surviving host chain tip (bone 2)
        let buffersBefore = try XCTUnwrap(model.springBoneBuffers)
        let currPtrBefore = try XCTUnwrap(buffersBefore.bonePosCurr).contents()
            .bindMemory(to: SIMD3<Float>.self, capacity: buffersBefore.numBones)
        let prevPtrBefore = try XCTUnwrap(buffersBefore.bonePosPrev).contents()
            .bindMemory(to: SIMD3<Float>.self, capacity: buffersBefore.numBones)
        let distinctCurr = SIMD3<Float>(0.37, 1.12, -0.21)
        let distinctPrev = SIMD3<Float>(0.34, 1.13, -0.20)
        currPtrBefore[2] = distinctCurr
        prevPtrBefore[2] = distinctPrev

        // Attach a new physics cosmetic (bumps springBoneRevision & physicsRevision)
        let tail = makeSpringBoneCosmeticAsset(name: "Tail")
        _ = try model.attach(tail, to: .hips)

        // Trigger ensureTargetCaptureCaches BEFORE rebuildSpringBoneData (e.g., warmup/update outside drawCore)
        sys.update(model: model, deltaTime: 1.0 / 60.0)
        sys.waitForPendingFrame()

        // activeLayout MUST still match the currently allocated 3-bone host GPU buffers
        XCTAssertEqual(sys.activeLayout?.totalBones, 3)

        // Capture live simulated tip position right before rebuild
        let preRebuildCurr = currPtrBefore[2]
        let preRebuildPrev = prevPtrBefore[2]

        // Now perform the dynamic rebuild; surviving host chain MUST retain continuity
        try sys.rebuildSpringBoneData(model: model, warmupNewChainSteps: 6)
        XCTAssertEqual(sys.activeLayout?.totalBones, 6)

        let buffersAfter = try XCTUnwrap(model.springBoneBuffers)
        XCTAssertEqual(buffersAfter.numBones, 6)
        let currPtrAfter = try XCTUnwrap(buffersAfter.bonePosCurr).contents()
            .bindMemory(to: SIMD3<Float>.self, capacity: buffersAfter.numBones)
        let prevPtrAfter = try XCTUnwrap(buffersAfter.bonePosPrev).contents()
            .bindMemory(to: SIMD3<Float>.self, capacity: buffersAfter.numBones)

        XCTAssertLessThan(simd_distance(currPtrAfter[2], preRebuildCurr), 1e-3,
            "Surviving host chain position must be preserved even when cache refresh ran before rebuild")
        XCTAssertLessThan(simd_distance(prevPtrAfter[2], preRebuildPrev), 1e-3,
            "Surviving host chain momentum must be preserved even when cache refresh ran before rebuild")
    }
}
