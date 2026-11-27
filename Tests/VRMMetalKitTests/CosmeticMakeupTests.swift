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
import CoreGraphics
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd
@testable import VRMMetalKit

@MainActor
final class CosmeticMakeupTests: XCTestCase {
    private var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    // MARK: - Helpers

    private func makeSolidTexture(
        width: Int = 16,
        height: Int = 16,
        rgba: (UInt8, UInt8, UInt8, UInt8),
        pixelFormat: MTLPixelFormat = .rgba8Unorm_srgb,
        name: String = "solid"
    ) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        let tex = try XCTUnwrap(device.makeTexture(descriptor: desc))
        tex.label = name
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4 + 0] = rgba.0
            pixels[i * 4 + 1] = rgba.1
            pixels[i * 4 + 2] = rgba.2
            pixels[i * 4 + 3] = rgba.3
        }
        tex.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: &pixels,
            bytesPerRow: width * 4
        )
        return tex
    }

    private func readPixel(_ texture: MTLTexture, x: Int, y: Int, mipLevel: Int = 0) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var px: [UInt8] = [0, 0, 0, 0]
        texture.getBytes(&px, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: mipLevel)
        return (px[0], px[1], px[2], px[3])
    }

    private func makeInMemoryPNG(width: Int, height: Int, rgba: (UInt8, UInt8, UInt8, UInt8)) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            // Premultiply for CGContext
            let a = Float(rgba.3) / 255.0
            pixels[i * 4 + 0] = UInt8((Float(rgba.0) * a).rounded())
            pixels[i * 4 + 1] = UInt8((Float(rgba.1) * a).rounded())
            pixels[i * 4 + 2] = UInt8((Float(rgba.2) * a).rounded())
            pixels[i * 4 + 3] = rgba.3
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        let cgImage: CGImage = try pixels.withUnsafeMutableBytes { ptr in
            let ctx = try XCTUnwrap(CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ))
            return try XCTUnwrap(ctx.makeImage())
        }
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func makeQuadModel(material: VRMMaterial) throws -> VRMModel {
        let verts: [VRMVertex] = [
            VRMVertex(position: [-0.8, -0.8, 0], normal: [0, 0, 1], texCoord: [0, 1], color: [1, 1, 1, 1]),
            VRMVertex(position: [ 0.8, -0.8, 0], normal: [0, 0, 1], texCoord: [1, 1], color: [1, 1, 1, 1]),
            VRMVertex(position: [ 0.8,  0.8, 0], normal: [0, 0, 1], texCoord: [1, 0], color: [1, 1, 1, 1]),
            VRMVertex(position: [-0.8,  0.8, 0], normal: [0, 0, 1], texCoord: [0, 0], color: [1, 1, 1, 1]),
        ]
        let indices: [UInt16] = [0, 1, 2, 0, 2, 3]
        let prim = VRMPrimitive()
        prim.materialIndex = 0
        prim.hasNormals = true
        prim.hasTexCoords = true
        prim.hasColors = true
        prim.localMin = [-0.8, -0.8, 0]
        prim.localMax = [ 0.8,  0.8, 0]
        prim.uploadVertices(verts, device: device)
        prim.indexCount = indices.count
        prim.indexType = .uint16
        prim.indexBuffer = indices.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        let mesh = VRMMesh(name: "FaceQuad")
        mesh.primitives = [prim]
        let node = VRMNode(index: 0, name: "FaceNode", mesh: 0)
        node.updateWorldTransform()

        let gltf = try JSONDecoder().decode(GLTFDocument.self, from: Data(#"{"asset":{"version":"2.0"}}"#.utf8))
        let model = VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: ""), humanoid: nil, gltf: gltf)
        model.device = device
        model.materials = [material]
        model.meshes = [mesh]
        model.nodes = [node]
        model.finalizeModelLocalBounds()
        return model
    }

    private func renderOffscreen(
        renderer: VRMRenderer,
        size: Int = 64,
        clearColor: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    ) throws -> [UInt8] {
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false
        )
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .shared
        let colorTex = try XCTUnwrap(device.makeTexture(descriptor: colorDesc))

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: size, height: size, mipmapped: false
        )
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private
        let depthTex = try XCTUnwrap(device.makeTexture(descriptor: depthDesc))

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = colorTex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = clearColor
        rpd.depthAttachment.texture = depthTex
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.storeAction = .dontCare
        rpd.depthAttachment.clearDepth = 1.0

        renderer.viewMatrix = RenderTestSupport.makeLookAt(eye: [0, 0, 2.5], center: [0, 0, 0], up: [0, 1, 0])
        renderer.projectionMatrix = renderer.makeProjectionMatrix(aspectRatio: 1.0)

        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        renderer.drawOffscreen(to: colorTex, depth: depthTex, commandBuffer: cb, renderPassDescriptor: rpd)
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertNil(cb.error)

        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        colorTex.getBytes(&rgba, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        return rgba
    }

    // MARK: - 1. Zero-Disk In-Memory PNG Decoding

    func testInMemoryPNGDecodingAndErrorHandling() throws {
        let png = try makeInMemoryPNG(width: 8, height: 8, rgba: (200, 100, 50, 128))
        let tex = try VRMTextureLayerStack.makeTexture(from: png, device: device, sRGB: true, label: "lips_png")
        XCTAssertEqual(tex.width, 8)
        XCTAssertEqual(tex.height, 8)
        XCTAssertEqual(tex.pixelFormat, .rgba8Unorm_srgb)

        let px = readPixel(tex, x: 4, y: 4)
        XCTAssertEqual(Int(px.r), 200, accuracy: 3)
        XCTAssertEqual(Int(px.g), 100, accuracy: 3)
        XCTAssertEqual(Int(px.b), 50, accuracy: 3)
        XCTAssertEqual(Int(px.a), 128, accuracy: 2)

        XCTAssertThrowsError(try VRMTextureLayerStack.makeTexture(from: Data("not-a-png".utf8), device: device)) { error in
            guard case VRMCosmeticError.imageDecodingFailed = error else {
                return XCTFail("Expected imageDecodingFailed, got \(error)")
            }
            XCTAssertNotNil(error.localizedDescription)
        }
    }

    // MARK: - 2. All 6 Blend Modes + Out-of-Rect UV Clipping

    func testAllSixBlendModes() throws {
        let stack = try VRMTextureLayerStack(device: device)
        let base = try makeSolidTexture(width: 16, height: 16, rgba: (128, 128, 128, 255), pixelFormat: .rgba8Unorm)
        let redHalf = try makeSolidTexture(width: 16, height: 16, rgba: (255, 0, 0, 255), pixelFormat: .rgba8Unorm)
        let midGray = try makeSolidTexture(width: 16, height: 16, rgba: (128, 128, 128, 255), pixelFormat: .rgba8Unorm)

        // normal (opacity 0.5): mix(0.5, 1.0, 0.5) = 0.75 -> ~191, green -> 64
        stack.layers = [VRMTextureLayer(texture: redHalf, blendMode: .normal, opacity: 0.5)]
        let normOut = try stack.composite(baseTexture: base, sRGB: false).color
        let pNorm = readPixel(normOut, x: 8, y: 8)
        XCTAssertEqual(Int(pNorm.r), 191, accuracy: 3)
        XCTAssertEqual(Int(pNorm.g), 64, accuracy: 3)

        // multiply: 0.5 * (1, 0, 0) = (0.5, 0, 0)
        stack.layers = [VRMTextureLayer(texture: redHalf, blendMode: .multiply, opacity: 1.0)]
        let mulOut = try stack.composite(baseTexture: base, sRGB: false).color
        let pMul = readPixel(mulOut, x: 8, y: 8)
        XCTAssertEqual(Int(pMul.r), 128, accuracy: 3)
        XCTAssertLessThan(pMul.g, 5)

        // screen: 1 - (1 - 0.5) * (1 - 0.5) = 0.75 -> ~191
        stack.layers = [VRMTextureLayer(texture: midGray, blendMode: .screen, opacity: 1.0)]
        let scrOut = try stack.composite(baseTexture: base, sRGB: false).color
        let pScr = readPixel(scrOut, x: 8, y: 8)
        XCTAssertEqual(Int(pScr.r), 191, accuracy: 3)

        // overlay: base 0.5 >= 0.5 -> 1 - 2*(0.5)*(0.5) = 0.5 -> ~128; on bright base (200/255) -> brighter
        let brightBase = try makeSolidTexture(width: 16, height: 16, rgba: (200, 200, 200, 255), pixelFormat: .rgba8Unorm)
        stack.layers = [VRMTextureLayer(texture: redHalf, blendMode: .overlay, opacity: 1.0)]
        let ovOut = try stack.composite(baseTexture: brightBase, sRGB: false).color
        let pOv = readPixel(ovOut, x: 8, y: 8)
        XCTAssertGreaterThan(pOv.r, 240)
        XCTAssertLessThan(pOv.g, 160)

        // additive: 0.5 + 0.5 * 0.5 = 0.75 -> ~191
        stack.layers = [VRMTextureLayer(texture: midGray, blendMode: .additive, opacity: 0.5)]
        let addOut = try stack.composite(baseTexture: base, sRGB: false).color
        let pAdd = readPixel(addOut, x: 8, y: 8)
        XCTAssertEqual(Int(pAdd.r), 191, accuracy: 3)

        // eraseAlpha: opacity 1.0 -> alpha becomes 0, RGB preserved
        stack.layers = [VRMTextureLayer(texture: redHalf, blendMode: .eraseAlpha, opacity: 1.0)]
        let eraseOut = try stack.composite(baseTexture: base, sRGB: false).color
        let pErase = readPixel(eraseOut, x: 8, y: 8)
        XCTAssertEqual(pErase.a, 0)
        XCTAssertEqual(Int(pErase.r), 128, accuracy: 3)
    }

    func testStrictUVRectClippingLeavesOutsidePixelsUntouched() throws {
        let stack = try VRMTextureLayerStack(device: device, faceLandmarks: .vroidDefault)
        let base = try makeSolidTexture(width: 64, height: 64, rgba: (40, 80, 200, 255), pixelFormat: .rgba8Unorm)
        let lipsDecal = try makeSolidTexture(width: 16, height: 16, rgba: (255, 20, 60, 255), pixelFormat: .rgba8Unorm)

        stack.layers = [
            VRMTextureLayer(name: "lips", texture: lipsDecal, blendMode: .normal, opacity: 1.0, landmarkRegion: .lips)
        ]
        let out = try stack.composite(baseTexture: base, sRGB: false).color

        // Inside vroidDefault.lips (u in [0.40, 0.60], v in [0.64, 0.74]) -> (32, 44)
        let inside = readPixel(out, x: 32, y: 44)
        XCTAssertGreaterThan(inside.r, 240)
        XCTAssertLessThan(inside.b, 80)

        // Outside lips (corner 2, 2) -> untouched base blue
        let outside = readPixel(out, x: 2, y: 2)
        XCTAssertEqual(Int(outside.r), 40, accuracy: 2)
        XCTAssertEqual(Int(outside.g), 80, accuracy: 2)
        XCTAssertEqual(Int(outside.b), 200, accuracy: 2)
    }

    // MARK: - 3. Complete Mipmaps, BC7/sRGB Sampling & Typed Format Errors (#485 §2)

    func testCompleteMipmapChainAndUnsupportedFormatRejection() throws {
        let stack = try VRMTextureLayerStack(device: device)
        let base = try makeSolidTexture(width: 64, height: 64, rgba: (100, 150, 200, 255), pixelFormat: .rgba8Unorm_srgb)
        let decal = try makeSolidTexture(width: 16, height: 16, rgba: (255, 0, 0, 255), pixelFormat: .rgba8Unorm_srgb)
        stack.layers = [VRMTextureLayer(texture: decal, blendMode: .normal, opacity: 1.0)]

        let out = try stack.composite(baseTexture: base, sRGB: true).color
        // 64 -> 7 mip levels (64, 32, 16, 8, 4, 2, 1)
        XCTAssertEqual(out.mipmapLevelCount, 7)
        XCTAssertEqual(out.pixelFormat, .rgba8Unorm_srgb)
        let mipTop = readPixel(out, x: 0, y: 0, mipLevel: 6)
        XCTAssertGreaterThan(mipTop.r, 230, "Lowest 1x1 mip level must be generated, not blank")

        // Unsupported pixel format (.r32Uint) must throw typed error, NEVER substitute a flat fallback
        let badDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Uint, width: 8, height: 8, mipmapped: false)
        badDesc.usage = [.shaderRead]
        badDesc.storageMode = .shared
        let badTex = try XCTUnwrap(device.makeTexture(descriptor: badDesc))
        XCTAssertThrowsError(try stack.composite(baseTexture: badTex, sRGB: true)) { error in
            guard case VRMCosmeticError.unsupportedPixelFormat(let fmt, _) = error else {
                return XCTFail("Expected unsupportedPixelFormat, got \(error)")
            }
            XCTAssertEqual(fmt, .r32Uint)
        }
    }

    #if os(macOS)
    func testBC7SRGBCompressedBaseTextureSamplesCleanly() throws {
        // Allocate a valid 4x4 BC7 sRGB block (16 bytes) and verify hardware sampling works.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bc7_rgbaUnorm_srgb,
            width: 4,
            height: 4,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let bc7Tex = device.makeTexture(descriptor: desc) else {
            throw XCTSkip("Device does not support BC7 textures")
        }
        // BC7 Mode 6 solid white block (bit 6 = 1 -> 0x40, endpoints = max)
        var block: [UInt8] = [0x40, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                              0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00]
        bc7Tex.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: &block, bytesPerRow: 16)

        let stack = try VRMTextureLayerStack(device: device)
        let tintLayer = try makeSolidTexture(width: 4, height: 4, rgba: (0, 255, 0, 128), pixelFormat: .rgba8Unorm_srgb)
        stack.layers = [VRMTextureLayer(texture: tintLayer, blendMode: .normal, opacity: 1.0)]
        let out = try stack.composite(baseTexture: bc7Tex, sRGB: true).color
        XCTAssertEqual(out.width, 4)
        XCTAssertEqual(out.mipmapLevelCount, 3)
        let px = readPixel(out, x: 2, y: 2)
        XCTAssertGreaterThan(px.g, 180)
    }
    #endif

    // MARK: - 4. Linked shadeMultiplyTexture Sync & Clean Restore (#485 §1)

    func testLinkedShadeMultiplyTextureSyncAndRestore() throws {
        let origMTL = try makeSolidTexture(width: 16, height: 16, rgba: (200, 200, 200, 255))
        let redDecal = try makeSolidTexture(width: 16, height: 16, rgba: (255, 0, 0, 255))

        let gltfMat = try JSONDecoder().decode(GLTFMaterial.self, from: Data(#"{"name":"Face_00_SKIN"}"#.utf8))
        let stack = try VRMTextureLayerStack(device: device, layers: [VRMTextureLayer(texture: redDecal)])

        // Case A: Same VRMTexture wrapper shared by baseColorTexture and shadeMultiplyTexture
        let sharedWrapper = VRMTexture(name: "face_atlas", mtlTexture: origMTL)
        let matA = VRMMaterial(from: gltfMat, textures: [])
        matA.baseColorTexture = sharedWrapper
        matA.mtoon = VRMMToonMaterial()
        matA.mtoon?.shadeMultiplyTexture = sharedWrapper
        let modelA = try makeQuadModel(material: matA)

        let revBefore = modelA.materialRevision
        try stack.apply(to: matA, slot: .baseColor, in: modelA)
        XCTAssertEqual(modelA.materialRevision, revBefore + 1)
        XCTAssertTrue(matA.baseColorTexture?.mtlTexture === matA.mtoon?.shadeMultiplyTexture?.mtlTexture)
        XCTAssertFalse(matA.baseColorTexture?.mtlTexture === origMTL)

        stack.clear(from: matA, slot: .baseColor, in: modelA)
        XCTAssertTrue(matA.baseColorTexture?.mtlTexture === origMTL)
        XCTAssertTrue(matA.mtoon?.shadeMultiplyTexture?.mtlTexture === origMTL)

        // Case B: Distinct VRMTexture wrappers referencing the same original MTLTexture
        let baseWrapperB = VRMTexture(name: "base", mtlTexture: origMTL)
        let shadeWrapperB = VRMTexture(name: "shade", mtlTexture: origMTL)
        let matB = VRMMaterial(from: gltfMat, textures: [])
        matB.baseColorTexture = baseWrapperB
        matB.mtoon = VRMMToonMaterial()
        matB.mtoon?.shadeMultiplyTexture = shadeWrapperB

        try stack.apply(to: matB, slot: .baseColor)
        XCTAssertTrue(matB.baseColorTexture?.mtlTexture === matB.mtoon?.shadeMultiplyTexture?.mtlTexture,
                      "Distinct wrappers sharing the original MTLTexture must both sync so shadeUsesBaseColor stays active")
        stack.clear(from: matB, slot: .baseColor)
        XCTAssertTrue(matB.baseColorTexture?.mtlTexture === origMTL)
        XCTAssertTrue(matB.mtoon?.shadeMultiplyTexture?.mtlTexture === origMTL)

        // Case C: Unlinked distinct shade texture is left untouched
        let separateShadeMTL = try makeSolidTexture(width: 16, height: 16, rgba: (50, 50, 255, 255))
        let matC = VRMMaterial(from: gltfMat, textures: [])
        matC.baseColorTexture = VRMTexture(name: "base", mtlTexture: origMTL)
        matC.mtoon = VRMMToonMaterial()
        matC.mtoon?.shadeMultiplyTexture = VRMTexture(name: "separateShade", mtlTexture: separateShadeMTL)

        try stack.apply(to: matC, slot: .baseColor)
        XCTAssertTrue(matC.mtoon?.shadeMultiplyTexture?.mtlTexture === separateShadeMTL)
    }

    // MARK: - 5. ARKAVO_vrm_cosmetics 0.1 Landmarks (#485 §6)

    func testFaceLandmarksExtensionAndExtrasParsingAndVRoidDefault() throws {
        // vroidDefault covers every region with valid UV rects and native-anime-v1 face materials
        for region in VRMFaceLandmarkRegion.allCases {
            XCTAssertNotNil(VRMFaceLandmarks.vroidDefault.rect(for: region), "Missing vroidDefault rect for \(region)")
        }
        XCTAssertTrue(VRMFaceLandmarks.vroidDefault.faceMaterialNames.contains("Face_00_SKIN"))
        XCTAssertTrue(VRMFaceLandmarks.vroidDefault.faceMaterialNames.contains("EyeIris_00"))

        // Parse from glTF root extension ARKAVO_vrm_cosmetics 0.1
        let extJSON = """
        {
          "asset": { "version": "2.0" },
          "extensions": {
            "ARKAVO_vrm_cosmetics": {
              "schemaVersion": "0.1",
              "faceMaterialNames": ["Face_00_SKIN", "Eyeline_00"],
              "faceLandmarks": {
                "lips": { "minU": 0.41, "minV": 0.65, "maxU": 0.59, "maxV": 0.75 },
                "leftEye": [0.51, 0.43, 0.69, 0.53]
              }
            }
          }
        }
        """
        let docExt = try JSONDecoder().decode(GLTFDocument.self, from: Data(extJSON.utf8))
        let parsedExt = try XCTUnwrap(VRMFaceLandmarks.parse(from: docExt))
        XCTAssertEqual(parsedExt.schemaVersion, "0.1")
        XCTAssertEqual(parsedExt.faceMaterialNames, ["Face_00_SKIN", "Eyeline_00"])
        XCTAssertEqual(parsedExt.rect(for: .lips)?.minU ?? 0, 0.41, accuracy: 1e-5)
        XCTAssertEqual(parsedExt.rect(for: .leftEye)?.maxV ?? 0, 0.53, accuracy: 1e-5)

        // Fallback to extras.vrmFaceLandmarks
        let extrasJSON = """
        {
          "asset": { "version": "2.0" },
          "extras": {
            "vrmFaceLandmarks": {
              "lips": { "minU": 0.35, "minV": 0.60, "maxU": 0.65, "maxV": 0.72 }
            }
          }
        }
        """
        let docExtras = try JSONDecoder().decode(GLTFDocument.self, from: Data(extrasJSON.utf8))
        let parsedExtras = try XCTUnwrap(VRMFaceLandmarks.parse(from: docExtras))
        XCTAssertEqual(parsedExtras.rect(for: .lips)?.minU ?? 0, 0.35, accuracy: 1e-5)
    }

    // MARK: - 6. Per-Pixel Finish Map in MToonShader.metal (texture(9) + fc_hasFinishMapTexture)

    func testPerPixelFinishMapRendersLocalizedSpecularOnlyOnPaintedRegion() throws {
        // Dark matte face base so specular highlight pops clearly on the painted right half
        let baseMTL = try makeSolidTexture(width: 32, height: 32, rgba: (60, 60, 80, 255))
        let decalMTL = try makeSolidTexture(width: 16, height: 16, rgba: (60, 60, 80, 255))

        let gltfMat = try JSONDecoder().decode(GLTFMaterial.self, from: Data(#"{"name":"Face_00_SKIN"}"#.utf8))
        let mat = VRMMaterial(from: gltfMat, textures: [])
        mat.baseColorTexture = VRMTexture(name: "face", mtlTexture: baseMTL)
        mat.mtoon = VRMMToonMaterial()
        mat.mtoon?.shadeColorFactor = [0.2, 0.2, 0.2]
        mat.mtoon?.outlineWidthMode = .none
        let model = try makeQuadModel(material: mat)

        // Place a metallic glossy finish strictly on the right half (u in [0.55, 0.95], v in [0.1, 0.9])
        let customLandmarks = VRMFaceLandmarks(regions: [
            .lips: VRMUVRect(minU: 0.55, minV: 0.10, maxU: 0.95, maxV: 0.90)
        ])
        let stack = try VRMTextureLayerStack(
            device: device,
            layers: [
                VRMTextureLayer(
                    name: "gloss_patch",
                    texture: decalMTL,
                    blendMode: .normal,
                    opacity: 1.0,
                    finish: VRMFinishOverride(metallic: 0.95, roughness: 0.15),
                    landmarkRegion: .lips
                )
            ],
            faceLandmarks: customLandmarks
        )
        try stack.apply(to: mat, slot: .baseColor, in: model)
        XCTAssertNotNil(mat.metallicRoughnessTexture?.mtlTexture)

        // Notice config.enableMaterialFinish is FALSE — per-pixel finish map activates automatically!
        var cfg = RendererConfig()
        cfg.colorPixelFormat = .rgba8Unorm
        cfg.enableMaterialFinish = false
        let renderer = VRMRenderer(device: device, config: cfg)
        renderer.loadModelWithoutWarmup(model)
        // Front light along -Z matches view direction from +Z -> peak NdotH = 1.0 on the quad!
        renderer.setLight(0, direction: [0, 0, -1], color: [1, 1, 1], intensity: 2.0)
        renderer.disableLight(1)
        renderer.disableLight(2)
        renderer.setAmbientColor([0, 0, 0])

        let rgba = try renderOffscreen(renderer: renderer, size: 64)
        // Left half of quad (x=22, y=32): matte unpainted skin (B=0 in finish map)
        let leftIdx = (32 * 64 + 22) * 4
        let leftLuma = Int(rgba[leftIdx]) + Int(rgba[leftIdx + 1]) + Int(rgba[leftIdx + 2])
        // Right half of quad (x=42, y=32): painted glossy metallic region (B=0.95, G=0.15)
        let rightIdx = (32 * 64 + 42) * 4
        let rightLuma = Int(rgba[rightIdx]) + Int(rgba[rightIdx + 1]) + Int(rgba[rightIdx + 2])

        XCTAssertGreaterThan(rightLuma, leftLuma + 40,
            "Painted finish region (luma=\(rightLuma)) must produce specular highlight over matte region (luma=\(leftLuma))")

        // Clearing restores original matte state (no finish map)
        stack.clear(from: mat, slot: .baseColor, in: model)
        XCTAssertNil(mat.metallicRoughnessTexture)
        let clearedRGBA = try renderOffscreen(renderer: renderer, size: 64)
        let clearedRightLuma = Int(clearedRGBA[rightIdx]) + Int(clearedRGBA[rightIdx + 1]) + Int(clearedRGBA[rightIdx + 2])
        XCTAssertEqual(clearedRightLuma, leftLuma, accuracy: 5, "Clearing stack must restore uniform matte appearance")
    }

    // MARK: - 7. Body MASK + .eraseAlpha Cutout Rendering

    func testEraseAlphaCreatesPixelExactMaskCutout() throws {
        let baseMTL = try makeSolidTexture(width: 32, height: 32, rgba: (255, 220, 200, 255))
        let holeMTL = try makeSolidTexture(width: 16, height: 16, rgba: (255, 255, 255, 255))

        let gltfMat = try JSONDecoder().decode(
            GLTFMaterial.self,
            from: Data(#"{"name":"Body_00_SKIN","alphaMode":"MASK","alphaCutoff":0.5}"#.utf8)
        )
        let mat = VRMMaterial(from: gltfMat, textures: [])
        mat.baseColorTexture = VRMTexture(name: "body", mtlTexture: baseMTL)
        mat.mtoon = VRMMToonMaterial()
        mat.mtoon?.outlineWidthMode = .none
        let model = try makeQuadModel(material: mat)

        // Cut a centered hole in the body texture using .eraseAlpha
        let centerRect = VRMFaceLandmarks(regions: [
            .nose: VRMUVRect(minU: 0.35, minV: 0.35, maxU: 0.65, maxV: 0.65)
        ])
        let stack = try VRMTextureLayerStack(
            device: device,
            layers: [VRMTextureLayer(texture: holeMTL, blendMode: .eraseAlpha, opacity: 1.0, landmarkRegion: .nose)],
            faceLandmarks: centerRect
        )
        try stack.apply(to: mat, slot: .baseColor, in: model)

        var cfg = RendererConfig()
        cfg.colorPixelFormat = .rgba8Unorm
        let renderer = VRMRenderer(device: device, config: cfg)
        renderer.loadModelWithoutWarmup(model)
        renderer.setLight(0, direction: [0, 0, -1], color: [1, 1, 1], intensity: 1.0)
        renderer.disableLight(1)
        renderer.disableLight(2)
        renderer.setAmbientColor([1, 1, 1])

        // Bright green background shows through the erased center cutout!
        let rgba = try renderOffscreen(
            renderer: renderer,
            size: 64,
            clearColor: MTLClearColor(red: 0, green: 1, blue: 0, alpha: 1)
        )
        let centerIdx = (32 * 64 + 32) * 4
        XCTAssertLessThan(rgba[centerIdx], 20, "Center cutout must discard and reveal green clear color")
        XCTAssertGreaterThan(rgba[centerIdx + 1], 240)

        // Uncut body pixel outside the hole (x=18, y=32) stays warm skin tone (high red)
        let edgeIdx = (32 * 64 + 18) * 4
        XCTAssertGreaterThan(rgba[edgeIdx], 180)
    }

    // MARK: - 8. PR Review Regressions (Finish Gating, Per-Binding Pools, Authored MR Factor Preservation)

    func testAuthoredMetallicRoughnessTextureRespectsEnableMaterialFinishFlag() throws {
        let baseMTL = try makeSolidTexture(width: 32, height: 32, rgba: (60, 60, 60, 255))
        // Authored glTF MR texture with full metallic (B=255) and low roughness (G=38)
        let authoredMR = try makeSolidTexture(width: 32, height: 32, rgba: (0, 38, 255, 255), pixelFormat: .rgba8Unorm)

        let gltfMat = try JSONDecoder().decode(GLTFMaterial.self, from: Data(#"{"name":"AuthoredPBR"}"#.utf8))
        let mat = VRMMaterial(from: gltfMat, textures: [])
        mat.baseColorTexture = VRMTexture(name: "base", mtlTexture: baseMTL)
        mat.metallicRoughnessTexture = VRMTexture(name: "authored_mr", mtlTexture: authoredMR)
        mat.metallicFactor = 1.0
        mat.roughnessFactor = 1.0
        mat.mtoon = VRMMToonMaterial()
        mat.mtoon?.shadeColorFactor = [0.2, 0.2, 0.2]
        mat.mtoon?.outlineWidthMode = .none
        XCTAssertFalse(mat.hasCosmeticFinishMap)

        let model = try makeQuadModel(material: mat)

        // With enableMaterialFinish == false, authored MR texture MUST NOT produce MToon specular
        var offCfg = RendererConfig()
        offCfg.colorPixelFormat = .rgba8Unorm
        offCfg.enableMaterialFinish = false
        let offRenderer = VRMRenderer(device: device, config: offCfg)
        offRenderer.loadModelWithoutWarmup(model)
        offRenderer.setLight(0, direction: [0, 0, -1], color: [1, 1, 1], intensity: 2.0)
        offRenderer.disableLight(1)
        offRenderer.disableLight(2)
        offRenderer.setAmbientColor([0, 0, 0])
        let offRGBA = try renderOffscreen(renderer: offRenderer, size: 64)

        // Compare against identical material without any MR texture
        let plainMat = VRMMaterial(from: gltfMat, textures: [])
        plainMat.baseColorTexture = VRMTexture(name: "base", mtlTexture: baseMTL)
        plainMat.mtoon = VRMMToonMaterial()
        plainMat.mtoon?.shadeColorFactor = [0.2, 0.2, 0.2]
        plainMat.mtoon?.outlineWidthMode = .none
        let plainModel = try makeQuadModel(material: plainMat)
        offRenderer.loadModelWithoutWarmup(plainModel)
        let plainRGBA = try renderOffscreen(renderer: offRenderer, size: 64)

        let centerIdx = (32 * 64 + 32) * 4
        let offLuma = Int(offRGBA[centerIdx]) + Int(offRGBA[centerIdx + 1]) + Int(offRGBA[centerIdx + 2])
        let plainLuma = Int(plainRGBA[centerIdx]) + Int(plainRGBA[centerIdx + 1]) + Int(plainRGBA[centerIdx + 2])
        XCTAssertEqual(offLuma, plainLuma, accuracy: 2,
            "Authored metallicRoughnessTexture must stay inactive when enableMaterialFinish is false")

        // Opting in via enableMaterialFinish == true activates the authored MR finish
        var onCfg = RendererConfig()
        onCfg.colorPixelFormat = .rgba8Unorm
        onCfg.enableMaterialFinish = true
        let onRenderer = VRMRenderer(device: device, config: onCfg)
        onRenderer.loadModelWithoutWarmup(model)
        onRenderer.setLight(0, direction: [0, 0, -1], color: [1, 1, 1], intensity: 2.0)
        onRenderer.disableLight(1)
        onRenderer.disableLight(2)
        onRenderer.setAmbientColor([0, 0, 0])
        let onRGBA = try renderOffscreen(renderer: onRenderer, size: 64)
        let onLuma = Int(onRGBA[centerIdx]) + Int(onRGBA[centerIdx + 1]) + Int(onRGBA[centerIdx + 2])
        XCTAssertGreaterThan(onLuma, offLuma + 40,
            "Enabling enableMaterialFinish must activate authored metallicRoughnessTexture specular")
    }

    func testSharedLayerStackAcrossThreeMaterialsNeverAliasesBoundTextures() throws {
        let baseA = try makeSolidTexture(width: 16, height: 16, rgba: (255, 0, 0, 255))
        let baseB = try makeSolidTexture(width: 16, height: 16, rgba: (0, 255, 0, 255))
        let baseC = try makeSolidTexture(width: 16, height: 16, rgba: (0, 0, 255, 255))
        let subtleDecal = try makeSolidTexture(width: 16, height: 16, rgba: (255, 255, 255, 32))

        let gltfMat = try JSONDecoder().decode(GLTFMaterial.self, from: Data(#"{"name":"Mat"}"#.utf8))
        let matA = VRMMaterial(from: gltfMat, textures: [])
        matA.baseColorTexture = VRMTexture(name: "A", mtlTexture: baseA)
        let matB = VRMMaterial(from: gltfMat, textures: [])
        matB.baseColorTexture = VRMTexture(name: "B", mtlTexture: baseB)
        let matC = VRMMaterial(from: gltfMat, textures: [])
        matC.baseColorTexture = VRMTexture(name: "C", mtlTexture: baseC)

        let stack = try VRMTextureLayerStack(
            device: device,
            layers: [
                VRMTextureLayer(
                    texture: subtleDecal,
                    blendMode: .normal,
                    opacity: 0.1,
                    finish: VRMFinishOverride(metallic: 0.8, roughness: 0.2)
                )
            ]
        )

        try stack.apply(to: matA)
        try stack.apply(to: matB)
        try stack.apply(to: matC)

        let texA = try XCTUnwrap(matA.baseColorTexture?.mtlTexture)
        let texB = try XCTUnwrap(matB.baseColorTexture?.mtlTexture)
        let texC = try XCTUnwrap(matC.baseColorTexture?.mtlTexture)
        XCTAssertFalse(texA === texB)
        XCTAssertFalse(texA === texC)
        XCTAssertFalse(texB === texC)

        let finA = try XCTUnwrap(matA.metallicRoughnessTexture?.mtlTexture)
        let finB = try XCTUnwrap(matB.metallicRoughnessTexture?.mtlTexture)
        let finC = try XCTUnwrap(matC.metallicRoughnessTexture?.mtlTexture)
        XCTAssertFalse(finA === finB)
        XCTAssertFalse(finA === finC)
        XCTAssertFalse(finB === finC)

        // Material A must still contain its red pixels after applying to B and C
        let pxA = readPixel(texA, x: 8, y: 8)
        let pxB = readPixel(texB, x: 8, y: 8)
        let pxC = readPixel(texC, x: 8, y: 8)
        XCTAssertGreaterThan(pxA.r, 230)
        XCTAssertLessThan(pxA.b, 80)
        XCTAssertGreaterThan(pxB.g, 230)
        XCTAssertLessThan(pxB.r, 80)
        XCTAssertGreaterThan(pxC.b, 230)
        XCTAssertLessThan(pxC.r, 80)
    }

    func testFinishLayerPreservesAuthoredMetallicRoughnessFactorsOnUnpaintedPixels() throws {
        let baseMTL = try makeSolidTexture(width: 32, height: 32, rgba: (80, 80, 80, 255))
        // Authored MR texture has B=255 (1.0) and G=204 (0.8), but material authored metallicFactor = 0.0, roughnessFactor = 0.5.
        let authoredMR = try makeSolidTexture(width: 32, height: 32, rgba: (0, 204, 255, 255), pixelFormat: .rgba8Unorm)
        let decalMTL = try makeSolidTexture(width: 16, height: 16, rgba: (80, 80, 80, 255))

        let gltfMat = try JSONDecoder().decode(GLTFMaterial.self, from: Data(#"{"name":"Face_MR"}"#.utf8))
        let mat = VRMMaterial(from: gltfMat, textures: [])
        mat.baseColorTexture = VRMTexture(name: "face", mtlTexture: baseMTL)
        mat.metallicRoughnessTexture = VRMTexture(name: "authored_mr", mtlTexture: authoredMR)
        mat.metallicFactor = 0.0
        mat.roughnessFactor = 0.5
        mat.mtoon = VRMMToonMaterial()
        mat.mtoon?.shadeColorFactor = [0.2, 0.2, 0.2]
        mat.mtoon?.outlineWidthMode = .none

        let landmarks = VRMFaceLandmarks(regions: [
            .lips: VRMUVRect(minU: 0.55, minV: 0.10, maxU: 0.95, maxV: 0.90)
        ])
        let stack = try VRMTextureLayerStack(
            device: device,
            layers: [
                VRMTextureLayer(
                    name: "lip_gloss",
                    texture: decalMTL,
                    blendMode: .normal,
                    opacity: 1.0,
                    finish: VRMFinishOverride(metallic: 0.9, roughness: 0.15),
                    landmarkRegion: .lips
                )
            ],
            faceLandmarks: landmarks
        )

        try stack.apply(to: mat)
        XCTAssertTrue(mat.hasCosmeticFinishMap)
        let finishTex = try XCTUnwrap(mat.metallicRoughnessTexture?.mtlTexture)

        // Unpainted left region (u = 0.25 -> x = 8): must preserve G ≈ 0.8 * 0.5 = 0.40 (~102) and B == 1.0 * 0.0 = 0
        let unpainted = readPixel(finishTex, x: 8, y: 16)
        XCTAssertEqual(unpainted.b, 0, accuracy: 2, "Unpainted region must preserve authored metallicFactor=0")
        XCTAssertEqual(unpainted.g, 102, accuracy: 4, "Unpainted region must preserve authored roughnessFactor * mr.g")

        // Painted right region (u = 0.75 -> x = 24): reflects cosmetic finish override (metallic=0.9 -> ~230, roughness=0.15 -> ~38)
        let painted = readPixel(finishTex, x: 24, y: 16)
        XCTAssertEqual(painted.b, 230, accuracy: 4)
        XCTAssertEqual(painted.g, 38, accuracy: 4)

        // Clearing restores original MR texture, factors, and clears hasCosmeticFinishMap
        stack.clear(from: mat)
        XCTAssertFalse(mat.hasCosmeticFinishMap)
        XCTAssertEqual(mat.metallicFactor, 0.0, accuracy: 1e-6)
        XCTAssertEqual(mat.roughnessFactor, 0.5, accuracy: 1e-6)
        XCTAssertTrue(mat.metallicRoughnessTexture?.mtlTexture === authoredMR)
    }
}
