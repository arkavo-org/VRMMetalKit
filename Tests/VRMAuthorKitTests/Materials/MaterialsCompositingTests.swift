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

final class MaterialsCompositingTests: XCTestCase {
    static let target = ImageSpec(id: "image:t", width: 2, height: 2, colourSpace: .linear, usage: .colour)

    func solid(_ id: String, _ rgba: [Double], opacity: Double = 1, blend: BlendMode = .normal, mask: String? = nil, enabled: Bool = true, target: String = "image:t") -> TextureLayer {
        TextureLayer(id: id, targetImage: target, kind: .solid, colour: Colour(rgba: rgba), mask: mask, opacity: opacity, blend: blend, enabled: enabled)
    }

    func assertPixel(_ p: SIMD4<Float>, _ expected: [Float], accuracy: Float = 1e-6, line: UInt = #line) {
        for (i, e) in expected.enumerated() { XCTAssertEqual(p[i], e, accuracy: accuracy, "component \(i)", line: line) }
    }

    func composite(_ layers: [TextureLayer], base: RasterImage? = RasterImage(width: 2, height: 2, fill: SIMD4(0.2, 0.4, 0.6, 1)), sources: [String: RasterImage] = [:]) throws -> RasterImage {
        try TextureCompositor.composite(spec: MaterialsCompositingTests.target, layers: layers, base: base, sources: { sources[$0] })
    }

    func testNormalBlendWithOpacityOverOpaqueBase() throws {
        let out = try composite([solid("l", [1, 0, 0, 1], opacity: 0.5)])
        assertPixel(out[0, 0], [0.6, 0.2, 0.3, 1])
        assertPixel(out[1, 1], [0.6, 0.2, 0.3, 1])
    }

    func testMultiplyAndScreen() throws {
        let multiplied = try composite([solid("m", [0.5, 1, 0.5, 1], blend: .multiply)], base: RasterImage(width: 2, height: 2, fill: SIMD4(0.5, 0.5, 1, 1)))
        assertPixel(multiplied[0, 0], [0.25, 0.5, 0.5, 1])
        let screened = try composite([solid("s", [0.5, 0.5, 0.5, 1], blend: .screen)], base: RasterImage(width: 2, height: 2, fill: SIMD4(0.5, 0.2, 0, 1)))
        assertPixel(screened[0, 0], [0.75, 0.6, 0.5, 1])
        let half = try composite([solid("h", [0.5, 1, 0.5, 1], opacity: 0.5, blend: .multiply)], base: RasterImage(width: 2, height: 2, fill: SIMD4(0.5, 0.5, 1, 1)))
        assertPixel(half[0, 0], [0.375, 0.5, 0.75, 1])
    }

    func testLayerAlphaTimesOpacityAndTransparentBase() throws {
        let out = try composite([solid("a", [1, 1, 1, 0.5], opacity: 0.5)], base: RasterImage(width: 2, height: 2, fill: SIMD4(0, 0, 0, 1)))
        assertPixel(out[0, 0], [0.25, 0.25, 0.25, 1])
        let transparent = try composite([solid("b", [1, 0, 0, 0.5])], base: nil)
        assertPixel(transparent[0, 0], [1, 0, 0, 0.5], accuracy: 1e-6)
        let stacked = try composite([solid("b", [1, 0, 0, 0.5]), solid("c", [0, 0, 1, 0.5])], base: nil)
        assertPixel(stacked[0, 0], [1.0 / 3, 0, 2.0 / 3, 0.75], accuracy: 1e-6)
        let multiplyOnTransparent = try composite([solid("d", [0.5, 0.5, 0.5, 1], blend: .multiply)], base: nil)
        assertPixel(multiplyOnTransparent[0, 0], [0.5, 0.5, 0.5, 1])
    }

    func testMaskSamplesTargetUVSpace() throws {
        let mask = RasterImage(width: 2, height: 2, pixels: [SIMD4(1, 0, 0, 1), SIMD4(0, 0, 0, 1), SIMD4(0, 1, 1, 1), SIMD4(0.5, 0, 0, 1)])
        let out = try composite([solid("m", [1, 1, 1, 1], mask: "mask:m")], sources: ["mask:m": mask])
        assertPixel(out[0, 0], [1, 1, 1, 1])
        assertPixel(out[1, 0], [0.2, 0.4, 0.6, 1])
        assertPixel(out[0, 1], [0.2, 0.4, 0.6, 1], accuracy: 1e-6)
        assertPixel(out[1, 1], [0.6, 0.7, 0.8, 1])
        XCTAssertThrowsError(try composite([solid("m", [1, 1, 1, 1], mask: "mask:missing")])) { XCTAssertEqual(($0 as? AuthorError)?.code, .validationFailed) }
    }

    func testDisabledAndForeignLayersAreSkipped() throws {
        let out = try composite([solid("off", [1, 0, 0, 1], enabled: false), solid("other", [0, 1, 0, 1], target: "image:elsewhere")])
        assertPixel(out[0, 0], [0.2, 0.4, 0.6, 1])
    }

    static let source = RasterImage(width: 2, height: 2, pixels: [SIMD4(1, 0, 0, 1), SIMD4(0, 1, 0, 1), SIMD4(0, 0, 1, 1), SIMD4(1, 1, 1, 1)])

    func image(_ id: String, offset: [Double] = [0, 0], scale: [Double] = [1, 1], rotation: Double = 0) -> TextureLayer {
        TextureLayer(id: id, targetImage: "image:t", kind: .image, image: "src", uvOffset: offset, uvScale: scale, uvRotationDeg: rotation)
    }

