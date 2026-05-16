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

import Foundation
@preconcurrency import Metal
import simd

/// PBR renderer for static glTF 2.0 assets.
///
/// Phase 3a step 2: ships the real PBR shader (Lambert + GGX direct light,
/// Khronos PBR Neutral tonemap) and constructs the matching render-pipeline
/// state. Scene-graph traversal, IBL setup, and the draw loop land in steps
/// 3–4.
///
/// Public-API note: this is still pre-1.0 and the shape (uniform layout,
/// IBL binding contract, KHR extension dispatch) may shift until Phase 3a
/// step 4 lands.
public final class GLTFRenderer: @unchecked Sendable {
    public let device: MTLDevice
    public let library: MTLLibrary

    /// View-independent BRDF integration LUT used by the IBL split-sum path.
    /// Generated once at init time via a compute kernel — the math is fixed
    /// for a given BRDF, so it never needs rebuilding.
    public let brdfLUT: MTLTexture

    /// Image-based lighting environment. Defaults to a 1×1 neutral-gray
    /// fallback so the shader's IBL split-sum path stays valid without an
    /// HDR asset. Replace via assignment when a real environment is loaded
    /// (the renderer reads this each frame; no rebuild required).
    public var environment: GLTFEnvironment

    /// Creates a renderer bound to a Metal device.
    ///
    /// - Parameter device: The Metal device to use for pipeline state and
    ///   GPU resource allocation. Typically `MTLCreateSystemDefaultDevice()`.
    /// - Throws: An error if the bundled `GLTFMetalKitShaders.metallib`
    ///   cannot be located or loaded, or if BRDF LUT generation fails.
    public init(device: MTLDevice) throws {
        self.device = device

        guard let metallibURL = GLTFMetalKit.bundle.url(
            forResource: "GLTFMetalKitShaders",
            withExtension: "metallib"
        ) else {
            throw GLTFRendererError.missingShaderLibrary
        }

        self.library = try device.makeLibrary(URL: metallibURL)
        self.brdfLUT = try GLTFBRDFLUT.generate(device: device, library: library)

        guard let fallback = GLTFEnvironment.makeFallback(device: device) else {
            throw GLTFRendererError.environmentSetupFailed
        }
        self.environment = fallback
    }

    /// Builds the vertex descriptor that matches ``GLTFPBRShader.metal``'s
    /// `GLTFVertexIn`.
    ///
    /// Attribute layout: position (float3) | normal (float3) | tangent
    /// (float4) | uv0 (float2). Interleaved in ``GLTFRenderableVertex``
    /// layout at ``GLTFShaderBindings/vertexBuffer``.
    ///
    /// Per-attribute offsets are fixed (Swift's SIMD3 has 16-byte alignment
    /// so position/normal each consume a 16-byte slot); the layout stride
    /// uses `MemoryLayout<GLTFRenderableVertex>.stride` directly so any
    /// Swift trailing padding (e.g. the 8 bytes after uv0 to round the
    /// struct to a 16-byte alignment boundary) is honoured.
    public static func makeVertexDescriptor() -> MTLVertexDescriptor {
        let vd = MTLVertexDescriptor()

        // attribute 0: position (float3 at offset 0)
        vd.attributes[0].format = .float3
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = GLTFShaderBindings.vertexBuffer

        // attribute 1: normal (float3 at offset 16 — after SIMD3 padding)
        vd.attributes[1].format = .float3
        vd.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vd.attributes[1].bufferIndex = GLTFShaderBindings.vertexBuffer

        // attribute 2: tangent (float4 at offset 32)
        vd.attributes[2].format = .float4
        vd.attributes[2].offset = 2 * MemoryLayout<SIMD3<Float>>.stride
        vd.attributes[2].bufferIndex = GLTFShaderBindings.vertexBuffer

        // attribute 3: uv0 (float2 at offset 48)
        vd.attributes[3].format = .float2
        vd.attributes[3].offset = 2 * MemoryLayout<SIMD3<Float>>.stride + MemoryLayout<SIMD4<Float>>.stride
        vd.attributes[3].bufferIndex = GLTFShaderBindings.vertexBuffer

        vd.layouts[GLTFShaderBindings.vertexBuffer].stride = MemoryLayout<GLTFRenderableVertex>.stride
        vd.layouts[GLTFShaderBindings.vertexBuffer].stepFunction = .perVertex
        vd.layouts[GLTFShaderBindings.vertexBuffer].stepRate = 1

        return vd
    }

