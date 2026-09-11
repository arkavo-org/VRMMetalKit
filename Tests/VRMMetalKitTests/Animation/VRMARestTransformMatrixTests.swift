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

/// glTF `node.matrix` is column-major, so elements 12..14 are the translation.
final class VRMARestTransformMatrixTests: XCTestCase {
    private func node(matrix: [Float]) throws -> GLTFNode {
        let json = "{\"name\": \"m\", \"matrix\": [\(matrix.map { "\($0)" }.joined(separator: ","))]}"
        return try JSONDecoder().decode(GLTFNode.self, from: json.data(using: .utf8)!)
    }

    func testMatrixNodeTranslationIsColumnMajor() throws {
        let rest = RestTransform(node: try node(matrix: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 5, 6, 7, 1]))
        XCTAssertEqual(rest.translation, SIMD3<Float>(5, 6, 7))
        XCTAssertEqual(rest.rotation.real, 1, accuracy: 1e-5)
    }

    func testMatrixNodeRotationKeepsHandedness() throws {
        // 90° about +Y: column 0 = (0,0,-1), column 2 = (1,0,0).
        let rest = RestTransform(node: try node(matrix: [0, 0, -1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1]))
        let rotated = rest.rotation.act(SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(rotated.x, 0, accuracy: 1e-5)
        XCTAssertEqual(rotated.z, -1, accuracy: 1e-5, "+90° about Y takes +X to -Z, got \(rotated)")
    }
}
