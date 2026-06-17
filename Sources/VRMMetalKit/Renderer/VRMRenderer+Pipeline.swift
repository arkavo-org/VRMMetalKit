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
import MetalKit
import simd

extension VRMRenderer {
    /// Build a ``VRMPipelineCache`` key that captures every property of the
    /// pipeline descriptor that affects compilation.
    ///
    /// The static `name` pins the shader-function pair, blend state,
    /// alpha-to-coverage flag, and vertex layout (which are constant per
    /// call site). `config.colorPixelFormat` and `config.sampleCount` vary
    /// per renderer, so they must be part of the cache key — otherwise a
    /// second renderer asking for the "same" pipeline at a different format
    /// or sample count receives the first renderer's pipeline back and the
    /// GPU silently writes the wrong attachment layout. That latent collision
    /// is what surfaced as the framebuffer-format mismatch behind
    /// vrm-conformance #213 (linear bytes where sRGB-encoded bytes were
    /// expected, because the cache returned a `.bgra8Unorm` pipeline for a
    /// `.rgba8Unorm_srgb` render target).
    func pipelineKey(_ name: String) -> String {
        return "\(name)|fmt=\(config.colorPixelFormat.rawValue)|samples=\(config.sampleCount)"
    }

    /// Enables the process-wide pipeline binary archive when
    /// ``RendererConfig/enablePipelineArchive`` is set, so the pipeline builds
    /// that follow are served from / recorded into an on-disk archive. Resolves
    /// the archive directory (config override or the caches dir) and the
    /// shader-hash invalidation key. Returns whether persistence was enabled;
    /// any failure degrades silently to plain in-memory caching.
    static func enablePipelineArchiveIfRequested(device: MTLDevice, config: RendererConfig) -> Bool {
        guard config.enablePipelineArchive else { return false }
        guard let shaderHash = VRMShaderLibraryLoader.bundledLibraryHash() else {
            vrmLog("[VRMRenderer] Pipeline archive requested but the bundled shader hash is unavailable; skipping persistence.")
            return false
        }
        let directory: URL
        if let dir = config.pipelineArchiveDirectory {
            directory = dir
        } else if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            directory = caches.appendingPathComponent("VRMMetalKitPipelineArchive", isDirectory: true)
        } else {
            vrmLog("[VRMRenderer] Pipeline archive requested but no caches directory is available; skipping persistence.")
            return false
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try VRMPipelineCache.shared.enablePersistentArchive(
                device: device, directory: directory, shaderHash: shaderHash)
            return true
        } catch {
            vrmLog("[VRMRenderer] Failed to enable pipeline archive: \(error); falling back to in-memory cache.")
            return false
        }
    }

    func validateMaterialUniformAlignment() {
        // Calculate Swift struct size and stride
        let swiftSize = MemoryLayout<MToonMaterialUniforms>.size
        let swiftStride = MemoryLayout<MToonMaterialUniforms>.stride

        // Expected Metal struct size — sourced from the canonical constant in StrictMode.
        // Blocks 0-11 are the original MToon material fields; blocks 12-14 cover
        // the time uniform and the KHR_texture_transform offset/rotation/scale.
        let expectedMetalSize = MetalSizeConstants.mtoonMaterialSize

        if config.strict != .off {
            vrmLog("[VRMRenderer] MToonMaterialUniforms alignment check:")
            vrmLog("  - Swift size: \(swiftSize) bytes")
            vrmLog("  - Swift stride: \(swiftStride) bytes")
            vrmLog("  - Expected Metal size: \(expectedMetalSize) bytes")
        }

        // In strict mode, fail if sizes don't match
        if config.strict != .off {
            if swiftStride != expectedMetalSize {
                let message = "MToonMaterialUniforms stride mismatch! Swift: \(swiftStride), Expected: \(expectedMetalSize)"
                if config.strict == .fail {
                    do {
                        try strictValidator?.handle(.uniformLayoutMismatch(swift: swiftStride, metal: expectedMetalSize, type: "MToonMaterialUniforms"))
                    } catch {
                        vrmLog("⚠️ [StrictMode] Error handling validation: \(error)")
                    }
                } else {
                    vrmLog("⚠️ [StrictMode] \(message)")
                }
            }
        }
    }

    func setupTripleBuffering() {
        // Create triple-buffered uniform buffers with private storage for GPU efficiency
        let uniformSize = MemoryLayout<Uniforms>.size
        for _ in 0..<Self.maxBufferedFrames {
            if let buffer = device.makeBuffer(length: uniformSize, options: .storageModeShared) {
                buffer.label = "Uniform Buffer \(uniformsBuffers.count)"
                uniformsBuffers.append(buffer)
            }
        }

        if uniformsBuffers.count != Self.maxBufferedFrames {
            vrmLog("[VRMRenderer] Warning: Failed to create all uniform buffers. Created \(uniformsBuffers.count)/\(Self.maxBufferedFrames)")
        }
    }

    func setupCachedStates() {
        // Pre-create depth stencil states
        // Opaque/Mask state
        let opaqueDepthDescriptor = MTLDepthStencilDescriptor()
        opaqueDepthDescriptor.depthCompareFunction = .less
        opaqueDepthDescriptor.isDepthWriteEnabled = true
        if let state = device.makeDepthStencilState(descriptor: opaqueDepthDescriptor) {
            depthStencilStates["opaque"] = state
            depthStencilStates["mask"] = state  // Same as opaque
        }

        // Blend state (no depth write)
        let blendDepthDescriptor = MTLDepthStencilDescriptor()
        blendDepthDescriptor.depthCompareFunction = .lessEqual
        blendDepthDescriptor.isDepthWriteEnabled = false
        if let state = device.makeDepthStencilState(descriptor: blendDepthDescriptor) {
            depthStencilStates["blend"] = state
        }

        // Kill switch test state (always pass, no depth write)
        let alwaysDepthDescriptor = MTLDepthStencilDescriptor()
        alwaysDepthDescriptor.depthCompareFunction = .always  // Always pass depth test
        alwaysDepthDescriptor.isDepthWriteEnabled = false     // Don't write to depth buffer
        if let state = device.makeDepthStencilState(descriptor: alwaysDepthDescriptor) {
            depthStencilStates["always"] = state
        }

        // Face materials depth state - more permissive to avoid z-fighting
        let faceDepthDescriptor = MTLDepthStencilDescriptor()
        faceDepthDescriptor.depthCompareFunction = .lessEqual  // More permissive than .less
        faceDepthDescriptor.isDepthWriteEnabled = true
        if let state = device.makeDepthStencilState(descriptor: faceDepthDescriptor) {
            depthStencilStates["face"] = state
        }

        // Face overlay depth state - for materials that render on top of face skin (mouth, eyebrows)
        // Uses lessEqual (wins at equal depth) but doesn't write depth to avoid Z-fighting
        let faceOverlayDescriptor = MTLDepthStencilDescriptor()
        faceOverlayDescriptor.depthCompareFunction = .lessEqual
        faceOverlayDescriptor.isDepthWriteEnabled = false  // Don't write - prevents Z-fighting
        if let state = device.makeDepthStencilState(descriptor: faceOverlayDescriptor) {
            depthStencilStates["faceOverlay"] = state
        }

        // Depth prepass: write opaque depth ahead of the main pass (same as opaque).
        let prepassDescriptor = MTLDepthStencilDescriptor()
        prepassDescriptor.depthCompareFunction = .less
        prepassDescriptor.isDepthWriteEnabled = true
        if let state = device.makeDepthStencilState(descriptor: prepassDescriptor) {
            depthStencilStates["prepass"] = state
        }

        // Opaque main pass AFTER a depth prepass: test `.lessEqual` against the
        // prepass-written depth and do NOT write (early-Z rejects occluded
        // fragments). `.lessEqual` (not `.equal`) tolerates depth-bias / tiny
        // differences without dropping visible fragments.
        let opaqueEqualDescriptor = MTLDepthStencilDescriptor()
        opaqueEqualDescriptor.depthCompareFunction = .lessEqual
        opaqueEqualDescriptor.isDepthWriteEnabled = false
        if let state = device.makeDepthStencilState(descriptor: opaqueEqualDescriptor) {
            depthStencilStates["opaqueEqual"] = state
        }

        // Pre-create sampler states
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .repeat
        samplerDescriptor.tAddressMode = .repeat
        samplerDescriptor.maxAnisotropy = 16
        if let sampler = device.makeSamplerState(descriptor: samplerDescriptor) {
            samplerStates["default"] = sampler
        }
    }

    func setupPipeline() {
        // Use MToon shader for proper VRM rendering

        do {
            // Load precompiled shader library (50-100x faster than runtime compilation)
            let library = try VRMPipelineCache.shared.getLibrary(device: device)

            // Validate vertex function
            let vertexFunction = library.makeFunction(name: "mtoon_vertex")
            try strictValidator?.validateFunction(vertexFunction, name: "mtoon_vertex", type: "vertex")
            guard let vertexFunc = vertexFunction else {
                if config.strict == .off {
                    vrmLog("[VRMRenderer] Failed to find mtoon_vertex function")
                    return
                }
                throw StrictModeError.missingVertexFunction(name: "mtoon_vertex")
            }

            // Validate fragment function. Use function constants in fallback mode
            // so the same shader source supports both the dynamic path and future
            // per-material specializations.
            vrmLog("[SHADER DEBUG] Looking for fragment function: mtoon_fragment_v2")
            let fragmentFunction = try? library.makeFunction(
                name: "mtoon_fragment_v2",
                constantValues: MToonFunctionConstantKey.fallback.makeFunctionConstantValues()
            )
            vrmLog("[SHADER DEBUG] Fragment function found: \(fragmentFunction != nil)")
            try strictValidator?.validateFunction(fragmentFunction, name: "mtoon_fragment_v2", type: "fragment")
            guard let fragmentFunc = fragmentFunction else {
                if config.strict == .off {
                    vrmLog("[VRMRenderer] Failed to find mtoon_fragment_v2 function")
                    return
                }
                throw StrictModeError.missingFragmentFunction(name: "mtoon_fragment_v2")
            }

            // Create vertex descriptor
            let vertexDescriptor = MTLVertexDescriptor()

            // Use compiler-accurate offsets (fixes alignment padding issues)
            let posOffset = MemoryLayout<VRMVertex>.offset(of: \.position)!
            let normOffset = MemoryLayout<VRMVertex>.offset(of: \.normal)!
            let texOffset = MemoryLayout<VRMVertex>.offset(of: \.texCoord)!
            let colorOffset = MemoryLayout<VRMVertex>.offset(of: \.color)!
            let stride = MemoryLayout<VRMVertex>.stride

            // Position
            vertexDescriptor.attributes[0].format = .float3
            vertexDescriptor.attributes[0].offset = posOffset
            vertexDescriptor.attributes[0].bufferIndex = 0

            // Normal
            vertexDescriptor.attributes[1].format = .float3
            vertexDescriptor.attributes[1].offset = normOffset
            vertexDescriptor.attributes[1].bufferIndex = 0

            // TexCoord
            vertexDescriptor.attributes[2].format = .float2
            vertexDescriptor.attributes[2].offset = texOffset
            vertexDescriptor.attributes[2].bufferIndex = 0

            // Color
            vertexDescriptor.attributes[3].format = .float4
            vertexDescriptor.attributes[3].offset = colorOffset
            vertexDescriptor.attributes[3].bufferIndex = 0

            vertexDescriptor.layouts[0].stride = stride

            // Create base pipeline descriptor
            let basePipelineDescriptor = MTLRenderPipelineDescriptor()
            basePipelineDescriptor.vertexFunction = vertexFunc
            basePipelineDescriptor.fragmentFunction = fragmentFunc
            basePipelineDescriptor.vertexDescriptor = vertexDescriptor
            basePipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
            basePipelineDescriptor.rasterSampleCount = config.sampleCount

            // Create OPAQUE/MASK pipeline (no blending)
            let opaqueDescriptor = basePipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            opaqueDescriptor.label = "mtoon_opaque"  // Add label for debugging
            let opaqueColorAttachment = opaqueDescriptor.colorAttachments[0]
            opaqueColorAttachment?.pixelFormat = config.colorPixelFormat
            opaqueColorAttachment?.isBlendingEnabled = false

            // Use cached pipeline state for better performance
            let opaqueState = try VRMPipelineCache.shared.getPipelineState(
                device: device,
                descriptor: opaqueDescriptor,
                key: pipelineKey("mtoon_opaque")
            )
            try strictValidator?.validatePipelineState(opaqueState, name: "mtoon_opaque_pipeline")
            opaquePipelineState = opaqueState

            // Create BLEND pipeline (blending enabled)
            let blendDescriptor = basePipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            blendDescriptor.label = "mtoon_blend"  // Add label for debugging
            let blendColorAttachment = blendDescriptor.colorAttachments[0]
            blendColorAttachment?.pixelFormat = config.colorPixelFormat
            blendColorAttachment?.isBlendingEnabled = true
            blendColorAttachment?.sourceRGBBlendFactor = .sourceAlpha
            blendColorAttachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
            blendColorAttachment?.rgbBlendOperation = .add
            // Alpha union: final.a = src.a + dst.a*(1-src.a). `.one` (not `.sourceAlpha`)
            // keeps dst.a=1 when src draws over an already-opaque pixel, so transparent
            // MTKView compositing doesn't bleed background through stacked BLEND layers.
            blendColorAttachment?.sourceAlphaBlendFactor = .one
            blendColorAttachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            blendColorAttachment?.alphaBlendOperation = .add

            // Use cached pipeline state for better performance
            let blendState = try VRMPipelineCache.shared.getPipelineState(
                device: device,
                descriptor: blendDescriptor,
                key: pipelineKey("mtoon_blend")
            )
            try strictValidator?.validatePipelineState(blendState, name: "mtoon_blend_pipeline")
            blendPipelineState = blendState

            // Create WIREFRAME pipeline (for debugging)
            let wireframeDescriptor = basePipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            wireframeDescriptor.label = "mtoon_wireframe"  // Add label for debugging
            let wireframeColorAttachment = wireframeDescriptor.colorAttachments[0]
            wireframeColorAttachment?.pixelFormat = config.colorPixelFormat
            wireframeColorAttachment?.isBlendingEnabled = false

            // Use cached pipeline state for better performance
            let wireframeState = try VRMPipelineCache.shared.getPipelineState(
                device: device,
                descriptor: wireframeDescriptor,
                key: pipelineKey("mtoon_wireframe")
            )
            try strictValidator?.validatePipelineState(wireframeState, name: "mtoon_wireframe_pipeline")
            wireframePipelineState = wireframeState
            
            // Create MASK with Alpha-to-Coverage pipeline (reduces edge aliasing)
            // This requires MSAA render target (sampleCount > 1)
            let maskA2CDescriptor = basePipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            maskA2CDescriptor.label = "mtoon_mask_a2c"
            maskA2CDescriptor.isAlphaToCoverageEnabled = true
            let maskA2CColorAttachment = maskA2CDescriptor.colorAttachments[0]
            maskA2CColorAttachment?.pixelFormat = config.colorPixelFormat
            maskA2CColorAttachment?.isBlendingEnabled = false
            
            let maskA2CState = try VRMPipelineCache.shared.getPipelineState(
                device: device,
                descriptor: maskA2CDescriptor,
                key: pipelineKey("mtoon_mask_a2c")
            )
            try strictValidator?.validatePipelineState(maskA2CState, name: "mtoon_mask_a2c_pipeline")
            maskAlphaToCoveragePipelineState = maskA2CState
            vrmLog("[VRMRenderer] Created MASK alpha-to-coverage pipeline")

            // Create MToon OUTLINE pipeline (inverted hull technique).
            // The outline vertex shader also references function constants, so
            // build it with the fallback key to preserve the dynamic uniform path.
            let outlineVertexFunction = try? library.makeFunction(
                name: "mtoon_outline_vertex",
                constantValues: MToonFunctionConstantKey.fallback.makeFunctionConstantValues()
            )
            let outlineFragmentFunction = library.makeFunction(name: "mtoon_outline_fragment")
            if let outlineVertexFunc = outlineVertexFunction,
               let outlineFragmentFunc = outlineFragmentFunction {
                let outlineDescriptor = MTLRenderPipelineDescriptor()
                outlineDescriptor.label = "mtoon_outline"
                outlineDescriptor.vertexFunction = outlineVertexFunc
                outlineDescriptor.fragmentFunction = outlineFragmentFunc
                outlineDescriptor.vertexDescriptor = vertexDescriptor
                outlineDescriptor.depthAttachmentPixelFormat = .depth32Float
                outlineDescriptor.rasterSampleCount = config.sampleCount

                let outlineColorAttachment = outlineDescriptor.colorAttachments[0]
                outlineColorAttachment?.pixelFormat = config.colorPixelFormat
                outlineColorAttachment?.isBlendingEnabled = false  // Outlines are opaque

                let outlineState = try VRMPipelineCache.shared.getPipelineState(
                    device: device,
                    descriptor: outlineDescriptor,
                    key: pipelineKey("mtoon_outline")
                )
                mtoonOutlinePipelineState = outlineState
                vrmLog("[VRMRenderer] Created MToon outline pipeline successfully")
            } else {
                vrmLog("[VRMRenderer] MToon outline shaders not found - outlines will be disabled")
            }

            // Non-skinned depth-prepass pipeline: position-only, no fragment.
            if let depthVertexFunc = library.makeFunction(name: "mtoon_depth_vertex") {
                let depthVD = MTLVertexDescriptor()
                depthVD.attributes[0].format = .float3
                depthVD.attributes[0].offset = MemoryLayout<VRMVertex>.offset(of: \.position)!
                depthVD.attributes[0].bufferIndex = 0
                depthVD.layouts[0].stride = MemoryLayout<VRMVertex>.stride

                let depthDescriptor = MTLRenderPipelineDescriptor()
                depthDescriptor.label = "mtoon_depth_prepass"
                depthDescriptor.vertexFunction = depthVertexFunc
                depthDescriptor.fragmentFunction = nil  // depth-only
                depthDescriptor.vertexDescriptor = depthVD
                depthDescriptor.depthAttachmentPixelFormat = .depth32Float
                depthDescriptor.rasterSampleCount = config.sampleCount

                let state = try VRMPipelineCache.shared.getPipelineState(
                    device: device,
                    descriptor: depthDescriptor,
                    key: pipelineKey("mtoon_depth_prepass")
                )
                depthPrepassPipelineState = state
                vrmLog("[VRMRenderer] Created depth-prepass pipeline successfully")
            }

            // Note: Depth stencil states are created in setupCachedStates()
            // Note: Uniforms buffers are created in setupTripleBuffering()
            // Validate uniform size in strict mode
            let uniformSize = MemoryLayout<Uniforms>.size
            if config.strict != .off {
                try strictValidator?.validateUniformSize(swift: uniformSize, metal: MetalSizeConstants.uniformsSize, type: "Uniforms")
                // Validate all uniform buffers
                for buffer in uniformsBuffers {
                    try strictValidator?.validateUniformBuffer(buffer, requiredSize: uniformSize)
                }
            }

        } catch {
            vrmLogError(
                "[VRMRenderer] MToon pipeline setup failed — this renderer will not draw. " +
                "Underlying error: \(error.localizedDescription) " +
                "If the bundled shader library failed to load, rebuild the metallib slices with the release toolchain (`make shaders`). " +
                "See https://github.com/arkavo-org/VRMMetalKit/issues/336"
            )
            if config.strict == .fail {
                // In strict mode, propagate the error through validator
                do {
                    try strictValidator?.handle(.pipelineCreationFailed(error.localizedDescription))
                } catch {
                    vrmLog("❌ [VRMRenderer] StrictMode validation failed: \(error)")
                }
            }
        }
    }

    func setupSkinnedPipeline() {
        do {
            // For now, use the same MToon shader for skinned meshes
            // TODO: Create a proper skinned MToon vertex shader
            // Load precompiled shader library (reuses cached library from setupPipeline)
            let library = try VRMPipelineCache.shared.getLibrary(device: device)
            vrmLog("[VRMRenderer] Successfully loaded precompiled shader library")

            // Validate skinned vertex function for MToon
            let skinnedVertexFunction = library.makeFunction(name: "skinned_mtoon_vertex")
            try strictValidator?.validateFunction(skinnedVertexFunction, name: "skinned_mtoon_vertex", type: "vertex")
            guard let skinnedVertexFunc = skinnedVertexFunction else {
                vrmLog("[VRMRenderer] ❌ CRITICAL: Failed to find skinned_mtoon_vertex function - skinned models will not render correctly!")
                vrmLog("[VRMRenderer] This will cause golden/corrupted rendering for skinned meshes")
                if config.strict == .off {
                    return
                }
                throw StrictModeError.missingVertexFunction(name: "skinned_mtoon_vertex")
            }

            // Use MToon fragment shader for proper rendering (reuse library from above).
            // Build with fallback function constants so the dynamic path continues to
            // read feature flags from the uniform buffer.
            let fragmentFunction = try? library.makeFunction(
                name: "mtoon_fragment_v2",
                constantValues: MToonFunctionConstantKey.fallback.makeFunctionConstantValues()
            )
            try strictValidator?.validateFunction(fragmentFunction, name: "mtoon_fragment_v2", type: "fragment")
            guard let fragmentFunc = fragmentFunction else {
                if config.strict == .off {
                    vrmLog("[VRMRenderer] Failed to find mtoon_fragment_v2 for skinned pipeline")
                    return
                }
                throw StrictModeError.missingFragmentFunction(name: "mtoon_fragment_v2")
            }

            let vertexDescriptor = MTLVertexDescriptor()

            // 🎯 CRITICAL FIX: Use compiler-accurate offsets instead of manual calculations
            let posOffset = MemoryLayout<VRMVertex>.offset(of: \.position)!
            let normOffset = MemoryLayout<VRMVertex>.offset(of: \.normal)!
            let texOffset = MemoryLayout<VRMVertex>.offset(of: \.texCoord)!
            let colorOffset = MemoryLayout<VRMVertex>.offset(of: \.color)!
            let jointsOffset = MemoryLayout<VRMVertex>.offset(of: \.joints)!
            let weightsOffset = MemoryLayout<VRMVertex>.offset(of: \.weights)!
            let stride = MemoryLayout<VRMVertex>.stride

            // 📐 DIAGNOSTIC: Log actual offsets for debugging wedge artifact
            vrmLog("📐 [VERTEX LAYOUT] MToon Skinned Pipeline:")
            vrmLog("   position: \(posOffset), normal: \(normOffset), texCoord: \(texOffset)")
            vrmLog("   color: \(colorOffset), joints: \(jointsOffset), weights: \(weightsOffset)")
            vrmLog("   stride: \(stride)")

            // Position
            vertexDescriptor.attributes[0].format = .float3
            vertexDescriptor.attributes[0].offset = posOffset
            vertexDescriptor.attributes[0].bufferIndex = 0

            // Normal
            vertexDescriptor.attributes[1].format = .float3
            vertexDescriptor.attributes[1].offset = normOffset
            vertexDescriptor.attributes[1].bufferIndex = 0

            // TexCoord
            vertexDescriptor.attributes[2].format = .float2
            vertexDescriptor.attributes[2].offset = texOffset
            vertexDescriptor.attributes[2].bufferIndex = 0

            // Color
            vertexDescriptor.attributes[3].format = .float4
            vertexDescriptor.attributes[3].offset = colorOffset
            vertexDescriptor.attributes[3].bufferIndex = 0

            // Joints
            vertexDescriptor.attributes[4].format = .uint4
            vertexDescriptor.attributes[4].offset = jointsOffset
            vertexDescriptor.attributes[4].bufferIndex = 0

            // Weights
            vertexDescriptor.attributes[5].format = .float4
            vertexDescriptor.attributes[5].offset = weightsOffset
            vertexDescriptor.attributes[5].bufferIndex = 0

            vertexDescriptor.layouts[0].stride = stride

            // Create base skinned pipeline descriptor
            let basePipelineDescriptor = MTLRenderPipelineDescriptor()
            basePipelineDescriptor.vertexFunction = skinnedVertexFunc  // Use skinned vertex shader
            basePipelineDescriptor.fragmentFunction = fragmentFunc
            basePipelineDescriptor.vertexDescriptor = vertexDescriptor
            basePipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
            basePipelineDescriptor.rasterSampleCount = config.sampleCount

            // Create SKINNED OPAQUE/MASK pipeline (no blending)
            let skinnedOpaqueDescriptor = basePipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            skinnedOpaqueDescriptor.label = "mtoon_skinned_opaque"  // Add label for debugging
            let skinnedOpaqueColorAttachment = skinnedOpaqueDescriptor.colorAttachments[0]
            skinnedOpaqueColorAttachment?.pixelFormat = config.colorPixelFormat
            skinnedOpaqueColorAttachment?.isBlendingEnabled = false

            let skinnedOpaqueState = try VRMPipelineCache.shared.getPipelineState(
                device: device,
                descriptor: skinnedOpaqueDescriptor,
                key: pipelineKey("mtoon_skinned_opaque")
            )
            try strictValidator?.validatePipelineState(skinnedOpaqueState, name: "skinned_opaque_pipeline")
            skinnedOpaquePipelineState = skinnedOpaqueState
            vrmLog("[SKINNED PSO] Created skinned opaque pipeline successfully")

            // Create SKINNED BLEND pipeline (blending enabled)
            let skinnedBlendDescriptor = basePipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            skinnedBlendDescriptor.label = "mtoon_skinned_blend"  // Add label for debugging
            let skinnedBlendColorAttachment = skinnedBlendDescriptor.colorAttachments[0]
            skinnedBlendColorAttachment?.pixelFormat = config.colorPixelFormat
            skinnedBlendColorAttachment?.isBlendingEnabled = true
            skinnedBlendColorAttachment?.sourceRGBBlendFactor = .sourceAlpha
            skinnedBlendColorAttachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
            skinnedBlendColorAttachment?.rgbBlendOperation = .add
            // See comment on the non-skinned BLEND pipeline above.
            skinnedBlendColorAttachment?.sourceAlphaBlendFactor = .one
            skinnedBlendColorAttachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            skinnedBlendColorAttachment?.alphaBlendOperation = .add

            let skinnedBlendState = try VRMPipelineCache.shared.getPipelineState(
                device: device,
                descriptor: skinnedBlendDescriptor,
                key: pipelineKey("mtoon_skinned_blend")
            )
            try strictValidator?.validatePipelineState(skinnedBlendState, name: "skinned_blend_pipeline")
            skinnedBlendPipelineState = skinnedBlendState
            vrmLog("[SKINNED PSO] Created skinned blend pipeline successfully")
            
            // Create SKINNED MASK with Alpha-to-Coverage pipeline
            let skinnedMaskA2CDescriptor = basePipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            skinnedMaskA2CDescriptor.label = "mtoon_skinned_mask_a2c"
            skinnedMaskA2CDescriptor.isAlphaToCoverageEnabled = true
            let skinnedMaskA2CColorAttachment = skinnedMaskA2CDescriptor.colorAttachments[0]
            skinnedMaskA2CColorAttachment?.pixelFormat = config.colorPixelFormat
            skinnedMaskA2CColorAttachment?.isBlendingEnabled = false
            
            let skinnedMaskA2CState = try VRMPipelineCache.shared.getPipelineState(
                device: device,
                descriptor: skinnedMaskA2CDescriptor,
                key: pipelineKey("mtoon_skinned_mask_a2c")
            )
            try strictValidator?.validatePipelineState(skinnedMaskA2CState, name: "skinned_mask_a2c_pipeline")
            skinnedMaskAlphaToCoveragePipelineState = skinnedMaskA2CState
            vrmLog("[SKINNED PSO] Created skinned MASK alpha-to-coverage pipeline")

            // Create SKINNED MToon OUTLINE pipeline (inverted hull technique).
            // Use function-constant fallback so the outline vertex shader keeps
            // reading feature flags from the uniform buffer.
            let skinnedOutlineVertexFunction = try? library.makeFunction(
                name: "skinned_mtoon_outline_vertex",
                constantValues: MToonFunctionConstantKey.fallback.makeFunctionConstantValues()
            )
            let skinnedOutlineFragmentFunction = library.makeFunction(name: "mtoon_outline_fragment")
            if let skinnedOutlineVertexFunc = skinnedOutlineVertexFunction,
               let skinnedOutlineFragmentFunc = skinnedOutlineFragmentFunction {
                let skinnedOutlineDescriptor = MTLRenderPipelineDescriptor()
                skinnedOutlineDescriptor.label = "mtoon_skinned_outline"
                skinnedOutlineDescriptor.vertexFunction = skinnedOutlineVertexFunc
                skinnedOutlineDescriptor.fragmentFunction = skinnedOutlineFragmentFunc
                skinnedOutlineDescriptor.vertexDescriptor = vertexDescriptor
                skinnedOutlineDescriptor.depthAttachmentPixelFormat = .depth32Float
                skinnedOutlineDescriptor.rasterSampleCount = config.sampleCount

                let skinnedOutlineColorAttachment = skinnedOutlineDescriptor.colorAttachments[0]
                skinnedOutlineColorAttachment?.pixelFormat = config.colorPixelFormat
                skinnedOutlineColorAttachment?.isBlendingEnabled = false

                let skinnedOutlineState = try VRMPipelineCache.shared.getPipelineState(
                    device: device,
                    descriptor: skinnedOutlineDescriptor,
                    key: pipelineKey("mtoon_skinned_outline")
                )
                mtoonSkinnedOutlinePipelineState = skinnedOutlineState
                vrmLog("[SKINNED PSO] Created skinned MToon outline pipeline successfully")
            } else {
                vrmLog("[SKINNED PSO] Skinned MToon outline shaders not found - outlines will be disabled for skinned meshes")
            }

            // Skinned depth-prepass pipeline: position + joints + weights only
            // (drops normal/uv/color), no fragment, depth attachment only.
            if let depthVertexFunc = library.makeFunction(name: "skinned_mtoon_depth_vertex") {
                let depthVD = MTLVertexDescriptor()
                depthVD.attributes[0].format = .float3
                depthVD.attributes[0].offset = posOffset
                depthVD.attributes[0].bufferIndex = 0
                depthVD.attributes[4].format = .uint4
                depthVD.attributes[4].offset = jointsOffset
                depthVD.attributes[4].bufferIndex = 0
                depthVD.attributes[5].format = .float4
                depthVD.attributes[5].offset = weightsOffset
                depthVD.attributes[5].bufferIndex = 0
                depthVD.layouts[0].stride = stride

                let depthDescriptor = MTLRenderPipelineDescriptor()
                depthDescriptor.label = "mtoon_skinned_depth_prepass"
                depthDescriptor.vertexFunction = depthVertexFunc
                depthDescriptor.fragmentFunction = nil  // depth-only
                depthDescriptor.vertexDescriptor = depthVD
                depthDescriptor.depthAttachmentPixelFormat = .depth32Float
                depthDescriptor.rasterSampleCount = config.sampleCount

                let state = try VRMPipelineCache.shared.getPipelineState(
                    device: device,
                    descriptor: depthDescriptor,
                    key: pipelineKey("mtoon_skinned_depth_prepass")
                )
                skinnedDepthPrepassPipelineState = state
                vrmLog("[SKINNED PSO] Created skinned depth-prepass pipeline successfully")
            }
        } catch {
            vrmLogError(
                "[VRMRenderer] Skinned MToon pipeline setup failed — skinned meshes will not draw. " +
                "Underlying error: \(error.localizedDescription) " +
                "If the bundled shader library failed to load, rebuild the metallib slices with the release toolchain (`make shaders`). " +
                "See https://github.com/arkavo-org/VRMMetalKit/issues/336"
            )
            if config.strict == .fail {
                // In strict mode, propagate the error through validator
                do {
                    try strictValidator?.handle(.pipelineCreationFailed(error.localizedDescription))
                } catch {
                    vrmLog("❌ [VRMRenderer] StrictMode validation failed: \(error)")
                }
            }
        }
    }

    // MARK: - MToon Function-Constant Specialization

    /// Creates a fresh MToon pipeline descriptor specialized for the given
    /// material feature flags. The vertex function is shared with the fallback
    /// pipeline; only the fragment function is specialized via Metal function
    /// constants.
    func makeMToonSpecializedDescriptor(
        library: MTLLibrary,
        isSkinned: Bool,
        features: MToonFunctionConstantKey
    ) throws -> MTLRenderPipelineDescriptor {
        let vertexDescriptor = MTLVertexDescriptor()

        // Position
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = MemoryLayout<VRMVertex>.offset(of: \.position)!
        vertexDescriptor.attributes[0].bufferIndex = 0

        // Normal
        vertexDescriptor.attributes[1].format = .float3
        vertexDescriptor.attributes[1].offset = MemoryLayout<VRMVertex>.offset(of: \.normal)!
        vertexDescriptor.attributes[1].bufferIndex = 0

        // TexCoord
        vertexDescriptor.attributes[2].format = .float2
        vertexDescriptor.attributes[2].offset = MemoryLayout<VRMVertex>.offset(of: \.texCoord)!
        vertexDescriptor.attributes[2].bufferIndex = 0

        // Color
        vertexDescriptor.attributes[3].format = .float4
        vertexDescriptor.attributes[3].offset = MemoryLayout<VRMVertex>.offset(of: \.color)!
        vertexDescriptor.attributes[3].bufferIndex = 0

        if isSkinned {
            // Joints
            vertexDescriptor.attributes[4].format = .uint4
            vertexDescriptor.attributes[4].offset = MemoryLayout<VRMVertex>.offset(of: \.joints)!
            vertexDescriptor.attributes[4].bufferIndex = 0

            // Weights
            vertexDescriptor.attributes[5].format = .float4
            vertexDescriptor.attributes[5].offset = MemoryLayout<VRMVertex>.offset(of: \.weights)!
            vertexDescriptor.attributes[5].bufferIndex = 0
        }

        vertexDescriptor.layouts[0].stride = MemoryLayout<VRMVertex>.stride

        let vertexFunctionName = isSkinned ? "skinned_mtoon_vertex" : "mtoon_vertex"
        guard let vertexFunction = library.makeFunction(name: vertexFunctionName) else {
            throw StrictModeError.missingVertexFunction(name: vertexFunctionName)
        }

        guard let fragmentFunction = try? library.makeFunction(
            name: "mtoon_fragment_v2",
            constantValues: features.makeFunctionConstantValues()
        ) else {
            throw StrictModeError.missingFragmentFunction(name: "mtoon_fragment_v2")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "mtoon_\(isSkinned ? "skinned" : "non_skinned")_fc_\(features.alphaMode)"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.depthAttachmentPixelFormat = .depth32Float
        descriptor.rasterSampleCount = config.sampleCount

        let colorAttachment = descriptor.colorAttachments[0]
        colorAttachment?.pixelFormat = config.colorPixelFormat

        switch features.alphaMode {
        case 2: // BLEND
            colorAttachment?.isBlendingEnabled = true
            colorAttachment?.sourceRGBBlendFactor = .sourceAlpha
            colorAttachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
            colorAttachment?.rgbBlendOperation = .add
            colorAttachment?.sourceAlphaBlendFactor = .one
            colorAttachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            colorAttachment?.alphaBlendOperation = .add
        default: // OPAQUE / MASK
            colorAttachment?.isBlendingEnabled = false
        }

        return descriptor
    }

    /// Returns a cached or freshly built MToon pipeline specialized for the
    /// given material feature flags. Falls back to `nil` if specialization
    /// fails, so callers can use the dynamic fallback pipeline.
    func specializedMToonPipelineState(
        isSkinned: Bool,
        features: MToonFunctionConstantKey
    ) -> MTLRenderPipelineState? {
        // Build a compact integer bitfield key instead of multiple string interpolations
        // Bit layout: [skinned:1][bc:1][sm:1][ss:1][nm:1][mc:1][rm:1][em:1][oc:1][uv:1][alpha:4]
        var bits: UInt32 = isSkinned ? 1 : 0
        bits = (bits << 1) | (features.hasBaseColorTexture ? 1 : 0)
        bits = (bits << 1) | (features.hasShadeMultiplyTexture ? 1 : 0)
        bits = (bits << 1) | (features.hasShadingShiftTexture ? 1 : 0)
        bits = (bits << 1) | (features.hasNormalTexture ? 1 : 0)
        bits = (bits << 1) | (features.hasMatcapTexture ? 1 : 0)
        bits = (bits << 1) | (features.hasRimMultiplyTexture ? 1 : 0)
        bits = (bits << 1) | (features.hasEmissiveTexture ? 1 : 0)
        bits = (bits << 1) | (features.hasOcclusionTexture ? 1 : 0)
        bits = (bits << 1) | (features.hasUvAnimationMaskTexture ? 1 : 0)
        bits = (bits << 4) | (UInt32(features.alphaMode) & 0xF)
        let key = "mtfc_\(bits)_\(config.colorPixelFormat.rawValue)_\(config.sampleCount)"

        do {
            let library = try VRMPipelineCache.shared.getLibrary(device: device)
            let descriptor = try makeMToonSpecializedDescriptor(
                library: library,
                isSkinned: isSkinned,
                features: features
            )
            return try VRMPipelineCache.shared.getPipelineState(
                device: device,
                descriptor: descriptor,
                key: key
            )
        } catch {
            vrmLog("[VRMRenderer] Failed to create specialized MToon pipeline, falling back: \(error)")
            return nil
        }
    }


    // MARK: - Sprite Rendering Pipeline Setup

    func setupSpritePipeline() {
        do {
            // Create shader library
            let library = try VRMPipelineCache.shared.getLibrary(device: device)

            guard let vertexFunction = library.makeFunction(name: "sprite_vertex"),
                  let fragmentFunction = library.makeFunction(name: "sprite_fragment") else {
                vrmLog("[VRMRenderer] Failed to load sprite shader functions")
                return
            }

            // Create vertex descriptor
            let vertexDescriptor = MTLVertexDescriptor()

            // Position (attribute 0)
            vertexDescriptor.attributes[0].format = .float2
            vertexDescriptor.attributes[0].offset = 0
            vertexDescriptor.attributes[0].bufferIndex = 0

            // TexCoord (attribute 1)
            vertexDescriptor.attributes[1].format = .float2
            vertexDescriptor.attributes[1].offset = MemoryLayout<Float>.stride * 2
            vertexDescriptor.attributes[1].bufferIndex = 0

            // Layout
            vertexDescriptor.layouts[0].stride = MemoryLayout<Float>.stride * 4  // 2 floats position + 2 floats texCoord
            vertexDescriptor.layouts[0].stepRate = 1
            vertexDescriptor.layouts[0].stepFunction = .perVertex

            // Create pipeline descriptor
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.label = "Sprite Pipeline"
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.vertexDescriptor = vertexDescriptor
            pipelineDescriptor.rasterSampleCount = config.sampleCount

            // Color attachment (BGRA8)
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
            pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add

            // Depth attachment
            pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

            // Create pipeline state
            spritePipelineState = try VRMPipelineCache.shared.getPipelineState(
                device: device,
                descriptor: pipelineDescriptor,
                key: pipelineKey("sprite")
            )
            vrmLog("[VRMRenderer] Created sprite pipeline successfully")

            // Create sprite quad buffers
            if let buffers = SpriteQuadMesh.createBuffers(device: device) {
                spriteVertexBuffer = buffers.vertexBuffer
                spriteIndexBuffer = buffers.indexBuffer
                vrmLog("[VRMRenderer] Created sprite quad buffers")
            } else {
                vrmLog("[VRMRenderer] Failed to create sprite quad buffers")
            }

        } catch {
            vrmLogError(
                "[VRMRenderer] Sprite pipeline setup failed — sprite rendering is disabled. " +
                "Underlying error: \(error.localizedDescription)"
            )
            if config.strict == .fail {
                // In strict mode, propagate the error through validator
                do {
                    try strictValidator?.handle(.pipelineCreationFailed(error.localizedDescription))
                } catch {
                    vrmLog("❌ [VRMRenderer] StrictMode validation failed: \(error)")
                }
            }
        }
    }
}