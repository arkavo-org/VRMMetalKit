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
import simd

/// Parser for USDZ (Universal Scene Description) files
///
/// Converts USDZ assets to glTF document structures for rendering with VRMMetalKit.
/// Note: USDZ does not support VRM-specific metadata (humanoid bones, expressions, etc.),
/// so imported models will have minimal VRM structure.
public class USDZParser {
    private let device: MTLDevice?

    /// Configuration for USDZ import
    public struct ImportOptions {
        /// Whether to generate default humanoid bone mapping (best-effort)
        public var generateHumanoidBones: Bool = true

        /// Whether to create a default VRM metadata block
        public var createDefaultVRMMetadata: Bool = true

        /// Scale factor to apply to all vertices (useful for unit conversion)
        public var scaleFactor: Float = 1.0

        /// Default MToon material settings for imported materials
        public var useDefaultMToonMaterial: Bool = true

        public init() {}
    }

    public init(device: MTLDevice? = nil) {
        self.device = device
    }

    // MARK: - Parsing

    /// Parse USDZ file from URL
    /// - Parameters:
    ///   - url: URL to USDZ file
    ///   - options: Import configuration options
    /// - Returns: Tuple of GLTFDocument and optional binary data
    public func parse(from url: URL, options: ImportOptions = ImportOptions()) throws -> (GLTFDocument, Data?) {
        vrmLog("[USDZParser] Loading USDZ from: \(url.path)")

        // Load MDLAsset from USDZ
        let asset = MDLAsset(url: url)

        guard asset.count > 0 else {
            throw VRMError.invalidGLBFormat(
                reason: "USDZ file contains no objects",
                filePath: url.path
            )
        }

        vrmLog("[USDZParser] Loaded \(asset.count) objects from USDZ")

        // Convert to glTF structure
        return try convertToGLTF(asset: asset, options: options, filePath: url.path)
    }

    /// Parse USDZ data directly
    /// - Parameters:
    ///   - data: USDZ binary data
    ///   - options: Import configuration options
    /// - Returns: Tuple of GLTFDocument and optional binary data
    public func parse(from data: Data, filePath: String? = nil, options: ImportOptions = ImportOptions()) throws -> (GLTFDocument, Data?) {
        vrmLog("[USDZParser] Loading USDZ from data (\(data.count) bytes)")

        // Write to temporary file (ModelIO requires file URLs)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("usdz")

        try data.write(to: tempURL)
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        return try parse(from: tempURL, options: options)
    }

    // MARK: - Conversion

    private func convertToGLTF(asset: MDLAsset, options: ImportOptions, filePath: String?) throws -> (GLTFDocument, Data?) {
        var nodes: [GLTFNode] = []
        var meshes: [GLTFMesh] = []
        var materials: [GLTFMaterial] = []
        var accessors: [GLTFAccessor] = []
        var bufferViews: [GLTFBufferView] = []
        var buffers: [GLTFBuffer] = []
        var binaryData = Data()

        // Process each MDLObject
        for objectIndex in 0..<asset.count {
            guard let object = asset.object(at: objectIndex) as? MDLMesh else {
                vrmLog("[USDZParser] Warning: Object \(objectIndex) is not an MDLMesh, skipping")
                continue
            }

            vrmLog("[USDZParser] Processing mesh \(objectIndex): \(object.name)")

            // Convert mesh to glTF structures
            let (gltfMesh, meshAccessors, meshBufferViews, meshData) = try convertMesh(
                object,
                options: options,
                accessorBaseIndex: accessors.count,
                bufferViewBaseIndex: bufferViews.count,
                bufferDataOffset: binaryData.count
            )

            meshes.append(gltfMesh)
            accessors.append(contentsOf: meshAccessors)
            bufferViews.append(contentsOf: meshBufferViews)
            binaryData.append(meshData)

            // Create node for this mesh
            let node = GLTFNode(
                name: object.name,
                mesh: meshes.count - 1,
                translation: nil,
                rotation: nil,
                scale: nil,
                matrix: nil,
                children: nil,
                skin: nil,
                extensions: nil
            )
            nodes.append(node)

            // Process materials
            if let submeshes = object.submeshes as? [MDLSubmesh] {
                for submesh in submeshes {
                    if let mdlMaterial = submesh.material {
                        let gltfMaterial = try convertMaterial(mdlMaterial, options: options)
                        materials.append(gltfMaterial)
                    }
                }
            }
        }

        // Create buffer
        let buffer = GLTFBuffer(
            byteLength: binaryData.count,
            uri: nil,
            name: "USDZ_imported_buffer"
        )
        buffers.append(buffer)

        // Create default scene
        let scene = GLTFScene(
            name: "Scene",
            nodes: Array(0..<nodes.count)
        )

        // Create VRM extensions if requested
        var extensions: [String: Any]?
        if options.createDefaultVRMMetadata {
            extensions = createDefaultVRMExtension(nodeCount: nodes.count, options: options)
        }

        // Assemble glTF document
        let document = GLTFDocument(
            asset: GLTFAsset(version: "2.0", generator: "VRMMetalKit-USDZParser"),
            scene: 0,
            scenes: [scene],
            nodes: nodes,
            meshes: meshes,
            materials: materials.isEmpty ? nil : materials,
            textures: nil,
            images: nil,
            samplers: nil,
            buffers: buffers,
            bufferViews: bufferViews,
            accessors: accessors,
            skins: nil,
            animations: nil,
            extensions: extensions,
            extensionsUsed: options.createDefaultVRMMetadata ? ["VRMC_vrm"] : nil,
            extensionsRequired: nil,
            binaryBufferData: binaryData
        )

        vrmLog("[USDZParser] Conversion complete: \(nodes.count) nodes, \(meshes.count) meshes")

        return (document, binaryData)
    }

