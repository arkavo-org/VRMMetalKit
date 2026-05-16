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

/// Image-based lighting inputs for a single scene/camera.
///
/// **Diffuse irradiance** — low-frequency cubemap convolution. Sample with
/// the surface normal to get the integrated diffuse ambient term.
///
/// **Specular prefiltered** — cubemap with a mip chain. Mip 0 is the
/// sharpest reflection; each subsequent level convolves the source at a
/// progressively higher roughness. Sample at LOD `roughness * (mips - 1)`.
///
/// **BRDF LUT** — 2D `.rg16Float` texture indexed by `(NdotV, roughness)`.
/// Used by the split-sum approximation (Karis 2013); independent of view
/// and environment, so ``GLTFRenderer`` generates it once at init time
/// (see ``GLTFRenderer/brdfLUT``).
///
/// Construct via the explicit init or, for headless / asset-less testing
/// and bring-up flows, via ``makeFallback(device:)`` which produces 1×1
/// neutral-gray cubemaps. Step 3 ships this fallback only; a baked default
/// environment (Poly Haven CC0 HDR) lands in step 4.
public struct GLTFEnvironment {
    /// Diffuse irradiance cubemap.
    public let diffuse: MTLTexture
    /// Specular prefiltered cubemap with a mip chain.
    public let specular: MTLTexture
    /// Number of mip levels in ``specular`` — typically 5–8.
    public var specularMipCount: Int { specular.mipmapLevelCount }

    public init(diffuse: MTLTexture, specular: MTLTexture) {
        self.diffuse = diffuse
        self.specular = specular
    }

    /// Builds a neutral-gray fallback environment (1×1 cube faces, no mips).
    ///
    /// Lets a renderer initialise before any real environment is supplied —
    /// surfaces look matte-gray but not pitch-black, the shader's split-sum
    /// path stays valid, and the BRDF LUT keeps doing its work. Real
    /// brushed-metal looks require a baked HDR environment in step 4.
    public static func makeFallback(device: MTLDevice) -> GLTFEnvironment? {
        guard let diffuse = makeNeutralCube(device: device, side: 1, mipLevels: 1, gray: 0.2),
              let specular = makeNeutralCube(device: device, side: 1, mipLevels: 1, gray: 0.2) else {
            return nil
        }
        return GLTFEnvironment(diffuse: diffuse, specular: specular)
    }

    private static func makeNeutralCube(
        device: MTLDevice,
        side: Int,
        mipLevels: Int,
        gray: Float
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.textureCubeDescriptor(
            pixelFormat: .rgba16Float,
            size: side,
            mipmapped: mipLevels > 1
        )
        descriptor.mipmapLevelCount = mipLevels
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        let pixelCount = side * side
        let bytesPerRow = side * MemoryLayout<UInt16>.stride * 4
        let value = Self.float32ToFloat16(gray)
        let alpha = Self.float32ToFloat16(1.0)
        var pixels = [UInt16](repeating: 0, count: pixelCount * 4)
        for i in 0..<pixelCount {
            pixels[i * 4 + 0] = value
            pixels[i * 4 + 1] = value
            pixels[i * 4 + 2] = value
            pixels[i * 4 + 3] = alpha
        }

        for face in 0..<6 {
            pixels.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self).baseAddress!
                texture.replace(
                    region: MTLRegionMake2D(0, 0, side, side),
                    mipmapLevel: 0,
                    slice: face,
                    withBytes: bytes,
                    bytesPerRow: bytesPerRow,
                    bytesPerImage: bytesPerRow * side
                )
            }
        }

        return texture
    }

    /// IEEE-754 half-precision conversion (round-to-nearest-even, ties to even).
    /// Pulled inline so this kit has no third-party dependency for one helper.
    private static func float32ToFloat16(_ f: Float) -> UInt16 {
        let bits = f.bitPattern
        let sign = UInt16((bits >> 31) & 0x1) << 15
        let expF = Int((bits >> 23) & 0xFF)
        let mantF = bits & 0x007F_FFFF

        // Special cases: +/-0, denormals → 0; NaN/Inf preserved.
        if expF == 0 {
            return sign
        } else if expF == 0xFF {
            return sign | 0x7C00 | (mantF != 0 ? 0x0200 : 0)
        }

        let expH = expF - 127 + 15
        if expH >= 0x1F { return sign | 0x7C00 }            // overflow → +/-Inf
        if expH <= 0 { return sign }                         // underflow → +/-0
        let mantH = UInt16(mantF >> 13)
        return sign | (UInt16(expH) << 10) | mantH
    }
}

