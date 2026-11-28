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

/// Opaque handle uniquely identifying an attached 3D cosmetic on a ``VRMModel``.
public struct VRMAttachmentHandle: Hashable, Sendable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

/// Local TRS transform applied to an attached cosmetic's pivot node relative to its anchor.
public struct VRMAttachmentTransform: Sendable, Equatable {
    public var translation: SIMD3<Float>
    public var rotation: simd_quatf
    public var scale: SIMD3<Float>

    public init(
        translation: SIMD3<Float> = .zero,
        rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
        scale: SIMD3<Float> = SIMD3<Float>(1, 1, 1)
    ) {
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
    }

    public static let identity = VRMAttachmentTransform()

    public static func == (lhs: VRMAttachmentTransform, rhs: VRMAttachmentTransform) -> Bool {
        lhs.translation == rhs.translation
            && lhs.rotation.vector == rhs.rotation.vector
            && lhs.scale == rhs.scale
    }
}

/// Strategy used by ``VRMModel/attachSkinned(_:options:)`` to fit a skinned
/// garment's bind pose onto a target avatar's proportions.
public enum VRMProportionFitMode: Sendable, Equatable {
    /// Transfers bind frames without uniform scaling (1:1 metric fit).
    case exact
    /// Computes a single uniform garment scale and hips/torso translation from
    /// matched humanoid bone spans, baking scale into cloned geometry so LBS and DQS match.
    case proportionFit
}

/// Semantic avatar body region used by ``VRMCosmeticColliderBinding/matchingHostRegions(_:)``.
public enum VRMColliderRegion: String, CaseIterable, Hashable, Sendable {
    case head
    case neck
    case chest
    case torso
    case hips
    case leftArm
    case rightArm
    case leftLeg
    case rightLeg
}

/// Controls which host collider groups interact with an attached cosmetic's SpringBone chains.
public enum VRMCosmeticColliderBinding: Equatable, Sendable {
    /// Collide against all authored host collider groups (plus the host's synthetic swept group).
    case allHostColliders
    /// Collide only against host collider groups whose collider nodes fall in the requested regions.
    case matchingHostRegions(Set<VRMColliderRegion>)
    /// Collide only against explicit authored host collider group indices.
    case hostGroupIndices([Int])
    /// Collide only against colliders authored on the cosmetic itself (no host colliders).
    case cosmeticOnly
}

/// Configuration for attaching a ``VRMCosmeticAsset`` via ``VRMModel/attach(_:to:options:)``
/// or ``VRMModel/attachSkinned(_:options:)``.
public struct VRMAttachmentOptions: Sendable {
    /// Initial local TRS offset applied to the attachment pivot.
    public var transform: VRMAttachmentTransform
    /// First-person camera visibility override. When `nil`, `.head`-anchored rigid
    /// attachments default to `.thirdPersonOnly` and all other attachments default to `.both`.
    public var firstPersonFlag: VRMFirstPersonFlag?
    /// Explicit opt-in allowing ``VRMModel/attach(_:to:options:)`` to strip skinning attributes
    /// from a skinned `.glb` and attach it rigidly. Defaults to `false` (rejects skinned assets).
    public var rigidifySkinnedMeshes: Bool
    /// Optional MToon fallback override applied to plain PBR materials in the attached instance.
    public var mtoonFallback: VRMCosmeticMToonFallback?
    /// Proportion-fitting mode used by ``VRMModel/attachSkinned(_:options:)``.
    public var proportionFit: VRMProportionFitMode
    /// Optional set of host humanoid bones to hide beneath this cosmetic using the
    /// composable 2-bit vertex body mask (auto-cleaned on detach).
    public var bodyMaskBones: Set<VRMHumanoidBone>?
    /// Skinning weight threshold used when generating a body mask from ``bodyMaskBones``.
    public var bodyMaskWeightThreshold: Float
    /// Host collider binding policy for any SpringBone chains carried by the cosmetic.
    public var colliderBinding: VRMCosmeticColliderBinding
    /// Cumulative resource quotas enforced across host + all active attachments.
    public var limits: VRMLoaderLimits

