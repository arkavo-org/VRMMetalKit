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

    /// Updates vertex positions in place on the specified mesh primitive without reallocating
    /// GPU buffers or triggering a topology rebuild.
    ///
    /// Also updates ``VRMPrimitive/basePositionsBuffer`` (if morph targets are present) and
    /// recomputes the primitive's local AABB so whole-model frustum bounds refresh on edit exit.
    public func updatePositions(
        _ positions: [SIMD3<Float>],
        meshIndex: Int,
        primitiveIndex: Int
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
        guard let vertexBuffer = primitive.vertexBuffer else {
            throw VRMError.invalidEdit("Primitive (\(meshIndex), \(primitiveIndex)) has no GPU vertexBuffer to update in place")
        }

        if !positions.isEmpty {
            let posPtr = vertexBuffer.contents().bindMemory(to: VRMPositionVertex.self, capacity: positions.count)
            let basePtr = primitive.basePositionsBuffer?.contents().bindMemory(to: SIMD3<Float>.self, capacity: positions.count)
            var lo = positions[0]
            var hi = positions[0]
            for i in 0..<positions.count {
                let p = positions[i]
                posPtr[i].position = p
                basePtr?[i] = p
                lo = simd_min(lo, p)
                hi = simd_max(hi, p)
            }
            primitive.localMin = lo
            primitive.localMax = hi
        }
        boundsDirty = true
    }

    /// Updates all vertex streams on the specified mesh primitive.
    ///
    /// When `vertices.count == primitive.vertexCount` and both split GPU buffers exist,
    /// writes directly in place without reallocating buffers or bumping ``VRMModel/topologyRevision``.
    /// Otherwise reallocates the split GPU buffers via ``VRMPrimitive/uploadVertices(_:device:)``
    /// and marks topology modified.
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

        if vertices.count == primitive.vertexCount,
           let vertexBuffer = primitive.vertexBuffer,
           let attributeBuffer = primitive.attributeBuffer {
            let posPtr = vertexBuffer.contents().bindMemory(to: VRMPositionVertex.self, capacity: vertices.count)
            let attrPtr = attributeBuffer.contents().bindMemory(to: VRMAttributeVertex.self, capacity: vertices.count)
            let basePosPtr = primitive.basePositionsBuffer?.contents().bindMemory(to: SIMD3<Float>.self, capacity: vertices.count)
            let baseNormPtr = primitive.baseNormalsBuffer?.contents().bindMemory(to: SIMD3<Float>.self, capacity: vertices.count)
            for i in 0..<vertices.count {
                let v = vertices[i]
                posPtr[i] = VRMPositionVertex(position: v.position)
                attrPtr[i] = VRMAttributeVertex(
                    normal: v.normal,
                    texCoord: v.texCoord,
                    color: v.color,
                    joints: v.joints,
                    weights: v.weights
                )
                basePosPtr?[i] = v.position
                baseNormPtr?[i] = v.normal
            }
        } else {
            guard let targetDevice = device ?? model.device else {
                throw VRMError.invalidEdit("No MTLDevice available to reallocate vertex buffers for primitive (\(meshIndex), \(primitiveIndex))")
            }
            primitive.uploadVertices(vertices, device: targetDevice)
            if primitive.basePositionsBuffer != nil {
                if vertices.isEmpty {
                    primitive.basePositionsBuffer = nil
                    primitive.baseNormalsBuffer = nil
                } else if let newBasePos = targetDevice.makeBuffer(
                    length: vertices.count * MemoryLayout<SIMD3<Float>>.stride,
                    options: .storageModeShared
                ) {
                    newBasePos.label = "Morph Base Positions"
                    let ptr = newBasePos.contents().bindMemory(to: SIMD3<Float>.self, capacity: vertices.count)
                    for i in 0..<vertices.count { ptr[i] = vertices[i].position }
                    primitive.basePositionsBuffer = newBasePos
                }
            }
            if primitive.baseNormalsBuffer != nil, !vertices.isEmpty,
               let newBaseNorm = targetDevice.makeBuffer(
                   length: vertices.count * MemoryLayout<SIMD3<Float>>.stride,
                   options: .storageModeShared
               ) {
                newBaseNorm.label = "Morph Base Normals"
                let ptr = newBaseNorm.contents().bindMemory(to: SIMD3<Float>.self, capacity: vertices.count)
                for i in 0..<vertices.count { ptr[i] = vertices[i].normal }
                primitive.baseNormalsBuffer = newBaseNorm
            }
            topologyDirty = true
        }

        if let first = vertices.first {
            var lo = first.position
            var hi = first.position
            for v in vertices {
                lo = simd_min(lo, v.position)
                hi = simd_max(hi, v.position)
            }
            primitive.localMin = lo
            primitive.localMax = hi
        } else {
            primitive.localMin = .zero
            primitive.localMax = .zero
        }
        boundsDirty = true
    }

    /// Updates a node's bind pose (`initialTranslation`/`initialRotation`/`initialScale`)
    /// and current local transform, propagating world matrices down its subtree and marking
    /// skin content modified.
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
    }

    /// Replaces a skin's inverse bind matrices in place and marks skin content modified.
    public func updateSkinInverseBindMatrices(_ matrices: [float4x4], skinIndex: Int) {
        guard skinIndex >= 0 && skinIndex < model.skins.count else { return }
        model.skins[skinIndex].inverseBindMatrices = matrices
        skinContentDirty = true
    }

    /// Replaces the model's SpringBone configuration and re-initializes GPU physics buffers
    /// when a Metal device is available, bumping ``VRMModel/physicsRevision``.
    public func replaceSpringBone(
        _ springBone: VRMSpringBone?,
        augmentColliders: Bool = true,
        limits: VRMLoaderLimits = .default,
        device: MTLDevice? = nil
    ) throws {
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
    @discardableResult
    public func addNode(_ node: VRMNode, parentIndex: Int? = nil) -> Int {
        let index = model.nodes.count
        model.nodes.append(node)
        if let parentIndex, parentIndex >= 0 && parentIndex < model.nodes.count {
            let parent = model.nodes[parentIndex]
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
