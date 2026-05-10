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
@testable import VRMMetalKit

/// Regression tests for loader-side security hardening:
/// 1. Malicious morphIndex values beyond the per-mesh cap must be rejected.
/// 2. Unknown glTF componentType values must throw, not silently default.
/// 3. Symlinks inside the base URL pointing outside must be rejected by the
///    path-traversal guard.
final class LoaderSecurityTests: XCTestCase {

    // MARK: - 1. Morph target index cap

    func testApplyExpressionRejectsMorphIndexAtCap() {
        // index == maxMorphTargets is the first out-of-range value (cap is exclusive).
        let cap = VRMConstants.Rendering.maxMorphTargets

        let controller = VRMExpressionController()
        var expr = VRMExpression(name: "evil", preset: nil)
        expr.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: cap, weight: 1.0)]
        controller.registerCustomExpression(expr, name: "evil")
        controller.setCustomExpressionWeight("evil", weight: 1.0)

        let weights = controller.weightsForMesh(0, morphCount: cap + 1)
        XCTAssertEqual(
            weights[cap], 0.0,
            "Bind with morphIndex >= maxMorphTargets (\(cap)) must be skipped"
        )
    }

    func testApplyExpressionAcceptsMorphIndexBelowCap() {
        let cap = VRMConstants.Rendering.maxMorphTargets
        let validIndex = cap - 1

        let controller = VRMExpressionController()
        var expr = VRMExpression(name: "ok", preset: nil)
        expr.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: validIndex, weight: 0.5)]
        controller.registerCustomExpression(expr, name: "ok")
        controller.setCustomExpressionWeight("ok", weight: 1.0)

        let weights = controller.weightsForMesh(0, morphCount: cap)
        XCTAssertEqual(
            weights[validIndex], 0.5, accuracy: 1e-6,
            "Valid bind at index \(validIndex) must still be applied after cap enforcement"
        )
    }

    func testApplyExpressionRejectsNegativeMorphIndex() {
        // Defensive: a JSON value coerced to a negative Int must not crash the loader
        // by going through the array-grow path with a negative count.
        let controller = VRMExpressionController()
        var expr = VRMExpression(name: "neg", preset: nil)
        expr.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: -1, weight: 1.0)]
        controller.registerCustomExpression(expr, name: "neg")
        controller.setCustomExpressionWeight("neg", weight: 1.0)

        // Just reaching this assert without crashing is the win; we also check the
        // valid window is untouched.
        let weights = controller.weightsForMesh(0, morphCount: 4)
        XCTAssertEqual(weights, [0, 0, 0, 0], "Negative morphIndex bind must be skipped")
    }

    // MARK: - 2. Unknown componentType / accessor type rejection

    private func makeAccessorDocument(componentType: Int, type: String, count: Int = 1) -> (GLTFDocument, Data) {
        let binaryData = Data(count: 16)
        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "buffers": [["byteLength": binaryData.count]],
            "bufferViews": [
                ["buffer": 0, "byteOffset": 0, "byteLength": binaryData.count]
            ],
            "accessors": [
                [
                    "bufferView": 0,
                    "byteOffset": 0,
                    "componentType": componentType,
                    "count": count,
                    "type": type
                ]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let document = try! JSONDecoder().decode(GLTFDocument.self, from: data)
        return (document, binaryData)
    }

    func testLoadAccessorThrowsOnUnknownComponentType() {
        // 5124 is the deliberately-undefined slot in glTF (between SHORT and UNSIGNED_INT),
        // and any other integer is also invalid. Both must be rejected rather than
        // silently treated as 4-byte FLOAT.
        let (document, binaryData) = makeAccessorDocument(componentType: 99999, type: "SCALAR")
        let loader = BufferLoader(document: document, binaryData: binaryData)

        XCTAssertThrowsError(try loader.loadAccessor(0, type: UInt32.self)) { error in
            guard case VRMError.invalidAccessor(_, let reason, _, _) = error else {
                XCTFail("Expected VRMError.invalidAccessor, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("componentType"),
                          "Error reason should mention componentType, got: \(reason)")
        }
    }

    func testLoadAccessorAsFloatThrowsOnUnknownComponentType() {
        let (document, binaryData) = makeAccessorDocument(componentType: 5124, type: "SCALAR")
        let loader = BufferLoader(document: document, binaryData: binaryData)

        XCTAssertThrowsError(try loader.loadAccessorAsFloat(0))
    }

    func testLoadAccessorAsUInt32ThrowsOnUnknownComponentType() {
        let (document, binaryData) = makeAccessorDocument(componentType: -1, type: "SCALAR")
        let loader = BufferLoader(document: document, binaryData: binaryData)

        XCTAssertThrowsError(try loader.loadAccessorAsUInt32(0))
    }

    func testLoadAccessorThrowsOnUnknownAccessorType() {
        let (document, binaryData) = makeAccessorDocument(componentType: 5126, type: "MAT5")
        let loader = BufferLoader(document: document, binaryData: binaryData)

        XCTAssertThrowsError(try loader.loadAccessor(0, type: Float.self)) { error in
            guard case VRMError.invalidAccessor(_, let reason, _, _) = error else {
                XCTFail("Expected VRMError.invalidAccessor, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("type"),
                          "Error reason should mention accessor type, got: \(reason)")
        }
    }

    // MARK: - 3. Path traversal via symlink

    func testLoadExternalBufferRejectsSymlinkPointingOutsideBaseDir() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("VRMSecTest-\(UUID().uuidString)", isDirectory: true)
        let baseDir = tmp.appendingPathComponent("base", isDirectory: true)
        let outsideDir = tmp.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // A "secret" file outside the base directory.
        let secretURL = outsideDir.appendingPathComponent("secret.bin")
        try Data([0xAA, 0xBB, 0xCC, 0xDD]).write(to: secretURL)

        // A symlink inside the base directory pointing at the secret file.
        let linkURL = baseDir.appendingPathComponent("link.bin")
        try fm.createSymbolicLink(at: linkURL, withDestinationURL: secretURL)

        // Build a minimal glTF document that references the symlink as an external buffer.
        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "buffers": [["uri": "link.bin", "byteLength": 4]],
            "bufferViews": [["buffer": 0, "byteOffset": 0, "byteLength": 4]],
            "accessors": [[
                "bufferView": 0,
                "byteOffset": 0,
                "componentType": 5121,  // UNSIGNED_BYTE
                "count": 4,
                "type": "SCALAR"
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let document = try JSONDecoder().decode(GLTFDocument.self, from: data)
        let loader = BufferLoader(document: document, binaryData: nil, baseURL: baseDir)

        XCTAssertThrowsError(try loader.loadAccessor(0, type: UInt8.self)) { error in
            guard case VRMError.invalidPath(_, let reason, _) = error else {
                XCTFail("Expected VRMError.invalidPath, got \(error)")
                return
            }
            XCTAssertTrue(reason.lowercased().contains("outside") ||
                          reason.lowercased().contains("traversal") ||
                          reason.lowercased().contains("security"),
                          "Error reason should flag the traversal, got: \(reason)")
        }
    }

    func testLoadExternalBufferAcceptsSymlinkPointingInsideBaseDir() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("VRMSecTest-\(UUID().uuidString)", isDirectory: true)
        let baseDir = tmp.appendingPathComponent("base", isDirectory: true)
        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // A real buffer inside the base directory.
        let realURL = baseDir.appendingPathComponent("real.bin")
        try Data([0x01, 0x02, 0x03, 0x04]).write(to: realURL)

        // A symlink that points within the base directory — must remain allowed.
        let linkURL = baseDir.appendingPathComponent("alias.bin")
        try fm.createSymbolicLink(at: linkURL, withDestinationURL: realURL)

        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "buffers": [["uri": "alias.bin", "byteLength": 4]],
            "bufferViews": [["buffer": 0, "byteOffset": 0, "byteLength": 4]],
            "accessors": [[
                "bufferView": 0,
                "byteOffset": 0,
                "componentType": 5121,
                "count": 4,
                "type": "SCALAR"
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let document = try JSONDecoder().decode(GLTFDocument.self, from: data)
        let loader = BufferLoader(document: document, binaryData: nil, baseURL: baseDir)

        let result: [UInt8] = try loader.loadAccessor(0, type: UInt8.self)
        XCTAssertEqual(result, [1, 2, 3, 4],
                       "In-base symlink must still resolve and load")
    }
}
