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

/// Interleaved vertex layout consumed by ``GLTFPBRShader.metal``'s `GLTFVertexIn`.
///
/// Mirrors the vertex descriptor returned by
/// ``GLTFRenderer/makeVertexDescriptor()`` — keep both in sync if attributes
/// change.
public struct GLTFRenderableVertex {
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    /// xyz = tangent direction, w = bitangent sign (±1).
    public var tangent: SIMD4<Float>
    public var uv0: SIMD2<Float>

    public init(
        position: SIMD3<Float>,
        normal: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
        tangent: SIMD4<Float> = SIMD4<Float>(1, 0, 0, 1),
        uv0: SIMD2<Float> = SIMD2<Float>(0, 0)
    ) {
        self.position = position
        self.normal = normal
        self.tangent = tangent
        self.uv0 = uv0
    }
}

/// A drawable mesh primitive in GPU-ready form — interleaved vertex buffer
/// in ``GLTFRenderableVertex`` layout plus an optional index buffer.
///
/// Distinct from VRMMetalKit's `VRMMesh`: it carries no morph targets, no
/// skinning palette state, no first-person flags. PBR-rendered static
/// meshes only.
public struct GLTFRenderableMesh {
    public let vertexBuffer: MTLBuffer
    public let vertexCount: Int
    /// `nil` for non-indexed (direct-array) draws.
    public let indexBuffer: MTLBuffer?
    public let indexCount: Int
    public let indexType: MTLIndexType
    public let primitiveType: MTLPrimitiveType

    /// Builds a non-indexed mesh from in-memory vertices. Direct-array draw.
    public static func make(
        vertices: [GLTFRenderableVertex],
        primitiveType: MTLPrimitiveType = .triangle,
        device: MTLDevice
    ) -> GLTFRenderableMesh? {
        let stride = MemoryLayout<GLTFRenderableVertex>.stride
        guard let buffer = vertices.withUnsafeBufferPointer({ ptr in
            device.makeBuffer(bytes: ptr.baseAddress!, length: vertices.count * stride, options: [])
        }) else {
            return nil
        }
        return GLTFRenderableMesh(
            vertexBuffer: buffer,
            vertexCount: vertices.count,
            indexBuffer: nil,
            indexCount: 0,
            indexType: .uint16,
            primitiveType: primitiveType
        )
    }

    /// Builds an indexed mesh from in-memory vertices + UInt16 indices.
    public static func makeIndexed(
        vertices: [GLTFRenderableVertex],
        indices: [UInt16],
        primitiveType: MTLPrimitiveType = .triangle,
        device: MTLDevice
    ) -> GLTFRenderableMesh? {
        let vertexStride = MemoryLayout<GLTFRenderableVertex>.stride
        guard let vbuf = vertices.withUnsafeBufferPointer({ ptr in
            device.makeBuffer(bytes: ptr.baseAddress!, length: vertices.count * vertexStride, options: [])
        }),
        let ibuf = indices.withUnsafeBufferPointer({ ptr in
            device.makeBuffer(bytes: ptr.baseAddress!, length: indices.count * MemoryLayout<UInt16>.stride, options: [])
        }) else {
            return nil
        }
        return GLTFRenderableMesh(
            vertexBuffer: vbuf,
            vertexCount: vertices.count,
            indexBuffer: ibuf,
            indexCount: indices.count,
            indexType: .uint16,
            primitiveType: primitiveType
        )
    }
}

/// Runtime PBR material: factors + texture refs + flags. One per glTF material.
///
/// Texture refs are optional `MTLTexture` instances — the draw call binds a
/// 1×1 default for any nil slot so the shader path stays simple. The flags
/// bitmask tells the fragment which sampled values to actually use.
public struct GLTFRenderableMaterial {
    public var uniforms: GLTFMaterialUniforms
    public var baseColorTexture: MTLTexture?
    public var metallicRoughnessTexture: MTLTexture?
    public var normalTexture: MTLTexture?
    public var occlusionTexture: MTLTexture?
    public var emissiveTexture: MTLTexture?

    public init(
        uniforms: GLTFMaterialUniforms = GLTFMaterialUniforms(),
        baseColorTexture: MTLTexture? = nil,
        metallicRoughnessTexture: MTLTexture? = nil,
        normalTexture: MTLTexture? = nil,
        occlusionTexture: MTLTexture? = nil,
        emissiveTexture: MTLTexture? = nil
    ) {
        self.uniforms = uniforms
        self.baseColorTexture = baseColorTexture
        self.metallicRoughnessTexture = metallicRoughnessTexture
        self.normalTexture = normalTexture
        self.occlusionTexture = occlusionTexture
        self.emissiveTexture = emissiveTexture
    }
}

/// One drawable unit — mesh + material + world transform.
///
/// Asset loaders (step 4b) emit these by walking the glTF scene graph; for
/// step 4a they're hand-built in tests.
public struct GLTFDrawCall {
    public let mesh: GLTFRenderableMesh
    public let material: GLTFRenderableMaterial
    public let modelMatrix: simd_float4x4

    public init(
        mesh: GLTFRenderableMesh,
        material: GLTFRenderableMaterial,
        modelMatrix: simd_float4x4 = matrix_identity_float4x4
    ) {
        self.mesh = mesh
        self.material = material
        self.modelMatrix = modelMatrix
    }
}

/// Per-frame scene state — camera + single directional light.
///
/// Punctual-light arrays (`KHR_lights_punctual`) come in step 4c; this type
/// will grow a `lights:` collection then.
public struct GLTFSceneState {
    public var viewProjection: simd_float4x4
    public var cameraPosition: SIMD3<Float>
    /// World-space direction the light travels (i.e. points *from* sun *into* scene).
    public var lightDirection: SIMD3<Float>
    /// Linear RGB, pre-multiplied by intensity.
    public var lightColor: SIMD3<Float>

    public init(
        viewProjection: simd_float4x4,
        cameraPosition: SIMD3<Float>,
        lightDirection: SIMD3<Float> = normalize(SIMD3<Float>(0.3, -1.0, -0.4)),
        lightColor: SIMD3<Float> = SIMD3<Float>(3.0, 3.0, 3.0)
    ) {
        self.viewProjection = viewProjection
        self.cameraPosition = cameraPosition
        self.lightDirection = lightDirection
        self.lightColor = lightColor
    }
}
