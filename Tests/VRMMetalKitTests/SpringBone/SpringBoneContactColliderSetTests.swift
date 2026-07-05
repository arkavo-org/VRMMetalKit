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
        let set = SpringBoneContactColliderSet.synthesize(model: model, includeAuthored: false)
        // torso (1 capsule) + 2 upper-arm capsules + head brow (1 capsule) = 4 capsules;
        // skull sphere = 1 sphere. Bounded contact-set cardinality (design §6).
        let capsules = set.filter { if case .capsule = $0.shape { return true } else { return false } }
        let spheres = set.filter { if case .sphere = $0.shape { return true } else { return false } }
        XCTAssertEqual(capsules.count, 6, "torso + 2 arms + brow + 2 thighs")
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
        let skull = try XCTUnwrap(SpringBoneBoneGeometry.headSkullSphere(humanoid: humanoid, model: model, ratios: ratios))
        guard case let .capsule(browOffset, browRadius, browTail) = brow.shape else {
            return XCTFail("augmentor brow primitive is not a capsule")
        }
        guard case let .sphere(skullOffset, skullRadius) = skull.shape else {
            return XCTFail("augmentor skull primitive is not a sphere")
        }

        let set = SpringBoneContactColliderSet.synthesize(model: model, includeAuthored: false)
        let setBrow = set.first {
            if case .capsule = $0.shape, $0.node == brow.node { return true } else { return false }
        }
        let setSkull = set.first {
            if case .sphere = $0.shape, $0.node == skull.node { return true } else { return false }
        }
        let browCollider = try XCTUnwrap(setBrow, "contact set includes the same brow capsule the augmentor emits")
        let skullCollider = try XCTUnwrap(setSkull, "contact set includes the same skull sphere the augmentor emits")

        guard case let .capsule(setBrowOffset, setBrowRadius, setBrowTail) = browCollider.shape else {
            return XCTFail("contact-set brow primitive is not a capsule")
        }
        XCTAssertEqual(setBrowOffset, browOffset, "brow capsule offset must match the augmentor's geometry")
        XCTAssertEqual(setBrowRadius, browRadius, "brow capsule radius must match the augmentor's geometry")
        XCTAssertEqual(setBrowTail, browTail, "brow capsule tail must match the augmentor's geometry")

        guard case let .sphere(setSkullOffset, setSkullRadius) = skullCollider.shape else {
            return XCTFail("contact-set skull primitive is not a sphere")
        }
        XCTAssertEqual(setSkullOffset, skullOffset, "skull sphere offset must match the augmentor's geometry")
        XCTAssertEqual(setSkullRadius, skullRadius, "skull sphere radius must match the augmentor's geometry")
    }
}
