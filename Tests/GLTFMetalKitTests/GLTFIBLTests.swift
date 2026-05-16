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

/// Credibility test for Phase 3a's IBL pipeline: under a procedural sky
/// environment, a metallic surface must reflect *meaningfully* more energy
/// than a rough dielectric. If this fails, the renderer is rendering
/// "metallic plastic" — IBL is wired but the math doesn't pick up the
/// material distinction.
final class GLTFIBLTests: XCTestCase {

    func testProceduralEnvironmentGenerates() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }

        let renderer = try GLTFRenderer(device: device)
        let environment = try GLTFEnvironment.makeProcedural(
            device: device,
            library: renderer.library
        )

        XCTAssertEqual(environment.diffuse.textureType, .typeCube)
        XCTAssertEqual(environment.specular.textureType, .typeCube)
        XCTAssertGreaterThan(environment.specularMipCount, 1,
            "Specular cubemap must have a mip chain (got \(environment.specularMipCount)).")
        XCTAssertEqual(environment.specular.width, 256)
        XCTAssertEqual(environment.diffuse.width, 32)
    }

    /// The credibility check: pure-metallic vs pure-dielectric must render
    /// with a measurable brightness difference under the same environment.
    func testMetallicIsBrighterThanDielectric() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            XCTFail("Could not create command queue"); return
        }

        let renderer = try GLTFRenderer(device: device)
        // Build a procedural sky whose sun sits directly along the
        // reflection vector of a +Z-facing surface viewed from +Z, and
        // tuned to *not* saturate the Khronos PBR Neutral tonemap —
        // otherwise metallic and dielectric both clip to near-white and
        // the test can't separate them.
        let testSky = GLTFProceduralSkyParams(
            sunDirection: normalize(SIMD3<Float>(0.0, -0.05, -1.0)),
            sunColor: SIMD3<Float>(6.0, 5.0, 3.0),       // bright but not tonemap-saturating
            sunAngularRadius: 0.3,                       // wide so prefilter samples hit it
            zenithColor: SIMD3<Float>(0.15, 0.20, 0.30), // dim blue
            horizonColor: SIMD3<Float>(0.30, 0.25, 0.20),
            groundColor: SIMD3<Float>(0.05, 0.05, 0.05)
        )
        renderer.environment = try GLTFEnvironment.makeProcedural(
            device: device,
            library: renderer.library,
            params: testSky
        )

        let colorFormat: MTLPixelFormat = .bgra8Unorm
        let depthFormat: MTLPixelFormat = .depth32Float
        let pipelines = try renderer.makePipelineStates(colorFormat: colorFormat, depthFormat: depthFormat)

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            XCTFail("Could not create depth state"); return
        }

        // A simple quad facing the camera (camera at +Z, looking at -Z).
        // Normal is (0, 0, 1) — picks up the sun reflection nicely with
        // the default sky params (sun is up-and-forward).
        let vertices: [GLTFRenderableVertex] = [
            GLTFRenderableVertex(position: SIMD3<Float>(-0.7,  0.7, 0.0),
                                 normal:   SIMD3<Float>( 0,   0,   1)),
            GLTFRenderableVertex(position: SIMD3<Float>(-0.7, -0.7, 0.0),
                                 normal:   SIMD3<Float>( 0,   0,   1)),
            GLTFRenderableVertex(position: SIMD3<Float>( 0.7,  0.7, 0.0),
                                 normal:   SIMD3<Float>( 0,   0,   1)),
            GLTFRenderableVertex(position: SIMD3<Float>( 0.7, -0.7, 0.0),
                                 normal:   SIMD3<Float>( 0,   0,   1)),
        ]
        let indices: [UInt16] = [0, 1, 2, 1, 3, 2]
        guard let mesh = GLTFRenderableMesh.makeIndexed(vertices: vertices, indices: indices, device: device) else {
            XCTFail("Could not create mesh"); return
        }

        // Disable the directional fallback light so IBL is the only contributor.
        // We override by setting `lightCount > 0` with a single zero-intensity
        // directional light (the shader skips the fallback in that case).
        let zeroLight = GLTFPunctualLightUniform(
            type: .directional,
            color: SIMD3<Float>(0, 0, 0),
            intensity: 0,
            direction: SIMD3<Float>(0, -1, 0)
        )
        let scene = GLTFSceneState(
            viewProjection: matrix_identity_float4x4,
            cameraPosition: SIMD3<Float>(0, 0, 1.5),
            lights: [zeroLight]
        )

        // Two materials: pure metallic vs pure dielectric. Same base color
        // so any brightness difference is from F0 + IBL split-sum, not albedo.
        let baseColor = SIMD4<Float>(0.85, 0.85, 0.85, 1.0)
        let metallicMaterial = GLTFRenderableMaterial(uniforms: GLTFMaterialUniforms(
            baseColorFactor: baseColor,
            metallicFactor: 1.0,
            roughnessFactor: 0.1
        ))
        let dielectricMaterial = GLTFRenderableMaterial(uniforms: GLTFMaterialUniforms(
            baseColorFactor: baseColor,
            metallicFactor: 0.0,
            roughnessFactor: 1.0
        ))

        let metallicLuminance = try renderQuad(
            material: metallicMaterial, mesh: mesh, scene: scene,
            pipelines: pipelines, depthState: depthState, renderer: renderer,
            commandQueue: commandQueue, colorFormat: colorFormat, depthFormat: depthFormat
        )
        let dielectricLuminance = try renderQuad(
            material: dielectricMaterial, mesh: mesh, scene: scene,
            pipelines: pipelines, depthState: depthState, renderer: renderer,
            commandQueue: commandQueue, colorFormat: colorFormat, depthFormat: depthFormat
        )

        // Metallic should be at least 1.5x brighter than the matte
        // dielectric — F0 jumps from 0.04 to baseColor for metals, and
        // the rough dielectric scatters all IBL diffusely.
        XCTAssertGreaterThan(metallicLuminance, dielectricLuminance * 1.5,
            "Metallic (lum=\(String(format: "%.1f", metallicLuminance))) was not meaningfully brighter than dielectric (lum=\(String(format: "%.1f", dielectricLuminance))) — IBL split-sum is not picking up the material distinction.")
    }

    // MARK: - Helpers

    private func renderQuad(
        material: GLTFRenderableMaterial,
        mesh: GLTFRenderableMesh,
        scene: GLTFSceneState,
        pipelines: GLTFRenderer.PipelineStates,
        depthState: MTLDepthStencilState,
        renderer: GLTFRenderer,
        commandQueue: MTLCommandQueue,
        colorFormat: MTLPixelFormat,
        depthFormat: MTLPixelFormat
    ) throws -> Double {
        let width = 128
        let height = 128

        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorFormat, width: width, height: height, mipmapped: false
        )
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        colorDescriptor.storageMode = .shared
        let colorTexture = renderer.device.makeTexture(descriptor: colorDescriptor)!

        let depthDescriptor2 = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: depthFormat, width: width, height: height, mipmapped: false
        )
        depthDescriptor2.usage = [.renderTarget]
        depthDescriptor2.storageMode = .private
        let depthTexture = renderer.device.makeTexture(descriptor: depthDescriptor2)!

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = colorTexture
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.depthAttachment.texture = depthTexture
        renderPass.depthAttachment.loadAction = .clear
        renderPass.depthAttachment.clearDepth = 1.0
        renderPass.depthAttachment.storeAction = .dontCare

        let commandBuffer = commandQueue.makeCommandBuffer()!
        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass)!
        let calls = [GLTFDrawCall(mesh: mesh, material: material, modelMatrix: matrix_identity_float4x4)]
        renderer.encodeOpaqueDrawCalls(calls, scene: scene, pipelineStates: pipelines, depthState: depthState, encoder: encoder)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Mean luminance over the central 50% to skip framebuffer edges.
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBufferPointer { ptr in
            colorTexture.getBytes(ptr.baseAddress!, bytesPerRow: width * 4,
                                  from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        let yRange = (height / 4)..<(3 * height / 4)
        let xRange = (width  / 4)..<(3 * width  / 4)
        var sum = 0
        var count = 0
        for y in yRange {
            for x in xRange {
                let offset = y * width * 4 + x * 4
                // bgra8Unorm storage: B, G, R, A
                let lum = Int(pixels[offset + 0]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2])
                sum += lum
                count += 1
            }
        }
        return Double(sum) / Double(count)
    }
}
