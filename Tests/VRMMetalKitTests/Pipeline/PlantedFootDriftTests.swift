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

/// C3's headline gate: a planted foot must hold its world-space position while
/// the stagger shove displaces the root. Before the S2→S3 re-solve the foot
/// slides by the full shove offset, because the root moved after the plant was
/// solved.
final class PlantedFootDriftTests: XCTestCase {

    @MainActor private func avatar(_ device: MTLDevice, index: Int) async throws
        -> CrowdFrameStepper.Avatar {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        var config = RendererConfig(); config.synchronousSpringBone = true
        let r = VRMRenderer(device: device, config: config)
        r.loadModel(model)
        for root in model.nodes where root.parent == nil {
            root.rotation = CrowdPlacement.facing(avatarIndex: index, avatarCount: 2)
        }
        model.updateNodeTransforms()
        return CrowdFrameStepper.Avatar(renderer: r, model: model, player: AnimationPlayer(), index: index)
    }

    @MainActor private func anklePositions(_ model: VRMModel) throws -> (SIMD3<Float>, SIMD3<Float>) {
        let humanoid = try XCTUnwrap(model.humanoid)
        let l = try XCTUnwrap(humanoid.getBoneNode(.leftFoot))
        let r = try XCTUnwrap(humanoid.getBoneNode(.rightFoot))
        return (model.nodes[l].worldPosition, model.nodes[r].worldPosition)
    }

    /// Drift threshold for the single-shot (`.walkCycle`) gate: a one-time 50 mm
    /// root shift, measured once immediately after re-solve. 5 mm sits comfortably
    /// above measured solver residual (~1 mm on this fixture) and an order of
    /// magnitude below the un-corrected 50 mm slide a foot with no re-solve would
    /// show.
    private static let driftThreshold: Float = 0.005

    /// Drift threshold for the crowd gate: CUMULATIVE drift from `target(_:)`
    /// (fixed for the whole planted interval — see the comment at the measurement
    /// site for why per-frame delta cannot fail here regardless of correctness).
    /// Measured solver residual on this fixture is ~0.9 mm; a foot silently
    /// tracking the root would accumulate ~2.3 mm per frame it is planted for
    /// (the shove's `velocityCap`-limited per-frame displacement), so even a
    /// handful of tracked frames clears this by an order of magnitude. Set at
    /// roughly 2× the measured residual, an order of magnitude below what one
    /// tracked frame alone would already produce.
    private static let crowdCumulativeDriftThreshold: Float = 0.002

    @MainActor func testPlantedFootHoldsWorldPositionUnderShove() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let a = try await avatar(device, index: 0)
        let b = try await avatar(device, index: 1)
        let driver = CrowdMotionDriver(startSep: 0.12, holdSep: 0.12,
                                       approachStart: 0.0, approachEnd: 0.01, holdEnd: 1.0, partEnd: 1.0)
        let stepper = CrowdFrameStepper(avatars: [a, b], driver: driver, group: nil, fps: 60,
                                        stagger: StaggerShoveParams())

        var maxDrift: Float = 0
        for f in 0..<60 {
            stepper.step(frameTime: Float(f) / 60.0)
            let controller = try XCTUnwrap(stepper.captureStepController(forAvatar: 0))
            let now = try anklePositions(a.model)
            // Compare against the controller's own OWN locked target, not the
            // previous frame's ankle position: `target(_:)` is fixed for the
            // whole planted interval, so this measures CUMULATIVE drift from
            // the plant, not a per-frame delta. Per-frame delta cannot fail
            // for a root-tracking foot, because the shove itself is
            // rate-limited to ≤2.3mm/frame (`StaggerShoveSolver.velocityCap`
            // = 0.14 m/s at 1/60s) — a foot that slides in lockstep with the
            // root would ALSO show ≤2.3mm/frame, indistinguishable from a
            // correctly-held foot's solver noise at a per-frame threshold.
            if case .planted = controller.phase(.left) {
                maxDrift = max(maxDrift, simd_length(now.0 - controller.target(.left)))
            }
            if case .planted = controller.phase(.right) {
                maxDrift = max(maxDrift, simd_length(now.1 - controller.target(.right)))
            }
        }

        XCTAssertLessThan(maxDrift, Self.crowdCumulativeDriftThreshold,
                          "a planted foot tracked the shoved root instead of holding its world pivot")
    }
}

extension PlantedFootDriftTests {
    /// `IKLayer` in `.walkCycle` mode locks a planted foot to an absolute
    /// world-space position via `FootContactDetector` — the same "hold the world
    /// pivot" contract `CaptureStepController` proves in the crowd gate above, just
    /// through `IKLayer`'s own leg solve instead. When a root displacement lands
    /// after the layer has solved (S3 running after S2), the locked foot must still
    /// hold its world position — that is what "limb IK is terminal" buys.
    ///
    /// This deliberately does not use `.idleGrounding`: that mode retargets each
    /// foot to `currentHipPosition + fixedHipOffset` on every call, so its target
    /// is mathematically defined relative to the hip and moves by construction
    /// whenever the hip does — no re-solve ordering can hold it fixed, so it is not
    /// a valid vehicle for this gate. `.walkCycle`'s target is `FootContactDetector`'s
    /// locked absolute position, which does not move with the hip; it is the correct
    /// analogue of the crowd path's `captureStepper`.
    @MainActor func testWalkCycleGroundedFootHoldsWorldPositionUnderRootShift() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let a = try await avatar(device, index: 0)

        let ik = IKLayer()
        ik.groundingMode = .walkCycle
        let ankleHeight = try anklePositions(a.model).0.y
        ik.contactConfig = FootContactDetector.Config(
            velocityThreshold: 0.05, heightThreshold: 0.5, minFramesInState: 3, groundY: ankleHeight)
        ik.initialize(with: a.model)

        var avatarState = PipelineAvatar(index: 0, model: a.model, player: a.player,
                                         baseTranslations: [:])
        avatarState.ikLayer = ik
        avatarState.footTargetSource = DetectorFootTargetSource()
        let snapshot = FrozenSnapshot(torsos: [:], indices: [0])
        let dt: Float = 1.0 / 60.0

        PoseStage.sample(avatar: &avatarState, partners: snapshot, dt: dt)
        // Stationary warm-up so the detector's hysteresis (minFramesInState: 3)
        // locks a plant before the root shift lands.
        for _ in 0..<5 {
            PoseStage.limbSolve(avatar: &avatarState, partners: snapshot, dt: dt)
        }
        let before = try anklePositions(a.model)

        for root in a.model.nodes where root.parent == nil {
            root.translation.x += 0.05
        }
        a.model.updateNodeTransforms()
        PoseStage.limbSolve(avatar: &avatarState, partners: snapshot, dt: dt)
        let after = try anklePositions(a.model)

        XCTAssertLessThan(simd_length(after.0 - before.0), Self.driftThreshold,
                          "left foot tracked the displaced root instead of re-solving to its world target")
    }
}