/// Generates the view-independent BRDF integration LUT used by the split-sum
/// IBL approximation.
///
/// The output texture is `.rg16Float`, sized 256×256 (a common
/// quality/memory compromise — Khronos sample uses this size). One thread
/// per texel; each runs 1024 Hammersley-distributed GGX importance samples
/// (see `Sources/GLTFMetalKit/Shaders/IBLPrefilter.metal`).
public enum GLTFBRDFLUT {

    /// Output size of the generated LUT. Both axes — `NdotV` along x, `roughness` along y.
    public static let size = 256

    /// Generates the BRDF LUT on the supplied device.
    ///
    /// Synchronously waits for the compute pass to complete so the returned
    /// texture is ready to use as a fragment input. Run this once at
    /// renderer startup and cache the result.
    public static func generate(device: MTLDevice, library: MTLLibrary) throws -> MTLTexture {
        guard let kernelFunction = library.makeFunction(name: "gltf_ibl_brdf_lut") else {
            throw GLTFRendererError.missingShaderFunction(name: "gltf_ibl_brdf_lut")
        }

        let pipelineState = try device.makeComputePipelineState(function: kernelFunction)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg16Float,
            width: size,
            height: size,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw GLTFIBLError.brdfLUTAllocationFailed
        }

        guard let commandQueue = device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw GLTFIBLError.brdfLUTAllocationFailed
        }

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(texture, index: 0)

        let threadWidth = pipelineState.threadExecutionWidth
        let threadHeight = pipelineState.maxTotalThreadsPerThreadgroup / threadWidth
        let threadsPerThreadgroup = MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        let threadsPerGrid = MTLSize(width: size, height: size, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw GLTFIBLError.brdfLUTComputeFailed(reason: error.localizedDescription)
        }

        return texture
    }
}

/// Errors thrown by IBL prep.
public enum GLTFIBLError: Error, LocalizedError {
    case brdfLUTAllocationFailed
    case brdfLUTComputeFailed(reason: String)
    case environmentAllocationFailed
    case environmentComputeFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .brdfLUTAllocationFailed:
            return """
            ❌ BRDF LUT Allocation Failed

            Metal failed to allocate a 256×256 .rg16Float texture or a compute command buffer.

            Suggestion: Check that the supplied MTLDevice is valid and that the system has enough free GPU memory. The LUT itself is tiny (~256 KB), so allocation failure usually indicates a more general Metal problem.
            """
        case .brdfLUTComputeFailed(let reason):
            return """
            ❌ BRDF LUT Compute Failed

            Reason: \(reason)

            Suggestion: Rebuild the GLTFMetalKit shaders via `make gltf-shaders`. The kernel `gltf_ibl_brdf_lut` lives in `Sources/GLTFMetalKit/Shaders/IBLPrefilter.metal`.
            """
        case .environmentAllocationFailed:
            return """
            ❌ Environment Allocation Failed

            Metal failed to allocate a cubemap or compute command buffer for the procedural environment.

            Suggestion: Verify the MTLDevice is valid and the system has enough free GPU memory. The runtime IBL pipeline allocates one 256-cube source + one 32-cube diffuse + one 256-cube specular mip chain — typically a few MB.
            """
        case .environmentComputeFailed(let reason):
            return """
            ❌ Environment Compute Failed

            Reason: \(reason)

            Suggestion: Rebuild GLTFMetalKit shaders with `make gltf-shaders`. The kernels involved are `gltf_ibl_procedural_sky`, `gltf_ibl_specular_prefilter`, and `gltf_ibl_diffuse_irradiance` (see `Sources/GLTFMetalKit/Shaders/IBLPrefilter.metal`).
            """
        }
    }
}

