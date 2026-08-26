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
import simd
@testable import VRMMetalKit

/// Sleep-gate wake conditions under SLOW motion, on the async
/// (shared-command-buffer) path where the gate is live.
///
/// Fixture: `springbone_collider_capsule_x0p02_r0p1` — one 4-joint chain
/// hanging from the head, resting against a head capsule (offset x=0.02,
/// r=0.1) that pushes it sideways. The chain settles pressed against the
/// collider, falls asleep, and the tests then move either the collider or
/// the chain root and check that the chain wakes.
///
/// The wake check compares root/collider transforms against per-chain
/// ANCHORS taken when the chain fell asleep, so motion slower than
/// `sleepThreshold` per frame still accumulates. Diffing against last frame
/// instead would never wake a chain under a slow head turn — a hair root
/// moves a fraction of a millimetre per frame at 90 Hz, well under 0.001
/// units — and the chain would hold its last local pose (`writeBonesToNodes`
/// skips sleeping chains) until something faster happened.
final class SpringBoneSleepDriftWakeTests: XCTestCase {

    private struct Harness {
        let model: VRMModel
        let system: SpringBoneComputeSystem
        let queue: MTLCommandQueue
        let rootNode: Int
        let tailNode: Int

        func step(dt: TimeInterval = 1.0 / 60.0) {
            let cb = queue.makeCommandBuffer()!
            system.update(model: model, deltaTime: dt, commandBuffer: cb)
            cb.commit()
            cb.waitUntilCompleted()
            // Same order as VRMRenderer: the completed frame's snapshot is
            // applied to the nodes after the GPU is done.
            system.writeBonesToNodes(model: model)
            model.updateNodeTransforms()
        }

        var asleep: Bool { system.testChainAsleep.first ?? false }
        var rootX: Float { model.nodes[rootNode].worldPosition.x }

        /// GPU-side joint positions (`bonePosCurr`); safe to read because
        /// `step()` waits for the frame. Chain joints occupy slots 0..<4.
        var gpuPositions: [SIMD3<Float>] {
            guard let buffers = model.springBoneBuffers,
                  let curr = buffers.bonePosCurr, buffers.numBones > 0 else { return [] }
            let ptr = curr.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
            return (0..<buffers.numBones).map { ptr[$0] }
        }
        /// Sideways displacement of the chain's tail from its root, GPU truth.
        var tailOffsetX: Float {
            let p = gpuPositions
            guard let first = p.first, let last = p.last else { return .nan }
            return last.x - first.x
        }

        /// Shifts the (single) capsule collider's authored offset. The compute
        /// system re-derives collider world transforms from `model.springBone`
        /// every frame, so this moves the capsule without touching any node.
        func shiftCapsule(by delta: SIMD3<Float>) throws {
            guard case .capsule(let offset, let radius, let tail)? =
                    model.springBone?.colliders.first?.shape else {
                throw XCTSkip("fixture collider is not a capsule")
            }
            model.springBone?.colliders[0].shape =
                .capsule(offset: offset + delta, radius: radius, tail: tail)
        }

        func shiftRoot(by delta: SIMD3<Float>) {
            model.nodes[rootNode].translation += delta
            model.nodes[rootNode].updateLocalMatrix()
            model.updateNodeTransforms()
        }
    }

    /// Loads the fixture, runs the async path until the chain is asleep and
    /// resting against the capsule.
    private func settledHarness() async throws -> Harness {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device")
        }
        guard let url = Bundle.module.url(
            forResource: "springbone_collider_capsule_x0p02_r0p1",
            withExtension: "vrm",
            subdirectory: "TestData/Conformance"
        ) else {
            throw XCTSkip("springbone_collider_capsule_x0p02_r0p1.vrm not bundled")
        }
        let model = try await VRMModel.load(from: url, device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()
        try model.initializeSpringBoneGPUSystem(device: device)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)
        model.springBoneGlobalParams?.settlingFrames = 0

