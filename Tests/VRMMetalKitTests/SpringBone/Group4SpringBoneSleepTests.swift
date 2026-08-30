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

/// Group 4: honest sleep velocities, per-chain skip, targeted wake.
/// Sleep stays off on the sync path; CCD scoping is unchanged.
final class Group4SpringBoneSleepTests: XCTestCase {

    private let ranges: [Range<Int>] = [0..<3, 3..<6]
    private let threshold: Float = 0.001
    private let delay = 5

    func testVelocitiesComeFromCompletedSnapshots() {
        let curr: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(0, 0.01, 0), SIMD3(0, 0.02, 0),
            SIMD3(1, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 0, 0)
        ]
        let prev: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(0, 0, 0),
            SIMD3(1, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 0, 0)
        ]
        let invDt: Float = 120
        let v = SpringBoneSleepGate.chainMaxVelocities(
            curr: curr, prev: prev, ranges: ranges, invDt: invDt)
        XCTAssertEqual(v.count, 2)
        XCTAssertEqual(v[0], 0.02 * invDt, accuracy: 1e-4)
        XCTAssertEqual(v[1], 0, accuracy: 1e-6)
    }

    func testMissingSnapshotStaysAwake() {
        let v = SpringBoneSleepGate.chainMaxVelocities(
            curr: [], prev: [], ranges: ranges, invDt: 120)
        XCTAssertEqual(v, [Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude])
    }

    func testStillChainSleepsAfterDelayWithoutWakingSibling() {
        var gate = SpringBoneSleepGate(chainCount: 2)
        let still = [Float](repeating: 0, count: 2)
        let noWake = [false, false]
        for _ in 0..<delay {
            gate.apply(velocities: still, wakeMask: noWake, ranges: ranges,
                       threshold: threshold, delay: delay)
        }
        XCTAssertTrue(gate.asleep[0])
        XCTAssertTrue(gate.asleep[1])
        XCTAssertEqual(gate.sleepingBoneCount, 6)

        // Chain 0 starts moving; chain 1 stays still and must remain asleep.
        gate.apply(velocities: [1.0, 0], wakeMask: [true, false], ranges: ranges,
                   threshold: threshold, delay: delay)
        XCTAssertFalse(gate.asleep[0])
        XCTAssertTrue(gate.asleep[1])
        XCTAssertEqual(gate.sleepingBoneCount, 3)
    }

    func testGlobalWakeWakesEveryChain() {
        var gate = SpringBoneSleepGate(chainCount: 2)
        for _ in 0..<delay {
            gate.apply(velocities: [0, 0], wakeMask: [false, false],
                       ranges: ranges, threshold: threshold, delay: delay)
        }
        let mask = SpringBoneSleepGate.wakeMask(
            chainCount: 2,
            globalWake: true,
            movedRootIndices: [],
            movedColliderMasks: [],
            chainColliderMasks: [0b001, 0b010]
        )
        XCTAssertEqual(mask, [true, true])
        gate.apply(velocities: [0, 0], wakeMask: mask, ranges: ranges,
                   threshold: threshold, delay: delay)
        XCTAssertFalse(gate.asleep[0])
        XCTAssertFalse(gate.asleep[1])
        XCTAssertEqual(gate.sleepingBoneCount, 0)
    }

    func testColliderMotionWakesOnlyIntersectingChains() {
        let mask = SpringBoneSleepGate.wakeMask(
            chainCount: 3,
            globalWake: false,
            movedRootIndices: [],
            movedColliderMasks: [0b010],
            chainColliderMasks: [0b001, 0b010, 0b100]
        )
        XCTAssertEqual(mask, [false, true, false])
    }

    func testRootMotionWakesOnlyThatChain() {
        let mask = SpringBoneSleepGate.wakeMask(
            chainCount: 3,
            globalWake: false,
            movedRootIndices: [2],
            movedColliderMasks: [],
            chainColliderMasks: [0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF]
        )
        XCTAssertEqual(mask, [false, false, true])
    }

    @MainActor
    func testAsyncRootMotionWakesOnlyMovedChain() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let path = getTestVRM10ModelPath()
        try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        model.updateNodeTransforms()
        try model.initializeSpringBoneGPUSystem(device: device)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)
        model.springBoneGlobalParams?.settlingFrames = 0
        XCTAssertGreaterThan(system.testChainAsleep.count, 1, "fixture needs multiple spring chains")

        let queue = device.makeCommandQueue()!
        func stepAsync() {
            let cb = queue.makeCommandBuffer()!
            system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: cb)
            cb.commit()
            cb.waitUntilCompleted()
        }
        var asleepIndices: [Int] = []
        for _ in 0..<120 {
            stepAsync()
            asleepIndices = system.testChainAsleep.enumerated().compactMap { $0.element ? $0.offset : nil }
            if asleepIndices.count >= 2 { break }
        }
        XCTAssertGreaterThanOrEqual(asleepIndices.count, 2,
                                    "async rest should sleep at least two chains")

        let target = asleepIndices[0]
        let sibling = asleepIndices[1]
        let springs = try XCTUnwrap(model.springBone?.springs)
        XCTAssertLessThan(target, springs.count)
        let rootNodeIndex = try XCTUnwrap(springs[target].joints.first?.node)
        model.nodes[rootNodeIndex].translation += SIMD3<Float>(0, 0.05, 0)
        model.nodes[rootNodeIndex].updateLocalMatrix()
        model.updateNodeTransforms()
        stepAsync()

        XCTAssertFalse(system.testChainAsleep[target],
                       "moved root must wake its own chain (\(target))")
        XCTAssertTrue(system.testChainAsleep[sibling],
                      "sibling chain \(sibling) must stay asleep when only chain \(target)'s root moved")
    }

    func testForeignGroupMaskWakesChainsThatIncludeIt() {
        let foreignBit: UInt32 = 1 << 5
        let mask = SpringBoneSleepGate.wakeMask(
            chainCount: 2,
            globalWake: false,
            movedRootIndices: [],
            movedColliderMasks: [foreignBit],
            chainColliderMasks: [foreignBit | 0b1, 0b1]
        )
        XCTAssertEqual(mask, [true, false])
    }

    /// Hosts A/B the async sleep gate by shortening the settle delay.
    @MainActor
    func testHostSettableSleepDelayFramesTakesEffect() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let path = getTestVRM10ModelPath()
        try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        model.updateNodeTransforms()
        try model.initializeSpringBoneGPUSystem(device: device)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)
        model.springBoneGlobalParams?.settlingFrames = 0
        system.sleepDelayFrames = 1

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
        XCTAssertTrue(asleep, "sleepDelayFrames = 1 must still allow a still chain to sleep")
    }

    /// `sleepThreshold = 0` disables velocity-based sleep so A/B can pin the gate off.
    @MainActor
    func testZeroSleepThresholdNeverSleepsFromVelocity() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let path = getTestVRM10ModelPath()
        try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        model.updateNodeTransforms()
        try model.initializeSpringBoneGPUSystem(device: device)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)
        model.springBoneGlobalParams?.settlingFrames = 0
        system.sleepThreshold = 0

        let queue = device.makeCommandQueue()!
        func stepAsync() {
            let cb = queue.makeCommandBuffer()!
            system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: cb)
            cb.commit()
            cb.waitUntilCompleted()
        }
        for _ in 0..<80 { stepAsync() }
        XCTAssertEqual(system.sleepingBoneCount, 0,
                       "sleepThreshold = 0 must not sleep from velocity (A/B off-switch)")
    }

    /// VRMRenderer is the public seam for the same knobs.
    func testRendererForwardsSleepGateKnobs() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let renderer = VRMRenderer(device: device)
        XCTAssertEqual(renderer.springBoneSleepThreshold, 0.001, accuracy: 1e-8)
        XCTAssertEqual(renderer.springBoneSleepDelayFrames, 5)
        renderer.springBoneSleepThreshold = 0.01
        renderer.springBoneSleepDelayFrames = 2
        XCTAssertEqual(renderer.springBoneSleepThreshold, 0.01, accuracy: 1e-8)
        XCTAssertEqual(renderer.springBoneSleepDelayFrames, 2)
        XCTAssertEqual(renderer.springBoneComputeSystem?.sleepThreshold ?? -1, 0.01, accuracy: 1e-8)
        XCTAssertEqual(renderer.springBoneComputeSystem?.sleepDelayFrames, 2)
        renderer.springBoneSleepThreshold = -1
        renderer.springBoneSleepDelayFrames = 0
        XCTAssertEqual(renderer.springBoneSleepThreshold, 0, accuracy: 1e-8)
        XCTAssertEqual(renderer.springBoneSleepDelayFrames, 1)
    }

    /// #87 / #423: a chain that slept while resting on an authored collider must
    /// wake when that collider moves away. Foreign/external injection already
    /// has this coverage; authored leave-wake did not.
    @MainActor
    func testAsyncAuthoredColliderMotionWakesIntersectingChain() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let path = getTestVRM10ModelPath()
        try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        model.updateNodeTransforms()
        try model.initializeSpringBoneGPUSystem(device: device)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)
        model.springBoneGlobalParams?.settlingFrames = 0
        let springBone = try XCTUnwrap(model.springBone)
        XCTAssertFalse(springBone.colliders.isEmpty, "fixture needs authored colliders")

        let queue = device.makeCommandQueue()!
        func stepAsync() {
            let cb = queue.makeCommandBuffer()!
            system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: cb)
            cb.commit()
            cb.waitUntilCompleted()
        }
        var asleepIndices: [Int] = []
        for _ in 0..<120 {
            stepAsync()
            asleepIndices = system.testChainAsleep.enumerated().compactMap { $0.element ? $0.offset : nil }
            if !asleepIndices.isEmpty { break }
        }
        XCTAssertFalse(asleepIndices.isEmpty, "async rest should sleep at least one chain")

        let nonEmptySprings = springBone.springs.filter { !$0.joints.isEmpty }
        func groupMask(forColliderIndex colliderIndex: Int) -> UInt32 {
            var mask: UInt32 = 0
            for (groupIndex, group) in springBone.colliderGroups.enumerated() {
                if group.colliders.contains(colliderIndex) {
                    mask |= 1 << min(groupIndex, 31)
                }
            }
            return mask == 0 ? 1 : mask
        }

        var movedChain: Int?
        for chain in asleepIndices {
            guard chain < system.testChainColliderMasks.count, chain < nonEmptySprings.count else { continue }
            let chainMask = system.testChainColliderMasks[chain]
            let rootNode = nonEmptySprings[chain].joints.first?.node
            for (colliderIndex, collider) in springBone.colliders.enumerated() {
                let colliderMask = groupMask(forColliderIndex: colliderIndex)
                guard colliderMask & chainMask != 0 else { continue }
                guard collider.node != rootNode else { continue }
                guard let node = model.nodes[safe: collider.node] else { continue }
                node.translation += SIMD3<Float>(0, 0.05, 0)
                node.updateLocalMatrix()
                model.updateNodeTransforms()
                movedChain = chain
                break
            }
            if movedChain != nil { break }
        }
        let chain = try XCTUnwrap(movedChain,
            "need a sleeping chain whose collider-group mask intersects an authored collider on a different node")

        stepAsync()
        XCTAssertFalse(system.testChainAsleep[chain],
                       "moved authored collider must wake intersecting chain \(chain)")
    }
}
