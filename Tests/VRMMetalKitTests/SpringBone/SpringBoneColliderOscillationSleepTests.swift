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

/// Sub-threshold collider motion against the sleep gate's frozen collider
/// anchors, on a full avatar where some chains sleep while others may not.
///
/// Collider wake anchors refresh every frame only while NO chain sleeps;
/// once any chain is asleep they hold their pose until a collider is seen to
/// cross the wake threshold, and only that collider's anchor is then moved.
/// A collider oscillating at half the threshold per frame therefore cannot
/// pin the mask-intersecting chains awake: the wake check is
/// `distance(current, anchor) > threshold`, so an oscillation that stays
/// within half a threshold of the anchor never fires, and an anchor refreshed
/// on a crossing frame holds THAT frame's pose, so a subsequent half-threshold
/// alternation around it never fires either. Only net displacement beyond the
/// threshold (a drift) wakes, and it wakes exactly the intersecting chains.
///
/// Fixture: `AvatarSample_U_1.0.vrm.glb` (authored colliders only). The
/// oscillated collider is the first UpperChest sphere: its group is referenced
/// by the hair chains, and the no-group chains (bust, sleeve, coat, cat) carry
/// the all-groups mask, while the skirt chains reference only the leg groups.
/// Displacing it by tens of thresholds moves no resting joint measurably, so
/// wake behaviour here is the anchor policy alone, not contact physics.
final class SpringBoneColliderOscillationSleepTests: XCTestCase {

    private struct Harness {
        let model: VRMModel
        let system: SpringBoneComputeSystem
        let queue: MTLCommandQueue
        /// Authored collider being moved, and its slot in the sphere upload order.
        let colliderIndex: Int
        let sphereSlot: Int
        let baseOffset: SIMD3<Float>
        let radius: Float
        let worldRotation: simd_float3x3
        let nodeWorldPosition: SIMD3<Float>
        /// Chains asleep at baseline whose mask intersects the collider's group.
        let intersecting: [Int]
        /// Chains asleep at baseline whose mask does NOT intersect it.
        let disjoint: [Int]
        let baselineSleepingBones: Int

        var threshold: Float { system.wakeMotionThreshold }
        var delay: Int { system.sleepDelayFrames }

        func step() {
            let cb = queue.makeCommandBuffer()!
            system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: cb)
            cb.commit()
            cb.waitUntilCompleted()
            system.writeBonesToNodes(model: model)
            model.updateNodeTransforms()
        }

        /// Places the collider `worldDelta` away from its authored pose. The
        /// authored offset is rotated by the node's world rotation on upload,
        /// so the delta is mapped back into node space here.
        func placeCollider(worldDelta: SIMD3<Float>) {
            let localDelta = worldRotation.inverse * worldDelta
            model.springBone?.colliders[colliderIndex].shape =
                .sphere(offset: baseOffset + localDelta, radius: radius)
        }

        func expectedWorldCenter(worldDelta: SIMD3<Float>) -> SIMD3<Float> {
            nodeWorldPosition + worldRotation * baseOffset + worldDelta
        }

        var anchorCenter: SIMD3<Float> { system.testSphereWakeAnchors[sphereSlot].center }

        func awake(in chains: [Int]) -> [Int] {
            let asleep = system.testChainAsleep
            return chains.filter { !asleep[$0] }
        }