    /// Builds the standard PBR render-pipeline state. Real renderer will
    /// vary on alpha mode + double-sided + skinning; step 2 ships only the
    /// opaque, single-sided, non-skinned variant.
    ///
    /// - Parameters:
    ///   - colorFormat: Color-attachment pixel format. Pass the one matching the drawable's framebuffer.
    ///   - depthFormat: Depth-attachment pixel format. Typically `.depth32Float`.
    ///   - sampleCount: MSAA sample count. `1` = no MSAA.
    public func makeOpaquePBRPipelineState(
        colorFormat: MTLPixelFormat,
        depthFormat: MTLPixelFormat,
        sampleCount: Int = 1
    ) throws -> MTLRenderPipelineState {
        guard let vertexFn = library.makeFunction(name: "gltf_pbr_vertex") else {
            throw GLTFRendererError.missingShaderFunction(name: "gltf_pbr_vertex")
        }
        guard let fragmentFn = library.makeFunction(name: "gltf_pbr_fragment") else {
            throw GLTFRendererError.missingShaderFunction(name: "gltf_pbr_fragment")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.vertexDescriptor = Self.makeVertexDescriptor()
        descriptor.colorAttachments[0].pixelFormat = colorFormat
        descriptor.depthAttachmentPixelFormat = depthFormat
        descriptor.rasterSampleCount = sampleCount

        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Issues an opaque PBR pass for the supplied draw calls.
    ///
    /// Phase 3a step 4a: single-pipeline opaque only. Alpha-blended and
    /// double-sided variants come in step 4c. The encoder must already be
    /// configured for a render pass with a depth attachment.
    ///
    /// - Parameters:
    ///   - calls: Draw calls in scene-graph order (back-to-front not yet enforced).
    ///   - scene: Per-frame state: view-projection, camera, directional light.
    ///   - pipelineState: PBR pipeline state created via ``makeOpaquePBRPipelineState(colorFormat:depthFormat:sampleCount:)``.
    ///   - depthState: Depth-stencil state (typically `less`, write enabled). Caller owns it so the same `GLTFRenderer` can serve multiple render passes.
    ///   - encoder: Active render-command encoder.
    public func encodeOpaqueDrawCalls(
        _ calls: [GLTFDrawCall],
        scene: GLTFSceneState,
        pipelineState: MTLRenderPipelineState,
        depthState: MTLDepthStencilState,
        encoder: MTLRenderCommandEncoder
    ) {
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthState)

        // Samplers — built lazily on first use and cached on the renderer.
        let colorSampler = colorSamplerState
        let linearSampler = linearSamplerState
        let environmentSampler = environmentSamplerState

        encoder.setFragmentSamplerState(colorSampler,       index: GLTFShaderBindings.colorSampler)
        encoder.setFragmentSamplerState(linearSampler,      index: GLTFShaderBindings.linearSampler)
        encoder.setFragmentSamplerState(environmentSampler, index: GLTFShaderBindings.environmentSampler)

        // Environment bindings are scene-wide.
        encoder.setFragmentTexture(environment.diffuse,  index: GLTFShaderBindings.diffuseEnvironmentTexture)
        encoder.setFragmentTexture(environment.specular, index: GLTFShaderBindings.specularEnvironmentTexture)
        encoder.setFragmentTexture(brdfLUT,              index: GLTFShaderBindings.brdfLUTTexture)

        // 1×1 white default for unbound material slots so the shader can
        // sample without worrying about null textures — the material flags
        // are what gates the contribution.
        let defaultColor = defaultWhiteTexture
        let defaultLinear = defaultLinearTexture

        for call in calls {
            // Per-draw frame uniforms — model + normal matrix differ per call.
            let normalMatrix = Self.normalMatrix(from: call.modelMatrix)
            var frame = GLTFFrameUniforms(
                viewProjection: scene.viewProjection,
                model: call.modelMatrix,
                normalMatrix: normalMatrix,
                cameraPosition: scene.cameraPosition,
                lightDirection: scene.lightDirection,
                lightColor: scene.lightColor,
                specularMipCount: Float(environment.specularMipCount)
            )
            encoder.setVertexBytes(&frame, length: MemoryLayout<GLTFFrameUniforms>.stride, index: GLTFShaderBindings.frameUniforms)
            encoder.setFragmentBytes(&frame, length: MemoryLayout<GLTFFrameUniforms>.stride, index: GLTFShaderBindings.frameUniforms)

            var material = call.material.uniforms
            encoder.setFragmentBytes(&material, length: MemoryLayout<GLTFMaterialUniforms>.stride, index: GLTFShaderBindings.materialUniforms)

            encoder.setFragmentTexture(call.material.baseColorTexture         ?? defaultColor,  index: GLTFShaderBindings.baseColorTexture)
            encoder.setFragmentTexture(call.material.metallicRoughnessTexture ?? defaultLinear, index: GLTFShaderBindings.metallicRoughnessTexture)
            encoder.setFragmentTexture(call.material.normalTexture            ?? defaultLinear, index: GLTFShaderBindings.normalTexture)
            encoder.setFragmentTexture(call.material.occlusionTexture         ?? defaultLinear, index: GLTFShaderBindings.occlusionTexture)
            encoder.setFragmentTexture(call.material.emissiveTexture          ?? defaultColor,  index: GLTFShaderBindings.emissiveTexture)

            encoder.setVertexBuffer(call.mesh.vertexBuffer, offset: 0, index: GLTFShaderBindings.vertexBuffer)
            if let indexBuffer = call.mesh.indexBuffer {
                encoder.drawIndexedPrimitives(
                    type: call.mesh.primitiveType,
                    indexCount: call.mesh.indexCount,
                    indexType: call.mesh.indexType,
                    indexBuffer: indexBuffer,
                    indexBufferOffset: 0
                )
            } else {
                encoder.drawPrimitives(
                    type: call.mesh.primitiveType,
                    vertexStart: 0,
                    vertexCount: call.mesh.vertexCount
                )
            }
        }
    }

    /// 3×3 inverse-transpose of the upper-left 3×3 of the model matrix —
    /// the correct way to transform normals into world space when the model
    /// matrix may include non-uniform scale.
    private static func normalMatrix(from modelMatrix: simd_float4x4) -> simd_float3x3 {
        let m = modelMatrix
        let upperLeft = simd_float3x3(columns: (
            SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        ))
        return upperLeft.inverse.transpose
    }

    // MARK: - Lazy sampler / fallback-texture cache

    private lazy var colorSamplerState: MTLSamplerState = {
        let d = MTLSamplerDescriptor()
        d.minFilter = .linear; d.magFilter = .linear; d.mipFilter = .linear
        d.sAddressMode = .repeat; d.tAddressMode = .repeat
        d.maxAnisotropy = 16
        return device.makeSamplerState(descriptor: d)!
    }()

    private lazy var linearSamplerState: MTLSamplerState = {
        let d = MTLSamplerDescriptor()
        d.minFilter = .linear; d.magFilter = .linear; d.mipFilter = .linear
        d.sAddressMode = .repeat; d.tAddressMode = .repeat
        d.maxAnisotropy = 16
        return device.makeSamplerState(descriptor: d)!
    }()

    private lazy var environmentSamplerState: MTLSamplerState = {
        let d = MTLSamplerDescriptor()
        d.minFilter = .linear; d.magFilter = .linear; d.mipFilter = .linear
        d.sAddressMode = .clampToEdge; d.tAddressMode = .clampToEdge; d.rAddressMode = .clampToEdge
        return device.makeSamplerState(descriptor: d)!
    }()

    private lazy var defaultWhiteTexture: MTLTexture = {
        return Self.makeSolidTexture(device: device, rgba: SIMD4<UInt8>(255, 255, 255, 255), sRGB: true)
    }()

    private lazy var defaultLinearTexture: MTLTexture = {
        // Default for MR / normal / AO. Linear (0.5, 0.5, 1.0, 1.0) reads as
        // “no metallic, mid-roughness, +Z normal, full AO” when sampled by
        // shaders that gate via the material flags — never actually consumed
        // because the flags clear those bits when no texture is bound, but
        // a sensible byte pattern keeps GPU validation layers happy.
        return Self.makeSolidTexture(device: device, rgba: SIMD4<UInt8>(128, 128, 255, 255), sRGB: false)
    }()

    private static func makeSolidTexture(device: MTLDevice, rgba: SIMD4<UInt8>, sRGB: Bool) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: sRGB ? .rgba8Unorm_srgb : .rgba8Unorm,
            width: 1, height: 1, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)!
        var bytes: [UInt8] = [rgba.x, rgba.y, rgba.z, rgba.w]
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &bytes, bytesPerRow: 4)
        return texture
    }
}