    public init(
        transform: VRMAttachmentTransform = .identity,
        firstPersonFlag: VRMFirstPersonFlag? = nil,
        rigidifySkinnedMeshes: Bool = false,
        mtoonFallback: VRMCosmeticMToonFallback? = nil,
        proportionFit: VRMProportionFitMode = .proportionFit,
        bodyMaskBones: Set<VRMHumanoidBone>? = nil,
        bodyMaskWeightThreshold: Float = 0.25,
        colliderBinding: VRMCosmeticColliderBinding = .allHostColliders,
        limits: VRMLoaderLimits = .default
    ) {
        self.transform = transform
        self.firstPersonFlag = firstPersonFlag
        self.rigidifySkinnedMeshes = rigidifySkinnedMeshes
        self.mtoonFallback = mtoonFallback
        self.proportionFit = proportionFit
        self.bodyMaskBones = bodyMaskBones
        self.bodyMaskWeightThreshold = bodyMaskWeightThreshold
        self.colliderBinding = colliderBinding
        self.limits = limits
    }
}

/// Live side-scene instance representing an attached 3D cosmetic on a ``VRMModel``.
///
/// Conforms to ``VRMSceneContent`` so ``VRMRenderer`` renders base and attached
/// geometry through a single unified pipeline without mutating the host model's
/// `nodes`, `meshes`, `materials`, `textures`, `skins`, or `nodeLookupTable`.
public final class VRMAttachmentInstance: VRMSceneContent, @unchecked Sendable {
    public let handle: VRMAttachmentHandle
    public let name: String?
    public let anchorBone: VRMHumanoidBone?
    public weak var anchorNode: VRMNode?
    public let pivotNode: VRMNode
    public let nodes: [VRMNode]
    public let meshes: [VRMMesh]
    public let materials: [VRMMaterial]
    public let textures: [VRMTexture]
    public let skins: [VRMSkin]
    public internal(set) var firstPersonFlag: VRMFirstPersonFlag
    public internal(set) var isHidden: Bool = false
    public let colliderBinding: VRMCosmeticColliderBinding
    public let springBone: VRMSpringBone?

    internal let isSkinnedAttachment: Bool
    internal let parentAttachmentHandle: VRMAttachmentHandle?
    internal let bodyMaskID: String?
    internal let secondaryRoots: [VRMNode]
    internal let estimatedBufferBytes: Int
    internal let springBoneJointCount: Int

    internal init(
        handle: VRMAttachmentHandle,
        name: String?,
        anchorBone: VRMHumanoidBone?,
        anchorNode: VRMNode?,
        pivotNode: VRMNode,
        nodes: [VRMNode],
        meshes: [VRMMesh],
        materials: [VRMMaterial],
        textures: [VRMTexture],
        skins: [VRMSkin],
        firstPersonFlag: VRMFirstPersonFlag,
        colliderBinding: VRMCosmeticColliderBinding,
        springBone: VRMSpringBone?,
        isSkinnedAttachment: Bool,
        parentAttachmentHandle: VRMAttachmentHandle?,
        bodyMaskID: String?,
        secondaryRoots: [VRMNode],
        estimatedBufferBytes: Int,
        springBoneJointCount: Int
    ) {
        self.handle = handle
        self.name = name
        self.anchorBone = anchorBone
        self.anchorNode = anchorNode
        self.pivotNode = pivotNode
        self.nodes = nodes
        self.meshes = meshes
        self.materials = materials
        self.textures = textures
        self.skins = skins
        self.firstPersonFlag = firstPersonFlag
        self.colliderBinding = colliderBinding
        self.springBone = springBone
        self.isSkinnedAttachment = isSkinnedAttachment
        self.parentAttachmentHandle = parentAttachmentHandle
        self.bodyMaskID = bodyMaskID
        self.secondaryRoots = secondaryRoots
        self.estimatedBufferBytes = estimatedBufferBytes
        self.springBoneJointCount = springBoneJointCount
    }

    internal func updateWorldTransforms() {
        pivotNode.updateWorldTransform()
        for root in secondaryRoots {
            root.updateWorldTransform()
        }
    }
}

// MARK: - VRMModel Attachment APIs

