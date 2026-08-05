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

final class SkinMeshCoverageTests: XCTestCase {

    @MainActor func testArmsAtSidesPlacesWristsBesideTheHips() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let path = getTestModelPath("AvatarSample_U_1.0.vrm.glb")
        try requireFixture(path, hint: "AvatarSample_U_1.0.vrm.glb")
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        let humanoid = try XCTUnwrap(model.humanoid)

        let player = AnimationPlayer()
        player.load(StressPoseFactory.clip(.armsAtSides, duration: 1))
        player.play()
        player.update(deltaTime: 0.5, model: model)
        model.updateNodeTransforms()

        let hips = model.nodes[try XCTUnwrap(humanoid.getBoneNode(.hips))].worldPosition
        let wrist = model.nodes[try XCTUnwrap(humanoid.getBoneNode(.leftHand))].worldPosition
        let shoulder = model.nodes[try XCTUnwrap(humanoid.getBoneNode(.leftUpperArm))].worldPosition

        // Rest is T-pose, so the wrist starts level with the shoulder and far
        // lateral. At the sides it must be BELOW the shoulder and near the hips
        // in height — asserted, not eyeballed.
        XCTAssertLessThan(wrist.y, shoulder.y - 0.2, "the arm hangs down")
        XCTAssertLessThan(abs(wrist.y - hips.y), 0.25, "the wrist is beside the hips in height")
        XCTAssertLessThan(abs(wrist.x - hips.x), 0.30, "the wrist is close to the body laterally")
    }
}
