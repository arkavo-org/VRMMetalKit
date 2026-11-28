//
// Copyright 2026 Arkavo
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

/// Uniform scene-graph surface implemented by both a base ``VRMModel`` and
/// attached cosmetic side scenes.
///
/// The renderer iterates `[model] + attachments` through this protocol so
/// rigid accessories and skinned garments share one draw, prepass, outline,
/// morph, and skinning pipeline without mutating the base model's arrays.
public protocol VRMSceneContent: AnyObject {
    var nodes: [VRMNode] { get }
    var meshes: [VRMMesh] { get }
    var materials: [VRMMaterial] { get }
    var textures: [VRMTexture] { get }
    var skins: [VRMSkin] { get }
}

/// Transactional editor passed to ``VRMModel/edit(_:)``.
///
/// Mutations performed through this editor run while holding `VRMModel.lock`
/// and coalesce all affected revision counter bumps into a single atomic
/// publication when the transaction exits.
public final class VRMModelEditor {
    /// The model being edited. Caller already holds the model lock.
    public let model: VRMModel

    internal var topologyDirty = false
    internal var materialsDirty = false
    internal var visibilityDirty = false
    internal var skinLayoutDirty = false
    internal var skinContentDirty = false
    internal var physicsDirty = false
    internal var boundsDirty = false
    internal var geometryDirty = false

    internal init(model: VRMModel) {
        self.model = model
    }

    /// Updates the base color tint (and optionally MToon shade color) on the material at `index`.
    public func setTint(
        _ color: SIMD4<Float>,
        forMaterialAt index: Int,
        updateShadeColor: Bool = true,
        shadeTintMultiplier: Float = 0.75
    ) {
        guard index >= 0 && index < model.materials.count else { return }
        model.materials[index].setTint(
            color,
            updateShadeColor: updateShadeColor,
            shadeTintMultiplier: shadeTintMultiplier
        )
        materialsDirty = true
    }

    /// Mutates a material in place and automatically bumps ``VRMModel/materialRevision``
    /// (and ``VRMModel/topologyRevision`` if pipeline-affecting properties changed).
    public func mutateMaterial(at index: Int, _ body: (VRMMaterial) throws -> Void) rethrows {
        guard index >= 0 && index < model.materials.count else { return }
        let material = model.materials[index]
        let oldAlphaMode = material.alphaMode
        let oldTransparentWithZWrite = material.transparentWithZWrite
        let oldDoubleSided = material.doubleSided
        let oldRenderQueue = material.renderQueue
        let oldAlphaCutoff = material.alphaCutoff

        try body(material)

        materialsDirty = true
        if material.alphaMode != oldAlphaMode
            || material.transparentWithZWrite != oldTransparentWithZWrite
            || material.doubleSided != oldDoubleSided
            || material.renderQueue != oldRenderQueue
            || material.alphaCutoff != oldAlphaCutoff {
            topologyDirty = true
        }
    }

    /// Replaces the GPU texture backing `model.textures[index]` directly from raw straight-alpha
    /// RGBA8 pixel bytes, bypassing GLB re-serialization and ImageIO decoding.
    ///
    /// Every `VRMMaterial` referencing `model.textures[index]` immediately renders with the new
    /// texture on the next draw, and ``VRMModel/materialRevision`` is bumped when the edit exits.
    public func replaceTexture(
        at index: Int,
        rgba8Data: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int? = nil,
        sRGB: Bool = true,
        mipmapped: Bool = true,
        alphaIsCoverage: Bool = false,
        blockCompress: Bool = false,
        sampler: MTLSamplerState? = nil,
        device: MTLDevice? = nil
    ) throws {
        guard index >= 0 && index < model.textures.count else {
            throw GLTFError.missingTexture(
                textureIndex: index,
                materialName: nil,
                uri: nil,
                filePath: model.baseURL?.path
            )
        }
        guard let targetDevice = device ?? model.device else {
            throw GLTFError.invalidImageData(
                textureIndex: index,
                reason: "No MTLDevice available on VRMModel or replaceTexture(at:) call",
                filePath: model.baseURL?.path
            )
        }
        let uploaded = try VRMTexture.makeRGBA8(
            data: rgba8Data,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            sRGB: sRGB,
            mipmapped: mipmapped,
            alphaIsCoverage: alphaIsCoverage,
            blockCompress: blockCompress,
            name: model.textures[index].name,
            sampler: sampler,
            device: targetDevice
        )
        model.textures[index].mtlTexture = uploaded.mtlTexture
        if let sampler {
            model.textures[index].sampler = sampler
        }
        materialsDirty = true
    }

