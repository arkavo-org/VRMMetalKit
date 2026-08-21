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

/// Invariance checks for the straight-alpha upload path.
///
/// The contract is: `CGContext`-decoded premultiplied bytes in, texture
/// storing STRAIGHT alpha out. These tests pin the two properties that make
/// that an alpha-edge fix and not a tone shift:
///
/// 1. The upload is an exact unpremultiply of the input (round-trip
///    identity on a known color).
/// 2. Re-premultiplying the uploaded texture (which is what blending's
///    `.sourceAlpha` factor does at composite time) recovers the input's
///    mean color — unpremultiply relocates energy out of the stored bytes,
///    it does not create or destroy it. This is the committed form of the
///    whole-image "mean color unchanged to 3 decimals" A/B that motivated
///    the change.
final class TextureUploaderTests: XCTestCase {

    private var device: MTLDevice!

    override func setUp() {
        device = MTLCreateSystemDefaultDevice()
    }

    // MARK: - Helpers

    /// Deterministic pseudo-random RGBA image, premultiplied, as CGContext
    /// would decode it. SplitMix64 so runs are identical everywhere.
    private func makeSyntheticPremultiplied(width: Int, height: Int) -> [UInt8] {
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
            let a = UInt8(truncatingIfNeeded: r >> 24)
            // Premultiplied: channels can never exceed alpha.
            data[p * 4 + 0] = UInt8(Int(UInt8(truncatingIfNeeded: r)) * Int(a) / 255)
            data[p * 4 + 1] = UInt8(Int(UInt8(truncatingIfNeeded: r >> 8)) * Int(a) / 255)
            data[p * 4 + 2] = UInt8(Int(UInt8(truncatingIfNeeded: r >> 16)) * Int(a) / 255)
            data[p * 4 + 3] = a
        }
        return data
    }

    private func makeTexture(from premultiplied: [UInt8], width: Int, height: Int) throws -> MTLTexture {
        guard let device else { throw XCTSkip("Metal device not available") }
        var bytes = premultiplied
        let texture = bytes.withUnsafeMutableBytes { buf in
            TextureUploader.makeTexture(
                bitmapData: buf.baseAddress!,
                width: width, height: height,
                pixelFormat: .rgba8Unorm, device: device)
        }
        return try XCTUnwrap(texture, "makeTexture returned nil")
    }

    private func readBack(_ texture: MTLTexture) -> [UInt8] {
        let w = texture.width, h = texture.height
        var out = [UInt8](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!, bytesPerRow: w * 4,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        return out
    }

    /// Mean premultiplied color (r·a, g·a, b·a, a) of straight-alpha bytes,
    /// in [0, 255] units. Premultiplied space is where "image energy" lives:
    /// it is what blending composites.
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

    /// Mean of already-premultiplied bytes, same units as `premultipliedMean`.
    private func mean(premultiplied: [UInt8], pixels: Int) -> (r: Double, g: Double, b: Double, a: Double) {
        var r = 0.0, g = 0.0, b = 0.0, a = 0.0
        for p in 0..<pixels {
            r += Double(premultiplied[p * 4 + 0])
            g += Double(premultiplied[p * 4 + 1])
            b += Double(premultiplied[p * 4 + 2])
            a += Double(premultiplied[p * 4 + 3])
        }
        let n = Double(pixels)
        return (r / n, g / n, b / n, a / n)
    }

    // MARK: - Tests

    /// The texture must be an exact unpremultiply of the input: a known
    /// straight color premultiplied on the way in comes back as the straight
    /// color.
    func testUploadRoundTripsToStraightAlpha() throws {
        let w = 8, h = 8
        // Straight (200, 80, 40) at alpha 128 → premultiplied (100, 40, 20, 128).
        var premul = [UInt8](repeating: 0, count: w * h * 4)
        for p in 0..<(w * h) {
            premul[p * 4 + 0] = 100
            premul[p * 4 + 1] = 40
            premul[p * 4 + 2] = 20
            premul[p * 4 + 3] = 128
        }
        let texture = try makeTexture(from: premul, width: w, height: h)
        let straight = readBack(texture)
        // vImage unpremultiply rounds; allow ±1.
        for p in 0..<(w * h) {
            XCTAssertEqual(Int(straight[p * 4 + 0]), 199, accuracy: 2)
            XCTAssertEqual(Int(straight[p * 4 + 1]), 80, accuracy: 2)
            XCTAssertEqual(Int(straight[p * 4 + 2]), 40, accuracy: 2)
            XCTAssertEqual(Int(straight[p * 4 + 3]), 128)
        }
    }

    /// Re-premultiplying the uploaded straight-alpha texture must recover
    /// the input's mean color: the fix must not darken (the rgb·a² bug in
    /// reverse) or brighten what blending composites.
    func testUnpremultiplyPreservesPremultipliedMean() throws {
        let w = 128, h = 128
        let premul = makeSyntheticPremultiplied(width: w, height: h)
        let texture = try makeTexture(from: premul, width: w, height: h)

        let reference = mean(premultiplied: premul, pixels: w * h)
        let uploaded = premultipliedMean(straight: readBack(texture), pixels: w * h)

        // Unpremultiply→re-premultiply round-trips through 8-bit
        // quantization once; 1.0/255 ≈ 0.004 normalized per channel.
        XCTAssertEqual(uploaded.r, reference.r, accuracy: 1.0, "red mean drifted")
        XCTAssertEqual(uploaded.g, reference.g, accuracy: 1.0, "green mean drifted")
        XCTAssertEqual(uploaded.b, reference.b, accuracy: 1.0, "blue mean drifted")
        XCTAssertEqual(uploaded.a, reference.a, accuracy: 1.0, "alpha mean drifted")
    }
}
