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

/// Uploads a decoded straight-alpha RGBA bitmap as a fully mipmapped Metal
/// texture.
///
/// Used when the glTF sampler asks for a mip chain (a `*_MIPMAP_*`
/// `minFilter`, or no stated preference — see
/// ``TextureLoader/samplerRequestsMipmaps(_:)``). ``TextureUploader``'s
/// single-level upload is the counterpart for samplers that decline one.
///
/// Three properties the chain must hold:
///
/// 1. **Level 0 is the decoded image, byte for byte.** The decode seam
///    already stores exactly the bytes the source image holds — including
///    authored color under fully transparent texels — and building a mip
///    chain must not reintroduce a premultiply round trip at the one level
///    whose bytes have a ground truth.
/// 2. **Downscaling is alpha-weighted where alpha is coverage — and only
///    there.** For a base-color texture on a MASK/BLEND material,
///    averaging straight RGBA drags fully transparent texels' RGB (usually
///    black) into every soft edge at every level below 0; weighting by
///    coverage is the standard fix (premultiply, average, unpremultiply).
///    For every other texture alpha is not coverage — metallic-roughness
///    (G/B data, alpha unused), occlusion (R), normal, emissive, and
///    OPAQUE base color (alpha ignored by the spec) — and weighting by it
///    would bias or erase real data (a legal all-zero-alpha
///    metallic-roughness texture would lose every mip). Those filter each
///    channel independently, exactly as GPU mip generation does. The
///    caller says which (`alphaIsCoverage`); the loaders decide from the
///    document — see ``TextureLoader/textureAlphaIsCoverage(_:in:)``.
/// 3. **Downscaling happens in linear light.** Metal decodes `_srgb` texels
///    to linear intensity when sampling, so the average the sampler will
///    see is a linear-space quantity. Averaging the sRGB-encoded bytes
///    instead darkens minified content — a black/white pair averages to
///    encoded 128, which decodes to ~0.22 linear instead of the correct
///    0.5 (encoded ~188).
///
/// Each level is therefore filtered from the level above it: the source
/// texels are decoded to linear light (sRGB→linear where the pixel format
/// says so), premultiplied by alpha when alpha is coverage, area-averaged
/// in float, then unpremultiplied (coverage only), re-encoded, and
/// quantized for upload. The average is
/// the exact area (box) average — 2×2 taps for even dimensions, and for
/// odd ones the 3-tap polyphase weights whose footprints tile the source
/// exactly (`3×3 → 1×1` sees all nine texels) — so the alpha-weighted mean
/// of every level equals the level above it to within one 8-bit rounding,
/// with no resampling-kernel ringing. Filtering from the previous
/// *uploaded* level rather than a full-resolution float chain keeps the
/// transient footprint to the encoded level being read plus the one
/// being built — ~20 MiB of scratch for a 4096² source (16 + 4 at level
/// 2) instead of ~330 MiB of float (measured peak resident delta
/// 428 → 108 MiB, most of the remainder being the texture itself) —
/// which is what the GPU blit path would do too; the per-level 8-bit
/// rounding this admits is unbiased and sub-perceptual (see the
/// mean-conservation test's tolerance). One consequence worth naming:
/// below level 0 of a coverage texture, a fully transparent texel's
/// authored color has zero weight and cannot survive the average — that is
/// the semantics of coverage weighting, not a decode loss.
enum TextureMipUploader {

