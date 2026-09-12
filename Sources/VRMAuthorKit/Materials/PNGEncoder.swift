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

/// Deterministic, dependency-free PNG writer: 8-bit RGBA, filter type 0 on
/// every row, a zlib stream of fixed-Huffman deflate blocks with greedy LZ77
/// matching, and exactly three chunks (IHDR, IDAT, IEND). No ancillary chunks
/// are written, so the bytes depend only on the pixels and dimensions.
public enum PNGEncoder {
    public static let version = "png-fixed/1"
    public static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    public static let maxStoredBlock = 65535

    /// `rgba` holds width*height*4 bytes in row-major order.
    public static func encode(width: Int, height: Int, rgba: [UInt8]) throws -> Data {
        guard width >= 1, height >= 1, width <= 4096, height <= 4096 else {
            throw AuthorError(code: .validationFailed, path: "/width", observed: [.number(Double(width)), .number(Double(height))], required: "1...4096",
                              message: "PNG dimensions must be within 1...4096.")
        }
        guard rgba.count == width * height * 4 else {
            throw AuthorError(code: .validationFailed, path: "/rgba", observed: .number(Double(rgba.count)), required: .number(Double(width * height * 4)),
                              message: "Pixel buffer length does not match width*height*4.")
        }
        var raw: [UInt8] = []
        raw.reserveCapacity(height * (1 + width * 4))
        for y in 0..<height {
            raw.append(0)
            raw.append(contentsOf: rgba[(y * width * 4)..<((y + 1) * width * 4)])
        }
        var out = Data(signature)
        var ihdr: [UInt8] = []
        ihdr.append(contentsOf: bigEndian(UInt32(width)))
        ihdr.append(contentsOf: bigEndian(UInt32(height)))
        ihdr.append(contentsOf: [8, 6, 0, 0, 0])
        appendChunk(&out, type: "IHDR", payload: ihdr)
        appendChunk(&out, type: "IDAT", payload: zlibDeflateFixed(raw))
        appendChunk(&out, type: "IEND", payload: [])
        return out
    }

    // MARK: zlib / deflate

    /// zlib wrapper around a single fixed-Huffman deflate block produced by
    /// greedy LZ77 matching (3-byte hash chains, bounded search depth). Fully
    /// deterministic: ties break toward the nearest match, no lazy evaluation.
    public static func zlibDeflateFixed(_ bytes: [UInt8]) -> [UInt8] {
        [0x78, 0x01] + deflateFixed(bytes) + bigEndian(adler32(bytes))
    }

    public static func deflateFixed(_ bytes: [UInt8]) -> [UInt8] {
        let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
        let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
        let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
        let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

        var writer = BitWriter()
        writer.writeBits(1, 1)  // BFINAL
        writer.writeBits(1, 2)  // BTYPE = fixed Huffman

        func writeSymbol(_ symbol: Int) {
            if symbol < 144 {
                writer.writeHuffman(0x30 + symbol, 8)
            } else if symbol < 256 {
                writer.writeHuffman(0x190 + symbol - 144, 9)
            } else if symbol < 280 {
                writer.writeHuffman(symbol - 256, 7)
            } else {
                writer.writeHuffman(0xC0 + symbol - 280, 8)
            }
        }
        func writeMatch(_ length: Int, _ distance: Int) {
            var li = 0
            while li + 1 < lengthBase.count, lengthBase[li + 1] <= length { li += 1 }
            writeSymbol(257 + li)
            if lengthExtra[li] > 0 { writer.writeBits(length - lengthBase[li], lengthExtra[li]) }
            var di = 0
            while di + 1 < distBase.count, distBase[di + 1] <= distance { di += 1 }
            writer.writeHuffman(di, 5)
            if distExtra[di] > 0 { writer.writeBits(distance - distBase[di], distExtra[di]) }
        }

        var head = [Int](repeating: -1, count: 1 << 15)
        var prev = [Int](repeating: -1, count: max(bytes.count, 1))
        func hash(_ i: Int) -> Int {
            Int((UInt32(bytes[i]) &* 31 &+ UInt32(bytes[i + 1])) &* 31 &+ UInt32(bytes[i + 2])) & 0x7FFF
        }
        var i = 0
        while i < bytes.count {
            var bestLength = 0, bestDistance = 0
            if i + 2 < bytes.count {
                let h = hash(i)
                var candidate = head[h]
                var depth = 0
                while candidate >= 0, i - candidate <= 32768, depth < 64 {
                    var length = 0
                    let maxLength = min(258, bytes.count - i)
                    while length < maxLength, bytes[candidate + length] == bytes[i + length] { length += 1 }
                    if length > bestLength {
                        bestLength = length
                        bestDistance = i - candidate
                        if length >= 258 { break }
                    }
                    candidate = prev[candidate]
                    depth += 1
                }
                prev[i] = head[h]
                head[h] = i
            }
            if bestLength >= 3 {
                writeMatch(bestLength, bestDistance)
                var j = i + 1
                while j < i + bestLength, j + 2 < bytes.count {
                    let h = hash(j)
                    prev[j] = head[h]
                    head[h] = j
                    j += 1
                }
                i += bestLength
            } else {
                writeSymbol(Int(bytes[i]))
                i += 1
            }
        }
        writeSymbol(256)  // end of block
        return writer.finish()
    }

