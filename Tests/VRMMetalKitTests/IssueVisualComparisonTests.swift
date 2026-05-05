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
import CoreGraphics
import UniformTypeIdentifiers
@testable import VRMMetalKit

/// Generates side-by-side PNG images demonstrating the before/after visual impact
/// of GitHub Issues #145, #146, and #147 fixes.
///
/// Run with: swift test --filter IssueVisualComparisonTests
/// Images are saved to the project root as:
///   - issue145_giIntensityFactor_comparison.png
///   - issue146_emissive_comparison.png
///   - issue147_lighting_comparison.png
enum VisualTestError: Error {
    case commandBufferCreationFailed
    case encoderCreationFailed
    case textureCreationFailed
    case samplerCreationFailed
}

@MainActor
final class IssueVisualComparisonTests: XCTestCase {

    var device: MTLDevice!
    var renderer: LightingTestRenderer!

    override func setUp() async throws {
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else {
            throw XCTSkip("Metal device not available")
        }
        renderer = try LightingTestRenderer(device: device, width: 256, height: 256)
    }

    override func tearDown() async throws {
        renderer = nil
        device = nil
    }

    // MARK: - #145: giIntensityFactor Visual Comparison

    func test_generateGIIntensityComparison() async throws {
        var material = MToonMaterialUniforms()
        material.baseColorFactor = SIMD4<Float>(0.4, 0.35, 0.3, 1)
        material.shadeColorFactor = SIMD3<Float>(0.1, 0.08, 0.06)
        material.shadingToonyFactor = 0.9
        material.shadingShiftFactor = 0.0
        material.emissiveFactor = SIMD3<Float>(0, 0, 0)
        material.giIntensityFactor = 1.0

        // Render with high GI
        let frameHigh = try renderer.render(
            material: material,
            lightDir: SIMD3<Float>(0.5, 0, 0.866),
            ambientIntensity: 0.6
        )

        // Render with zero GI
        var materialLow = material
        materialLow.giIntensityFactor = 0.0
        let frameLow = try renderer.render(
            material: materialLow,
            lightDir: SIMD3<Float>(0.5, 0, 0.866),
            ambientIntensity: 0.6
        )

        let sideBySide = createSideBySide(left: frameLow, right: frameHigh, width: 256, height: 256)
        let path = "issue145_giIntensityFactor_comparison.png"
        try saveBGRA(data: sideBySide, width: 512, height: 256, to: path)
        print("📸 Saved: \(path)")
        print("   LEFT  = giIntensityFactor=0.0 (dark, flat shadows)")
        print("   RIGHT = giIntensityFactor=1.0 (brighter indirect, lifted shadows)")
    }

    // MARK: - #146: Emissive Visual Comparison

    func test_generateEmissiveComparison() async throws {
        // Black base, black shade — only emissive contributes
        var material = MToonMaterialUniforms()
        material.baseColorFactor = SIMD4<Float>(0.05, 0.05, 0.05, 1)
        material.shadeColorFactor = SIMD3<Float>(0, 0, 0)
        material.shadingToonyFactor = 1.0
        material.shadingShiftFactor = 0.0
        material.emissiveFactor = SIMD3<Float>(0.8, 0.2, 0.1)  // Warm orange emissive
        material.giIntensityFactor = 0.0

        // With emissive preserved (current code after fix)
        let frameWithEmissive = try renderer.render(
            material: material,
            lightDir: SIMD3<Float>(0, 0, 1),
            ambientIntensity: 0.0
        )

        // Simulate the old bug: zero out emissive in the material before rendering
        var materialZeroed = material
        materialZeroed.emissiveFactor = SIMD3<Float>(0, 0, 0)
        let frameWithoutEmissive = try renderer.render(
            material: materialZeroed,
            lightDir: SIMD3<Float>(0, 0, 1),
            ambientIntensity: 0.0
        )

        let sideBySide = createSideBySide(left: frameWithoutEmissive, right: frameWithEmissive, width: 256, height: 256)
        let path = "issue146_emissive_comparison.png"
        try saveBGRA(data: sideBySide, width: 512, height: 256, to: path)
        print("📸 Saved: \(path)")
        print("   LEFT  = emissive force-zeroed (near-black sphere)")
        print("   RIGHT = emissive preserved (glowing warm orange)")
    }

