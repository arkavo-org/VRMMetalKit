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
import simd
@testable import VRMMetalKit

/// `SpriteCacheSystem` composes its own render pass descriptor, so the depth
/// clear value is its choice, not the caller's. A host running reverse-Z
/// (`VRMRenderer.useReverseZ`, compares `.greater`/`.greaterEqual`) drawing
/// through a pass cleared to 1.0 has every fragment rejected and gets a
/// silently empty sprite — nothing errors, the cache just fills with blanks.
///
/// These tests drive the cache with a quad whose depth-stencil state and
/// projection are reverse-Z, and assert on the pixels that reach the cache
/// texture. The standard-Z case and the opt-out case are pinned alongside,
/// so the parameter cannot be made to work by flipping the default.
final class SpriteCacheReverseZTests: XCTestCase {

    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Failed to create command queue")
        }
        self.commandQueue = queue
    }

    /// A reverse-Z draw through the sprite cache must reach the texture.
    /// Fails before the `reverseZ` parameter existed: the pass cleared depth
    /// to 1.0, the far plane under reverse-Z, so `.greater` rejected every
    /// fragment and the cache texture came back fully transparent.
    func testReverseZDrawReachesCacheTexture() throws {
        let drawn = try renderQuadThroughCache(reverseZ: true, poseHash: 0xA1)
        XCTAssertGreaterThan(drawn, 100,
                             "Reverse-Z draw through renderToCache(reverseZ: true) covered \(drawn) pixels — the cache pass still clears depth to the reverse-Z far plane, so the depth test rejects everything")
    }

    /// The default path is unchanged: standard-Z projection with `.less`
    /// compares against a 1.0 clear still draws, exactly as before the
    /// parameter was added.
    func testStandardZDrawStillReachesCacheTextureByDefault() throws {
        let drawn = try renderQuadThroughCache(reverseZ: false, poseHash: 0xB2)
        XCTAssertGreaterThan(drawn, 100,
                             "Standard-Z draw through the default renderToCache path covered \(drawn) pixels — the pre-existing behaviour regressed")
    }

    /// Opt-in means opt-in: a reverse-Z draw that does NOT ask for the
    /// reverse-Z clear still lands on a 1.0-cleared buffer and draws nothing.
    /// Without this, the first test could pass by the default flipping to 0.0
    /// and breaking every existing standard-Z host.
    func testReverseZDrawDrawsNothingWhenNotOptedIn() throws {
        let drawn = try renderQuadThroughCache(reverseZ: true, poseHash: 0xC3, optIn: false)
        XCTAssertEqual(drawn, 0,
                       "\(drawn) pixels drew with reverse-Z compares through the default cache pass — the default depth clear is no longer the standard-Z far plane")
    }

    // MARK: - Helpers

    /// Renders one quad through `SpriteCacheSystem.renderToCache` and returns
    /// the number of covered pixels in the resulting cache texture.
    ///
    /// - Parameters:
    ///   - reverseZ: Builds the draw for reverse-Z — mirrored projection and a
    ///     `.greater` depth-stencil state — instead of standard-Z with `.less`.
    ///   - poseHash: Cache key; must be unique per render within a test run.
    ///   - optIn: Whether the reverse-Z depth clear is requested from the cache.
    ///     Defaults to matching `reverseZ`; pass `false` to exercise the
    ///     mismatch a non-opted-in host would hit.
    private func renderQuadThroughCache(reverseZ: Bool,
                                        poseHash: UInt64,
                                        optIn: Bool? = nil) throws -> Int {
        let size = 128
        let cache = SpriteCacheSystem(device: device, commandQueue: commandQueue)
        let pipeline = try makeQuadPipeline()

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = reverseZ ? .greater : .less
        depthDescriptor.isDepthWriteEnabled = true
        let depthState = try XCTUnwrap(device.makeDepthStencilState(descriptor: depthDescriptor))

        let projection = makePerspectiveProjection(fovY: Float.pi / 4,
                                                   aspectRatio: 1.0,
                                                   nearZ: 0.01,
                                                   farZ: 100.0)
        let view = makeLookAt(eye: SIMD3<Float>(0, 0, 3),
                              target: SIMD3<Float>(0, 0, 0),
                              up: SIMD3<Float>(0, 1, 0))
        let mvp = (reverseZ ? reverseZProjection(projection) : projection) * view

        let captured = TextureBox()
        let commandBuffer = try XCTUnwrap(commandQueue.makeCommandBuffer())

        _ = cache.renderToCache(
            characterID: "reverseZ",
            poseHash: poseHash,
            resolution: CGSize(width: size, height: size),
            commandBuffer: commandBuffer,
            reverseZ: optIn ?? reverseZ
        ) { encoder, texture in
            captured.texture = texture
            encoder.setRenderPipelineState(pipeline)
            encoder.setDepthStencilState(depthState)
            var transform = mvp
            encoder.setVertexBytes(&transform, length: MemoryLayout<float4x4>.size, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        let texture = try XCTUnwrap(captured.texture, "renderToCache never invoked the render block")
        let bytesPerRow = size * 4
        let readback = try XCTUnwrap(device.makeBuffer(length: bytesPerRow * size,
                                                       options: .storageModeShared))
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: size, height: size, depth: 1),
                  to: readback, destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: bytesPerRow * size)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let pixels = UnsafeRawBufferPointer(start: readback.contents(), count: bytesPerRow * size)
        return stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 0 }.count
    }

    private func makeQuadPipeline() throws -> MTLRenderPipelineState {
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        constant float2 kQuad[6] = {
            float2(-0.5, -0.5), float2( 0.5, -0.5), float2( 0.5,  0.5),
            float2(-0.5, -0.5), float2( 0.5,  0.5), float2(-0.5,  0.5)
        };

        vertex float4 quad_vertex(uint vid [[vertex_id]],
                                  constant float4x4 &mvp [[buffer(0)]]) {
            return mvp * float4(kQuad[vid], 0.0, 1.0);
        }

        fragment float4 quad_fragment() {
            return float4(1.0, 0.0, 0.0, 1.0);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "quad_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "quad_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.depthAttachmentPixelFormat = .depth32Float
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private final class TextureBox: @unchecked Sendable {
        var texture: MTLTexture?
    }
}
