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

// MARK: - VRM Mesh

public class VRMMesh {
    public let name: String?
    public var primitives: [VRMPrimitive] = []

    public init(name: String? = nil) {
        self.name = name
    }

    public static func load(from gltfMesh: GLTFMesh,
                           document: GLTFDocument,
                           device: MTLDevice?,
                           bufferLoader: BufferLoader) async throws -> VRMMesh {
        let mesh = VRMMesh(name: gltfMesh.name)
        vrmLog("[VRMMesh] Loading mesh \(gltfMesh.name ?? "unnamed") with \(gltfMesh.primitives.count) primitives")

        for (primitiveIndex, gltfPrimitive) in gltfMesh.primitives.enumerated() {
            vrmLog("[VRMMesh] Loading primitive \(primitiveIndex)")
            let primitive = try await VRMPrimitive.load(
                from: gltfPrimitive,
                document: document,
                device: device,
                bufferLoader: bufferLoader
            )
            mesh.primitives.append(primitive)
        }

        return mesh
    }
}

// MARK: - VRM Primitive

public class VRMPrimitive {
    public var vertexBuffer: MTLBuffer?
    public var indexBuffer: MTLBuffer?
    public var vertexCount: Int = 0
    public var indexCount: Int = 0
    public var indexType: MTLIndexType = .uint16
    public var indexBufferOffset: Int = 0  // Byte offset for index buffer from accessor
    public var primitiveType: MTLPrimitiveType = .triangle
    public var materialIndex: Int?

    // Vertex attributes
    public var hasNormals = false
    public var hasTexCoords = false
    public var hasTangents = false
    public var hasColors = false
    public var hasJoints = false
    public var hasWeights = false

    // Skinning requirements
    public var requiredPaletteSize: Int = 0  // Minimum joints needed (maxJoint + 1 from JOINTS_0 data)

    // Morph targets
    public var morphTargets: [VRMMorphTarget] = []
    public var morphPositionBuffers: [MTLBuffer] = []
    public var morphNormalBuffers: [MTLBuffer] = []
    public var morphTangentBuffers: [MTLBuffer] = []

    // SoA morph buffers for compute path
    public var morphPositionsSoA: MTLBuffer?  // Layout: [morph0[v0..vN], morph1[v0..vN], ...]
    public var morphNormalsSoA: MTLBuffer?    // Same layout for normals
    public var basePositionsBuffer: MTLBuffer? // Base positions for compute
    public var baseNormalsBuffer: MTLBuffer?   // Base normals for compute

    public init() {}

