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

    /// Exact-byte golden for the 2×2 image (fixed-Huffman deflate encoding).
    static let expected2x2 = "89504e470d0a1a0a0000000d494844520000000200000002080600000072b60d240000001449444154780163f8cf0044ff191a18c0341000003fd708797cb4d77e0000000049454e44ae426082"

    func testKnownImageEncodesToExactBytes() throws {
        let png = try PNGEncoder.encode(width: 2, height: 2, rgba: PNGEncoderTests.pixels2x2)
        XCTAssertEqual(png.map { String(format: "%02x", $0) }.joined(), PNGEncoderTests.expected2x2)
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
        XCTAssertEqual(idat[2] & 0x07, 0x03, "single final fixed-Huffman block")
        XCTAssertEqual(PNGEncoder.crc32(Array("IEND".utf8)), 0xAE42_6082)
        XCTAssertEqual(PNGEncoder.crc32([]), 0)
        XCTAssertEqual(PNGEncoder.adler32(Array("Wikipedia".utf8)), 0x11E6_0398)
        var corrupted = png
        corrupted[40] ^= 0xFF
        XCTAssertFalse(try PNGEncoder.chunks(of: corrupted).allSatisfy(\.crcValid))
    }

    /// A 300×300 noise image deflates losslessly: the fixed-Huffman stream is
    /// decoded here by an independent in-test inflate and must reproduce the
    /// filter-0 rows byte for byte, with the zlib adler32 intact.
    func testDeflateRoundTripsNoiseWithValidAdler() throws {
        let width = 300, height = 300
        var prng = SplitMix64(seed: 42)
        let rgba = (0..<(width * height * 4)).map { _ in UInt8(truncatingIfNeeded: prng.next()) }
        let png = try PNGEncoder.encode(width: width, height: height, rgba: rgba)
        let idat = try PNGEncoder.chunks(of: png)[1].payload
        let raw = try XCTUnwrap(PNGEncoderTests.inflateFixed(Array(idat.dropFirst(2).dropLast(4))))
        XCTAssertEqual(raw.count, height * (1 + width * 4))
        let n = idat.count
        let adler = UInt32(idat[n - 4]) << 24 | UInt32(idat[n - 3]) << 16 | UInt32(idat[n - 2]) << 8 | UInt32(idat[n - 1])
        XCTAssertEqual(adler, PNGEncoder.adler32(raw))
        for y in 0..<height {
            XCTAssertEqual(raw[y * (1 + width * 4)], 0)
            XCTAssertEqual(Array(raw[(y * (1 + width * 4) + 1)..<((y + 1) * (1 + width * 4))]), Array(rgba[(y * width * 4)..<((y + 1) * width * 4)]))
        }
    }

    /// Flat pixels must collapse: a solid 512×512 image is orders of magnitude
    /// smaller under LZ77 matches than the stored-block layout.
    func testDeflateCompressesFlatImage() throws {
        let png = try PNGEncoder.encode(width: 512, height: 512, rgba: Array(repeating: 200, count: 512 * 512 * 4))
        XCTAssertLessThan(png.count, 512 * (1 + 512 * 4) / 50)
    }

    /// Minimal inflate for the encoder's single fixed-Huffman block.
    static func inflateFixed(_ bytes: [UInt8]) -> [UInt8]? {
        var bitPos = 0
        func bit() -> Int? {
            guard bitPos / 8 < bytes.count else { return nil }
            let b = Int((bytes[bitPos / 8] >> (bitPos % 8)) & 1)
            bitPos += 1
            return b
        }
        func bits(_ n: Int) -> Int? {
            var v = 0
            for k in 0..<n {
                guard let b = bit() else { return nil }
                v |= b << k
            }
            return v
        }
        let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
        let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
        let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
        let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
        guard let bfinal = bits(1), let btype = bits(2), bfinal == 1, btype == 1 else { return nil }
        var out: [UInt8] = []
        while true {
            var code = 0, length = 0
            while true {
                guard let b = bit() else { return nil }
                code = (code << 1) | b
                length += 1
                if length == 7, code <= 0x17 { break }
                if length == 8, (0x30...0xBF).contains(code) || (0xC0...0xC7).contains(code) { break }
                if length == 9 { break }
            }
            let symbol: Int
            switch length {
            case 7: symbol = 256 + code
            case 8: symbol = code <= 0xBF ? code - 0x30 : 280 + code - 0xC0
            default:
                guard (0x190...0x1FF).contains(code) else { return nil }
                symbol = 144 + code - 0x190
            }
            if symbol == 256 { return out }
            if symbol < 256 {
                out.append(UInt8(symbol))
                continue
            }
            let li = symbol - 257
            guard li < 29, let extraLen = bits(lengthExtra[li]) else { return nil }
            let matchLength = lengthBase[li] + extraLen
            var distSym = 0
            for _ in 0..<5 {
                guard let b = bit() else { return nil }
                distSym = (distSym << 1) | b
            }
            guard distSym < 30, let distExtraBits = bits(distExtra[distSym]) else { return nil }
            let distance = distBase[distSym] + distExtraBits
            guard distance <= out.count else { return nil }
            for _ in 0..<matchLength { out.append(out[out.count - distance]) }
        }
    }

    func testRejectsBadDimensionsAndBufferSizes() {
        XCTAssertThrowsError(try PNGEncoder.encode(width: 0, height: 1, rgba: []))
        XCTAssertThrowsError(try PNGEncoder.encode(width: 4097, height: 1, rgba: Array(repeating: 0, count: 4097 * 4)))
        XCTAssertThrowsError(try PNGEncoder.encode(width: 2, height: 2, rgba: [1, 2, 3]))
        XCTAssertThrowsError(try PNGEncoder.chunks(of: Data([1, 2, 3])))
    }
}
