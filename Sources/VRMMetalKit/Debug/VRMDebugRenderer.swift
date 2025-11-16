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


import Metal
import MetalKit
import Foundation

/// Debug renderer for systematic pipeline testing
public class VRMDebugRenderer {

    public enum DebugPhase: String, CaseIterable {
        case unlitSolid = "unlit_solid"      // Phase 1: Solid color
        case clipSpace = "clip_space"        // Phase 1b: Clip-space position as color
        case depthViz = "depth_viz"          // Phase 2: Depth visualization
        case textureOnly = "texture_only"    // Phase 3: Texture sampling only
        case alphaProbe = "alpha_probe"      // Phase 3b: Alpha channel visualization
        case jointsProbe = "joints_probe"    // Phase 3c: Joint indices visualization
        case weightsProbe = "weights_probe"  // Phase 3d: Weights visualization
        case skinnedIdentity = "skinned_id"  // Phase 4: Skinning with identity
        case skinnedReal = "skinned_real"    // Phase 5: Real skinning
        case fullMaterial = "full_material"  // Phase 6: Full MToon
    }

    private let device: MTLDevice

    // Debug pipeline states
    private var unlitPipelineState: MTLRenderPipelineState?
    private var clipSpacePipelineState: MTLRenderPipelineState?
    private var depthPipelineState: MTLRenderPipelineState?
    private var texturePipelineState: MTLRenderPipelineState?
    private var alphaProbePipelineState: MTLRenderPipelineState?
    private var jointsProbePipelineState: MTLRenderPipelineState?
    private var weightsProbePipelineState: MTLRenderPipelineState?
    private var skinnedPipelineState: MTLRenderPipelineState?

    // Debug uniform buffer
    private var uniformBuffer: MTLBuffer?

    public var currentPhase: DebugPhase = .unlitSolid

    public init(device: MTLDevice) {
        self.device = device
        setupDebugPipelines()
        setupUniformBuffer()
    }

    private func setupDebugPipelines() {
        // Load the Metal library from bundle resources
        guard let bundleURL = Bundle.module.url(forResource: "DebugShaders", withExtension: "metal"),
              let source = try? String(contentsOf: bundleURL, encoding: .utf8) else {
            vrmLog("[VRMDebugRenderer] Failed to load DebugShaders.metal from bundle")
            return
        }

        // Compile the Metal source
        let options = MTLCompileOptions()
        guard let library = try? device.makeLibrary(source: source, options: options) else {
            vrmLog("[VRMDebugRenderer] Failed to compile DebugShaders.metal")
            return
        }

        let vertexDescriptor = createDebugVertexDescriptor()

        // Phase 1: Unlit solid color pipeline
        unlitPipelineState = createPipeline(
            library: library,
            vertexFunction: "debug_unlit_vertex",
            fragmentFunction: "debug_unlit_fragment",
            vertexDescriptor: vertexDescriptor,
            label: "Debug Unlit"
        )

        // Phase 1b: Clip-space position visualization pipeline
        clipSpacePipelineState = createPipeline(
            library: library,
            vertexFunction: "debug_clip_space_vertex",
            fragmentFunction: "debug_clip_space_fragment",
            vertexDescriptor: vertexDescriptor,
            label: "Debug Clip Space"
        )

        // Phase 2: Depth visualization pipeline
        depthPipelineState = createPipeline(
            library: library,
            vertexFunction: "debug_unlit_vertex",
            fragmentFunction: "debug_depth_fragment",
            vertexDescriptor: vertexDescriptor,
            label: "Debug Depth"
        )

        // Phase 3: Texture-only pipeline
        texturePipelineState = createPipeline(
            library: library,
            vertexFunction: "debug_unlit_vertex",
            fragmentFunction: "debug_texture_fragment",
            vertexDescriptor: vertexDescriptor,
            label: "Debug Texture"
        )

        // Phase 3b: Alpha probe pipeline
        alphaProbePipelineState = createPipeline(
            library: library,
            vertexFunction: "debug_unlit_vertex",
            fragmentFunction: "debug_alpha_probe_fragment",
            vertexDescriptor: vertexDescriptor,
            label: "Debug Alpha Probe"
        )

        // Phase 3c: Joints probe pipeline
        jointsProbePipelineState = createPipeline(
            library: library,
            vertexFunction: "debug_joints_weights_vertex",
            fragmentFunction: "debug_joints_fragment",
            vertexDescriptor: vertexDescriptor,
            label: "Debug Joints Probe"
        )

        // Phase 3d: Weights probe pipeline
        weightsProbePipelineState = createPipeline(
            library: library,
            vertexFunction: "debug_joints_weights_vertex",
            fragmentFunction: "debug_weights_fragment",
            vertexDescriptor: vertexDescriptor,
            label: "Debug Weights Probe"
        )

        // Phase 4: Skinned pipeline
        skinnedPipelineState = createPipeline(
            library: library,
            vertexFunction: "debug_skinned_vertex",
            fragmentFunction: "debug_unlit_fragment",
            vertexDescriptor: vertexDescriptor,
            label: "Debug Skinned"
        )
    }

