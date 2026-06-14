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

/// Read-only inputs for loading a single primitive, bundled so they can cross a
/// task boundary. `@unchecked Sendable` is sound because the glTF document and
/// buffer loader are immutable during loading and already shared concurrently by
/// the across-mesh parallel path; the wrapper only launders their non-Sendable
/// (cross-module) types past Swift 6 region isolation.
private struct PrimitiveLoadJob: @unchecked Sendable {
    let index: Int
    let primitive: GLTFPrimitive
    let document: GLTFDocument
    let device: MTLDevice?
    let bufferLoader: BufferLoader
}

/// A renderable mesh: a named container of ``VRMPrimitive`` draw calls.
///
/// VRM meshes are loaded from glTF `meshes` entries. A node references one
/// mesh; rendering iterates each primitive (one draw call per primitive) and
/// applies the per-primitive material.
public class VRMMesh: @unchecked Sendable {
    /// Original glTF mesh name, when present.
    public let name: String?
    /// Per-primitive draw calls owned by this mesh (one draw call per primitive).
    public var primitives: [VRMPrimitive] = []

    /// Creates an empty mesh with the given name. Primitives are appended by ``load(from:document:device:bufferLoader:)``.
    public init(name: String? = nil) {
        self.name = name
    }

    /// Loads a mesh and all of its primitives from a glTF mesh entry.
    ///
    /// Asynchronous because each primitive may load buffer data and create
    /// Metal vertex/index buffers in parallel.
    ///
    /// - Parameters:
    ///   - gltfMesh: Source glTF mesh.
    ///   - document: Parent glTF document used to resolve accessor indices.
    ///   - device: `MTLDevice` for GPU buffer allocation; `nil` is permitted for tests that only need CPU data.
    ///   - bufferLoader: Buffer/accessor loader for the source document.
    /// - Returns: A populated ``VRMMesh``.
    /// - Throws: Any ``VRMError`` raised by primitive loading (missing
    ///   attributes, malformed accessors, allocation failure).
    public static func load(from gltfMesh: GLTFMesh,
                           document: GLTFDocument,
                           device: MTLDevice?,
                           bufferLoader: BufferLoader,
                           concurrencyLimiter: AsyncConcurrencyLimiter? = nil) async throws -> VRMMesh {
        let mesh = VRMMesh(name: gltfMesh.name)
        let primitiveCount = gltfMesh.primitives.count
        vrmLog("[VRMMesh] Loading mesh \(gltfMesh.name ?? "unnamed") with \(primitiveCount) primitives")

        // Decode primitives concurrently. Each VRMPrimitive owns independent CPU/GPU
        // resources, and BufferLoader + the glTF document are already accessed
        // concurrently (and read-only) by the across-mesh parallel path, so
        // intra-mesh parallelism adds no new sharing hazard. The read-only load
        // inputs are laundered through an `@unchecked Sendable` job holder (the same
        // idiom ParallelMeshLoader uses) since GLTFDocument/GLTFPrimitive are not
        // Sendable across modules. Results are reassembled in source order to keep
        // loading deterministic (VRM models are commonly one mesh with many
        // primitives, so this is the dominant load-time win).
        let jobs = gltfMesh.primitives.enumerated().map { index, gltfPrimitive in
            PrimitiveLoadJob(index: index, primitive: gltfPrimitive,
                             document: document, device: device, bufferLoader: bufferLoader)
        }
        // Two complementary, machine-scaled bounds (neither is an arbitrary cap):
        //   1. A per-mesh sliding window sizes how many decode tasks are *created*
        //      at once for this mesh (so a many-primitive mesh doesn't spawn
        //      thousands of tasks). Sized to the core count; Swift's cooperative
        //      pool already runs only core-count tasks in parallel, so this
        //      preserves full throughput.
        //   2. The optional `concurrencyLimiter`, shared across ALL meshes, caps how
        //      many primitive decodes *execute* at once globally. Because this group
        //      is itself run per-mesh inside ParallelMeshLoader's group, the levels
        //      multiply (meshes × primitives); the shared limiter is the true global
        //      bound on peak live memory (intermediate accessor arrays + MTLBuffers).
        //      Only the leaf decode acquires a permit — mesh-orchestration tasks
        //      never do — so the nesting cannot deadlock.
        let maxInFlight = max(1, min(primitiveCount, ProcessInfo.processInfo.activeProcessorCount))
        let ordered = try await withThrowingTaskGroup(of: (Int, VRMPrimitive).self) { group in
            var nextJob = 0
            func addJob(_ job: PrimitiveLoadJob) {
                group.addTask {
                    // If acquire throws (cancellation), no permit was taken, so the
                    // release-balancing do/catch below is intentionally NOT entered.
                    try await concurrencyLimiter?.acquire()
                    do {
                        let primitive = try await VRMPrimitive.load(
                            from: job.primitive,
                            document: job.document,
                            device: job.device,
                            bufferLoader: job.bufferLoader
                        )
                        await concurrencyLimiter?.release()
                        return (job.index, primitive)
                    } catch {
                        await concurrencyLimiter?.release()
                        throw error
                    }
                }
            }
            while nextJob < jobs.count && nextJob < maxInFlight {
                addJob(jobs[nextJob]); nextJob += 1
            }
            var slots = [VRMPrimitive?](repeating: nil, count: primitiveCount)
            for try await (index, primitive) in group {
                slots[index] = primitive
                if nextJob < jobs.count {
                    addJob(jobs[nextJob]); nextJob += 1
                }
            }
            return slots.compactMap { $0 }
        }
        mesh.primitives = ordered

        return mesh
    }
}

// MARK: - VRM Primitive

/// A single draw call within a ``VRMMesh``: one vertex buffer, one optional index buffer, one material.
///
/// ## Discussion
/// `VRMPrimitive` owns all of the per-draw-call GPU resources for a slice of
/// a mesh — interleaved vertices in ``vertexBuffer``, indices (when present)
/// in ``indexBuffer``, morph-target deltas (both per-target AoS buffers and
/// SoA flattened buffers used by the GPU compute path), and first-person
/// per-vertex visibility flags. Attribute presence is exposed through the
/// `has*` Booleans so the renderer can route to the correct pipeline (skinned
/// vs non-skinned, with/without UVs).
///
/// Primitives are loaded from glTF by ``load(from:document:device:bufferLoader:)``.
/// During load, joint indices are sanitised to remove sentinel values
/// (see ``sanitizeJoints(maxJointIndex:)``), and the local-space AABB is
/// captured into ``localMin``/``localMax`` for frustum culling.
public class VRMPrimitive: @unchecked Sendable {
    /// Interleaved vertex buffer in ``VRMVertex`` layout.
    public var vertexBuffer: MTLBuffer?
    /// Index buffer; `nil` for non-indexed primitives.
    public var indexBuffer: MTLBuffer?
    /// Number of vertices in ``vertexBuffer``.
    public var vertexCount: Int = 0
    /// Number of indices in ``indexBuffer`` (or vertices, for non-indexed primitives).
    public var indexCount: Int = 0
    /// Index element type (`.uint16` or `.uint32`).
    public var indexType: MTLIndexType = .uint16
    /// Byte offset into ``indexBuffer`` where this primitive's indices begin (from the source accessor).
    public var indexBufferOffset: Int = 0
    /// `MTLPrimitiveType` produced from the glTF `mode` field (`triangle`, `triangleStrip`, etc.).
    public var primitiveType: MTLPrimitiveType = .triangle
    /// Index into the model's `materials` array, or `nil` for the default material.
    public var materialIndex: Int?