    /// Replaces the GPU texture backing `model.textures[index]` with an already-allocated
    /// `MTLTexture` (such as an ASTC, BC7, or pre-uploaded RGBA8 texture).
    public func replaceTexture(
        at index: Int,
        mtlTexture: MTLTexture,
        sampler: MTLSamplerState? = nil
    ) {
        guard index >= 0 && index < model.textures.count else { return }
        model.textures[index].mtlTexture = mtlTexture
        if let sampler {
            model.textures[index].sampler = sampler
        }
        materialsDirty = true
    }

    /// Sets ``VRMNode/isHidden`` on the node at `index` and marks visibility modified.
    public func setNodeHidden(_ hidden: Bool, at index: Int) {
        guard index >= 0 && index < model.nodes.count else { return }
        model.nodes[index].isHidden = hidden
        visibilityDirty = true
    }

    /// Sets ``VRMPrimitive/isHidden`` on the specified mesh primitive and marks visibility modified.
    public func setPrimitiveHidden(_ hidden: Bool, meshIndex: Int, primitiveIndex: Int) {
        guard meshIndex >= 0 && meshIndex < model.meshes.count else { return }
        let mesh = model.meshes[meshIndex]
        guard primitiveIndex >= 0 && primitiveIndex < mesh.primitives.count else { return }
        mesh.primitives[primitiveIndex].isHidden = hidden
        visibilityDirty = true
    }

    // MARK: - Live Geometry, Rig & Physics Editing

    /// Publishes updated vertex positions on the specified mesh primitive using copy-on-write
    /// buffer replacement so in-flight GPU frames keep reading the previous buffer safely
    /// without triggering a topology rebuild.
    ///
    /// Also publishes a replacement ``VRMPrimitive/basePositionsBuffer`` (when morph targets
    /// are present), recomputes the primitive's local AABB, and bumps ``VRMModel/geometryRevision``
    /// so cached morph outputs invalidate on the next draw.
    public func updatePositions(
        _ positions: [SIMD3<Float>],
        meshIndex: Int,
        primitiveIndex: Int,
        device: MTLDevice? = nil
    ) throws {
        guard meshIndex >= 0 && meshIndex < model.meshes.count else {
            throw VRMError.invalidEdit("meshIndex \(meshIndex) out of bounds (count: \(model.meshes.count))")
        }
        let mesh = model.meshes[meshIndex]
        guard primitiveIndex >= 0 && primitiveIndex < mesh.primitives.count else {
            throw VRMError.invalidEdit("primitiveIndex \(primitiveIndex) out of bounds for mesh \(meshIndex) (count: \(mesh.primitives.count))")
        }
        let primitive = mesh.primitives[primitiveIndex]
        guard positions.count == primitive.vertexCount else {
            throw VRMError.invalidEdit("Position count \(positions.count) does not match primitive vertexCount \(primitive.vertexCount)")
        }
        guard let existingVB = primitive.vertexBuffer else {
            throw VRMError.invalidEdit("Primitive (\(meshIndex), \(primitiveIndex)) has no GPU vertexBuffer to update")
        }

        if !positions.isEmpty {
            let targetDevice = device ?? model.device ?? existingVB.device
            let posVertices = positions.map { VRMPositionVertex(position: $0) }
            guard let newVB = posVertices.withUnsafeBytes({ bytes in
                targetDevice.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
            }) else {
                throw VRMError.invalidEdit("Failed to allocate replacement position vertex buffer (\(positions.count) vertices)")
            }
            newVB.label = existingVB.label

            var newBasePos: MTLBuffer? = nil
            if let existingBase = primitive.basePositionsBuffer {
                guard let allocated = positions.withUnsafeBytes({ bytes in
                    targetDevice.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
                }) else {
                    throw VRMError.invalidEdit("Failed to allocate replacement morph base positions buffer (\(positions.count) vertices)")
                }
                allocated.label = existingBase.label
                newBasePos = allocated
            }

            var lo = positions[0]
            var hi = positions[0]
            for p in positions {
                lo = simd_min(lo, p)
                hi = simd_max(hi, p)
            }
            primitive.vertexBuffer = newVB
            if let newBasePos {
                primitive.basePositionsBuffer = newBasePos
            }
            primitive.localMin = lo
            primitive.localMax = hi
        }
        geometryDirty = true
        boundsDirty = true
    }

