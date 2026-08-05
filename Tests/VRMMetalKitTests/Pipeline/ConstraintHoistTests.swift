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