    /// Whether the source defined per-vertex normals.
    public var hasNormals = false
    /// Whether the source defined `TEXCOORD_0` UVs.
    public var hasTexCoords = false
    /// Whether the source defined per-vertex tangents.
    public var hasTangents = false
    /// Whether the source defined per-vertex colors.
    public var hasColors = false
    /// Whether the source defined `JOINTS_0` data (skinning).
    public var hasJoints = false
    /// Whether the source defined `WEIGHTS_0` data (skinning).
    public var hasWeights = false

    /// Minimum joint palette size needed to skin this primitive (`maxJoint + 1` of the `JOINTS_0` data).
    public var requiredPaletteSize: Int = 0

    /// Morph-target CPU data parsed from glTF `primitive.targets`.
    public var morphTargets: [VRMMorphTarget] = []
    /// Per-morph-target position-delta buffers (Array-of-Structures layout, one buffer per target).
    public var morphPositionBuffers: [MTLBuffer] = []
    /// Per-morph-target normal-delta buffers.
    public var morphNormalBuffers: [MTLBuffer] = []
    /// Per-morph-target tangent-delta buffers.
    public var morphTangentBuffers: [MTLBuffer] = []

    /// Structure-of-Arrays position deltas for the GPU compute morph pass.
    /// Layout: `[morph0[v0..vN], morph1[v0..vN], ...]`.
    public var morphPositionsSoA: MTLBuffer?
    /// SoA normal deltas matching ``morphPositionsSoA``.
    public var morphNormalsSoA: MTLBuffer?
    /// Base (rest-pose) positions copied from ``vertexBuffer`` for the compute morph pass.
    public var basePositionsBuffer: MTLBuffer?
    /// Base (rest-pose) normals for the compute morph pass.
    public var baseNormalsBuffer: MTLBuffer?

    /// Local-space AABB minimum corner of base positions (pre-skinning, pre-morph). Set by ``load(from:document:device:bufferLoader:)``.
    public var localMin: SIMD3<Float> = SIMD3<Float>(repeating: 0)
    /// Local-space AABB maximum corner. See ``localMin``.
    public var localMax: SIMD3<Float> = SIMD3<Float>(repeating: 0)

    /// Per-vertex first-person hidden flags. `1` = hidden when ``VRMRenderer/cameraMode`` is `.firstPerson`, `0` = visible.
    /// Populated by `VRMFirstPersonProcessor` for meshes whose annotation resolves to `.auto`.
    public var firstPersonHiddenFlags: [UInt8] = []
    /// GPU buffer mirroring ``firstPersonHiddenFlags``; bound to the vertex shader in first-person mode.
    public var firstPersonHiddenFlagsBuffer: MTLBuffer?

    /// Creates an empty primitive. Use ``load(from:document:device:bufferLoader:)`` to populate from glTF.
    public init() {}

