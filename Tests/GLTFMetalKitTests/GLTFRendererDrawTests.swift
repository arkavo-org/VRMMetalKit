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
@testable import GLTFMetalKit

/// Phase 3a step 4a acceptance: a hand-built triangle goes in, non-zero
/// pixels come out. The full plumbing (vertex descriptor, pipeline state,
/// PBR + IBL fragment, default fallback textures, sampler bindings) has to
/// agree for this to produce anything other than a black frame.
final class GLTFRendererDrawTests: XCTestCase {

    func testRendersTriangleWithNonZeroPixels() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            XCTFail("Could not create command queue"); return
        }

        let renderer = try GLTFRenderer(device: device)

        // --- Pipeline state -------------------------------------------------

        let colorFormat: MTLPixelFormat = .bgra8Unorm
        let depthFormat: MTLPixelFormat = .depth32Float

        let pipelineState = try renderer.makeOpaquePBRPipelineState(
            colorFormat: colorFormat,
            depthFormat: depthFormat
        )

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            XCTFail("Could not create depth state"); return
        }

        // --- Triangle -------------------------------------------------------
        //
        // Z-facing equilateral triangle, white base color, mid-roughness.
        // Vertex positions chosen so the triangle fully covers the
        // framebuffer center; light is +Y so the diffuse term contributes
        // meaningfully even before IBL is plugged in.

        let vertices: [GLTFRenderableVertex] = [
            GLTFRenderableVertex(position: SIMD3<Float>( 0.0,  0.6, 0.0),
                                 normal:   SIMD3<Float>( 0,   0,   1),
                                 tangent:  SIMD4<Float>(1, 0, 0, 1),
                                 uv0:      SIMD2<Float>(0.5, 0.0)),
            GLTFRenderableVertex(position: SIMD3<Float>(-0.6, -0.4, 0.0),
                                 normal:   SIMD3<Float>( 0,   0,   1),
                                 tangent:  SIMD4<Float>(1, 0, 0, 1),
                                 uv0:      SIMD2<Float>(0.0, 1.0)),
            GLTFRenderableVertex(position: SIMD3<Float>( 0.6, -0.4, 0.0),
                                 normal:   SIMD3<Float>( 0,   0,   1),
                                 tangent:  SIMD4<Float>(1, 0, 0, 1),
                                 uv0:      SIMD2<Float>(1.0, 1.0)),
        ]

        guard let mesh = GLTFRenderableMesh.make(vertices: vertices, device: device) else {
            XCTFail("Could not create vertex buffer"); return
        }

        var materialUniforms = GLTFMaterialUniforms(
            baseColorFactor: SIMD4<Float>(0.9, 0.6, 0.3, 1.0),  // warm tan — easy to distinguish from black
            emissiveFactor: SIMD3<Float>(0, 0, 0),
            metallicFactor: 0.0,
            roughnessFactor: 0.5
        )
        // No bound material textures — the renderer will use its 1×1 defaults
        // and the fragment will fall through to the factors above.
        _ = materialUniforms

        let material = GLTFRenderableMaterial(uniforms: materialUniforms)

        let calls = [
            GLTFDrawCall(mesh: mesh, material: material, modelMatrix: matrix_identity_float4x4)
        ]

        // --- Scene state ----------------------------------------------------

        let scene = GLTFSceneState(
            viewProjection: matrix_identity_float4x4,
            cameraPosition: SIMD3<Float>(0, 0, 2),
            lightDirection: normalize(SIMD3<Float>(0, 0, -1)),
            lightColor: SIMD3<Float>(3.0, 3.0, 3.0)
        )

        // --- Offscreen render targets ---------------------------------------

        let width = 256
        let height = 256

        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorFormat, width: width, height: height, mipmapped: false
        )
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        colorDescriptor.storageMode = .shared
        guard let colorTexture = device.makeTexture(descriptor: colorDescriptor) else {
            XCTFail("Could not create color texture"); return
        }

        let depthDescriptor2 = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: depthFormat, width: width, height: height, mipmapped: false
        )
        depthDescriptor2.usage = [.renderTarget]
        depthDescriptor2.storageMode = .private
        guard let depthTexture = device.makeTexture(descriptor: depthDescriptor2) else {
            XCTFail("Could not create depth texture"); return
        }

        // --- Render pass ----------------------------------------------------

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = colorTexture
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.depthAttachment.texture = depthTexture
        renderPass.depthAttachment.loadAction = .clear
        renderPass.depthAttachment.clearDepth = 1.0
        renderPass.depthAttachment.storeAction = .dontCare

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            XCTFail("Could not create command buffer/encoder"); return
        }

        renderer.encodeOpaqueDrawCalls(
            calls,
            scene: scene,
            pipelineState: pipelineState,
            depthState: depthState,
            encoder: encoder
        )

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            XCTFail("Command buffer failed: \(error.localizedDescription)")
            return
        }

        // --- Pixel readback -------------------------------------------------

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBufferPointer { ptr in
            colorTexture.getBytes(ptr.baseAddress!,
                                  bytesPerRow: bytesPerRow,
                                  from: MTLRegionMake2D(0, 0, width, height),
                                  mipmapLevel: 0)
        }

        // Center pixel must be lit (background is black; lit triangle covers center).
        let centerOffset = (height / 2) * bytesPerRow + (width / 2) * 4
        let b = pixels[centerOffset + 0]
        let g = pixels[centerOffset + 1]
        let r = pixels[centerOffset + 2]
        XCTAssertGreaterThan(Int(r) + Int(g) + Int(b), 30,
            "Center pixel was effectively black (\(r), \(g), \(b)) — the PBR pipeline did not draw the triangle.")

        // Corner pixel must be the clear color (background).
        let cornerB = pixels[0]
        let cornerG = pixels[1]
        let cornerR = pixels[2]
        XCTAssertLessThan(Int(cornerR) + Int(cornerG) + Int(cornerB), 10,
            "Corner pixel was not the clear color (\(cornerR), \(cornerG), \(cornerB)) — render pass clear may have failed.")
    }
}
