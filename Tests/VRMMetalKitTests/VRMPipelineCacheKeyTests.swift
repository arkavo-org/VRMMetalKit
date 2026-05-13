//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Regression test for the latent ``VRMPipelineCache`` key bug surfaced while
/// diagnosing vrm-conformance #213. Cache keys were static strings
/// (`"mtoon_opaque"`, `"mtoon_blend"`, ...) that didn't include the descriptor
/// state actually used to compile the pipeline (`colorAttachments[0].pixelFormat`
/// and `rasterSampleCount`). Two renderers asking for the same logical pipeline
/// at different formats received the **first** renderer's pipeline back —
/// silently routing draws to a pipeline with the wrong attachment layout.
///
/// In single-renderer use this never bit (one config, one cache entry). It
/// surfaced once the vrm-conformance corpus tried to switch the framebuffer
/// pixel format between renders — see #213's full diagnosis.
@MainActor
final class VRMPipelineCacheKeyTests: XCTestCase {

    private var device: MTLDevice!

    override func setUp() async throws {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        device = dev
        // Reset cache so the test owns its own occupancy counts. The cache
        // is process-wide, so prior tests would otherwise pollute the stats.
        VRMPipelineCache.shared.clearCache()
    }

    /// Build three renderers that differ only in pipeline-affecting config
    /// fields and assert each produced a *distinct* cache entry per logical
    /// pipeline name. Pre-fix, the second and third renderers would reuse the
    /// first's pipeline state (wrong format / wrong sample count) and the
    /// cache occupancy after the third renderer would equal the count after
    /// the first.
    func testDifferentPixelFormatsProduceDistinctCacheEntries() throws {
        // Renderer A: linear bgra8Unorm, single-sample (the package default).
        var configA = RendererConfig()
        configA.colorPixelFormat = .bgra8Unorm
        configA.sampleCount = 1
        _ = VRMRenderer(device: device, config: configA)
        let countA = VRMPipelineCache.shared.getStatistics().pipelineStateCount
        XCTAssertGreaterThan(countA, 0, "First renderer must populate at least one cache entry.")

        // Renderer B: same sample count, sRGB-encoded format. Must NOT reuse
        // A's cached pipelines — they were compiled against bgra8Unorm.
        var configB = RendererConfig()
        configB.colorPixelFormat = .rgba8Unorm_srgb
        configB.sampleCount = 1
        _ = VRMRenderer(device: device, config: configB)
        let countB = VRMPipelineCache.shared.getStatistics().pipelineStateCount
        XCTAssertGreaterThan(
            countB, countA,
            "Pipelines for a second pixel format must be new cache entries. " +
            "Got countA=\(countA), countB=\(countB) — same count means the cache " +
            "returned A's pipelines for B's format request (vrm-conformance #213 root cause)."
        )

        // Renderer C: same format as A, different sample count. Must also be
        // a distinct cache slice — `rasterSampleCount` affects pipeline
        // compilation (MSAA shader variants) the same way pixel format does.
        var configC = RendererConfig()
        configC.colorPixelFormat = .bgra8Unorm
        configC.sampleCount = 4
        _ = VRMRenderer(device: device, config: configC)
        let countC = VRMPipelineCache.shared.getStatistics().pipelineStateCount
        XCTAssertGreaterThan(
            countC, countB,
            "Pipelines for a different sample count must be new cache entries. " +
            "Got countB=\(countB), countC=\(countC) — same count means the cache " +
            "ignores sampleCount, which causes the same wrong-pipeline-returned " +
            "class of bug as the pixel-format omission did."
        )
    }

    /// End-to-end correctness witness. Build two renderers — `.rgba8Unorm`
    /// (linear) and `.rgba8Unorm_srgb` — and render the exact same scene.
    /// With the cache-key fix in place, the sRGB renderer's center pixel
    /// must be visibly brighter than the linear renderer's (sRGB encoding
    /// pushes mid-range linear values up by ~50%). Pre-fix, both renderers
    /// got the same cached pipeline and produced identical bytes.
    func testCachedPipelineRespectsConfiguredPixelFormat() throws {
        let linearByte = try renderCenterRedByte(format: .rgba8Unorm)
        let srgbByte   = try renderCenterRedByte(format: .rgba8Unorm_srgb)

        print("[#213 cache-key] linear=\(linearByte), srgb=\(srgbByte)")

        // Shader output for this scene is ~0.46 linear. Encoding gap:
        //   .rgba8Unorm:      byte ≈ 0.46 * 255 ≈ 117
        //   .rgba8Unorm_srgb: byte ≈ sRGB_encode(0.46) * 255 ≈ 180
        XCTAssertGreaterThan(
            srgbByte - linearByte, 40,
            "sRGB-encoded center pixel must be at least 40 bytes brighter than " +
            "the linear-encoded center pixel (got srgb=\(srgbByte), linear=\(linearByte), " +
            "delta=\(srgbByte - linearByte)). A small delta means the cache returned the " +
            "wrong-format pipeline and the GPU never applied sRGB encoding."
        )
    }