    /// Loads a primitive from a glTF primitive descriptor: vertices, indices, morph targets, and material reference.
    ///
    /// During load, joint indices are sanitised (sentinel values clamped, see
    /// ``sanitizeJoints(maxJointIndex:)``) and the local-space AABB is captured.
    ///
    /// - Parameters:
    ///   - gltfPrimitive: Source primitive entry.
    ///   - document: Parent glTF document used to resolve accessor indices.
    ///   - device: `MTLDevice` for GPU buffer allocation; `nil` skips GPU upload (useful for unit tests).
    ///   - bufferLoader: Buffer/accessor loader bound to the source document.
    /// - Returns: A populated ``VRMPrimitive`` with buffers ready for rendering.
    /// - Throws: ``VRMError`` if required attributes (e.g. `POSITION`) are
    ///   missing or accessor data is malformed.
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
            if !vertexData.positions.isEmpty {
                var lo = vertexData.positions[0]
                var hi = vertexData.positions[0]
                for p in vertexData.positions {
                    lo = simd_min(lo, p)
                    hi = simd_max(hi, p)
                }
                primitive.localMin = lo
                primitive.localMax = hi
            }
        } else {
            throw GLTFError.missingVertexAttribute(
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

            // SANITIZE: Clamp sentinel values (65535, -1, etc.) to prevent vertex explosion
            // VRM models typically have < 256 bones, so anything >= 256 is suspicious
            let maxValidJoint: UInt32 = 255
            var sanitizedCount = 0

            vertexData.joints = stride(from: 0, to: jointCount, by: 4).map { i in
                var j0 = joints[i]
                var j1 = joints[i+1]
                var j2 = joints[i+2]
                var j3 = joints[i+3]

                // Clamp out-of-bounds indices to 0 (root bone)
                if j0 > maxValidJoint { j0 = 0; sanitizedCount += 1 }
                if j1 > maxValidJoint { j1 = 0; sanitizedCount += 1 }
                if j2 > maxValidJoint { j2 = 0; sanitizedCount += 1 }
                if j3 > maxValidJoint { j3 = 0; sanitizedCount += 1 }

                return SIMD4<UInt32>(j0, j1, j2, j3)
            }

            // Compute required palette size from SANITIZED joint indices
            let maxJoint = vertexData.joints.flatMap { [$0.x, $0.y, $0.z, $0.w] }.max() ?? 0
            primitive.requiredPaletteSize = Int(maxJoint) + 1
            primitive.hasJoints = true

            if sanitizedCount > 0 {
                vrmLog("[VRMPrimitive] ⚠️ SANITIZED \(sanitizedCount) out-of-bounds joint indices (sentinel values like 65535)")
            }
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
                primitive.vertexBuffer?.label = "VRM Vertices (mat \(primitive.materialIndex.map(String.init) ?? "—"))"
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
            var indices = try bufferLoader.loadAccessorAsUInt32(indicesAccessorIndex)

            primitive.indexCount = indices.count
            primitive.indexBufferOffset = 0 // Always 0 for newly created buffers

            // Rebase indices to 0 if they're out of bounds (fixes wedge artifacts)
            // This handles glTF files where indices are relative to global buffer views
            if !indices.isEmpty && primitive.vertexCount > 0 {
                let maxIndex = indices.max()!
                if maxIndex >= primitive.vertexCount {
                    let minIndex = indices.min()!
                    // Rebase: subtract minIndex so indices start at 0
                    indices = indices.map { $0 - minIndex }
                    let rebasedMax = indices.max()!
                    if rebasedMax >= primitive.vertexCount {
                        fputs("⚠️ [VRMMetalKit] Index out of bounds after rebasing: maxIndex=\(rebasedMax) >= vertexCount=\(primitive.vertexCount)\n", stderr)
                    }
                }
            }

            if let device = device {
                if accessor?.componentType == 5125 { // UNSIGNED_INT
                    primitive.indexType = .uint32
                    primitive.indexBuffer = device.makeBuffer(
                        bytes: indices,
                        length: indices.count * MemoryLayout<UInt32>.stride,
                        options: .storageModeShared
                    )
                    primitive.indexBuffer?.label = "VRM Indices u32 (mat \(primitive.materialIndex.map(String.init) ?? "—"))"
                } else { // UNSIGNED_SHORT or UNSIGNED_BYTE
                    primitive.indexType = .uint16
                    let uint16Indices = indices.map { UInt16($0) }
                    primitive.indexBuffer = device.makeBuffer(
                        bytes: uint16Indices,
                        length: uint16Indices.count * MemoryLayout<UInt16>.stride,
                        options: .storageModeShared
                    )
                    primitive.indexBuffer?.label = "VRM Indices u16 (mat \(primitive.materialIndex.map(String.init) ?? "—"))"
                }
            }
        }

        return primitive
    }

    // MARK: - Index/Accessor Consistency Audit

    /// Walks the index buffer checking for out-of-bounds indices, misaligned offsets, and degenerate triangles.
    ///
    /// Heavy diagnostic intended for debug builds: scans every index, logs
    /// findings, and applies extra heuristics for face materials (suspected
    /// UV anomalies, large index spreads).
    ///
    /// - Parameters:
    ///   - meshIndex: Source mesh index, used only for log output.
    ///   - primitiveIndex: Source primitive index, used only for log output.
    ///   - materialName: Optional material name; if it contains `"face"`, extra face-mesh diagnostics run.
    /// - Returns: `true` if no problems were found, `false` if any error was logged.
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

    /// Allocates GPU buffers (AoS and SoA layouts) for every morph target in ``morphTargets``.
    ///
    /// Call after ``morphTargets`` has been populated and before the first
    /// frame. The renderer requires both the per-target AoS buffers
    /// (``morphPositionBuffers``, ``morphNormalBuffers``, ``morphTangentBuffers``)
    /// and the flattened SoA buffers (``morphPositionsSoA``, ``morphNormalsSoA``)
    /// used by the compute morph kernel.
    public func createMorphTargetBuffers(device: MTLDevice) {
        morphPositionBuffers.removeAll()
        morphNormalBuffers.removeAll()
        morphTangentBuffers.removeAll()

        for target in morphTargets {
            // Create position delta buffer
            if let positionDeltas = target.positionDeltas {
                let bufferSize = positionDeltas.count * MemoryLayout<SIMD3<Float>>.stride
                if let buffer = device.makeBuffer(bytes: positionDeltas, length: bufferSize, options: .storageModeShared) {
                    buffer.label = "Morph Position Delta [\(morphPositionBuffers.count)]"
                    morphPositionBuffers.append(buffer)
                }
            }

            // Create normal delta buffer
            if let normalDeltas = target.normalDeltas {
                let bufferSize = normalDeltas.count * MemoryLayout<SIMD3<Float>>.stride
                if let buffer = device.makeBuffer(bytes: normalDeltas, length: bufferSize, options: .storageModeShared) {
                    buffer.label = "Morph Normal Delta [\(morphNormalBuffers.count)]"
                    morphNormalBuffers.append(buffer)
                }
            }

            // Create tangent delta buffer
            if let tangentDeltas = target.tangentDeltas {
                let bufferSize = tangentDeltas.count * MemoryLayout<SIMD3<Float>>.stride
                if let buffer = device.makeBuffer(bytes: tangentDeltas, length: bufferSize, options: .storageModeShared) {
                    buffer.label = "Morph Tangent Delta [\(morphTangentBuffers.count)]"
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
            basePositionsBuffer?.label = "Morph Base Positions"

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
                baseNormalsBuffer?.label = "Morph Base Normals"

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
        morphPositionsSoA?.label = "Morph Position Deltas SoA"
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
            morphNormalsSoA?.label = "Morph Normal Deltas SoA"
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

    // MARK: - Iron Dome Sanitization

    /// Sanitizes joint indices to prevent vertex explosions from out-of-bounds bone references.
    ///
    /// This is the "Iron Dome" sanitizer that catches:
    /// - **Sentinel values**: 65535 (0xFFFF) used by some exporters to mean "no bone"
    /// - **Out-of-bounds indices**: Joint indices >= actual bone count
    ///
    /// Both cases are remapped to joint 0 (root bone) with their weight zeroed out.
    ///
    /// - Parameter maxJointIndex: The maximum valid joint index (skin.joints.count - 1)
    /// - Returns: Number of joints that were sanitized
    @discardableResult
    public func sanitizeJoints(maxJointIndex: Int) -> Int {
        guard hasJoints, let vertexBuffer = vertexBuffer, vertexCount > 0 else {
            return 0
        }

        let maxValid = UInt32(maxJointIndex)
        var sanitizedCount = 0

        // Get mutable access to vertex buffer
        let vertexPointer = vertexBuffer.contents().bindMemory(to: VRMVertex.self, capacity: vertexCount)

        for i in 0..<vertexCount {
            var vertex = vertexPointer[i]
            var modified = false

            // Check and sanitize each joint index
            // If index is out of bounds or sentinel (65535), remap to joint 0 and zero the weight
            if vertex.joints.x > maxValid || vertex.joints.x == 65535 {
                vertex.joints.x = 0
                vertex.weights.x = 0
                modified = true
                sanitizedCount += 1
            }
            if vertex.joints.y > maxValid || vertex.joints.y == 65535 {
                vertex.joints.y = 0
                vertex.weights.y = 0
                modified = true
                sanitizedCount += 1
            }
            if vertex.joints.z > maxValid || vertex.joints.z == 65535 {
                vertex.joints.z = 0
                vertex.weights.z = 0
                modified = true
                sanitizedCount += 1
            }
            if vertex.joints.w > maxValid || vertex.joints.w == 65535 {
                vertex.joints.w = 0
                vertex.weights.w = 0
                modified = true
                sanitizedCount += 1
            }

            // Renormalize weights if any were zeroed
            if modified {
                let weightSum = vertex.weights.x + vertex.weights.y + vertex.weights.z + vertex.weights.w
                if weightSum > 0.0001 {
                    vertex.weights = vertex.weights / weightSum
                } else {
                    // All weights zeroed - set to 100% root bone
                    vertex.weights = SIMD4<Float>(1, 0, 0, 0)
                }
                vertexPointer[i] = vertex
            }
        }

        // Update requiredPaletteSize after sanitization
        if sanitizedCount > 0 {
            var newMaxJoint: UInt32 = 0
            for i in 0..<vertexCount {
                let joints = vertexPointer[i].joints
                newMaxJoint = max(newMaxJoint, joints.x, joints.y, joints.z, joints.w)
            }
            requiredPaletteSize = Int(newMaxJoint) + 1

            vrmLog("[IRON DOME] Sanitized \(sanitizedCount) out-of-bounds joint indices")
            vrmLog("  - Max valid joint: \(maxJointIndex)")
            vrmLog("  - New requiredPaletteSize: \(requiredPaletteSize)")
        }

        return sanitizedCount
    }

    // MARK: - First-Person Hidden Flags

    /// Computes per-vertex first-person hidden flags for `auto`-annotated meshes.
    ///
    /// A vertex is marked hidden (1) when any of its four skin joint slots references the
    /// head joint with a weight above `weightThreshold`. Vertices with no influence from
    /// the head joint are marked visible (0).
    ///
    /// - Parameters:
    ///   - joints: Per-vertex joint index quads (parallel to `weights`).
    ///   - weights: Per-vertex weight quads (parallel to `joints`).
    ///   - headJointIndex: The skin-local joint index that corresponds to the head bone.
    ///   - weightThreshold: Minimum weight to consider a joint influential (default 0.001).
    /// - Returns: One byte per vertex: 0 = visible in first-person, 1 = hidden.
    public static func computeFirstPersonHiddenFlags(
        joints: [SIMD4<UInt32>],
        weights: [SIMD4<Float>],
        headJointIndex: UInt32,
        weightThreshold: Float = 0.001
    ) -> [UInt8] {
        let count = min(joints.count, weights.count)
        var flags = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            let j = joints[i]
            let w = weights[i]
            if (j.x == headJointIndex && w.x > weightThreshold) ||
               (j.y == headJointIndex && w.y > weightThreshold) ||
               (j.z == headJointIndex && w.z > weightThreshold) ||
               (j.w == headJointIndex && w.w > weightThreshold) {
                flags[i] = 1
            }
        }
        return flags
    }

    /// Uploads `firstPersonHiddenFlags` to a Metal buffer on the given device.
    ///
    /// Call after populating `firstPersonHiddenFlags`. The buffer is stored in
    /// `firstPersonHiddenFlagsBuffer` and bound to the vertex shader at draw time
    /// when the camera mode is `.firstPerson`.
    public func uploadFirstPersonHiddenFlagsBuffer(device: MTLDevice) {
        guard !firstPersonHiddenFlags.isEmpty else { return }
        let length = firstPersonHiddenFlags.count * MemoryLayout<UInt8>.stride
        firstPersonHiddenFlagsBuffer = device.makeBuffer(
            bytes: firstPersonHiddenFlags,
            length: length,
            options: .storageModeShared
        )
        firstPersonHiddenFlagsBuffer?.label = "FirstPerson Hidden Flags"
    }
}

// MARK: - Vertex Data

struct VertexData {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var texCoords: [SIMD2<Float>] = []
    var colors: [SIMD4<Float>] = []
    var tangents: [SIMD4<Float>] = []
    var joints: [SIMD4<UInt32>] = []  // Changed to UInt32 to avoid truncation
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

/// Interleaved per-vertex layout used by every ``VRMPrimitive`` vertex buffer.
///
/// Must stay byte-compatible with the Metal `Vertex` struct in
/// `Shaders/VRMShared.h`. The strict-mode validator checks the byte size at
/// runtime via ``MetalSizeConstants/vertexSize``.
public struct VRMVertex {
    /// Object-space position.
    public var position: SIMD3<Float> = [0, 0, 0]
    /// Object-space normal; defaults to `(0, 1, 0)` for meshes without supplied normals.
    public var normal: SIMD3<Float> = [0, 1, 0]
    /// Primary UV channel (`TEXCOORD_0`).
    public var texCoord: SIMD2<Float> = [0, 0]
    /// Per-vertex color from `COLOR_0`; defaults to opaque white when absent.
    public var color: SIMD4<Float> = [1, 1, 1, 1]
    /// Skin joint indices into the joint palette. `UInt32` matches the shader's `uint4`.
    public var joints: SIMD4<UInt32> = [0, 0, 0, 0]
    /// Skin weights summing to 1.0; default `(1, 0, 0, 0)` is identity-rigged to joint 0.
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

/// A node in the VRM scene graph. Owns transform, parent/child links, and optional mesh/skin references.
///
/// ## Discussion
/// `VRMNode` corresponds one-to-one with a glTF `node`. Animation, look-at,
/// constraint solving, and spring-bone simulation all read and write
/// ``translation`` / ``rotation`` / ``scale``; the renderer then composes
/// these into ``localMatrix`` and ``worldMatrix`` via
/// ``updateLocalMatrix()`` and ``updateWorldTransform()``.
///
/// The bind pose is captured at load time in ``initialTranslation``,
/// ``initialRotation``, and ``initialScale`` (after VRM 0.0 → 1.0
/// coordinate normalization, if any).  Procedural systems compute
/// deltas against this rest pose, and ``resetToBindPose()`` restores it.
public class VRMNode {
    /// Source glTF node index; stable across loads.
    public let index: Int
    /// Source node name (often the humanoid bone name like `J_Bip_C_Head`).
    public let name: String?
    /// Parent node (weak to avoid retain cycles in the scene graph).
    public weak var parent: VRMNode?
    /// Child nodes; rendering walks this hierarchy.
    public var children: [VRMNode] = []

    /// Local-space translation. Mutated by animation, constraints, and physics.
    public var translation: SIMD3<Float> = [0, 0, 0]
    /// Local-space rotation. Mutated by animation, look-at, constraints, and physics.
    public var rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    /// Local-space scale.
    public var scale: SIMD3<Float> = [1, 1, 1]

    /// Bind-pose translation captured at load time. Used by ``resetToBindPose()`` and retargeting.
    public var initialTranslation: SIMD3<Float>
    /// Bind-pose rotation captured at load time.
    public var initialRotation: simd_quatf
    /// Bind-pose scale captured at load time.
    public var initialScale: SIMD3<Float>

    /// `translation * rotation * scale`, recomputed by ``updateLocalMatrix()`` whenever the components change.
    ///
    /// As of #206, this property is **owned by** ``translation`` / ``rotation``
    /// / ``scale``: ``updateWorldTransform()`` re-derives it from T/R/S at the
    /// top of every call. Direct assignment (`node.localMatrix = …`) is
    /// supported only as a transient injection point — the value will be
    /// overwritten the next time the node, or any of its ancestors, runs
    /// through ``updateWorldTransform()``. To set a stable local pose, mutate
    /// T/R/S instead.
    public var localMatrix: float4x4 = matrix_identity_float4x4
    /// `parent.worldMatrix * localMatrix`, recomputed by ``updateWorldTransform()``.
    public var worldMatrix: float4x4 = matrix_identity_float4x4

    /// World-space position of this node's origin, extracted from ``worldMatrix``. Used by spring-bone colliders.
    public var worldPosition: SIMD3<Float> {
        return SIMD3<Float>(worldMatrix[3][0], worldMatrix[3][1], worldMatrix[3][2])
    }

    /// Alias for ``rotation`` that automatically refreshes ``localMatrix`` on assignment.
    public var localRotation: simd_quatf {
        get { return rotation }
        set {
            rotation = newValue
            updateLocalMatrix()
        }
    }

    /// Index into the model's `meshes` array if this node draws a mesh; `nil` otherwise.
    public var mesh: Int?
    /// Index into the model's `skins` array if this node is a skinned-mesh instance; `nil` otherwise.
    public var skin: Int?

    /// Creates a node from a parsed glTF node. Decomposes a supplied 4x4 matrix into T/R/S when present.
    public init(index: Int, gltfNode: GLTFNode) {
        self.index = index
        self.name = gltfNode.name
        self.mesh = gltfNode.mesh
        self.skin = gltfNode.skin

        // Parse transform
        if let matrix = gltfNode.matrix, matrix.count == 16 {
            // GLTF matrices are stored in column-major order: indices 0-3 = column 0, 4-7 = column 1, etc.
            // float4x4 initializer takes columns, so we pass each column directly
            let m = float4x4(
                SIMD4<Float>(matrix[0], matrix[1], matrix[2], matrix[3]),     // column 0
                SIMD4<Float>(matrix[4], matrix[5], matrix[6], matrix[7]),     // column 1
                SIMD4<Float>(matrix[8], matrix[9], matrix[10], matrix[11]),   // column 2
                SIMD4<Float>(matrix[12], matrix[13], matrix[14], matrix[15])  // column 3 (translation)
            )

            // Decompose matrix to get T/R/S
            // This ensures that even if initialized with a matrix, we have valid T/R/S components
            // for the animation system to work with.
            let decomp = decomposeMatrix(m)
            self.translation = decomp.translation
            self.rotation = decomp.rotation
            self.scale = decomp.scale
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
        }

        // Store initial values as bind pose
        self.initialTranslation = translation
        self.initialRotation = rotation
        self.initialScale = scale

        // Update local matrix from T/R/S
        updateLocalMatrix()
    }

    /// Reset node transform to its initial bind pose (as defined in the file)
    public func resetToBindPose() {
        translation = initialTranslation
        rotation = initialRotation
        scale = initialScale
        updateLocalMatrix()
    }

    /// Recomputes ``localMatrix`` as `translate(translation) * rotate(rotation) * scale(scale)`.
    /// Call after mutating ``translation``, ``rotation``, or ``scale`` directly.
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

    /// Recomputes ``worldMatrix`` (and recurses through ``children``) by composing with the parent's world matrix.
    /// Call from each scene-graph root once per frame after animation has mutated local transforms.
    ///
    /// Refreshes ``localMatrix`` from the current ``translation`` / ``rotation``
    /// / ``scale`` first, so external callers that mutate those properties
    /// directly (without remembering to invoke ``updateLocalMatrix()``) still
    /// see the change reach ``worldMatrix``. This closed vrm-conformance #206,
    /// where the adapter's `root.translation = …; updateWorldTransform()`
    /// pattern left every spring-bone swing test SHA-identical to its
    /// no-animation settle pair because the cached `localMatrix` never
    /// picked up the displacement.
    public func updateWorldTransform() {
        updateLocalMatrix()

        #if DEBUG
        // Check for NaNs before using localMatrix
        if localMatrix[0][0].isNaN || localMatrix[0][1].isNaN || localMatrix[0][2].isNaN || localMatrix[0][3].isNaN ||
           localMatrix[1][0].isNaN || localMatrix[1][1].isNaN || localMatrix[1][2].isNaN || localMatrix[1][3].isNaN ||
           localMatrix[2][0].isNaN || localMatrix[2][1].isNaN || localMatrix[2][2].isNaN || localMatrix[2][3].isNaN ||
           localMatrix[3][0].isNaN || localMatrix[3][1].isNaN || localMatrix[3][2].isNaN || localMatrix[3][3].isNaN {
            vrmLogAnimation("!!! CRITICAL ERROR: NaN detected in localMatrix for node \(name ?? "unnamed") BEFORE world transform update")
            // Optionally, reset localMatrix to identity to prevent crash
            localMatrix = matrix_identity_float4x4
        }
        #endif

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

/// A skeletal skin: ordered joint array plus inverse bind matrices used to compute the per-frame joint palette.
///
/// The renderer's ``VRMSkinningSystem`` packs every model skin's joint matrices
/// into a single shared GPU buffer; ``bufferByteOffset`` and ``matrixOffset``
/// record where this skin's slice begins.
public class VRMSkin {
    /// Source skin name from glTF.
    public let name: String?
    /// Ordered joint nodes; vertex `JOINTS_0` indices reference positions in this array.
    public var joints: [VRMNode] = []
    /// Inverse bind matrices, one per joint (identity if the source did not supply an accessor).
    public var inverseBindMatrices: [float4x4] = []
    /// Optional skeleton root node, used by debug tools.
    public var skeleton: VRMNode?

    /// Byte offset of this skin's joint matrices within the shared palette buffer.
    public var bufferByteOffset: Int = 0
    /// Matrix-count offset of this skin's palette slice (`bufferByteOffset / sizeof(float4x4)`).
    public var matrixOffset: Int = 0

    /// Loads a skin from glTF: resolves joint node references and reads inverse bind matrices.
    ///
    /// - Throws: Any ``VRMError`` raised by `bufferLoader` when loading the inverse-bind-matrix accessor.
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

/// A Metal texture handle plus optional sampler, named per the source glTF texture.
///
/// Used by ``VRMMaterial`` to reference base color, normal, emissive,
/// shade, matcap, rim, and outline-width-mask textures.
public class VRMTexture {
    /// Decoded GPU texture; `nil` if loading failed or was deferred.
    public var mtlTexture: MTLTexture?
    /// Optional sampler override; renderer uses a default linear-wrap sampler when nil.
    public var sampler: MTLSamplerState?
    /// Source texture name from glTF, when available.
    public let name: String?

    /// Creates a texture wrapper. Both parameters are optional so the type can be constructed
    /// before GPU resources are ready.
    public init(name: String? = nil, mtlTexture: MTLTexture? = nil) {
        self.name = name
        self.mtlTexture = mtlTexture
    }
}

// MARK: - VRM Material

/// A material: glTF PBR parameters plus optional MToon (VRM) parameters, alpha handling, and render-queue sorting.
///
/// ## Discussion
/// `VRMMaterial` carries both the standard glTF PBR-metallic-roughness fields
/// (base color, normal, emissive, metallic/roughness factors) and a separate
/// ``mtoon`` block holding the VRM-specific toon-shading parameters. The
/// renderer picks an appropriate pipeline based on ``alphaMode``,
/// ``transparentWithZWrite``, and whether ``mtoon`` is present.
///
/// Sorting between transparent primitives is driven by ``renderQueue`` and
/// ``renderQueueOffset`` (see the VRM 1.0 spec for the base values: 2000 for
/// OPAQUE, 2450 for MASK, 2510 for transparent-with-zwrite, 3000 for BLEND).
public class VRMMaterial: @unchecked Sendable {
    /// Source material name from glTF.
    public let name: String?
    /// Base color (albedo) tint applied to ``baseColorTexture``. Clamped to `[0, 1]` per the glTF 2.0 spec.
    public var baseColorFactor: SIMD4<Float> = [1, 1, 1, 1]
    /// Base color texture (sRGB).
    public var baseColorTexture: VRMTexture?
    /// Tangent-space normal map used for surface detail.
    public var normalTexture: VRMTexture?
    /// glTF-core `normalTextureInfo.scale` — multiplies the X and Y
    /// components of the unpacked tangent-space normal before
    /// renormalisation. Defaults to `1.0`. VMK#290.
    public var normalScale: Float = 1.0
    /// glTF-core ambient-occlusion texture. The R channel carries the
    /// per-fragment occlusion value (0 = fully occluded, 1 = no
    /// occlusion). Modulates the indirect/ambient (GI) term only — never
    /// the direct toon-shaded term — via the spec factor
    /// `1.0 + occlusionStrength * (sample - 1.0)`, matching UniVRM /
    /// three-vrm / godot. VMK#293, VMK#310.
    public var occlusionTexture: VRMTexture?
    /// glTF-core `occlusionTextureInfo.strength` — scales the
    /// occlusion contribution. `0` disables occlusion (final factor =
    /// 1.0); `1` is full occlusion. Defaults to `1.0` per spec.
    /// VMK#293.
    public var occlusionStrength: Float = 1.0
    /// Emissive (self-illuminating) texture.
    public var emissiveTexture: VRMTexture?
    /// glTF metallic factor. Unused by the MToon path; retained for non-MToon fallback shading.
    public var metallicFactor: Float = 0.0
    /// glTF roughness factor. Unused by the MToon path.
    public var roughnessFactor: Float = 1.0
    /// Emissive tint multiplied into ``emissiveTexture``.
    public var emissiveFactor: SIMD3<Float> = [0, 0, 0]
    /// Disables back-face culling when true.
    public var doubleSided: Bool = false
    /// Alpha mode: `"OPAQUE"`, `"MASK"`, or `"BLEND"` (case-sensitive per the glTF spec, though parsing is tolerant).
    public var alphaMode: String = "OPAQUE"
    /// Alpha-cutoff threshold for ``alphaMode`` == `"MASK"`.
    public var alphaCutoff: Float = 0.5

    /// Optional MToon shading parameters; non-nil for materials with the `VRMC_materials_mtoon` extension.
    public var mtoon: VRMMToonMaterial?

    /// Spec version the material was authored against. VRM 0.x MToon parameters
    /// are converted to VRM 1.0 ramp space before shading; this flag remains
    /// available for shader paths whose semantics genuinely differ by source
    /// version.
    public var vrmVersion: VRMSpecVersion = .v1_0

    /// Render-queue value for transparency sorting (VRM 0.x uses Unity render-queue numbers; higher = drawn later).
    /// Default 2000 is the geometry queue; transparent materials typically sit at 3000+.
    public var renderQueue: Int = 2000

    /// Transparent material that still writes to the depth buffer.
    /// Critical for correctly layering face details (eyebrows/eyelashes over face skin).
    public var transparentWithZWrite: Bool = false

    /// Offset applied on top of the VRM-1.0 base render queue for the material's alpha mode.
    public var renderQueueOffset: Int = 0

    /// VRM 0.x `_ZWrite` flag mapped to a Bool.
    public var zWriteEnabled: Bool = true

    /// VRM 0.x `_BlendMode`: `0` Opaque, `1` Cutout, `2` Transparent, `3` TransparentWithZWrite.
    public var blendMode: Int = 0

    /// `KHR_texture_transform` UV transform parsed from ``baseColorTexture``'s `textureInfo` extensions.
    public var khrTextureTransform: GLTFKHRTextureTransform?

    /// `true` when this material is transparent and writes to depth (combination of VRM 1.0 flag and VRM 0.x heuristics).
    /// Used by the render-item sorter to place these materials between OPAQUE and BLEND queues.
    public var isTransparentWithZWrite: Bool {
        // Explicit flag from VRM 1.0 extension
        if transparentWithZWrite {
            return true
        }
        // VRM 0.x: BlendMode 3 is explicitly TransparentWithZWrite
        if blendMode == 3 {
            return true
        }
        // VRM 0.x: Infer from properties - transparent material with zWrite enabled
        let isTransparent = alphaMode == "BLEND" || blendMode == 2
        return isTransparent && zWriteEnabled
    }

    /// Coarse pipeline bucket used to pick between opaque and blended render-pass pipeline states.
    public enum PipelineCategory: Equatable {
        /// `OPAQUE` (and `MASK`, which the renderer also treats as opaque): no color blending.
        case opaque
        /// `BLEND` without depth writes: standard alpha-blend.
        case blend
        /// `BLEND` with depth writes enabled (transparent-with-zwrite layering).
        case blendZWrite
    }

    /// Picks a ``PipelineCategory`` from the alpha mode and the depth-write flag.
    public static func pipelineCategory(alphaMode: String, transparentWithZWrite: Bool) -> PipelineCategory {
        switch alphaMode.uppercased() {
        case "BLEND":
            return transparentWithZWrite ? .blendZWrite : .blend
        default:
            return .opaque
        }
    }

    /// Builds a material from glTF + optional VRM 0.x material property block.
    ///
    /// Parses the standard PBR fields, the `VRMC_materials_mtoon` extension
    /// (VRM 1.0), and — when supplied — the legacy `VRM.materialProperties`
    /// dictionary (VRM 0.x). Computes the final ``renderQueue`` from the
    /// alpha-mode base plus the spec-clamped offset.
    ///
    /// - Parameters:
    ///   - gltfMaterial: Source glTF material.
    ///   - textures: Texture array used to resolve texture indices.
    ///   - vrm0MaterialProperty: Optional VRM 0.x material property; pass `nil` for VRM 1.0 sources.
    ///   - vrmVersion: Authored spec version retained for version-specific render paths.
    public init(from gltfMaterial: GLTFMaterial, textures: [VRMTexture], vrm0MaterialProperty: VRM0MaterialProperty? = nil, vrmVersion: VRMSpecVersion = .v1_0) {
        self.name = gltfMaterial.name
        self.vrmVersion = vrmVersion

        if let pbr = gltfMaterial.pbrMetallicRoughness {
            if let baseColor = pbr.baseColorFactor, baseColor.count == 4 {
                let unclamped = SIMD4<Float>(baseColor[0], baseColor[1], baseColor[2], baseColor[3])

                // DEBUG: Log parsed values before clamping
                #if DEBUG
                vrmLog("[VRMMaterial] Parsed '\(gltfMaterial.name ?? "unnamed")' baseColorFactor: \(unclamped)")
                if unclamped.x > 10.0 || unclamped.y > 10.0 || unclamped.z > 10.0 || unclamped.w > 10.0 {
                    vrmLog("  ⚠️ WARNING: Extreme baseColorFactor detected (>10.0)!")
                }
                if unclamped.x < 0.0 || unclamped.y < 0.0 || unclamped.z < 0.0 || unclamped.w < 0.0 {
                    vrmLog("  ⚠️ WARNING: Negative baseColorFactor detected!")
                }
                if unclamped.x.isNaN || unclamped.y.isNaN || unclamped.z.isNaN || unclamped.w.isNaN {
                    vrmLog("  ⚠️ ERROR: NaN detected in baseColorFactor!")
                }
                #endif

                // Clamp to valid range [0.0, 1.0] per glTF 2.0 spec
                baseColorFactor = simd_clamp(unclamped, SIMD4<Float>(repeating: 0.0), SIMD4<Float>(repeating: 1.0))

                if baseColorFactor != unclamped {
                    vrmLog("  🔧 Clamped baseColorFactor from \(unclamped) to \(baseColorFactor)")
                }
            }
            metallicFactor = pbr.metallicFactor ?? 0.0
            roughnessFactor = pbr.roughnessFactor ?? 1.0

            if let baseColorTextureInfo = pbr.baseColorTexture {
                if baseColorTextureInfo.index < textures.count {
                    baseColorTexture = textures[baseColorTextureInfo.index]
                }
                if let transform = baseColorTextureInfo.khrTextureTransform {
                    khrTextureTransform = transform
                }
            }
        }

        // Load normal texture (provides surface detail like nose contours)
        if let normalTextureInfo = gltfMaterial.normalTexture,
           normalTextureInfo.index < textures.count {
            normalTexture = textures[normalTextureInfo.index]
            // glTF 2.0 normalTextureInfo.scale: amplifies the unpacked
            // tangent-space normal's XY before renormalisation. Default 1.0
            // per spec. VMK#290.
            normalScale = normalTextureInfo.scale ?? 1.0
        }

        // Load occlusion texture (per-fragment ambient occlusion, R
        // channel per glTF 2.0 spec). Sibling-gap to normalTexture.scale
        // — same wiring shape: a glTF-core textureInfo with its own
        // scalar parameter, missing from the VRMMetalKit MToon path
        // before VMK#293.
        if let occlusionTextureInfo = gltfMaterial.occlusionTexture,
           occlusionTextureInfo.index < textures.count {
            occlusionTexture = textures[occlusionTextureInfo.index]
            occlusionStrength = occlusionTextureInfo.strength ?? 1.0
        }

        // Load emissive texture (for glow effects)
        if let emissiveTextureInfo = gltfMaterial.emissiveTexture,
           emissiveTextureInfo.index < textures.count {
            emissiveTexture = textures[emissiveTextureInfo.index]
        }

        if let emissive = gltfMaterial.emissiveFactor, emissive.count == 3 {
            emissiveFactor = SIMD3<Float>(emissive[0], emissive[1], emissive[2])
        }

        // VRMC_materials_hdr_emissiveMultiplier-1.0 + KHR_materials_emissive_strength.
        // Both extensions scale `emissiveFactor` by a scalar. The VRMC spec
        // text reads: "Overwrite material.emissiveFactor of the target
        // material with the value multiplied by emissiveMultiplier." KHR is
        // the named glTF replacement and has identical semantics. When both
        // are present (vanishingly rare) the VRMC variant wins for explicit
        // alignment with VRM tooling. Negative multipliers are clamped to 0
        // per VRMC's `minimum: 0.0` schema bound. VMK#287.
        if let extensions = gltfMaterial.extensions {
            if let ext = extensions["VRMC_materials_hdr_emissiveMultiplier"] as? [String: Any],
               let m = floatScalar(from: ext["emissiveMultiplier"]) {
                emissiveFactor *= max(0, m)
            } else if let ext = extensions["KHR_materials_emissive_strength"] as? [String: Any],
                      let s = floatScalar(from: ext["emissiveStrength"]) {
                emissiveFactor *= max(0, s)
            }
        }

        doubleSided = gltfMaterial.doubleSided ?? false
        alphaMode = gltfMaterial.alphaMode ?? "OPAQUE"
        alphaCutoff = gltfMaterial.alphaCutoff ?? 0.5

        // Parse MToon extension if present
        // VRM 1.0: per-material VRMC_materials_mtoon extension
        if let extensions = gltfMaterial.extensions,
           let mtoonExt = extensions["VRMC_materials_mtoon"] as? [String: Any] {
            mtoon = parseMToonExtension(mtoonExt, textures: textures)

            // VRM 1.0: explicit transparentWithZWrite flag
            if let twzw = mtoonExt["transparentWithZWrite"] as? Bool {
                transparentWithZWrite = twzw
            }
            // VRM 1.0: renderQueueOffsetNumber for sorting within category
            // Compute final renderQueue from base + offset per VRM 1.0 spec
            if let rqOffset = mtoonExt["renderQueueOffsetNumber"] as? Int {
                // Clamp offset to spec-defined ranges per alphaMode / transparentWithZWrite
                let clampedOffset: Int
                switch alphaMode.uppercased() {
                case "OPAQUE", "MASK":
                    if rqOffset != 0 {
                        vrmLog("[VRMMaterial] renderQueueOffsetNumber \(rqOffset) ignored for \(alphaMode) (spec requires 0)")
                    }
                    clampedOffset = 0
                case "BLEND":
                    if transparentWithZWrite {
                        if rqOffset < 0 || rqOffset > 9 {
                            vrmLog("[VRMMaterial] renderQueueOffsetNumber \(rqOffset) clamped to [0,9] for BLEND+zWrite=true")
                        }
                        clampedOffset = max(0, min(9, rqOffset))
                    } else {
                        if rqOffset < -9 || rqOffset > 9 {
                            vrmLog("[VRMMaterial] renderQueueOffsetNumber \(rqOffset) clamped to [-9,9] for BLEND+zWrite=false")
                        }
                        clampedOffset = max(-9, min(9, rqOffset))
                    }
                default:
                    clampedOffset = 0
                }
                renderQueueOffset = clampedOffset

                // VRM 1.0 base render queue values per alpha mode + transparentWithZWrite
                let base: Int
                switch alphaMode.uppercased() {
                case "OPAQUE":
                    base = 2000
                case "MASK":
                    base = 2450
                case "BLEND":
                    base = transparentWithZWrite ? 2510 : 3000
                default:
                    base = 2000
                }
                renderQueue = base + clampedOffset
            }
            // Wire KHR_texture_transform from baseColorTexture into mtoon
            if let transform = khrTextureTransform {
                mtoon?.textureTransform = transform
            }
        }
        // VRM 0.x: material properties from document-level VRM extension
        else if let vrm0Prop = vrm0MaterialProperty {
            mtoon = vrm0Prop.toMToonMaterial()

            // Also get base color from VRM 0.x _Color vector property if present (sRGB to Linear)
            if let colorVec = vrm0Prop.vectorProperties["_Color"], colorVec.count >= 4 {
                // Convert RGB from sRGB to linear, alpha stays linear
                let r = sRGBToLinear(colorVec[0])
                let g = sRGBToLinear(colorVec[1])
                let b = sRGBToLinear(colorVec[2])
                let a = colorVec[3]  // Alpha stays linear
                baseColorFactor = SIMD4<Float>(r, g, b, a)
            }

            // Get renderQueue from VRM 0.x material (used for sorting transparent materials)
            if let queue = vrm0Prop.renderQueue {
                renderQueue = queue
            }

            // VRM 0.x: Read _ZWrite and _BlendMode from floatProperties
            // _ZWrite: 1 = writes to depth, 0 = no depth write
            if let zWrite = vrm0Prop.floatProperties["_ZWrite"] {
                zWriteEnabled = (zWrite == 1.0)
            }
            // _BlendMode: 0=Opaque, 1=Cutout, 2=Transparent, 3=TransparentWithZWrite
            if let bm = vrm0Prop.floatProperties["_BlendMode"] {
                blendMode = Int(bm)
                // Map VRM 0.x _BlendMode to glTF alphaMode for pipeline selection.
                // Without this, materials authored as Transparent (e.g.
                // AliciaSolid's bangs at _BlendMode=3) stay as glTF "OPAQUE" and
                // render without alpha blending.
                switch blendMode {
                case 0: alphaMode = "OPAQUE"
                case 1: alphaMode = "MASK"
                case 2, 3: alphaMode = "BLEND"
                default: alphaMode = "OPAQUE"
                }
                // VMK#265: _BlendMode = 3 is TransparentWithZWrite — the VRM 0.x
                // equivalent of VRM 1.0's `alphaMode: BLEND` +
                // `VRMC_materials_mtoon.transparentWithZWrite: true`. Set the
                // explicit field so direct readers see the same value as the
                // VRM 1.0 native path; the `isTransparentWithZWrite` computed
                // property's `blendMode == 3` fallback stays as a belt-and-
                // braces guard but is no longer load-bearing.
                if blendMode == 3 {
                    transparentWithZWrite = true
                }
            }
        }
    }

    /// Helper to convert sRGB color value to linear (gamma decoding)
    private func sRGBToLinear(_ value: Float) -> Float {
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// Extract a `[Float]` from an MToon JSON value where AnyCodable may have
    /// decoded array elements as `Int` rather than `Double` (e.g. `[1, 1, 1]`
    /// in the JSON literal). The `as? [Double]` cast at the call sites was
    /// silently failing for spec-conformant integer-valued vectors.
    private func floatArray(from value: Any?, count: Int) -> [Float]? {
        guard let array = value as? [Any], array.count >= count else { return nil }
        let parsed: [Float] = array.compactMap { floatScalar(from: $0) }
        return parsed.count >= count ? parsed : nil
    }

    /// Extract a `Float` from an MToon JSON scalar. ``AnyCodable`` tries
    /// `Int` before `Double` when decoding numbers, so JSON literals like
    /// `1.0`, `-1`, and `0` are stored as `Int`. The prior `as? Double`
    /// casts silently failed for those values, leaving every affected
    /// factor (shadingShift, shadingToony, rimLightingMix, …) stuck at
    /// its `VRMMToonMaterial` default — see VMK#238 and VMK#239.
    private func floatScalar(from value: Any?) -> Float? {
        if let intVal = value as? Int { return Float(intVal) }
        if let doubleVal = value as? Double { return Float(doubleVal) }
        if let floatVal = value as? Float { return floatVal }
        return nil
    }

    private func parseMToonExtension(_ mtoonExt: [String: Any], textures: [VRMTexture]) -> VRMMToonMaterial {
        var mtoon = VRMMToonMaterial()

        // Shade color factor
        if let shadeColorFactor = floatArray(from: mtoonExt["shadeColorFactor"], count: 3) {
            mtoon.shadeColorFactor = SIMD3<Float>(shadeColorFactor[0],
                                                  shadeColorFactor[1],
                                                  shadeColorFactor[2])
        }

        // Shading properties
        if let shadingToonyFactor = floatScalar(from: mtoonExt["shadingToonyFactor"]) {
            mtoon.shadingToonyFactor = shadingToonyFactor
        }
        if let shadingShiftFactor = floatScalar(from: mtoonExt["shadingShiftFactor"]) {
            mtoon.shadingShiftFactor = shadingShiftFactor
        }

        // Global illumination
        if let giEqualizationFactor = floatScalar(from: mtoonExt["giEqualizationFactor"]) {
            mtoon.giEqualizationFactor = giEqualizationFactor
        }

        // MatCap properties
        if let matcapFactor = floatArray(from: mtoonExt["matcapFactor"], count: 3) {
            mtoon.matcapFactor = SIMD3<Float>(matcapFactor[0],
                                              matcapFactor[1],
                                              matcapFactor[2])
        }

        // Parametric rim lighting
        if let parametricRimColorFactor = floatArray(from: mtoonExt["parametricRimColorFactor"], count: 3) {
            mtoon.parametricRimColorFactor = SIMD3<Float>(parametricRimColorFactor[0],
                                                          parametricRimColorFactor[1],
                                                          parametricRimColorFactor[2])
        }
        if let parametricRimFresnelPowerFactor = floatScalar(from: mtoonExt["parametricRimFresnelPowerFactor"]) {
            mtoon.parametricRimFresnelPowerFactor = parametricRimFresnelPowerFactor
        }
        if let parametricRimLiftFactor = floatScalar(from: mtoonExt["parametricRimLiftFactor"]) {
            mtoon.parametricRimLiftFactor = parametricRimLiftFactor
        }
        if let rimLightingMixFactor = floatScalar(from: mtoonExt["rimLightingMixFactor"]) {
            mtoon.rimLightingMixFactor = rimLightingMixFactor
        }

        // Outline properties
        if let outlineWidthMode = mtoonExt["outlineWidthMode"] as? String {
            mtoon.outlineWidthMode = VRMOutlineWidthMode(rawValue: outlineWidthMode) ?? .none
        }
        if let outlineWidthFactor = floatScalar(from: mtoonExt["outlineWidthFactor"]) {
            mtoon.outlineWidthFactor = outlineWidthFactor
        }
        if let outlineColorFactor = floatArray(from: mtoonExt["outlineColorFactor"], count: 3) {
            mtoon.outlineColorFactor = SIMD3<Float>(outlineColorFactor[0],
                                                    outlineColorFactor[1],
                                                    outlineColorFactor[2])
        }
        if let outlineLightingMixFactor = floatScalar(from: mtoonExt["outlineLightingMixFactor"]) {
            mtoon.outlineLightingMixFactor = outlineLightingMixFactor
        }

        // UV Animation properties
        if let uvAnimationScrollXSpeedFactor = floatScalar(from: mtoonExt["uvAnimationScrollXSpeedFactor"]) {
            mtoon.uvAnimationScrollXSpeedFactor = uvAnimationScrollXSpeedFactor
        }
        if let uvAnimationScrollYSpeedFactor = floatScalar(from: mtoonExt["uvAnimationScrollYSpeedFactor"]) {
            mtoon.uvAnimationScrollYSpeedFactor = uvAnimationScrollYSpeedFactor
        }
        if let uvAnimationRotationSpeedFactor = floatScalar(from: mtoonExt["uvAnimationRotationSpeedFactor"]) {
            mtoon.uvAnimationRotationSpeedFactor = uvAnimationRotationSpeedFactor
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
            let scale = floatScalar(from: shadingShiftTexture["scale"])
            mtoon.shadingShiftTexture = VRMShadingShiftTexture(
                index: index,
                texCoord: texCoord,
                scale: scale
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

    init(scaling s: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.0.x = s.x
        columns.1.y = s.y
        columns.2.z = s.z
    }
}

// MARK: - Matrix Decomposition

private func decomposeMatrix(_ matrix: float4x4) -> (translation: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>) {
    let translation = SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)

    var column0 = SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z)
    var column1 = SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z)
    var column2 = SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)

    var scaleX = length(column0)
    var scaleY = length(column1)
    var scaleZ = length(column2)

    if scaleX > 1e-6 { column0 /= scaleX } else { scaleX = 1 }
    if scaleY > 1e-6 { column1 /= scaleY } else { scaleY = 1 }
    if scaleZ > 1e-6 { column2 /= scaleZ } else { scaleZ = 1 }

    var rotationMatrix = float3x3(columns: (column0, column1, column2))

    // Correct for negative scale
    if simd_determinant(rotationMatrix) < 0 {
        scaleX = -scaleX
        rotationMatrix.columns.0 = -rotationMatrix.columns.0
    }

    let rotation = simd_quatf(rotationMatrix)
    let scale = SIMD3<Float>(scaleX, scaleY, scaleZ)

    return (translation, rotation, scale)
}