    public static func load(from gltfPrimitive: GLTFPrimitive,
                           document: GLTFDocument,
                           device: MTLDevice?,
                           bufferLoader: BufferLoader) async throws -> VRMPrimitive {
        let primitive = VRMPrimitive()
        primitive.materialIndex = gltfPrimitive.material

        // Set primitive type
        let mode = gltfPrimitive.mode ?? 4 // Default to triangles
        primitive.primitiveType = MTLPrimitiveType(gltfMode: mode)

        // Log primitive type for debugging wedge artifacts
        vrmLog("[PRIMITIVE MODE] glTF mode=\(mode) → Metal type=\(primitive.primitiveType)")
        if mode == 5 {
            vrmLog("[PRIMITIVE MODE] ⚠️ TRIANGLE_STRIP detected!")
        } else if mode == 6 {
            vrmLog("[PRIMITIVE MODE] ⚠️ TRIANGLE_FAN detected (mapped to triangleStrip)!")
        }

        // UNIFIED PATH: Load all attributes into VertexData struct and interleave manually.
        // This ensures all primitives, interleaved or not, produce a vertex buffer
        // with the exact layout expected by the renderer.
        var vertexData = VertexData()

        // Load positions (required)
        if let positionAccessorIndex = gltfPrimitive.attributes["POSITION"] {
            let positions = try bufferLoader.loadAccessorAsFloat(positionAccessorIndex)
            let positionCount = (positions.count / 3) * 3
            vertexData.positions = stride(from: 0, to: positionCount, by: 3).map { i in
                SIMD3<Float>(positions[i], positions[i+1], positions[i+2])
            }
            primitive.vertexCount = vertexData.positions.count
        } else {
            throw VRMError.missingVertexAttribute(
                meshIndex: 0, // We don't have meshIndex in this context, but this is a required POSITION attribute
                attributeName: "POSITION",
                filePath: bufferLoader.filePath
            )
        }

        // Load other attributes...
        if let normalAccessorIndex = gltfPrimitive.attributes["NORMAL"] {
            let normals = try bufferLoader.loadAccessorAsFloat(normalAccessorIndex)
            let normalCount = (normals.count / 3) * 3
            vertexData.normals = stride(from: 0, to: normalCount, by: 3).map { i in
                SIMD3<Float>(normals[i], normals[i+1], normals[i+2])
            }
            primitive.hasNormals = true
        }

        if let texCoordAccessorIndex = gltfPrimitive.attributes["TEXCOORD_0"] {
            let texCoords = try bufferLoader.loadAccessorAsFloat(texCoordAccessorIndex)
            let texCoordCount = (texCoords.count / 2) * 2
            vertexData.texCoords = stride(from: 0, to: texCoordCount, by: 2).map { i in
                SIMD2<Float>(texCoords[i], texCoords[i+1])
            }
            primitive.hasTexCoords = true
        }

        if let colorAccessorIndex = gltfPrimitive.attributes["COLOR_0"] {
            let colors = try bufferLoader.loadAccessorAsFloat(colorAccessorIndex)
            let colorCount = (colors.count / 4) * 4
            vertexData.colors = stride(from: 0, to: colorCount, by: 4).map { i in
                SIMD4<Float>(colors[i], colors[i+1], colors[i+2], colors[i+3])
            }
            primitive.hasColors = true
        }

        if let jointsAccessorIndex = gltfPrimitive.attributes["JOINTS_0"] {
            let joints = try bufferLoader.loadAccessorAsUInt32(jointsAccessorIndex)
            let jointCount = (joints.count / 4) * 4
            vertexData.joints = stride(from: 0, to: jointCount, by: 4).map { i in
                SIMD4<UInt16>(UInt16(joints[i]), UInt16(joints[i+1]), UInt16(joints[i+2]), UInt16(joints[i+3]))
            }

            // Compute required palette size from actual joint indices
            let maxJoint = joints.max() ?? 0
            primitive.requiredPaletteSize = Int(maxJoint) + 1
            primitive.hasJoints = true

            vrmLog("[VRMPrimitive] JOINTS_0 loaded: \(jointCount/4) vertices, maxJoint=\(maxJoint), requiredPalette=\(primitive.requiredPaletteSize)")
        }

        if let weightsAccessorIndex = gltfPrimitive.attributes["WEIGHTS_0"] {
            let weights = try bufferLoader.loadAccessorAsFloat(weightsAccessorIndex)
            let weightCount = (weights.count / 4) * 4
            vertexData.weights = stride(from: 0, to: weightCount, by: 4).map { i in
                SIMD4<Float>(weights[i], weights[i+1], weights[i+2], weights[i+3])
            }
            primitive.hasWeights = true
        }

        // Create the single, correctly formatted vertex buffer
        if let device = device {
            let vertices = vertexData.interleaved()
            if !vertices.isEmpty {
                primitive.vertexBuffer = device.makeBuffer(
                    bytes: vertices,
                    length: vertices.count * MemoryLayout<VRMVertex>.stride,
                    options: .storageModeShared
                )
            }
        }

        // Load morph targets (which depend on the vertex buffer being created)
        if let gltfTargets = gltfPrimitive.targets {
            // ... (morph target loading remains the same)
            for (targetIndex, target) in gltfTargets.enumerated() {
                var morphTarget = VRMMorphTarget(name: "target_\(targetIndex)")
                if let positionAccessor = target.position {
                    let deltaPositions = try bufferLoader.loadAccessorAsFloat(positionAccessor)
                    let deltaCount = (deltaPositions.count / 3) * 3
                    morphTarget.positionDeltas = stride(from: 0, to: deltaCount, by: 3).map { i in
                        SIMD3<Float>(deltaPositions[i], deltaPositions[i+1], deltaPositions[i+2])
                    }
                }
                if let normalAccessor = target.normal {
                    let deltaNormals = try bufferLoader.loadAccessorAsFloat(normalAccessor)
                    let deltaCount = (deltaNormals.count / 3) * 3
                    morphTarget.normalDeltas = stride(from: 0, to: deltaCount, by: 3).map { i in
                        SIMD3<Float>(deltaNormals[i], deltaNormals[i+1], deltaNormals[i+2])
                    }
                }
                primitive.morphTargets.append(morphTarget)
            }
            if !primitive.morphTargets.isEmpty, let device = device {
                primitive.createMorphTargetBuffers(device: device)
            }
        }

        // Load indices (remains the same, creates a new packed buffer)
        if let indicesAccessorIndex = gltfPrimitive.indices {
            let accessor = document.accessors?[safe: indicesAccessorIndex]
            let indices = try bufferLoader.loadAccessorAsUInt32(indicesAccessorIndex)

            primitive.indexCount = indices.count
            primitive.indexBufferOffset = 0 // Always 0 for newly created buffers

            if let device = device {
                if accessor?.componentType == 5125 { // UNSIGNED_INT
                    primitive.indexType = .uint32
                    primitive.indexBuffer = device.makeBuffer(
                        bytes: indices,
                        length: indices.count * MemoryLayout<UInt32>.stride,
                        options: .storageModeShared
                    )
                } else { // UNSIGNED_SHORT or UNSIGNED_BYTE
                    primitive.indexType = .uint16
                    let uint16Indices = indices.map { UInt16($0) }
                    primitive.indexBuffer = device.makeBuffer(
                        bytes: uint16Indices,
                        length: uint16Indices.count * MemoryLayout<UInt16>.stride,
                        options: .storageModeShared
                    )
                }
            }
        }

        return primitive
    }

    // MARK: - Index/Accessor Consistency Audit