    // MARK: - Mesh Conversion

    private func convertMesh(
        _ mdlMesh: MDLMesh,
        options: ImportOptions,
        accessorBaseIndex: Int,
        bufferViewBaseIndex: Int,
        bufferDataOffset: Int
    ) throws -> (GLTFMesh, [GLTFAccessor], [GLTFBufferView], Data) {
        var accessors: [GLTFAccessor] = []
        var bufferViews: [GLTFBufferView] = []
        var bufferData = Data()
        var primitives: [GLTFPrimitive] = []

        // Get vertex descriptor
        guard let vertexDescriptor = mdlMesh.vertexDescriptor else {
            throw VRMError.invalidMesh(
                meshIndex: 0,
                primitiveIndex: nil,
                reason: "MDLMesh has no vertex descriptor",
                filePath: nil
            )
        }

        // Extract vertex data
        var attributes: [String: Int] = [:]

        // Position attribute
        if let positionAttribute = vertexDescriptor.attributes.first(where: { ($0 as? MDLVertexAttribute)?.name == MDLVertexAttributePosition }) as? MDLVertexAttribute {
            let (accessor, bufferView, data) = try extractVertexAttribute(
                from: mdlMesh,
                attribute: positionAttribute,
                accessorIndex: accessorBaseIndex + accessors.count,
                bufferViewIndex: bufferViewBaseIndex + bufferViews.count,
                bufferOffset: bufferDataOffset + bufferData.count,
                scaleFactor: options.scaleFactor
            )
            accessors.append(accessor)
            bufferViews.append(bufferView)
            bufferData.append(data)
            attributes["POSITION"] = accessorBaseIndex + accessors.count - 1
        }

        // Normal attribute
        if let normalAttribute = vertexDescriptor.attributes.first(where: { ($0 as? MDLVertexAttribute)?.name == MDLVertexAttributeNormal }) as? MDLVertexAttribute {
            let (accessor, bufferView, data) = try extractVertexAttribute(
                from: mdlMesh,
                attribute: normalAttribute,
                accessorIndex: accessorBaseIndex + accessors.count,
                bufferViewIndex: bufferViewBaseIndex + bufferViews.count,
                bufferOffset: bufferDataOffset + bufferData.count,
                scaleFactor: 1.0  // Normals are unit vectors
            )
            accessors.append(accessor)
            bufferViews.append(bufferView)
            bufferData.append(data)
            attributes["NORMAL"] = accessorBaseIndex + accessors.count - 1
        }

        // Texture coordinate attribute
        if let texCoordAttribute = vertexDescriptor.attributes.first(where: { ($0 as? MDLVertexAttribute)?.name == MDLVertexAttributeTextureCoordinate }) as? MDLVertexAttribute {
            let (accessor, bufferView, data) = try extractVertexAttribute(
                from: mdlMesh,
                attribute: texCoordAttribute,
                accessorIndex: accessorBaseIndex + accessors.count,
                bufferViewIndex: bufferViewBaseIndex + bufferViews.count,
                bufferOffset: bufferDataOffset + bufferData.count,
                scaleFactor: 1.0
            )
            accessors.append(accessor)
            bufferViews.append(bufferView)
            bufferData.append(data)
            attributes["TEXCOORD_0"] = accessorBaseIndex + accessors.count - 1
        }

        // Process submeshes
        if let submeshes = mdlMesh.submeshes as? [MDLSubmesh] {
            for (submeshIndex, submesh) in submeshes.enumerated() {
                // Extract indices
                let indexBuffer = submesh.indexBuffer
                let (indexAccessor, indexBufferView, indexData) = try extractIndices(
                    from: submesh,
                    accessorIndex: accessorBaseIndex + accessors.count,
                    bufferViewIndex: bufferViewBaseIndex + bufferViews.count,
                    bufferOffset: bufferDataOffset + bufferData.count
                )
                accessors.append(indexAccessor)
                bufferViews.append(indexBufferView)
                bufferData.append(indexData)

                let primitive = GLTFPrimitive(
                    attributes: attributes,
                    indices: accessorBaseIndex + accessors.count - 1,
                    material: submeshIndex,
                    mode: .triangles,
                    targets: nil,
                    extensions: nil
                )
                primitives.append(primitive)
            }
        } else {
            // No submeshes - create single primitive without indices
            let primitive = GLTFPrimitive(
                attributes: attributes,
                indices: nil,
                material: nil,
                mode: .triangles,
                targets: nil,
                extensions: nil
            )
            primitives.append(primitive)
        }

        let gltfMesh = GLTFMesh(
            name: mdlMesh.name,
            primitives: primitives,
            weights: nil,
            extensions: nil
        )

        return (gltfMesh, accessors, bufferViews, bufferData)
    }