        let springs = try XCTUnwrap(model.springBone?.springs)
        XCTAssertEqual(springs.count, 1, "fixture has one chain")
        XCTAssertEqual(system.testChainAsleep.count, 1)
        let joints = springs[0].joints
        let harness = Harness(model: model, system: system,
                              queue: device.makeCommandQueue()!,
                              rootNode: try XCTUnwrap(joints.first?.node),
                              tailNode: try XCTUnwrap(joints.last?.node))

        var frames = 0
        while !harness.asleep && frames < 600 {
            harness.step()
            frames += 1
        }
        XCTAssertTrue(harness.asleep, "chain should settle and sleep within 600 frames")

        // Precondition for every test here: the chain is asleep while PRESSED
        // AGAINST the capsule (pushed sideways off the vertical), not hanging
        // free. Capsule axis at x=0.02, r=0.1, joint hitRadius 0.02 → the
        // contacting joints sit ~0.1 to the -x side of the root.
        XCTAssertLessThan(harness.tailOffsetX, -0.05,
            "chain should be resting against the capsule before the test starts " +
            "(tail x - root x = \(harness.tailOffsetX))")
        return harness
    }

    /// Settle a chain onto the capsule, sleep, move the capsule away in ONE
    /// step: the chain wakes, falls back toward vertical, and — the anchor
    /// having been refreshed by that wake — settles and sleeps AGAIN.
    func testColliderJumpingAwayWakesSettledChainWhichThenFalls() async throws {
        let h = try await settledHarness()
        let pressedX = h.tailOffsetX

        try h.shiftCapsule(by: SIMD3<Float>(0.5, 0, 0))
        h.step()
        XCTAssertFalse(h.asleep, "capsule moved 0.5 in one frame: chain must wake")

        for _ in 0..<180 { h.step() }
        let freeX = h.tailOffsetX
        XCTAssertGreaterThan(abs(pressedX) - abs(freeX), 0.03,
            "with the capsule gone the chain should swing back toward vertical " +
            "(pressed \(pressedX), now \(freeX))")
        XCTAssertTrue(h.asleep,
            "a collider that moved once and stopped must not keep the chain awake: " +
            "the wake anchor is refreshed when the collider is seen to move")
    }

    /// Same scenario, but the capsule DRIFTS away at a QUARTER of the per-frame
    /// wake threshold for 600 frames — 150× the threshold in total. The chain is left hanging in mid-air where
    /// the capsule used to be; it must not still be asleep.
    func testColliderDriftingAwayWakesSettledChain() async throws {
        let h = try await settledHarness()
        let perFrame = h.system.testWakeMotionThreshold * 0.25
        let frames = 600   // total travel = 150× the wake threshold
        var wokeAtFrame: Int? = nil
        for frame in 0..<frames {
            try h.shiftCapsule(by: SIMD3<Float>(perFrame, 0, 0))
            h.step()
            if !h.asleep { wokeAtFrame = frame; break }
        }
        XCTAssertNotNil(wokeAtFrame,
            "capsule drifted \(perFrame * Float(frames)) units (150× the wake threshold " +
            "\(h.system.testWakeMotionThreshold)) out from under a sleeping chain and the chain " +
            "never woke: the collider wake anchor is not accumulating slow motion")
    }

    /// The chain's ROOT drifts at a quarter of the per-frame wake threshold for
    /// 600 frames (150× the threshold in total) while the capsule stays put. While asleep the kinematic kernel does not run
    /// and `writeBonesToNodes` skips the chain, so its joints keep their last
    /// local pose — the "hair held a bent pose while the head moved" symptom.
    func testRootDriftingWakesSettledChain() async throws {
        let h = try await settledHarness()
        let startRootX = h.rootX
        let perFrame = h.system.testWakeMotionThreshold * 0.25
        var wokeAtFrame: Int? = nil
        for frame in 0..<600 {
            h.shiftRoot(by: SIMD3<Float>(perFrame, 0, 0))
            h.step()
            if !h.asleep { wokeAtFrame = frame; break }
        }
        XCTAssertNotNil(wokeAtFrame,
            "root travelled \(h.rootX - startRootX) units (150× the wake threshold " +
            "\(h.system.testWakeMotionThreshold)) and the chain never woke: the root wake " +
            "anchor is not accumulating slow motion")
    }
}
