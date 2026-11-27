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

// MARK: - Collider Region Bone Mapping

extension VRMColliderRegion {
    /// Humanoid bones whose subtrees belong to this semantic collider region.
    public var humanoidBones: Set<VRMHumanoidBone> {
        switch self {
        case .head:
            return [.head, .jaw, .leftEye, .rightEye]
        case .neck:
            return [.neck]
        case .chest:
            return [.chest, .upperChest]
        case .torso:
            return [.spine, .chest, .upperChest, .hips]
        case .hips:
            return [.hips]
        case .leftArm:
            return [.leftShoulder, .leftUpperArm, .leftLowerArm, .leftHand]
        case .rightArm:
            return [.rightShoulder, .rightUpperArm, .rightLowerArm, .rightHand]
        case .leftLeg:
            return [.leftUpperLeg, .leftLowerLeg, .leftFoot, .leftToes]
        case .rightLeg:
            return [.rightUpperLeg, .rightLowerLeg, .rightFoot, .rightToes]
        }
    }
}

// MARK: - Single-Solver Composed SpringBone Layout

internal struct ComposedSpringChain {
    let name: String?
    let sourceIsHost: Bool
    let jointNodes: [VRMNode?]
    let jointSettings: [VRMSpringJoint]
    let centerNodeIndex: Int?
    let centerNode: VRMNode?
    let colliderGroupMask: UInt32
    /// Full ordered joint identity key used to preserve live simulation state
    /// across dynamic cosmetic attach/detach rebuilds.
    let chainKey: [ObjectIdentifier]
}

internal struct ComposedCollider {
    let node: VRMNode
    let shape: VRMColliderShape
    let groupMask: UInt32
    let isSynthetic: Bool
}

/// Flattened, read-only composition of host + attached cosmetic SpringBone chains
/// and colliders consumed by the host's single ``SpringBoneComputeSystem``.
///
/// Preserves side-scene isolation (never mutates `model.nodes` or `model.springBone`)
/// and enforces the 32-bit collider-group mask budget (max 29 authored groups so
/// bit `count` remains reserved for host synthetic swept-CCD colliders and bit
/// `count + 1` remains reserved for cross-avatar foreign colliders).
internal struct ComposedSpringBoneLayout {
    static let maxAuthoredColliderGroupsWithCosmetics = 29

    let chains: [ComposedSpringChain]
    let authoredColliders: [ComposedCollider]
    let syntheticColliders: [ComposedCollider]
    let totalAuthoredColliderGroups: Int
    let hostAuthoredGroupCount: Int
    let hasCosmeticPhysics: Bool
    let syntheticGroupBit: UInt32
    let foreignColliderGroupIndex: UInt32
    let foreignGroupBit: UInt32

    var totalBones: Int {
        chains.reduce(0) { $0 + $1.jointNodes.count }
    }

    var allColliders: [ComposedCollider] {
        authoredColliders + syntheticColliders
    }

    func colliderCounts() -> (spheres: Int, capsules: Int, planes: Int) {
        var spheres = 0
        var capsules = 0
        var planes = 0
        for c in authoredColliders {
            switch c.shape {
            case .sphere, .insideSphere: spheres += 1
            case .capsule, .insideCapsule: capsules += 1
            case .plane: planes += 1
            }
        }
        for c in syntheticColliders {
            switch c.shape {
            case .sphere, .insideSphere: spheres += 1
            case .capsule, .insideCapsule: capsules += 1
            case .plane: break
            }
        }
        return (spheres, capsules, planes)
    }

