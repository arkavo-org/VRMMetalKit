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
@testable import GLTFMetalKit

/// The sampler state belongs to the glTF sampler, per texture.
///
/// `MTLSamplerState` is opaque — nothing can be read back off a created
/// state — so the wrap/filter mapping is pinned on the resolved
/// `MTLSamplerDescriptor` and the caching behaviour on state identity.
///
/// No bundled avatar exercises anything but `REPEAT`/`REPEAT`/`LINEAR`, so
/// every case here is a synthetic in-memory glTF.
final class GLTFSamplerCacheTests: XCTestCase {

    // MARK: - Wrap modes, per axis

    /// `wrapS` and `wrapT` are independent: each test case sets one axis
    /// away from `REPEAT` so a swapped-axis mapping cannot pass.
    func testWrapModesMapPerAxis() throws {
        let clampS = GLTFSamplerCache.descriptor(for: try sampler(["wrapS": 33071, "wrapT": 10497]))
        XCTAssertEqual(clampS.sAddressMode, .clampToEdge, "wrapS CLAMP_TO_EDGE must clamp the S axis")
        XCTAssertEqual(clampS.tAddressMode, .repeat, "wrapT REPEAT must leave the T axis repeating")

        let clampT = GLTFSamplerCache.descriptor(for: try sampler(["wrapS": 10497, "wrapT": 33071]))
        XCTAssertEqual(clampT.sAddressMode, .repeat, "wrapS REPEAT must leave the S axis repeating")
        XCTAssertEqual(clampT.tAddressMode, .clampToEdge, "wrapT CLAMP_TO_EDGE must clamp the T axis")

        let mirrorS = GLTFSamplerCache.descriptor(for: try sampler(["wrapS": 33648, "wrapT": 10497]))
        XCTAssertEqual(mirrorS.sAddressMode, .mirrorRepeat, "wrapS MIRRORED_REPEAT must mirror the S axis")
        XCTAssertEqual(mirrorS.tAddressMode, .repeat)

        let mirrorT = GLTFSamplerCache.descriptor(for: try sampler(["wrapS": 10497, "wrapT": 33648]))
        XCTAssertEqual(mirrorT.sAddressMode, .repeat)
        XCTAssertEqual(mirrorT.tAddressMode, .mirrorRepeat, "wrapT MIRRORED_REPEAT must mirror the T axis")

        let mixed = GLTFSamplerCache.descriptor(for: try sampler(["wrapS": 33648, "wrapT": 33071]))
        XCTAssertEqual(mixed.sAddressMode, .mirrorRepeat)
        XCTAssertEqual(mixed.tAddressMode, .clampToEdge)
    }

    // MARK: - Filters

    func testMagFilterMapsNearestAndLinear() throws {
        XCTAssertEqual(GLTFSamplerCache.descriptor(for: try sampler(["magFilter": 9728])).magFilter, .nearest,
                       "magFilter NEAREST")
        XCTAssertEqual(GLTFSamplerCache.descriptor(for: try sampler(["magFilter": 9729])).magFilter, .linear,
                       "magFilter LINEAR")
        XCTAssertEqual(GLTFSamplerCache.descriptor(for: try sampler([:])).magFilter, .linear,
                       "absent magFilter keeps the bilinear default")
    }

    func testMinFilterMapsInterpolationAndMipFilter() throws {
        let table: [(Int, MTLSamplerMinMagFilter, MTLSamplerMipFilter)] = [
            (9728, .nearest, .notMipmapped),
            (9729, .linear, .notMipmapped),
            (9984, .nearest, .nearest),
            (9985, .linear, .nearest),
            (9986, .nearest, .linear),
            (9987, .linear, .linear),
        ]
        for (constant, expectedMin, expectedMip) in table {
            let descriptor = GLTFSamplerCache.descriptor(for: try sampler(["minFilter": constant]))
            XCTAssertEqual(descriptor.minFilter, expectedMin, "minFilter \(constant) interpolation")
            XCTAssertEqual(descriptor.mipFilter, expectedMip, "minFilter \(constant) mip filter")
        }
    }

