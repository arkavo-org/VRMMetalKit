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

/// C2's gate, split by caller. Direct callers of `AnimationPlayer.update` keep
/// constraint-inclusive output — that is the correct contract for isolation
/// testing and it never sunsets. Pipeline callers get the behaviour change.
final class ConstraintHoistTests: XCTestCase {

    @MainActor private func loadModel(_ device: MTLDevice) async throws -> VRMModel {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        return try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
    }

    /// The flag defaults to true, so every existing direct caller — validators,
    /// benchmarks, and the isolation suites — is unaffected by the hoist.
    @MainActor func testFlagDefaultsToTrue() {
        XCTAssertTrue(AnimationPlayer().solvesConstraints,
                      "default must stay true; ~10 direct call sites depend on constraint-inclusive output")
    }

    /// With the flag off, constraint-target bones are left unconstrainted. This test
    /// constructs a synthetic roll constraint (axis-aligned to prove real twist extraction),
    /// rotates the source bone to a known angle, and asserts:
    /// 1. Target poses differ between solvesConstraints=true/false (flag gates the solve)
    /// 2. Target rotation is non-identity when flag=true (proves twist was extracted)
    /// 3. Target angle < source angle (proves weight blending is applied)
    @MainActor func testFlagGatesConstraintSolve() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }

        let modelOn = try await loadModel(device)
        let humanoid = try XCTUnwrap(modelOn.humanoid)

        guard let sourceNodeIdx = humanoid.getBoneNode(.leftLowerArm),
              let targetNodeIdx = humanoid.getBoneNode(.leftHand),
              sourceNodeIdx < modelOn.nodes.count,
              targetNodeIdx < modelOn.nodes.count else {
            throw XCTSkip("Fixture does not have left lower arm and left hand bones")
        }

        let constraintAxis = SIMD3<Float>(0, 1, 0)
        let sourceAngle = Float.pi / 4
        let weight: Float = 0.5

        let constraint = VRMNodeConstraint(
            targetNode: targetNodeIdx,
            constraint: .roll(sourceNode: sourceNodeIdx, axis: constraintAxis, weight: weight)
        )
        modelOn.nodeConstraints = [constraint]

        let playerOn = AnimationPlayer()
        playerOn.solvesConstraints = true
        let emptyClip = AnimationClip(duration: 1.0)
        playerOn.load(emptyClip)

        let sourceRotation = simd_quatf(angle: sourceAngle, axis: constraintAxis)
        modelOn.nodes[sourceNodeIdx].rotation = sourceRotation
        modelOn.nodes[sourceNodeIdx].updateLocalMatrix()
        playerOn.update(deltaTime: 0, model: modelOn)
        let poseOn = try capturePose(modelOn)
        let targetRotationOn = modelOn.nodes[targetNodeIdx].rotation

        let modelOff = try await loadModel(device)
        modelOff.nodeConstraints = [constraint]

        let playerOff = AnimationPlayer()
        playerOff.solvesConstraints = false
        playerOff.load(emptyClip)

        modelOff.nodes[sourceNodeIdx].rotation = sourceRotation
        modelOff.nodes[sourceNodeIdx].updateLocalMatrix()
        playerOff.update(deltaTime: 0, model: modelOff)
        let poseOff = try capturePose(modelOff)

        XCTAssertNotEqual(poseOn, poseOff,
                          "flag=true must apply constraint; flag=false must not")

        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        XCTAssertNotEqual(targetRotationOn, identity,
                          "solved target rotation must be non-identity (twist was extracted)")

        let angleOn = 2.0 * acos(max(-1, min(1, targetRotationOn.real)))
        XCTAssertLessThan(angleOn, sourceAngle,
                          "target angle (\(angleOn)) must be less than source (\(sourceAngle)) due to 0.5 weight")
    }
}

