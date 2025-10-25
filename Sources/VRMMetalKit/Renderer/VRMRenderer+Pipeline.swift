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
    func validateMaterialUniformAlignment() {
        // Calculate Swift struct size and stride
        let swiftSize = MemoryLayout<MToonMaterialUniforms>.size
        let swiftStride = MemoryLayout<MToonMaterialUniforms>.stride

        // Expected Metal struct size (11 blocks * 16 bytes = 176 bytes)
        // The Metal struct is laid out as:
        // - Block 0: baseColorFactor (16 bytes)
        // - Block 1: shadeColorFactor + shadingToonyFactor (16 bytes)
        // - Block 2: shadingShiftFactor + emissiveFactor (16 bytes)
        // - Block 3: metallicFactor + roughnessFactor + giIntensityFactor + shadingShiftTextureScale (16 bytes)
        // - Block 4: matcapFactor + hasMatcapTexture (16 bytes)
        // - Block 5: parametricRimColorFactor + parametricRimFresnelPowerFactor (16 bytes)
        // - Block 6: parametricRimLiftFactor + rimLightingMixFactor + hasRimMultiplyTexture + padding (16 bytes)
        // - Block 7: outlineWidthFactor + outlineColorFactor (16 bytes)
        // - Block 8: outlineLightingMixFactor + outlineMode + hasOutlineWidthMultiplyTexture + padding (16 bytes)
        // - Block 9: uvAnimation (4 floats) (16 bytes)
        // - Block 10: texture flags (4 int32s) (16 bytes)
        // - Block 11: more flags + alphaMode + alphaCutoff (16 bytes)
        let expectedMetalSize = 176  // 11 * 16

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
                    fatalError("[StrictMode] \(message)")
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
            // Create library from MToon shader source
            let library = try device.makeLibrary(source: MToonShader.shaderSource, options: nil)

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

            // Validate fragment function
            vrmLog("[SHADER DEBUG] Looking for fragment function: mtoon_fragment_v2")
            let fragmentFunction = library.makeFunction(name: "mtoon_fragment_v2")
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

            // Position
            vertexDescriptor.attributes[0].format = .float3
            vertexDescriptor.attributes[0].offset = 0
            vertexDescriptor.attributes[0].bufferIndex = 0

            // Normal
            vertexDescriptor.attributes[1].format = .float3
            vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.size
            vertexDescriptor.attributes[1].bufferIndex = 0

            // TexCoord
            vertexDescriptor.attributes[2].format = .float2
            vertexDescriptor.attributes[2].offset = MemoryLayout<SIMD3<Float>>.size * 2
            vertexDescriptor.attributes[2].bufferIndex = 0

            // Color
            vertexDescriptor.attributes[3].format = .float4
            vertexDescriptor.attributes[3].offset = MemoryLayout<SIMD3<Float>>.size * 2 + MemoryLayout<SIMD2<Float>>.size
            vertexDescriptor.attributes[3].bufferIndex = 0

            vertexDescriptor.layouts[0].stride = MemoryLayout<VRMVertex>.stride

            // Create base pipeline descriptor
            let basePipelineDescriptor = MTLRenderPipelineDescriptor()
            basePipelineDescriptor.vertexFunction = vertexFunc
            basePipelineDescriptor.fragmentFunction = fragmentFunc
            basePipelineDescriptor.vertexDescriptor = vertexDescriptor
            basePipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

            // Create OPAQUE/MASK pipeline (no blending)
            let opaqueDescriptor = basePipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            opaqueDescriptor.label = "mtoon_opaque"  // Add label for debugging
            let opaqueColorAttachment = opaqueDescriptor.colorAttachments[0]
            opaqueColorAttachment?.pixelFormat = .bgra8Unorm_srgb
            opaqueColorAttachment?.isBlendingEnabled = false

            let opaqueState = try device.makeRenderPipelineState(descriptor: opaqueDescriptor)
            try strictValidator?.validatePipelineState(opaqueState, name: "mtoon_opaque_pipeline")
            opaquePipelineState = opaqueState

            // Create BLEND pipeline (blending enabled)
            let blendDescriptor = basePipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            blendDescriptor.label = "mtoon_blend"  // Add label for debugging
            let blendColorAttachment = blendDescriptor.colorAttachments[0]
            blendColorAttachment?.pixelFormat = .bgra8Unorm_srgb
            blendColorAttachment?.isBlendingEnabled = true
            blendColorAttachment?.sourceRGBBlendFactor = .sourceAlpha
            blendColorAttachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
            blendColorAttachment?.rgbBlendOperation = .add
            blendColorAttachment?.sourceAlphaBlendFactor = .sourceAlpha
            blendColorAttachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            blendColorAttachment?.alphaBlendOperation = .add

            let blendState = try device.makeRenderPipelineState(descriptor: blendDescriptor)
            try strictValidator?.validatePipelineState(blendState, name: "mtoon_blend_pipeline")
            blendPipelineState = blendState

            // Create WIREFRAME pipeline (for debugging)
            let wireframeDescriptor = basePipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            wireframeDescriptor.label = "mtoon_wireframe"  // Add label for debugging
            let wireframeColorAttachment = wireframeDescriptor.colorAttachments[0]
            wireframeColorAttachment?.pixelFormat = .bgra8Unorm_srgb
            wireframeColorAttachment?.isBlendingEnabled = false

            let wireframeState = try device.makeRenderPipelineState(descriptor: wireframeDescriptor)
            try strictValidator?.validatePipelineState(wireframeState, name: "mtoon_wireframe_pipeline")
            wireframePipelineState = wireframeState

            // Create depth state
            let depthDescriptor = MTLDepthStencilDescriptor()
            depthDescriptor.depthCompareFunction = .less
            depthDescriptor.isDepthWriteEnabled = true
            depthState = device.makeDepthStencilState(descriptor: depthDescriptor)

            if config.strict != .off && depthState == nil {
                throw StrictModeError.depthStencilCreationFailed
            }

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
            if config.strict == .fail {
                fatalError("Failed to setup pipeline: \(error)")
            } else {
                vrmLog("Failed to setup pipeline: \(error)")
            }
        }
    }

    func setupSkinnedPipeline() {
        do {
            // For now, use the same MToon shader for skinned meshes
            // TODO: Create a proper skinned MToon vertex shader
            let library: MTLLibrary
            do {
                library = try device.makeLibrary(source: MToonSkinnedShader.source, options: nil)
                vrmLog("[VRMRenderer] Successfully compiled MToonSkinnedShader")
            } catch {
                vrmLog("[VRMRenderer] ❌ Failed to compile MToonSkinnedShader: \(error)")
                throw error
            }

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

            // Use MToon fragment shader for proper rendering
            let mtoonLibrary = try device.makeLibrary(source: MToonShader.shaderSource, options: nil)
            let fragmentFunction = mtoonLibrary.makeFunction(name: "mtoon_fragment_v2")
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

            // Joints
            vertexDescriptor.attributes[4].format = .ushort4
            vertexDescriptor.attributes[4].offset = MemoryLayout<VRMVertex>.offset(of: \.joints)!
            vertexDescriptor.attributes[4].bufferIndex = 0

            // Weights
            vertexDescriptor.attributes[5].format = .float4
            vertexDescriptor.attributes[5].offset = MemoryLayout<VRMVertex>.offset(of: \.weights)!
            vertexDescriptor.attributes[5].bufferIndex = 0

            vertexDescriptor.layouts[0].stride = MemoryLayout<VRMVertex>.stride

            // Create base skinned pipeline descriptor
            let basePipelineDescriptor = MTLRenderPipelineDescriptor()
            basePipelineDescriptor.vertexFunction = skinnedVertexFunc  // Use skinned vertex shader
            basePipelineDescriptor.fragmentFunction = fragmentFunc
            basePipelineDescriptor.vertexDescriptor = vertexDescriptor
            basePipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

            // Create SKINNED OPAQUE/MASK pipeline (no blending)
            let skinnedOpaqueDescriptor = basePipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            skinnedOpaqueDescriptor.label = "mtoon_skinned_opaque"  // Add label for debugging
            let skinnedOpaqueColorAttachment = skinnedOpaqueDescriptor.colorAttachments[0]
            skinnedOpaqueColorAttachment?.pixelFormat = .bgra8Unorm_srgb
            skinnedOpaqueColorAttachment?.isBlendingEnabled = false

            let skinnedOpaqueState = try device.makeRenderPipelineState(descriptor: skinnedOpaqueDescriptor)
            try strictValidator?.validatePipelineState(skinnedOpaqueState, name: "skinned_opaque_pipeline")
            skinnedOpaquePipelineState = skinnedOpaqueState
            vrmLog("[SKINNED PSO] Created skinned opaque pipeline successfully")

            // Create SKINNED BLEND pipeline (blending enabled)
            let skinnedBlendDescriptor = basePipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            skinnedBlendDescriptor.label = "mtoon_skinned_blend"  // Add label for debugging
            let skinnedBlendColorAttachment = skinnedBlendDescriptor.colorAttachments[0]
            skinnedBlendColorAttachment?.pixelFormat = .bgra8Unorm_srgb
            skinnedBlendColorAttachment?.isBlendingEnabled = true
            skinnedBlendColorAttachment?.sourceRGBBlendFactor = .sourceAlpha
            skinnedBlendColorAttachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
            skinnedBlendColorAttachment?.rgbBlendOperation = .add
            skinnedBlendColorAttachment?.sourceAlphaBlendFactor = .sourceAlpha
            skinnedBlendColorAttachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            skinnedBlendColorAttachment?.alphaBlendOperation = .add

            let skinnedBlendState = try device.makeRenderPipelineState(descriptor: skinnedBlendDescriptor)
            try strictValidator?.validatePipelineState(skinnedBlendState, name: "skinned_blend_pipeline")
            skinnedBlendPipelineState = skinnedBlendState
            vrmLog("[SKINNED PSO] Created skinned blend pipeline successfully")
        } catch {
            if config.strict == .fail {
                fatalError("Failed to setup skinned pipeline: \(error)")
            } else {
                vrmLog("Failed to setup skinned pipeline: \(error)")
            }
        }
    }

    // MARK: - Toon2D Pipeline Setup

    func setupToon2DPipeline() {
        print("[VRMRenderer] setupToon2DPipeline() called")
        do {
            // Create library from Toon2D shader source
            let library = try device.makeLibrary(source: Toon2DShader.shaderSource, options: nil)
            print("[VRMRenderer] Successfully compiled Toon2DShader")
            vrmLog("[VRMRenderer] Successfully compiled Toon2DShader")

            // Validate vertex function
            let vertexFunction = library.makeFunction(name: "vertex_main")
            guard let vertexFunc = vertexFunction else {
                vrmLog("[VRMRenderer] Failed to find vertex_main function in Toon2D shader")
                return
            }

            // Validate fragment function
            let fragmentFunction = library.makeFunction(name: "fragment_main")
            guard let fragmentFunc = fragmentFunction else {
                vrmLog("[VRMRenderer] Failed to find fragment_main function in Toon2D shader")
                return
            }

            // Validate outline vertex function
            let outlineVertexFunction = library.makeFunction(name: "outline_vertex")
            guard let outlineVertexFunc = outlineVertexFunction else {
                vrmLog("[VRMRenderer] Failed to find outline_vertex function in Toon2D shader")
                return
            }

            // Validate outline fragment function
            let outlineFragmentFunction = library.makeFunction(name: "outline_fragment")
            guard let outlineFragmentFunc = outlineFragmentFunction else {
                vrmLog("[VRMRenderer] Failed to find outline_fragment function in Toon2D shader")
                return
            }

            // Create vertex descriptor (same as standard pipeline)
            let vertexDescriptor = MTLVertexDescriptor()

            // Position
            vertexDescriptor.attributes[0].format = .float3
            vertexDescriptor.attributes[0].offset = 0
            vertexDescriptor.attributes[0].bufferIndex = 0

            // Normal
            vertexDescriptor.attributes[1].format = .float3
            vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.size
            vertexDescriptor.attributes[1].bufferIndex = 0

            // TexCoord
            vertexDescriptor.attributes[2].format = .float2
            vertexDescriptor.attributes[2].offset = MemoryLayout<SIMD3<Float>>.size * 2
            vertexDescriptor.attributes[2].bufferIndex = 0

            // Color
            vertexDescriptor.attributes[3].format = .float4
            vertexDescriptor.attributes[3].offset = MemoryLayout<SIMD3<Float>>.size * 2 + MemoryLayout<SIMD2<Float>>.size
            vertexDescriptor.attributes[3].bufferIndex = 0

            vertexDescriptor.layouts[0].stride = MemoryLayout<VRMVertex>.stride

            // Create base pipeline descriptor for main rendering
            let basePipelineDescriptor = MTLRenderPipelineDescriptor()
            basePipelineDescriptor.vertexFunction = vertexFunc
            basePipelineDescriptor.fragmentFunction = fragmentFunc
            basePipelineDescriptor.vertexDescriptor = vertexDescriptor
            basePipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

            // Create OPAQUE pipeline for toon2D (no blending)
            let toon2DOpaqueDescriptor = basePipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            toon2DOpaqueDescriptor.label = "toon2D_opaque"
            let toon2DOpaqueColorAttachment = toon2DOpaqueDescriptor.colorAttachments[0]
            toon2DOpaqueColorAttachment?.pixelFormat = .bgra8Unorm_srgb
            toon2DOpaqueColorAttachment?.isBlendingEnabled = false

            let toon2DOpaqueState = try device.makeRenderPipelineState(descriptor: toon2DOpaqueDescriptor)
            toon2DOpaquePipelineState = toon2DOpaqueState
            vrmLog("[VRMRenderer] Created toon2D opaque pipeline successfully")

            // Create BLEND pipeline for toon2D (blending enabled)
            let toon2DBlendDescriptor = basePipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            toon2DBlendDescriptor.label = "toon2D_blend"
            let toon2DBlendColorAttachment = toon2DBlendDescriptor.colorAttachments[0]
            toon2DBlendColorAttachment?.pixelFormat = .bgra8Unorm_srgb
            toon2DBlendColorAttachment?.isBlendingEnabled = true
            toon2DBlendColorAttachment?.sourceRGBBlendFactor = .sourceAlpha
            toon2DBlendColorAttachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
            toon2DBlendColorAttachment?.rgbBlendOperation = .add
            toon2DBlendColorAttachment?.sourceAlphaBlendFactor = .sourceAlpha
            toon2DBlendColorAttachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            toon2DBlendColorAttachment?.alphaBlendOperation = .add

            let toon2DBlendState = try device.makeRenderPipelineState(descriptor: toon2DBlendDescriptor)
            toon2DBlendPipelineState = toon2DBlendState
            vrmLog("[VRMRenderer] Created toon2D blend pipeline successfully")

            // Create OUTLINE pipeline (inverted hull rendering)
            let outlinePipelineDescriptor = MTLRenderPipelineDescriptor()
            outlinePipelineDescriptor.label = "toon2D_outline"
            outlinePipelineDescriptor.vertexFunction = outlineVertexFunc
            outlinePipelineDescriptor.fragmentFunction = outlineFragmentFunc
            outlinePipelineDescriptor.vertexDescriptor = vertexDescriptor
            outlinePipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

            let outlineColorAttachment = outlinePipelineDescriptor.colorAttachments[0]
            outlineColorAttachment?.pixelFormat = .bgra8Unorm_srgb
            outlineColorAttachment?.isBlendingEnabled = false  // Outlines are opaque

            let outlineState = try device.makeRenderPipelineState(descriptor: outlinePipelineDescriptor)
            toon2DOutlinePipelineState = outlineState
            vrmLog("[VRMRenderer] Created toon2D outline pipeline successfully")

        } catch {
            print("[TOON2D ERROR] Failed to setup Toon2D pipeline: \(error)")
            vrmLog("[VRMRenderer] Failed to setup Toon2D pipeline: \(error)")
            if config.strict == .fail {
                fatalError("Failed to setup Toon2D pipeline: \(error)")
            }
        }
    }

    // MARK: - Skinned Toon2D Pipeline Setup

    func setupToon2DSkinnedPipeline() {
        do {
            // Create library from Toon2D skinned shader source
            let library = try device.makeLibrary(source: Toon2DSkinnedShader.shaderSource, options: nil)
            vrmLog("[VRMRenderer] Successfully compiled Toon2DSkinnedShader")

            // Validate skinned vertex function
            let skinnedVertexFunction = library.makeFunction(name: "skinned_toon2d_vertex")
            guard let skinnedVertexFunc = skinnedVertexFunction else {
                vrmLog("[VRMRenderer] Failed to find skinned_toon2d_vertex function")
                return
            }

            // Validate fragment function
            let fragmentFunction = library.makeFunction(name: "skinned_toon2d_fragment")
            guard let fragmentFunc = fragmentFunction else {
                vrmLog("[VRMRenderer] Failed to find skinned_toon2d_fragment function")
                return
            }

            // Validate outline vertex function
            let outlineVertexFunction = library.makeFunction(name: "skinned_toon2d_outline_vertex")
            guard let outlineVertexFunc = outlineVertexFunction else {
                vrmLog("[VRMRenderer] Failed to find skinned_toon2d_outline_vertex function")
                return
            }

            // Validate outline fragment function
            let outlineFragmentFunction = library.makeFunction(name: "skinned_toon2d_outline_fragment")
            guard let outlineFragmentFunc = outlineFragmentFunction else {
                vrmLog("[VRMRenderer] Failed to find skinned_toon2d_outline_fragment function")
                return
            }

            // Create vertex descriptor (with joints and weights)
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

            // Joints
            vertexDescriptor.attributes[4].format = .ushort4
            vertexDescriptor.attributes[4].offset = MemoryLayout<VRMVertex>.offset(of: \.joints)!
            vertexDescriptor.attributes[4].bufferIndex = 0

            // Weights
            vertexDescriptor.attributes[5].format = .float4
            vertexDescriptor.attributes[5].offset = MemoryLayout<VRMVertex>.offset(of: \.weights)!
            vertexDescriptor.attributes[5].bufferIndex = 0

            vertexDescriptor.layouts[0].stride = MemoryLayout<VRMVertex>.stride

            // Create base pipeline descriptor for skinned main rendering
            let basePipelineDescriptor = MTLRenderPipelineDescriptor()
            basePipelineDescriptor.vertexFunction = skinnedVertexFunc
            basePipelineDescriptor.fragmentFunction = fragmentFunc
            basePipelineDescriptor.vertexDescriptor = vertexDescriptor
            basePipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

            // Create OPAQUE pipeline for skinned toon2D
            let toon2DSkinnedOpaqueDescriptor = basePipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            toon2DSkinnedOpaqueDescriptor.label = "toon2D_skinned_opaque"
            let toon2DSkinnedOpaqueColorAttachment = toon2DSkinnedOpaqueDescriptor.colorAttachments[0]
            toon2DSkinnedOpaqueColorAttachment?.pixelFormat = .bgra8Unorm_srgb
            toon2DSkinnedOpaqueColorAttachment?.isBlendingEnabled = false

            let toon2DSkinnedOpaqueState = try device.makeRenderPipelineState(descriptor: toon2DSkinnedOpaqueDescriptor)
            toon2DSkinnedOpaquePipelineState = toon2DSkinnedOpaqueState
            vrmLog("[VRMRenderer] Created toon2D skinned opaque pipeline successfully")

            // Create BLEND pipeline for skinned toon2D
            let toon2DSkinnedBlendDescriptor = basePipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            toon2DSkinnedBlendDescriptor.label = "toon2D_skinned_blend"
            let toon2DSkinnedBlendColorAttachment = toon2DSkinnedBlendDescriptor.colorAttachments[0]
            toon2DSkinnedBlendColorAttachment?.pixelFormat = .bgra8Unorm_srgb
            toon2DSkinnedBlendColorAttachment?.isBlendingEnabled = true
            toon2DSkinnedBlendColorAttachment?.sourceRGBBlendFactor = .sourceAlpha
            toon2DSkinnedBlendColorAttachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
            toon2DSkinnedBlendColorAttachment?.rgbBlendOperation = .add
            toon2DSkinnedBlendColorAttachment?.sourceAlphaBlendFactor = .sourceAlpha
            toon2DSkinnedBlendColorAttachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            toon2DSkinnedBlendColorAttachment?.alphaBlendOperation = .add

            let toon2DSkinnedBlendState = try device.makeRenderPipelineState(descriptor: toon2DSkinnedBlendDescriptor)
            toon2DSkinnedBlendPipelineState = toon2DSkinnedBlendState
            vrmLog("[VRMRenderer] Created toon2D skinned blend pipeline successfully")

            // Create OUTLINE pipeline for skinned toon2D
            let outlinePipelineDescriptor = MTLRenderPipelineDescriptor()
            outlinePipelineDescriptor.label = "toon2D_skinned_outline"
            outlinePipelineDescriptor.vertexFunction = outlineVertexFunc
            outlinePipelineDescriptor.fragmentFunction = outlineFragmentFunc
            outlinePipelineDescriptor.vertexDescriptor = vertexDescriptor
            outlinePipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

            let outlineColorAttachment = outlinePipelineDescriptor.colorAttachments[0]
            outlineColorAttachment?.pixelFormat = .bgra8Unorm_srgb
            outlineColorAttachment?.isBlendingEnabled = false

            let outlineState = try device.makeRenderPipelineState(descriptor: outlinePipelineDescriptor)
            toon2DSkinnedOutlinePipelineState = outlineState
            vrmLog("[VRMRenderer] Created toon2D skinned outline pipeline successfully")

        } catch {
            print("[TOON2D ERROR] Failed to setup Toon2D skinned pipeline: \(error)")
            vrmLog("[VRMRenderer] Failed to setup Toon2D skinned pipeline: \(error)")
            if config.strict == .fail {
                fatalError("Failed to setup Toon2D skinned pipeline: \(error)")
            }
        }
    }

    // MARK: - Sprite Rendering Pipeline Setup

    func setupSpritePipeline() {
        do {
            // Create shader library
            let library = try device.makeLibrary(source: SpriteShader.shaderSource, options: nil)

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
            spritePipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
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
            vrmLog("[VRMRenderer] Failed to setup sprite pipeline: \(error)")
            if config.strict == .fail {
                fatalError("Failed to setup sprite pipeline: \(error)")
            }
        }
    }
}