    /// LSB-first deflate bit stream; Huffman codes are emitted MSB-first.
    struct BitWriter {
        var bytes: [UInt8] = []
        var current: UInt32 = 0
        var count = 0

        mutating func writeBits(_ value: Int, _ bits: Int) {
            current |= UInt32(value) << count
            count += bits
            while count >= 8 {
                bytes.append(UInt8(current & 0xFF))
                current >>= 8
                count -= 8
            }
        }

        mutating func writeHuffman(_ code: Int, _ bits: Int) {
            var reversed = 0
            for k in 0..<bits { reversed |= ((code >> k) & 1) << (bits - 1 - k) }
            writeBits(reversed, bits)
        }

        func finish() -> [UInt8] {
            var out = bytes
            if count > 0 { out.append(UInt8(current & 0xFF)) }
            return out
        }
    }

    // MARK: zlib / deflate stored blocks

    public static func zlibStored(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        var offset = 0
        repeat {
            let length = min(maxStoredBlock, bytes.count - offset)
            let final: UInt8 = offset + length >= bytes.count ? 1 : 0
            out.append(final)
            out.append(UInt8(length & 0xFF))
            out.append(UInt8(length >> 8))
            let nlen = ~UInt16(length)
            out.append(UInt8(nlen & 0xFF))
            out.append(UInt8(nlen >> 8))
            out.append(contentsOf: bytes[offset..<(offset + length)])
            offset += length
        } while offset < bytes.count
        out.append(contentsOf: bigEndian(adler32(bytes)))
        return out
    }

    public static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        var index = 0
        while index < bytes.count {
            let end = min(index + 5552, bytes.count)
            while index < end {
                a &+= UInt32(bytes[index])
                b &+= a
                index += 1
            }
            a %= 65521
            b %= 65521
        }
        return (b << 16) | a
    }

    // MARK: CRC-32

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    // MARK: Chunks

    static func appendChunk(_ out: inout Data, type: String, payload: [UInt8]) {
        let typeBytes = Array(type.utf8)
        out.append(contentsOf: bigEndian(UInt32(payload.count)))
        out.append(contentsOf: typeBytes)
        out.append(contentsOf: payload)
        out.append(contentsOf: bigEndian(crc32(typeBytes + payload)))
    }

    static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    public struct Chunk: Hashable, Sendable {
        public var type: String
        public var payload: [UInt8]
        public var crcValid: Bool
    }

    /// Splits a PNG into chunks and verifies each CRC; no decompression.
    public static func chunks(of data: Data) throws -> [Chunk] {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, Array(bytes[0..<8]) == signature else {
            throw AuthorError(code: .validationFailed, message: "Not a PNG: bad signature.")
        }
        var out: [Chunk] = []
        var offset = 8
        while offset + 12 <= bytes.count {
            let length = Int(readBigEndian(bytes, offset))
            let typeBytes = Array(bytes[(offset + 4)..<(offset + 8)])
            guard offset + 12 + length <= bytes.count else { throw AuthorError(code: .validationFailed, message: "Truncated PNG chunk.") }
            let payload = Array(bytes[(offset + 8)..<(offset + 8 + length)])
            let crc = readBigEndian(bytes, offset + 8 + length)
            out.append(Chunk(type: String(decoding: typeBytes, as: UTF8.self), payload: payload, crcValid: crc == crc32(typeBytes + payload)))
            offset += 12 + length
        }
        guard offset == bytes.count else { throw AuthorError(code: .validationFailed, message: "Trailing bytes after IEND.") }
        return out
    }

    static func readBigEndian(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16) | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }
}