/// Parameters for the procedural sky cubemap kernel. Matches
/// `GLTFSkyParams` in `IBLPrefilter.metal`.
public struct GLTFProceduralSkyParams: Sendable {
    /// World-space direction the sun light travels (downward + sideways).
    public var sunDirection: SIMD3<Float>
    public var _pad0: Float = 0
    /// Linear RGB pre-multiplied by intensity. Bright values are expected
    /// for a credible IBL response — `[20, 18, 14]` reads as a warm sun.
    public var sunColor: SIMD3<Float>
    /// Half-angle of the sun disk in radians. The default ~0.5° matches
    /// the apparent size of the real sun (~9.3 mrad).
    public var sunAngularRadius: Float
    public var zenithColor: SIMD3<Float>
    public var _pad1: Float = 0
    public var horizonColor: SIMD3<Float>
    public var _pad2: Float = 0
    public var groundColor: SIMD3<Float>
    public var _pad3: Float = 0

    public static let `default` = GLTFProceduralSkyParams(
        // Sun roughly up-and-backward — bounces off the +Z facing test quad.
        sunDirection: normalize(SIMD3<Float>(0.3, -0.7, -0.4)),
        // Real-world HDR intensities. The diffuse irradiance integrates this
        // over the whole upper hemisphere; the specular prefilter at low
        // roughness picks up the sun disk. Without HDR values the metallic
        // vs dielectric distinction collapses into the noise floor of
        // 8-bit framebuffer readback.
        sunColor: SIMD3<Float>(800.0, 700.0, 500.0),
        // Wider sun so the importance-sampled GGX prefilter reliably hits
        // it at low roughness — at the canonical 0.5° solar half-angle
        // the disk spans ~3 texels of a 256-cube and the sampler misses
        // it for many output texels.
        sunAngularRadius: 0.15,
        zenithColor: SIMD3<Float>(0.4, 0.55, 0.85) * 5.0,
        horizonColor: SIMD3<Float>(0.95, 0.85, 0.75) * 3.0,
        groundColor: SIMD3<Float>(0.15, 0.13, 0.10)
    )

    public init(
        sunDirection: SIMD3<Float>,
        sunColor: SIMD3<Float>,
        sunAngularRadius: Float,
        zenithColor: SIMD3<Float>,
        horizonColor: SIMD3<Float>,
        groundColor: SIMD3<Float>
    ) {
        self.sunDirection = sunDirection
        self.sunColor = sunColor
        self.sunAngularRadius = sunAngularRadius
        self.zenithColor = zenithColor
        self.horizonColor = horizonColor
        self.groundColor = groundColor
    }
}

extension GLTFEnvironment {

