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

    /// Creates a renderer bound to a Metal device.
    ///
    /// - Parameter device: The Metal device to use for pipeline state and
    ///   GPU resource allocation. Typically `MTLCreateSystemDefaultDevice()`.
    /// - Throws: An error if the bundled `GLTFMetalKitShaders.metallib`
    ///   cannot be located or loaded.
    public init(device: MTLDevice) throws {
        self.device = device

        guard let metallibURL = GLTFMetalKit.bundle.url(
            forResource: "GLTFMetalKitShaders",
            withExtension: "metallib"
        ) else {
            throw GLTFRendererError.missingShaderLibrary
        }

        self.library = try device.makeLibrary(URL: metallibURL)
    }

    /// Builds the vertex descriptor that matches ``GLTFPBRShader.metal``'s
    /// `GLTFVertexIn`.
    ///
    /// Attribute layout: position (float3) | normal (float3) | tangent
    /// (float4) | uv0 (float2). All in a single interleaved buffer at
    /// ``GLTFShaderBindings/vertexBuffer``.
    public static func makeVertexDescriptor() -> MTLVertexDescriptor {
        let vd = MTLVertexDescriptor()

        var offset = 0
        // attribute 0: position
        vd.attributes[0].format = .float3
        vd.attributes[0].offset = offset
        vd.attributes[0].bufferIndex = GLTFShaderBindings.vertexBuffer
        offset += MemoryLayout<SIMD3<Float>>.stride  // 16 — float3 is padded to 16 in MSL

        // attribute 1: normal
        vd.attributes[1].format = .float3
        vd.attributes[1].offset = offset
        vd.attributes[1].bufferIndex = GLTFShaderBindings.vertexBuffer
        offset += MemoryLayout<SIMD3<Float>>.stride

        // attribute 2: tangent
        vd.attributes[2].format = .float4
        vd.attributes[2].offset = offset
        vd.attributes[2].bufferIndex = GLTFShaderBindings.vertexBuffer
        offset += MemoryLayout<SIMD4<Float>>.stride

        // attribute 3: uv0
        vd.attributes[3].format = .float2
        vd.attributes[3].offset = offset
        vd.attributes[3].bufferIndex = GLTFShaderBindings.vertexBuffer
        offset += MemoryLayout<SIMD2<Float>>.stride

        vd.layouts[GLTFShaderBindings.vertexBuffer].stride = offset
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
}

/// Errors thrown by ``GLTFRenderer``.
public enum GLTFRendererError: Error, LocalizedError {
    /// The bundled `GLTFMetalKitShaders.metallib` resource could not be found.
    case missingShaderLibrary
    /// A required shader function is absent from the loaded metallib (likely a stale build of `Sources/GLTFMetalKit/Resources/GLTFMetalKitShaders.metallib`).
    case missingShaderFunction(name: String)

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
        }
    }
}