    // MARK: - Attribute Extraction

    private func extractVertexAttribute(
        from mdlMesh: MDLMesh,
        attribute: MDLVertexAttribute,
        accessorIndex: Int,
        bufferViewIndex: Int,
        bufferOffset: Int,
        scaleFactor: Float
    ) throws -> (GLTFAccessor, GLTFBufferView, Data) {
        // Get vertex buffer
        guard let vertexBuffers = mdlMesh.vertexBuffers as? [MDLMeshBuffer],
              let buffer = vertexBuffers.first else {
            throw VRMError.missingBuffer(
                bufferIndex: 0,
                requiredBy: "vertex data",
                expectedSize: nil,
                filePath: nil
            )
        }

        let data = Data(bytes: buffer.map().bytes, count: buffer.length)
        let vertexCount = mdlMesh.vertexCount

        // Determine component type and count
        let (componentType, accessorType, componentCount) = try mapAttributeFormat(attribute.format)

        // Create accessor
        let accessor = GLTFAccessor(
            bufferView: bufferViewIndex,
            byteOffset: Int(attribute.offset),
            componentType: componentType,
            count: vertexCount,
            type: accessorType,
            normalized: false,
            min: nil,
            max: nil,
            sparse: nil,
            name: attribute.name
        )

        // Create buffer view
        let bufferView = GLTFBufferView(
            buffer: 0,
            byteOffset: bufferOffset,
            byteLength: data.count,
            byteStride: mdlMesh.vertexDescriptor.layouts.first.map { ($0 as? MDLVertexBufferLayout)?.stride } ?? nil,
            target: .arrayBuffer,
            name: "\(attribute.name)_bufferView"
        )

        return (accessor, bufferView, data)
    }

    private func extractIndices(
        from submesh: MDLSubmesh,
        accessorIndex: Int,
        bufferViewIndex: Int,
        bufferOffset: Int
    ) throws -> (GLTFAccessor, GLTFBufferView, Data) {
        let indexBuffer = submesh.indexBuffer
        let data = Data(bytes: indexBuffer.map().bytes, count: indexBuffer.length)
        let indexCount = submesh.indexCount

        // Determine index type
        let componentType: GLTFAccessor.ComponentType
        switch submesh.indexType {
        case .uint16:
            componentType = .unsignedShort
        case .uint32:
            componentType = .unsignedInt
        default:
            componentType = .unsignedInt
        }

        let accessor = GLTFAccessor(
            bufferView: bufferViewIndex,
            byteOffset: 0,
            componentType: componentType,
            count: indexCount,
            type: .scalar,
            normalized: false,
            min: nil,
            max: nil,
            sparse: nil,
            name: "indices"
        )

        let bufferView = GLTFBufferView(
            buffer: 0,
            byteOffset: bufferOffset,
            byteLength: data.count,
            byteStride: nil,
            target: .elementArrayBuffer,
            name: "indices_bufferView"
        )

        return (accessor, bufferView, data)
    }

