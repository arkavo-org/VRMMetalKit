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

final class SpringBoneContactColliderSetTests: XCTestCase {
    @MainActor func testEmptyWithoutHumanoid() {
        let json = #"{"asset":{"version":"2.0"}}"#
        let gltf = try! JSONDecoder().decode(GLTFDocument.self, from: Data(json.utf8))
        let model = VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: ""), humanoid: nil, gltf: gltf)
        XCTAssertTrue(SpringBoneContactColliderSet.synthesize(model: model).isEmpty)
    }

    @MainActor func testContactSetHasTorsoArmsAndHead() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()
        let set = SpringBoneContactColliderSet.synthesize(model: model)
        // torso (1 capsule) + 2 upper-arm capsules + head brow (1 capsule) = 4 capsules;
        // skull sphere = 1 sphere. Bounded contact-set cardinality (design §6).
        let capsules = set.filter { if case .capsule = $0.shape { return true } else { return false } }
        let spheres = set.filter { if case .sphere = $0.shape { return true } else { return false } }
        XCTAssertEqual(capsules.count, 4, "torso + 2 arms + brow")
        XCTAssertEqual(spheres.count, 1, "skull sphere")
        for c in set {
            switch c.shape {
            case let .capsule(_, radius, _): XCTAssertTrue(radius.isFinite && radius > 0)
            case let .sphere(_, radius): XCTAssertTrue(radius.isFinite && radius > 0)
            default: XCTFail("unexpected shape")
            }
        }
    }

    @MainActor func testHeadGeometryMatchesAugmentor() async throws {
        // Parity: the shared primitive means the contact set's head geometry is
        // identical to the augmentor's for the same bones (design §2.3).
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()
        let humanoid = try XCTUnwrap(model.humanoid)
        let ratios = SpringBoneColliderAugmentor.Ratios()
        let brow = try XCTUnwrap(SpringBoneBoneGeometry.headBrowCapsule(humanoid: humanoid, model: model, ratios: ratios))
        let set = SpringBoneContactColliderSet.synthesize(model: model)
        let setBrow = set.first {
            if case .capsule = $0.shape, $0.node == brow.node { return true } else { return false }
        }
        XCTAssertNotNil(setBrow, "contact set includes the same brow capsule the augmentor emits")
    }
}
