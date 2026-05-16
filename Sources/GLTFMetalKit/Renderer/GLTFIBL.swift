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
        }
    }
}