    public func auditIndexConsistency(meshIndex: Int, primitiveIndex: Int, materialName: String? = nil) -> Bool {
        let isFaceMaterial = materialName?.lowercased().contains("face") ?? false

        vrmLog("\n[INDEX AUDIT] Mesh \(meshIndex), Primitive \(primitiveIndex), Material: \(materialName ?? "unknown")")
        if isFaceMaterial {
            vrmLog("  🎭 FACE MATERIAL DETECTED - Special attention needed!")
        }

        var hasErrors = false

        // 1. Check vertex count
        vrmLog("  - Vertex count: \(vertexCount)")
        if vertexCount == 0 {
            vrmLog("    ❌ ERROR: Zero vertices!")
            hasErrors = true
        }

        // 2. Check index buffer
        guard let indexBuffer = indexBuffer else {
            vrmLog("  - No index buffer (non-indexed primitive)")
            return !hasErrors
        }

        vrmLog("  - Index count: \(indexCount)")
        vrmLog("  - Index type: \(indexType == .uint32 ? "uint32" : "uint16")")
        vrmLog("  - Index buffer offset: \(indexBufferOffset)")

        // 3. Calculate max index by scanning buffer
        let indexStride = (indexType == .uint32) ? 4 : 2
        var maxIndex: UInt32 = 0

        if indexType == .uint32 {
            let indexPointer = indexBuffer.contents().assumingMemoryBound(to: UInt32.self)
            for i in 0..<indexCount {
                let index = indexPointer[i]
                maxIndex = max(maxIndex, index)
            }
        } else {
            let indexPointer = indexBuffer.contents().assumingMemoryBound(to: UInt16.self)
            for i in 0..<indexCount {
                let index = UInt32(indexPointer[i])
                maxIndex = max(maxIndex, index)
            }
        }

        vrmLog("  - Max index found: \(maxIndex)")

        // 4. Assert: maxIndex < vertexCount
        if maxIndex >= vertexCount {
            vrmLog("    ❌ ERROR: Max index (\(maxIndex)) >= vertex count (\(vertexCount))!")
            vrmLog("    This will cause out-of-bounds vertex access!")
            hasErrors = true
        } else {
            vrmLog("    ✅ Index bounds OK: max index < vertex count")
        }

        // 5. Assert: index buffer offset alignment
        if indexBufferOffset % indexStride != 0 {
            vrmLog("    ❌ ERROR: Index buffer offset (\(indexBufferOffset)) not aligned to stride (\(indexStride))!")
            hasErrors = true
        } else {
            vrmLog("    ✅ Index offset alignment OK")
        }

        // 6. Assert: index buffer bounds
        let indexDataSize = indexCount * indexStride
        let totalSize = indexBufferOffset + indexDataSize
        if totalSize > indexBuffer.length {
            vrmLog("    ❌ ERROR: Index data exceeds buffer!")
            vrmLog("      Offset: \(indexBufferOffset), Data size: \(indexDataSize), Buffer size: \(indexBuffer.length)")
            hasErrors = true
        } else {
            vrmLog("    ✅ Index buffer bounds OK")
        }

        // 7. Check for degenerate triangles (if triangle primitive)
        if primitiveType == .triangle && indexCount >= 3 {
            var degenerateCount = 0
            let indices: [UInt32]

            if indexType == .uint32 {
                let indexPointer = indexBuffer.contents().assumingMemoryBound(to: UInt32.self)
                indices = Array(UnsafeBufferPointer(start: indexPointer, count: indexCount))
            } else {
                let indexPointer = indexBuffer.contents().assumingMemoryBound(to: UInt16.self)
                indices = (0..<indexCount).map { UInt32(indexPointer[$0]) }
            }

            for i in stride(from: 0, to: indexCount - 2, by: 3) {
                let i0 = indices[i]
                let i1 = indices[i + 1]
                let i2 = indices[i + 2]

                if i0 == i1 || i1 == i2 || i0 == i2 {
                    degenerateCount += 1
                    if degenerateCount <= 5 {  // Only log first few
                        vrmLog("    ⚠️ Degenerate triangle at index \(i): [\(i0), \(i1), \(i2)]")
                    }
                }
            }

            if degenerateCount > 0 {
                vrmLog("    ⚠️ WARNING: Found \(degenerateCount) degenerate triangles")
            }
        }

        // Additional checks for face primitives
        if isFaceMaterial && vertexBuffer != nil {
            vrmLog("\n  🎭 FACE PRIMITIVE ANALYSIS:")

            // Check if this primitive has morph targets (faces usually do)
            vrmLog("    - Morph targets: \(morphTargets.count)")
            vrmLog("    - Has normals: \(hasNormals)")
            vrmLog("    - Has tex coords: \(hasTexCoords)")
            vrmLog("    - Has colors: \(hasColors)")

            // Sample first few vertices to check for anomalies
            if let buffer = vertexBuffer {
                let vertices = buffer.contents().bindMemory(to: VRMVertex.self, capacity: min(5, vertexCount))
                vrmLog("    - First 5 vertices (or less):")
                for i in 0..<min(5, vertexCount) {
                    let v = vertices[i]
                    let uvOK = v.texCoord.x >= -0.1 && v.texCoord.x <= 1.1 &&
                              v.texCoord.y >= -0.1 && v.texCoord.y <= 1.1
                    vrmLog("      [\(i)] pos=(\(v.position.x), \(v.position.y), \(v.position.z)), " +
                          "uv=(\(v.texCoord.x), \(v.texCoord.y)) \(uvOK ? "✅" : "⚠️ UV OUT OF RANGE")")

                    if !uvOK {
                        vrmLog("        ⚠️ WARNING: UV coordinates out of expected range!")
                        hasErrors = true
                    }
                }
            }

            // Debug: Check indices for the wedge artifact
            vrmLog("\n    - Index analysis for wedge detection:")
            // indexBuffer already unwrapped above at line 485, so we can use it directly
            let ptr = indexBuffer.contents()
            if indexType == .uint32 {
                    let indices = ptr.bindMemory(to: UInt32.self, capacity: min(30, indexCount))
                    vrmLog("      First 10 triangles (uint32):")
                    for i in stride(from: 0, to: min(30, indexCount), by: 3) {
                        if i+2 < indexCount {
                            let v0 = indices[i]
                            let v1 = indices[i+1]
                            let v2 = indices[i+2]
                            let maxIdx = max(v0, v1, v2)
                            let spread1 = abs(Int(v0) - Int(v1))
                            let spread2 = abs(Int(v1) - Int(v2))
                            let spread3 = abs(Int(v0) - Int(v2))
                            let spread = max(spread1, spread2, spread3)
                            vrmLog("        Tri[\(i/3)]: \(v0), \(v1), \(v2) (max=\(maxIdx), spread=\(spread))")
                            if maxIdx >= vertexCount {
                                vrmLog("          ⚠️ INDEX OUT OF BOUNDS! (vertexCount=\(vertexCount))")
                            }
                            if spread > 500 {
                                vrmLog("          ⚠️ LARGE TRIANGLE SPREAD - potential wedge source!")
                            }
                        }
                    }
                } else if indexType == .uint16 {
                    let indices = ptr.bindMemory(to: UInt16.self, capacity: min(30, indexCount))
                    vrmLog("      First 10 triangles (uint16):")
                    for i in stride(from: 0, to: min(30, indexCount), by: 3) {
                        if i+2 < indexCount {
                            let v0 = indices[i]
                            let v1 = indices[i+1]
                            let v2 = indices[i+2]
                            let maxIdx = max(v0, v1, v2)
                            let spread1 = abs(Int(v0) - Int(v1))
                            let spread2 = abs(Int(v1) - Int(v2))
                            let spread3 = abs(Int(v0) - Int(v2))
                            let spread = max(spread1, spread2, spread3)
                            vrmLog("        Tri[\(i/3)]: \(v0), \(v1), \(v2) (max=\(maxIdx), spread=\(spread))")
                            if maxIdx >= vertexCount {
                                vrmLog("          ⚠️ INDEX OUT OF BOUNDS! (vertexCount=\(vertexCount))")
                            }
                            if spread > 500 {
                                vrmLog("          ⚠️ LARGE TRIANGLE SPREAD - potential wedge source!")
                            }
                        }
                    }
                }
            }

        return !hasErrors
    }

