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

        // Weight is 1.0 and the source rotation is a pure rotation about the
        // constraint axis, so the extracted twist equals the source rotation
        // exactly (no swing component to discard) — the solved value has a
        // known closed form, not just "differs from identity".
        let expected = simd_quatf(angle: 0.4, axis: axis)
        XCTAssertEqual(afterConstrain.vector.x, expected.vector.x, accuracy: 1e-5)
        XCTAssertEqual(afterConstrain.vector.y, expected.vector.y, accuracy: 1e-5)
        XCTAssertEqual(afterConstrain.vector.z, expected.vector.z, accuracy: 1e-5)
        XCTAssertEqual(afterConstrain.vector.w, expected.vector.w, accuracy: 1e-5)
        XCTAssertNotEqual(afterSample.vector, afterConstrain.vector,
                          "S4 must resolve the constraint against the arm write that landed after S0")
    }

    /// Proves the WIRED path, not just `PoseStage.constrain` in isolation, and
    /// specifically that S4 runs AFTER S3 — not merely "somewhere in `step()`".
    ///
    /// The source bone is `leftLowerArm`, one of the four bones
    /// `ArmCounterbalanceLayer` (S3) writes via its soft-elbow term
    /// (`ArmCounterbalanceLayer.applyDirect`); the target is `leftHand`, which no
    /// stage in this pipeline configuration writes. Two avatars are shoved into
    /// contact (`halfSep: 0.05`, matching `StaggerShoveIntegrationTests`'s brace
    /// gate) with `stagger` + `armCounterbalance` both enabled so S3 actually
    /// moves the source bone.
    ///
    /// The test solves the SAME constraint, with the SAME real `ConstraintSolver`,
    /// against two different source values — the value just before this frame's
    /// `step()` (pre-S3) and the value `step()` actually left behind (post-S3) —
    /// and shows the pipeline's own S4 output matches the post-S3 solve and NOT
    /// the pre-S3 one. That is the assertion that pins the ordering: a stray
    /// `constrain` call anywhere else in `step()` that happened to run before S3
    /// would fail it, where a bare "rotation != identity" check would not.
    @MainActor func testStepperWiresConstrainAfterLimbSolve() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }

        @MainActor func crowdAvatar(index: Int) async throws -> CrowdFrameStepper.Avatar {
            let model = try await loadModel(device)
            var config = RendererConfig(); config.synchronousSpringBone = true
            let renderer = VRMRenderer(device: device, config: config)
            renderer.loadModel(model)
            for root in model.nodes where root.parent == nil {
                root.rotation = CrowdPlacement.facing(avatarIndex: index, avatarCount: 2)
            }
            model.updateNodeTransforms()
            return CrowdFrameStepper.Avatar(renderer: renderer, model: model, player: AnimationPlayer(), index: index)
        }

        let a = try await crowdAvatar(index: 0)
        let b = try await crowdAvatar(index: 1)
        let humanoid = try XCTUnwrap(a.model.humanoid)
        let sourceIdx = try XCTUnwrap(humanoid.getBoneNode(.leftLowerArm))
        let targetIdx = try XCTUnwrap(humanoid.getBoneNode(.leftHand))

        let axis = SIMD3<Float>(0, 1, 0)
        let constraint = VRMNodeConstraint(
            targetNode: targetIdx, constraint: .roll(sourceNode: sourceIdx, axis: axis, weight: 1.0))
        a.model.nodeConstraints = [constraint]

        let driver = CrowdMotionDriver(startSep: 0.05, holdSep: 0.05,
                                       approachStart: 0.0, approachEnd: 0.01, holdEnd: 1.0, partEnd: 1.0)
        let stepper = CrowdFrameStepper(avatars: [a, b], driver: driver, group: nil, fps: 60,
                                        stagger: StaggerShoveParams(), armCounterbalance: ArmCounterbalanceParams())
        let armLayer = try XCTUnwrap(stepper.armCounterbalanceLayer(forAvatar: 0), "brace wired for avatar 0")

        XCTAssertFalse(a.player.solvesConstraints,
                       "CrowdFrameStepper must disable the player's own solve for pipeline-driven avatars")

        // Drive frames until the brace's elbow term actually engages — the fixture
        // precondition `StaggerShoveIntegrationTests.testArmBrace_engagesOnShove_releasesOnRecovery`
        // already establishes halfSep 0.05 does this within 180 frames.
        var preS3Source = a.model.nodes[sourceIdx].rotation
        var engaged = false
        for f in 0..<180 {
            preS3Source = a.model.nodes[sourceIdx].rotation
            stepper.step(frameTime: Float(f) / 180.0)
            if armLayer.currentPose.leftElbow > 1e-3 { engaged = true; break }
        }
        XCTAssertTrue(engaged,
                      "fixture precondition: halfSep 0.05 must engage the arm brace's elbow term within 180 frames, else the ordering probe never exercises S3's write")

        let postS3Source = a.model.nodes[sourceIdx].rotation
        let actualTarget = a.model.nodes[targetIdx].rotation
        XCTAssertNotEqual(preS3Source.vector, postS3Source.vector,
                          "the elbow term must change the source bone this frame, else pre/post-S3 are indistinguishable")

        // Solve the identical constraint against each candidate source value with
        // a fresh, isolated solver — mutating and immediately restoring the live
        // nodes so this probe has no lasting effect on the model.
        func solvedTarget(usingSource source: simd_quatf) -> simd_quatf {
            let savedSource = a.model.nodes[sourceIdx].rotation
            let savedTarget = a.model.nodes[targetIdx].rotation
            a.model.nodes[sourceIdx].rotation = source
            ConstraintSolver().solve(constraints: [constraint], nodes: a.model.nodes)
            let result = a.model.nodes[targetIdx].rotation
            a.model.nodes[sourceIdx].rotation = savedSource
            a.model.nodes[targetIdx].rotation = savedTarget
            return result
        }

        let expectedFromPostS3 = solvedTarget(usingSource: postS3Source)
        let expectedFromPreS3 = solvedTarget(usingSource: preS3Source)

        XCTAssertEqual(actualTarget.vector.x, expectedFromPostS3.vector.x, accuracy: 1e-6)
        XCTAssertEqual(actualTarget.vector.y, expectedFromPostS3.vector.y, accuracy: 1e-6)
        XCTAssertEqual(actualTarget.vector.z, expectedFromPostS3.vector.z, accuracy: 1e-6)
        XCTAssertEqual(actualTarget.vector.w, expectedFromPostS3.vector.w, accuracy: 1e-6)
        XCTAssertNotEqual(actualTarget.vector, expectedFromPreS3.vector,
                          "S4 must resolve against S3's output, not the pre-S3 value — a mis-ordered "
                          + "constrain() call would produce this pre-S3 result instead")
    }
}
