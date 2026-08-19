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
}