    /// The sampler's `mipFilter` must agree with whether ``TextureLoader``
    /// actually built a chain for that texture (#402). A trilinear sampler
    /// over a single-level texture — or `.notMipmapped` over a chain — is
    /// the bug this invariant forbids.
    func testMipFilterAgreesWithTheMipChainDecision() throws {
        var cases: [GLTFSampler?] = [nil]
        cases.append(try sampler([:]))
        for constant in [9728, 9729, 9984, 9985, 9986, 9987] {
            cases.append(try sampler(["minFilter": constant]))
        }
        for gltfSampler in cases {
            let mipmapped = TextureLoader.samplerRequestsMipmaps(gltfSampler)
            let descriptor = GLTFSamplerCache.descriptor(for: gltfSampler)
            XCTAssertEqual(descriptor.mipFilter == .notMipmapped, !mipmapped,
                           "minFilter \(gltfSampler?.minFilter.map(String.init) ?? "absent"): sampler mip filter must match the built chain")
        }
    }

    // MARK: - Defaults

    /// glTF states no default filters and `REPEAT` wrap. An absent sampler
    /// and a sampler with every field omitted must both keep the
    /// bilinear-with-mips, repeat-on-both-axes behaviour that predates
    /// per-texture sampler state.
    func testAbsentSamplerAndAbsentFieldsKeepTodaysDefaults() throws {
        for descriptor in [GLTFSamplerCache.descriptor(for: nil),
                           GLTFSamplerCache.descriptor(for: try sampler([:]))] {
            XCTAssertEqual(descriptor.minFilter, .linear)
            XCTAssertEqual(descriptor.magFilter, .linear)
            XCTAssertEqual(descriptor.mipFilter, .linear)
            XCTAssertEqual(descriptor.sAddressMode, .repeat)
            XCTAssertEqual(descriptor.tAddressMode, .repeat)
            XCTAssertEqual(descriptor.maxAnisotropy, 16)
            XCTAssertTrue(descriptor.normalizedCoordinates)
        }
    }

    // MARK: - Caching

    /// Assets reference a handful of distinct samplers across dozens of
    /// textures; Metal caps how many sampler states may be live at once.
    /// Equal descriptors must collapse onto one state, unequal ones must not.
    func testEqualDescriptorsDedupeAndDistinctOnesDoNot() throws {
        let device = try metalDevice()
        let cache = GLTFSamplerCache(device: device)

        let repeatLinear = try XCTUnwrap(cache.samplerState(for: try sampler(["minFilter": 9729, "magFilter": 9729, "wrapS": 10497, "wrapT": 10497])))
        let sameAgain = try XCTUnwrap(cache.samplerState(for: try sampler(["minFilter": 9729, "magFilter": 9729, "wrapS": 10497, "wrapT": 10497])))
        XCTAssertTrue(repeatLinear === sameAgain, "identical glTF samplers must share one MTLSamplerState")

        let spelledDifferently = try XCTUnwrap(cache.samplerState(for: nil))
        XCTAssertFalse(repeatLinear === spelledDifferently,
                       "9729 declines mips; the default sampler keeps them — these must not collapse")

        let clamped = try XCTUnwrap(cache.samplerState(for: try sampler(["magFilter": 9729, "wrapS": 33071, "wrapT": 10497])))
        let mirrored = try XCTUnwrap(cache.samplerState(for: try sampler(["magFilter": 9729, "wrapS": 33648, "wrapT": 10497])))
        let nearestMag = try XCTUnwrap(cache.samplerState(for: try sampler(["magFilter": 9728, "wrapS": 33071, "wrapT": 10497])))
        XCTAssertFalse(clamped === mirrored, "different wrap modes must produce different states")
        XCTAssertFalse(clamped === nearestMag, "different mag filters must produce different states")

        let clampedAgain = try XCTUnwrap(cache.samplerState(for: try sampler(["magFilter": 9729, "wrapS": 33071, "wrapT": 10497])))
        XCTAssertTrue(clamped === clampedAgain, "a repeated lookup must hit the cache")

        XCTAssertEqual(cache.stateCount, 5, "seven lookups over five distinct descriptors allocate five states")
    }

