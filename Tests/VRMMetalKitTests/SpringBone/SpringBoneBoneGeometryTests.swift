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

final class SpringBoneBoneGeometryTests: XCTestCase {
    @MainActor func testLimbCapsuleNilWhenBoneMissing() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()
        let humanoid = try XCTUnwrap(model.humanoid)
        // Same bone at both ends is a zero-length (degenerate) segment; the
        // length guard rejects it regardless of fixture-specific bone spacing.
        let collider = SpringBoneBoneGeometry.limbCapsule(
            fromBone: .leftEye, toBone: .leftEye, radiusFraction: 0.2,
            humanoid: humanoid, model: model)
        XCTAssertNil(collider)
    }

    @MainActor func testLimbCapsuleProducesFiniteCapsuleForLeg() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()
        let humanoid = try XCTUnwrap(model.humanoid)
        let collider = try XCTUnwrap(SpringBoneBoneGeometry.limbCapsule(
            fromBone: .leftUpperLeg, toBone: .leftLowerLeg, radiusFraction: 0.24,
            humanoid: humanoid, model: model))
        guard case let .capsule(_, radius, tail) = collider.shape else {
            return XCTFail("expected capsule")
        }
        XCTAssertTrue(radius.isFinite && radius > 0)
        XCTAssertTrue(tail.x.isFinite && tail.y.isFinite && tail.z.isFinite)
    }
}