    // MARK: - #147: Default Lighting Comparison

    func test_generateLightingComparison() async throws {
        var material = MToonMaterialUniforms()
        material.baseColorFactor = SIMD4<Float>(0.7, 0.6, 0.55, 1)
        material.shadeColorFactor = SIMD3<Float>(0.3, 0.25, 0.2)
        material.shadingToonyFactor = 0.9
        material.shadingShiftFactor = 0.0
        material.emissiveFactor = SIMD3<Float>(0, 0, 0)
        material.giIntensityFactor = 0.05

        // Simulate OLD default lighting (dim)
        let frameOld = try renderWithCustomLighting(
            material: material,
            lightDir: SIMD3<Float>(-0.25, -0.5, -0.83),
            lightColor: SIMD3<Float>(1, 1, 1),
            lightIntensity: 1.732,
            ambient: SIMD3<Float>(0.05, 0.05, 0.05),
            fillColor: SIMD3<Float>(0, 0, 0),
            fillIntensity: 0,
            rimColor: SIMD3<Float>(0, 0, 0),
            rimIntensity: 0
        )

        // Simulate NEW default lighting (brighter)
        let frameNew = try renderWithCustomLighting(
            material: material,
            lightDir: SIMD3<Float>(-0.25, -0.5, -0.83),
            lightColor: SIMD3<Float>(1, 1, 1),
            lightIntensity: 1.732,
            ambient: SIMD3<Float>(0.15, 0.15, 0.15),
            fillColor: SIMD3<Float>(0.45, 0.48, 0.55),
            fillIntensity: 0.83,
            rimColor: SIMD3<Float>(0.55, 0.50, 0.45),
            rimIntensity: 0.75
        )

        let sideBySide = createSideBySide(left: frameOld, right: frameNew, width: 256, height: 256)
        let path = "issue147_lighting_comparison.png"
        try saveBGRA(data: sideBySide, width: 512, height: 256, to: path)
        print("📸 Saved: \(path)")
        print("   LEFT  = old defaults: 5% ambient, no fill/rim (dark, flat)")
        print("   RIGHT = new defaults: 15% ambient + fill + rim (brighter, more shape)")
    }

    // MARK: - Helpers

    private func renderWithCustomLighting(
        material: MToonMaterialUniforms,
        lightDir: SIMD3<Float>,
        lightColor: SIMD3<Float>,
        lightIntensity: Float,
        ambient: SIMD3<Float>,
        fillColor: SIMD3<Float>,
        fillIntensity: Float,
        rimColor: SIMD3<Float>,
        rimIntensity: Float
    ) throws -> Data {
        var uniforms = Uniforms()
        uniforms.modelMatrix = matrix_identity_float4x4
        uniforms.viewMatrix = simd_float4x4(translation: SIMD3<Float>(0, 0, -2))
        uniforms.projectionMatrix = simd_float4x4(
            perspectiveWithAspect: 1.0,
            fovy: Float.pi / 4,
            near: 0.1,
            far: 100
        )
        uniforms.normalMatrix = matrix_identity_float4x4
        uniforms.lightDirection = normalize(lightDir)
        uniforms.lightColor = lightColor
        uniforms.lightColor_packed.w = lightIntensity
        uniforms.ambientColor = ambient
        uniforms.light1Direction = SIMD3<Float>(-0.58, -0.19, 0.79)
        uniforms.light1Color = fillColor
        uniforms.light1Color_packed.w = fillIntensity
        uniforms.light2Direction = SIMD3<Float>(0.32, 0.85, -0.42)
        uniforms.light2Color = rimColor
        uniforms.light2Color_packed.w = rimIntensity
        uniforms.lightNormalizationFactor = 1.0
        uniforms.debugUVs = 0

        var materialCopy = material

        // We need to access renderInternal, but it's private.
        // Workaround: use the public render method and override uniforms via reflection?
        // Actually, the simplest approach is to duplicate the render logic here.
        return try renderDirect(uniforms: &uniforms, material: &materialCopy)
    }