    /// Generates a real IBL environment at runtime from a procedural sky.
    ///
    /// Three compute passes:
    ///   1. `gltf_ibl_procedural_sky` writes a 256×256 source cubemap
    ///      using a gradient + sun-disk model.
    ///   2. `gltf_ibl_specular_prefilter` produces an 8-mip specular
    ///      cubemap by GGX-importance-sampling the source per roughness.
    ///   3. `gltf_ibl_diffuse_irradiance` integrates the cosine-weighted
    ///      hemisphere for the 32×32 diffuse cubemap.
    ///
    /// Synchronous — the compute work waits to completion so the returned
    /// `GLTFEnvironment` is immediately renderable. Costs ~1024
    /// Hammersley samples × 8 mips × 6 faces × (256→2) — well under a
    /// second on Apple silicon, and the result caches forever.
    ///
    /// Pass to ``GLTFRenderer/environment`` to replace the 1×1 gray
    /// fallback.
    public static func makeProcedural(
        device: MTLDevice,
        library: MTLLibrary,
        params: GLTFProceduralSkyParams = .default,
        sourceSize: Int = 256,
        specularSize: Int = 256,
        diffuseSize: Int = 32
    ) throws -> GLTFEnvironment {
        let specularMipCount = max(Int(floor(log2(Double(specularSize)))) + 1, 1)

        // --- Allocate textures ---------------------------------------------

        let cubemapPixelFormat: MTLPixelFormat = .rgba16Float

        let sourceDescriptor = MTLTextureDescriptor.textureCubeDescriptor(
            pixelFormat: cubemapPixelFormat, size: sourceSize, mipmapped: false
        )
        sourceDescriptor.usage = [.shaderRead, .shaderWrite]
        sourceDescriptor.storageMode = .private
        guard let source = device.makeTexture(descriptor: sourceDescriptor) else {
            throw GLTFIBLError.environmentAllocationFailed
        }

        let specularDescriptor = MTLTextureDescriptor.textureCubeDescriptor(
            pixelFormat: cubemapPixelFormat, size: specularSize, mipmapped: true
        )
        specularDescriptor.mipmapLevelCount = specularMipCount
        specularDescriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
        specularDescriptor.storageMode = .private
        guard let specular = device.makeTexture(descriptor: specularDescriptor) else {
            throw GLTFIBLError.environmentAllocationFailed
        }

        let diffuseDescriptor = MTLTextureDescriptor.textureCubeDescriptor(
            pixelFormat: cubemapPixelFormat, size: diffuseSize, mipmapped: false
        )
        diffuseDescriptor.usage = [.shaderRead, .shaderWrite]
        diffuseDescriptor.storageMode = .private
        guard let diffuse = device.makeTexture(descriptor: diffuseDescriptor) else {
            throw GLTFIBLError.environmentAllocationFailed
        }

        // --- Pipeline states -----------------------------------------------

        guard let skyFn      = library.makeFunction(name: "gltf_ibl_procedural_sky") else {
            throw GLTFRendererError.missingShaderFunction(name: "gltf_ibl_procedural_sky")
        }
        guard let specularFn = library.makeFunction(name: "gltf_ibl_specular_prefilter") else {
            throw GLTFRendererError.missingShaderFunction(name: "gltf_ibl_specular_prefilter")
        }
        guard let diffuseFn  = library.makeFunction(name: "gltf_ibl_diffuse_irradiance") else {
            throw GLTFRendererError.missingShaderFunction(name: "gltf_ibl_diffuse_irradiance")
        }
        let skyPipeline      = try device.makeComputePipelineState(function: skyFn)
        let specularPipeline = try device.makeComputePipelineState(function: specularFn)
        let diffusePipeline  = try device.makeComputePipelineState(function: diffuseFn)

        guard let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer() else {
            throw GLTFIBLError.environmentAllocationFailed
        }

        // Sampler used by the prefilter + irradiance kernels to read `source`.
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        samplerDescriptor.rAddressMode = .clampToEdge
        guard let envSampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw GLTFIBLError.environmentAllocationFailed
        }

        // --- Pass 1: procedural sky into source cubemap --------------------

        do {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw GLTFIBLError.environmentAllocationFailed
            }
            var skyParams = params
            encoder.setComputePipelineState(skyPipeline)
            encoder.setTexture(source, index: 0)
            encoder.setBytes(&skyParams, length: MemoryLayout<GLTFProceduralSkyParams>.stride, index: 0)

            let threadsPerGrid = MTLSize(width: sourceSize, height: sourceSize, depth: 6)
            let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 1)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()
        }

        // --- Pass 2: specular prefilter, one dispatch per mip --------------

        for mip in 0..<specularMipCount {
            // Create a per-mip texture view so `outCube.write(...)` writes
            // into the correct mip slice. (texture.makeTextureView limits
            // the view to one mip; the kernel writes mip 0 of that view.)
            guard let mipView = specular.makeTextureView(
                pixelFormat: cubemapPixelFormat,
                textureType: .typeCube,
                levels: mip..<(mip + 1),
                slices: 0..<6
            ) else {
                throw GLTFIBLError.environmentAllocationFailed
            }

            let roughness = specularMipCount == 1 ? 0.0 : Float(mip) / Float(specularMipCount - 1)
            let faceSize = max(specularSize >> mip, 1)

            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw GLTFIBLError.environmentAllocationFailed
            }
            encoder.setComputePipelineState(specularPipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(mipView, index: 1)
            encoder.setSamplerState(envSampler, index: 0)

            var prefilterParams = ShaderPrefilterParams(roughness: roughness)
            encoder.setBytes(&prefilterParams, length: MemoryLayout<ShaderPrefilterParams>.stride, index: 0)

            let threadsPerGrid = MTLSize(width: faceSize, height: faceSize, depth: 6)
            let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 1)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()
        }

        // --- Pass 3: diffuse irradiance ------------------------------------

        do {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw GLTFIBLError.environmentAllocationFailed
            }
            encoder.setComputePipelineState(diffusePipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(diffuse, index: 1)
            encoder.setSamplerState(envSampler, index: 0)

            let threadsPerGrid = MTLSize(width: diffuseSize, height: diffuseSize, depth: 6)
            let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 1)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw GLTFIBLError.environmentComputeFailed(reason: error.localizedDescription)
        }

        return GLTFEnvironment(diffuse: diffuse, specular: specular)
    }
}