        /// Steps until every chain in `chains` is asleep; returns the frame
        /// count, or nil when `budget` frames were not enough.
        func framesUntilAsleep(_ chains: [Int], budget: Int) -> Int? {
            for frame in 0..<budget {
                step()
                if awake(in: chains).isEmpty { return frame + 1 }
            }
            return nil
        }
    }

    /// Chains that never settle on this fixture are excluded from both sets;
    /// they keep `anyAsleep` semantics honest (the anchors freeze as soon as
    /// ANY chain sleeps) without adding assertions the fixture cannot meet.
    private func settledHarness() async throws -> Harness {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device")
        }
        let path = getTestModelPath("AvatarSample_U_1.0.vrm.glb")
        try requireFixture(path, hint: "AvatarSample_U_1.0.vrm.glb")
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()
        try model.initializeSpringBoneGPUSystem(device: device)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)
        model.springBoneGlobalParams?.settlingFrames = 0

        let springBone = try XCTUnwrap(model.springBone)
        let colliderIndex = try XCTUnwrap(springBone.colliders.firstIndex { collider in
            guard case .sphere = collider.shape else { return false }
            return model.nodes[collider.node].name == "J_Bip_C_UpperChest"
        }, "fixture should author a sphere collider on J_Bip_C_UpperChest")
        guard case .sphere(let baseOffset, let radius) = springBone.colliders[colliderIndex].shape else {
            throw XCTSkip("collider is not a sphere")
        }
        let sphereSlot = springBone.colliders[..<colliderIndex].filter {
            if case .sphere = $0.shape { return true }
            if case .insideSphere = $0.shape { return true }
            return false
        }.count
        let node = model.nodes[springBone.colliders[colliderIndex].node]
        let wm = node.worldMatrix
        let worldRotation = simd_float3x3(
            SIMD3<Float>(wm[0][0], wm[0][1], wm[0][2]),
            SIMD3<Float>(wm[1][0], wm[1][1], wm[1][2]),
            SIMD3<Float>(wm[2][0], wm[2][1], wm[2][2]))
        let colliderGroupMask: UInt32 = springBone.colliderGroups.enumerated().reduce(0) { mask, entry in
            entry.element.colliders.contains(colliderIndex) ? mask | (1 << UInt32(min(entry.offset, 31))) : mask
        }
        XCTAssertNotEqual(colliderGroupMask, 0, "the UpperChest sphere should belong to a collider group")

        let queue = device.makeCommandQueue()!
        let harness = Harness(model: model, system: system, queue: queue,
                              colliderIndex: colliderIndex, sphereSlot: sphereSlot,
                              baseOffset: baseOffset, radius: radius,
                              worldRotation: worldRotation, nodeWorldPosition: node.worldPosition,
                              intersecting: [], disjoint: [], baselineSleepingBones: 0)

        // Settle until the sleeping set has been stable for 120 frames.
        var sleepingChains = 0
        var lastChange = 0
        for frame in 0..<900 {
            harness.step()
            let now = system.testChainAsleep.filter { $0 }.count
            if now != sleepingChains { sleepingChains = now; lastChange = frame }
            if frame - lastChange >= 120 { break }
        }
        let asleep = system.testChainAsleep
        let masks = system.testChainColliderMasks
        XCTAssertEqual(asleep.count, masks.count)
        let settled = asleep.indices.filter { asleep[$0] }
        let intersecting = settled.filter { masks[$0] & colliderGroupMask != 0 }
        let disjoint = settled.filter { masks[$0] & colliderGroupMask == 0 }
        XCTAssertFalse(intersecting.isEmpty, "no settled chain collides with the UpperChest sphere")
        XCTAssertFalse(disjoint.isEmpty, "no settled chain is disjoint from the UpperChest sphere's group")
        XCTAssertGreaterThan(system.sleepingBoneCount, 0)
        XCTAssertEqual(harness.anchorCenter, harness.expectedWorldCenter(worldDelta: .zero),
            "the sphere anchor frozen at sleep time should be the authored world centre")

        return Harness(model: model, system: system, queue: queue,
                       colliderIndex: colliderIndex, sphereSlot: sphereSlot,
                       baseOffset: baseOffset, radius: radius,
                       worldRotation: worldRotation, nodeWorldPosition: node.worldPosition,
                       intersecting: intersecting, disjoint: disjoint,
                       baselineSleepingBones: system.sleepingBoneCount)
    }

    /// Alternates the collider between `origin` and `origin + amplitude`
    /// (one move per frame) for `frames` frames, asserting the disjoint set
    /// sleeps through it. Returns the frames on which some intersecting chain
    /// was awake.
    private func alternate(_ h: Harness, origin: SIMD3<Float>, amplitude: SIMD3<Float>,
                           frames: Int, label: String) -> [Int] {
        var awakeFrames: [Int] = []
        for frame in 0..<frames {
            let delta = frame % 2 == 0 ? origin + amplitude : origin
            h.placeCollider(worldDelta: delta)
            h.step()
            XCTAssertTrue(h.awake(in: h.disjoint).isEmpty,
                "\(label): frame \(frame): chains whose mask does not include the moving " +
                "collider's group must stay asleep; awake: \(h.awake(in: h.disjoint))")
            if !h.awake(in: h.intersecting).isEmpty { awakeFrames.append(frame) }
        }
        return awakeFrames
    }

    /// One-frame jump of the collider well past the threshold, then the
    /// collider holds still: measures the frames the intersecting chains take
    /// to sleep again, the budget the oscillation tests are held to.
    private func controlResleepFrames(_ h: Harness, jumpTo delta: SIMD3<Float>) throws -> Int {
        h.placeCollider(worldDelta: delta)
        h.step()
        XCTAssertEqual(h.awake(in: h.intersecting).count, h.intersecting.count,
            "a collider jump past the threshold must wake every chain whose mask includes its group")
        XCTAssertTrue(h.awake(in: h.disjoint).isEmpty,
            "a collider jump must not wake chains whose mask excludes its group")
        XCTAssertEqual(h.anchorCenter, h.expectedWorldCenter(worldDelta: delta),
            "the anchor refreshed on the crossing frame must hold the post-jump pose")
        let frames = try XCTUnwrap(h.framesUntilAsleep(h.intersecting, budget: 600),
            "a collider that jumped once and stopped must let the woken chains sleep again")
        XCTAssertEqual(h.anchorCenter, h.expectedWorldCenter(worldDelta: delta),
            "a collider holding still must not move its anchor while its chains settle")
        return frames
    }

    /// Everything asleep, one authored collider alternating ±half a threshold
    /// per frame: no chain wakes, the anchor never moves, and nothing changes
    /// once the collider stops.
    func testHalfThresholdAlternationUnderSleepingChainsWakesNothing() async throws {
        let h = try await settledHarness()
        let amplitude = SIMD3<Float>(0.5 * h.threshold, 0, 0)
        let anchorBefore = h.anchorCenter

        let awakeFrames = alternate(h, origin: .zero, amplitude: amplitude,
                                    frames: 3 * h.delay, label: "alternation")
        XCTAssertTrue(awakeFrames.isEmpty,
            "a collider alternating within half a wake threshold of its anchor never " +
            "crosses the threshold, so no chain should wake; intersecting chains were " +
            "awake on frames \(awakeFrames)")
        XCTAssertEqual(h.anchorCenter, anchorBefore,
            "sub-threshold motion must leave the frozen collider anchor untouched")
        XCTAssertGreaterThanOrEqual(h.system.sleepingBoneCount, h.baselineSleepingBones)

        h.placeCollider(worldDelta: .zero)
        for _ in 0..<(2 * h.delay) { h.step() }
        XCTAssertTrue(h.awake(in: h.intersecting + h.disjoint).isEmpty)
        XCTAssertGreaterThanOrEqual(h.system.sleepingBoneCount, h.baselineSleepingBones)
    }

    /// The stricter property: chains that are AWAKE while the collider
    /// alternates ±half a threshold per frame must still be able to settle
    /// and sleep, in about the time they take with the collider held still.
    func testHalfThresholdAlternationDoesNotPinWokenChainsAwake() async throws {
        let h = try await settledHarness()
        let jump = SIMD3<Float>(3 * h.threshold, 0, 0)
        let control = try controlResleepFrames(h, jumpTo: jump)

        // Jump back (crossing → wake, anchor refreshed to the authored pose),
        // then alternate around that pose while the chains try to settle.
        h.placeCollider(worldDelta: .zero)
        h.step()
        XCTAssertEqual(h.awake(in: h.intersecting).count, h.intersecting.count)
        let anchorAfterWake = h.anchorCenter
        XCTAssertEqual(anchorAfterWake, h.expectedWorldCenter(worldDelta: .zero))

        let amplitude = SIMD3<Float>(0.5 * h.threshold, 0, 0)
        let window = control + 4 * h.delay
        let awakeFrames = alternate(h, origin: .zero, amplitude: amplitude,
                                    frames: window, label: "alternation while settling")
        let firstAllAsleep = (0..<window).first { !awakeFrames.contains($0) }
        let sleptBy = try XCTUnwrap(firstAllAsleep,
            "chains woken by a collider jump never slept again while that collider " +
            "alternated ±0.5× the wake threshold per frame for \(window) frames " +
            "(control with the collider still: \(control) frames): the sub-threshold " +
            "oscillation is re-waking them")
        XCTAssertLessThanOrEqual(sleptBy + 1, control + 2 * h.delay,
            "chains settled on frame \(sleptBy + 1) under the oscillation versus " +
            "\(control) with the collider still; the oscillation is delaying sleep")
        XCTAssertTrue(awakeFrames.allSatisfy { $0 < sleptBy },
            "once asleep under the oscillation the chains must stay asleep; " +
            "re-wakes on frames \(awakeFrames.filter { $0 > sleptBy })")
        XCTAssertEqual(h.anchorCenter, anchorAfterWake,
            "the anchor refreshed on the wake frame must not move under sub-threshold alternation")
    }

    /// A monotone drift at half a threshold per frame is net motion: the
    /// anchor is crossed every few frames, so the intersecting chains stay
    /// awake for the drift's duration and no other chain wakes. Once the
    /// collider stops they sleep again within the still-collider budget.
    func testHalfThresholdRampWakesOnlyIntersectingChainsThenReleasesThem() async throws {
        let h = try await settledHarness()
        let control = try controlResleepFrames(h, jumpTo: SIMD3<Float>(3 * h.threshold, 0, 0))

        let perFrame = 0.5 * h.threshold
        var awakeFrames: [Int] = []
        let frames = 3 * h.delay
        var delta = SIMD3<Float>(3 * h.threshold, 0, 0)
        for frame in 0..<frames {
            delta.x += perFrame
            h.placeCollider(worldDelta: delta)
            h.step()
            XCTAssertTrue(h.awake(in: h.disjoint).isEmpty,
                "ramp: frame \(frame): chains whose mask excludes the drifting collider's " +
                "group must stay asleep; awake: \(h.awake(in: h.disjoint))")
            if !h.awake(in: h.intersecting).isEmpty { awakeFrames.append(frame) }
        }
        let firstWake = try XCTUnwrap(awakeFrames.first,
            "a collider drifting half a threshold per frame must wake the chains resting " +
            "on it once the accumulated drift crosses the threshold")
        XCTAssertLessThanOrEqual(firstWake, 3,
            "the accumulated drift exceeds the threshold by the third frame")
        XCTAssertLessThan(simd_distance(h.anchorCenter, h.expectedWorldCenter(worldDelta: delta)),
                          h.threshold + 1e-6,
            "the anchor must track a drifting collider to within one threshold")

        let resleep = try XCTUnwrap(h.framesUntilAsleep(h.intersecting, budget: control + 2 * h.delay),
            "once the drift stops the intersecting chains must sleep again within " +
            "\(control + 2 * h.delay) frames (still-collider control: \(control))")
        XCTAssertGreaterThan(resleep, 0)
        XCTAssertTrue(h.awake(in: h.disjoint).isEmpty)
    }
}