/// Errors thrown by ``GLTFRenderer``.
public enum GLTFRendererError: Error, LocalizedError {
    /// The bundled `GLTFMetalKitShaders.metallib` resource could not be found.
    case missingShaderLibrary
    /// A required shader function is absent from the loaded metallib (likely a stale build of `Sources/GLTFMetalKit/Resources/GLTFMetalKitShaders.metallib`).
    case missingShaderFunction(name: String)
    /// The fallback IBL environment could not be allocated. Indicates a deeper Metal-allocation problem.
    case environmentSetupFailed

    public var errorDescription: String? {
        switch self {
        case .missingShaderLibrary:
            return """
            ❌ Missing GLTFMetalKit Shader Library

            The bundled `GLTFMetalKitShaders.metallib` could not be located inside the GLTFMetalKit bundle.

            Suggestion: Run `make gltf-shaders` from the package root to compile the Metal shaders. The compiled metallib must live at `Sources/GLTFMetalKit/Resources/GLTFMetalKitShaders.metallib`.
            """
        case .missingShaderFunction(let name):
            return """
            ❌ Missing Shader Function: '\(name)'

            The bundled `GLTFMetalKitShaders.metallib` does not contain '\(name)'.

            Suggestion: Re-run `make gltf-shaders` to rebuild the metallib. If the function name recently changed, ensure both the .metal source and the Swift caller reference the same symbol.
            """
        case .environmentSetupFailed:
            return """
            ❌ Environment Setup Failed

            The fallback 1×1 neutral-gray IBL environment could not be allocated.

            Suggestion: This usually indicates a deeper Metal allocation problem — verify the supplied MTLDevice is valid and the system has enough free GPU memory.
            """
        }
    }
}