    private func createDebugVertexDescriptor() -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()

        // CRITICAL: Must match VRMVertex struct layout exactly!
        // VRMVertex layout:
        // - position: SIMD3<Float> at offset 0 (12 bytes)
        // - normal: SIMD3<Float> at offset 12 (12 bytes)
        // - texCoord: SIMD2<Float> at offset 24 (8 bytes)
        // - color: SIMD4<Float> at offset 32 (16 bytes)
        // - joints: SIMD4<UInt16> at offset 48 (8 bytes)
        // - weights: SIMD4<Float> at offset 56 (16 bytes)
        // Total stride: 96 bytes (includes padding for alignment)

        // Position (float3)
        descriptor.attributes[0].format = .float3
        descriptor.attributes[0].offset = 0
        descriptor.attributes[0].bufferIndex = 0

        // Normal (float3)
        descriptor.attributes[1].format = .float3
        descriptor.attributes[1].offset = 12  // MemoryLayout<SIMD3<Float>>.size
        descriptor.attributes[1].bufferIndex = 0

        // UV0 (float2)
        descriptor.attributes[2].format = .float2
        descriptor.attributes[2].offset = 24  // 12 + 12
        descriptor.attributes[2].bufferIndex = 0

        // Color (float4) - IMPORTANT: Must include even if not used!
        descriptor.attributes[3].format = .float4
        descriptor.attributes[3].offset = 32  // 24 + 8
        descriptor.attributes[3].bufferIndex = 0

        // Joints (ushort4) - for skinning phases
        descriptor.attributes[4].format = .ushort4
        descriptor.attributes[4].offset = 48  // 32 + 16
        descriptor.attributes[4].bufferIndex = 0

        // Weights (float4) - for skinning phases
        descriptor.attributes[5].format = .float4
        descriptor.attributes[5].offset = 56  // 48 + 8
        descriptor.attributes[5].bufferIndex = 0

        // Buffer layout - MUST match VRMVertex stride!
        descriptor.layouts[0].stride = MemoryLayout<VRMVertex>.stride  // 72 bytes

