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

/// O1: Tests for glTF sparse accessor support in BufferLoader.
final class SparseAccessorTests: XCTestCase {

    // MARK: - Helpers

    /// Build a minimal GLTFDocument with one buffer, two bufferViews (indices + values),
    /// and one accessor that has no bufferView but has a sparse override.
    ///
    /// Accessor: SCALAR UNSIGNED_INT, count=15
    /// Sparse: 3 overrides at indices [1, 5, 10] with values [42, 99, 7]
    private func makeSparseDocument() -> (GLTFDocument, Data) {
        // indices buffer: 3 x UInt8 = [1, 5, 10]
        var indicesBytes = Data([1, 5, 10])

        // values buffer: 3 x UInt32 = [42, 99, 7]
        var valuesBytes = Data(count: 12)
        valuesBytes.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt32(42), toByteOffset: 0, as: UInt32.self)
            ptr.storeBytes(of: UInt32(99), toByteOffset: 4, as: UInt32.self)
            ptr.storeBytes(of: UInt32(7),  toByteOffset: 8, as: UInt32.self)
        }

        // Pack both into a single binary blob
        let binaryData = indicesBytes + valuesBytes

        // bufferView 0 → indices (offset 0, length 3)
        // bufferView 1 → values  (offset 3, length 12)
        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "buffers": [["byteLength": binaryData.count]],
            "bufferViews": [
                ["buffer": 0, "byteOffset": 0, "byteLength": 3],
                ["buffer": 0, "byteOffset": 3, "byteLength": 12]
            ],
            "accessors": [
                [
                    "componentType": 5125,  // UNSIGNED_INT
                    "count": 15,
                    "type": "SCALAR",
                    "sparse": [
                        "count": 3,
                        "indices": [
                            "bufferView": 0,
                            "byteOffset": 0,
                            "componentType": 5121  // UNSIGNED_BYTE
                        ],
                        "values": [
                            "bufferView": 1,
                            "byteOffset": 0
                        ]
                    ]
                ]
            ]
        ]

        let data = try! JSONSerialization.data(withJSONObject: json)
        let document = try! JSONDecoder().decode(GLTFDocument.self, from: data)
        return (document, binaryData)
    }

    // MARK: - O1 Tests

    func testSparseAccessorZeroBaseWithOverrides() throws {
        let (document, binaryData) = makeSparseDocument()
        let loader = BufferLoader(document: document, binaryData: binaryData)

        let result: [UInt32] = try loader.loadAccessor(0, type: UInt32.self)

        XCTAssertEqual(result.count, 15, "Result count must match accessor.count")

        // Sparse overrides
        XCTAssertEqual(result[1], 42, "Sparse override at index 1 should be 42")
        XCTAssertEqual(result[5], 99, "Sparse override at index 5 should be 99")
        XCTAssertEqual(result[10], 7,  "Sparse override at index 10 should be 7")

        // All other elements must be zero
        for i in 0..<15 where i != 1 && i != 5 && i != 10 {
            XCTAssertEqual(result[i], 0, "Non-overridden element \(i) should be 0")
        }
    }

    func testSparseAccessorAsFloat() throws {
        let (document, binaryData) = makeSparseDocument()
        let loader = BufferLoader(document: document, binaryData: binaryData)

        let result: [Float] = try loader.loadAccessorAsFloat(0)

        XCTAssertEqual(result.count, 15)
        XCTAssertEqual(result[1], 42.0, accuracy: 0.01)
        XCTAssertEqual(result[5], 99.0, accuracy: 0.01)
        XCTAssertEqual(result[10], 7.0, accuracy: 0.01)

        for i in 0..<15 where i != 1 && i != 5 && i != 10 {
            XCTAssertEqual(result[i], 0.0, accuracy: 0.001)
        }
    }

    func testSparseAccessorAsUInt32() throws {
        let (document, binaryData) = makeSparseDocument()
        let loader = BufferLoader(document: document, binaryData: binaryData)

        let result: [UInt32] = try loader.loadAccessorAsUInt32(0)

        XCTAssertEqual(result.count, 15)
        XCTAssertEqual(result[1], 42)
        XCTAssertEqual(result[5], 99)
        XCTAssertEqual(result[10], 7)

        for i in 0..<15 where i != 1 && i != 5 && i != 10 {
            XCTAssertEqual(result[i], 0)
        }
    }

    func testSparseAccessorWithUnsignedShortIndices() throws {
        // Build an accessor with UNSIGNED_SHORT sparse indices
        var indicesBytes = Data(count: 6)
        indicesBytes.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt16(2), toByteOffset: 0, as: UInt16.self)
            ptr.storeBytes(of: UInt16(7), toByteOffset: 2, as: UInt16.self)
            ptr.storeBytes(of: UInt16(9), toByteOffset: 4, as: UInt16.self)
        }

        var valuesBytes = Data(count: 12)
        valuesBytes.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt32(100), toByteOffset: 0, as: UInt32.self)
            ptr.storeBytes(of: UInt32(200), toByteOffset: 4, as: UInt32.self)
            ptr.storeBytes(of: UInt32(300), toByteOffset: 8, as: UInt32.self)
        }

        let binaryData = indicesBytes + valuesBytes

        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "buffers": [["byteLength": binaryData.count]],
            "bufferViews": [
                ["buffer": 0, "byteOffset": 0, "byteLength": 6],
                ["buffer": 0, "byteOffset": 6, "byteLength": 12]
            ],
            "accessors": [
                [
                    "componentType": 5125,
                    "count": 10,
                    "type": "SCALAR",
                    "sparse": [
                        "count": 3,
                        "indices": [
                            "bufferView": 0,
                            "byteOffset": 0,
                            "componentType": 5123  // UNSIGNED_SHORT
                        ],
                        "values": [
                            "bufferView": 1,
                            "byteOffset": 0
                        ]
                    ]
                ]
            ]
        ]

        let data = try! JSONSerialization.data(withJSONObject: json)
        let document = try! JSONDecoder().decode(GLTFDocument.self, from: data)
        let loader = BufferLoader(document: document, binaryData: binaryData)

        let result: [UInt32] = try loader.loadAccessorAsUInt32(0)

        XCTAssertEqual(result.count, 10)
        XCTAssertEqual(result[2], 100)
        XCTAssertEqual(result[7], 200)
        XCTAssertEqual(result[9], 300)
        for i in 0..<10 where i != 2 && i != 7 && i != 9 {
            XCTAssertEqual(result[i], 0)
        }
    }
}
