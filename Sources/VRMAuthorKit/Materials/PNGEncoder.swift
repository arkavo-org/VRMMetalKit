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
/// every row, zlib stream made of stored (uncompressed) deflate blocks, and
/// exactly three chunks (IHDR, IDAT, IEND). No ancillary chunks are written,
/// so the bytes depend only on the pixels and dimensions.
public enum PNGEncoder {
    public static let version = "png-stored/1"
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
        appendChunk(&out, type: "IDAT", payload: zlibStored(raw))
        appendChunk(&out, type: "IEND", payload: [])
        return out
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