    /// Builds a unified single-solver layout from `model.springBone` and every
    /// attached ``VRMAttachmentInstance`` that carries `springBone` metadata.
    ///
    /// Caller must hold `model.lock` (or own exclusive access to `model`).
    static func build(
        model: VRMModel,
        enforceCosmeticBudget: Bool? = nil
    ) throws -> ComposedSpringBoneLayout {
        let hostSB = model.springBone
        let physicsAttachments = model.attachments.filter { $0.springBone != nil }
        let hasCosmeticPhysics = !physicsAttachments.isEmpty
        let shouldEnforceBudget = enforceCosmeticBudget ?? hasCosmeticPhysics

        // 1. Allocate collider-group bit ranges across host + attachments.
        let hostGroupCount = hostSB?.colliderGroups.count ?? 0

        // Check if host has any ungrouped authored colliders when colliderGroups is empty.
        var hostColliderToGroupMask: [Int: UInt32] = [:]
        if let hostSB {
            for (groupIndex, group) in hostSB.colliderGroups.enumerated() {
                let bit = UInt32(1 << min(groupIndex, 31))
                for colliderIndex in group.colliders {
                    hostColliderToGroupMask[colliderIndex, default: 0] |= bit
                }
            }
        }
        let hostHasUngroupedColliders: Bool = {
            guard let hostSB else { return false }
            return hostSB.colliders.indices.contains { hostColliderToGroupMask[$0] == nil }
        }()
        let hostEffectiveGroupCount = max(hostGroupCount, hostHasUngroupedColliders ? 1 : 0)

        var nextGroupSlot = hostEffectiveGroupCount
        struct AttachmentGroupSlice {
            let groupOffset: Int
            let groupCount: Int
            let colliderToGroupMask: [Int: UInt32]
        }
        var attachmentSlices: [AttachmentGroupSlice] = []
        attachmentSlices.reserveCapacity(physicsAttachments.count)

        for attachment in physicsAttachments {
            guard let attSB = attachment.springBone else {
                attachmentSlices.append(AttachmentGroupSlice(groupOffset: nextGroupSlot, groupCount: 0, colliderToGroupMask: [:]))
                continue
            }
            let offset = nextGroupSlot
            var localMap: [Int: UInt32] = [:]
            for (gIdx, group) in attSB.colliderGroups.enumerated() {
                let globalGroup = offset + gIdx
                let bit = UInt32(1 << min(globalGroup, 31))
                for colliderIndex in group.colliders {
                    localMap[colliderIndex, default: 0] |= bit
                }
            }
            let hasUngrouped = attSB.colliders.indices.contains { localMap[$0] == nil }
            let count = max(attSB.colliderGroups.count, hasUngrouped ? 1 : 0)
            if hasUngrouped {
                let ungroupedBit = UInt32(1 << min(offset, 31))
                for idx in attSB.colliders.indices where localMap[idx] == nil {
                    localMap[idx] = ungroupedBit
                }
            }
            nextGroupSlot += count
            attachmentSlices.append(AttachmentGroupSlice(
                groupOffset: offset,
                groupCount: count,
                colliderToGroupMask: localMap
            ))
        }

        let totalAuthoredGroups = nextGroupSlot
        if shouldEnforceBudget && totalAuthoredGroups > maxAuthoredColliderGroupsWithCosmetics {
            throw VRMError.colliderGroupLimitExceeded(
                limit: maxAuthoredColliderGroupsWithCosmetics,
                observed: totalAuthoredGroups
            )
        }

        // 2. Host synthetic colliders (NEVER refit onto attached cosmetics — AGENTS.md §4).
        let cachedSynthetic: [VRMCollider]
        if let hostSB {
            cachedSynthetic = hostSB.syntheticColliders
        } else if hasCosmeticPhysics {
            // Host had no base springBone; synthesize host-only colliders once and cache.
            if let existing = model.cachedHostSyntheticColliders {
                cachedSynthetic = existing
            } else if model.humanoid != nil && totalAuthoredGroups < 30 {
                var synth = SpringBoneColliderAugmentor.synthesize(model: model)
                let prefixCount = synth.count
                let meshFitted = SpringBoneMeshFit.computeAll(model: model)
                synth.append(contentsOf: meshFitted.breasts)
                synth.append(contentsOf: meshFitted.shoulders)
                synth.append(contentsOf: meshFitted.torso)
                synth.append(contentsOf: meshFitted.hands)
                SpringBoneSegmentFit.apply(to: &synth, prefixCount: prefixCount, model: model)
                model.cachedHostSyntheticColliders = synth
                cachedSynthetic = synth
            } else {
                cachedSynthetic = []
            }
        } else {
            cachedSynthetic = []
        }

        // 3. Reserve synthetic and foreign group bits.
        let syntheticGroupIndex = UInt32(min(totalAuthoredGroups, 31))
        let hasSyntheticColliders = !cachedSynthetic.isEmpty && totalAuthoredGroups < 32
        let syntheticGroupBit: UInt32 = hasSyntheticColliders ? (1 << syntheticGroupIndex) : 0

        let foreignSlotIsSafe = totalAuthoredGroups < 30
        let foreignColliderGroupIndex: UInt32 = foreignSlotIsSafe ? UInt32(totalAuthoredGroups + 1) : 0xFFFFFFFF
        let foreignGroupBit: UInt32 = foreignSlotIsSafe ? (1 << foreignColliderGroupIndex) : 0

        // Explicit host authored bitmask so host default chains (colliderGroups.isEmpty)
        // are NEVER blasted by newly attached cosmetic colliders.
        let hostAuthoredMask: UInt32
        if hostEffectiveGroupCount == 0 {
            hostAuthoredMask = 0
        } else if hostEffectiveGroupCount >= 32 {
            hostAuthoredMask = 0xFFFFFFFF
        } else {
            hostAuthoredMask = UInt32((UInt64(1) << UInt64(hostEffectiveGroupCount)) - 1)
        }

        // Precompute host node → region lookup for `.matchingHostRegions`.
        let hostNodeRegions = buildHostNodeRegions(model: model)

        // 4. Collect authored colliders (host first, then attachments).
        var authoredColliders: [ComposedCollider] = []
        if let hostSB {
            for (colliderIndex, collider) in hostSB.colliders.enumerated() {
                guard let node = model.nodes[safe: collider.node] else { continue }
                let mask = hostColliderToGroupMask[colliderIndex] ?? 1
                authoredColliders.append(ComposedCollider(
                    node: node,
                    shape: collider.shape,
                    groupMask: mask,
                    isSynthetic: false
                ))
            }
        }
        for (attIdx, attachment) in physicsAttachments.enumerated() {
            guard let attSB = attachment.springBone else { continue }
            let slice = attachmentSlices[attIdx]
            for (colliderIndex, collider) in attSB.colliders.enumerated() {
                guard let node = attachment.nodes[safe: collider.node] else { continue }
                let fallbackBit = UInt32(1 << min(slice.groupOffset, 31))
                let mask = slice.colliderToGroupMask[colliderIndex] ?? fallbackBit
                authoredColliders.append(ComposedCollider(
                    node: node,
                    shape: collider.shape,
                    groupMask: mask,
                    isSynthetic: false
                ))
            }
        }

        // 5. Collect synthetic colliders (host nodes only, always tagged with syntheticGroupBit).
        var syntheticColliders: [ComposedCollider] = []
        if hasSyntheticColliders {
            for collider in cachedSynthetic {
                guard let node = model.nodes[safe: collider.node] else { continue }
                if case .plane = collider.shape { continue }
                syntheticColliders.append(ComposedCollider(
                    node: node,
                    shape: collider.shape,
                    groupMask: syntheticGroupBit,
                    isSynthetic: true
                ))
            }
        }

        // 6. Collect spring chains (host first, then each physics attachment).
        var chains: [ComposedSpringChain] = []

        if let hostSB {
            let hasCosmeticColliders = nextGroupSlot > hostEffectiveGroupCount
            for spring in hostSB.springs {
                guard !spring.joints.isEmpty else { continue }
                let jointNodes: [VRMNode?] = spring.joints.map { model.nodes[safe: $0.node] }
                let jointSettings = spring.joints

                var mask: UInt32 = 0
                if spring.colliderGroups.isEmpty {
                    // When cosmetic colliders exist, restrict host's default empty-group
                    // mask strictly to host authored groups (not cosmetic bits!).
                    mask = hasCosmeticColliders ? hostAuthoredMask : 0xFFFFFFFF
                } else {
                    for groupIndex in spring.colliderGroups where groupIndex >= 0 && groupIndex < 32 {
                        mask |= (1 << groupIndex)
                    }
                }
                mask |= syntheticGroupBit
                mask |= foreignGroupBit
                if (spring.name ?? "").lowercased().contains("bust") {
                    mask &= ~syntheticGroupBit
                }

                let centerNode = spring.center.flatMap { model.nodes[safe: $0] }
                chains.append(ComposedSpringChain(
                    name: spring.name,
                    sourceIsHost: true,
                    jointNodes: jointNodes,
                    jointSettings: jointSettings,
                    centerNodeIndex: spring.center,
                    centerNode: centerNode,
                    colliderGroupMask: mask,
                    chainKey: jointNodes.compactMap { $0.map(ObjectIdentifier.init) }
                ))
            }
        }

        for (attIdx, attachment) in physicsAttachments.enumerated() {
            guard let attSB = attachment.springBone else { continue }
            let slice = attachmentSlices[attIdx]

            let hostMaskForAttachment = resolveHostColliderMask(
                binding: attachment.colliderBinding,
                hostSB: hostSB,
                hostNodes: model.nodes,
                hostAuthoredMask: hostAuthoredMask,
                hostNodeRegions: hostNodeRegions,
                syntheticGroupBit: syntheticGroupBit,
                foreignGroupBit: foreignGroupBit
            )

            for spring in attSB.springs {
                guard !spring.joints.isEmpty else { continue }
                let jointNodes: [VRMNode?] = spring.joints.map { attachment.nodes[safe: $0.node] }
                let jointSettings = spring.joints

                // Cosmetic's own authored collider bits (NEVER falls back to 0xFFFFFFFF).
                var ownMask: UInt32 = 0
                if !spring.colliderGroups.isEmpty {
                    for g in spring.colliderGroups where g >= 0 && g < slice.groupCount {
                        let globalIdx = slice.groupOffset + g
                        if globalIdx < 32 {
                            ownMask |= (1 << globalIdx)
                        }
                    }
                } else if slice.groupCount > 0 {
                    for g in 0..<slice.groupCount {
                        let globalIdx = slice.groupOffset + g
                        if globalIdx < 32 {
                            ownMask |= (1 << globalIdx)
                        }
                    }
                }

                var mask = ownMask | hostMaskForAttachment
                if (spring.name ?? "").lowercased().contains("bust") {
                    mask &= ~syntheticGroupBit
                }

                let centerNode = spring.center.flatMap { attachment.nodes[safe: $0] }
                chains.append(ComposedSpringChain(
                    name: spring.name,
                    sourceIsHost: false,
                    jointNodes: jointNodes,
                    jointSettings: jointSettings,
                    centerNodeIndex: spring.center,
                    centerNode: centerNode,
                    colliderGroupMask: mask,
                    chainKey: jointNodes.compactMap { $0.map(ObjectIdentifier.init) }
                ))
            }
        }

        return ComposedSpringBoneLayout(
            chains: chains,
            authoredColliders: authoredColliders,
            syntheticColliders: syntheticColliders,
            totalAuthoredColliderGroups: totalAuthoredGroups,
            hostAuthoredGroupCount: hostEffectiveGroupCount,
            hasCosmeticPhysics: hasCosmeticPhysics,
            syntheticGroupBit: syntheticGroupBit,
            foreignColliderGroupIndex: foreignColliderGroupIndex,
            foreignGroupBit: foreignGroupBit
        )
    }

