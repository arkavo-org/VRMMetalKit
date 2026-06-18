// Copyright 2026 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Validates the crowd render pattern the `VRMBenchmark --mode crowd` load test
/// (and any future #199 occlusion work) builds on: N renderers SHARE one loaded
/// model and draw once each into a SHARED color+depth target, positioned by
/// baking a world offset into the view matrix with a shared projection. This is
/// the cheapest correct way to render a crowd today (1× geometry memory), and it
/// must (a) render, (b) not deadlock on the per-renderer in-flight semaphore, and
/// (c) place distinct avatars (more cover more pixels).
@MainActor
final class CrowdRenderTests: XCTestCase {

    private let size = 256

    private func renderCrowd(device: MTLDevice, queue: MTLCommandQueue,
                             model: VRMModel, count: Int, spacing: Float) throws -> [UInt8] {
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .shared
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: size, height: size, mipmapped: false)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private
        guard let colorTex = device.makeTexture(descriptor: colorDesc),
              let depthTex = device.makeTexture(descriptor: depthDesc),
              let cb = queue.makeCommandBuffer() else {
            throw XCTSkip("Could not allocate crowd render targets")
        }

        let proj = RenderTestSupport.makePerspective(
            fovRadians: 60.0 * .pi / 180.0, aspect: 1, near: 0.05, far: 100)
        let view = RenderTestSupport.makeLookAt(
            eye: SIMD3<Float>(0, 1.3, 3.5), center: SIMD3<Float>(0, 1.0, 0), up: SIMD3<Float>(0, 1, 0))

        var renderers: [VRMRenderer] = []
        for i in 0..<count {
            var c = RendererConfig()
            c.sampleCount = 1
            c.strict = .off
            c.colorPixelFormat = .rgba8Unorm
            let r = VRMRenderer(device: device, config: c)
            r.loadModel(model)                       // shared model — no per-avatar copy
            r.enableSpringBone = false
            r.skipPreDrawTransformUpdate = true       // static; no mutation of the shared model
            r.setupBrightToonLighting()
            r.projectionMatrix = proj
            let offset = SIMD3<Float>((Float(i) - Float(count - 1) / 2) * spacing, 0, 0)
            var t = matrix_identity_float4x4
            t.columns.3 = SIMD4<Float>(offset.x, offset.y, offset.z, 1)
            r.viewMatrix = simd_mul(view, t)          // bake world offset into the view
            renderers.append(r)
        }

        for i in 0..<count {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = colorTex
            rpd.colorAttachments[0].loadAction = (i == 0) ? .clear : .load
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            rpd.depthAttachment.texture = depthTex
            rpd.depthAttachment.loadAction = (i == 0) ? .clear : .load
            rpd.depthAttachment.storeAction = .store
            rpd.depthAttachment.clearDepth = 1.0
            renderers[i].drawOffscreenHeadless(
                to: colorTex, depth: depthTex, commandBuffer: cb, renderPassDescriptor: rpd)
        }
        cb.commit()
        cb.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        bytes.withUnsafeMutableBytes { buf in
            colorTex.getBytes(buf.baseAddress!, bytesPerRow: size * 4,
                              from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        }
        return bytes
    }

    private func coverage(_ px: [UInt8]) -> Int {
        var n = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i] > 8 || px[i + 1] > 8 || px[i + 2] > 8 {
            n += 1
        }
        return n
    }

    func testSharedModelCrowdRendersDistinctAvatars() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal not available") }
        guard let queue = device.makeCommandQueue() else { throw XCTSkip("No command queue") }
        let path = getTestVRM10ModelPath()
        try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)

        // 5 spread avatars must not deadlock (5 > the renderer's 3 in-flight slots,
        // but each renderer draws once so its own semaphore is never exhausted).
        let one = try renderCrowd(device: device, queue: queue, model: model, count: 1, spacing: 1.0)
        let five = try renderCrowd(device: device, queue: queue, model: model, count: 5, spacing: 1.0)

        let c1 = coverage(one)
        let c5 = coverage(five)
        XCTAssertGreaterThan(c1, 0, "single avatar rendered nothing")
        XCTAssertGreaterThan(c5, c1, "5 spread avatars should cover more pixels than 1 — the shared-model, shared-depth crowd path renders distinct avatars")
    }
}