extension ConstraintHoistTests {
    /// The behaviour change C2 buys: a constraint whose source bone is written
    /// by a post-S0 stage now tracks that stage's output. Built as a synthetic
    /// roll constraint on the forearm sourced from the upper arm, because the
    /// stock fixture may author none — the mechanism is what is under test, not
    /// any particular rig's authoring. Constraint axis and source-rotation axis
    /// are the same (0,1,0): a mismatch would send `extractTwist`'s projection
    /// to zero and make this pass even if the solver were broken.
    @MainActor func testConstraintTracksPostComposeArmWrite() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await loadModel(device)
        let humanoid = try XCTUnwrap(model.humanoid)
        let upperArm = try XCTUnwrap(humanoid.getBoneNode(.leftUpperArm))
        let lowerArm = try XCTUnwrap(humanoid.getBoneNode(.leftLowerArm))

        let axis = SIMD3<Float>(0, 1, 0)
        model.nodeConstraints = [
            VRMNodeConstraint(targetNode: lowerArm, constraint: .roll(sourceNode: upperArm, axis: axis, weight: 1.0))
        ]

        var avatar = PipelineAvatar(index: 0, model: model, player: AnimationPlayer(),
                                    baseTranslations: [:])
        avatar.player.solvesConstraints = false
        let snapshot = FrozenSnapshot(torsos: [:], indices: [0])

        PoseStage.sample(avatar: &avatar, partners: snapshot, dt: 1.0 / 60.0)
        let afterSample = model.nodes[lowerArm].rotation

        model.nodes[upperArm].rotation = simd_quatf(angle: 0.4, axis: axis)
        model.nodes[upperArm].updateLocalMatrix()
        model.updateNodeTransforms()

        PoseStage.constrain(avatar: &avatar, partners: snapshot, dt: 1.0 / 60.0)
        let afterConstrain = model.nodes[lowerArm].rotation

        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        XCTAssertNotEqual(afterConstrain, identity,
                          "solved target rotation must be non-identity, else the projection degenerated to zero")
        XCTAssertNotEqual(afterSample.vector, afterConstrain.vector,
                          "S4 must resolve the constraint against the arm write that landed after S0")
    }

    /// Proves the WIRED path, not just `PoseStage.constrain` in isolation:
    /// `CrowdFrameStepper` must (a) flip `solvesConstraints` off on every
    /// pipeline-driven player, so the solve is not run twice against two
    /// different poses, and (b) reach S4 after S3 inside `step()`, so a
    /// synthetic constraint set before the frame is resolved by the time the
    /// frame returns.
    @MainActor func testStepperWiresConstrainAfterLimbSolve() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await loadModel(device)
        let humanoid = try XCTUnwrap(model.humanoid)
        let upperArm = try XCTUnwrap(humanoid.getBoneNode(.leftUpperArm))
        let lowerArm = try XCTUnwrap(humanoid.getBoneNode(.leftLowerArm))

        let axis = SIMD3<Float>(0, 1, 0)
        model.nodeConstraints = [
            VRMNodeConstraint(targetNode: lowerArm, constraint: .roll(sourceNode: upperArm, axis: axis, weight: 1.0))
        ]
        model.nodes[upperArm].rotation = simd_quatf(angle: 0.4, axis: axis)
        model.nodes[upperArm].updateLocalMatrix()
        model.updateNodeTransforms()

        var config = RendererConfig(); config.synchronousSpringBone = true
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)

        let player = AnimationPlayer()
        let avatar = CrowdFrameStepper.Avatar(renderer: renderer, model: model, player: player, index: 0)
        let driver = CrowdMotionDriver(startSep: 1.0, holdSep: 1.0,
                                       approachStart: 0.0, approachEnd: 0.01, holdEnd: 1.0, partEnd: 1.0)
        let stepper = CrowdFrameStepper(avatars: [avatar], driver: driver, group: nil, fps: 60)

        XCTAssertFalse(player.solvesConstraints,
                       "CrowdFrameStepper must disable the player's own solve for pipeline-driven avatars")

        stepper.step(frameTime: 0)

        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        XCTAssertNotEqual(model.nodes[lowerArm].rotation, identity,
                          "PoseStage.constrain must run inside CrowdFrameStepper.step() after limbSolve")
    }
}
