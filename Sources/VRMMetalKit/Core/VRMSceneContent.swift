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
