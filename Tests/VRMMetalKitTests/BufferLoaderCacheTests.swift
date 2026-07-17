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

/// Regression coverage for BufferLoader's per-instance accessor memoization
/// and the tightly-packed bulk-copy fast path. Split-primitive face meshes
/// re-reference the same morph/attribute accessors 7–8× per model; the
/// cache must return identical values on repeat and concurrent decodes.
final class BufferLoaderCacheTests: XCTestCase {

    /// One tightly-packed FLOAT SCALAR accessor over [0.5, 1.5, 2.5, 3.5] —
    /// exactly the shape the bulk-copy fast path handles.
    private func makeFloatDocument() -> (GLTFDocument, Data) {
        var binaryData = Data()
        for i in 0..<4 {
            var f = Float(i) + 0.5
            binaryData.append(Data(bytes: &f, count: MemoryLayout<Float>.size))
        }
        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "buffers": [["byteLength": binaryData.count]],
            "bufferViews": [["buffer": 0, "byteOffset": 0, "byteLength": binaryData.count]],
            "accessors": [[
                "bufferView": 0,
                "byteOffset": 0,
                "componentType": 5126,
                "count": 4,
                "type": "SCALAR",
            ]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return (try! JSONDecoder().decode(GLTFDocument.self, from: data), binaryData)
    }

    func testRepeatDecodeReturnsIdenticalValues() throws {
        let (document, bin) = makeFloatDocument()
        let loader = BufferLoader(document: document, binaryData: bin)

        let first = try loader.loadAccessorAsFloat(0)
        let second = try loader.loadAccessorAsFloat(0)

        XCTAssertEqual(first, [0.5, 1.5, 2.5, 3.5],
                       "bulk fast path must decode the packed floats exactly")
        XCTAssertEqual(first, second, "cached repeat decode must return identical values")
    }

    /// The cache is read/written from concurrent mesh-decode tasks; 16
    /// parallel decodes of the same accessor must all return the same values.
    func testConcurrentRepeatDecodesAreConsistent() async throws {
        let (document, bin) = makeFloatDocument()
        let loader = BufferLoader(document: document, binaryData: bin)
        let expected = try loader.loadAccessorAsFloat(0)

        try await withThrowingTaskGroup(of: [Float].self) { group in
            for _ in 0..<16 {
                group.addTask { try loader.loadAccessorAsFloat(0) }
            }
            for try await result in group {
                XCTAssertEqual(result, expected)
            }
        }
    }
}
