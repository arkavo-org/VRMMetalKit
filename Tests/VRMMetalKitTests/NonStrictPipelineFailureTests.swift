//
// Copyright 2026 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

import XCTest
import Metal
@testable import VRMMetalKit

/// Issue #336: the 0.18.0 metallib slices were compiled with a beta Metal
/// toolchain (MSL 4.1) and `MTLDevice.makeLibrary` rejects them on macOS 26.
/// With `strict: .off` the resulting setup failure was swallowed (`vrmLog` is
/// compiled out by default), leaving nil pipelines that wedged the first draw
/// in the legacy `drawCore` assert. These tests pin both halves: the committed
/// slices must load on the OS running the tests, and a renderer whose pipeline
/// setup failed must skip frames cleanly instead of trapping.
final class NonStrictPipelineFailureTests: XCTestCase {

    /// The committed metallib must load on this OS. Fails with the exact
    /// driver error when a slice was built by a toolchain whose language
    /// version exceeds the deployment floor (the #336 regression), instead of
    /// the dozens of confusing downstream pipeline failures it causes.
    func testBundledShaderLibraryLoadsOnThisOS() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no GPU") }
        XCTAssertNoThrow(
            try VRMShaderLibraryLoader.loadBundledLibrary(device: device),
            "Bundled \(VRMShaderLibraryLoader.bundledLibraryName).metallib does not load on this OS. " +
            "Rebuild the slices with the release toolchain (`make shaders`) — see issue #336."
        )
    }

    /// With `strict: .off`, a renderer whose pipeline setup failed must report
    /// itself not ready to draw — without trapping — so `drawCore` can skip
    /// the frame instead of wedging the host's main thread.
    func testPipelinesNotReadyAfterSetupFailure() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no GPU") }
        let renderer = VRMRenderer(device: device, config: RendererConfig(strict: .off))
        // Reproduce the state a swallowed setup failure leaves behind (an
        // unloadable metallib nils every pipeline — there is no config-level
        // injection for that, so null the state directly).
        renderer.opaquePipelineState = nil

        XCTAssertFalse(renderer.pipelinesReadyForDraw(),
                       "A renderer with nil pipelines must report not-ready instead of trapping")
    }

    /// A healthy renderer must remain drawable — the not-ready guard must not
    /// false-positive and silently blank rendering for working configs.
    func testPipelinesReadyForValidConfig() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no GPU") }
        let renderer = VRMRenderer(device: device, config: RendererConfig(strict: .off))
        XCTAssertNotNil(renderer.opaquePipelineState)
        XCTAssertTrue(renderer.pipelinesReadyForDraw())
    }

    /// End-to-end: a non-strict draw with nil pipelines must return cleanly.
    /// Draws more frames than the triple-buffer ring to prove the skipped
    /// frames also released their inflight-semaphore slot (a missed signal
    /// here deadlocks the fourth call).
    @MainActor
    func testDrawSkipsFrameInsteadOfTrappingWhenPipelinesNil() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no GPU") }
        let renderer = VRMRenderer(device: device, config: RendererConfig(strict: .off))
        renderer.opaquePipelineState = nil
        renderer.loadModel(Self.makeMinimalModel())

        guard let queue = device.makeCommandQueue() else { throw XCTSkip("no command queue") }
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 16, height: 16, mipmapped: false)
        texDesc.usage = [.renderTarget]
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: 16, height: 16, mipmapped: false)
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private
        guard let color = device.makeTexture(descriptor: texDesc),
              let depth = device.makeTexture(descriptor: depthDesc) else {
            throw XCTSkip("texture allocation failed")
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = color
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.depthAttachment.texture = depth
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.storeAction = .dontCare

        for _ in 0..<4 {
            guard let commandBuffer = queue.makeCommandBuffer() else {
                throw XCTSkip("command buffer allocation failed")
            }
            renderer.drawOffscreenHeadless(
                to: color, depth: depth,
                commandBuffer: commandBuffer, renderPassDescriptor: rpd)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }
        // Reaching here means no trap and no semaphore deadlock.
    }

    private static func makeMinimalModel() -> VRMModel {
        let json = #"{"asset":{"version":"2.0"}}"#
        let gltf = try! JSONDecoder().decode(GLTFDocument.self, from: Data(json.utf8))
        return VRMModel(specVersion: .v1_0, meta: VRMMeta(licenseUrl: ""), humanoid: nil, gltf: gltf)
    }
}
