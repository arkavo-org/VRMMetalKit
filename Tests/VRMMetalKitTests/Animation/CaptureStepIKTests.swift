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

final class CaptureStepIKTests: XCTestCase {
    @MainActor private func loadRig() async throws -> VRMModel {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()
        return model
    }

    @MainActor private func ankleWorld(_ model: VRMModel, _ foot: BalanceModel.Foot) throws -> SIMD3<Float> {
        let bone: VRMHumanoidBone = foot == .left ? .leftFoot : .rightFoot
        let idx = try XCTUnwrap(model.humanoid?.getBoneNode(bone))
        return model.nodes[idx].worldPosition
    }

    /// The IK-correctness gate (spec §2.1): the ankle lands at the world target within
    /// ε ACROSS a range of reachable targets — not right-at-one-point. ε (the measured
    /// worst-case error here) is Task 4's residual noise floor. Rig-only; no stepping.
    @MainActor func testPlaceAnkle_landsAtTargetAcrossRange() async throws {
        let model = try await loadRig()
        let c = CaptureStepController()
        let rest = try ankleWorld(model, .left)
        // Leg reach: the fixture's leg is near-fully-extended at rest, so targets that
        // move the ankle AWAY from the hip exceed reach and the solver clamps them (spec
        // §2.1 excludes clamped targets from ε). The reachable range is therefore targets
        // that BEND the knee — the ankle closer to the hip (raised) and lateral.
        let humanoid = try XCTUnwrap(model.humanoid)
        let hipIdx = try XCTUnwrap(humanoid.getBoneNode(.leftUpperLeg))
        let kneeIdx = try XCTUnwrap(humanoid.getBoneNode(.leftLowerLeg))
        let ankleIdx = try XCTUnwrap(humanoid.getBoneNode(.leftFoot))
        let hip = model.nodes[hipIdx].worldPosition
        let reach = simd_distance(hip, model.nodes[kneeIdx].worldPosition)
                  + simd_distance(model.nodes[kneeIdx].worldPosition, model.nodes[ankleIdx].worldPosition)
        let offsets: [SIMD3<Float>] = [
            SIMD3(0.06, 0.06, 0), SIMD3(-0.06, 0.06, 0), SIMD3(0, 0.06, 0.08), SIMD3(0, 0.05, -0.08),
            SIMD3(0.05, 0.10, 0.05), SIMD3(-0.05, 0.08, -0.05), SIMD3(0.08, 0.04, -0.06),
            SIMD3(0.02, 0.15, 0.02), SIMD3(-0.04, 0.12, 0.03),
        ]
        var worstError: Float = 0
        var reachableCount = 0
        for off in offsets {
            let target = rest + off
            // Exclude beyond-reach targets from ε (spec §2.1) — those are solver clamps,
            // not placement errors.
            guard simd_distance(target, hip) < reach - 0.002 else { continue }
            c.placeAnkle(.left, worldTarget: target, model: model)
            model.updateNodeTransforms()
            let landed = try ankleWorld(model, .left)
            worstError = max(worstError, simd_distance(landed, target))
            reachableCount += 1
        }
        // Range coverage (spec §2.1 / §0): the metric is direct-measurement, so its rigor
        // is coverage + a tight ε, not a failing counter-case. Enough reachable targets,
        // ankle essentially at target across all of them.
        XCTAssertGreaterThanOrEqual(reachableCount, 5, "enough reachable targets for range coverage")
        XCTAssertLessThan(worstError, 0.005, "worst-case placement error (ε) across the reachable range")
    }

    /// Restore-IK polygon gate (spec Redline 1): under a driven root the support-polygon
    /// corners at decision time match the controller's plantedPositions — proving the
    /// clip's skating leg positions never reach BalanceModel.evaluate.
    @MainActor func testUpdate_supportPolygonMatchesPlantedPositions_underDrivenRoot() async throws {
        let model = try await loadRig()
        let c = CaptureStepController()
        // First update seeds from the rig.
        c.update(deltaTime: 1.0 / 60.0, model: model)
        // Drive the root laterally (the moonwalk disturbance), approaching and holding —
        // this fixture's leg is at essentially zero reach-slack in its rest pose (measured
        // rawReach ≈ maxReach), so an UNBOUNDED lateral drift would eventually force the
        // still-planted foot beyond physical leg reach regardless of controller
        // correctness (2a allows only one foot to swing at a time, and a swing needs
        // `swingDuration` to land). Capping the approach lets the triggered step complete
        // within the run, which is what this gate is actually about.
        for f in 1...30 {
            for root in model.nodes where root.parent == nil {
                root.translation.x = min(0.01 * Float(f), 0.09)      // slow scripted approach, then hold
            }
            model.updateNodeTransforms()
            c.update(deltaTime: 1.0 / 60.0, model: model)
        }
        // The polygon BalanceModel would build from the rig's planted feet must equal
        // the controller's stored planted positions (within IK ε), i.e. no skate leaked in.
        // Compare each planted foot's rig world position to the controller's stored one.
        for foot in [BalanceModel.Foot.left, .right] where c.plantedFeet.contains(foot) {
            let boneIdx = try XCTUnwrap(model.humanoid?.getBoneNode(foot == .left ? .leftFoot : .rightFoot))
            let rig = model.nodes[boneIdx].worldPosition
            let stored = c.target(foot)
            XCTAssertLessThan(simd_distance(rig, stored), 0.02,
                              "evaluate-time foot (\(foot)) reflects the controller, not the clip skate")
        }
    }

    @MainActor func testUpdate_disabledIsBitIdenticalNoOp() async throws {
        let model = try await loadRig()
        let hipsIdx = try XCTUnwrap(model.humanoid?.getBoneNode(.leftUpperLeg))
        let before = model.nodes[hipsIdx].rotation
        let c = CaptureStepController()
        c.isEnabled = false
        c.update(deltaTime: 1.0 / 60.0, model: model)
        XCTAssertEqual(model.nodes[hipsIdx].rotation, before, "disabled ⇒ leg bones untouched")
    }

    @MainActor func testUpdate_plantedFootHoldsThenSteps_underSlowApproach() async throws {
        let model = try await loadRig()
        let c = CaptureStepController()
        c.update(deltaTime: 1.0 / 60.0, model: model)
        let firstPlanted = c.plantedPositions().first
        var sawStep = false
        for f in 1...40 {
            for root in model.nodes where root.parent == nil { root.translation.x = 0.012 * Float(f) }
            model.updateNodeTransforms()
            c.update(deltaTime: 1.0 / 60.0, model: model)
            if c.plantedFeet.count == 1 { sawStep = true }   // a swing occurred
        }
        XCTAssertTrue(sawStep, "a step fired as the root dragged the CoM toward the support edge")
        XCTAssertNotNil(firstPlanted)
    }
}
