//
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
//

import XCTest
import Metal
import simd
@testable import GLTFMetalKit

/// Tests for `GLTFAsset.nodeIndex(named:)`, `GLTFAsset.evaluate(poses:)` and
/// `GLTFAsset.restPose(ofNode:)`.
///
/// Fixture: a small node hierarchy with one triangle mesh —
/// ```
/// root (0)
/// ├── childA (1)  T=(1,2,3)
/// │   └── grandchild (2)  T=(0,1,0), mesh
/// └── childB (3)  T=(5,0,0), mesh
/// ```
final class GLTFNodePoseEvaluationTests: XCTestCase {

    // MARK: - nodeIndex(named:)

    func testNodeIndexFindsNamedNode() async throws {
        let asset = try await loadFixture()
        XCTAssertEqual(asset.nodeIndex(named: "root"), 0)
        XCTAssertEqual(asset.nodeIndex(named: "childA"), 1)
        XCTAssertEqual(asset.nodeIndex(named: "grandchild"), 2)
        XCTAssertEqual(asset.nodeIndex(named: "childB"), 3)
        XCTAssertNil(asset.nodeIndex(named: "no-such-node"))
    }

    // MARK: - restPose(ofNode:)

    func testRestPoseReturnsAuthoredTRS() async throws {
        let asset = try await loadFixture()
        let rest = asset.restPose(ofNode: 1)
        XCTAssertEqual(rest.translation, SIMD3<Float>(1, 2, 3))
        XCTAssertEqual(rest.rotation, simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
        XCTAssertEqual(rest.scale, SIMD3<Float>(1, 1, 1))
        // Out-of-range → identity.
        let identity = asset.restPose(ofNode: 99)
        XCTAssertEqual(identity.translation, SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(identity.rotation, simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
    }

    // MARK: - evaluate(poses:)

    func testTranslationOverrideMovesChildButNotSibling() async throws {
        let asset = try await loadFixture()
        let childA = asset.nodeIndex(named: "childA")!
        let grandchild = asset.nodeIndex(named: "grandchild")!
        let childB = asset.nodeIndex(named: "childB")!

        let rest = asset.evaluate(poses: [:])
        let posed = asset.evaluate(poses: [
            childA: GLTFNodePose(translation: SIMD3<Float>(10, 0, 0))
        ])

        // Overridden node + its child move together.
        XCTAssertEqual(translation(of: posed.worldMatrices[childA]), SIMD3<Float>(10, 0, 0))
        XCTAssertEqual(translation(of: posed.worldMatrices[grandchild]), SIMD3<Float>(10, 1, 0))

        // Unrelated sibling is unchanged from rest.
        XCTAssertEqual(translation(of: posed.worldMatrices[childB]),
                       translation(of: rest.worldMatrices[childB]))
        XCTAssertEqual(translation(of: posed.worldMatrices[childB]), SIMD3<Float>(5, 0, 0))
    }

    func testRotationOverridePropagatesToGrandchild() async throws {
        let asset = try await loadFixture()
        let childA = asset.nodeIndex(named: "childA")!
        let grandchild = asset.nodeIndex(named: "grandchild")!

        // 90° about Z maps local +Y to -X: grandchild (0,1,0) → (-1,0,0).
        let rotation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
        let posed = asset.evaluate(poses: [childA: GLTFNodePose(rotation: rotation)])

        let expected = SIMD3<Float>(1, 2, 3) + SIMD3<Float>(-1, 0, 0)
        let actual = translation(of: posed.worldMatrices[grandchild])
        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-5)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-5)
        XCTAssertEqual(actual.z, expected.z, accuracy: 1e-5)
    }

    func testEmptyPosesReproduceRestDrawCalls() async throws {
        let asset = try await loadFixture()
        let rebuilt = asset.evaluate(poses: [:])

        XCTAssertEqual(rebuilt.drawCalls.count, asset.drawCalls.count)
        for (rest, reposed) in zip(asset.drawCalls, rebuilt.drawCalls) {
            for column in 0..<4 {
                for row in 0..<4 {
                    XCTAssertEqual(
                        reposed.modelMatrix[column][row],
                        rest.modelMatrix[column][row],
                        accuracy: 1e-6,
                        "draw call model matrix mismatch at [\(column)][\(row)]"
                    )
                }
            }
        }
    }

    // MARK: - Helpers

    private func translation(of matrix: simd_float4x4) -> SIMD3<Float> {
        let c = matrix.columns.3
        return SIMD3<Float>(c.x, c.y, c.z)
    }

    /// Builds the fixture asset from an in-memory GLB (JSON + BIN chunks).
    private func loadFixture() async throws -> GLTFAsset {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }

        // One triangle: (0,0,0), (1,0,0), (0,1,0) — 36 bytes of Float32.
        var bin = Data()
        for value: Float in [0, 0, 0, 1, 0, 0, 0, 1, 0] {
            bin.append(contentsOf: value.bitPattern.littleEndianBytes())
        }
        let binPad = (4 - bin.count % 4) % 4
        bin.append(contentsOf: Array(repeating: UInt8(0), count: binPad))

        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [
                ["name": "root", "children": [1, 3]],
                ["name": "childA", "translation": [1.0, 2.0, 3.0], "children": [2]],
                ["name": "grandchild", "translation": [0.0, 1.0, 0.0], "mesh": 0],
                ["name": "childB", "translation": [5.0, 0.0, 0.0], "mesh": 0],
            ],
            "meshes": [
                ["primitives": [["attributes": ["POSITION": 0]]]]
            ],
            "accessors": [
                [
                    "bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3",
                    "min": [0.0, 0.0, 0.0], "max": [1.0, 1.0, 0.0],
                ]
            ],
            "bufferViews": [
                ["buffer": 0, "byteOffset": 0, "byteLength": 36]
            ],
            "buffers": [
                ["byteLength": 36]
            ],
        ]

        var jsonData = try JSONSerialization.data(withJSONObject: json, options: [])
        let jsonPad = (4 - jsonData.count % 4) % 4
        jsonData.append(contentsOf: Array(repeating: UInt8(0x20), count: jsonPad))

        var glb = Data()
        let totalLength = UInt32(12 + 8 + jsonData.count + 8 + bin.count)
        glb.append(contentsOf: [0x67, 0x6C, 0x54, 0x46])                // "glTF" magic
        glb.append(contentsOf: UInt32(2).littleEndianBytes())           // version
        glb.append(contentsOf: totalLength.littleEndianBytes())         // total length
        glb.append(contentsOf: UInt32(jsonData.count).littleEndianBytes())
        glb.append(contentsOf: [0x4A, 0x53, 0x4F, 0x4E])                // "JSON" chunk
        glb.append(jsonData)
        glb.append(contentsOf: UInt32(bin.count).littleEndianBytes())
        glb.append(contentsOf: [0x42, 0x49, 0x4E, 0x00])                // "BIN\0" chunk
        glb.append(bin)

        let parser = GLTFParser()
        let parsed = try parser.parse(data: glb)
        let loader = GLTFAssetLoader()
        return try await loader.build(
            document: parsed.document,
            binaryData: parsed.binaryData,
            baseURL: nil,
            device: device
        )
    }
}

private extension UInt32 {
    func littleEndianBytes() -> [UInt8] {
        let le = self.littleEndian
        return [
            UInt8(le & 0xFF),
            UInt8((le >> 8) & 0xFF),
            UInt8((le >> 16) & 0xFF),
            UInt8((le >> 24) & 0xFF),
        ]
    }
}
