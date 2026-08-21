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
import CoreGraphics
import ImageIO
@testable import GLTFCore

/// The mip decision belongs to the glTF sampler.
///
/// glTF 2.0 `minFilter` encodes both interpolation and whether a mip chain
/// exists: `9984`–`9987` (`*_MIPMAP_*`) request one, `9728` NEAREST and
/// `9729` LINEAR decline one, and an absent filter leaves the choice to the
/// runtime (we default to mips, matching `createSampler`'s trilinear
/// default for the same cases). These tests pin the truth
/// table and, end-to-end, that a loaded texture's `mipmapLevelCount`
/// follows the sampler in its document — not a loader-wide constant.
///
/// The second document-level decision is whether alpha weights the chain:
/// only where glTF gives alpha coverage semantics (base color of a
/// MASK/BLEND material). That table, and its end-to-end effect on the
/// loaded mip bytes, are pinned here too.
final class SamplerMipmapTests: XCTestCase {

    // MARK: - Decision table

    func testMinFilterDecidesMipmapping() {
        func sampler(minFilter: Int?) -> GLTFSampler? {
            let json: String
            if let minFilter {
                json = #"{"minFilter": \#(minFilter)}"#
            } else {
                json = "{}"
            }
            return try? JSONDecoder().decode(GLTFSampler.self, from: Data(json.utf8))
        }

        XCTAssertFalse(TextureLoader.samplerRequestsMipmaps(sampler(minFilter: 9728)), "NEAREST declines mips")
        XCTAssertFalse(TextureLoader.samplerRequestsMipmaps(sampler(minFilter: 9729)), "LINEAR declines mips")
        XCTAssertTrue(TextureLoader.samplerRequestsMipmaps(sampler(minFilter: 9984)), "NEAREST_MIPMAP_NEAREST requests mips")
        XCTAssertTrue(TextureLoader.samplerRequestsMipmaps(sampler(minFilter: 9985)), "LINEAR_MIPMAP_NEAREST requests mips")
        XCTAssertTrue(TextureLoader.samplerRequestsMipmaps(sampler(minFilter: 9986)), "NEAREST_MIPMAP_LINEAR requests mips")
        XCTAssertTrue(TextureLoader.samplerRequestsMipmaps(sampler(minFilter: 9987)), "LINEAR_MIPMAP_LINEAR requests mips")
        XCTAssertTrue(TextureLoader.samplerRequestsMipmaps(sampler(minFilter: nil)), "absent minFilter defaults to mips")
        XCTAssertTrue(TextureLoader.samplerRequestsMipmaps(nil), "absent sampler defaults to mips")
    }

    /// Alpha is coverage only for base color on MASK/BLEND. OPAQUE base
    /// color (explicit or spec-default), data slots even on a BLEND
    /// material, and unbound textures all filter independently.
    func testAlphaIsCoverageFollowsMaterialBinding() throws {
        let json = """
        {"asset": {"version": "2.0"},
         "textures": [{"source": 0}, {"source": 0}, {"source": 0}, {"source": 0}, {"source": 0}, {"source": 0}],
         "images": [{"uri": "data:image/png;base64,"}],
         "materials": [
           {"pbrMetallicRoughness": {"baseColorTexture": {"index": 0}}, "alphaMode": "BLEND"},
           {"pbrMetallicRoughness": {"baseColorTexture": {"index": 1}}},
           {"pbrMetallicRoughness": {"baseColorTexture": {"index": 2}}, "alphaMode": "OPAQUE"},
           {"pbrMetallicRoughness": {"metallicRoughnessTexture": {"index": 3}}, "alphaMode": "BLEND"},
           {"pbrMetallicRoughness": {"baseColorTexture": {"index": 4}}, "alphaMode": "MASK", "alphaCutoff": 0.5}
         ]}
        """
        let document = try JSONDecoder().decode(GLTFDocument.self, from: Data(json.utf8))
        XCTAssertTrue(TextureLoader.textureAlphaIsCoverage(0, in: document), "BLEND base color: alpha is coverage")
        XCTAssertFalse(TextureLoader.textureAlphaIsCoverage(1, in: document), "spec-default OPAQUE base color ignores alpha")
        XCTAssertFalse(TextureLoader.textureAlphaIsCoverage(2, in: document), "explicit OPAQUE base color ignores alpha")
        XCTAssertFalse(TextureLoader.textureAlphaIsCoverage(3, in: document), "metallic-roughness carries data in G/B, alpha is not coverage even on a BLEND material")
        XCTAssertTrue(TextureLoader.textureAlphaIsCoverage(4, in: document), "MASK base color: alpha is coverage")
        XCTAssertFalse(TextureLoader.textureAlphaIsCoverage(5, in: document), "unbound texture filters independently")
    }

    // MARK: - End to end through TextureLoader

    /// `minFilter: 9987 LINEAR_MIPMAP_LINEAR` — the sampler asks; the
    /// loaded texture must carry a chain.
    func testMipRequestingSamplerGetsMipChain() async throws {
        let texture = try await loadFixtureTexture(samplerJSON: ["minFilter": 9987, "magFilter": 9729])
        XCTAssertGreaterThan(texture.mipmapLevelCount, 1)
    }