    /// Publishes updated vertex streams on the specified mesh primitive using copy-on-write
    /// buffer replacement so in-flight GPU frames never race with CPU writes.
    ///
    /// - When `vertices.count == primitive.vertexCount`, replaces GPU vertex/attribute/morph-base
    ///   buffers without bumping ``VRMModel/topologyRevision`` (only ``VRMModel/geometryRevision``).
    /// - When `vertices.count != primitive.vertexCount`, validates dependent index and morph
    ///   buffers, rebuilds morph SoA buffers from retained CPU deltas (throwing ``VRMError/invalidEdit(_:)``
    ///   if CPU deltas were already dropped), clears stale first-person visibility buffers, and
    ///   marks topology modified.
    public func updateVertices(
        _ vertices: [VRMVertex],
        meshIndex: Int,
        primitiveIndex: Int,
        device: MTLDevice? = nil
    ) throws {
        guard meshIndex >= 0 && meshIndex < model.meshes.count else {
            throw VRMError.invalidEdit("meshIndex \(meshIndex) out of bounds (count: \(model.meshes.count))")
        }
        let mesh = model.meshes[meshIndex]
        guard primitiveIndex >= 0 && primitiveIndex < mesh.primitives.count else {
            throw VRMError.invalidEdit("primitiveIndex \(primitiveIndex) out of bounds for mesh \(meshIndex) (count: \(mesh.primitives.count))")
        }
        let primitive = mesh.primitives[primitiveIndex]
        guard let targetDevice = device ?? model.device ?? primitive.vertexBuffer?.device else {
            throw VRMError.invalidEdit("No MTLDevice available to allocate vertex buffers for primitive (\(meshIndex), \(primitiveIndex))")
        }

        let countChanged = vertices.count != primitive.vertexCount

        if countChanged {
            if primitive.morphTargetCount > 0 && !vertices.isEmpty {
                let hasRetainedDeltas = primitive.morphTargets.contains { $0.positionDeltas != nil }
                guard hasRetainedDeltas else {
                    throw VRMError.invalidEdit(
                        "Cannot resize vertexCount from \(primitive.vertexCount) to \(vertices.count) on morph-bearing primitive (\(meshIndex), \(primitiveIndex)) after CPU morph deltas were released; load with VRMLoadingOptions(retainCPUMorphDeltas: true) or replace the mesh."
                    )
                }
            }
            if vertices.count < primitive.vertexCount,
               let indexBuffer = primitive.indexBuffer,
               primitive.indexCount > 0 {
                let maxIdx = Self.maxIndexValue(in: indexBuffer, count: primitive.indexCount, type: primitive.indexType, byteOffset: primitive.indexBufferOffset)
                if maxIdx >= vertices.count {
                    throw VRMError.invalidEdit(
                        "Cannot shrink vertexCount to \(vertices.count) on primitive (\(meshIndex), \(primitiveIndex)) while indexBuffer references vertex index \(maxIdx); upload replacement indices first."
                    )
                }
            }
        }

        // Sanitize sentinel joint indices and compute required palette size before upload.
        var sanitizedVertices = vertices
        var maxJoint: UInt32 = 0
        var hasJointData = primitive.hasJoints
        for i in sanitizedVertices.indices {
            var j = sanitizedVertices[i].joints
            if j.x >= 65535 { j.x = 0 }
            if j.y >= 65535 { j.y = 0 }
            if j.z >= 65535 { j.z = 0 }
            if j.w >= 65535 { j.w = 0 }
            sanitizedVertices[i].joints = j
            if j.x != 0 || j.y != 0 || j.z != 0 || j.w != 0 {
                hasJointData = true
            }
            maxJoint = max(maxJoint, max(max(j.x, j.y), max(j.z, j.w)))
        }

        primitive.uploadVertices(sanitizedVertices, device: targetDevice)
        if !sanitizedVertices.isEmpty && (primitive.vertexBuffer == nil || primitive.attributeBuffer == nil) {
            throw VRMError.invalidEdit("Failed to allocate GPU vertex/attribute buffers for primitive (\(meshIndex), \(primitiveIndex))")
        }

        primitive.skinningInputSample = nil
        if hasJointData {
            primitive.hasJoints = true
            primitive.requiredPaletteSize = sanitizedVertices.isEmpty ? 0 : Int(maxJoint) + 1
            if !model.skins.isEmpty {
                VRMResourceLoader.sanitizeAllMeshJoints(
                    nodes: model.nodes,
                    meshes: [mesh],
                    skins: model.skins
                )
            }
        }

        if countChanged {
            if primitive.firstPersonHiddenFlags.count != sanitizedVertices.count {
                primitive.firstPersonHiddenFlags = []
                primitive.firstPersonHiddenFlagsBuffer = nil
            }
            if !primitive.morphTargets.isEmpty {
                primitive.basePositionsBuffer = nil
                primitive.baseNormalsBuffer = nil
                primitive.morphPositionsSoA = nil
                primitive.morphNormalsSoA = nil
                primitive.uploadedMorphTargetCount = 0
                primitive.uploadedMorphVertexCount = 0
                if !sanitizedVertices.isEmpty {
                    primitive.createMorphTargetBuffers(device: targetDevice)
                }
            }
            topologyDirty = true
        } else {
            if let existingBasePos = primitive.basePositionsBuffer, !sanitizedVertices.isEmpty {
                let positions = sanitizedVertices.map(\.position)
                guard let newBasePos = positions.withUnsafeBytes({ bytes in
                    targetDevice.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
                }) else {
                    throw VRMError.invalidEdit("Failed to allocate replacement morph base positions buffer")
                }
                newBasePos.label = existingBasePos.label
                primitive.basePositionsBuffer = newBasePos
            }
            if let existingBaseNorm = primitive.baseNormalsBuffer, !sanitizedVertices.isEmpty {
                let normals = sanitizedVertices.map(\.normal)
                guard let newBaseNorm = normals.withUnsafeBytes({ bytes in
                    targetDevice.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
                }) else {
                    throw VRMError.invalidEdit("Failed to allocate replacement morph base normals buffer")
                }
                newBaseNorm.label = existingBaseNorm.label
                primitive.baseNormalsBuffer = newBaseNorm
            }
        }

        if let first = sanitizedVertices.first {
            var lo = first.position
            var hi = first.position
            for v in sanitizedVertices {
                lo = simd_min(lo, v.position)
                hi = simd_max(hi, v.position)
            }
            primitive.localMin = lo
            primitive.localMax = hi
        } else {
            primitive.localMin = .zero
            primitive.localMax = .zero
        }
        geometryDirty = true
        boundsDirty = true
    }