    // Create GPU buffers for morph targets
    public func createMorphTargetBuffers(device: MTLDevice) {
        morphPositionBuffers.removeAll()
        morphNormalBuffers.removeAll()
        morphTangentBuffers.removeAll()

        for target in morphTargets {
            // Create position delta buffer
            if let positionDeltas = target.positionDeltas {
                let bufferSize = positionDeltas.count * MemoryLayout<SIMD3<Float>>.stride
                if let buffer = device.makeBuffer(bytes: positionDeltas, length: bufferSize, options: .storageModeShared) {
                    morphPositionBuffers.append(buffer)
                }
            }

            // Create normal delta buffer
            if let normalDeltas = target.normalDeltas {
                let bufferSize = normalDeltas.count * MemoryLayout<SIMD3<Float>>.stride
                if let buffer = device.makeBuffer(bytes: normalDeltas, length: bufferSize, options: .storageModeShared) {
                    morphNormalBuffers.append(buffer)
                }
            }

            // Create tangent delta buffer
            if let tangentDeltas = target.tangentDeltas {
                let bufferSize = tangentDeltas.count * MemoryLayout<SIMD3<Float>>.stride
                if let buffer = device.makeBuffer(bytes: tangentDeltas, length: bufferSize, options: .storageModeShared) {
                    morphTangentBuffers.append(buffer)
                }
            }
        }

        vrmLog("[VRMPrimitive] Created GPU buffers for \(morphTargets.count) morph targets")
        vrmLog("  - Position buffers: \(morphPositionBuffers.count)")
        vrmLog("  - Normal buffers: \(morphNormalBuffers.count)")
        vrmLog("  - Tangent buffers: \(morphTangentBuffers.count)")

        // Create SoA buffers for compute path if we have morph targets
        createSoAMorphBuffers(device: device)
    }

    /// Create Structure-of-Arrays morph buffers for efficient GPU compute
    private func createSoAMorphBuffers(device: MTLDevice) {
        guard !morphTargets.isEmpty, vertexCount > 0 else { return }

        // Create base position buffer from vertex data
        if let vertexBuffer = vertexBuffer {
            // Extract positions from interleaved vertex buffer
            let vertexPointer = vertexBuffer.contents().bindMemory(to: VRMVertex.self, capacity: vertexCount)

            // Create base positions buffer
            let basePositionsSize = vertexCount * MemoryLayout<SIMD3<Float>>.stride
            basePositionsBuffer = device.makeBuffer(length: basePositionsSize, options: .storageModeShared)

            if let baseBuffer = basePositionsBuffer {
                let basePointer = baseBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: vertexCount)
                for i in 0..<vertexCount {
                    basePointer[i] = vertexPointer[i].position
                }
            }

            // Create base normals buffer if we have normals
            if hasNormals {
                let baseNormalsSize = vertexCount * MemoryLayout<SIMD3<Float>>.stride
                baseNormalsBuffer = device.makeBuffer(length: baseNormalsSize, options: .storageModeShared)

                if let normalsBuffer = baseNormalsBuffer {
                    let normalsPointer = normalsBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: vertexCount)
                    for i in 0..<vertexCount {
                        normalsPointer[i] = vertexPointer[i].normal
                    }
                }
            }
        }

        // Create SoA morph deltas buffer
        let morphCount = morphTargets.count
        let totalDeltasSize = morphCount * vertexCount * MemoryLayout<SIMD3<Float>>.stride

        // Position deltas SoA
        morphPositionsSoA = device.makeBuffer(length: totalDeltasSize, options: .storageModeShared)
        if let soaBuffer = morphPositionsSoA {
            let soaPointer = soaBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: morphCount * vertexCount)

            // Copy morph deltas in SoA layout
            for (morphIdx, morphTarget) in morphTargets.enumerated() {
                let baseOffset = morphIdx * vertexCount
                if let deltas = morphTarget.positionDeltas {
                    let deltaCount = min(deltas.count, vertexCount)
                    for vertexIdx in 0..<deltaCount {
                        soaPointer[baseOffset + vertexIdx] = deltas[vertexIdx]
                    }
                    // Fill remaining with zeros if deltas are shorter than vertexCount
                    for vertexIdx in deltaCount..<vertexCount {
                        soaPointer[baseOffset + vertexIdx] = SIMD3<Float>(0, 0, 0)
                    }
                } else {
                    // Fill with zeros if no deltas
                    for vertexIdx in 0..<vertexCount {
                        soaPointer[baseOffset + vertexIdx] = SIMD3<Float>(0, 0, 0)
                    }
                }
            }
        }

        // Normal deltas SoA (if we have normals)
        if hasNormals {
            morphNormalsSoA = device.makeBuffer(length: totalDeltasSize, options: .storageModeShared)
            if let soaBuffer = morphNormalsSoA {
                let soaPointer = soaBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: morphCount * vertexCount)

                for (morphIdx, morphTarget) in morphTargets.enumerated() {
                    let baseOffset = morphIdx * vertexCount
                    if let deltas = morphTarget.normalDeltas {
                        let deltaCount = min(deltas.count, vertexCount)
                        for vertexIdx in 0..<deltaCount {
                            soaPointer[baseOffset + vertexIdx] = deltas[vertexIdx]
                        }
                        // Fill remaining with zeros if deltas are shorter than vertexCount
                        for vertexIdx in deltaCount..<vertexCount {
                            soaPointer[baseOffset + vertexIdx] = SIMD3<Float>(0, 0, 0)
                        }
                    } else {
                        for vertexIdx in 0..<vertexCount {
                            soaPointer[baseOffset + vertexIdx] = SIMD3<Float>(0, 0, 0)
                        }
                    }
                }
            }
        }

        vrmLog("[VRMPrimitive] Created SoA morph buffers:")
        vrmLog("  - Base positions buffer: \(basePositionsBuffer != nil)")
        vrmLog("  - Base normals buffer: \(baseNormalsBuffer != nil)")
        vrmLog("  - SoA positions buffer: \(morphPositionsSoA != nil) (\(totalDeltasSize) bytes)")
        vrmLog("  - SoA normals buffer: \(morphNormalsSoA != nil)")
    }
}