    // MARK: - Per-texture resolution through a document

    /// Textures name their sampler by index; two textures sharing an index
    /// share a state, a texture with no `sampler` field gets the defaults.
    func testDocumentResolvesSamplerPerTexture() throws {
        let device = try metalDevice()
        let json = """
        {"asset": {"version": "2.0"},
         "images": [{"uri": "data:image/png;base64,"}],
         "samplers": [{"magFilter": 9728, "minFilter": 9728, "wrapS": 33071, "wrapT": 33648},
                      {"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}],
         "textures": [{"sampler": 0, "source": 0}, {"sampler": 1, "source": 0},
                      {"sampler": 0, "source": 0}, {"source": 0}]}
        """
        let document = try JSONDecoder().decode(GLTFDocument.self, from: Data(json.utf8))

        let clamped = GLTFSamplerCache.descriptor(forTextureAt: 0, in: document)
        XCTAssertEqual(clamped.sAddressMode, .clampToEdge)
        XCTAssertEqual(clamped.tAddressMode, .mirrorRepeat)
        XCTAssertEqual(clamped.magFilter, .nearest)
        XCTAssertEqual(clamped.mipFilter, .notMipmapped)

        let trilinear = GLTFSamplerCache.descriptor(forTextureAt: 1, in: document)
        XCTAssertEqual(trilinear.sAddressMode, .repeat)
        XCTAssertEqual(trilinear.mipFilter, .linear)

        let unsampled = GLTFSamplerCache.descriptor(forTextureAt: 3, in: document)
        XCTAssertEqual(unsampled.sAddressMode, .repeat, "a texture with no sampler keeps the REPEAT default")
        XCTAssertEqual(unsampled.magFilter, .linear)

        let cache = GLTFSamplerCache(device: device)
        let first = try XCTUnwrap(cache.samplerState(forTextureAt: 0, in: document))
        let second = try XCTUnwrap(cache.samplerState(forTextureAt: 1, in: document))
        let third = try XCTUnwrap(cache.samplerState(forTextureAt: 2, in: document))
        XCTAssertTrue(first === third, "textures 0 and 2 name the same sampler")
        XCTAssertFalse(first === second, "textures 0 and 1 name different samplers")

        let outOfRange = cache.samplerState(forTextureAt: 99, in: document)
        XCTAssertNotNil(outOfRange, "an out-of-range texture index falls back to the default sampler")
    }

    // MARK: - Renderable material association

    /// The PBR shader has one sampler per texture *role*: the color slots
    /// take the base color texture's sampler, the data slots the first of
    /// metallic-roughness / normal / occlusion the material binds.
    func testRenderableMaterialTakesItsSamplersFromTheRightTextures() throws {
        let device = try metalDevice()
        let json = """
        {"asset": {"version": "2.0"},
         "images": [{"uri": "data:image/png;base64,"}],
         "samplers": [{"magFilter": 9729, "minFilter": 9729, "wrapS": 33071, "wrapT": 33071},
                      {"magFilter": 9728, "minFilter": 9987, "wrapS": 33648, "wrapT": 10497}],
         "textures": [{"sampler": 0, "source": 0}, {"sampler": 1, "source": 0}],
         "materials": [{"pbrMetallicRoughness": {"baseColorTexture": {"index": 0}},
                        "normalTexture": {"index": 1}}]}
        """
        let document = try JSONDecoder().decode(GLTFDocument.self, from: Data(json.utf8))
        let gltfMaterial = try XCTUnwrap(document.materials?.first)
        let cache = GLTFSamplerCache(device: device)
        let loaded = [0: try stubTexture(device), 1: try stubTexture(device)]

        let material = GLTFAssetLoader.makeMaterial(from: gltfMaterial, textures: loaded,
                                                    samplerCache: cache, document: document)
        XCTAssertTrue(material.colorSampler === cache.samplerState(forTextureAt: 0, in: document),
                      "the color slots take the base color texture's sampler")
        XCTAssertTrue(material.linearSampler === cache.samplerState(forTextureAt: 1, in: document),
                      "the data slots take the normal map's sampler")
        XCTAssertFalse(material.colorSampler === material.linearSampler,
                       "the two roles name different glTF samplers here")
    }

