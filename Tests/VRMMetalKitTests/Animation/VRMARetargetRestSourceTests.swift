// Copyright 2026 Arkavo
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

import XCTest
import simd
@testable import VRMMetalKit

/// VRMA retargeting composes deltas onto the model's rest pose. For VRM 0.x
/// models the runtime skeleton is conjugated by Ry180 at load time and the
/// bind pose is stored on `VRMNode.initialRotation`; the raw glTF node data
/// describes the pre-conversion skeleton and must not be used as the rest.
final class VRMARetargetRestSourceTests: XCTestCase {
    func testModelRestUsesNodeBindPoseNotRawGLTF() throws {
        let json = """
        {
          "asset": {"version": "2.0"},
          "nodes": [
            {"name": "root", "children": [1], "rotation": [0, 0, 0, 1]},
            {"name": "hips", "rotation": [0.3826834, 0, 0, 0.9238795], "translation": [0, 0.9, -0.01]}
          ]
        }
        """
        let gltf = try JSONDecoder().decode(GLTFDocument.self, from: Data(json.utf8))
        let humanoid = VRMHumanoid()
        humanoid.humanBones[.hips] = VRMHumanoid.VRMHumanBone(node: 1)
        let model = VRMModel(specVersion: .v0_0, meta: VRMMeta(licenseUrl: ""), humanoid: humanoid, gltf: gltf)
        model.nodes = gltf.nodes!.enumerated().map { VRMNode(index: $0.offset, gltfNode: $0.element) }

        // Simulate the load-time Ry180 conjugation of the bind pose.
        let ry180 = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        let hips = model.nodes[1]
        let converted = ry180 * hips.rotation * ry180.inverse
        hips.initialRotation = converted
        hips.initialTranslation = SIMD3<Float>(0, 0.9, 0.01)
        hips.rotation = converted
        hips.translation = hips.initialTranslation

        let rest = try XCTUnwrap(buildModelRestTransforms(model: model)[.hips])

        let d = min(simd_length(rest.rotation.vector - converted.vector), simd_length(rest.rotation.vector + converted.vector))
        XCTAssertLessThan(d, 1e-5, "rest rotation must be the converted bind pose, got \(rest.rotation)")
        XCTAssertEqual(rest.translation.z, 0.01, accuracy: 1e-6, "rest translation must be the converted bind pose")
    }
}