extension VRMModel {
    /// Attaches a rigid ``VRMCosmeticAsset`` to the specified humanoid anchor bone.
    ///
    /// Rejects skinned assets with ``VRMError/unsupportedSkinnedAttachment(assetName:skinCount:)``
    /// unless `options.rigidifySkinnedMeshes` is explicitly set to `true`.
    @discardableResult
    public func attach(
        _ asset: VRMCosmeticAsset,
        to bone: VRMHumanoidBone,
        options: VRMAttachmentOptions = VRMAttachmentOptions()
    ) throws -> VRMAttachmentHandle {
        let anchorNode: VRMNode = try withLock {
            guard let nodeIndex = humanoid?.getBoneNode(bone),
                  nodeIndex >= 0, nodeIndex < nodes.count else {
                throw VRMError.anchorBoneNotFound(bone: bone)
            }
            return nodes[nodeIndex]
        }
        return try attachRigid(asset, toNode: anchorNode, anchorBone: bone, options: options)
    }

    /// Attaches a rigid ``VRMCosmeticAsset`` to an explicit host or attachment scene node.
    @discardableResult
    public func attach(
        _ asset: VRMCosmeticAsset,
        toNode anchorNode: VRMNode,
        options: VRMAttachmentOptions = VRMAttachmentOptions()
    ) throws -> VRMAttachmentHandle {
        try attachRigid(asset, toNode: anchorNode, anchorBone: nil, options: options)
    }

    private func attachRigid(
        _ asset: VRMCosmeticAsset,
        toNode anchorNode: VRMNode,
        anchorBone: VRMHumanoidBone?,
        options: VRMAttachmentOptions
    ) throws -> VRMAttachmentHandle {
        if asset.isSkinned && !options.rigidifySkinnedMeshes {
            throw VRMError.unsupportedSkinnedAttachment(
                assetName: asset.name,
                skinCount: max(1, asset.skins.count)
            )
        }

        // Off-lock preparation: clone CPU scene graph and optionally strip skinning.
        var cloned = asset.cloneScene(mtoonFallbackOverride: options.mtoonFallback)
        if asset.isSkinned && options.rigidifySkinnedMeshes {
            cloned.skins.removeAll()
            for node in cloned.nodes {
                node.skin = nil
            }
            for mesh in cloned.meshes {
                for primitive in mesh.primitives {
                    primitive.hasJoints = false
                    primitive.hasWeights = false
                    primitive.requiredPaletteSize = 0
                }
            }
        }

        let handle = VRMAttachmentHandle()
        let pivotNode = VRMNode(
            index: -1,
            name: "attachment_pivot_\(handle.id.uuidString)",
            translation: options.transform.translation,
            rotation: options.transform.rotation,
            scale: options.transform.scale
        )
        // Offline parent links keep VRMNode.parentHierarchyRevision and host anchorNode.children untouched.
        pivotNode.setParentOffline(anchorNode)
        for rootIdx in cloned.rootNodeIndices where rootIdx >= 0 && rootIdx < cloned.nodes.count {
            let root = cloned.nodes[rootIdx]
            if root.parent == nil {
                root.setParentOffline(pivotNode)
                pivotNode.children.append(root)
            }
        }

        let effectiveFPFlag = options.firstPersonFlag ?? (anchorBone == .head ? .thirdPersonOnly : .both)
        let bodyMaskID = (options.bodyMaskBones?.isEmpty == false)
            ? "attachment.\(handle.id.uuidString)"
            : nil

        // Brief locked splice into side-scene list.
        try withLock {
            try validateCumulativeLimitsLocked(adding: asset, limits: options.limits)

            let parentHandle = attachments.first { existing in
                existing.pivotNode === anchorNode || existing.nodes.contains { $0 === anchorNode }
            }?.handle

            let instance = VRMAttachmentInstance(
                handle: handle,
                name: asset.name,
                anchorBone: anchorBone,
                anchorNode: anchorNode,
                pivotNode: pivotNode,
                nodes: cloned.nodes,
                meshes: cloned.meshes,
                materials: cloned.materials,
                textures: cloned.textures,
                skins: cloned.skins,
                firstPersonFlag: effectiveFPFlag,
                colliderBinding: options.colliderBinding,
                springBone: cloned.springBone,
                isSkinnedAttachment: false,
                parentAttachmentHandle: parentHandle,
                bodyMaskID: bodyMaskID,
                secondaryRoots: [],
                estimatedBufferBytes: asset.estimatedBufferBytes,
                springBoneJointCount: asset.springBoneJointCount
            )
            instance.updateWorldTransforms()
            attachments.append(instance)

            if let bodyMaskID, let bones = options.bodyMaskBones {
                setBodyMaskLocked(
                    id: bodyMaskID,
                    bones: bones,
                    weightThreshold: options.bodyMaskWeightThreshold
                )
            }

            bumpTopologyRevisionLocked()
            if cloned.springBone != nil {
                bumpPhysicsRevisionLocked()
            }
        }

        finalizeModelLocalBounds()
        return handle
    }