    private static func maxIndexValue(in buffer: MTLBuffer, count: Int, type: MTLIndexType, byteOffset: Int) -> Int {
        let basePtr = buffer.contents().advanced(by: byteOffset)
        var maxVal = 0
        switch type {
        case .uint16:
            let elemCount = min(count, max(0, (buffer.length - byteOffset) / MemoryLayout<UInt16>.stride))
            let ptr = basePtr.bindMemory(to: UInt16.self, capacity: elemCount)
            for i in 0..<elemCount { maxVal = max(maxVal, Int(ptr[i])) }
        case .uint32:
            let elemCount = min(count, max(0, (buffer.length - byteOffset) / MemoryLayout<UInt32>.stride))
            let ptr = basePtr.bindMemory(to: UInt32.self, capacity: elemCount)
            for i in 0..<elemCount { maxVal = max(maxVal, Int(ptr[i])) }
        @unknown default:
            break
        }
        return maxVal
    }

    /// Updates a node's bind pose (`initialTranslation`/`initialRotation`/`initialScale`)
    /// and current local transform, propagating world matrices down its subtree and marking
    /// skin content (and SpringBone rest data, when present) modified.
    public func updateNodeBindPose(
        at index: Int,
        translation: SIMD3<Float>? = nil,
        rotation: simd_quatf? = nil,
        scale: SIMD3<Float>? = nil
    ) {
        guard index >= 0 && index < model.nodes.count else { return }
        let node = model.nodes[index]
        if let translation {
            node.initialTranslation = translation
            node.translation = translation
        }
        if let rotation {
            node.initialRotation = rotation
            node.rotation = rotation
        }
        if let scale {
            node.initialScale = scale
            node.scale = scale
        }
        node.updateLocalMatrix()
        node.updateWorldTransform()
        skinContentDirty = true
        if model.springBone != nil {
            physicsDirty = true
        }
    }

