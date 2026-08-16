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
import Metal
@testable import GLTFCore

/// Invariance checks for the mipmapped upload path.
///
/// The contract is: straight-alpha bytes in (the decode seam's output —
/// exactly the bytes the source image holds), texture whose EVERY mip level
/// stores straight alpha out, with each level 1+ area-averaged from the
/// level above it in float, linear-light space — premultiplied when the
/// caller says alpha is coverage, per-channel independent otherwise. These
/// tests pin the properties that make the chain an alpha-edge fix and not
/// a tone shift (or a data corruption):
///
/// 1. Level 0 stores the input bytes verbatim — building a mip chain must
///    not reintroduce the premultiply round trip that
///    `StraightAlphaDecodeTests` pins the decode against.
/// 2. The alpha-weighted (premultiplied) mean color of every mip level
///    matches level 0 — the box average is the exact area average, so
///    downscaling redistributes energy without creating or destroying it,
///    including for isolated single-texel features (where a ringing
///    resampling kernel inflates coverage by ~40% and then clips) and for
///    odd dimensions (where a naive 2×2 step silently drops the last
///    row/column — `3×3 → 1×1` must see all nine texels).
/// 3. sRGB content is averaged in linear light — the average Metal's
///    sampler will reconstruct — not on the encoded bytes, which darkens
///    minified color content.
/// 4. Transparent texels' RGB never bleeds into visible texels at any
///    level (the artifact alpha-weighted averaging exists to prevent) —
///    for coverage textures.
/// 5. Alpha weighting is opt-in: a data texture (metallic-roughness,
///    occlusion, …) whose alpha is unrelated or all-zero must filter every
///    channel independently, or its real channels get biased or erased.
final class TextureMipUploaderTests: XCTestCase {

    private var device: MTLDevice!

    override func setUp() {
        device = MTLCreateSystemDefaultDevice()
    }

    // MARK: - Helpers

    /// Deterministic pseudo-random straight-alpha RGBA image, as the decode
    /// seam would produce it. SplitMix64 so runs are identical everywhere.
    private func makeSyntheticStraight(width: Int, height: Int) -> [UInt8] {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for p in 0..<(width * height) {
            let r = next()
            // Straight alpha: channels are free to exceed alpha.
            data[p * 4 + 0] = UInt8(truncatingIfNeeded: r)
            data[p * 4 + 1] = UInt8(truncatingIfNeeded: r >> 8)
            data[p * 4 + 2] = UInt8(truncatingIfNeeded: r >> 16)
            data[p * 4 + 3] = UInt8(truncatingIfNeeded: r >> 24)
        }
        return data
    }

    private func makeTexture(from straight: [UInt8], width: Int, height: Int,
                             pixelFormat: MTLPixelFormat = .rgba8Unorm,
                             alphaIsCoverage: Bool) throws -> MTLTexture {
        guard let device else { throw XCTSkip("Metal device not available") }
        let texture = straight.withUnsafeBytes { buf in
            TextureMipUploader.makeTexture(
                straightData: buf.baseAddress!,
                width: width, height: height,
                bytesPerRow: width * 4,
                pixelFormat: pixelFormat,
                alphaIsCoverage: alphaIsCoverage, device: device)
        }
        return try XCTUnwrap(texture, "makeTexture returned nil")
    }