    /// Updates an attached cosmetic's local TRS transform in place without detaching,
    /// re-attaching, or rebuilding renderer caches.
    @discardableResult
    public func updateTransform(
        for handle: VRMAttachmentHandle,
        translation: SIMD3<Float>? = nil,
        rotation: simd_quatf? = nil,
        scale: SIMD3<Float>? = nil
    ) -> Bool {
        let updated: Bool = withLock {
            guard let instance = attachments.first(where: { $0.handle == handle }) else {
                return false
            }
            if let translation {
                instance.pivotNode.translation = translation
                instance.pivotNode.initialTranslation = translation
            }
            if let rotation {
                instance.pivotNode.rotation = rotation
                instance.pivotNode.initialRotation = rotation
            }
            if let scale {
                instance.pivotNode.scale = scale
                instance.pivotNode.initialScale = scale
            }
            instance.pivotNode.updateLocalMatrix()
            updateAttachmentWorldTransformsLocked()
            return true
        }
        if updated {
            finalizeModelLocalBounds()
        }
        return updated
    }

    /// Updates the first-person visibility flag for an attached cosmetic.
    @discardableResult
    public func setFirstPersonFlag(
        _ flag: VRMFirstPersonFlag,
        for handle: VRMAttachmentHandle
    ) -> Bool {
        withLock {
            guard let instance = attachments.first(where: { $0.handle == handle }) else {
                return false
            }
            if instance.firstPersonFlag != flag {
                instance.firstPersonFlag = flag
                bumpTopologyRevisionLocked()
            }
            return true
        }
    }

    /// Shows or hides an attached cosmetic without detaching it or rebuilding render items.
    @discardableResult
    public func setHidden(_ hidden: Bool, for handle: VRMAttachmentHandle) -> Bool {
        var changed = false
        let found: Bool = withLock {
            guard let instance = attachments.first(where: { $0.handle == handle }) else {
                return false
            }
            if instance.isHidden != hidden {
                instance.isHidden = hidden
                instance.pivotNode.isHidden = hidden
                bumpVisibilityRevisionLocked()
                changed = true
            }
            return true
        }
        if changed {
            finalizeModelLocalBounds()
        }
        return found
    }

    /// Detaches the cosmetic identified by `handle` along with any nested child attachments
    /// anchored to its nodes. Returns every detached handle (empty if `handle` was not found).
    @discardableResult
    public func detach(_ handle: VRMAttachmentHandle) -> [VRMAttachmentHandle] {
        let removedHandles: [VRMAttachmentHandle] = withLock {
            guard attachments.contains(where: { $0.handle == handle }) else { return [] }

            // Collect handle plus all transitive child attachments.
            var toRemove: Set<VRMAttachmentHandle> = [handle]
            var expanded = true
            while expanded {
                expanded = false
                for inst in attachments where !toRemove.contains(inst.handle) {
                    if let parentHandle = inst.parentAttachmentHandle, toRemove.contains(parentHandle) {
                        toRemove.insert(inst.handle)
                        expanded = true
                    }
                }
            }

            var removedList: [VRMAttachmentHandle] = []
            var hadSkins = false
            var hadPhysics = false

            attachments.removeAll { inst in
                guard toRemove.contains(inst.handle) else { return false }
                removedList.append(inst.handle)
                if !inst.skins.isEmpty { hadSkins = true }
                if inst.springBone != nil { hadPhysics = true }
                if let maskID = inst.bodyMaskID {
                    removeBodyMaskLocked(id: maskID)
                }
                inst.pivotNode.setParentOffline(nil)
                for secRoot in inst.secondaryRoots {
                    secRoot.setParentOffline(nil)
                }
                return true
            }

            if !removedList.isEmpty {
                bumpTopologyRevisionLocked()
                if hadSkins { bumpSkinLayoutRevisionLocked() }
                if hadPhysics { bumpPhysicsRevisionLocked() }
            }
            return removedList
        }

        if !removedHandles.isEmpty {
            finalizeModelLocalBounds()
        }
        return removedHandles
    }

