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

import Metal

/// Load-time BC7 encoder used by ``VRMLoadingOptimization/aggressiveTextureCompression``.
///
/// Color (sRGB) textures are re-uploaded as `bc7_rgbaUnorm_srgb` when the
/// device can sample BC. Linear data maps stay RGBA8 — compressing normals
/// or masks is a quality loss that the flag does not ask for.
///
/// BC7 Mode 6 is 8 bits/pixel (4× vs RGBA8). Solid colors round-trip
/// exactly; typical albedo mean-absolute error is at or below
/// ``pixelNearMeanAbsoluteError`` (3/255 per channel). That is the
/// documented pixel-near threshold for this path, not bit identity.
enum TextureBlockCompressor {

    /// Per-channel mean-absolute-error cap that "pixel-near" tests use.
    static let pixelNearMeanAbsoluteError: Float = 3.0 / 255.0

    static let blockSize = 4
    static let blockBytes = 16

    static func supportsCompression(on device: MTLDevice) -> Bool {
        device.supportsBCTextureCompression
    }

    static func preferredFormat(sRGB: Bool, device: MTLDevice) -> MTLPixelFormat? {
        guard device.supportsBCTextureCompression else { return nil }
        return sRGB ? .bc7_rgbaUnorm_srgb : .bc7_rgbaUnorm
    }

    /// Re-encodes an RGBA8 texture as BC7. Returns `nil` when the device
    /// cannot sample BC, the source is not RGBA8, or upload fails — callers
    /// keep the uncompressed original.
    static func compress(_ source: MTLTexture, device: MTLDevice) -> MTLTexture? {
        let srgb: Bool
        switch source.pixelFormat {
        case .rgba8Unorm_srgb: srgb = true
        case .rgba8Unorm: srgb = false
        default: return nil
        }
        guard let destFormat = preferredFormat(sRGB: srgb, device: device) else { return nil }
        guard source.storageMode == .shared else { return nil }
        guard source.width > 0, source.height > 0 else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: destFormat,
            width: source.width,
            height: source.height,
            mipmapped: source.mipmapLevelCount > 1
        )
        descriptor.mipmapLevelCount = source.mipmapLevelCount
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let dest = device.makeTexture(descriptor: descriptor) else { return nil }

