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

import Foundation
import XCTest
@testable import VRMAuthorKit

final class PNGEncoderTests: XCTestCase {
    static let pixels2x2: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 255, 255, 255, 255]

    /// Independently assembled (Python zlib/struct) bytes for the 2×2 image.
    static let expected2x2 = "89504e470d0a1a0a0000000d494844520000000200000002080600000072b60d240000001d494441547801011200edff00ff0000ff00ff0080000000ff00ffffffff3fd70879122ad9880000000049454e44ae426082"

    func testKnownImageEncodesToExactBytes() throws {
        let png = try PNGEncoder.encode(width: 2, height: 2, rgba: PNGEncoderTests.pixels2x2)
        XCTAssertEqual(png.map { String(format: "%02x", $0) }.joined(), PNGEncoderTests.expected2x2)
        XCTAssertEqual(png.count, 86)
        XCTAssertEqual(try PNGEncoder.encode(width: 2, height: 2, rgba: PNGEncoderTests.pixels2x2), png, "deterministic")
    }

    func testChunkLayoutAndChecksums() throws {
        let png = try PNGEncoder.encode(width: 2, height: 2, rgba: PNGEncoderTests.pixels2x2)
        let chunks = try PNGEncoder.chunks(of: png)
        XCTAssertEqual(chunks.map(\.type), ["IHDR", "IDAT", "IEND"], "no ancillary chunks")
        XCTAssertTrue(chunks.allSatisfy(\.crcValid))
        XCTAssertEqual(chunks[0].payload, [0, 0, 0, 2, 0, 0, 0, 2, 8, 6, 0, 0, 0])
        let idat = chunks[1].payload
        XCTAssertEqual(Array(idat[0..<2]), [0x78, 0x01])
        XCTAssertEqual((Int(idat[0]) << 8 | Int(idat[1])) % 31, 0, "zlib header check")
        XCTAssertEqual(idat[2], 1, "single final stored block")
        XCTAssertEqual(PNGEncoder.crc32(Array("IEND".utf8)), 0xAE42_6082)
        XCTAssertEqual(PNGEncoder.crc32([]), 0)
        XCTAssertEqual(PNGEncoder.adler32(Array("Wikipedia".utf8)), 0x11E6_0398)
        var corrupted = png
        corrupted[40] ^= 0xFF
        XCTAssertFalse(try PNGEncoder.chunks(of: corrupted).allSatisfy(\.crcValid))
    }

    func testLargeImageUsesMultipleStoredBlocksWithValidAdler() throws {
        let width = 300, height = 300
        var prng = SplitMix64(seed: 42)
        let rgba = (0..<(width * height * 4)).map { _ in UInt8(truncatingIfNeeded: prng.next()) }
        let png = try PNGEncoder.encode(width: width, height: height, rgba: rgba)
        let idat = try PNGEncoder.chunks(of: png)[1].payload
        var offset = 2
        var raw: [UInt8] = []
        var blocks = 0
        while true {
            let final = idat[offset]
            let length = Int(idat[offset + 1]) | Int(idat[offset + 2]) << 8
            let nlength = Int(idat[offset + 3]) | Int(idat[offset + 4]) << 8
            XCTAssertEqual(length ^ nlength, 0xFFFF)
            XCTAssertLessThanOrEqual(length, PNGEncoder.maxStoredBlock)
            raw.append(contentsOf: idat[(offset + 5)..<(offset + 5 + length)])
            offset += 5 + length
            blocks += 1
            if final == 1 { break }
        }
        XCTAssertEqual(blocks, 6)
        XCTAssertEqual(raw.count, height * (1 + width * 4))
        XCTAssertEqual(offset + 4, idat.count)
        let adler = UInt32(idat[offset]) << 24 | UInt32(idat[offset + 1]) << 16 | UInt32(idat[offset + 2]) << 8 | UInt32(idat[offset + 3])
        XCTAssertEqual(adler, PNGEncoder.adler32(raw))
        for y in 0..<height {
            XCTAssertEqual(raw[y * (1 + width * 4)], 0)
            XCTAssertEqual(Array(raw[(y * (1 + width * 4) + 1)..<((y + 1) * (1 + width * 4))]), Array(rgba[(y * width * 4)..<((y + 1) * width * 4)]))
        }
    }

    func testRejectsBadDimensionsAndBufferSizes() {
        XCTAssertThrowsError(try PNGEncoder.encode(width: 0, height: 1, rgba: []))
        XCTAssertThrowsError(try PNGEncoder.encode(width: 4097, height: 1, rgba: Array(repeating: 0, count: 4097 * 4)))
        XCTAssertThrowsError(try PNGEncoder.encode(width: 2, height: 2, rgba: [1, 2, 3]))
        XCTAssertThrowsError(try PNGEncoder.chunks(of: Data([1, 2, 3])))
    }
}
