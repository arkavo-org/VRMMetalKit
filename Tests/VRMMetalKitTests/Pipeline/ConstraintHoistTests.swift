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

    /// With the flag off, constraint-target bones are left at their source-node's
    /// pose rather than having constraints solved against it. This test constructs
    /// a synthetic roll constraint, rotates the source bone, and asserts the target
    /// diverges between solvesConstraints=true and solvesConstraints=false.
    @MainActor func testFlagOffLeavesNonConstraintBonesIdentical() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }

        let modelOn = try await loadModel(device)
        let humanoid = try XCTUnwrap(modelOn.humanoid)

        guard let sourceNodeIdx = humanoid.getBoneNode(.leftLowerArm),
              let targetNodeIdx = humanoid.getBoneNode(.leftHand),
              sourceNodeIdx < modelOn.nodes.count,
              targetNodeIdx < modelOn.nodes.count else {
            throw XCTSkip("Fixture does not have left lower arm and left hand bones")
        }

        let constraint = VRMNodeConstraint(
            targetNode: targetNodeIdx,
            constraint: .roll(sourceNode: sourceNodeIdx, axis: SIMD3<Float>(1, 0, 0), weight: 0.5)
        )
        modelOn.nodeConstraints = [constraint]

        let playerOn = AnimationPlayer()
        playerOn.solvesConstraints = true
        let emptyClip = AnimationClip(duration: 1.0)
        playerOn.load(emptyClip)

        let sourceRotation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 1, 0))
        modelOn.nodes[sourceNodeIdx].rotation = sourceRotation
        modelOn.nodes[sourceNodeIdx].updateLocalMatrix()
        playerOn.update(deltaTime: 0, model: modelOn)
        let poseOn = try capturePose(modelOn)

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
                          "with synthetic constraint, disabling the solve must change the target bone's pose")
    }
}
