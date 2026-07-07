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
        // A range of reachable targets around the rest ankle: fore/back/lateral, small
        // vertical, within leg reach (offsets ≤ ~0.15 m so the solve doesn't clamp).
        let offsets: [SIMD3<Float>] = [
            SIMD3(0.10, 0, 0), SIMD3(-0.10, 0, 0), SIMD3(0, 0, 0.12), SIMD3(0, 0, -0.12),
            SIMD3(0.08, 0.03, 0.08), SIMD3(-0.08, 0.02, -0.06), SIMD3(0.12, 0, -0.10),
        ]
        var worstError: Float = 0
        for off in offsets {
            let target = rest + off
            c.placeAnkle(.left, worldTarget: target, model: model)
            model.updateNodeTransforms()
            let landed = try ankleWorld(model, .left)
            worstError = max(worstError, simd_distance(landed, target))
        }
        // ε: the ankle must land essentially at the target everywhere in range.
        XCTAssertLessThan(worstError, 0.01, "worst-case placement error (ε) across the target range")
    }
}