    // MARK: - Material Conversion

    private func convertMaterial(_ mdlMaterial: MDLMaterial, options: ImportOptions) throws -> GLTFMaterial {
        var pbr = GLTFPBRMetallicRoughness(
            baseColorFactor: [1, 1, 1, 1],
            baseColorTexture: nil,
            metallicFactor: 0.0,
            roughnessFactor: 1.0,
            metallicRoughnessTexture: nil
        )

        // Extract base color if available
        if let baseColorProperty = mdlMaterial.property(with: MDLMaterialSemantic.baseColor) {
            if baseColorProperty.type == .float3 {
                let color = baseColorProperty.float3Value
                pbr.baseColorFactor = [color.x, color.y, color.z, 1.0]
            } else if baseColorProperty.type == .float4 {
                let color = baseColorProperty.float4Value
                pbr.baseColorFactor = [color.x, color.y, color.z, color.w]
            }
        }

        // Create glTF material
        let material = GLTFMaterial(
            name: mdlMaterial.name,
            pbrMetallicRoughness: pbr,
            normalTexture: nil,
            occlusionTexture: nil,
            emissiveTexture: nil,
            emissiveFactor: [0, 0, 0],
            alphaMode: .opaque,
            alphaCutoff: 0.5,
            doubleSided: false,
            extensions: options.useDefaultMToonMaterial ? createDefaultMToonExtension() : nil
        )

        return material
    }

    // MARK: - VRM Extension Creation

    private func createDefaultVRMExtension(nodeCount: Int, options: ImportOptions) -> [String: Any] {
        var vrm: [String: Any] = [:]

        // Meta (required)
        vrm["meta"] = [
            "name": "Imported USDZ Model",
            "version": "1.0",
            "authors": ["VRMMetalKit"],
            "copyrightInformation": "",
            "contactInformation": "",
            "licenseUrl": "https://vrm.dev/licenses/1.0/",
            "avatarPermission": "onlyAuthor",
            "commercialUsage": "personalNonProfit",
            "allowExcessivelyViolentUsage": false,
            "allowExcessivelySexualUsage": false,
            "allowPoliticalOrReligiousUsage": false,
            "allowAntisocialOrHateUsage": false
        ]

        // Humanoid (optional, best-effort)
        if options.generateHumanoidBones && nodeCount > 0 {
            vrm["humanoid"] = [
                "humanBones": [
                    // Minimal humanoid - just reference root node
                    "hips": ["node": 0]
                ]
            ]
        }

        return ["VRMC_vrm": vrm]
    }

    private func createDefaultMToonExtension() -> [String: Any] {
        return [
            "VRMC_materials_mtoon": [
                "transparentWithZWrite": false,
                "renderQueueOffsetNumber": 0,
                "shadeColorFactor": [1.0, 1.0, 1.0],
                "shadeMultiplyTexture": NSNull(),
                "shadingShiftFactor": 0.0,
                "shadingToonyFactor": 0.9,
                "giEqualizationFactor": 0.9
            ]
        ]
    }

    // MARK: - Helper Methods

    private func mapAttributeFormat(_ format: MDLVertexFormat) throws -> (GLTFAccessor.ComponentType, GLTFAccessor.AccessorType, Int) {
        switch format {
        case .float3:
            return (.float, .vec3, 3)
        case .float2:
            return (.float, .vec2, 2)
        case .float4:
            return (.float, .vec4, 4)
        case .uChar4Normalized:
            return (.unsignedByte, .vec4, 4)
        default:
            throw VRMError.invalidMesh(
                meshIndex: 0,
                primitiveIndex: nil,
                reason: "Unsupported vertex format: \(format.rawValue)",
                filePath: nil
            )
        }
    }
}
