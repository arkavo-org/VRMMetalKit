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
                key: "mtoon_opaque"
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
            blendColorAttachment?.sourceAlphaBlendFactor = .sourceAlpha
            blendColorAttachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            blendColorAttachment?.alphaBlendOperation = .add

            // Use cached pipeline state for better performance
            let blendState = try VRMPipelineCache.shared.getPipelineState(
                device: device,
                descriptor: blendDescriptor,
                key: "mtoon_blend"
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
                key: "mtoon_wireframe"
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
                key: "mtoon_mask_a2c"
            )
            try strictValidator?.validatePipelineState(maskA2CState, name: "mtoon_mask_a2c_pipeline")
            maskAlphaToCoveragePipelineState = maskA2CState
            vrmLog("[VRMRenderer] Created MASK alpha-to-coverage pipeline")

            // Create MToon OUTLINE pipeline (inverted hull technique)
            let outlineVertexFunction = library.makeFunction(name: "mtoon_outline_vertex")
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
                    key: "mtoon_outline"
                )
                mtoonOutlinePipelineState = outlineState
                vrmLog("[VRMRenderer] Created MToon outline pipeline successfully")
            } else {
                vrmLog("[VRMRenderer] MToon outline shaders not found - outlines will be disabled")
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
            if config.strict == .fail {
                vrmLog("❌ [VRMRenderer] Failed to setup pipeline: \(error)")
                // In strict mode, propagate the error through validator
                do {
                    try strictValidator?.handle(.pipelineCreationFailed(error.localizedDescription))
                } catch {
                    vrmLog("❌ [VRMRenderer] StrictMode validation failed: \(error)")
                }
            } else {
                vrmLog("Failed to setup pipeline: \(error)")
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

            // Use MToon fragment shader for proper rendering (reuse library from above)
            let fragmentFunction = library.makeFunction(name: "mtoon_fragment_v2")
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
                key: "mtoon_skinned_opaque"
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
            skinnedBlendColorAttachment?.sourceAlphaBlendFactor = .sourceAlpha
            skinnedBlendColorAttachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            skinnedBlendColorAttachment?.alphaBlendOperation = .add

            let skinnedBlendState = try VRMPipelineCache.shared.getPipelineState(
                device: device,
                descriptor: skinnedBlendDescriptor,
                key: "mtoon_skinned_blend"
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
                key: "mtoon_skinned_mask_a2c"
            )
            try strictValidator?.validatePipelineState(skinnedMaskA2CState, name: "skinned_mask_a2c_pipeline")
            skinnedMaskAlphaToCoveragePipelineState = skinnedMaskA2CState
            vrmLog("[SKINNED PSO] Created skinned MASK alpha-to-coverage pipeline")

            // Create SKINNED MToon OUTLINE pipeline (inverted hull technique)
            let skinnedOutlineVertexFunction = library.makeFunction(name: "skinned_mtoon_outline_vertex")
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
                    key: "mtoon_skinned_outline"
                )
                mtoonSkinnedOutlinePipelineState = skinnedOutlineState
                vrmLog("[SKINNED PSO] Created skinned MToon outline pipeline successfully")
            } else {
                vrmLog("[SKINNED PSO] Skinned MToon outline shaders not found - outlines will be disabled for skinned meshes")
            }
        } catch {
            if config.strict == .fail {
                vrmLog("❌ [VRMRenderer] Failed to setup skinned pipeline: \(error)")
                // In strict mode, propagate the error through validator
                do {
                    try strictValidator?.handle(.pipelineCreationFailed(error.localizedDescription))
                } catch {
                    vrmLog("❌ [VRMRenderer] StrictMode validation failed: \(error)")
                }
            } else {
                vrmLog("Failed to setup skinned pipeline: \(error)")
            }
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
                key: "sprite"
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
            vrmLog("[VRMRenderer] Failed to setup sprite pipeline: \(error)")
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