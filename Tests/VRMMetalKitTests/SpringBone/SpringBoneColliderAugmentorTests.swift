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

final class SpringBoneColliderAugmentorTests: XCTestCase {
    private func makeModelWithoutHumanoid() -> VRMModel {
        let json = #"{"asset":{"version":"2.0"}}"#
        let gltf = try! JSONDecoder().decode(GLTFDocument.self, from: Data(json.utf8))
        return VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: ""), humanoid: nil, gltf: gltf)
    }

    @MainActor func testAugmentorEmptyWithoutHumanoid() {
        let model = makeModelWithoutHumanoid()
        XCTAssertTrue(SpringBoneColliderAugmentor.synthesize(model: model).isEmpty)
    }

    @MainActor func testAugmentOffAddsNoSyntheticColliders() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        XCTAssertEqual(model.springBone?.syntheticColliders.count, 0)
    }

    @MainActor func testAugmentOnAddsEightLimbCapsules() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        // Eight end-to-end limb capsules: upper/lower arm + upper/lower leg, both sides.
        let synthetic = model.springBone?.syntheticColliders ?? []
        XCTAssertEqual(synthetic.count, 8)
        for collider in synthetic {
            guard case let .capsule(_, radius, _) = collider.shape else {
                return XCTFail("Synthetic colliders must all be capsules")
            }
            XCTAssertTrue(radius.isFinite && radius > 0, "Capsule radius must be finite and positive")
        }
    }

    /// AvatarSample_U: `synthesize` returns 8 limb capsules; the `leftUpperArm`
    /// capsule's far end (after applying the from-bone world transform to
    /// offset+tail) lands within 1 cm of `leftLowerArm`'s world position; and the
    /// limb radii comfortably exceed the physical skin floors the oracle measured
    /// (arm > 0.037, thigh > 0.062) — sanity FLOORS, not oracle reads.
    @MainActor func testAugmentU_limbCapsuleGeometryAndRadii() async throws {
        let path = getTestModelPath("AvatarSample_U_1.0.vrm.glb")
        try requireFixture(path, hint: "AvatarSample_U_1.0.vrm.glb")
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        guard let humanoid = model.humanoid else { return XCTFail("U must have a humanoid") }

        let synthetic = SpringBoneColliderAugmentor.synthesize(model: model)
        XCTAssertEqual(synthetic.count, 8, "U should yield 8 limb capsules")

        // Resolve the leftUpperArm capsule and verify its far end lands on leftLowerArm.
        guard let upperArmNode = humanoid.getBoneNode(.leftUpperArm),
              let lowerArmNode = humanoid.getBoneNode(.leftLowerArm) else {
            return XCTFail("U must rig left upper/lower arm")
        }
        guard let upperArmCapsule = synthetic.first(where: { $0.node == upperArmNode }) else {
            return XCTFail("Missing leftUpperArm capsule")
        }
        guard case let .capsule(offset, radius, tail) = upperArmCapsule.shape else {
            return XCTFail("leftUpperArm collider must be a capsule")
        }

        let wm = model.nodes[upperArmNode].worldMatrix
        let rot = simd_float3x3(
            SIMD3<Float>(wm[0][0], wm[0][1], wm[0][2]),
            SIMD3<Float>(wm[1][0], wm[1][1], wm[1][2]),
            SIMD3<Float>(wm[2][0], wm[2][1], wm[2][2])
        )
        let p0 = model.nodes[upperArmNode].worldPosition + rot * offset
        let farEnd = p0 + rot * tail
        let lowerArmPos = model.nodes[lowerArmNode].worldPosition
        XCTAssertLessThan(simd_length(farEnd - lowerArmPos), 0.01,
            "leftUpperArm capsule far end must land within 1cm of leftLowerArm")

        // Arm radius must enclose the arm skin (oracle measured ~0.037).
        XCTAssertTrue(radius.isFinite)
        XCTAssertGreaterThan(radius, 0.037, "Arm capsule must enclose the arm skin")

        // Thigh radius must enclose the thigh skin (oracle measured ~0.062).
        guard let thighNode = humanoid.getBoneNode(.leftUpperLeg),
              let thighCapsule = synthetic.first(where: { $0.node == thighNode }),
              case let .capsule(_, thighRadius, _) = thighCapsule.shape else {
            return XCTFail("Missing leftUpperLeg capsule")
        }
        XCTAssertGreaterThan(thighRadius, 0.062, "Thigh capsule must enclose the thigh skin")
    }


    /// Fail-safe: a model with >= 31 authored collider groups disables
    /// augmentation (the synthetic group bit would alias an authored group).
    @MainActor func testAugmentSkippedAtOrAbove31ColliderGroups() {
        let json = #"{"asset":{"version":"2.0"}}"#
        let gltf = try! JSONDecoder().decode(GLTFDocument.self, from: Data(json.utf8))
        let humanoid = VRMHumanoid()
        humanoid.humanBones[.leftUpperArm] = VRMHumanoid.VRMHumanBone(node: 0)
        humanoid.humanBones[.leftLowerArm] = VRMHumanoid.VRMHumanBone(node: 1)
        let model = VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: ""), humanoid: humanoid, gltf: gltf)
        var sb = VRMSpringBone()
        sb.colliderGroups = (0..<31).map { VRMColliderGroup(name: "G\($0)", colliders: []) }
        model.springBone = sb
        XCTAssertTrue(SpringBoneColliderAugmentor.synthesize(model: model).isEmpty,
            "Augmentation must be disabled at >= 31 authored collider groups")
    }
}
