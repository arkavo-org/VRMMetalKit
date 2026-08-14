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
import ImageIO
import UniformTypeIdentifiers
@testable import GLTFCore

/// Exactness checks for decoding PNG straight into a straight-alpha texture.
///
/// PNG stores unassociated (straight) alpha by spec, and the blend pipelines
/// consume straight alpha, so the two ends already agree — anything the
/// loader does in between is loss. Decoding through a `CGBitmapContext`
/// premultiplies (that format cannot represent unpremultiplied 8-bit RGBA)
/// and unpremultiplying afterwards only approximates the inverse, because
/// the premultiply quantized to 8 bits first. These tests pin the property
/// that a round-tripping decode cannot have: the bytes the GPU stores are
/// the bytes the PNG holds.
final class StraightAlphaDecodeTests: XCTestCase {

    private var device: MTLDevice!

    override func setUp() {
        device = MTLCreateSystemDefaultDevice()
    }

    // MARK: - Helpers

    /// Straight-alpha RGBA texels spanning the cases that separate the two
    /// error sources: opaque texels (any error there is colorspace
    /// conversion, which is alpha-independent), partial-alpha texels where a
    /// channel exceeds alpha (impossible to represent premultiplied, so
    /// error there is the premultiply round trip, which scales as 1/alpha),
    /// and fully transparent texels carrying color.
    private func authoredStraightTexels() -> (bytes: [UInt8], width: Int, height: Int) {
        var texels: [[UInt8]] = []

        // Opaque, across the range — isolates colorspace error.
        for v in stride(from: 0, through: 255, by: 51) {
            texels.append([UInt8(v), UInt8(255 - v), UInt8((v &* 2) % 256), 255])
        }

        // Partial alpha with channels above alpha — white-ish art at low
        // coverage, the worst case for the premultiply round trip.
        for a in [1, 2, 4, 8, 16, 32, 64, 128, 192, 254] as [Int] {
            texels.append([250, 240, 230, UInt8(a)])
            texels.append([255, 0, 128, UInt8(a)])
        }

        // Fully transparent but carrying authored color. Premultiplication
        // destroys this outright: rgb·0 = 0, and unpremultiply cannot
        // recover it. Bilinear filtering samples these at every alpha edge.
        texels.append([200, 100, 50, 0])
        texels.append([255, 255, 255, 0])

        let width = 8
        let height = (texels.count + width - 1) / width
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for (i, t) in texels.enumerated() {
            bytes[i * 4 + 0] = t[0]
            bytes[i * 4 + 1] = t[1]
            bytes[i * 4 + 2] = t[2]
            bytes[i * 4 + 3] = t[3]
        }
        return (bytes, width, height)
    }

    /// Encodes straight-alpha bytes as a PNG, the way the art in a GLB is
    /// stored. `CGImage` (unlike `CGBitmapContext`) can represent
    /// unassociated alpha, so nothing is premultiplied on the way in.
    private func pngData(from straight: [UInt8], width: Int, height: Int) throws -> Data {
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(straight) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent))

        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "PNG encode failed")
        return out as Data
    }

    private func decodePNG(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
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

    /// Authored PNG -> uploaded texture, through the loader's decode seam.
    private func upload(_ straight: [UInt8], width: Int, height: Int) throws -> [UInt8] {
        guard let device else { throw XCTSkip("Metal device not available") }
        let cgImage = try decodePNG(try pngData(from: straight, width: width, height: height))
        let texture = try XCTUnwrap(
            TextureUploader.makeTexture(cgImage: cgImage,
                                        pixelFormat: .rgba8Unorm,
                                        device: device),
            "makeTexture returned nil")
        return readBack(texture)
    }

    // MARK: - Tests

    /// The bytes the GPU stores are the bytes the PNG holds, exactly.
    ///
    /// Errors are reported split by alpha so a regression names its own
    /// cause: alpha-independent error is colorspace conversion, error
    /// growing as alpha falls is a premultiply round trip.
    func testDecodedTexelsMatchAuthoredPNGExactly() throws {
        let (authored, width, height) = authoredStraightTexels()
        let uploaded = try upload(authored, width: width, height: height)

        var opaqueMax = 0, partialMax = 0, worstAlpha = 255
        for p in 0..<(width * height) {
            let a = Int(authored[p * 4 + 3])
            var maxChannel = 0
            for c in 0..<4 {
                maxChannel = max(maxChannel, abs(Int(uploaded[p * 4 + c]) - Int(authored[p * 4 + c])))
            }
            if a == 255 {
                opaqueMax = max(opaqueMax, maxChannel)
            } else if maxChannel > partialMax {
                partialMax = maxChannel
                worstAlpha = a
            }
        }

        XCTAssertEqual(opaqueMax, 0,
                       "Opaque texels differ by \(opaqueMax); alpha-independent error means colorspace conversion, not premultiply")
        XCTAssertEqual(partialMax, 0,
                       "Partial-alpha texels differ by \(partialMax) (worst at alpha=\(worstAlpha)); error that grows as alpha falls means the decode round-tripped through premultiplied bytes")
    }

    /// Fully transparent texels keep their authored color.
    ///
    /// Premultiplication zeroes them irrecoverably (rgb·0 = 0), and a
    /// bilinear sample straddling an alpha edge mixes those texels into the
    /// visible result, so black leaks into the edge. This is the one case
    /// where the decode change is visible beyond quantization noise.
    func testFullyTransparentTexelsKeepAuthoredColor() throws {
        let authored: [UInt8] = [
            200, 100, 50, 0,
            255, 255, 255, 0,
            10, 220, 130, 0,
            128, 128, 128, 255,
        ]
        let uploaded = try upload(authored, width: 2, height: 2)
        XCTAssertEqual(uploaded, authored,
                       "Transparent texels lost their color — the decode premultiplied")
    }
}