        return descriptor
    }

    private func createPipeline(library: MTLLibrary, vertexFunction: String, fragmentFunction: String, vertexDescriptor: MTLVertexDescriptor, label: String) -> MTLRenderPipelineState? {
        guard let vertexFunc = library.makeFunction(name: vertexFunction),
              let fragmentFunc = library.makeFunction(name: fragmentFunction) else {
            vrmLog("[VRMDebugRenderer] Failed to create functions for \(label)")
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunction = vertexFunc
        descriptor.fragmentFunction = fragmentFunc
        descriptor.vertexDescriptor = vertexDescriptor

        // Set up render target formats (match offscreen rendering)
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        descriptor.depthAttachmentPixelFormat = .depth32Float

        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            vrmLog("[VRMDebugRenderer] Failed to create \(label) pipeline: \(error)")
            return nil
        }
    }

    private func setupUniformBuffer() {
        let size = MemoryLayout<DebugUniforms>.size
        uniformBuffer = device.makeBuffer(length: size, options: [.storageModeShared])
        uniformBuffer?.label = "Debug Uniforms"
    }

    /// Render a single mesh primitive in debug mode
    public func renderPrimitive(
        encoder: MTLRenderCommandEncoder,
        primitive: VRMPrimitive,
        node: VRMNode,
        viewMatrix: float4x4,
        projectionMatrix: float4x4,
        materials: [VRMMaterial]? = nil,
        jointBuffer: MTLBuffer? = nil
    ) {
        // Validate buffers - log and return instead of crashing
        let primitiveName = node.name ?? "unnamed"

        guard let vertexBuffer = primitive.vertexBuffer else {
            let error = VRMDebugRendererError.vertexBufferNil(primitive: primitiveName)
            vrmLog("❌ \(error.localizedDescription)")
            return
        }

        guard let indexBuffer = primitive.indexBuffer else {
            let error = VRMDebugRendererError.indexBufferNil(primitive: primitiveName)
            vrmLog("❌ \(error.localizedDescription)")
            return
        }

        guard primitive.indexCount > 0 else {
            let error = VRMDebugRendererError.zeroIndexCount(primitive: primitiveName)
            vrmLog("❌ \(error.localizedDescription)")
            return
        }

        // Verify index buffer size
        let indexStride = primitive.indexType == .uint16 ? 2 : 4
        let requiredIndexBufferSize = primitive.indexCount * indexStride
        guard indexBuffer.length >= requiredIndexBufferSize else {
            let error = VRMDebugRendererError.indexBufferTooSmall(
                primitive: primitiveName,
                required: requiredIndexBufferSize,
                actual: indexBuffer.length
            )
            vrmLog("❌ \(error.localizedDescription)")
            return
        }

        // Verify vertex buffer size
        let requiredVertexBufferSize = primitive.vertexCount * MemoryLayout<VRMVertex>.stride
        guard vertexBuffer.length >= requiredVertexBufferSize else {
            let error = VRMDebugRendererError.vertexBufferTooSmall(
                primitive: primitiveName,
                required: requiredVertexBufferSize,
                actual: vertexBuffer.length
            )
            vrmLog("❌ \(error.localizedDescription)")
            return
        }

        // Select pipeline based on current phase
        let pipelineState: MTLRenderPipelineState?
        switch currentPhase {
        case .unlitSolid:
            pipelineState = unlitPipelineState
        case .clipSpace:
            pipelineState = clipSpacePipelineState
        case .depthViz:
            pipelineState = depthPipelineState
        case .textureOnly:
            pipelineState = texturePipelineState
        case .alphaProbe:
            pipelineState = alphaProbePipelineState
        case .jointsProbe:
            pipelineState = jointsProbePipelineState
        case .weightsProbe:
            pipelineState = weightsProbePipelineState
        case .skinnedIdentity, .skinnedReal:
            pipelineState = skinnedPipelineState
        case .fullMaterial:
            // Fall back to normal rendering
            return
        }

        guard let pipeline = pipelineState else {
            vrmLog("[VRMDebugRenderer] ❌ No pipeline for phase \(currentPhase)")
            return
        }

        encoder.setRenderPipelineState(pipeline)

        // Update uniforms
        updateUniforms(modelMatrix: node.worldMatrix, viewMatrix: viewMatrix, projectionMatrix: projectionMatrix)

        // Bind vertex buffer
        encoder.setVertexBuffer(primitive.vertexBuffer!, offset: 0, index: 0)

        // Bind uniform buffer
        if let uniformBuffer = uniformBuffer {
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        }

        // Phase-specific bindings
        switch currentPhase {
        case .textureOnly:
            bindTextureIfAvailable(encoder: encoder, primitive: primitive, materials: materials)
        case .alphaProbe:
            bindMaterialAndTexture(encoder: encoder, primitive: primitive, materials: materials)
        case .skinnedIdentity:
            bindIdentityJointMatrices(encoder: encoder)
        case .skinnedReal:
            bindRealJointMatrices(encoder: encoder, jointBuffer: jointBuffer)
        default:
            break
        }

        // Log critical info before draw
        vrmLog("[VRMDebugRenderer] 🎯 Phase: \(currentPhase.rawValue)")
        vrmLog("[VRMDebugRenderer] 📊 Draw call: primitiveType=\(primitive.primitiveType.rawValue), indexCount=\(primitive.indexCount), indexType=\(primitive.indexType.rawValue)")
        vrmLog("[VRMDebugRenderer] 📏 Buffers: vertexCount=\(primitive.vertexCount), vertexStride=\(MemoryLayout<VRMVertex>.stride)")

        // DIAGNOSTIC: Sample first few vertices to check data validity
        if currentPhase == .unlitSolid && primitive.vertexBuffer != nil {
            let vertexPointer = primitive.vertexBuffer!.contents().bindMemory(to: VRMVertex.self, capacity: min(3, primitive.vertexCount))
            for i in 0..<min(3, primitive.vertexCount) {
                let vertex = vertexPointer[i]
                vrmLog("[VERTEX \(i)] pos=(\(vertex.position.x), \(vertex.position.y), \(vertex.position.z)), normal=(\(vertex.normal.x), \(vertex.normal.y), \(vertex.normal.z))")
                if vertex.position.x.isNaN || vertex.position.y.isNaN || vertex.position.z.isNaN {
                    vrmLog("⚠️ WARNING: Vertex \(i) has NaN position!")
                }
                if abs(vertex.position.x) > 1000 || abs(vertex.position.y) > 1000 || abs(vertex.position.z) > 1000 {
                    vrmLog("⚠️ WARNING: Vertex \(i) has extreme position values!")
                }
            }

            // Check first few indices
            if let indexBuffer = primitive.indexBuffer {
                if primitive.indexType == .uint16 {
                    let indexPointer = indexBuffer.contents().bindMemory(to: UInt16.self, capacity: min(6, primitive.indexCount))
                    let indices = Array(0..<min(6, primitive.indexCount)).map { indexPointer[$0] }
                    vrmLog("[INDICES] First 6: \(indices)")
                    // Check if indices are within bounds
                    for i in 0..<min(6, primitive.indexCount) {
                        let index = Int(indexPointer[i])
                        if index >= primitive.vertexCount {
                            vrmLog("❌ ERROR: Index \(i) = \(index) is out of bounds (vertexCount=\(primitive.vertexCount))!")
                        }
                    }
                } else if primitive.indexType == .uint32 {
                    let indexPointer = indexBuffer.contents().bindMemory(to: UInt32.self, capacity: min(6, primitive.indexCount))
                    let indices = Array(0..<min(6, primitive.indexCount)).map { indexPointer[$0] }
                    vrmLog("[INDICES] First 6 (uint32): \(indices)")
                }
            }
        }

        // Draw the primitive
        encoder.drawIndexedPrimitives(
            type: primitive.primitiveType,
            indexCount: primitive.indexCount,
            indexType: primitive.indexType,
            indexBuffer: primitive.indexBuffer!,
            indexBufferOffset: 0
        )
    }

    private func updateUniforms(modelMatrix: float4x4, viewMatrix: float4x4, projectionMatrix: float4x4) {
        guard let buffer = uniformBuffer else { return }

        var uniforms = DebugUniforms(
            modelMatrix: modelMatrix,
            viewMatrix: viewMatrix,
            projectionMatrix: projectionMatrix,
            modelViewProjectionMatrix: projectionMatrix * viewMatrix * modelMatrix
        )

        // DIAGNOSTIC: Check matrix values
        vrmLog("[MATRIX DEBUG]")
        vrmLog("  Model translation: (\(modelMatrix.columns.3.x), \(modelMatrix.columns.3.y), \(modelMatrix.columns.3.z))")
        vrmLog("  View translation: (\(viewMatrix.columns.3.x), \(viewMatrix.columns.3.y), \(viewMatrix.columns.3.z))")

        // Check if projection matrix looks reasonable
        let fov = atan(1.0 / projectionMatrix[1][1]) * 2.0 * 180.0 / Float.pi
        vrmLog("  Projection FOV: ~\(fov) degrees")

        buffer.contents().copyMemory(from: &uniforms, byteCount: MemoryLayout<DebugUniforms>.size)
    }

    private func bindMaterialAndTexture(encoder: MTLRenderCommandEncoder, primitive: VRMPrimitive, materials: [VRMMaterial]?) {
        // Bind base color factor and texture for alpha probe
        var baseColorFactor = SIMD4<Float>(1, 1, 1, 1)

        if let materialIndex = primitive.materialIndex,
           let materials = materials,
           materialIndex < materials.count {
            let material = materials[materialIndex]
            baseColorFactor = material.baseColorFactor

            // Bind base color factor to fragment buffer 0
            encoder.setFragmentBytes(&baseColorFactor,
                                    length: MemoryLayout<SIMD4<Float>>.size,
                                    index: 0)

            // Bind texture if available
            if let baseColorTexture = material.baseColorTexture?.mtlTexture {
                encoder.setFragmentTexture(baseColorTexture, index: 0)
                vrmLog("[VRMDebugRenderer] ✅ Alpha probe: material \(materialIndex), baseColor: \(baseColorFactor), texture: yes")
            } else {
                // Use white texture as fallback
                if let fallbackTexture = createFallbackTexture() {
                    encoder.setFragmentTexture(fallbackTexture, index: 0)
                }
                vrmLog("[VRMDebugRenderer] ⚠️ Alpha probe: material \(materialIndex), baseColor: \(baseColorFactor), texture: fallback")
            }
        } else {
            // No material - use white defaults
            encoder.setFragmentBytes(&baseColorFactor,
                                    length: MemoryLayout<SIMD4<Float>>.size,
                                    index: 0)
            if let fallbackTexture = createFallbackTexture() {
                encoder.setFragmentTexture(fallbackTexture, index: 0)
            }
            vrmLog("[VRMDebugRenderer] ⚠️ Alpha probe: no material, using white defaults")
        }

        // Always bind a sampler
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .repeat
        samplerDescriptor.tAddressMode = .repeat
        if let sampler = device.makeSamplerState(descriptor: samplerDescriptor) {
            encoder.setFragmentSamplerState(sampler, index: 0)
        }
    }

    private func bindTextureIfAvailable(encoder: MTLRenderCommandEncoder, primitive: VRMPrimitive, materials: [VRMMaterial]?) {
        // Try to bind base color texture if available
        var textureFound = false

        if let materialIndex = primitive.materialIndex,
           let materials = materials,
           materialIndex < materials.count {
            let material = materials[materialIndex]

            if let baseColorTexture = material.baseColorTexture?.mtlTexture {
                encoder.setFragmentTexture(baseColorTexture, index: 0)
                textureFound = true
                vrmLog("[VRMDebugRenderer] ✅ Bound texture for material \(materialIndex)")
            }
        }

        if !textureFound {
            // Create a pink fallback texture if no texture available
            vrmLog("[VRMDebugRenderer] ⚠️ No texture found, using fallback")
            if let fallbackTexture = createFallbackTexture() {
                encoder.setFragmentTexture(fallbackTexture, index: 0)
            }
        }

        // Create a simple sampler
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .repeat
        samplerDescriptor.tAddressMode = .repeat
        if let sampler = device.makeSamplerState(descriptor: samplerDescriptor) {
            encoder.setFragmentSamplerState(sampler, index: 0)
        }
    }

    private func createFallbackTexture() -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 2,
            height: 2,
            mipmapped: false
        )

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        // Create pink texture data
        let pink: [UInt8] = [255, 0, 255, 255]  // RGBA
        let data = [pink, pink, pink, pink].flatMap { $0 }

        texture.replace(
            region: MTLRegionMake2D(0, 0, 2, 2),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: 8
        )

        return texture
    }

    private func bindIdentityJointMatrices(encoder: MTLRenderCommandEncoder) {
        // Create buffer with 64 identity matrices (typical max joint count)
        let identityMatrix = matrix_identity_float4x4
        var identityMatrices = [float4x4](repeating: identityMatrix, count: 64)
        let identityBuffer = device.makeBuffer(bytes: &identityMatrices,
                                              length: MemoryLayout<float4x4>.size * 64,
                                              options: [.storageModeShared])
        encoder.setVertexBuffer(identityBuffer, offset: 0, index: 2)
        vrmLog("[VRMDebugRenderer] Bound identity joint matrices")
    }

    private func bindRealJointMatrices(encoder: MTLRenderCommandEncoder, jointBuffer: MTLBuffer?) {
        if let jointBuffer = jointBuffer {
            encoder.setVertexBuffer(jointBuffer, offset: 0, index: 2)
            vrmLog("[VRMDebugRenderer] ✅ Bound real joint matrices buffer")
        } else {
            // Fall back to identity if no joint buffer provided
            bindIdentityJointMatrices(encoder: encoder)
            vrmLog("[VRMDebugRenderer] ⚠️ No joint buffer, using identity matrices")
        }
    }
}

// Debug uniform structure (matches Metal shader)
private struct DebugUniforms {
    let modelMatrix: float4x4
    let viewMatrix: float4x4
    let projectionMatrix: float4x4
    let modelViewProjectionMatrix: float4x4
}