    /// `minFilter: 9729 LINEAR` — the sampler declines; the loaded texture
    /// must be single-level. This is what every sampler in
    /// `AvatarSample_A_1.0.vrm.glb` writes, so it also pins that this
    /// change leaves that asset's rendering untouched.
    func testMipDecliningSamplerGetsSingleLevel() async throws {
        let texture = try await loadFixtureTexture(samplerJSON: ["minFilter": 9729, "magFilter": 9729])
        XCTAssertEqual(texture.mipmapLevelCount, 1)
    }

    /// No sampler on the texture at all — the runtime chooses; ours chooses
    /// mips (matching `createSampler`'s trilinear default).
    func testAbsentSamplerDefaultsToMipChain() async throws {
        let texture = try await loadFixtureTexture(samplerJSON: nil)
        XCTAssertGreaterThan(texture.mipmapLevelCount, 1)
    }

    /// The loader must pass the material's verdict to the chain. Same
    /// image — seven columns of opaque red, nine of transparent black — so
    /// level-1 texel x=3 straddles column 6 (red) and 7 (transparent):
    /// bound as base color of a BLEND material it is alpha-weighted
    /// (`[255,0,0,128]`); bound as metallic-roughness (loaded linear, as
    /// the asset loaders do) it is the plain average (`[128,0,0,128]`);
    /// unbound and sRGB it is the plain average in linear light
    /// (`[188,0,0,128]` — 0.5 linear encodes to 188).
    func testLoaderWeightsAlphaOnlyForCoverageTextures() async throws {
        let sampler: [String: Any] = ["minFilter": 9987, "magFilter": 9729]
        func level1Texel3(_ texture: MTLTexture) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: 8 * 8 * 4)
            out.withUnsafeMutableBytes { buf in
                texture.getBytes(buf.baseAddress!, bytesPerRow: 8 * 4,
                                 from: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 1)
            }
            return Array(out[(3 * 4)..<(3 * 4 + 4)])
        }

        let blend = try await loadFixtureTexture(
            samplerJSON: sampler, image: .redSevenColumns,
            materialJSON: ["pbrMetallicRoughness": ["baseColorTexture": ["index": 0]], "alphaMode": "BLEND"])
        XCTAssertEqual(level1Texel3(blend), [255, 0, 0, 128],
                       "BLEND base color must be alpha-weighted through the loader")

        let data = try await loadFixtureTexture(
            samplerJSON: sampler, image: .redSevenColumns, sRGB: false,
            materialJSON: ["pbrMetallicRoughness": ["metallicRoughnessTexture": ["index": 0]], "alphaMode": "BLEND"])
        XCTAssertEqual(level1Texel3(data), [128, 0, 0, 128],
                       "data slot must filter independently through the loader, even on a BLEND material")

        let unbound = try await loadFixtureTexture(samplerJSON: sampler, image: .redSevenColumns, materialJSON: nil)
        XCTAssertEqual(level1Texel3(unbound), [188, 0, 0, 128],
                       "unbound sRGB texture must filter independently, in linear light, through the loader")
    }

    // MARK: - End to end through ParallelTextureLoader

    /// `GLTFAssetLoader` (and the `.parallelTextureLoading` VRM preset)
    /// load through `ParallelTextureLoader`, which carries the same two
    /// decisions independently of `TextureLoader` — pin them there too.
    func testParallelLoaderFollowsSamplerAndMaterial() async throws {
        let mips = try await loadFixtureTextureParallel(samplerJSON: ["minFilter": 9987, "magFilter": 9729])
        XCTAssertGreaterThan(mips.mipmapLevelCount, 1, "9987 through ParallelTextureLoader must get a chain")

        let single = try await loadFixtureTextureParallel(samplerJSON: ["minFilter": 9729, "magFilter": 9729])
        XCTAssertEqual(single.mipmapLevelCount, 1, "9729 through ParallelTextureLoader must stay single-level")

        let absent = try await loadFixtureTextureParallel(samplerJSON: nil)
        XCTAssertGreaterThan(absent.mipmapLevelCount, 1, "absent sampler through ParallelTextureLoader defaults to a chain")

        let sampler: [String: Any] = ["minFilter": 9987, "magFilter": 9729]
        func level1Texel3(_ texture: MTLTexture) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: 8 * 8 * 4)
            out.withUnsafeMutableBytes { buf in
                texture.getBytes(buf.baseAddress!, bytesPerRow: 8 * 4,
                                 from: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 1)
            }
            return Array(out[(3 * 4)..<(3 * 4 + 4)])
        }
        let blend = try await loadFixtureTextureParallel(
            samplerJSON: sampler, image: .redSevenColumns,
            materialJSON: ["pbrMetallicRoughness": ["baseColorTexture": ["index": 0]], "alphaMode": "BLEND"])
        XCTAssertEqual(level1Texel3(blend), [255, 0, 0, 128],
                       "BLEND base color must be alpha-weighted through ParallelTextureLoader")
        let data = try await loadFixtureTextureParallel(
            samplerJSON: sampler, image: .redSevenColumns, sRGB: false,
            materialJSON: ["pbrMetallicRoughness": ["metallicRoughnessTexture": ["index": 0]], "alphaMode": "BLEND"])
        XCTAssertEqual(level1Texel3(data), [128, 0, 0, 128],
                       "data slot must filter independently through ParallelTextureLoader")
    }

    // MARK: - Fixture

    private enum FixtureImage {
        /// Opaque gradient.
        case gradient
        /// Columns 0–6 opaque red, 7–15 transparent black.
        case redSevenColumns
    }

    /// Builds a one-texture glTF document in memory (16×16 PNG as a data
    /// URI, so no buffers are involved), optionally with one material
    /// referencing texture 0, and loads texture 0 through the real
    /// `TextureLoader` path.
    private func loadFixtureTexture(samplerJSON: [String: Any]?,
                                    image: FixtureImage = .gradient,
                                    sRGB: Bool = true,
                                    materialJSON: [String: Any]? = nil,
                                    parallel: Bool = false) async throws -> MTLTexture {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }

        var root: [String: Any] = [
            "asset": ["version": "2.0"],
            "images": [["uri": "data:image/png;base64,\(try makePNGBase64(image))"]],
        ]
        if let materialJSON {
            root["materials"] = [materialJSON]
        }
        if let samplerJSON {
            root["samplers"] = [samplerJSON]
            root["textures"] = [["sampler": 0, "source": 0]]
        } else {
            root["textures"] = [["source": 0]]
        }

        var jsonData = try JSONSerialization.data(withJSONObject: root, options: [])
        jsonData.append(contentsOf: Array(repeating: UInt8(0x20), count: (4 - jsonData.count % 4) % 4))

        var glb = Data()
        glb.append(contentsOf: [0x67, 0x6C, 0x54, 0x46])                       // 'glTF'
        glb.append(contentsOf: withUnsafeBytes(of: UInt32(2).littleEndian) { Array($0) })
        glb.append(contentsOf: withUnsafeBytes(of: UInt32(12 + 8 + jsonData.count).littleEndian) { Array($0) })
        glb.append(contentsOf: withUnsafeBytes(of: UInt32(jsonData.count).littleEndian) { Array($0) })
        glb.append(contentsOf: [0x4A, 0x53, 0x4F, 0x4E])                       // 'JSON'
        glb.append(jsonData)

        let parsed = try GLTFParser().parse(data: glb)
        let bufferLoader = BufferLoader(document: parsed.document, binaryData: parsed.binaryData)
        if parallel {
            let loader = ParallelTextureLoader(device: device, bufferLoader: bufferLoader, document: parsed.document)
            let map = await loader.loadTexturesParallel(indices: [0], linearTextureIndices: sRGB ? [] : [0])
            return try XCTUnwrap(map[0], "fixture texture failed to load (parallel)")
        }
        let loader = TextureLoader(device: device, bufferLoader: bufferLoader, document: parsed.document)
        let texture = try await loader.loadTexture(at: 0, sRGB: sRGB)
        return try XCTUnwrap(texture, "fixture texture failed to load")
    }

    private func loadFixtureTextureParallel(samplerJSON: [String: Any]?,
                                            image: FixtureImage = .gradient,
                                            sRGB: Bool = true,
                                            materialJSON: [String: Any]? = nil) async throws -> MTLTexture {
        try await loadFixtureTexture(samplerJSON: samplerJSON, image: image, sRGB: sRGB,
                                     materialJSON: materialJSON, parallel: true)
    }

    /// A deterministic 16×16 image, PNG-encoded. (The context is
    /// premultiplied, so transparent texels store black — fine for both
    /// patterns here.)
    private func makePNGBase64(_ image: FixtureImage) throws -> String {
        let size = 16
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for p in 0..<(size * size) {
            switch image {
            case .gradient:
                pixels[p * 4 + 0] = UInt8(p % 256)
                pixels[p * 4 + 1] = UInt8((p * 3) % 256)
                pixels[p * 4 + 2] = 64
                pixels[p * 4 + 3] = 255
            case .redSevenColumns:
                if p % size < 7 {
                    pixels[p * 4 + 0] = 255
                    pixels[p * 4 + 3] = 255
                }
            }
        }
        let context = try XCTUnwrap(CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pixels.withUnsafeBytes { buf in
            context.data?.copyMemory(from: buf.baseAddress!, byteCount: buf.count)
        }
        let cgImage = try XCTUnwrap(context.makeImage(), "CGContext.makeImage failed")
        let pngData = NSMutableData()
        let dest = try XCTUnwrap(
            CGImageDestinationCreateWithData(pngData, "public.png" as CFString, 1, nil),
            "CGImageDestination creation failed")
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw XCTSkip("PNG encode unavailable")
        }
        return (pngData as Data).base64EncodedString()
    }
}