    /// Build a renderer with the supplied pixel format, render a single MToon
    /// triangle lit from above into a 32×32 framebuffer of that format, and
    /// return the R-channel byte at the center pixel.
    ///
    /// **Important:** does *not* clear the pipeline cache. The two calls in
    /// `testCachedPipelineRespectsConfiguredPixelFormat` share a cache, so the
    /// pre-fix collision (second renderer reuses first's wrong-format pipeline)
    /// is what the test relies on to fail.
    private func renderCenterRedByte(format: MTLPixelFormat) throws -> Int {
        var config = RendererConfig()
        config.colorPixelFormat = format
        config.sampleCount = 1
        config.strict = .off
        let renderer = VRMRenderer(device: device, config: config)
        renderer.performanceTracker = PerformanceTracker()

        // Single triangle filling NDC, normal pointing toward camera. Lit
        // straight on so NdotL=1 and the MToon shader exercises its
        // brightest direct-lighting path — that's where the format-encode
        // delta is largest.
        let model = try makeSingleTriangleModel()
        renderer.loadModel(model)
        renderer.viewMatrix = matrix_identity_float4x4
        renderer.projectionMatrix = matrix_identity_float4x4
        renderer.setLight(0, direction: SIMD3<Float>(0, 0, 1), color: SIMD3<Float>(1, 1, 1), intensity: 1.0)
        renderer.disableLight(1)
        renderer.disableLight(2)
        renderer.setAmbientColor(SIMD3<Float>(0, 0, 0))

        let size = 32
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: size, height: size, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .shared
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: size, height: size, mipmapped: false)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private

        guard let colorTex = device.makeTexture(descriptor: colorDesc),
              let depthTex = device.makeTexture(descriptor: depthDesc),
              let queue = device.makeCommandQueue(),
              let cb = queue.makeCommandBuffer() else {
            throw XCTSkip("Could not allocate Metal render targets")
        }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = colorTex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        rpd.depthAttachment.texture = depthTex
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1.0
        rpd.depthAttachment.storeAction = .dontCare

        renderer.drawOffscreenHeadless(to: colorTex, depth: depthTex, commandBuffer: cb, renderPassDescriptor: rpd)
        cb.commit()
        cb.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        bytes.withUnsafeMutableBytes { buf in
            colorTex.getBytes(buf.baseAddress!, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        }
        // R-channel byte at center pixel; rgba8Unorm stores RGBA in memory order.
        let i = ((size / 2) * size + size / 2) * 4
        return Int(bytes[i])
    }

    /// One MToon triangle filling NDC with a +Z normal (lit pole when the
    /// light comes from the camera). baseColor white, shadeColor mid-gray —
    /// matches the conformance corpus's MToon defaults so the brightness
    /// arithmetic is identical to what surfaced #213.
    private func makeSingleTriangleModel() throws -> VRMModel {
        let gltfJSON = """
        {"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],
         "nodes":[{"name":"root","mesh":0}]}
        """
        let gltf = try JSONDecoder().decode(GLTFDocument.self, from: gltfJSON.data(using: .utf8)!)
        let model = VRMModel(
            specVersion: .v1_0,
            meta: VRMMeta(licenseUrl: "https://vrm.dev/licenses/1.0/"),
            humanoid: nil,
            gltf: gltf
        )
        for (i, gltfNode) in (gltf.nodes ?? []).enumerated() {
            model.nodes.append(VRMNode(index: i, gltfNode: gltfNode))
        }
        for n in model.nodes { n.updateWorldTransform() }

        let mesh = VRMMesh(name: "tri")
        let primitive = VRMPrimitive()
        var verts = [VRMVertex(), VRMVertex(), VRMVertex()]
        verts[0].position = SIMD3<Float>(-0.9, -0.9, 0)
        verts[1].position = SIMD3<Float>( 0.9, -0.9, 0)
        verts[2].position = SIMD3<Float>( 0.0,  0.9, 0)
        for i in 0..<3 {
            verts[i].normal = SIMD3<Float>(0, 0, 1)
            verts[i].texCoord = SIMD2<Float>(0, 0)
            verts[i].color = SIMD4<Float>(1, 1, 1, 1)
        }
        primitive.vertexCount = 3
        primitive.vertexBuffer = device.makeBuffer(
            bytes: verts,
            length: 3 * MemoryLayout<VRMVertex>.stride,
            options: .storageModeShared
        )
        primitive.localMin = SIMD3<Float>(-0.9, -0.9, 0)
        primitive.localMax = SIMD3<Float>( 0.9,  0.9, 0)
        let indices: [UInt16] = [0, 1, 2]
        primitive.indexBuffer = device.makeBuffer(
            bytes: indices,
            length: 3 * MemoryLayout<UInt16>.stride,
            options: .storageModeShared
        )
        primitive.indexCount = 3
        primitive.indexType = .uint16
        primitive.indexBufferOffset = 0
        primitive.primitiveType = .triangle
        primitive.hasNormals = true
        primitive.hasTexCoords = false
        primitive.hasColors = false
        primitive.hasJoints = false
        primitive.hasWeights = false
        primitive.requiredPaletteSize = 0
        primitive.materialIndex = 0
        mesh.primitives = [primitive]
        model.meshes = [mesh]

        let materialJSON = """
        {
          "name":"mtoon_test",
          "pbrMetallicRoughness":{"baseColorFactor":[1.0,1.0,1.0,1.0]},
          "extensions":{
            "VRMC_materials_mtoon":{
              "specVersion":"1.0",
              "shadeColorFactor":[0.5,0.5,0.5],
              "shadingToonyFactor":0.9,
              "shadingShiftFactor":0.0,
              "giEqualizationFactor":0.9
            }
          }
        }
        """
        let gltfMat = try JSONDecoder().decode(GLTFMaterial.self, from: materialJSON.data(using: .utf8)!)
        let material = VRMMaterial(from: gltfMat, textures: [], vrm0MaterialProperty: nil, vrmVersion: .v1_0)
        model.materials = [material]
        return model
    }
}
