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
import ModelIO
import Metal
import MetalKit
import simd

/// Exporter for converting VRM models to USDZ format
///
/// Note: USDZ export will lose VRM-specific features like:
/// - Humanoid bone mappings
/// - Expression/morph target animations
/// - Spring bone physics
/// - MToon shader properties
///
/// USDZ export is primarily useful for AR Quick Look on iOS/macOS.
public class USDZExporter {
    private let device: MTLDevice

    /// Configuration for USDZ export
    public struct ExportOptions {
        /// Whether to bake current pose into exported mesh
        public var bakeCurrentPose: Bool = false

        /// Whether to include textures in USDZ archive
        public var includeTextures: Bool = true

        /// Scale factor to apply (useful for unit conversion)
        public var scaleFactor: Float = 1.0

        /// Whether to optimize mesh for AR Quick Look
        public var optimizeForAR: Bool = true

        /// Maximum texture resolution (images will be downscaled)
        public var maxTextureResolution: Int = 2048

        public init() {}
    }

    public init(device: MTLDevice) {
        self.device = device
    }

    // MARK: - Export

    /// Export VRM model to USDZ file
    /// - Parameters:
    ///   - model: VRM model to export
    ///   - url: Destination URL for USDZ file
    ///   - options: Export configuration
    public func export(model: VRMModel, to url: URL, options: ExportOptions = ExportOptions()) throws {
        vrmLog("[USDZExporter] Starting USDZ export to: \(url.path)")

        // Create MDLAsset
        let asset = MDLAsset()

        // Set frame rate and time samples for animations (if any)
        asset.frameInterval = 1.0 / 30.0  // 30 FPS

        // Convert meshes to MDL
        for (meshIndex, vrmMesh) in model.meshes.enumerated() {
            vrmLog("[USDZExporter] Converting mesh \(meshIndex): \(vrmMesh.name ?? "unnamed")")

            let mdlMesh = try convertToMDLMesh(
                vrmMesh,
                model: model,
                options: options
            )

            asset.add(mdlMesh)
        }

        // Export to USDZ
        do {
            if #available(macOS 10.14, iOS 12.0, *) {
                try asset.export(to: url)
                vrmLog("[USDZExporter] Export complete: \(url.path)")
            } else {
                throw VRMError.invalidPath(
                    path: url.path,
                    reason: "USDZ export requires macOS 10.14+ or iOS 12+",
                    filePath: nil
                )
            }
        } catch {
            throw VRMError.invalidPath(
                path: url.path,
                reason: "Failed to export USDZ: \(error.localizedDescription)",
                filePath: nil
            )
        }
    }

    /// Export VRM model to USDZ data
    /// - Parameters:
    ///   - model: VRM model to export
    ///   - options: Export configuration
    /// - Returns: USDZ data
    public func export(model: VRMModel, options: ExportOptions = ExportOptions()) throws -> Data {
        // Write to temporary file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("usdz")

        try export(model: model, to: tempURL, options: options)
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        return try Data(contentsOf: tempURL)
    }

    // MARK: - Mesh Conversion

    private func convertToMDLMesh(
        _ vrmMesh: VRMMesh,
        model: VRMModel,
        options: ExportOptions
    ) throws -> MDLMesh {
        // Create allocator
        let allocator = MTKMeshBufferAllocator(device: device)

        // We need to combine all primitives into a single MDLMesh
        // For simplicity, we'll process the first primitive
        guard let firstPrimitive = vrmMesh.primitives.first else {
            throw VRMError.invalidMesh(
                meshIndex: 0,
                primitiveIndex: nil,
                reason: "Mesh has no primitives",
                filePath: nil
            )
        }

        // Extract vertex data
        let vertexCount = firstPrimitive.vertexCount
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var texCoords: [SIMD2<Float>] = []

        // Get positions
        if let posBuffer = firstPrimitive.vertexBuffers["POSITION"] {
            let count = posBuffer.length / MemoryLayout<SIMD3<Float>>.stride
            let pointer = posBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: count)
            for i in 0..<count {
                var pos = pointer[i]
                pos *= options.scaleFactor
                positions.append(pos)
            }
        }

        // Get normals
        if let normalBuffer = firstPrimitive.vertexBuffers["NORMAL"] {
            let count = normalBuffer.length / MemoryLayout<SIMD3<Float>>.stride
            let pointer = normalBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: count)
            for i in 0..<count {
                normals.append(pointer[i])
            }
        } else {
            // Generate default normals
            normals = Array(repeating: SIMD3<Float>(0, 1, 0), count: positions.count)
        }

        // Get texture coordinates
        if let texCoordBuffer = firstPrimitive.vertexBuffers["TEXCOORD_0"] {
            let count = texCoordBuffer.length / MemoryLayout<SIMD2<Float>>.stride
            let pointer = texCoordBuffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: count)
            for i in 0..<count {
                texCoords.append(pointer[i])
            }
        } else {
            // Generate default UVs
            texCoords = Array(repeating: SIMD2<Float>(0, 0), count: positions.count)
        }

        // Create vertex descriptor
        let vertexDescriptor = MDLVertexDescriptor()
        vertexDescriptor.attributes[0] = MDLVertexAttribute(
            name: MDLVertexAttributePosition,
            format: .float3,
            offset: 0,
            bufferIndex: 0
        )
        vertexDescriptor.attributes[1] = MDLVertexAttribute(
            name: MDLVertexAttributeNormal,
            format: .float3,
            offset: MemoryLayout<SIMD3<Float>>.stride,
            bufferIndex: 0
        )
        vertexDescriptor.attributes[2] = MDLVertexAttribute(
            name: MDLVertexAttributeTextureCoordinate,
            format: .float2,
            offset: MemoryLayout<SIMD3<Float>>.stride * 2,
            bufferIndex: 0
        )
        vertexDescriptor.layouts[0] = MDLVertexBufferLayout(
            stride: MemoryLayout<SIMD3<Float>>.stride * 2 + MemoryLayout<SIMD2<Float>>.stride
        )

        // Create interleaved vertex data
        let stride = MemoryLayout<SIMD3<Float>>.stride * 2 + MemoryLayout<SIMD2<Float>>.stride
        var vertexData = Data(count: stride * positions.count)

        vertexData.withUnsafeMutableBytes { rawPtr in
            let ptr = rawPtr.baseAddress!
            for i in 0..<positions.count {
                let offset = i * stride
                // Position
                ptr.advanced(by: offset).assumingMemoryBound(to: SIMD3<Float>.self).pointee = positions[i]
                // Normal
                ptr.advanced(by: offset + MemoryLayout<SIMD3<Float>>.stride).assumingMemoryBound(to: SIMD3<Float>.self).pointee = normals[i]
                // TexCoord
                ptr.advanced(by: offset + MemoryLayout<SIMD3<Float>>.stride * 2).assumingMemoryBound(to: SIMD2<Float>>.self).pointee = texCoords[i]
            }
        }

        // Create MDLMeshBuffers
        let vertexBuffer = allocator.newBuffer(with: vertexData, type: .vertex)

        // Get indices
        var indices: [UInt32] = []
        if let indexBuffer = firstPrimitive.indexBuffer {
            // Determine index size
            let indexCount = firstPrimitive.indexCount ?? 0
            let bytesPerIndex = indexBuffer.length / indexCount

            if bytesPerIndex == 2 {
                // UInt16 indices
                let ptr = indexBuffer.contents().bindMemory(to: UInt16.self, capacity: indexCount)
                for i in 0..<indexCount {
                    indices.append(UInt32(ptr[i]))
                }
            } else if bytesPerIndex == 4 {
                // UInt32 indices
                let ptr = indexBuffer.contents().bindMemory(to: UInt32.self, capacity: indexCount)
                for i in 0..<indexCount {
                    indices.append(ptr[i])
                }
            }
        } else {
            // No index buffer - generate sequential indices
            indices = Array(0..<UInt32(positions.count))
        }

        // Create index buffer
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.stride)
        let indexBuffer = allocator.newBuffer(with: indexData, type: .index)

        // Create submesh
        let submesh = MDLSubmesh(
            indexBuffer: indexBuffer,
            indexCount: indices.count,
            indexType: .uint32,
            geometryType: .triangles,
            material: nil
        )

        // Create MDLMesh
        let mdlMesh = MDLMesh(
            vertexBuffer: vertexBuffer,
            vertexCount: positions.count,
            descriptor: vertexDescriptor,
            submeshes: [submesh]
        )

        mdlMesh.name = vrmMesh.name ?? "mesh"

        // Add default material
        let material = MDLMaterial(
            name: "material",
            scatteringFunction: MDLPhysicallyPlausibleScatteringFunction()
        )

        // Set base color if we can find it from VRM material
        if let primitiveMatIndex = firstPrimitive.material,
           primitiveMatIndex < model.materials.count {
            let vrmMaterial = model.materials[primitiveMatIndex]

            // Convert VRM color to MDL
            let baseColor = vrmMaterial.baseColorFactor
            let float3Color = SIMD3<Float>(baseColor.x, baseColor.y, baseColor.z)

            let colorProperty = MDLMaterialProperty(
                name: "baseColor",
                semantic: .baseColor,
                float3: float3Color
            )
            material.setProperty(colorProperty)
        }

        submesh.material = material

        return mdlMesh
    }
}