/// Per-mip prefilter kernel parameters, mirroring `GLTFPrefilterParams` in
/// `IBLPrefilter.metal`.
private struct ShaderPrefilterParams {
    var roughness: Float
}

extension GLTFEnvironment {

    /// Builds an IBL environment from a Radiance HDR equirectangular panorama.
    ///
    /// Steps:
    ///   1. Parse the `.hdr` into half-float RGBA pixels.
    ///   2. Upload as a 2D source texture.
    ///   3. Run `gltf_ibl_equirect_to_cube` to project into a cubemap.
    ///   4. Reuse the procedural pipeline's specular prefilter + diffuse
    ///      irradiance kernels on that cubemap.
    ///
    /// Synchronous — compute work waits to completion. Pass the result to
    /// ``GLTFRenderer/environment`` to replace either the gray fallback or
    /// a previous procedural environment.
    public static func makeFromRadianceHDR(
        data: Data,
        device: MTLDevice,
        library: MTLLibrary,
        sourceCubeSize: Int = 512,
        specularSize: Int = 256,
        diffuseSize: Int = 32
    ) throws -> GLTFEnvironment {
        let hdr = try GLTFRadianceHDR(data: data)
        let specularMipCount = max(Int(floor(log2(Double(specularSize)))) + 1, 1)

        // --- 2D source texture from the HDR pixels ---
        let panoDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: hdr.width, height: hdr.height, mipmapped: false
        )
        panoDescriptor.usage = [.shaderRead]
        panoDescriptor.storageMode = .shared
        guard let panoTexture = device.makeTexture(descriptor: panoDescriptor) else {
            throw GLTFIBLError.environmentAllocationFailed
        }
        hdr.pixelsFloat16.withUnsafeBytes { ptr in
            panoTexture.replace(
                region: MTLRegionMake2D(0, 0, hdr.width, hdr.height),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: hdr.width * MemoryLayout<UInt16>.stride * 4
            )
        }

        // --- Cubemap allocations + pipelines mirror makeProcedural ---
        let cubemapPixelFormat: MTLPixelFormat = .rgba16Float
        let sourceDescriptor = MTLTextureDescriptor.textureCubeDescriptor(
            pixelFormat: cubemapPixelFormat, size: sourceCubeSize, mipmapped: false
        )
        sourceDescriptor.usage = [.shaderRead, .shaderWrite]
        sourceDescriptor.storageMode = .private
        guard let source = device.makeTexture(descriptor: sourceDescriptor) else {
            throw GLTFIBLError.environmentAllocationFailed
        }

        let specularDescriptor = MTLTextureDescriptor.textureCubeDescriptor(
            pixelFormat: cubemapPixelFormat, size: specularSize, mipmapped: true
        )
        specularDescriptor.mipmapLevelCount = specularMipCount
        specularDescriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
        specularDescriptor.storageMode = .private
        guard let specular = device.makeTexture(descriptor: specularDescriptor) else {
            throw GLTFIBLError.environmentAllocationFailed
        }

        let diffuseDescriptor = MTLTextureDescriptor.textureCubeDescriptor(
            pixelFormat: cubemapPixelFormat, size: diffuseSize, mipmapped: false
        )
        diffuseDescriptor.usage = [.shaderRead, .shaderWrite]
        diffuseDescriptor.storageMode = .private
        guard let diffuse = device.makeTexture(descriptor: diffuseDescriptor) else {
            throw GLTFIBLError.environmentAllocationFailed
        }