        for level in 0..<source.mipmapLevelCount {
            let width = max(1, source.width >> level)
            let height = max(1, source.height >> level)
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            source.getBytes(
                &rgba,
                bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: level
            )
            let encoded = rgba.withUnsafeBufferPointer { buf in
                encodeBC7Mode6(
                    rgba: buf.baseAddress!,
                    width: width,
                    height: height,
                    bytesPerRow: width * 4
                )
            }
            let bytesPerRow = ((width + blockSize - 1) / blockSize) * blockBytes
            encoded.withUnsafeBytes { buf in
                dest.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: level,
                    withBytes: buf.baseAddress!,
                    bytesPerRow: bytesPerRow
                )
            }
        }
        return dest
    }

    /// Encodes tightly-or-strided RGBA8 bytes as a BC7 Mode 6 image.
    static func encodeBC7Mode6(
        rgba: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> Data {
        let blocksX = (width + blockSize - 1) / blockSize
        let blocksY = (height + blockSize - 1) / blockSize
        var out = Data(count: blocksX * blocksY * blockBytes)
        out.withUnsafeMutableBytes { raw in
            let dest = raw.bindMemory(to: UInt8.self)
            var destOffset = 0
            for by in 0..<blocksY {
                for bx in 0..<blocksX {
                    var pixels = [SIMD4<UInt8>](repeating: .zero, count: 16)
                    for py in 0..<blockSize {
                        let y = min(by * blockSize + py, height - 1)
                        for px in 0..<blockSize {
                            let x = min(bx * blockSize + px, width - 1)
                            let src = rgba + y * bytesPerRow + x * 4
                            pixels[py * blockSize + px] = SIMD4<UInt8>(src[0], src[1], src[2], src[3])
                        }
                    }
                    var block = encodeBlock(pixels)
                    withUnsafeBytes(of: &block) { blockBytes in
                        let src = blockBytes.bindMemory(to: UInt8.self)
                        for i in 0..<Self.blockBytes {
                            dest[destOffset + i] = src[i]
                        }
                    }
                    destOffset += Self.blockBytes
                }
            }
        }
        return out
    }

    /// Decodes one Mode 6 block to 16 RGBA pixels (row-major). Used by tests.
    static func decodeBC7Mode6Block(_ block: UnsafeRawPointer) -> [SIMD4<UInt8>] {
        var reader = BitReader(bytes: block)
        let mode = reader.read(7)
        precondition(mode == 0b1000000, "not a Mode 6 block")
        let r0 = reader.read(7)
        let r1 = reader.read(7)
        let g0 = reader.read(7)
        let g1 = reader.read(7)
        let b0 = reader.read(7)
        let b1 = reader.read(7)
        let a0 = reader.read(7)
        let a1 = reader.read(7)
        let p0 = reader.read(1)
        let p1 = reader.read(1)
        let e0 = SIMD4<Int>(
            Int((r0 << 1) | p0),
            Int((g0 << 1) | p0),
            Int((b0 << 1) | p0),
            Int((a0 << 1) | p0)
        )
        let e1 = SIMD4<Int>(
            Int((r1 << 1) | p1),
            Int((g1 << 1) | p1),
            Int((b1 << 1) | p1),
            Int((a1 << 1) | p1)
        )
        var indices = [Int](repeating: 0, count: 16)
        indices[0] = Int(reader.read(3))
        for i in 1..<16 {
            indices[i] = Int(reader.read(4))
        }
        return indices.map { index in
            let w = Int(Self.weights4[index])
            let c = (e0 &* (64 - w) &+ e1 &* w &+ SIMD4<Int>(repeating: 32)) &>> 6
            return SIMD4<UInt8>(
                UInt8(clamping: c.x),
                UInt8(clamping: c.y),
                UInt8(clamping: c.z),
                UInt8(clamping: c.w)
            )
        }
    }

    // MARK: - Mode 6 encode

    /// 4-bit BC7 interpolation weights.
    private static let weights4: [UInt8] = [
        0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64
    ]

    /// Picks the shared p-bit that reconstructs `endpoint` with the least L1 error.
    private static func bestPBit(_ endpoint: SIMD4<Int>) -> UInt32 {
        var best: UInt32 = 0
        var bestErr = Int.max
        for p in 0...1 {
            let q = applyPBit(endpoint, UInt32(p))
            let err = abs(q.x - endpoint.x) + abs(q.y - endpoint.y)
                + abs(q.z - endpoint.z) + abs(q.w - endpoint.w)
            if err < bestErr {
                bestErr = err
                best = UInt32(p)
            }
        }
        return best
    }

    private static func applyPBit(_ endpoint: SIMD4<Int>, _ p: UInt32) -> SIMD4<Int> {
        let bit = Int(p)
        return SIMD4<Int>(
            (endpoint.x & ~1) | bit,
            (endpoint.y & ~1) | bit,
            (endpoint.z & ~1) | bit,
            (endpoint.w & ~1) | bit
        )
    }

    private static func encodeBlock(_ pixels: [SIMD4<UInt8>]) -> (UInt64, UInt64) {
        var ep0 = SIMD4<Int>(repeating: 0)
        var ep1 = ep0
        var indices = [Int](repeating: 0, count: 16)
        var bestErr = Int.max
        let axes: [SIMD4<Int>] = [
            SIMD4(77, 150, 29, 0),
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(0, 0, 0, 1),
            SIMD4(1, 1, 1, 1)
        ]
        for axis in axes {
            var minC = SIMD4<Int>(Int(pixels[0].x), Int(pixels[0].y), Int(pixels[0].z), Int(pixels[0].w))
            var maxC = minC
            var minP = minC.x * axis.x + minC.y * axis.y + minC.z * axis.z + minC.w * axis.w
            var maxP = minP
            for p in pixels {
                let c = SIMD4<Int>(Int(p.x), Int(p.y), Int(p.z), Int(p.w))
                let proj = c.x * axis.x + c.y * axis.y + c.z * axis.z + c.w * axis.w
                if proj < minP { minP = proj; minC = c }
                if proj > maxP { maxP = proj; maxC = c }
            }
            var trial = [Int](repeating: 0, count: 16)
            let dir = maxC &- minC
            let len2 = max(1, dir.x * dir.x + dir.y * dir.y + dir.z * dir.z + dir.w * dir.w)
            var err = 0
            for i in 0..<16 {
                let p = pixels[i]
                let c = SIMD4<Int>(Int(p.x), Int(p.y), Int(p.z), Int(p.w))
                let t = min(1.0, max(0.0, Float((c &- minC).x * dir.x + (c &- minC).y * dir.y
                    + (c &- minC).z * dir.z + (c &- minC).w * dir.w) / Float(len2)))
                let idx = Int((t * 15.0).rounded())
                trial[i] = idx
                let w = Int(Self.weights4[idx])
                let recon = (minC &* (64 - w) &+ maxC &* w &+ SIMD4<Int>(repeating: 32)) &>> 6
                err += abs(recon.x - c.x) + abs(recon.y - c.y) + abs(recon.z - c.z) + abs(recon.w - c.w)
            }
            if err < bestErr {
                bestErr = err
                ep0 = minC
                ep1 = maxC
                indices = trial
            }
        }

        // Mode 6 stores pixel 0's index in 3 bits (MSB implicit 0). Swap
        // endpoints when that MSB would have been set.
        if indices[0] >= 8 {
            swap(&ep0, &ep1)
            for i in 0..<16 {
                indices[i] = 15 - indices[i]
            }
        }

        // One p-bit is shared across all four channels of an endpoint.
        let p0 = bestPBit(ep0)
        let p1 = bestPBit(ep1)
        ep0 = applyPBit(ep0, p0)
        ep1 = applyPBit(ep1, p1)

        var writer = BitWriter()
        writer.write(0b1000000, 7) // mode 6, LSB-first
        writer.write(UInt32(ep0.x >> 1), 7)
        writer.write(UInt32(ep1.x >> 1), 7)
        writer.write(UInt32(ep0.y >> 1), 7)
        writer.write(UInt32(ep1.y >> 1), 7)
        writer.write(UInt32(ep0.z >> 1), 7)
        writer.write(UInt32(ep1.z >> 1), 7)
        writer.write(UInt32(ep0.w >> 1), 7)
        writer.write(UInt32(ep1.w >> 1), 7)
        writer.write(UInt32(p0), 1)
        writer.write(UInt32(p1), 1)
        writer.write(UInt32(indices[0] & 0x7), 3)
        for i in 1..<16 {
            writer.write(UInt32(indices[i] & 0xF), 4)
        }
        return (writer.lo, writer.hi)
    }

    // MARK: - Bit packing

    private struct BitWriter {
        var lo: UInt64 = 0
        var hi: UInt64 = 0
        var pos: Int = 0

        mutating func write(_ raw: UInt32, _ bitCount: Int) {
            precondition(bitCount > 0 && bitCount <= 32)
            precondition(pos + bitCount <= 128)
            let mask: UInt64 = bitCount == 64 ? .max : (UInt64(1) << bitCount) - 1
            let value = UInt64(raw) & mask
            if pos < 64 {
                lo |= value << pos
                let overflow = pos + bitCount - 64
                if overflow > 0 {
                    hi |= value >> (bitCount - overflow)
                }
            } else {
                hi |= value << (pos - 64)
            }
            pos += bitCount
        }
    }

    private struct BitReader {
        let lo: UInt64
        let hi: UInt64
        var pos: Int = 0

        init(bytes: UnsafeRawPointer) {
            let words = bytes.bindMemory(to: UInt64.self, capacity: 2)
            lo = words[0]
            hi = words[1]
        }

        mutating func read(_ bitCount: Int) -> UInt32 {
            precondition(bitCount > 0 && bitCount <= 32)
            let mask: UInt64 = (UInt64(1) << bitCount) - 1
            let value: UInt64
            if pos < 64 {
                value = lo >> pos
                let overflow = pos + bitCount - 64
                if overflow > 0 {
                    let combined = value | (hi << (bitCount - overflow))
                    pos += bitCount
                    return UInt32(truncatingIfNeeded: combined & mask)
                }
            } else {
                value = hi >> (pos - 64)
            }
            pos += bitCount
            return UInt32(truncatingIfNeeded: value & mask)
        }
    }
}