    private func readLevel(_ texture: MTLTexture, _ level: Int) -> (bytes: [UInt8], w: Int, h: Int) {
        let w = max(1, texture.width >> level)
        let h = max(1, texture.height >> level)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!, bytesPerRow: w * 4,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: level)
        }
        return (out, w, h)
    }

    /// Mean premultiplied color (r·a, g·a, b·a, a) of straight-alpha bytes,
    /// in [0, 255] units. Premultiplied space is where "image energy" lives:
    /// it is what blending composites and what alpha-weighted downscaling
    /// must conserve.
    private func premultipliedMean(straight: [UInt8], pixels: Int) -> (r: Double, g: Double, b: Double, a: Double) {
        var r = 0.0, g = 0.0, b = 0.0, a = 0.0
        for p in 0..<pixels {
            let alpha = Double(straight[p * 4 + 3]) / 255.0
            r += Double(straight[p * 4 + 0]) * alpha
            g += Double(straight[p * 4 + 1]) * alpha
            b += Double(straight[p * 4 + 2]) * alpha
            a += Double(straight[p * 4 + 3])
        }
        let n = Double(pixels)
        return (r / n, g / n, b / n, a / n)
    }

    // MARK: - Tests

    /// Level 0 must store the decoded bytes verbatim — including channels
    /// above alpha (unrepresentable premultiplied) and authored color under
    /// fully transparent texels (destroyed by any premultiply round trip).
    /// This is the mip-path half of the exactness `StraightAlphaDecodeTests`
    /// pins for the single-level path.
    func testLevelZeroStoresDecodedBytesVerbatim() throws {
        let w = 8, h = 8
        var straight = [UInt8](repeating: 0, count: w * h * 4)
        for p in 0..<(w * h) {
            switch p % 4 {
            case 0: straight.replaceSubrange(p * 4..<(p * 4 + 4), with: [250, 240, 230, 8])   // white-ish art at low coverage
            case 1: straight.replaceSubrange(p * 4..<(p * 4 + 4), with: [255, 0, 128, 1])     // channels far above alpha
            case 2: straight.replaceSubrange(p * 4..<(p * 4 + 4), with: [200, 100, 50, 0])    // color under full transparency
            default: straight.replaceSubrange(p * 4..<(p * 4 + 4), with: [128, 128, 128, 255]) // opaque
            }
        }
        for coverage in [true, false] {
            let texture = try makeTexture(from: straight, width: w, height: h, alphaIsCoverage: coverage)
            XCTAssertGreaterThan(texture.mipmapLevelCount, 1)
            XCTAssertEqual(readLevel(texture, 0).bytes, straight,
                           "Level 0 (alphaIsCoverage=\(coverage)) differs from the decoded input — the mip path round-tripped through premultiplied bytes")
        }
    }

    /// Every mip level's premultiplied mean must match level 0's: the chain
    /// redistributes color, it must not darken (the rgb·a² bug) or brighten.
    func testMipChainPreservesMeanColor() throws {
        let w = 128, h = 128
        let straight = makeSyntheticStraight(width: w, height: h)
        let texture = try makeTexture(from: straight, width: w, height: h, alphaIsCoverage: true)

        let level0 = readLevel(texture, 0)
        let reference = premultipliedMean(straight: level0.bytes, pixels: level0.w * level0.h)

        // The box average is exact in float; each level is filtered from
        // the level above it, so the read-back carries one unbiased 8-bit
        // rounding per level and means over ≥64 texels sit well inside
        // half a byte.
        for level in 1...4 {
            let mip = readLevel(texture, level)
            let mean = premultipliedMean(straight: mip.bytes, pixels: mip.w * mip.h)
            XCTAssertEqual(mean.r, reference.r, accuracy: 0.75, "level \(level) red mean drifted")
            XCTAssertEqual(mean.g, reference.g, accuracy: 0.75, "level \(level) green mean drifted")
            XCTAssertEqual(mean.b, reference.b, accuracy: 0.75, "level \(level) blue mean drifted")
            XCTAssertEqual(mean.a, reference.a, accuracy: 0.75, "level \(level) alpha mean drifted")
        }
    }

    /// The adversarial case for kernel choice: a single opaque texel in a
    /// transparent field. A ringing resampler (Lanczos) redistributes its
    /// energy into negative-lobe neighbors and clips, inflating first-mip
    /// coverage by ~40%; the exact 2×2 box average puts all of it in one
    /// texel at exactly a quarter weight, at every level down.
    func testSingleTexelFeatureConservesCoverageExactly() throws {
        let w = 4, h = 4
        var straight = [UInt8](repeating: 0, count: w * h * 4)
        let p = (1 * w + 1) * 4
        straight[p + 0] = 255
        straight[p + 3] = 255

        let texture = try makeTexture(from: straight, width: w, height: h, alphaIsCoverage: true)

        let level1 = readLevel(texture, 1)
        var expected1 = [UInt8](repeating: 0, count: 2 * 2 * 4)
        expected1[0] = 255  // straight red survives unpremultiply exactly
        expected1[3] = 64   // alpha 255/4 = 63.75 → 64
        XCTAssertEqual(level1.bytes, expected1,
                       "First mip of a single-texel feature must be its exact quarter-weight box average")

        let level2 = readLevel(texture, 2)
        XCTAssertEqual(Array(level2.bytes), [255, 0, 0, 16],
                       "Second mip must keep exact area weight (255/16 ≈ 16), not kernel-inflated coverage")
    }

    /// Odd dimensions: the last row and column are real texels and must
    /// carry their area weight. `3×3 → 1×1` with the only opaque texel at
    /// the far corner: a 2×2 step that only reads the upper-left block
    /// yields a fully transparent mip; the area average is alpha 255/9 ≈ 28
    /// of pure red.
    func testOddDimensionsKeepTheLastRowAndColumn() throws {
        let w = 3, h = 3
        var straight = [UInt8](repeating: 0, count: w * h * 4)
        let p = (2 * w + 2) * 4
        straight[p + 0] = 255
        straight[p + 3] = 255

        let texture = try makeTexture(from: straight, width: w, height: h, alphaIsCoverage: true)
        XCTAssertEqual(texture.mipmapLevelCount, 2)
        XCTAssertEqual(readLevel(texture, 1).bytes, [255, 0, 0, 28],
                       "3×3 → 1×1 dropped the trailing row/column — mean not conserved for odd dimensions")
    }

    /// Mixed parity, two levels deep: `5×3 → 2×1 → 1×1`. The opaque texel
    /// sits at (4, 2), the far corner. Column taps for dest 1 are
    /// (1/5, 2/5, 2/5) over source columns 2..4 and the single row tap is
    /// 1/3 each, so level 1 is `[transparent, red at 255·(2/5)(1/3) ≈ 34]`
    /// and level 2 halves that to 17 — the premultiplied mean 255/15 = 17
    /// holds at every level.
    func testMixedParityChainConservesMean() throws {
        let w = 5, h = 3
        var straight = [UInt8](repeating: 0, count: w * h * 4)
        let p = (2 * w + 4) * 4
        straight[p + 0] = 255
        straight[p + 3] = 255

        let texture = try makeTexture(from: straight, width: w, height: h, alphaIsCoverage: true)
        XCTAssertEqual(texture.mipmapLevelCount, 3)
        XCTAssertEqual(readLevel(texture, 1).bytes, [0, 0, 0, 0, 255, 0, 0, 34],
                       "5×3 → 2×1: the far-corner texel must land in dest 1 at weight (2/5)(1/3)")
        XCTAssertEqual(readLevel(texture, 2).bytes, [255, 0, 0, 17],
                       "2×1 → 1×1: half of 34")

        let reference = premultipliedMean(straight: straight, pixels: w * h)
        for level in 1...2 {
            let mip = readLevel(texture, level)
            let mean = premultipliedMean(straight: mip.bytes, pixels: mip.w * mip.h)
            XCTAssertEqual(mean.a, reference.a, accuracy: 0.5, "level \(level) alpha mean drifted")
            XCTAssertEqual(mean.r, reference.r, accuracy: 0.5, "level \(level) red mean drifted")
        }
    }

    /// The per-axis taps must partition the source: every dest texel's
    /// weights sum to 1, and every source texel receives the same total
    /// weight (`dest/source`) across the level — the property that makes
    /// the level mean equal the source mean for any dimension.
    func testBoxTapsPartitionTheSourceForEveryDimension() {
        for source in 1...33 {
            let dest = max(1, source / 2)
            let taps = TextureMipUploader.boxTaps(source: source, dest: dest)
            XCTAssertEqual(taps.index.count, dest * taps.count)
            var perSource = [Float](repeating: 0, count: source)
            for x in 0..<dest {
                var sum: Float = 0
                for t in 0..<taps.count {
                    let i = taps.index[x * taps.count + t]
                    XCTAssertTrue((0..<source).contains(i), "source \(source): tap index \(i) out of range")
                    sum += taps.weight[x * taps.count + t]
                    perSource[i] += taps.weight[x * taps.count + t]
                }
                XCTAssertEqual(sum, 1, accuracy: 1e-6, "source \(source) dest \(x): weights don't sum to 1")
            }
            for (i, total) in perSource.enumerated() {
                XCTAssertEqual(total, Float(dest) / Float(source), accuracy: 1e-6,
                               "source \(source): texel \(i) weighted \(total), not dest/source")
            }
        }
    }


    /// Alpha weighting is opt-in. A metallic-roughness texture carries
    /// roughness in G and metallic in B; its alpha is unused by the spec and
    /// may hold anything — here two texels at alpha 0 and two at 255 with
    /// DIFFERENT roughness. Filtered independently, level 1 is the plain
    /// average of every channel (G 150, A 128). Weighted by alpha it would
    /// be biased to the opaque texels' roughness (G 100) — real data lost to
    /// a channel that means nothing here.
    func testDataTextureFiltersChannelsIndependently() throws {
        let w = 2, h = 2
        var straight = [UInt8](repeating: 0, count: w * h * 4)
        for p in 0..<(w * h) {
            let opaque = p >= 2
            straight[p * 4 + 1] = opaque ? 100 : 200   // roughness
            straight[p * 4 + 2] = opaque ? 40 : 80     // metallic
            straight[p * 4 + 3] = opaque ? 255 : 0     // unrelated alpha
        }
        let independent = try makeTexture(from: straight, width: w, height: h, alphaIsCoverage: false)
        XCTAssertEqual(readLevel(independent, 1).bytes, [0, 150, 60, 128],
                       "Data texture mip must be the plain per-channel average — alpha is not coverage here")

        let weighted = try makeTexture(from: straight, width: w, height: h, alphaIsCoverage: true)
        XCTAssertEqual(readLevel(weighted, 1).bytes, [0, 100, 40, 128],
                       "(Contrast: with alphaIsCoverage the transparent texels' data would be discarded)")
    }

    /// The erasure case: a legal metallic-roughness texture with alpha 0
    /// everywhere (some exporters leave the channel zeroed). Independent
    /// filtering keeps G/B intact at every level; alpha weighting would
    /// zero every mip below 0.
    func testZeroAlphaDataTextureKeepsItsChannels() throws {
        let w = 8, h = 8
        var straight = [UInt8](repeating: 0, count: w * h * 4)
        for p in 0..<(w * h) {
            straight[p * 4 + 1] = 200
            straight[p * 4 + 2] = 50
        }
        let texture = try makeTexture(from: straight, width: w, height: h, alphaIsCoverage: false)
        for level in 1..<texture.mipmapLevelCount {
            let mip = readLevel(texture, level)
            for p in 0..<(mip.w * mip.h) {
                XCTAssertEqual(Array(mip.bytes[(p * 4)..<(p * 4 + 4)]), [0, 200, 50, 0],
                               "level \(level) texel \(p): zero-alpha data texture lost its channels")
            }
        }
    }

    /// Independent mode conserves the plain (straight) mean of every
    /// channel — the counterpart of the premultiplied-mean invariant for
    /// coverage textures.
    func testIndependentModeConservesStraightMeans() throws {
        let w = 64, h = 64
        let straight = makeSyntheticStraight(width: w, height: h)
        let texture = try makeTexture(from: straight, width: w, height: h, alphaIsCoverage: false)
        func means(_ bytes: [UInt8]) -> [Double] {
            var m = [0.0, 0.0, 0.0, 0.0]
            for i in 0..<bytes.count { m[i % 4] += Double(bytes[i]) }
            return m.map { $0 / Double(bytes.count / 4) }
        }
        let reference = means(straight)
        for level in 1...3 {
            let mip = readLevel(texture, level)
            let m = means(mip.bytes)
            for c in 0..<4 {
                XCTAssertEqual(m[c], reference[c], accuracy: 0.75, "level \(level) channel \(c) mean drifted")
            }
        }
    }

    /// The interpolated encode table must agree with the exact transfer
    /// function to well inside an 8-bit step everywhere in [0, 1] — a dense
    /// sweep, densest near 0 where the curve bends hardest.
    func testFastSRGBEncodeMatchesExactWithinAFractionOfAStep() {
        var worst: Float = 0
        for i in 0...200_000 {
            let linear = Float(i) / 200_000
            let exact = TextureMipUploader.srgbEncode(linear)
            let fast = TextureMipUploader.srgbEncodeFast(linear)
            worst = max(worst, abs(exact - fast) * 255)
        }
        for i in 0...20_000 {   // the toe, magnified
            let linear = Float(i) / 20_000 * 0.02
            let exact = TextureMipUploader.srgbEncode(linear)
            let fast = TextureMipUploader.srgbEncodeFast(linear)
            worst = max(worst, abs(exact - fast) * 255)
        }
        XCTAssertLessThan(worst, 0.05, "table error \(worst) of an 8-bit step — too coarse for exact rounding")
        XCTAssertEqual(TextureMipUploader.srgbEncodeFast(0), 0)
        XCTAssertEqual(TextureMipUploader.srgbEncodeFast(1), 1)
    }

    /// sRGB content must be averaged in linear light. Metal decodes `_srgb`
    /// texels to linear when sampling, so the correct average of opaque
    /// black and white is 0.5 linear ≈ encoded 188 — averaging the encoded
    /// bytes instead yields 128, which decodes to ~0.22 linear: minified
    /// color content darkens by half its brightness.
    func testSRGBMipsAverageInLinearLight() throws {
        let w = 2, h = 2
        var straight = [UInt8](repeating: 0, count: w * h * 4)
        for p in 0..<(w * h) {
            let white: UInt8 = p % 2 == 1 ? 255 : 0
            straight[p * 4 + 0] = white
            straight[p * 4 + 1] = white
            straight[p * 4 + 2] = white
            straight[p * 4 + 3] = 255
        }

        for coverage in [true, false] {
            let texture = try makeTexture(from: straight, width: w, height: h,
                                          pixelFormat: .rgba8Unorm_srgb, alphaIsCoverage: coverage)
            let level1 = readLevel(texture, 1).bytes
            for c in 0..<3 {
                XCTAssertGreaterThanOrEqual(Int(level1[c]), 186,
                    "sRGB mip (alphaIsCoverage=\(coverage)) averaged toward \(level1[c]) — encoded-space averaging (would be 128) darkens minified content")
                XCTAssertLessThanOrEqual(Int(level1[c]), 189,
                    "sRGB mip average overshot linear 0.5 (expected encoded ≈188)")
            }
            XCTAssertEqual(level1[3], 255)
        }
    }

    /// Opaque red against fully transparent GREEN: at every mip level, any
    /// texel that is visibly opaque must still be pure red with no green.
    /// Averaging in straight space would drag the transparent texels' RGB
    /// into the soft edge — as green here, so the failure names its source;
    /// in real art that RGB is usually black, and the artifact is the dark
    /// fringe this uploader exists to prevent. (The green itself survives
    /// verbatim at level 0 and has zero weight below it — coverage-weighted
    /// averaging, not a decode loss.)
    func testTransparentTexelsDoNotBleedIntoVisibleEdges() throws {
        let w = 64, h = 64
        var straight = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let p = (y * w + x) * 4
                if x < w / 2 {
                    straight[p + 0] = 255
                    straight[p + 3] = 255
                } else {
                    straight[p + 1] = 255  // authored color, alpha 0
                }
            }
        }
        let texture = try makeTexture(from: straight, width: w, height: h, alphaIsCoverage: true)

        for level in 0...4 {
            let mip = readLevel(texture, level)
            for p in 0..<(mip.w * mip.h) {
                let a = mip.bytes[p * 4 + 3]
                guard a > 32 else { continue }  // invisible texels may hold anything
                XCTAssertGreaterThanOrEqual(mip.bytes[p * 4 + 0], 250,
                    "level \(level) texel \(p) (a=\(a)) lost red — transparent RGB bled in")
                XCTAssertLessThanOrEqual(mip.bytes[p * 4 + 1], 5,
                    "level \(level) texel \(p) gained green — transparent RGB bled in")
            }
        }
    }
}
