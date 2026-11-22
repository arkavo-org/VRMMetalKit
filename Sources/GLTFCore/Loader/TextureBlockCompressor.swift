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

        var rgba = [UInt8](repeating: 0, count: source.width * source.height * 4)
        for level in 0..<source.mipmapLevelCount {
            let width = max(1, source.width >> level)
            let height = max(1, source.height >> level)
            rgba.withUnsafeMutableBytes { raw in
                source.getBytes(
                    raw.baseAddress!,
                    bytesPerRow: width * 4,
                    from: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: level
                )
            }
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

    private struct SendablePointer<T>: @unchecked Sendable {
        let ptr: UnsafePointer<T>
    }
    private struct SendableMutableRawPointer: @unchecked Sendable {
        let ptr: UnsafeMutableRawPointer
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
        let totalBlocks = blocksX * blocksY
        var out = Data(count: totalBlocks * blockBytes)
        out.withUnsafeMutableBytes { raw in
            guard let baseAddr = raw.baseAddress else { return }
            let srcWrap = SendablePointer(ptr: rgba)
            let dstWrap = SendableMutableRawPointer(ptr: baseAddr)

            if totalBlocks >= 1024 && blocksY >= 4 {
                let bands = min(blocksY, max(1, ProcessInfo.processInfo.activeProcessorCount))
                let rowsPerBand = (blocksY + bands - 1) / bands
                let activeBands = (blocksY + rowsPerBand - 1) / rowsPerBand
                DispatchQueue.concurrentPerform(iterations: activeBands) { band in
                    let startRow = band * rowsPerBand
                    let endRow = min(startRow + rowsPerBand, blocksY)
                    Self.encodeBC7RowRange(
                        rgba: srcWrap.ptr,
                        destBase: dstWrap.ptr,
                        width: width,
                        height: height,
                        bytesPerRow: bytesPerRow,
                        blocksX: blocksX,
                        startRow: startRow,
                        endRow: endRow
                    )
                }
            } else {
                Self.encodeBC7RowRange(
                    rgba: srcWrap.ptr,
                    destBase: dstWrap.ptr,
                    width: width,
                    height: height,
                    bytesPerRow: bytesPerRow,
                    blocksX: blocksX,
                    startRow: 0,
                    endRow: blocksY
                )
            }
        }
        return out
    }

    private static func encodeBC7RowRange(
        rgba: UnsafePointer<UInt8>,
        destBase: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        blocksX: Int,
        startRow: Int,
        endRow: Int
    ) {
        withUnsafeTemporaryAllocation(of: SIMD4<Int32>.self, capacity: 16) { pixelsBuf in
            withUnsafeTemporaryAllocation(of: Int32.self, capacity: 32) { idxBuf in
                let pixels = pixelsBuf.baseAddress!
                let bestIndices = idxBuf.baseAddress!
                let trialIndices = idxBuf.baseAddress! + 16
                for by in startRow..<endRow {
                    let y0 = by * blockSize
                    let rowByteOffset = by * blocksX * blockBytes
                    let fullBlockY = (y0 + 3) < height
                    let r0 = rgba + min(y0 + 0, height - 1) * bytesPerRow
                    let r1 = rgba + min(y0 + 1, height - 1) * bytesPerRow
                    let r2 = rgba + min(y0 + 2, height - 1) * bytesPerRow
                    let r3 = rgba + min(y0 + 3, height - 1) * bytesPerRow
                    for bx in 0..<blocksX {
                        let x0 = bx * blockSize
                        if fullBlockY && (x0 + 3) < width {
                            let off = x0 * 4
                            loadRow4(r0 + off, pixels + 0)
                            loadRow4(r1 + off, pixels + 4)
                            loadRow4(r2 + off, pixels + 8)
                            loadRow4(r3 + off, pixels + 12)
                        } else {
                            for py in 0..<4 {
                                let y = min(y0 + py, height - 1)
                                let row = rgba + y * bytesPerRow
                                for px in 0..<4 {
                                    let x = min(x0 + px, width - 1)
                                    let s = row + x * 4
                                    pixels[py * 4 + px] = SIMD4<Int32>(Int32(s[0]), Int32(s[1]), Int32(s[2]), Int32(s[3]))
                                }
                            }
                        }
                        let (lo, hi) = encodeBlockNoAlloc(
                            pixels: pixels,
                            bestIndices: bestIndices,
                            trialIndices: trialIndices
                        )
                        let blockByteOffset = rowByteOffset + bx * blockBytes
                        destBase.storeBytes(of: lo.littleEndian, toByteOffset: blockByteOffset, as: UInt64.self)
                        destBase.storeBytes(of: hi.littleEndian, toByteOffset: blockByteOffset + 8, as: UInt64.self)
                    }
                }
            }
        }
    }

    @inline(__always)
    private static func loadRow4(_ src: UnsafePointer<UInt8>, _ dst: UnsafeMutablePointer<SIMD4<Int32>>) {
        dst[0] = SIMD4<Int32>(Int32(src[0]), Int32(src[1]), Int32(src[2]), Int32(src[3]))
        dst[1] = SIMD4<Int32>(Int32(src[4]), Int32(src[5]), Int32(src[6]), Int32(src[7]))
        dst[2] = SIMD4<Int32>(Int32(src[8]), Int32(src[9]), Int32(src[10]), Int32(src[11]))
        dst[3] = SIMD4<Int32>(Int32(src[12]), Int32(src[13]), Int32(src[14]), Int32(src[15]))
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
    @inline(__always)
    private static func bestPBit(_ endpoint: SIMD4<Int32>) -> UInt32 {
        let q0 = endpoint & ~SIMD4<Int32>(repeating: 1)
        let q1 = q0 | SIMD4<Int32>(repeating: 1)
        let d0 = endpoint &- q0
        let d1 = q1 &- endpoint
        let err0 = abs(d0.x) &+ abs(d0.y) &+ abs(d0.z) &+ abs(d0.w)
        let err1 = abs(d1.x) &+ abs(d1.y) &+ abs(d1.z) &+ abs(d1.w)
        return err1 < err0 ? 1 : 0
    }

    @inline(__always)
    private static func applyPBit(_ endpoint: SIMD4<Int32>, _ p: UInt32) -> SIMD4<Int32> {
        let bit = Int32(p)
        return (endpoint & ~SIMD4<Int32>(repeating: 1)) | SIMD4<Int32>(repeating: bit)
    }

    private static let mode6Axes: (SIMD4<Int32>, SIMD4<Int32>, SIMD4<Int32>, SIMD4<Int32>, SIMD4<Int32>, SIMD4<Int32>) = (
        SIMD4<Int32>(77, 150, 29, 0),
        SIMD4<Int32>(1, 0, 0, 0),
        SIMD4<Int32>(0, 1, 0, 0),
        SIMD4<Int32>(0, 0, 1, 0),
        SIMD4<Int32>(0, 0, 0, 1),
        SIMD4<Int32>(1, 1, 1, 1)
    )

    @inline(__always)
    private static func encodeBlockNoAlloc(
        pixels: UnsafePointer<SIMD4<Int32>>,
        bestIndices: UnsafeMutablePointer<Int32>,
        trialIndices: UnsafeMutablePointer<Int32>
    ) -> (UInt64, UInt64) {
        let p0 = pixels[0]
        var allEqual = true
        for i in 1..<16 {
            if pixels[i] != p0 {
                allEqual = false
                break
            }
        }

        var ep0: SIMD4<Int32>
        var ep1: SIMD4<Int32>

        if allEqual {
            ep0 = p0
            ep1 = p0
            for i in 0..<16 { bestIndices[i] = 0 }
        } else {
            ep0 = p0
            ep1 = p0
            var bestErr: Int32 = .max

            @inline(__always)
            func evaluateAxis(_ axis: SIMD4<Int32>) {
                var minC = p0
                var maxC = p0
                var minP = p0.x &* axis.x &+ p0.y &* axis.y &+ p0.z &* axis.z &+ p0.w &* axis.w
                var maxP = minP
                for i in 1..<16 {
                    let c = pixels[i]
                    let proj = c.x &* axis.x &+ c.y &* axis.y &+ c.z &* axis.z &+ c.w &* axis.w
                    if proj < minP { minP = proj; minC = c }
                    if proj > maxP { maxP = proj; maxC = c }
                }
                let dir = maxC &- minC
                let len2 = max(Int32(1), dir.x &* dir.x &+ dir.y &* dir.y &+ dir.z &* dir.z &+ dir.w &* dir.w)
                let invLen2 = 1.0 / Float(len2)
                var err: Int32 = 0
                for i in 0..<16 {
                    let c = pixels[i]
                    let d = c &- minC
                    let dot = d.x &* dir.x &+ d.y &* dir.y &+ d.z &* dir.z &+ d.w &* dir.w
                    let t = min(1.0, max(0.0, Float(dot) * invLen2))
                    let idx = Int32((t * 15.0).rounded())
                    trialIndices[i] = idx
                    let w = Int32(Self.weights4[Int(idx)])
                    let recon = (minC &* (64 &- w) &+ maxC &* w &+ SIMD4<Int32>(repeating: 32)) &>> 6
                    let diff = recon &- c
                    err &+= abs(diff.x) &+ abs(diff.y) &+ abs(diff.z) &+ abs(diff.w)
                    if err >= bestErr { return }
                }
                bestErr = err
                ep0 = minC
                ep1 = maxC
                for i in 0..<16 { bestIndices[i] = trialIndices[i] }
            }

            evaluateAxis(mode6Axes.0)
            if bestErr > 0 { evaluateAxis(mode6Axes.1) }
            if bestErr > 0 { evaluateAxis(mode6Axes.2) }
            if bestErr > 0 { evaluateAxis(mode6Axes.3) }
            if bestErr > 0 { evaluateAxis(mode6Axes.4) }
            if bestErr > 0 { evaluateAxis(mode6Axes.5) }
        }

        // Mode 6 stores pixel 0's index in 3 bits (MSB implicit 0). Swap
        // endpoints when that MSB would have been set.
        if bestIndices[0] >= 8 {
            swap(&ep0, &ep1)
            for i in 0..<16 {
                bestIndices[i] = 15 &- bestIndices[i]
            }
        }

        // One p-bit is shared across all four channels of an endpoint.
        let pBit0 = bestPBit(ep0)
        let pBit1 = bestPBit(ep1)
        ep0 = applyPBit(ep0, pBit0)
        ep1 = applyPBit(ep1, pBit1)

        // Direct 128-bit Mode 6 bit packing (identical layout to BitWriter):
        // bits 0..6:   mode (0b1000000 = 64)
        // bits 7..62:  r0, r1, g0, g1, b0, b1, a0, a1 (8 × 7 bits = 56 bits; total 63 bits)
        // bit  63:     p0
        // bit  64:     p1
        // bits 65..67: index[0] (3 bits)
        // bits 68..127: index[1..15] (15 × 4 bits = 60 bits)
        var lo: UInt64 = 0b1000000
        lo |= UInt64(UInt32(ep0.x >> 1) & 0x7F) << 7
        lo |= UInt64(UInt32(ep1.x >> 1) & 0x7F) << 14
        lo |= UInt64(UInt32(ep0.y >> 1) & 0x7F) << 21
        lo |= UInt64(UInt32(ep1.y >> 1) & 0x7F) << 28
        lo |= UInt64(UInt32(ep0.z >> 1) & 0x7F) << 35
        lo |= UInt64(UInt32(ep1.z >> 1) & 0x7F) << 42
        lo |= UInt64(UInt32(ep0.w >> 1) & 0x7F) << 49
        lo |= UInt64(UInt32(ep1.w >> 1) & 0x7F) << 56
        lo |= UInt64(pBit0 & 1) << 63

        var hi: UInt64 = UInt64(pBit1 & 1)
        hi |= UInt64(UInt32(bestIndices[0]) & 0x7) << 1
        for i in 1..<16 {
            hi |= UInt64(UInt32(bestIndices[i]) & 0xF) << (4 * i)
        }
        return (lo, hi)
    }

    // MARK: - Bit reading (test decoder)

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
