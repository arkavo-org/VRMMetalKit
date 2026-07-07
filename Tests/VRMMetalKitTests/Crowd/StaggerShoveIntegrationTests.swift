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

/// Crowd-wiring gates for the stagger shove (design 2026-07-07 §6.2/§6.3):
/// G7 (disabled/dormant is a byte-identical no-op), contact-onset activation,
/// and — appended in the integration-gate task — G5/G6 (residual contraction on
/// the real rig, with the over-capacity escape counter-case).
final class StaggerShoveIntegrationTests: XCTestCase {
    @MainActor private func avatar(_ device: MTLDevice, index: Int) async throws -> CrowdFrameStepper.Avatar {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        var config = RendererConfig(); config.synchronousSpringBone = true
        let r = VRMRenderer(device: device, config: config)
        r.loadModel(model)
        let player = AnimationPlayer()
        for root in model.nodes where root.parent == nil {
            root.rotation = CrowdPlacement.facing(avatarIndex: index, avatarCount: 2)
        }
        model.updateNodeTransforms()
        return CrowdFrameStepper.Avatar(renderer: r, model: model, player: player, index: index)
    }

    /// Hold-only driver: constant half-separation for the whole run — zero
    /// scripted root motion, so the shove is the only root disturbance
    /// (design §6.2 fixture constraint (a)).
    private func holdOnlyDriver(halfSep: Float) -> CrowdMotionDriver {
        CrowdMotionDriver(startSep: halfSep, holdSep: halfSep,
                          approachStart: 0.0, approachEnd: 0.01, holdEnd: 1.0, partEnd: 1.0)
    }

    /// Leg-bone rotations + root translations — the exact state the stagger path
    /// writes (controller writes hips/knees via IK; the shove writes roots).
    @MainActor private func legAndRootState(_ model: VRMModel) throws -> [SIMD4<Float>] {
        let humanoid = try XCTUnwrap(model.humanoid)
        var out: [SIMD4<Float>] = []
        for bone: VRMHumanoidBone in [.leftUpperLeg, .leftLowerLeg, .rightUpperLeg, .rightLowerLeg] {
            let idx = try XCTUnwrap(humanoid.getBoneNode(bone))
            out.append(model.nodes[idx].rotation.vector)
        }
        for root in model.nodes where root.parent == nil {
            out.append(SIMD4<Float>(root.translation, 0))
        }
        return out
    }

    /// G7 — disabled is a no-op, and enabled-but-never-in-contact is byte-identical
    /// to disabled (the dormant gating): far-separated avatars stepped 60 frames
    /// with `stagger: nil` vs with stagger enabled produce exactly equal leg-bone
    /// rotations and root translations, and the enabled run's solver never leaves
    /// zero. This is the opt-in guarantee — existing renders are unaffected.
    @MainActor func testG7_disabledAndDormantAreByteIdenticalNoOp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }

        func run(stagger: StaggerShoveParams?) async throws -> (states: [[SIMD4<Float>]], stepper: CrowdFrameStepper, model: VRMModel) {
            let a = try await avatar(device, index: 0)
            let b = try await avatar(device, index: 1)
            let stepper = CrowdFrameStepper(avatars: [a, b], driver: holdOnlyDriver(halfSep: 1.0),
                                            group: nil, fps: 60, stagger: stagger)
            var states: [[SIMD4<Float>]] = []
            for f in 0..<60 {
                stepper.step(frameTime: Float(f) / 60.0)
                states.append(try legAndRootState(a.model))
            }
            return (states, stepper, a.model)
        }

        let disabled = try await run(stagger: nil)
        XCTAssertNil(disabled.stepper.staggerSolver(forAvatar: 0), "stagger nil ⇒ no solver")
        XCTAssertNil(disabled.stepper.captureStepController(forAvatar: 0), "stagger nil ⇒ no controller")

        let dormant = try await run(stagger: StaggerShoveParams())
        let solver = try XCTUnwrap(dormant.stepper.staggerSolver(forAvatar: 0))
        XCTAssertEqual(solver.offset, .zero, "no contact ⇒ solver never activated")

        XCTAssertEqual(disabled.states.count, dormant.states.count)
        for f in disabled.states.indices {
            XCTAssertEqual(disabled.states[f], dormant.states[f],
                           "frame \(f): dormant stagger must be byte-identical to stagger-off")
        }
    }

    /// Activation — contact onset: at deep constant overlap the channel activates,
    /// the offset grows away from the partner (avatar 0 sits at −X, partner at +X,
    /// so its push direction is −X), and the controller exists and has been run
    /// (it seeds itself on its first update, so both feet report planted).
    @MainActor func testActivation_onsetAtFirstContact_offsetGrowsAwayFromPartner() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let a = try await avatar(device, index: 0)
        let b = try await avatar(device, index: 1)
        let stepper = CrowdFrameStepper(avatars: [a, b], driver: holdOnlyDriver(halfSep: 0.05),
                                        group: nil, fps: 60, stagger: StaggerShoveParams())
        for f in 0..<30 { stepper.step(frameTime: Float(f) / 60.0) }
        let solver = try XCTUnwrap(stepper.staggerSolver(forAvatar: 0))
        XCTAssertGreaterThan(simd_length(solver.offset), 0.02, "offset built up after contact onset")
        XCTAssertLessThan(solver.offset.x, 0, "avatar 0 is shoved away from the +X partner")
        XCTAssertNotNil(stepper.captureStepController(forAvatar: 0), "controller wired per avatar")
    }
}