    private static func buildHostNodeRegions(model: VRMModel) -> [ObjectIdentifier: Set<VRMColliderRegion>] {
        guard let humanoid = model.humanoid else { return [:] }
        var boneRootToRegions: [ObjectIdentifier: Set<VRMColliderRegion>] = [:]
        for region in VRMColliderRegion.allCases {
            for bone in region.humanoidBones {
                if let idx = humanoid.getBoneNode(bone), let node = model.nodes[safe: idx] {
                    boneRootToRegions[ObjectIdentifier(node), default: []].insert(region)
                }
            }
        }
        var nodeRegions: [ObjectIdentifier: Set<VRMColliderRegion>] = [:]
        for node in model.nodes {
            var cursor: VRMNode? = node
            while let current = cursor {
                if let matched = boneRootToRegions[ObjectIdentifier(current)] {
                    nodeRegions[ObjectIdentifier(node)] = matched
                    break
                }
                cursor = current.parent
            }
        }
        return nodeRegions
    }

    private static func resolveHostColliderMask(
        binding: VRMCosmeticColliderBinding,
        hostSB: VRMSpringBone?,
        hostNodes: [VRMNode],
        hostAuthoredMask: UInt32,
        hostNodeRegions: [ObjectIdentifier: Set<VRMColliderRegion>],
        syntheticGroupBit: UInt32,
        foreignGroupBit: UInt32
    ) -> UInt32 {
        switch binding {
        case .allHostColliders:
            return hostAuthoredMask | syntheticGroupBit | foreignGroupBit

        case .matchingHostRegions(let regions):
            guard !regions.isEmpty else { return foreignGroupBit }
            var mask: UInt32 = foreignGroupBit
            if let hostSB {
                for (groupIdx, group) in hostSB.colliderGroups.enumerated() where groupIdx < 32 {
                    let matches = group.colliders.contains { cIdx in
                        guard let c = hostSB.colliders[safe: cIdx],
                              let node = hostNodes[safe: c.node],
                              let nodeRegs = hostNodeRegions[ObjectIdentifier(node)] else {
                            return false
                        }
                        return !nodeRegs.isDisjoint(with: regions)
                    }
                    if matches {
                        mask |= (1 << groupIdx)
                    }
                }
            }
            // Include host synthetic swept colliders when body/head/limb regions are requested.
            mask |= syntheticGroupBit
            return mask

        case .hostGroupIndices(let indices):
            let hostGroupCount = hostSB?.colliderGroups.count ?? 0
            var mask: UInt32 = foreignGroupBit
            for g in indices where g >= 0 && g < hostGroupCount && g < 32 {
                mask |= (1 << g)
            }
            return mask

        case .cosmeticOnly:
            // Strictly cosmetic's own colliders only — zero host authored, zero synthetic, zero foreign.
            return 0
        }
    }
}