    /// Creates a fully mipmapped texture from straight-alpha RGBA8888 bytes.
    ///
    /// - Parameters:
    ///   - straightData: Decoded straight-alpha bitmap (RGBA, 4 bytes per
    ///     pixel). Uploaded verbatim as level 0; never mutated.
    ///   - width: Bitmap width in pixels.
    ///   - height: Bitmap height in pixels.
    ///   - bytesPerRow: Row stride of `straightData` in bytes (rows may be
    ///     padded, e.g. by `vImageBuffer_InitWithCGImage`).
    ///   - pixelFormat: `.rgba8Unorm` or `.rgba8Unorm_srgb`. Decides whether
    ///     the RGB channels are sRGB-decoded for filtering and re-encoded
    ///     for upload; alpha is linear either way.
    ///   - alphaIsCoverage: `true` to weight RGB by alpha when filtering
    ///     (base color of a MASK/BLEND material); `false` to filter every
    ///     channel independently (data textures, OPAQUE color).
    ///   - device: Device to allocate on.
    /// - Returns: A texture with a full mip chain and straight alpha at
    ///   every level, or `nil` on allocation failure.
    static func makeTexture(straightData: UnsafeRawPointer,
                            width: Int, height: Int,
                            bytesPerRow: Int,
                            pixelFormat: MTLPixelFormat,
                            alphaIsCoverage: Bool,
                            device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: true
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0,
                        withBytes: straightData,
                        bytesPerRow: bytesPerRow)
        guard texture.mipmapLevelCount > 1 else { return texture }

        let srgb = pixelFormat == .rgba8Unorm_srgb

