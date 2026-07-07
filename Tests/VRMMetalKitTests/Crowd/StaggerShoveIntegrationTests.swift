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
    /// Checked for BOTH avatars in the pair, not just avatar 0 — Phase 0e reads a
    /// partner snapshot, so a one-sided check could hide dormant-path drift that
    /// only shows up on the partner's side.
    @MainActor func testG7_disabledAndDormantAreByteIdenticalNoOp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }

        func run(stagger: StaggerShoveParams?) async throws
            -> (statesA: [[SIMD4<Float>]], statesB: [[SIMD4<Float>]], stepper: CrowdFrameStepper, model: VRMModel) {
            let a = try await avatar(device, index: 0)
            let b = try await avatar(device, index: 1)
            let stepper = CrowdFrameStepper(avatars: [a, b], driver: holdOnlyDriver(halfSep: 1.0),
                                            group: nil, fps: 60, stagger: stagger)
            var statesA: [[SIMD4<Float>]] = []
            var statesB: [[SIMD4<Float>]] = []
            for f in 0..<60 {
                stepper.step(frameTime: Float(f) / 60.0)
                statesA.append(try legAndRootState(a.model))
                statesB.append(try legAndRootState(b.model))
            }
            return (statesA, statesB, stepper, a.model)
        }

        let disabled = try await run(stagger: nil)
        XCTAssertNil(disabled.stepper.staggerSolver(forAvatar: 0), "stagger nil ⇒ no solver")
        XCTAssertNil(disabled.stepper.captureStepController(forAvatar: 0), "stagger nil ⇒ no controller")

        let dormant = try await run(stagger: StaggerShoveParams())
        let solver = try XCTUnwrap(dormant.stepper.staggerSolver(forAvatar: 0))
        XCTAssertEqual(solver.offset, .zero, "no contact ⇒ solver never activated")

        XCTAssertEqual(disabled.statesA.count, dormant.statesA.count)
        for f in disabled.statesA.indices {
            XCTAssertEqual(disabled.statesA[f], dormant.statesA[f],
                           "avatar 0, frame \(f): dormant stagger must be byte-identical to stagger-off")
        }
        XCTAssertEqual(disabled.statesB.count, dormant.statesB.count)
        for f in disabled.statesB.indices {
            XCTAssertEqual(disabled.statesB[f], dormant.statesB[f],
                           "avatar 1, frame \(f): dormant stagger must be byte-identical to stagger-off")
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

    /// Shared G5/G6 runner: two avatars at deep constant overlap (hold-only driver,
    /// zero scripted motion). The shove ramps the root at `velocityCap` until the
    /// mutual displacement reaches the self-limiting equilibrium (≈ the initial
    /// overlap depth; partner-feedback, spec G5 amendment) — a bounded transient,
    /// not a sustained drive. Returns the residual peak/tail (increment 2's
    /// metric) and whether a step fired.
    @MainActor private func staggerRun(velocityCap: Float, postural: Bool,
                                       suppressStep: Bool = false) async throws
        -> (peak: Float, tail: Float, stepped: Bool, leanAngle: Float) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let a = try await avatar(device, index: 0)
        let b = try await avatar(device, index: 1)
        // 0.05, not 0.06: the postural lean (G6) is still driven by the CHEST
        // signal, which only fires with the torso axes inside one radius — 0.05
        // is where Task 2 measured it live, so G6's lean is genuinely active.
        let driver = holdOnlyDriver(halfSep: 0.05)

        // Probe the fixture's torso-pair overlap depth (the Phase 0e signal:
        // radiusA + radiusB − segmentDistance) on throwaway avatars (scoped so
        // the ~330MB instances free before the measured run), then size the gain
        // large (target gain·depth = 1.5 m) so the raw target never caps the
        // displacement — the binding bound is the partner-feedback equilibrium
        // offset ≈ depth·g/(1+g) ≈ the measured overlap itself, reached at
        // `velocityCap` and held (spec G5 amendment).
        let gain: Float = try await {
            let pa = try await avatar(device, index: 0)
            let pb = try await avatar(device, index: 1)
            let probe = CrowdFrameStepper(avatars: [pa, pb], driver: driver, group: nil, fps: 60)
            probe.step(frameTime: 0)
            let mine = try XCTUnwrap(SpringBoneContactColliderSet.worldTorsoCapsule(model: pa.model))
            let partner = try XCTUnwrap(SpringBoneContactColliderSet.worldTorsoCapsule(model: pb.model))
            let dist = CrowdContactClamp.segmentDistance(mine.p0, mine.p1, partner.p0, partner.p1)
            let depth = max(0, mine.radius + partner.radius - dist)
            XCTAssertGreaterThan(depth, 0.01,
                "fixture precondition: torso capsules overlap at halfSep 0.05 — lower halfSep if this fails")
            return 1.5 / depth
        }()

        let stepper = CrowdFrameStepper(
            avatars: [a, b], driver: driver, group: nil, fps: 60,
            postural: postural ? PosturalContactParams() : nil,
            stagger: StaggerShoveParams(shoveGain: gain, velocityCap: velocityCap))
        if suppressStep {
            // G5's counter-case: make the step trigger unreachable. The controller
            // still restores/pins the planted feet every frame — only the capture
            // step is removed, isolating the mechanism under test.
            stepper.captureStepController(forAvatar: 0)?.params.triggerMargin = -10
            stepper.captureStepController(forAvatar: 1)?.params.triggerMargin = -10
        }

        var residuals: [Float] = []
        var stepped = false
        var maxLean: Float = 0
        for f in 0..<180 {
            stepper.step(frameTime: Float(f) / 180.0)
            let c = try XCTUnwrap(stepper.captureStepController(forAvatar: 0))
            if c.plantedFeet.count == 1 { stepped = true }
            if let bal = BalanceModel.evaluate(model: a.model, plantedFeet: c.plantedFeet) {
                residuals.append(max(0, -bal.margin))
            }
            maxLean = max(maxLean, stepper.posturalLayer(forAvatar: 0)?.currentLeanAngle ?? 0)
        }
        return (residuals.max() ?? 0, Array(residuals.suffix(15)).max() ?? 0, stepped, maxLean)
    }

    /// G5 — the north-star gate: the crowd shove staggers the avatar (a step
    /// fires) and it stays balanced — the residual CONTRACTS, on the same metric
    /// increment 2's rig gate uses. Counter-case (non-negotiable) — STEP
    /// SUPPRESSED: the same shove with the step trigger made unreachable reaches
    /// a real residual peak and FAILS to contract, proving the capture step (not
    /// the fixture) is what restores balance. Rate discriminator: a 0.4 m/s cap
    /// transiently degrades balance ≥2× the 0.14 peak yet still contracts — the
    /// mutual shove is self-limiting (partner-feedback equilibrium, spec G5
    /// amendment), so sustained over-capacity escape is structurally impossible
    /// in-crowd; escape under sustained drive is increment 2's rig gate.
    @MainActor func testG5_shoveStaggersAndStepKeepsItUpright() async throws {
        let epsilon: Float = 0.001

        let under = try await staggerRun(velocityCap: 0.14, postural: false)
        XCTAssertTrue(under.stepped, "the shove forced at least one capture step (plantedFeet dropped to one)")
        XCTAssertLessThanOrEqual(under.tail, under.peak * 0.5 + epsilon,
            "with the step the residual contracts — staggered but upright (peak \(under.peak), tail \(under.tail))")

        let suppressed = try await staggerRun(velocityCap: 0.14, postural: false, suppressStep: true)
        XCTAssertFalse(suppressed.stepped, "trigger unreachable ⇒ no step fired")
        XCTAssertGreaterThan(suppressed.peak, 0.01,
            "the shove produced a real disturbance (peak \(suppressed.peak))")
        XCTAssertGreaterThan(suppressed.tail, suppressed.peak * 0.5 + epsilon,
            "without the step the residual does NOT contract (peak \(suppressed.peak), tail \(suppressed.tail))")

        let overRate = try await staggerRun(velocityCap: 0.4, postural: false)
        XCTAssertGreaterThan(overRate.peak, under.peak * 2,
            "a faster cap transiently degrades balance materially (\(overRate.peak) vs \(under.peak))")
        XCTAssertLessThanOrEqual(overRate.tail, overRate.peak * 0.5 + epsilon,
            "yet still contracts — the self-limiting displacement bound (peak \(overRate.peak), tail \(overRate.tail))")
    }

    /// G6 — self-relief independence: G5's under-capacity case with the postural
    /// lean ACTIVE. The lean tilts the chest, which is this avatar's own torso
    /// capsule's endpoint — so the lean still relieves the Phase 0e overlap
    /// signal (0e runs after 0d), yet the step still fires and balance still
    /// contracts — the shove channel triggers the stagger independently of the
    /// self-relieving yield (validates the §5 tension resolution directly).
    @MainActor func testG6_stepFiresWithPosturalLeanActive() async throws {
        let withLean = try await staggerRun(velocityCap: 0.14, postural: true)
        XCTAssertGreaterThan(withLean.leanAngle, 0.01,
            "non-vacuity: the postural lean genuinely engaged in this run")
        XCTAssertTrue(withLean.stepped, "the step fires even with the self-relieving lean active")
        XCTAssertLessThanOrEqual(withLean.tail, withLean.peak * 0.5 + 0.001,
            "and the residual still contracts (peak \(withLean.peak), tail \(withLean.tail))")
    }
}
