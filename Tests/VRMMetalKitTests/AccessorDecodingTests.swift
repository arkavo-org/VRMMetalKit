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
@testable import VRMMetalKit

final class AccessorDecodingTests: XCTestCase {
    private func loader(bytes: [UInt8], componentType: Int = 5121,
                        normalized: Bool? = nil, count: Int? = nil,
                        accessorOffset: Int = 0, viewOffset: Int = 0,
                        viewLength: Int? = nil, stride: Int? = nil,
                        sparse: [String: Any]? = nil) throws -> BufferLoader {
        var accessor: [String: Any] = [
            "componentType": componentType, "type": "SCALAR",
            "count": count ?? bytes.count, "byteOffset": accessorOffset,
        ]
        if let normalized { accessor["normalized"] = normalized }
        if let sparse { accessor["sparse"] = sparse } else { accessor["bufferView"] = 0 }
        var view = ["buffer": 0, "byteOffset": viewOffset, "byteLength": viewLength ?? bytes.count]
        if let stride { view["byteStride"] = stride }
        let json: [String: Any] = [
            "asset": ["version": "2.0"], "buffers": [["byteLength": bytes.count]],
            "bufferViews": [view], "accessors": [accessor],
        ]
        let document = try JSONDecoder().decode(GLTFDocument.self, from: JSONSerialization.data(withJSONObject: json))
        return BufferLoader(document: document, binaryData: Data(bytes))
    }

    func testUnnormalizedIntegersKeepTheirMagnitude() throws {
        for normalized in [nil, false] as [Bool?] {
            let bytes = try loader(bytes: [0, 128, 255], normalized: normalized)
            XCTAssertEqual(try bytes.loadAccessorAsFloat(0), [0, 128, 255])
            let shorts = try loader(bytes: [0, 128, 255, 127], componentType: 5122,
                                    normalized: normalized, count: 2)
            XCTAssertEqual(try shorts.loadAccessorAsFloat(0), [-32768, 32767])
        }
    }

    func testSignedNormalizedMinimumClampsToMinusOne() throws {
        let bytes = try loader(bytes: [128, 0, 127], componentType: 5120, normalized: true)
        XCTAssertEqual(try bytes.loadAccessorAsFloat(0), [-1, 0, 1])
        let shorts = try loader(bytes: [0, 128, 255, 127], componentType: 5122, normalized: true, count: 2)
        XCTAssertEqual(try shorts.loadAccessorAsFloat(0), [-1, 1])
    }

    func testUnsignedNormalizedEndpointsAndCache() throws {
        let bytes = try loader(bytes: [0, 255], normalized: true)
        XCTAssertEqual(try bytes.loadAccessorAsFloat(0), [0, 1])
        XCTAssertEqual(try bytes.loadAccessorAsFloat(0), [0, 1])
    }

    func testSparseValuesHonorNormalization() throws {
        let sparse: [String: Any] = [
            "count": 1, "indices": ["bufferView": 0, "componentType": 5121],
            "values": ["bufferView": 0, "byteOffset": 1],
        ]
        let raw = try loader(bytes: [1, 128], normalized: false, count: 3, sparse: sparse)
        XCTAssertEqual(try raw.loadAccessorAsFloat(0), [0, 128, 0])
        let signed = try loader(bytes: [1, 128], componentType: 5120, normalized: true, count: 3, sparse: sparse)
        XCTAssertEqual(try signed.loadAccessorAsFloat(0), [0, -1, 0])
    }

    func testAccessorsCannotReadAdjacentBufferViews() throws {
        let value = try loader(bytes: [1, 42], count: 2, viewLength: 1)
        XCTAssertThrowsError(try value.loadAccessorAsFloat(0))
        XCTAssertThrowsError(try value.loadAccessorAsUInt32(0))
        XCTAssertThrowsError(try value.loadAccessor(0, type: UInt8.self))
    }

    func testInvalidAccessorRangesThrowBeforeReadingOrAllocating() throws {
        let invalid = [
            try loader(bytes: [0], count: -1),
            try loader(bytes: [0], count: Int.max),
            try loader(bytes: [0], accessorOffset: -1),
            try loader(bytes: [0], accessorOffset: Int.max),
            try loader(bytes: [0], viewOffset: -1),
            try loader(bytes: [0], viewOffset: Int.max),
            try loader(bytes: [0], viewLength: -1),
            try loader(bytes: [0], viewLength: Int.max),
            try loader(bytes: [0], stride: -1),
        ]
        for value in invalid {
            XCTAssertThrowsError(try value.loadAccessorAsFloat(0))
            XCTAssertThrowsError(try value.loadAccessorAsUInt32(0))
            XCTAssertThrowsError(try value.loadAccessor(0, type: UInt8.self))
        }
    }

    func testSparseRangesAreBoundedByTheirBufferViews() throws {
        for offset in [-1, 2, Int.max] {
            let sparse: [String: Any] = [
                "count": 1, "indices": ["bufferView": 0, "componentType": 5121],
                "values": ["bufferView": 0, "byteOffset": offset],
            ]
            let value = try loader(bytes: [0, 128], count: 1, sparse: sparse)
            XCTAssertThrowsError(try value.loadAccessorAsFloat(0))
        }
    }
}
