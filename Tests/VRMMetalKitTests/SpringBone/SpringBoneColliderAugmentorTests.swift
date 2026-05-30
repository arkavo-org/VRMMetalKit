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

    @MainActor func testAugmentOnWithEmptyGeneratorStillNoSynthetic() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        XCTAssertEqual(model.springBone?.syntheticColliders.count, 0)   // empty generator
    }
}
