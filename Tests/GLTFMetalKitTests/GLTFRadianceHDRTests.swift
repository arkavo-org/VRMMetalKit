//
// Copyright 2025 Arkavo
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
@testable import GLTFMetalKit

/// Phase 4+ HDR loader. Tests synthesize a minimal Radiance HDR file in
/// memory, parse it, then upload the result through the
/// `makeFromRadianceHDR(data:device:library:)` pipeline. No external
/// HDR asset committed to the repo (Poly Haven assets are heavy);
/// in-memory fixtures keep the test self-contained.
final class GLTFRadianceHDRTests: XCTestCase {

    /// Builds a 2×2 uncompressed Radiance HDR (no RLE — too few columns for
    /// adaptive RLE). Pixels: top row red, bottom row green.
    private func makeMinimalHDR() -> Data {
        var bytes = [UInt8]()
        let header = """
        #?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 2 +X 2\n
        """
        bytes.append(contentsOf: Array(header.utf8))
        // RGBE for red (R=1, G=0, B=0): mantissa 128, exponent 128-(-1+8)=… Use simple Brett values.
        // Direct: pick e=129 (= 2^(129-128-8) = 2^-7 = 1/128) so mantissa 128 → 1.0.
        let red: [UInt8] = [128, 0, 0, 129]
        let green: [UInt8] = [0, 128, 0, 129]
        // Row 0: red, red
        bytes.append(contentsOf: red); bytes.append(contentsOf: red)
        // Row 1: green, green
        bytes.append(contentsOf: green); bytes.append(contentsOf: green)
        return Data(bytes)
    }

    func testParsesMinimalRGBEUncompressed() throws {
        let data = makeMinimalHDR()
        let hdr = try GLTFRadianceHDR(data: data)
        XCTAssertEqual(hdr.width, 2)
        XCTAssertEqual(hdr.height, 2)
        XCTAssertEqual(hdr.pixelsFloat16.count, 2 * 2 * 4)
        // Top-left pixel should decode to (1, 0, 0).
        // Half-precision 1.0 has bit pattern 0x3C00.
        XCTAssertEqual(hdr.pixelsFloat16[0], 0x3C00,
            "Top-left R channel should be half-precision 1.0; got \(String(hdr.pixelsFloat16[0], radix: 16))")
        XCTAssertEqual(hdr.pixelsFloat16[1], 0)
        XCTAssertEqual(hdr.pixelsFloat16[2], 0)
    }

    func testRejectsInvalidSignature() {
        let bad = Data([0x41, 0x42, 0x43, 0x44])  // "ABCD"
        XCTAssertThrowsError(try GLTFRadianceHDR(data: bad)) { error in
            guard case GLTFRadianceHDRError.invalidSignature = error else {
                XCTFail("Expected .invalidSignature, got \(error)"); return
            }
        }
    }

    func testMakeFromRadianceHDRBuildsEnvironment() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }

        // Use a larger synthetic HDR (8×8) so the compute kernels do real work.
        // Same RGBE per row but each row a different colour to give the
        // diffuse irradiance + specular prefilter directional signal.
        var bytes = [UInt8]()
        bytes.append(contentsOf: Array("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 8 +X 8\n".utf8))
        for row in 0..<8 {
            let shade = UInt8(40 + row * 25)
            for _ in 0..<8 {
                bytes.append(contentsOf: [shade, shade, shade, 129])
            }
        }
        let data = Data(bytes)

        let renderer = try GLTFRenderer(device: device)
        let env = try GLTFEnvironment.makeFromRadianceHDR(
            data: data,
            device: device,
            library: renderer.library,
            sourceCubeSize: 32,
            specularSize: 32,
            diffuseSize: 8
        )
        XCTAssertEqual(env.diffuse.textureType, .typeCube)
        XCTAssertEqual(env.specular.textureType, .typeCube)
        XCTAssertGreaterThan(env.specularMipCount, 1,
            "Specular cubemap should carry a mip chain (\(env.specularMipCount))")
    }
}