    /// Replaces a skin's inverse bind matrices in place and marks skin content modified.
    ///
    /// - Throws: ``VRMError/invalidEdit(_:)`` if `skinIndex` is out of bounds or
    ///   `matrices.count` does not match the skin's joint count.
    public func updateSkinInverseBindMatrices(_ matrices: [float4x4], skinIndex: Int) throws {
        guard skinIndex >= 0 && skinIndex < model.skins.count else {
            throw VRMError.invalidEdit("skinIndex \(skinIndex) out of bounds (count: \(model.skins.count))")
        }
        let skin = model.skins[skinIndex]
        guard matrices.count == skin.joints.count else {
            throw VRMError.invalidEdit("Inverse bind matrix count \(matrices.count) does not match joint count \(skin.joints.count) for skin \(skinIndex)")
        }
        skin.inverseBindMatrices = matrices
        skinContentDirty = true
    }

    /// Replaces the model's SpringBone configuration and re-initializes GPU physics buffers
    /// when a Metal device is available, bumping ``VRMModel/physicsRevision``.
    ///
    /// Rolls back to the previous SpringBone state if quota validation or GPU allocation throws.
    public func replaceSpringBone(
        _ springBone: VRMSpringBone?,
        augmentColliders: Bool = true,
        limits: VRMLoaderLimits = .default,
        device: MTLDevice? = nil
    ) throws {
        if let sb = springBone {
            let totalBones = sb.springs.reduce(0) { $0 + $1.joints.count }
            if totalBones > limits.maxSpringBones {
                throw VRMError.limitExceeded(
                    kind: "springBones",
                    limit: limits.maxSpringBones,
                    observed: totalBones
                )
            }
        }

        let previousSpringBone = model.springBone
        let previousBuffers = model.springBoneBuffers
        let previousGlobalParams = model.springBoneGlobalParams

        do {
            model.springBone = springBone
            if springBone == nil {
                model.springBoneBuffers = nil
                model.springBoneGlobalParams = nil
            } else if let targetDevice = device ?? model.device {
                try model.initializeSpringBoneGPUSystem(
                    device: targetDevice,
                    augmentColliders: augmentColliders,
                    limits: limits
                )
            }
            physicsDirty = true
        } catch {
            model.springBone = previousSpringBone
            model.springBoneBuffers = previousBuffers
            model.springBoneGlobalParams = previousGlobalParams
            throw error
        }
    }