    private func renderDirect(uniforms: inout Uniforms, material: inout MToonMaterialUniforms) throws -> Data {
        guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
            throw VisualTestError.commandBufferCreationFailed
        }

        let renderPassDesc = MTLRenderPassDescriptor()
        renderPassDesc.colorAttachments[0].texture = renderer.colorTexture
        renderPassDesc.colorAttachments[0].loadAction = .clear
        renderPassDesc.colorAttachments[0].storeAction = .store
        renderPassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
        renderPassDesc.depthAttachment.texture = renderer.depthTexture
        renderPassDesc.depthAttachment.loadAction = .clear
        renderPassDesc.depthAttachment.storeAction = .dontCare
        renderPassDesc.depthAttachment.clearDepth = 1.0

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
            throw VisualTestError.encoderCreationFailed
        }

        encoder.setRenderPipelineState(renderer.pipelineState)
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.counterClockwise)

        encoder.setVertexBuffer(renderer.vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setVertexBytes(&material, length: MemoryLayout<MToonMaterialUniforms>.stride, index: 8)

        var hasMorphed: UInt32 = 0
        encoder.setVertexBytes(&hasMorphed, length: MemoryLayout<UInt32>.stride, index: 22)

        var dummyMorph = SIMD3<Float>(0, 0, 0)
        encoder.setVertexBytes(&dummyMorph, length: MemoryLayout<SIMD3<Float>>.stride, index: 20)

        encoder.setFragmentBytes(&material, length: MemoryLayout<MToonMaterialUniforms>.stride, index: 8)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        texDesc.usage = .shaderRead
        guard let whiteTex = device.makeTexture(descriptor: texDesc) else {
            throw VisualTestError.textureCreationFailed
        }
        var whitePixel: [UInt8] = [255, 255, 255, 255]
        whiteTex.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &whitePixel,
            bytesPerRow: 4
        )

        for i in 0..<16 {
            encoder.setFragmentTexture(whiteTex, index: i)
        }

        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .repeat
        samplerDesc.tAddressMode = .repeat
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else {
            throw VisualTestError.samplerCreationFailed
        }
        encoder.setFragmentSamplerState(sampler, index: 0)

        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: renderer.indexCount,
            indexType: .uint32,
            indexBuffer: renderer.indexBuffer,
            indexBufferOffset: 0
        )

        encoder.endEncoding()

        let blitEncoder = commandBuffer.makeBlitCommandEncoder()
        blitEncoder?.synchronize(texture: renderer.colorTexture, slice: 0, level: 0)
        blitEncoder?.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var frameData = [UInt8](repeating: 0, count: 256 * 256 * 4)
        renderer.colorTexture.getBytes(
            &frameData,
            bytesPerRow: 256 * 4,
            from: MTLRegionMake2D(0, 0, 256, 256),
            mipmapLevel: 0
        )

        return Data(frameData)
    }

    private func createSideBySide(left: Data, right: Data, width: Int, height: Int) -> Data {
        let outWidth = width * 2
        var output = Data(count: outWidth * height * 4)

        left.withUnsafeBytes { leftPtr in
            right.withUnsafeBytes { rightPtr in
                output.withUnsafeMutableBytes { outPtr in
                    guard let leftBytes = leftPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let rightBytes = rightPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let outBytes = outPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

                    for y in 0..<height {
                        let leftOffset = y * width * 4
                        let rightOffset = y * width * 4
                        let outOffset = y * outWidth * 4

                        memcpy(outBytes + outOffset, leftBytes + leftOffset, width * 4)
                        memcpy(outBytes + outOffset + width * 4, rightBytes + rightOffset, width * 4)
                    }
                }
            }
        }

        return output
    }

    private func saveBGRA(data: Data, width: Int, height: Int, to path: String) throws {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        guard let provider = CGDataProvider(data: data as CFData) else {
            throw XCTestError(.failureWhileWaiting)
        }

        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw XCTestError(.failureWhileWaiting)
        }

        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw XCTestError(.failureWhileWaiting)
        }

        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            throw XCTestError(.failureWhileWaiting)
        }
    }
}
