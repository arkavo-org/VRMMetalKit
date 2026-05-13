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

/// Regression coverage for `GLTFParser` cross-call state. See issue #189: a parser
/// instance reused for a second `parse(data:)` call must not surface the previous
/// call's `BIN` chunk when the new input has none.
final class GLTFParserStateTests: XCTestCase {

    // Minimal glTF JSON that satisfies `GLTFDocument` decoding.
    private static let minimalJSON: Data = {
        let payload: [String: Any] = ["asset": ["version": "2.0", "generator": "test"]]
        return try! JSONSerialization.data(withJSONObject: payload, options: [])
    }()

    /// Builds a GLB byte stream with a JSON chunk and (optionally) a BIN chunk.
    /// Each chunk's payload is padded to a 4-byte multiple per the GLB spec.
    private func makeGLB(binaryChunk: Data?) -> Data {
        var bytes = Data()

        // Header: magic "glTF", version 2, total length filled in later.
        bytes.append(contentsOf: [0x67, 0x6C, 0x54, 0x46])           // "glTF"
        withUnsafeBytes(of: UInt32(2).littleEndian) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(0).littleEndian) { bytes.append(contentsOf: $0) } // placeholder

        func appendChunk(_ payload: Data, type: [UInt8], pad: UInt8) {
            var padded = payload
            while padded.count % 4 != 0 { padded.append(pad) }
            withUnsafeBytes(of: UInt32(padded.count).littleEndian) { bytes.append(contentsOf: $0) }
            bytes.append(contentsOf: type)
            bytes.append(padded)
        }

        appendChunk(Self.minimalJSON, type: [0x4A, 0x53, 0x4F, 0x4E], pad: 0x20) // "JSON", space pad
        if let bin = binaryChunk {
            appendChunk(bin, type: [0x42, 0x49, 0x4E, 0x00], pad: 0x00)         // "BIN\0", zero pad
        }
        return bytes
    }

    /// Parsing a GLB with a BIN chunk and then a GLB without one must surface
    /// `nil` for the second call's binary data (and on `parser.binaryChunk`).
    /// Pre-#189 this returned the first call's bytes.
    func testParserResetsBinaryChunkBetweenCalls() throws {
        let parser = GLTFParser()
        let firstBinaryPayload = Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x10, 0x20])

        let firstGLB = makeGLB(binaryChunk: firstBinaryPayload)
        let (_, firstBinary) = try parser.parse(data: firstGLB)
        XCTAssertEqual(firstBinary, firstBinaryPayload, "first parse should return the BIN chunk bytes")
        XCTAssertEqual(parser.binaryChunk, firstBinaryPayload, "parser.binaryChunk should reflect the first parse")

        let secondGLB = makeGLB(binaryChunk: nil)
        let (_, secondBinary) = try parser.parse(data: secondGLB)
        XCTAssertNil(secondBinary, "second parse without a BIN chunk must return nil binary data")
        XCTAssertNil(parser.binaryChunk, "parser.binaryChunk must be cleared on the second parse")
    }

    /// Re-parsing with a *different* BIN chunk must overwrite, not append or
    /// otherwise leak the first chunk into the second result.
    func testParserOverwritesBinaryChunkOnSubsequentParse() throws {
        let parser = GLTFParser()
        let first = Data([0x01, 0x02, 0x03, 0x04])
        let second = Data([0xDE, 0xAD, 0xBE, 0xEF])

        _ = try parser.parse(data: makeGLB(binaryChunk: first))
        let (_, secondBinary) = try parser.parse(data: makeGLB(binaryChunk: second))
        XCTAssertEqual(secondBinary, second, "second parse must return the new BIN chunk, not the prior one")
        XCTAssertEqual(parser.binaryChunk, second, "parser.binaryChunk must reflect the most recent parse")
    }
}