    // MARK: - Structural Additions

    /// Appends a texture to `model.textures`, marks materials modified, and returns its new index.
    @discardableResult
    public func addTexture(_ texture: VRMTexture) -> Int {
        let index = model.textures.count
        model.textures.append(texture)
        materialsDirty = true
        return index
    }

    /// Appends a material to `model.materials`, marks materials modified, and returns its new index.
    @discardableResult
    public func addMaterial(_ material: VRMMaterial) -> Int {
        let index = model.materials.count
        model.materials.append(material)
        materialsDirty = true
        return index
    }

    /// Appends a mesh to `model.meshes`, marks topology modified, and returns its new index.
    @discardableResult
    public func addMesh(_ mesh: VRMMesh) -> Int {
        let index = model.meshes.count
        model.meshes.append(mesh)
        topologyDirty = true
        return index
    }

    /// Appends a node to `model.nodes`, optionally parenting it under `model.nodes[parentIndex]`,
    /// refreshes world transforms and node lookup cache, marks topology modified, and returns its index.
    ///
    /// - Throws: ``VRMError/invalidEdit(_:)`` if `node` is already in `model.nodes`, if `parentIndex`
    ///   is out of bounds (including self-parenting), or if parenting would introduce a cycle.
    @discardableResult
    public func addNode(_ node: VRMNode, parentIndex: Int? = nil) throws -> Int {
        guard !model.nodes.contains(where: { $0 === node }) else {
            throw VRMError.invalidEdit("Node '\(node.name ?? "#\(node.index)")' is already present in model.nodes")
        }
        let index = model.nodes.count
        var resolvedParent: VRMNode? = nil
        if let parentIndex {
            guard parentIndex >= 0 && parentIndex < index else {
                throw VRMError.invalidEdit("parentIndex \(parentIndex) out of bounds for existing nodes (count: \(index))")
            }
            let candidate = model.nodes[parentIndex]
            var ancestor: VRMNode? = candidate
            while let current = ancestor {
                if current === node {
                    throw VRMError.invalidEdit("Parenting node '\(node.name ?? "#\(node.index)")' under parentIndex \(parentIndex) would create a hierarchy cycle")
                }
                ancestor = current.parent
            }
            resolvedParent = candidate
        }

        model.nodes.append(node)
        if let parent = resolvedParent {
            node.parent = parent
            if !parent.children.contains(where: { $0 === node }) {
                parent.children.append(node)
            }
        }
        node.updateWorldTransform()
        model.buildNodeLookupTable()
        topologyDirty = true
        return index
    }

    /// Appends a skin to `model.skins`, marks skin layout and topology modified, and returns its new index.
    @discardableResult
    public func addSkin(_ skin: VRMSkin) -> Int {
        let index = model.skins.count
        model.skins.append(skin)
        skinLayoutDirty = true
        topologyDirty = true
        return index
    }

    /// Marks scene topology (nodes, meshes, primitives, alpha/cull/queue modes) as modified.
    public func markTopologyModified() {
        topologyDirty = true
    }

    /// Marks material colors, textures, or MToon parameters as modified.
    public func markMaterialsModified() {
        materialsDirty = true
    }

    /// Marks node or primitive visibility flags as modified.
    public func markVisibilityModified() {
        visibilityDirty = true
    }

    /// Marks the set of skins or their joint counts as modified.
    public func markSkinsLayoutModified() {
        skinLayoutDirty = true
    }

    /// Marks skin joint arrays or inverse bind matrices as modified (same layout).
    public func markSkinsContentModified() {
        skinContentDirty = true
    }

    /// Marks SpringBone chains or colliders as modified.
    public func markPhysicsModified() {
        physicsDirty = true
    }
}