    /// Detaches every active cosmetic attachment and removes their body masks.
    @discardableResult
    public func detachAll() -> [VRMAttachmentHandle] {
        let removedHandles: [VRMAttachmentHandle] = withLock {
            guard !attachments.isEmpty else { return [] }
            let handles = attachments.map(\.handle)
            let hadSkins = attachments.contains { !$0.skins.isEmpty }
            let hadPhysics = attachments.contains { $0.springBone != nil }
            for inst in attachments {
                if let maskID = inst.bodyMaskID {
                    removeBodyMaskLocked(id: maskID)
                }
                inst.pivotNode.setParentOffline(nil)
                for secRoot in inst.secondaryRoots {
                    secRoot.setParentOffline(nil)
                }
            }
            attachments.removeAll()
            bumpTopologyRevisionLocked()
            if hadSkins { bumpSkinLayoutRevisionLocked() }
            if hadPhysics { bumpPhysicsRevisionLocked() }
            return handles
        }

        if !removedHandles.isEmpty {
            finalizeModelLocalBounds()
        }
        return removedHandles
    }

    /// Returns the live attachment instance for `handle`, if still attached.
    public func attachment(for handle: VRMAttachmentHandle) -> VRMAttachmentInstance? {
        withLock {
            attachments.first { $0.handle == handle }
        }
    }

    /// Updates world matrices for all attached side scenes from their current anchor nodes.
    public func updateAttachmentWorldTransforms() {
        withLock {
            updateAttachmentWorldTransformsLocked()
        }
    }

    internal func updateAttachmentWorldTransformsLocked() {
        for attachment in attachments {
            attachment.updateWorldTransforms()
        }
    }

    internal func validateCumulativeLimitsLocked(
        adding asset: VRMCosmeticAsset,
        limits: VRMLoaderLimits
    ) throws {
        let hostBufferBytes: Int
        if let gltfBuffers = gltf?.buffers {
            hostBufferBytes = try VRMModel.checkedSumBufferBytes(gltfBuffers.map { max(0, $0.byteLength) }, limit: limits.maxTotalBufferBytes)
        } else {
            hostBufferBytes = estimatedHostBufferBytes
        }
        let existingAttachedBytes = try VRMModel.checkedSumBufferBytes(attachments.map { max(0, $0.estimatedBufferBytes) }, limit: limits.maxTotalBufferBytes)
        let totalBytes = try VRMModel.checkedSumBufferBytes([hostBufferBytes, existingAttachedBytes, max(0, asset.estimatedBufferBytes)], limit: limits.maxTotalBufferBytes)
        if totalBytes > limits.maxTotalBufferBytes {
            throw VRMError.limitExceeded(
                kind: "totalBufferBytes",
                limit: limits.maxTotalBufferBytes,
                observed: totalBytes
            )
        }

        let hostSpringJoints = springBone?.springs.reduce(0) { $0 + $1.joints.count } ?? 0
        let existingAttachedJoints = attachments.reduce(0) { $0 + $1.springBoneJointCount }
        let totalSpringJoints = hostSpringJoints + existingAttachedJoints + asset.springBoneJointCount
        if totalSpringJoints > limits.maxSpringBones {
            throw VRMError.limitExceeded(
                kind: "springBones",
                limit: limits.maxSpringBones,
                observed: totalSpringJoints
            )
        }
    }
}