        // Level 1 filters the caller's bytes (honoring their row stride);
        // every later level filters the bytes just uploaded for the level
        // above it, so only that level and the one being built are alive.
        var previous: [UInt8] = []
        var w = width, h = height
        for level in 1..<texture.mipmapLevelCount {
            let nw = max(1, w / 2), nh = max(1, h / 2)
            let encoded: [UInt8]
            if level == 1 {
                encoded = downsample(source: straightData.assumingMemoryBound(to: UInt8.self),
                                     bytesPerRow: bytesPerRow,
                                     width: w, height: h, to: nw, nh,
                                     srgb: srgb, alphaIsCoverage: alphaIsCoverage)
            } else {
                encoded = previous.withUnsafeBufferPointer { src in
                    downsample(source: src.baseAddress!, bytesPerRow: w * 4,
                               width: w, height: h, to: nw, nh,
                               srgb: srgb, alphaIsCoverage: alphaIsCoverage)
                }
            }
            encoded.withUnsafeBytes { buf in
                texture.replace(region: MTLRegionMake2D(0, 0, nw, nh),
                                mipmapLevel: level,
                                withBytes: buf.baseAddress!,
                                bytesPerRow: nw * 4)
            }
            previous = encoded
            w = nw; h = nh
        }
        return texture
    }

    // MARK: - Area-weighted downsample

    /// Filters one straight-alpha RGBA8 level into the next: decode taps to
    /// linear light, area-average, re-encode — with RGB weighted by alpha
    /// (premultiply / unpremultiply around the average) when
    /// `alphaIsCoverage`, and each channel filtered independently otherwise.
    /// `nw`/`nh` must be `max(1, w/2)` / `max(1, h/2)`.
    private static func downsample(source: UnsafePointer<UInt8>, bytesPerRow: Int,
                                   width w: Int, height h: Int,
                                   to nw: Int, _ nh: Int,
                                   srgb: Bool, alphaIsCoverage: Bool) -> [UInt8] {
        let decode = srgb ? srgbDecode : unormDecode
        let xTaps = boxTaps(source: w, dest: nw)
        let yTaps = boxTaps(source: h, dest: nh)
        var out = [UInt8](repeating: 0, count: nw * nh * 4)
        out.withUnsafeMutableBufferPointer { dst in
            for y in 0..<nh {
                for x in 0..<nw {
                    // RGB accumulate at weight w·alpha (coverage) or w
                    // (independent); `norm` is the matching RGB divisor
                    // (= alpha sum, resp. 1). Alpha always averages plainly.
                    var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0, norm: Float = 0
                    for ty in 0..<yTaps.count {
                        let row = source + yTaps.index[y * yTaps.count + ty] * bytesPerRow
                        let wy = yTaps.weight[y * yTaps.count + ty]
                        for tx in 0..<xTaps.count {
                            let s = row + xTaps.index[x * xTaps.count + tx] * 4
                            let wgt = wy * xTaps.weight[x * xTaps.count + tx]
                            let alpha = Float(s[3]) / 255
                            let wc = alphaIsCoverage ? wgt * alpha : wgt
                            r += decode[Int(s[0])] * wc
                            g += decode[Int(s[1])] * wc
                            b += decode[Int(s[2])] * wc
                            norm += wc
                            a += wgt * alpha
                        }
                    }
                    let d = (y * nw + x) * 4
                    let inv: Float = norm > 0 ? 1 / norm : 0
                    dst[d + 0] = encode(r * inv, srgb: srgb)
                    dst[d + 1] = encode(g * inv, srgb: srgb)
                    dst[d + 2] = encode(b * inv, srgb: srgb)
                    dst[d + 3] = UInt8((min(max(a, 0), 1) * 255).rounded())
                }
            }
        }
        return out
    }

    /// Per-axis taps of the exact area average from `source` texels to
    /// `dest = max(1, source/2)`. Even: two taps at 1/2 each. Odd (≥3):
    /// three taps — dest texel `x` covers source `2x, 2x+1, 2x+2` with
    /// weights `(dest−x)/source, dest/source, (x+1)/source` (they sum to 1,
    /// and adjacent footprints share the odd texel exactly, so every source
    /// texel's total weight across the level is the same). `source == 1`:
    /// one tap. Flat arrays, `count` taps per dest texel.
    static func boxTaps(source: Int, dest: Int) -> (index: [Int], weight: [Float], count: Int) {
        precondition(dest == max(1, source / 2), "dest must be the next mip size of source")
        if source == 1 {
            return ([0], [1], 1)
        }
        if source == 2 * dest {
            var index = [Int](), weight = [Float]()
            index.reserveCapacity(dest * 2); weight.reserveCapacity(dest * 2)
            for x in 0..<dest {
                index.append(2 * x); index.append(2 * x + 1)
                weight.append(0.5); weight.append(0.5)
            }
            return (index, weight, 2)
        }
        // source == 2 * dest + 1
        var index = [Int](), weight = [Float]()
        index.reserveCapacity(dest * 3); weight.reserveCapacity(dest * 3)
        let inv = 1 / Float(source)
        for x in 0..<dest {
            index.append(2 * x); index.append(2 * x + 1); index.append(2 * x + 2)
            weight.append(Float(dest - x) * inv)
            weight.append(Float(dest) * inv)
            weight.append(Float(x + 1) * inv)
        }
        return (index, weight, 3)
    }

    @inline(__always)
    private static func encode(_ linear: Float, srgb: Bool) -> UInt8 {
        let v = srgb ? srgbEncodeFast(linear) : linear
        return UInt8((min(max(v, 0), 1) * 255).rounded())
    }

    // MARK: - sRGB transfer function (IEC 61966-2-1)

    private static let unormDecode: [Float] = (0...255).map { Float($0) / 255 }

    private static let srgbDecode: [Float] = (0...255).map { v in
        let s = Float(v) / 255
        return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }

    static func srgbEncode(_ linear: Float) -> Float {
        linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
    }

    /// Linear→sRGB via a piecewise-linear table (4096 segments over [0, 1]).
    /// The transfer curve's second derivative is largest near 0, where the
    /// table's absolute error is still < 1e-4 encoded (< 0.03 of an 8-bit
    /// step) — well inside `.rounded()`; the exact `pow` form above is the
    /// reference the table is built from. Saves one `pow` per output
    /// channel per texel, which dominates the chain's CPU time.
    private static let srgbEncodeTable: [Float] = (0...4096).map { srgbEncode(Float($0) / 4096) }

    @inline(__always)
    static func srgbEncodeFast(_ linear: Float) -> Float {
        let x = min(max(linear, 0), 1) * 4096
        let i = Int(x)
        if i >= 4096 { return 1 }
        let f = x - Float(i)
        return srgbEncodeTable[i] + (srgbEncodeTable[i + 1] - srgbEncodeTable[i]) * f
    }
}
