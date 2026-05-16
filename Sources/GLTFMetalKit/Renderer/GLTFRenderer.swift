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
/// Provides the PBR + IBL shader stack (Lambert + GGX direct light,
/// split-sum IBL, Khronos PBR Neutral tonemap) and the pipeline-state +
/// per-draw encoding plumbing.
///
/// ## Thread safety
///
/// Marked `@unchecked Sendable` for ergonomic interop with Swift
/// concurrency, but **the type is designed for single-threaded use from a
/// render loop**. The public ``environment`` property is read-write;
/// concurrent reads-during-writes from different threads are not
/// synchronised by the renderer. If multi-threaded encoding is desired,
/// serialise access at the call site (e.g. an actor or a single
/// dispatch queue per renderer instance).
///
/// Stateless per-draw work (encoding draw calls) is safe to issue
/// concurrently from multiple threads onto different command buffers as
/// long as the renderer's `environment` isn't being mutated.
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

    /// Bundle of PBR pipeline states for one (color, depth, sample-count)
    /// framebuffer configuration. The renderer picks `opaque` or
    /// `skinnedOpaque` per draw based on each mesh's `isSkinned` flag.
    public struct PipelineStates {
        public let opaque: MTLRenderPipelineState
        public let skinnedOpaque: MTLRenderPipelineState

        public init(opaque: MTLRenderPipelineState, skinnedOpaque: MTLRenderPipelineState) {
            self.opaque = opaque
            self.skinnedOpaque = skinnedOpaque
        }
    }

    /// Build both PBR pipeline states (non-skinned + skinned) in one call.
    /// The two PSOs share fragment shader; only the vertex stage + vertex
    /// descriptor differ.
    public func makePipelineStates(
        colorFormat: MTLPixelFormat,
        depthFormat: MTLPixelFormat,
        sampleCount: Int = 1
    ) throws -> PipelineStates {
        let opaque = try makeOpaquePBRPipelineState(
            colorFormat: colorFormat, depthFormat: depthFormat, sampleCount: sampleCount
        )
        let skinned = try makeSkinnedOpaquePBRPipelineState(
            colorFormat: colorFormat, depthFormat: depthFormat, sampleCount: sampleCount
        )
        return PipelineStates(opaque: opaque, skinnedOpaque: skinned)
    }

    /// Pipeline that outputs world-space normals as RGB (debug aid).
    /// Build alongside the opaque pipeline; use to confirm NORMAL accessor
    /// decoding and per-vertex normal interpolation are working. See the
    /// `gltf_debug_normals_fragment` shader.
    public func makeDebugNormalsPipelineState(
        colorFormat: MTLPixelFormat,
        depthFormat: MTLPixelFormat,
        sampleCount: Int = 1,
        skinned: Bool = false
    ) throws -> MTLRenderPipelineState {
        let vertexFnName = skinned ? "gltf_pbr_vertex_skinned" : "gltf_pbr_vertex"
        guard let vertexFn = library.makeFunction(name: vertexFnName) else {
            throw GLTFRendererError.missingShaderFunction(name: vertexFnName)
        }
        guard let fragmentFn = library.makeFunction(name: "gltf_debug_normals_fragment") else {
            throw GLTFRendererError.missingShaderFunction(name: "gltf_debug_normals_fragment")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.vertexDescriptor = skinned ? Self.makeSkinnedVertexDescriptor() : Self.makeVertexDescriptor()
        descriptor.colorAttachments[0].pixelFormat = colorFormat
        descriptor.depthAttachmentPixelFormat = depthFormat
        descriptor.rasterSampleCount = sampleCount
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Skinned-variant pipeline. Same fragment as the opaque pipeline; the
    /// difference is the vertex shader (`gltf_pbr_vertex_skinned`) and the
    /// vertex descriptor (adds `JOINTS_0` + `WEIGHTS_0`).
    public func makeSkinnedOpaquePBRPipelineState(
        colorFormat: MTLPixelFormat,
        depthFormat: MTLPixelFormat,
        sampleCount: Int = 1
    ) throws -> MTLRenderPipelineState {
        guard let vertexFn = library.makeFunction(name: "gltf_pbr_vertex_skinned") else {
            throw GLTFRendererError.missingShaderFunction(name: "gltf_pbr_vertex_skinned")
        }
        guard let fragmentFn = library.makeFunction(name: "gltf_pbr_fragment") else {
            throw GLTFRendererError.missingShaderFunction(name: "gltf_pbr_fragment")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.vertexDescriptor = Self.makeSkinnedVertexDescriptor()
        descriptor.colorAttachments[0].pixelFormat = colorFormat
        descriptor.depthAttachmentPixelFormat = depthFormat
        descriptor.rasterSampleCount = sampleCount

        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Vertex descriptor matching `GLTFSkinnedVertexIn`. Extends the basic
    /// layout with `JOINTS_0` (ushort4) and `WEIGHTS_0` (float4).
    public static func makeSkinnedVertexDescriptor() -> MTLVertexDescriptor {
        let vd = MTLVertexDescriptor()

        vd.attributes[0].format = .float3
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = GLTFShaderBindings.vertexBuffer

        vd.attributes[1].format = .float3
        vd.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vd.attributes[1].bufferIndex = GLTFShaderBindings.vertexBuffer

        vd.attributes[2].format = .float4
        vd.attributes[2].offset = 2 * MemoryLayout<SIMD3<Float>>.stride
        vd.attributes[2].bufferIndex = GLTFShaderBindings.vertexBuffer

        vd.attributes[3].format = .float2
        vd.attributes[3].offset = 2 * MemoryLayout<SIMD3<Float>>.stride + MemoryLayout<SIMD4<Float>>.stride
        vd.attributes[3].bufferIndex = GLTFShaderBindings.vertexBuffer

        // Compute the offset of `joints` in `GLTFSkinnedRenderableVertex`
        // by reproducing the Swift layout: position(16) + normal(16) +
        // tangent(16) + uv0(8) → 56. The struct's alignment is 16 so the
        // next member starts at offset 64 (`joints` is SIMD4<UInt16> with
        // 8-byte alignment, so 56 rounds up to next multiple of 8 = 56;
        // but `weights` is SIMD4<Float> with 16-byte alignment, so joints
        // ends at 64 and weights starts at 64+8=72 — actually 80 once
        // the SIMD4<Float> alignment kicks in).
        //
        // Safest: stash a static probe to query MemoryLayout offsets via
        // a sentinel value at debug-time. Production: pin the offsets we
        // know from the struct definition and rely on
        // `MemoryLayout<GLTFSkinnedRenderableVertex>.stride` for the
        // overall stride.
        vd.attributes[4].format = .ushort4
        vd.attributes[4].offset = Self.skinnedJointsOffset
        vd.attributes[4].bufferIndex = GLTFShaderBindings.vertexBuffer

        vd.attributes[5].format = .float4
        vd.attributes[5].offset = Self.skinnedWeightsOffset
        vd.attributes[5].bufferIndex = GLTFShaderBindings.vertexBuffer

        vd.layouts[GLTFShaderBindings.vertexBuffer].stride = MemoryLayout<GLTFSkinnedRenderableVertex>.stride
        vd.layouts[GLTFShaderBindings.vertexBuffer].stepFunction = .perVertex
        vd.layouts[GLTFShaderBindings.vertexBuffer].stepRate = 1

        return vd
    }

    /// Offset of `joints` field inside `GLTFSkinnedRenderableVertex`.
    /// Swift layout: position(0..15) + normal(16..31) + tangent(32..47) +
    /// uv0(48..55) → joints field follows. joints is `SIMD4<UInt16>`
    /// (8 bytes), 8-byte aligned. The previous field ended at 56 which
    /// is already 8-aligned, so joints starts at 56.
    private static let skinnedJointsOffset =
        2 * MemoryLayout<SIMD3<Float>>.stride
        + MemoryLayout<SIMD4<Float>>.stride
        + MemoryLayout<SIMD2<Float>>.stride

    /// Offset of `weights` field. SIMD4<Float> is 16-byte aligned; after
    /// joints ends at 56+8=64 we're already 16-aligned, so weights = 64.
    private static let skinnedWeightsOffset =
        GLTFRenderer.skinnedJointsOffset + MemoryLayout<SIMD4<UInt16>>.stride

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
    /// Picks the non-skinned or skinned pipeline per draw based on each
    /// mesh's `isSkinned` flag. The encoder must already be configured
    /// for a render pass with a depth attachment.
    ///
    /// - Parameters:
    ///   - calls: Draw calls in scene-graph order (back-to-front not yet enforced).
    ///   - scene: Per-frame state: view-projection, camera, directional light.
    ///   - pipelineStates: PBR pipeline-state bundle created via ``makePipelineStates(colorFormat:depthFormat:sampleCount:)``.
    ///   - depthState: Depth-stencil state (typically `less`, write enabled). Caller owns it so the same `GLTFRenderer` can serve multiple render passes.
    ///   - encoder: Active render-command encoder.
    public func encodeOpaqueDrawCalls(
        _ calls: [GLTFDrawCall],
        scene: GLTFSceneState,
        pipelineStates: PipelineStates,
        depthState: MTLDepthStencilState,
        encoder: MTLRenderCommandEncoder
    ) {
        // Bind depth-state up front; pipeline is selected per draw.
        encoder.setDepthStencilState(depthState)
        // Track the currently bound pipeline to avoid redundant
        // `setRenderPipelineState` calls when consecutive draws share it.
        var currentPipeline: MTLRenderPipelineState? = nil

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

        // Per-scene punctual lights — bound once, scoped to the whole batch.
        // Clamp to the shader's hard cap; anything past is silently dropped.
        //
        // Always bind something to the lights buffer slot, even when the
        // scene has no `KHR_lights_punctual` entries: Metal API validation
        // (in debug builds) flags missing bindings on slots the shader
        // signature declares, and the shader's `lightCount == 0` branch
        // doesn't dereference the buffer so a zero placeholder is safe.
        let lightCount = min(scene.lights.count, GLTFShaderBindings.maxPunctualLights)
        var lightArray = Array(scene.lights.prefix(lightCount))
        if lightArray.isEmpty {
            lightArray = [GLTFPunctualLightUniform(type: .directional, color: SIMD3<Float>(0, 0, 0))]
        }
        let bufferSize = lightArray.count * MemoryLayout<GLTFPunctualLightUniform>.stride
        encoder.setFragmentBytes(&lightArray, length: bufferSize, index: GLTFShaderBindings.lightsBuffer)

        for call in calls {
            // Pick + bind pipeline state for this draw.
            let pipelineForCall = call.mesh.isSkinned ? pipelineStates.skinnedOpaque : pipelineStates.opaque
            if pipelineForCall !== currentPipeline {
                encoder.setRenderPipelineState(pipelineForCall)
                currentPipeline = pipelineForCall
            }

            // Per-draw frame uniforms — model + normal matrix differ per call.
            let normalMatrix = Self.normalMatrix(from: call.modelMatrix)
            var frame = GLTFFrameUniforms(
                viewProjection: scene.viewProjection,
                model: call.modelMatrix,
                normalMatrix: normalMatrix,
                cameraPosition: scene.cameraPosition,
                lightDirection: scene.lightDirection,
                lightColor: scene.lightColor,
                specularMipCount: Float(environment.specularMipCount),
                lightCount: UInt32(lightCount)
            )
            encoder.setVertexBytes(&frame, length: MemoryLayout<GLTFFrameUniforms>.stride, index: GLTFShaderBindings.frameUniforms)
            encoder.setFragmentBytes(&frame, length: MemoryLayout<GLTFFrameUniforms>.stride, index: GLTFShaderBindings.frameUniforms)

            // Skin palette — only the skinned pipeline reads it. Skip the
            // bind for non-skinned draws so Metal doesn't complain about
            // missing buffer when an empty palette would still be valid
            // input but is semantically wrong.
            if call.mesh.isSkinned, let palette = call.skinPalette, !palette.isEmpty {
                var paletteCopy = palette
                let stride = MemoryLayout<simd_float4x4>.stride
                encoder.setVertexBytes(&paletteCopy, length: paletteCopy.count * stride, index: GLTFShaderBindings.skinPaletteBuffer)
            }

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
        guard let s = device.makeSamplerState(descriptor: d) else {
            fatalError("GLTFRenderer: MTLDevice.makeSamplerState returned nil for the color sampler — Metal allocation failure")
        }
        return s
    }()

    private lazy var linearSamplerState: MTLSamplerState = {
        let d = MTLSamplerDescriptor()
        d.minFilter = .linear; d.magFilter = .linear; d.mipFilter = .linear
        d.sAddressMode = .repeat; d.tAddressMode = .repeat
        d.maxAnisotropy = 16
        guard let s = device.makeSamplerState(descriptor: d) else {
            fatalError("GLTFRenderer: MTLDevice.makeSamplerState returned nil for the linear sampler — Metal allocation failure")
        }
        return s
    }()

    private lazy var environmentSamplerState: MTLSamplerState = {
        let d = MTLSamplerDescriptor()
        d.minFilter = .linear; d.magFilter = .linear; d.mipFilter = .linear
        d.sAddressMode = .clampToEdge; d.tAddressMode = .clampToEdge; d.rAddressMode = .clampToEdge
        guard let s = device.makeSamplerState(descriptor: d) else {
            fatalError("GLTFRenderer: MTLDevice.makeSamplerState returned nil for the environment sampler — Metal allocation failure")
        }
        return s
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
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            fatalError("GLTFRenderer: MTLDevice.makeTexture returned nil for a 1×1 default texture — Metal allocation failure")
        }
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
