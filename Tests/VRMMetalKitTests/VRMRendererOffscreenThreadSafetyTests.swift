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
import simd
@testable import VRMMetalKit

/// Regression coverage for the two thread-safety fixes in #384, neither of
/// which shipped with a test.
///
/// Deliberately *not* `@MainActor`: the whole point of
/// ``VRMRenderer/drawOffscreen(to:depth:commandBuffer:renderPassDescriptor:)``
/// is that a host whose render loop does not run on the main actor (a
/// CompositorServices frame loop on visionOS) can drive it. A `@MainActor`
/// test class would run every case on the main thread and silently pass even
/// if the main-actor pin came back.
final class VRMRendererOffscreenThreadSafetyTests: XCTestCase {

    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var model: VRMModel!

    override func setUp() async throws {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device not available") }
        guard let q = d.makeCommandQueue() else { throw XCTSkip("Could not create command queue") }
        device = d
        queue = q

        // A model is mandatory, not incidental: `drawCore` returns at its
        // `guard let model` before ever reaching the viewport cascade or
        // installing the command-buffer completion handler. Without one, every
        // case here would pass while exercising none of the code under test.
        let path = getTestVRM10ModelPath()
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Test VRM 1.0 model not found (set MUSE_RESOURCES_PATH)")
        }
        model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: d)
    }

    /// Renderer with the model loaded and camera set, ready to produce a frame.
    private func makeRenderer(aspect: Float) -> VRMRenderer {
        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.projectionMatrix = makePerspectiveProjection(
            fovY: Float.pi / 4, aspectRatio: aspect, nearZ: 0.01, farZ: 100.0)
        renderer.viewMatrix = RenderTestSupport.makeLookAt(
            eye: SIMD3<Float>(0, 1.2, 2.0),
            center: SIMD3<Float>(0, 1.2, 0),
            up: SIMD3<Float>(0, 1, 0))
        return renderer
    }

    // MARK: - Fixtures

    /// `@unchecked Sendable`: the textures and the pass descriptor are built
    /// once on the test thread, then handed to exactly one render thread and
    /// never mutated afterwards, so the hand-off is the only cross-thread
    /// access and it happens-before the render.
    private struct Target: @unchecked Sendable {
        let color: MTLTexture
        let depth: MTLTexture
        let descriptor: MTLRenderPassDescriptor
    }

    private func makeTarget(width: Int, height: Int) throws -> Target {
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .private

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private

        guard let color = device.makeTexture(descriptor: colorDesc),
              let depth = device.makeTexture(descriptor: depthDesc) else {
            throw XCTSkip("Could not allocate render targets")
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1.0

        return Target(color: color, depth: depth, descriptor: pass)
    }

    /// Runs `body` on a dedicated non-main thread and waits for it, so a
    /// main-actor violation surfaces as a trap here rather than being masked
    /// by the test already running on the main thread.
    private func onRenderThread(timeout: TimeInterval = 30, _ body: @escaping @Sendable () -> Void) {
        let done = expectation(description: "render thread finished")
        let thread = Thread {
            body()
            done.fulfill()
        }
        thread.name = "VRM Test Render Thread"
        thread.start()
        wait(for: [done], timeout: timeout)
    }

    // MARK: - drawOffscreen off the main actor

    /// `drawOffscreen` must complete when driven from a non-main thread.
    ///
    /// Before #384 this was impossible: the only offscreen entry point was
    /// `@MainActor drawOffscreenHeadless`, and `drawCore`'s viewport read went
    /// through `MainActor.assumeIsolated`, which traps off the main actor.
    func testDrawOffscreenRunsOnBackgroundThread() throws {
        let renderer = makeRenderer(aspect: 128.0 / 96.0)
        let target = try makeTarget(width: 128, height: 96)

        onRenderThread { [queue] in
            guard let commandBuffer = queue?.makeCommandBuffer() else {
                XCTFail("Could not create command buffer"); return
            }
            XCTAssertFalse(Thread.isMainThread, "Test must exercise a non-main thread to be meaningful.")
            renderer.drawOffscreen(
                to: target.color, depth: target.depth,
                commandBuffer: commandBuffer, renderPassDescriptor: target.descriptor)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            XCTAssertNil(commandBuffer.error, "Offscreen frame failed: \(String(describing: commandBuffer.error))")
        }
    }

    /// The viewport handed to the shaders must be the render target's
    /// dimensions — not the 1280x720 `Uniforms` default, and not a stale size
    /// left over from another entry point.
    func testDrawOffscreenPublishesTextureDimensionsAsViewport() throws {
        let width = 321, height = 214   // deliberately unlike any default
        let renderer = makeRenderer(aspect: Float(width) / Float(height))
        let target = try makeTarget(width: width, height: height)

        onRenderThread { [queue] in
            guard let commandBuffer = queue?.makeCommandBuffer() else {
                XCTFail("Could not create command buffer"); return
            }
            renderer.drawOffscreen(
                to: target.color, depth: target.depth,
                commandBuffer: commandBuffer, renderPassDescriptor: target.descriptor)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }

        // `currentUniformBufferIndex` is private, so scan the triple-buffered
        // ring for the frame that was just written.
        let expected = SIMD2<Float>(Float(width), Float(height))
        let found = renderer.uniformsBuffers.contains { buffer in
            buffer.contents().load(as: Uniforms.self).viewportSize == expected
        }
        XCTAssertTrue(
            found,
            "No uniform buffer carries the offscreen viewport \(expected); "
            + "sizes seen: \(renderer.uniformsBuffers.map { $0.contents().load(as: Uniforms.self).viewportSize })")
    }

    // MARK: - Semaphore lifetime across teardown

    /// Releasing the renderer while a frame is still on the GPU must not trap.
    ///
    /// The completion handler signalled `inflightSemaphore` through
    /// `[weak self]`; when the host dropped its last reference mid-flight (an
    /// immersive space closing), the signal was skipped and the semaphore
    /// deallocated below its creation value — which libdispatch traps on with
    /// "BUG IN CLIENT OF LIBDISPATCH: Semaphore object deallocated while in
    /// use". #384 captures the semaphore strongly; this pins that.
    func testReleasingRendererWithFrameInFlightDoesNotTrap() throws {
        let target = try makeTarget(width: 64, height: 64)
        // Holds the only strong reference, so the render thread can drop it
        // mid-flight. The renderer itself is built on the test thread, keeping
        // this case about teardown rather than about background construction.
        let box = RendererBox(makeRenderer(aspect: 1.0))

        onRenderThread { [queue] in
            guard let commandBuffer = queue?.makeCommandBuffer() else {
                XCTFail("Could not create command buffer"); return
            }
            // No local strong binding: the box must hold the ONLY reference,
            // or nilling it below will not actually deallocate the renderer
            // and this case silently stops testing anything.
            box.renderer!.drawOffscreen(
                to: target.color, depth: target.depth,
                commandBuffer: commandBuffer, renderPassDescriptor: target.descriptor)
            commandBuffer.commit()

            // Last reference drops while the frame is still on the GPU. A
            // weak-self signal would be skipped here, leaving the semaphore
            // below its creation value when it deallocates.
            // Guards against this case silently going vacuous: if a future
            // change makes something else retain the renderer, the scenario
            // stops reproducing and the assertion below catches that.
            weak var probe = box.renderer
            box.renderer = nil
            XCTAssertNil(
                probe,
                "The box must hold the only reference — if the renderer survives here, "
                + "this case is no longer exercising teardown-with-frame-in-flight.")

            commandBuffer.waitUntilCompleted()
            XCTAssertNil(commandBuffer.error, "Frame failed: \(String(describing: commandBuffer.error))")
        }
    }
}

/// Mutable single-reference holder so a test can release the renderer from a
/// different thread than the one that built it.
private final class RendererBox: @unchecked Sendable {
    var renderer: VRMRenderer?
    init(_ renderer: VRMRenderer?) { self.renderer = renderer }
}