// MARK: - Vertex Data

struct VertexData {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var texCoords: [SIMD2<Float>] = []
    var colors: [SIMD4<Float>] = []
    var tangents: [SIMD4<Float>] = []
    var joints: [SIMD4<UInt16>] = []
    var weights: [SIMD4<Float>] = []

    func interleaved() -> [VRMVertex] {
        var vertices: [VRMVertex] = []

        for i in 0..<positions.count {
            var vertex = VRMVertex()

            vertex.position = positions[i]

            if i < normals.count {
                vertex.normal = normals[i]
            }

            if i < texCoords.count {
                vertex.texCoord = texCoords[i]
            }

            if i < colors.count {
                vertex.color = colors[i]
            }

            if i < joints.count {
                vertex.joints = joints[i]
            }

            if i < weights.count {
                vertex.weights = weights[i]
            }

            vertices.append(vertex)
        }

        return vertices
    }
}

// MARK: - Vertex Structure

public struct VRMVertex {
    public var position: SIMD3<Float> = [0, 0, 0]
    public var normal: SIMD3<Float> = [0, 1, 0]
    public var texCoord: SIMD2<Float> = [0, 0]
    public var color: SIMD4<Float> = [1, 1, 1, 1]
    public var joints: SIMD4<UInt16> = [0, 0, 0, 0]
    public var weights: SIMD4<Float> = [1, 0, 0, 0]
}

// MARK: - Helper Types

enum AccessorType {
    case scalar
    case vec2
    case vec3
    case vec4
    case mat2
    case mat3
    case mat4

    var componentCount: Int {
        switch self {
        case .scalar: return 1
        case .vec2: return 2
        case .vec3: return 3
        case .vec4: return 4
        case .mat2: return 4
        case .mat3: return 9
        case .mat4: return 16
        }
    }
}

extension MTLPrimitiveType {
    init(gltfMode: Int) {
        switch gltfMode {
        case 0: self = .point
        case 1: self = .line
        case 2: self = .lineStrip
        case 3: self = .lineStrip // LINE_LOOP not directly supported
        case 4: self = .triangle
        case 5: self = .triangleStrip
        case 6: self = .triangleStrip // TRIANGLE_FAN not directly supported
        default: self = .triangle
        }
    }
}

// MARK: - Metal Format Mapping

extension VRMPrimitive {
    static func metalVertexFormat(componentType: Int, accessorType: String, normalized: Bool = false) -> MTLVertexFormat? {
        switch (componentType, accessorType, normalized) {
        // FLOAT (5126)
        case (5126, "SCALAR", _): return .float
        case (5126, "VEC2", _): return .float2
        case (5126, "VEC3", _): return .float3
        case (5126, "VEC4", _): return .float4

        // UNSIGNED_BYTE (5121)
        case (5121, "SCALAR", false): return .uchar
        case (5121, "SCALAR", true): return .ucharNormalized
        case (5121, "VEC2", false): return .uchar2
        case (5121, "VEC2", true): return .uchar2Normalized
        case (5121, "VEC3", false): return .uchar3
        case (5121, "VEC3", true): return .uchar3Normalized
        case (5121, "VEC4", false): return .uchar4
        case (5121, "VEC4", true): return .uchar4Normalized

        // UNSIGNED_SHORT (5123)
        case (5123, "SCALAR", false): return .ushort
        case (5123, "SCALAR", true): return .ushortNormalized
        case (5123, "VEC2", false): return .ushort2
        case (5123, "VEC2", true): return .ushort2Normalized
        case (5123, "VEC3", false): return .ushort3
        case (5123, "VEC3", true): return .ushort3Normalized
        case (5123, "VEC4", false): return .ushort4
        case (5123, "VEC4", true): return .ushort4Normalized

        // BYTE (5120)
        case (5120, "SCALAR", false): return .char
        case (5120, "SCALAR", true): return .charNormalized
        case (5120, "VEC2", false): return .char2
        case (5120, "VEC2", true): return .char2Normalized
        case (5120, "VEC3", false): return .char3
        case (5120, "VEC3", true): return .char3Normalized
        case (5120, "VEC4", false): return .char4
        case (5120, "VEC4", true): return .char4Normalized

        // SHORT (5122)
        case (5122, "SCALAR", false): return .short
        case (5122, "SCALAR", true): return .shortNormalized
        case (5122, "VEC2", false): return .short2
        case (5122, "VEC2", true): return .short2Normalized
        case (5122, "VEC3", false): return .short3
        case (5122, "VEC3", true): return .short3Normalized
        case (5122, "VEC4", false): return .short4
        case (5122, "VEC4", true): return .short4Normalized

        default:
            vrmLog("[VRMPrimitive] Unsupported format: componentType=\(componentType), type=\(accessorType), normalized=\(normalized)")
            return nil
        }
    }