    func testImageLayerIdentityOffsetScaleAndRotation() throws {
        let sources = ["src": MaterialsCompositingTests.source]
        let identity = try composite([image("i")], base: nil, sources: sources)
        XCTAssertEqual(identity.pixels, MaterialsCompositingTests.source.pixels)

        let shifted = try composite([image("o", offset: [0.5, 0])], base: nil, sources: sources)
        XCTAssertEqual(shifted.pixels, [SIMD4(0, 1, 0, 1), SIMD4(1, 0, 0, 1), SIMD4(1, 1, 1, 1), SIMD4(0, 0, 1, 1)])

        let scaled = try composite([image("s", scale: [2, 2])], base: nil, sources: sources)
        XCTAssertEqual(scaled.pixels, Array(repeating: SIMD4(1, 1, 1, 1), count: 4), "uv doubled: every centre lands on the (1,1) texel")

        let rotated = try composite([image("r", rotation: 90)], base: nil, sources: sources)
        XCTAssertEqual(rotated.pixels, [SIMD4(0, 0, 1, 1), SIMD4(1, 0, 0, 1), SIMD4(1, 1, 1, 1), SIMD4(0, 1, 0, 1)])
        let uv = TextureCompositor.transformUV(SIMD2(0.25, 0.25), layer: image("r", rotation: 90))
        XCTAssertEqual(uv.x, 0.25, accuracy: 1e-12)
        XCTAssertEqual(uv.y, -0.25, accuracy: 1e-12)
        XCTAssertThrowsError(try composite([image("missing")], base: nil, sources: [:]))
    }

    func testEightBitEncodingAndColourSpaceHandling() {
        let image = RasterImage(width: 1, height: 3, pixels: [SIMD4(0.5, 0.25, 0.2, 0.5), SIMD4(0, 1, 0.75, 1), SIMD4(-0.5, 2, 0.0031308, 0)])
        XCTAssertEqual(image.rgba8(colourSpace: .srgb, usage: .colour), [188, 137, 124, 128, 0, 255, 225, 255, 0, 255, 10, 0])
        XCTAssertEqual(image.rgba8(colourSpace: .linear, usage: .colour), [128, 64, 51, 128, 0, 255, 191, 255, 0, 255, 1, 0])
        XCTAssertEqual(image.rgba8(colourSpace: .srgb, usage: .normal), [128, 64, 51, 128, 0, 255, 191, 255, 0, 255, 1, 0], "normal maps bypass transfer coding")
        XCTAssertEqual(image.rgba8(colourSpace: .srgb, usage: .mask), [188, 137, 124, 128, 0, 255, 225, 255, 0, 255, 10, 0])
        XCTAssertEqual(ColourTransfer.linearRGBA(Colour(rgba: [0.5, 0, 1, 0.5], space: .srgb)), SIMD4(Float(ColourTransfer.srgbToLinear(0.5)), 0, 1, 0.5))
        XCTAssertEqual(ColourTransfer.srgbToLinear(ColourTransfer.linearToSrgb(0.3)), 0.3, accuracy: 1e-12)
    }

    func testSamplingWrapsAndBaseIsResampledToSpecSize() throws {
        let src = MaterialsCompositingTests.source
        XCTAssertEqual(src.sample(SIMD2(1.25, -0.75)), SIMD4(1, 0, 0, 1))
        XCTAssertEqual(src.sample(SIMD2(0.75, 0.75)), SIMD4(1, 1, 1, 1))
        let spec = ImageSpec(id: "image:big", width: 4, height: 4, colourSpace: .linear, usage: .colour)
        let out = try TextureCompositor.composite(spec: spec, layers: [], base: src, sources: { _ in nil })
        XCTAssertEqual(out[0, 0], SIMD4(1, 0, 0, 1))
        XCTAssertEqual(out[3, 0], SIMD4(0, 1, 0, 1))
        XCTAssertEqual(out[0, 3], SIMD4(0, 0, 1, 1))
        XCTAssertEqual(out[3, 3], SIMD4(1, 1, 1, 1))
    }

    func testProceduralDefaultsAreDeterministicAndSeedSensitive() throws {
        for role in MaterialRole.allCases {
            let a = MaterialRoleDefaults.raster(for: role, width: 32, height: 32, seed: 7)
            let b = MaterialRoleDefaults.raster(for: role, width: 32, height: 32, seed: 7)
            XCTAssertEqual(a, b, role.rawValue)
            let png = try a.png(colourSpace: .srgb, usage: .colour)
            XCTAssertEqual(png, try b.png(colourSpace: .srgb, usage: .colour))
            XCTAssertEqual(try PNGEncoder.chunks(of: png).map(\.type), ["IHDR", "IDAT", "IEND"])
        }
        XCTAssertNotEqual(MaterialRoleDefaults.raster(for: .cloth, width: 32, height: 32, seed: 1), MaterialRoleDefaults.raster(for: .cloth, width: 32, height: 32, seed: 2))
        XCTAssertNotEqual(MaterialRoleDefaults.raster(for: .hair, width: 32, height: 32, seed: 1), MaterialRoleDefaults.raster(for: .hair, width: 32, height: 32, seed: 2))
        XCTAssertEqual(MaterialRoleDefaults.raster(for: .faceSkin, width: 32, height: 32, seed: 1), MaterialRoleDefaults.raster(for: .faceSkin, width: 32, height: 32, seed: 2), "flat roles ignore the seed")
        var prng = SplitMix64(seed: 0)
        XCTAssertEqual(prng.next(), 0xE220_A839_7B1D_CDAF, "SplitMix64 reference output for seed 0")
    }
}