        guard let equirectFn = library.makeFunction(name: "gltf_ibl_equirect_to_cube") else {
            throw GLTFRendererError.missingShaderFunction(name: "gltf_ibl_equirect_to_cube")
        }
        guard let specularFn = library.makeFunction(name: "gltf_ibl_specular_prefilter") else {
            throw GLTFRendererError.missingShaderFunction(name: "gltf_ibl_specular_prefilter")
        }
        guard let diffuseFn = library.makeFunction(name: "gltf_ibl_diffuse_irradiance") else {
            throw GLTFRendererError.missingShaderFunction(name: "gltf_ibl_diffuse_irradiance")
        }
        let equirectPipeline = try device.makeComputePipelineState(function: equirectFn)
        let specularPipeline = try device.makeComputePipelineState(function: specularFn)
        let diffusePipeline = try device.makeComputePipelineState(function: diffuseFn)

        guard let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer() else {
            throw GLTFIBLError.environmentAllocationFailed
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .repeat   // equirect wraps in U
        samplerDescriptor.tAddressMode = .clampToEdge
        samplerDescriptor.rAddressMode = .clampToEdge
        guard let panoSampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw GLTFIBLError.environmentAllocationFailed
        }
        let envSamplerDescriptor = MTLSamplerDescriptor()
        envSamplerDescriptor.minFilter = .linear
        envSamplerDescriptor.magFilter = .linear
        envSamplerDescriptor.mipFilter = .linear
        envSamplerDescriptor.sAddressMode = .clampToEdge
        envSamplerDescriptor.tAddressMode = .clampToEdge
        envSamplerDescriptor.rAddressMode = .clampToEdge
        guard let envSampler = device.makeSamplerState(descriptor: envSamplerDescriptor) else {
            throw GLTFIBLError.environmentAllocationFailed
        }

        // --- Pass 1: equirectangular → cubemap ---
        do {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw GLTFIBLError.environmentAllocationFailed
            }
            encoder.setComputePipelineState(equirectPipeline)
            encoder.setTexture(panoTexture, index: 0)
            encoder.setTexture(source, index: 1)
            encoder.setSamplerState(panoSampler, index: 0)
            let threadsPerGrid = MTLSize(width: sourceCubeSize, height: sourceCubeSize, depth: 6)
            let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 1)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()
        }

        // --- Pass 2: specular prefilter per mip ---
        for mip in 0..<specularMipCount {
            guard let mipView = specular.makeTextureView(
                pixelFormat: cubemapPixelFormat,
                textureType: .typeCube,
                levels: mip..<(mip + 1),
                slices: 0..<6
            ) else {
                throw GLTFIBLError.environmentAllocationFailed
            }
            let roughness = specularMipCount == 1 ? 0.0 : Float(mip) / Float(specularMipCount - 1)
            let faceSize = max(specularSize >> mip, 1)
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw GLTFIBLError.environmentAllocationFailed
            }
            encoder.setComputePipelineState(specularPipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(mipView, index: 1)
            encoder.setSamplerState(envSampler, index: 0)
            var prefilterParams = ShaderPrefilterParams(roughness: roughness)
            encoder.setBytes(&prefilterParams, length: MemoryLayout<ShaderPrefilterParams>.stride, index: 0)
            let threadsPerGrid = MTLSize(width: faceSize, height: faceSize, depth: 6)
            let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 1)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()
        }

        // --- Pass 3: diffuse irradiance ---
        do {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw GLTFIBLError.environmentAllocationFailed
            }
            encoder.setComputePipelineState(diffusePipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(diffuse, index: 1)
            encoder.setSamplerState(envSampler, index: 0)
            let threadsPerGrid = MTLSize(width: diffuseSize, height: diffuseSize, depth: 6)
            let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 1)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw GLTFIBLError.environmentComputeFailed(reason: error.localizedDescription)
        }

        return GLTFEnvironment(diffuse: diffuse, specular: specular)
    }

    /// Convenience: load + decode + bake an HDR from a file URL.
    public static func makeFromRadianceHDR(
        url: URL,
        device: MTLDevice,
        library: MTLLibrary,
        sourceCubeSize: Int = 512,
        specularSize: Int = 256,
        diffuseSize: Int = 32
    ) throws -> GLTFEnvironment {
        let data = try Data(contentsOf: url)
        return try makeFromRadianceHDR(
            data: data, device: device, library: library,
            sourceCubeSize: sourceCubeSize,
            specularSize: specularSize,
            diffuseSize: diffuseSize
        )
    }
}