    static func bytesPerComponent(_ componentType: Int) -> Int {
        switch componentType {
        case 5120, 5121: return 1  // BYTE, UNSIGNED_BYTE
        case 5122, 5123: return 2  // SHORT, UNSIGNED_SHORT
        case 5125, 5126: return 4  // UNSIGNED_INT, FLOAT
        default: return 4
        }
    }

    static func componentCount(for type: String) -> Int {
        switch type {
        case "SCALAR": return 1
        case "VEC2": return 2
        case "VEC3": return 3
        case "VEC4": return 4
        case "MAT2": return 4
        case "MAT3": return 9
        case "MAT4": return 16
        default: return 1
        }
    }
}

// MARK: - VRM Node

public class VRMNode {
    public let index: Int
    public let name: String?
    public var parent: VRMNode?
    public var children: [VRMNode] = []

    // Transform components
    public var translation: SIMD3<Float> = [0, 0, 0]
    public var rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    public var scale: SIMD3<Float> = [1, 1, 1]

    // Computed transforms
    public var localMatrix: float4x4 = matrix_identity_float4x4
    public var worldMatrix: float4x4 = matrix_identity_float4x4

    // Computed properties for SpringBone
    public var worldPosition: SIMD3<Float> {
        return SIMD3<Float>(worldMatrix[3][0], worldMatrix[3][1], worldMatrix[3][2])
    }

    public var localRotation: simd_quatf {
        get { return rotation }
        set {
            rotation = newValue
            updateLocalMatrix()
        }
    }

    // References
    public var mesh: Int?
    public var skin: Int?

    public init(index: Int, gltfNode: GLTFNode) {
        self.index = index
        self.name = gltfNode.name
        self.mesh = gltfNode.mesh
        self.skin = gltfNode.skin

        // Parse transform
        if let matrix = gltfNode.matrix, matrix.count == 16 {
            // vrmLog("[NODE INIT] Node '\(name ?? "unnamed")' has matrix: \(matrix)")
            // GLTF matrices are stored in column-major order
            // Swift float4x4 init takes rows, so we need to transpose
            localMatrix = float4x4(
                SIMD4<Float>(matrix[0], matrix[4], matrix[8], matrix[12]),   // row 0
                SIMD4<Float>(matrix[1], matrix[5], matrix[9], matrix[13]),   // row 1
                SIMD4<Float>(matrix[2], matrix[6], matrix[10], matrix[14]),  // row 2
                SIMD4<Float>(matrix[3], matrix[7], matrix[11], matrix[15])   // row 3 (translation)
            )
            // vrmLog("[NODE INIT] Resulting localMatrix translation: (\(localMatrix[3][0]), \(localMatrix[3][1]), \(localMatrix[3][2]))")
        } else {
            if let t = gltfNode.translation, t.count == 3 {
                translation = SIMD3<Float>(t[0], t[1], t[2])
            }
            if let r = gltfNode.rotation, r.count == 4 {
                rotation = simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3])
            }
            if let s = gltfNode.scale, s.count == 3 {
                scale = SIMD3<Float>(s[0], s[1], s[2])
            }
            // if hadTransform {
            //     vrmLog("[NODE INIT] Node '\(name ?? "unnamed")' T:\(translation), R:\(rotation), S:\(scale)")
            // }
            updateLocalMatrix()
        }
    }

    public func updateLocalMatrix() {
        let t = float4x4(translation: translation)
        
        // Manual quaternion to matrix conversion (Column-Major)
        let x = rotation.imag.x
        let y = rotation.imag.y
        let z = rotation.imag.z
        let w = rotation.real
        
        let xx = x * x
        let yy = y * y
        let zz = z * z
        let xy = x * y
        let xz = x * z
        let yz = y * z
        let wx = w * x
        let wy = w * y
        let wz = w * z

        let col0 = SIMD4<Float>(1.0 - 2.0 * (yy + zz), 2.0 * (xy + wz), 2.0 * (xz - wy), 0.0)
        let col1 = SIMD4<Float>(2.0 * (xy - wz), 1.0 - 2.0 * (xx + zz), 2.0 * (yz + wx), 0.0)
        let col2 = SIMD4<Float>(2.0 * (xz + wy), 2.0 * (yz - wx), 1.0 - 2.0 * (xx + yy), 0.0)
        let col3 = SIMD4<Float>(0.0, 0.0, 0.0, 1.0)
        
        let r = float4x4([col0, col1, col2, col3])

        let s = float4x4(scaling: scale)
        localMatrix = t * r * s
    }

    public func updateWorldTransform() {
        // Check for NaNs before using localMatrix
        if localMatrix[0][0].isNaN || localMatrix[0][1].isNaN || localMatrix[0][2].isNaN || localMatrix[0][3].isNaN ||
           localMatrix[1][0].isNaN || localMatrix[1][1].isNaN || localMatrix[1][2].isNaN || localMatrix[1][3].isNaN ||
           localMatrix[2][0].isNaN || localMatrix[2][1].isNaN || localMatrix[2][2].isNaN || localMatrix[2][3].isNaN ||
           localMatrix[3][0].isNaN || localMatrix[3][1].isNaN || localMatrix[3][2].isNaN || localMatrix[3][3].isNaN {
            vrmLogAnimation("!!! CRITICAL ERROR: NaN detected in localMatrix for node \(name ?? "unnamed") BEFORE world transform update")
            // Optionally, reset localMatrix to identity to prevent crash
            localMatrix = matrix_identity_float4x4
        }

        if let parent = parent {
            worldMatrix = parent.worldMatrix * localMatrix
        } else {
            worldMatrix = localMatrix
        }

        for child in children {
            child.updateWorldTransform()
        }
    }
}

