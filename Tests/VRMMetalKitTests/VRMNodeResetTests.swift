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
import simd
@testable import VRMMetalKit

final class VRMNodeResetTests: XCTestCase {

    // Helper to create GLTFNode from JSON
    func createGLTFNode(json: String) throws -> GLTFNode {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(GLTFNode.self, from: data)
    }

    func testResetToBindPose_TRS() throws {
        // Node defined with Translation, Rotation, Scale
        let json = """
        {
            "name": "TestNode",
            "translation": [1.0, 2.0, 3.0],
            "rotation": [0.0, 0.0, 0.0, 1.0],
            "scale": [1.0, 1.0, 1.0]
        }
        """
        let gltfNode = try createGLTFNode(json: json)
        let node = VRMNode(index: 0, gltfNode: gltfNode)

        // Verify initial state
        XCTAssertEqual(node.translation.x, 1.0)
        XCTAssertEqual(node.rotation.real, 1.0)

        // Modify transform (simulate procedural animation)
        node.translation = SIMD3<Float>(10, 10, 10)
        let newRot = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        node.rotation = newRot
        node.scale = SIMD3<Float>(2, 2, 2)
        node.updateLocalMatrix()

        // Verify modification
        XCTAssertEqual(node.translation.x, 10.0)
        XCTAssertNotEqual(node.rotation.real, 1.0)

        // RESET
        node.resetToBindPose()

        // Verify restored state
        XCTAssertEqual(node.translation.x, 1.0)
        XCTAssertEqual(node.translation.y, 2.0)
        XCTAssertEqual(node.translation.z, 3.0)

        // Quaternion equality check (dot product close to 1 or -1)
        let dot = abs(simd_dot(node.rotation, simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)))
        XCTAssertGreaterThan(dot, 0.999)

        XCTAssertEqual(node.scale.x, 1.0)
    }

    func testResetToBindPose_Matrix() throws {
        // Node defined with Matrix (Translation 1,2,3)
        // Matrix is column-major in JSON:
        // 1 0 0 0
        // 0 1 0 0
        // 0 0 1 0
        // 1 2 3 1
        let json = """
        {
            "name": "MatrixNode",
            "matrix": [
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                1, 2, 3, 1
            ]
        }
        """
        let gltfNode = try createGLTFNode(json: json)
        let node = VRMNode(index: 1, gltfNode: gltfNode)

        // Verify decomposition worked
        XCTAssertEqual(node.translation.x, 1.0)
        XCTAssertEqual(node.translation.y, 2.0)
        XCTAssertEqual(node.translation.z, 3.0)
        XCTAssertEqual(node.scale.x, 1.0)

        // Modify
        node.translation = SIMD3<Float>(5, 5, 5)
        node.updateLocalMatrix()
        XCTAssertEqual(node.translation.x, 5.0)

        // RESET
        node.resetToBindPose()

        // Verify restored
        XCTAssertEqual(node.translation.x, 1.0)
        XCTAssertEqual(node.translation.y, 2.0)
        XCTAssertEqual(node.translation.z, 3.0)
    }
}