    /// A texture reference that failed to decode binds the renderer's
    /// fallback texture, so it must not claim its slot's sampler either:
    /// the role falls through to the next candidate that actually loaded.
    /// Otherwise a loaded emissive map is sampled through the wrap mode of
    /// a base color texture that never bound.
    func testSamplerRoleSkipsTexturesThatFailedToLoad() throws {
        let device = try metalDevice()
        let json = """
        {"asset": {"version": "2.0"},
         "images": [{"uri": "data:image/png;base64,"}],
         "samplers": [{"magFilter": 9729, "minFilter": 9729, "wrapS": 33071, "wrapT": 33071},
                      {"magFilter": 9728, "minFilter": 9987, "wrapS": 33648, "wrapT": 10497}],
         "textures": [{"sampler": 0, "source": 0}, {"sampler": 1, "source": 0}],
         "materials": [{"pbrMetallicRoughness": {"baseColorTexture": {"index": 0}},
                        "emissiveTexture": {"index": 1}}]}
        """
        let document = try JSONDecoder().decode(GLTFDocument.self, from: Data(json.utf8))
        let gltfMaterial = try XCTUnwrap(document.materials?.first)
        let cache = GLTFSamplerCache(device: device)

        // Texture 0 (base color) failed to decode; texture 1 (emissive) did not.
        let material = GLTFAssetLoader.makeMaterial(from: gltfMaterial,
                                                    textures: [1: try stubTexture(device)],
                                                    samplerCache: cache, document: document)

        XCTAssertTrue(material.colorSampler === cache.samplerState(forTextureAt: 1, in: document),
                      "the color slot must take the emissive sampler — base color never bound")
        XCTAssertFalse(material.colorSampler === cache.samplerState(forTextureAt: 0, in: document),
                       "a texture that failed to load must not supply its slot's sampler")
        XCTAssertNil(material.linearSampler,
                     "no data map loaded, so the data slots stay on the renderer default")
    }

    private func stubTexture(_ device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    /// A material with no textures — and any material built without a
    /// cache, as tests and callers outside the asset loader do — carries no
    /// samplers, leaving the renderer on its own linear/repeat states.
    func testMaterialWithoutTexturesCarriesNoSamplers() throws {
        let json = """
        {"asset": {"version": "2.0"}, "materials": [{"pbrMetallicRoughness": {"baseColorFactor": [1, 1, 1, 1]}}]}
        """
        let document = try JSONDecoder().decode(GLTFDocument.self, from: Data(json.utf8))
        let gltfMaterial = try XCTUnwrap(document.materials?.first)
        let cache = GLTFSamplerCache(device: try metalDevice())

        let material = GLTFAssetLoader.makeMaterial(from: gltfMaterial, textures: [:],
                                                    samplerCache: cache, document: document)
        XCTAssertNil(material.colorSampler)
        XCTAssertNil(material.linearSampler)

        let uncached = GLTFAssetLoader.makeMaterial(from: gltfMaterial, textures: [:])
        XCTAssertNil(uncached.colorSampler)
        XCTAssertNil(uncached.linearSampler)
    }

    // MARK: - Helpers

    private func sampler(_ fields: [String: Int]) throws -> GLTFSampler {
        let data = try JSONSerialization.data(withJSONObject: fields, options: [])
        return try JSONDecoder().decode(GLTFSampler.self, from: data)
    }

    private func metalDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        return device
    }
}