// MARK: - VRM Skin

public class VRMSkin {
    public let name: String?
    public var joints: [VRMNode] = []
    public var inverseBindMatrices: [float4x4] = []
    public var skeleton: VRMNode?

    // Buffer offset management for efficient multi-skin rendering
    public var bufferByteOffset: Int = 0  // Byte offset in the large joint buffer
    public var matrixOffset: Int = 0      // Matrix count offset (bufferByteOffset / sizeof(float4x4))

    public init(from gltfSkin: GLTFSkin, nodes: [VRMNode], document: GLTFDocument, bufferLoader: BufferLoader) throws {
        self.name = gltfSkin.name

        // Get joint nodes
        for jointIndex in gltfSkin.joints {
            if jointIndex < nodes.count {
                joints.append(nodes[jointIndex])
            }
        }

        // Get skeleton root
        if let skeletonIndex = gltfSkin.skeleton, skeletonIndex < nodes.count {
            skeleton = nodes[skeletonIndex]
        }

        // Load inverse bind matrices
        if let inverseBindMatricesIndex = gltfSkin.inverseBindMatrices {
            // Load actual inverse bind matrices from accessor
            do {
                inverseBindMatrices = try bufferLoader.loadAccessorAsMatrix4x4(inverseBindMatricesIndex)
                vrmLog("[VRMSkin] Loaded \(inverseBindMatrices.count) inverse bind matrices from accessor \(inverseBindMatricesIndex)")
            } catch {
                vrmLog("[VRMSkin] Failed to load inverse bind matrices: \(error), using identity matrices")
                inverseBindMatrices = Array(repeating: matrix_identity_float4x4, count: joints.count)
            }
        } else {
            // Use identity matrices if not specified
            vrmLog("[VRMSkin] No inverse bind matrices specified, using identity matrices")
            inverseBindMatrices = Array(repeating: matrix_identity_float4x4, count: joints.count)
        }
    }
}

// MARK: - VRM Texture

public class VRMTexture {
    public var mtlTexture: MTLTexture?
    public var sampler: MTLSamplerState?
    public let name: String?

    public init(name: String? = nil, mtlTexture: MTLTexture? = nil) {
        self.name = name
        self.mtlTexture = mtlTexture
    }
}

// MARK: - VRM Material

public class VRMMaterial {
    public let name: String?
    public var baseColorFactor: SIMD4<Float> = [1, 1, 1, 1]
    public var baseColorTexture: VRMTexture?
    public var metallicFactor: Float = 0.0
    public var roughnessFactor: Float = 1.0
    public var emissiveFactor: SIMD3<Float> = [0, 0, 0]
    public var doubleSided: Bool = false
    public var alphaMode: String = "OPAQUE"
    public var alphaCutoff: Float = 0.5

    // MToon properties
    public var mtoon: VRMMToonMaterial?

    public init(from gltfMaterial: GLTFMaterial, textures: [VRMTexture]) {
        self.name = gltfMaterial.name

        if let pbr = gltfMaterial.pbrMetallicRoughness {
            if let baseColor = pbr.baseColorFactor, baseColor.count == 4 {
                baseColorFactor = SIMD4<Float>(baseColor[0], baseColor[1], baseColor[2], baseColor[3])
            }
            metallicFactor = pbr.metallicFactor ?? 0.0
            roughnessFactor = pbr.roughnessFactor ?? 1.0

            if let textureIndex = pbr.baseColorTexture?.index, textureIndex < textures.count {
                baseColorTexture = textures[textureIndex]
            }
        }

        if let emissive = gltfMaterial.emissiveFactor, emissive.count == 3 {
            emissiveFactor = SIMD3<Float>(emissive[0], emissive[1], emissive[2])
        }

        doubleSided = gltfMaterial.doubleSided ?? false
        alphaMode = gltfMaterial.alphaMode ?? "OPAQUE"
        alphaCutoff = gltfMaterial.alphaCutoff ?? 0.5

        // Parse MToon extension if present
        if let extensions = gltfMaterial.extensions,
           let mtoonExt = extensions["VRMC_materials_mtoon"] as? [String: Any] {
            mtoon = parseMToonExtension(mtoonExt, textures: textures)
        }
    }

