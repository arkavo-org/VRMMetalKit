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
import Metal
import simd

// MARK: - CPU-Side Structures

/// CPU-side per-instance data uploaded to the sprite vertex shader.
///
/// Layout matches the `SpriteInstance` MSL struct in `SpriteShader.metal`.
public struct SpriteInstanceCPU {
    /// Per-instance model matrix (position, rotation, scale).
    public var modelMatrix: simd_float4x4
    /// Per-instance tint colour applied multiplicatively to the sampled texture.
    public var tintColor: SIMD4<Float>
    /// Texture-atlas UV offset (sprite sheets).
    public var texOffset: SIMD2<Float>
    /// Texture-atlas UV scale (sprite sheets).
    public var texScale: SIMD2<Float>

    /// Creates a sprite instance with optional matrix, tint, and atlas-region overrides.
    public init(
        modelMatrix: simd_float4x4 = matrix_identity_float4x4,
        tintColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1),
        texOffset: SIMD2<Float> = SIMD2<Float>(0, 0),
        texScale: SIMD2<Float> = SIMD2<Float>(1, 1)
    ) {
        self.modelMatrix = modelMatrix
        self.tintColor = tintColor
        self.texOffset = texOffset
        self.texScale = texScale
    }

    /// Create instance with position, rotation, and scale
    public static func makeInstance(
        position: SIMD3<Float>,
        rotation: Float = 0.0,
        scale: SIMD2<Float> = SIMD2<Float>(1, 1),
        tintColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
    ) -> SpriteInstanceCPU {
        // Build transformation matrix
        let translationMatrix = matrix_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(position.x, position.y, position.z, 1)
        )

        let rotationMatrix = matrix_float4x4(
            SIMD4<Float>(cos(rotation), sin(rotation), 0, 0),
            SIMD4<Float>(-sin(rotation), cos(rotation), 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )

        let scaleMatrix = matrix_float4x4(
            SIMD4<Float>(scale.x, 0, 0, 0),
            SIMD4<Float>(0, scale.y, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )

        let modelMatrix = translationMatrix * rotationMatrix * scaleMatrix

        return SpriteInstanceCPU(
            modelMatrix: modelMatrix,
            tintColor: tintColor
        )
    }
}

/// CPU-side per-pass uniforms uploaded to the sprite shaders.
///
/// Layout matches the `SpriteUniforms` MSL struct in `SpriteShader.metal`.
public struct SpriteUniformsCPU {
    /// Combined view-projection matrix used to transform sprite quads into clip space.
    public var viewProjectionMatrix: simd_float4x4
    /// Viewport size in pixels; available to MSL for screen-space effects.
    public var viewportSize: SIMD2<Float>
    /// Reserved padding to satisfy 16-byte alignment requirements.
    public var _padding1: Float = 0
    /// Reserved padding to satisfy 16-byte alignment requirements.
    public var _padding2: Float = 0

    /// Creates a uniform payload for a sprite draw with the given camera and viewport.
    public init(
        viewProjectionMatrix: simd_float4x4,
        viewportSize: SIMD2<Float>
    ) {
        self.viewProjectionMatrix = viewProjectionMatrix
        self.viewportSize = viewportSize
    }
}

// MARK: - Quad Mesh Generator

/// Generates a simple quad mesh for sprite rendering
public struct SpriteQuadMesh {
    /// Sprite vertex (position + texCoord)
    public struct Vertex {
        var position: SIMD2<Float>
        var texCoord: SIMD2<Float>
    }

    /// Create a quad mesh centered at origin
    /// - Parameter size: Quad size (default: 1x1, centered at origin)
    /// - Returns: Tuple of (vertices, indices)
    public static func createQuad(size: SIMD2<Float> = SIMD2<Float>(1, 1)) -> ([Vertex], [UInt16]) {
        let halfWidth = size.x * 0.5
        let halfHeight = size.y * 0.5

        // Vertices (counter-clockwise winding)
        let vertices: [Vertex] = [
            Vertex(position: SIMD2<Float>(-halfWidth, -halfHeight), texCoord: SIMD2<Float>(0, 1)), // Bottom-left
            Vertex(position: SIMD2<Float>( halfWidth, -halfHeight), texCoord: SIMD2<Float>(1, 1)), // Bottom-right
            Vertex(position: SIMD2<Float>( halfWidth,  halfHeight), texCoord: SIMD2<Float>(1, 0)), // Top-right
            Vertex(position: SIMD2<Float>(-halfWidth,  halfHeight), texCoord: SIMD2<Float>(0, 0))  // Top-left
        ]

        // Indices (two triangles)
        let indices: [UInt16] = [
            0, 1, 2,  // First triangle
            0, 2, 3   // Second triangle
        ]

        return (vertices, indices)
    }

    /// Create Metal buffers for quad mesh
    public static func createBuffers(device: MTLDevice) -> (vertexBuffer: MTLBuffer, indexBuffer: MTLBuffer)? {
        let (vertices, indices) = createQuad()

        guard let vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<Vertex>.stride,
            options: .storageModeShared
        ) else {
            return nil
        }

        guard let indexBuffer = device.makeBuffer(
            bytes: indices,
            length: indices.count * MemoryLayout<UInt16>.stride,
            options: .storageModeShared
        ) else {
            return nil
        }

        return (vertexBuffer, indexBuffer)
    }
}