    private func parseMToonExtension(_ mtoonExt: [String: Any], textures: [VRMTexture]) -> VRMMToonMaterial {
        var mtoon = VRMMToonMaterial()

        // Shade color factor
        if let shadeColorFactor = mtoonExt["shadeColorFactor"] as? [Double], shadeColorFactor.count >= 3 {
            mtoon.shadeColorFactor = SIMD3<Float>(Float(shadeColorFactor[0]),
                                                  Float(shadeColorFactor[1]),
                                                  Float(shadeColorFactor[2]))
        }

        // Shading properties
        if let shadingToonyFactor = mtoonExt["shadingToonyFactor"] as? Double {
            mtoon.shadingToonyFactor = Float(shadingToonyFactor)
        }
        if let shadingShiftFactor = mtoonExt["shadingShiftFactor"] as? Double {
            mtoon.shadingShiftFactor = Float(shadingShiftFactor)
        }

        // Global illumination
        if let giIntensityFactor = mtoonExt["giIntensityFactor"] as? Double {
            mtoon.giIntensityFactor = Float(giIntensityFactor)
        }

        // MatCap properties
        if let matcapFactor = mtoonExt["matcapFactor"] as? [Double], matcapFactor.count >= 3 {
            mtoon.matcapFactor = SIMD3<Float>(Float(matcapFactor[0]),
                                              Float(matcapFactor[1]),
                                              Float(matcapFactor[2]))
        }

        // Parametric rim lighting
        if let parametricRimColorFactor = mtoonExt["parametricRimColorFactor"] as? [Double], parametricRimColorFactor.count >= 3 {
            mtoon.parametricRimColorFactor = SIMD3<Float>(Float(parametricRimColorFactor[0]),
                                                          Float(parametricRimColorFactor[1]),
                                                          Float(parametricRimColorFactor[2]))
        }
        if let parametricRimFresnelPowerFactor = mtoonExt["parametricRimFresnelPowerFactor"] as? Double {
            mtoon.parametricRimFresnelPowerFactor = Float(parametricRimFresnelPowerFactor)
        }
        if let parametricRimLiftFactor = mtoonExt["parametricRimLiftFactor"] as? Double {
            mtoon.parametricRimLiftFactor = Float(parametricRimLiftFactor)
        }
        if let rimLightingMixFactor = mtoonExt["rimLightingMixFactor"] as? Double {
            mtoon.rimLightingMixFactor = Float(rimLightingMixFactor)
        }

        // Outline properties
        if let outlineWidthMode = mtoonExt["outlineWidthMode"] as? String {
            mtoon.outlineWidthMode = VRMOutlineWidthMode(rawValue: outlineWidthMode) ?? .none
        }
        if let outlineWidthFactor = mtoonExt["outlineWidthFactor"] as? Double {
            mtoon.outlineWidthFactor = Float(outlineWidthFactor)
        }
        if let outlineColorFactor = mtoonExt["outlineColorFactor"] as? [Double], outlineColorFactor.count >= 3 {
            mtoon.outlineColorFactor = SIMD3<Float>(Float(outlineColorFactor[0]),
                                                    Float(outlineColorFactor[1]),
                                                    Float(outlineColorFactor[2]))
        }
        if let outlineLightingMixFactor = mtoonExt["outlineLightingMixFactor"] as? Double {
            mtoon.outlineLightingMixFactor = Float(outlineLightingMixFactor)
        }

        // UV Animation properties
        if let uvAnimationScrollXSpeedFactor = mtoonExt["uvAnimationScrollXSpeedFactor"] as? Double {
            mtoon.uvAnimationScrollXSpeedFactor = Float(uvAnimationScrollXSpeedFactor)
        }
        if let uvAnimationScrollYSpeedFactor = mtoonExt["uvAnimationScrollYSpeedFactor"] as? Double {
            mtoon.uvAnimationScrollYSpeedFactor = Float(uvAnimationScrollYSpeedFactor)
        }
        if let uvAnimationRotationSpeedFactor = mtoonExt["uvAnimationRotationSpeedFactor"] as? Double {
            mtoon.uvAnimationRotationSpeedFactor = Float(uvAnimationRotationSpeedFactor)
        }

        // Texture references
        if let shadeMultiplyTexture = mtoonExt["shadeMultiplyTexture"] as? [String: Any],
           let index = shadeMultiplyTexture["index"] as? Int {
            mtoon.shadeMultiplyTexture = index
        }

        // Shading shift texture with scale support
        if let shadingShiftTexture = mtoonExt["shadingShiftTexture"] as? [String: Any],
           let index = shadingShiftTexture["index"] as? Int {
            let texCoord = shadingShiftTexture["texCoord"] as? Int
            let scale = shadingShiftTexture["scale"] as? Double
            mtoon.shadingShiftTexture = VRMShadingShiftTexture(
                index: index,
                texCoord: texCoord,
                scale: scale.map(Float.init)
            )
        }

        // MatCap texture
        if let matcapTexture = mtoonExt["matcapTexture"] as? [String: Any],
           let index = matcapTexture["index"] as? Int {
            mtoon.matcapTexture = index
        }

        // Rim multiply texture
        if let rimMultiplyTexture = mtoonExt["rimMultiplyTexture"] as? [String: Any],
           let index = rimMultiplyTexture["index"] as? Int {
            mtoon.rimMultiplyTexture = index
        }

        // Outline width multiply texture
        if let outlineWidthMultiplyTexture = mtoonExt["outlineWidthMultiplyTexture"] as? [String: Any],
           let index = outlineWidthMultiplyTexture["index"] as? Int {
            mtoon.outlineWidthMultiplyTexture = index
        }

        // UV animation mask texture
        if let uvAnimationMaskTexture = mtoonExt["uvAnimationMaskTexture"] as? [String: Any],
           let index = uvAnimationMaskTexture["index"] as? Int {
            mtoon.uvAnimationMaskTexture = index
        }

        return mtoon
    }
}

// MARK: - Matrix Extensions

extension float4x4 {
    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3.x = t.x
        columns.3.y = t.y
        columns.3.z = t.z
    }

    init(_ quaternion: simd_quatf) {
        self = simd_matrix4x4(quaternion)
    }

    init(scaling s: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.0.x = s.x
        columns.1.y = s.y
        columns.2.z = s.z
    }
}
