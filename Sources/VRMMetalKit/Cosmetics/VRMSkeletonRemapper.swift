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

/// Skeleton retargeting and bind-pose adaptation engine for skinned 3D garments.
public enum VRMSkeletonRemapper {
    /// Resolves a cosmetic joint node name to a ``VRMHumanoidBone``, extending
    /// `VRMAnimationLoader.heuristicBone` with fingers and eyes while strictly
    /// excluding `J_Sec_*` secondary physics bones and rig helper nodes.
    public static func heuristicBone(forNodeName name: String) -> VRMHumanoidBone? {
        let stripped = stripNamespace(name)
        let lower = stripped.lowercased()
        guard !lower.isEmpty else { return nil }

        let tokens = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let compact = tokens.joined()

        // Strictly exclude VRoid secondary physics bones (e.g. J_Sec_L_Arm_01) and rig helpers.
        if lower.hasPrefix("j_sec") || lower.contains("_sec_")
            || (tokens.count >= 2 && tokens[0] == "j" && tokens[1] == "sec") {
            return nil
        }
        let excludedHelpers: Set<String> = ["end", "nub", "ik", "fk"]
        if tokens.contains(where: { excludedHelpers.contains($0) }) {
            return nil
        }
        if compact.hasSuffix("headtop") || compact.hasSuffix("nub") {
            return nil
        }
        if tokens.contains(where: { $0.count >= 3 && $0.allSatisfy(\.isNumber) }) {
            return nil
        }

        // Exact VRM 1.0 rawValue match first.
        if let exact = VRMHumanoidBone.allCases.first(where: { $0.rawValue.lowercased() == compact }) {
            return exact
        }

        let isLeft = hasLeftSide(lower: lower, tokens: tokens)
        let isRight = hasRightSide(lower: lower, tokens: tokens)

        // Extended eye and finger resolution (excluded by VRMA fallback, supported for gloves/goggles).
        if isLeft != isRight {
            if compact.contains("eye") && !compact.contains("brow") && !compact.contains("lash") && !compact.contains("lid") {
                return isLeft ? .leftEye : .rightEye
            }
            if let finger = resolveFingerBone(compact: compact, tokens: tokens, isLeft: isLeft) {
                return finger
            }
        }

        // Delegate primary torso/limb resolution to VRMAnimationLoader.heuristicBone.
        return VRMAnimationLoader.heuristicBone(forNodeName: name)
    }

    internal static func isSecondaryBoneName(_ name: String) -> Bool {
        let lower = stripNamespace(name).lowercased()
        let tokens = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return lower.hasPrefix("j_sec") || lower.contains("_sec_")
            || (tokens.count >= 2 && tokens[0] == "j" && tokens[1] == "sec")
    }

    private static func stripNamespace(_ name: String) -> String {
        var result = name
        if let pipe = result.lastIndex(of: "|") {
            result = String(result[result.index(after: pipe)...])
        }
        if let colon = result.lastIndex(of: ":") {
            result = String(result[result.index(after: colon)...])
        }
        return result
    }

    private static func hasLeftSide(lower: String, tokens: [String]) -> Bool {
        lower.contains("left")
            || lower.contains("_l_")
            || lower.hasSuffix(".l") || lower.contains(".l.") || lower.contains(".l_")
            || lower.hasSuffix("_l") || lower.hasSuffix("-l") || lower.contains("-l-")
            || lower.hasPrefix("l_") || lower.hasPrefix("l.") || lower.hasPrefix("l-")
            || tokens.contains("l")
    }

    private static func hasRightSide(lower: String, tokens: [String]) -> Bool {
        lower.contains("right")
            || lower.contains("_r_")
            || lower.hasSuffix(".r") || lower.contains(".r.") || lower.contains(".r_")
            || lower.hasSuffix("_r") || lower.hasSuffix("-r") || lower.contains("-r-")
            || lower.hasPrefix("r_") || lower.hasPrefix("r.") || lower.hasPrefix("r-")
            || tokens.contains("r")
    }

    private static func resolveFingerBone(
        compact: String,
        tokens: [String],
        isLeft: Bool
    ) -> VRMHumanoidBone? {
        let phalanx: Int // 1 = proximal/metacarpal, 2 = intermediate/proximal(thumb), 3 = distal
        if compact.contains("distal") || compact.hasSuffix("3") || tokens.last == "3" {
            phalanx = 3
        } else if compact.contains("intermediate") || compact.contains("mid") && !compact.contains("middle")
            || compact.hasSuffix("2") || tokens.last == "2" {
            phalanx = 2
        } else if compact.contains("metacarpal") || compact.contains("proximal")
            || compact.hasSuffix("1") || tokens.last == "1" {
            phalanx = 1
        } else {
            return nil
        }

        if compact.contains("thumb") {
            if compact.contains("metacarpal") || phalanx == 1 {
                return isLeft ? .leftThumbMetacarpal : .rightThumbMetacarpal
            } else if compact.contains("proximal") || phalanx == 2 {
                return isLeft ? .leftThumbProximal : .rightThumbProximal
            } else {
                return isLeft ? .leftThumbDistal : .rightThumbDistal
            }
        }
        if compact.contains("index") {
            switch phalanx {
            case 1: return isLeft ? .leftIndexProximal : .rightIndexProximal
            case 2: return isLeft ? .leftIndexIntermediate : .rightIndexIntermediate
            default: return isLeft ? .leftIndexDistal : .rightIndexDistal
            }
        }
        if compact.contains("middle") {
            switch phalanx {
            case 1: return isLeft ? .leftMiddleProximal : .rightMiddleProximal
            case 2: return isLeft ? .leftMiddleIntermediate : .rightMiddleIntermediate
            default: return isLeft ? .leftMiddleDistal : .rightMiddleDistal
            }
        }
        if compact.contains("ring") {
            switch phalanx {
            case 1: return isLeft ? .leftRingProximal : .rightRingProximal
            case 2: return isLeft ? .leftRingIntermediate : .rightRingIntermediate
            default: return isLeft ? .leftRingDistal : .rightRingDistal
            }
        }
        if compact.contains("little") || compact.contains("pinky") {
            switch phalanx {
            case 1: return isLeft ? .leftLittleProximal : .rightLittleProximal
            case 2: return isLeft ? .leftLittleIntermediate : .rightLittleIntermediate
            default: return isLeft ? .leftLittleDistal : .rightLittleDistal
            }
        }
        return nil
    }

    /// Computes a node's immutable bind-pose world matrix from `initialTranslation`,
    /// `initialRotation`, and `initialScale` along its ancestor chain.
    internal static func bindWorldMatrix(of node: VRMNode) -> float4x4 {
        var chain: [VRMNode] = []
        var cursor: VRMNode? = node
        var visited = Set<ObjectIdentifier>()
        while let current = cursor, visited.insert(ObjectIdentifier(current)).inserted {
            chain.append(current)
            cursor = current.parent
        }
        var world = matrix_identity_float4x4
        for item in chain.reversed() {
            world = simd_mul(world, trsMatrix(
                translation: item.initialTranslation,
                rotation: item.initialRotation,
                scale: item.initialScale
            ))
        }
        return world
    }

    internal static func trsMatrix(
        translation: SIMD3<Float>,
        rotation: simd_quatf,
        scale: SIMD3<Float>
    ) -> float4x4 {
        let q = simd_normalize(rotation)
        let rotMat = float4x4(q)
        let col0 = rotMat.columns.0 * scale.x
        let col1 = rotMat.columns.1 * scale.y
        let col2 = rotMat.columns.2 * scale.z
        let col3 = SIMD4<Float>(translation.x, translation.y, translation.z, 1.0)
        return float4x4(col0, col1, col2, col3)
    }

    internal static func decomposeTRS(_ m: float4x4) -> (translation: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>) {
        let t = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        var c0 = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        var c1 = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        var c2 = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        var sx = length(c0)
        var sy = length(c1)
        var sz = length(c2)
        if sx > 1e-6 { c0 /= sx } else { sx = 1; c0 = SIMD3<Float>(1, 0, 0) }
        if sy > 1e-6 { c1 /= sy } else { sy = 1; c1 = SIMD3<Float>(0, 1, 0) }
        if sz > 1e-6 { c2 /= sz } else { sz = 1; c2 = SIMD3<Float>(0, 0, 1) }
        var rot3 = float3x3(columns: (c0, c1, c2))
        if simd_determinant(rot3) < 0 {
            sx = -sx
            rot3.columns.0 = -rot3.columns.0
        }
        return (t, simd_normalize(simd_quatf(rot3)), SIMD3<Float>(sx, sy, sz))
    }

    internal static func orthonormalRotationMatrix(of m: float4x4) -> float4x4 {
        let (_, rot, _) = decomposeTRS(m)
        return float4x4(rot)
    }
}

// MARK: - VRMModel Skinned Garment Attachment

extension VRMModel {
    /// Attaches a skinned 3D garment (`.vrm` or skinned `.glb`) onto this avatar's
    /// skeleton via bind-pose adaptation and side-scene skinning.
    ///
    /// - Maps garment joints via `asset.humanoid` → extended `VRMSkeletonRemapper.heuristicBone`
    ///   (excluding `J_Sec_*` secondary physics bones) → host bone name match.
    /// - Reparents unmapped secondary cloth/hair roots offline under their nearest mapped host bone.
    /// - Computes adapted inverse bind matrices from `inverse(IBM)` bind frames with zero double
    ///   VRM 0.x `Ry180` conjugation, baking any uniform proportion-fit scale into copy-on-write
    ///   cloned vertex/morph buffers so LBS and DQS agree identically.
    @discardableResult
    public func attachSkinned(
        _ asset: VRMCosmeticAsset,
        options: VRMAttachmentOptions = VRMAttachmentOptions()
    ) throws -> VRMAttachmentHandle {
        // Snapshot immutable host skeleton metadata under a brief lock.
        struct HostBoneSnapshot {
            let boneToNode: [VRMHumanoidBone: VRMNode]
            let normalizedNameToNode: [String: VRMNode]
            let hostBindWorldByNode: [ObjectIdentifier: float4x4]
            let anchorRootNode: VRMNode?
            let device: MTLDevice?
        }

        let hostSnapshot: HostBoneSnapshot = withLock {
            var boneToNode: [VRMHumanoidBone: VRMNode] = [:]
            var normalizedNameToNode: [String: VRMNode] = [:]
            var bindWorlds: [ObjectIdentifier: float4x4] = [:]

            if let humanoid {
                for (bone, entry) in humanoid.humanBones where entry.node >= 0 && entry.node < nodes.count {
                    let node = nodes[entry.node]
                    boneToNode[bone] = node
                    bindWorlds[ObjectIdentifier(node)] = VRMSkeletonRemapper.bindWorldMatrix(of: node)
                }
            }
            for node in nodes {
                if let name = node.name {
                    let key = name.lowercased()
                        .replacingOccurrences(of: "_", with: "")
                        .replacingOccurrences(of: ".", with: "")
                    if !key.isEmpty && normalizedNameToNode[key] == nil {
                        normalizedNameToNode[key] = node
                    }
                }
            }
            let hipsNode = boneToNode[.hips] ?? nodes.first(where: { $0.parent == nil })
            if let hipsNode, bindWorlds[ObjectIdentifier(hipsNode)] == nil {
                bindWorlds[ObjectIdentifier(hipsNode)] = VRMSkeletonRemapper.bindWorldMatrix(of: hipsNode)
            }
            return HostBoneSnapshot(
                boneToNode: boneToNode,
                normalizedNameToNode: normalizedNameToNode,
                hostBindWorldByNode: bindWorlds,
                anchorRootNode: hipsNode,
                device: device
            )
        }

        // Off-lock clone so blueprint stays 100% immutable.
        let cloned = asset.cloneScene(mtoonFallbackOverride: options.mtoonFallback)
        let isAssetVRM0 = (asset.specVersion == .v0_0)
        let ry180 = float4x4(
            SIMD4<Float>(-1, 0,  0, 0),
            SIMD4<Float>( 0, 1,  0, 0),
            SIMD4<Float>( 0, 0, -1, 0),
            SIMD4<Float>( 0, 0,  0, 1)
        )

        // Precompute bind-pose world matrices of cloned asset nodes (already in VRM 1.0 space).
        var assetNodeBindWorld: [ObjectIdentifier: float4x4] = [:]
        assetNodeBindWorld.reserveCapacity(cloned.nodes.count)
        for node in cloned.nodes {
            assetNodeBindWorld[ObjectIdentifier(node)] = VRMSkeletonRemapper.bindWorldMatrix(of: node)
        }

        // Build authoritative asset node-index → VRMHumanoidBone map from asset.humanoid.
        var assetIndexToBone: [Int: VRMHumanoidBone] = [:]
        if let assetHumanoid = asset.humanoid {
            for (bone, entry) in assetHumanoid.humanBones {
                assetIndexToBone[entry.node] = bone
            }
        }

        // Resolve each cloned asset node to a target host node (when mapped).
        var mappedHostNodeByAssetNode: [ObjectIdentifier: VRMNode] = [:]
        var mappedBoneByAssetNode: [ObjectIdentifier: VRMHumanoidBone] = [:]
        var hostBindWorldCache = hostSnapshot.hostBindWorldByNode

        func hostBindWorld(for node: VRMNode) -> float4x4 {
            let id = ObjectIdentifier(node)
            if let cached = hostBindWorldCache[id] { return cached }
            let computed = VRMSkeletonRemapper.bindWorldMatrix(of: node)
            hostBindWorldCache[id] = computed
            return computed
        }

        for node in cloned.nodes {
            let nodeID = ObjectIdentifier(node)
            // 1. Authoritative asset.humanoid mapping.
            if let bone = assetIndexToBone[node.index],
               let hostNode = hostSnapshot.boneToNode[bone] {
                mappedHostNodeByAssetNode[nodeID] = hostNode
                mappedBoneByAssetNode[nodeID] = bone
                continue
            }
            guard let name = node.name, !name.isEmpty else { continue }
            // Never map J_Sec_* secondary physics bones to host skeleton bones.
            if VRMSkeletonRemapper.isSecondaryBoneName(name) {
                continue
            }
            // 2. Extended heuristicBone (torso, limbs, fingers, eyes; J_Sec_* excluded).
            if let bone = VRMSkeletonRemapper.heuristicBone(forNodeName: name),
               let hostNode = hostSnapshot.boneToNode[bone] {
                mappedHostNodeByAssetNode[nodeID] = hostNode
                mappedBoneByAssetNode[nodeID] = bone
                continue
            }
            // 3. Direct normalized host bone name match.
            let norm = name.lowercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: ".", with: "")
            if !norm.isEmpty, let hostNode = hostSnapshot.normalizedNameToNode[norm] {
                mappedHostNodeByAssetNode[nodeID] = hostNode
            }
        }

        // Derive each asset joint's VRM 1.0 bind frame from inverse(IBM) when invertible.
        var assetBindFrameByNode: [ObjectIdentifier: float4x4] = [:]
        for skin in cloned.skins {
            let count = min(skin.joints.count, skin.inverseBindMatrices.count)
            for i in 0..<count {
                let joint = skin.joints[i]
                let jointID = ObjectIdentifier(joint)
                guard assetBindFrameByNode[jointID] == nil else { continue }
                let ibm = skin.inverseBindMatrices[i]
                if abs(simd_determinant(ibm)) > 1e-8 {
                    let invIBM = simd_inverse(ibm)
                    // For VRM 0.0 assets, VRMResourceLoader left-multiplied IBM by Ry180:
                    //   IBM_vrm1 = Ry180 * IBM_raw => inv(IBM_vrm1) = C_raw * Ry180.
                    // Left-multiplying by Ry180 yields C_vrm1 = Ry180 * C_raw * Ry180.
                    assetBindFrameByNode[jointID] = isAssetVRM0 ? simd_mul(ry180, invIBM) : invIBM
                } else if let nodeBind = assetNodeBindWorld[jointID] {
                    assetBindFrameByNode[jointID] = nodeBind
                }
            }
        }
        for node in cloned.nodes {
            let id = ObjectIdentifier(node)
            if assetBindFrameByNode[id] == nil {
                assetBindFrameByNode[id] = assetNodeBindWorld[id] ?? matrix_identity_float4x4
            }
        }

        // Compute uniform garment proportion fit (scale + rigid offset).
        var fitScale: Float = 1.0
        var fitTranslation: SIMD3<Float> = .zero

        if options.proportionFit == .proportionFit {
            var matchedBonePositions: [VRMHumanoidBone: (host: SIMD3<Float>, asset: SIMD3<Float>)] = [:]
            for node in cloned.nodes {
                let id = ObjectIdentifier(node)
                guard let bone = mappedBoneByAssetNode[id],
                      let hostNode = mappedHostNodeByAssetNode[id],
                      matchedBonePositions[bone] == nil else { continue }
                let hPos = hostBindWorld(for: hostNode).columns.3
                let cPos = (assetBindFrameByNode[id] ?? matrix_identity_float4x4).columns.3
                matchedBonePositions[bone] = (
                    SIMD3<Float>(hPos.x, hPos.y, hPos.z),
                    SIMD3<Float>(cPos.x, cPos.y, cPos.z)
                )
            }

            let referencePairs: [(VRMHumanoidBone, VRMHumanoidBone)] = [
                (.hips, .neck),
                (.hips, .head),
                (.hips, .chest),
                (.leftUpperArm, .rightUpperArm),
                (.leftUpperLeg, .leftFoot),
                (.rightUpperLeg, .rightFoot),
            ]
            var ratios: [Float] = []
            for (a, b) in referencePairs {
                guard let pa = matchedBonePositions[a], let pb = matchedBonePositions[b] else { continue }
                let assetDist = simd_distance(pa.asset, pb.asset)
                let hostDist = simd_distance(pa.host, pb.host)
                if assetDist > 0.02 && hostDist > 0.02 {
                    ratios.append(hostDist / assetDist)
                }
            }
            if !ratios.isEmpty {
                let meanRatio = ratios.reduce(0, +) / Float(ratios.count)
                fitScale = max(0.5, min(2.0, meanRatio))
            }

            let anchorPriority: [VRMHumanoidBone] = [.hips, .chest, .spine, .neck, .head]
            if let anchorBone = anchorPriority.first(where: { matchedBonePositions[$0] != nil }),
               let pair = matchedBonePositions[anchorBone] {
                fitTranslation = pair.host - fitScale * pair.asset
            } else if let firstPair = matchedBonePositions.values.first {
                fitTranslation = firstPair.host - fitScale * firstPair.asset
            }
        }

        // Fold any user-supplied uniform scale and rigid transform from options.transform.
        let userScale = (options.transform.scale.x + options.transform.scale.y + options.transform.scale.z) / 3.0
        let totalUniformScale = fitScale * userScale
        let userRigidMatrix = VRMSkeletonRemapper.trsMatrix(
            translation: options.transform.translation,
            rotation: options.transform.rotation,
            scale: SIMD3<Float>(1, 1, 1)
        )
        let fitRigidMatrix = simd_mul(userRigidMatrix, float4x4(translation: fitTranslation))

        // Bake uniform scale into copy-on-write cloned geometry (positions, morph deltas, AABBs)
        // so both LBS and DQS see strictly rigid joint matrices and agree identically.
        if abs(totalUniformScale - 1.0) > 1e-5 {
            for mesh in cloned.meshes {
                for primitive in mesh.primitives {
                    primitive.scaleGeometryCopyOnWrite(by: totalUniformScale, device: hostSnapshot.device)
                }
            }
        }

        // Create attachment pivot node anchored offline to host root (hips or scene root).
        let handle = VRMAttachmentHandle()
        let pivotNode = VRMNode(
            index: -1,
            name: "skinned_attachment_pivot_\(handle.id.uuidString)"
        )
        pivotNode.setParentOffline(hostSnapshot.anchorRootNode)

        // Identify unmapped secondary cloth/hair roots (unmapped nodes whose nearest mapped
        // ancestor is a host bone) and reparent them offline under that host bone.
        var secondaryRoots: [VRMNode] = []
        var secondaryRootSet = Set<ObjectIdentifier>()
        var targetSecondaryBindWorld: [ObjectIdentifier: float4x4] = [:]

        func nearestMappedHostAncestor(of node: VRMNode) -> VRMNode? {
            var cursor = node.parent
            while let current = cursor {
                if let hostNode = mappedHostNodeByAssetNode[ObjectIdentifier(current)] {
                    return hostNode
                }
                cursor = current.parent
            }
            return nil
        }

        var unmappedJointIDs = Set<ObjectIdentifier>()
        for skin in cloned.skins {
            for joint in skin.joints {
                let id = ObjectIdentifier(joint)
                if mappedHostNodeByAssetNode[id] == nil {
                    unmappedJointIDs.insert(id)
                }
            }
        }
        // Also include SpringBone joint nodes that are unmapped.
        if let sb = cloned.springBone {
            for spring in sb.springs {
                for j in spring.joints where j.node >= 0 && j.node < cloned.nodes.count {
                    let id = ObjectIdentifier(cloned.nodes[j.node])
                    if mappedHostNodeByAssetNode[id] == nil {
                        unmappedJointIDs.insert(id)
                    }
                }
            }
        }

        // Find top-most unmapped nodes (roots of secondary subtrees).
        func collectSecondarySubtreeBind(root: VRMNode, parentTargetBind: float4x4, isRoot: Bool) {
            let id = ObjectIdentifier(root)
            if isRoot {
                let origBind = assetBindFrameByNode[id] ?? matrix_identity_float4x4
                let origPos = SIMD3<Float>(origBind.columns.3.x, origBind.columns.3.y, origBind.columns.3.z)
                let scaledPos4 = simd_mul(fitRigidMatrix, SIMD4<Float>(origPos * totalUniformScale, 1.0))
                let origRot = VRMSkeletonRemapper.orthonormalRotationMatrix(of: origBind)
                let userRot = VRMSkeletonRemapper.orthonormalRotationMatrix(of: fitRigidMatrix)
                var targetBind = simd_mul(userRot, origRot)
                targetBind.columns.3 = SIMD4<Float>(scaledPos4.x, scaledPos4.y, scaledPos4.z, 1.0)

                let localMat = simd_mul(simd_inverse(parentTargetBind), targetBind)
                let (t, r, s) = VRMSkeletonRemapper.decomposeTRS(localMat)
                root.translation = t
                root.rotation = r
                root.scale = s
                root.initialTranslation = t
                root.initialRotation = r
                root.initialScale = s
                root.updateLocalMatrix()
                targetSecondaryBindWorld[id] = targetBind

                for child in root.children where mappedHostNodeByAssetNode[ObjectIdentifier(child)] == nil {
                    collectSecondarySubtreeBind(root: child, parentTargetBind: targetBind, isRoot: false)
                }
            } else {
                // Scale child translation along the secondary chain consistently with garment scale.
                root.translation *= totalUniformScale
                root.initialTranslation *= totalUniformScale
                root.updateLocalMatrix()
                let childBind = simd_mul(parentTargetBind, root.localMatrix)
                targetSecondaryBindWorld[id] = childBind
                for child in root.children where mappedHostNodeByAssetNode[ObjectIdentifier(child)] == nil {
                    collectSecondarySubtreeBind(root: child, parentTargetBind: childBind, isRoot: false)
                }
            }
        }

        for node in cloned.nodes {
            let id = ObjectIdentifier(node)
            guard unmappedJointIDs.contains(id) else { continue }
            // Check if this node's parent is mapped or nil (i.e. it is a secondary root).
            let parentIsMappedOrNil: Bool
            if let p = node.parent {
                parentIsMappedOrNil = mappedHostNodeByAssetNode[ObjectIdentifier(p)] != nil
            } else {
                parentIsMappedOrNil = true
            }
            guard parentIsMappedOrNil else { continue }
            guard secondaryRootSet.insert(id).inserted else { continue }

            let newParent = nearestMappedHostAncestor(of: node) ?? pivotNode
            let newParentBind: float4x4
            if newParent === pivotNode {
                newParentBind = hostSnapshot.anchorRootNode.map { hostBindWorld(for: $0) } ?? matrix_identity_float4x4
            } else {
                newParentBind = hostBindWorld(for: newParent)
            }

            // Detach from cloned parent's children list and attach offline to host parent.
            if let oldParent = node.parent {
                oldParent.children.removeAll { $0 === node }
            }
            node.setParentOffline(newParent)
            secondaryRoots.append(node)
            collectSecondarySubtreeBind(root: node, parentTargetBind: newParentBind, isRoot: true)
        }

        // Remap every cloned skin's joints and compute adapted inverse bind matrices:
        //   IBM_adapted_i = inverse(Target_bind_i) * Fit_rigid * (C_bind_i * IBM_asset_i)
        // where C_bind_i * IBM_asset_i is Identity for VRM 1.0 and Ry180 for VRM 0.0
        // (or preserves any non-identity mesh bind offset when IBM was not exact inverse).
        for skin in cloned.skins {
            var remappedJoints: [VRMNode] = []
            remappedJoints.reserveCapacity(skin.joints.count)
            var adaptedIBMs: [float4x4] = []
            adaptedIBMs.reserveCapacity(skin.joints.count)

            for i in 0..<skin.joints.count {
                let assetJoint = skin.joints[i]
                let jointID = ObjectIdentifier(assetJoint)
                let origIBM = i < skin.inverseBindMatrices.count ? skin.inverseBindMatrices[i] : matrix_identity_float4x4
                let cBind = assetBindFrameByNode[jointID] ?? matrix_identity_float4x4
                let cBindTimesIBM = simd_mul(cBind, origIBM)

                if let hostNode = mappedHostNodeByAssetNode[jointID] {
                    let hBind = hostBindWorld(for: hostNode)
                    let adapted = simd_mul(simd_mul(simd_inverse(hBind), fitRigidMatrix), cBindTimesIBM)
                    remappedJoints.append(hostNode)
                    adaptedIBMs.append(adapted)
                } else {
                    let secBind = targetSecondaryBindWorld[jointID]
                        ?? (assetNodeBindWorld[jointID] ?? matrix_identity_float4x4)
                    let adapted = simd_mul(simd_mul(simd_inverse(secBind), fitRigidMatrix), cBindTimesIBM)
                    remappedJoints.append(assetJoint)
                    adaptedIBMs.append(adapted)
                }
            }

            skin.joints = remappedJoints
            skin.inverseBindMatrices = adaptedIBMs
            if let skel = skin.skeleton,
               let mappedSkel = mappedHostNodeByAssetNode[ObjectIdentifier(skel)] {
                skin.skeleton = mappedSkel
            }
        }

        // Copy-on-write sanitize joint indices against the remapped skins so blueprints
        // remain untouched across multiple attachments.
        for node in cloned.nodes {
            guard let meshIdx = node.mesh, meshIdx >= 0, meshIdx < cloned.meshes.count,
                  let skinIdx = node.skin, skinIdx >= 0, skinIdx < cloned.skins.count else {
                continue
            }
            let maxJoint = cloned.skins[skinIdx].joints.count - 1
            guard maxJoint >= 0 else { continue }
            for primitive in cloned.meshes[meshIdx].primitives where primitive.hasJoints {
                // Only copy attributeBuffer if sanitization actually has out-of-bounds indices.
                if primitive.requiredPaletteSize > cloned.skins[skinIdx].joints.count {
                    primitive.ensureMutableAttributeBuffer(device: hostSnapshot.device)
                    primitive.sanitizeJoints(maxJointIndex: maxJoint)
                }
            }
        }

        // Wire any non-skinned mesh nodes inside the asset under pivotNode.
        for rootIdx in cloned.rootNodeIndices where rootIdx >= 0 && rootIdx < cloned.nodes.count {
            let root = cloned.nodes[rootIdx]
            if root.parent == nil && !secondaryRootSet.contains(ObjectIdentifier(root)) {
                root.setParentOffline(pivotNode)
                pivotNode.children.append(root)
            }
        }

        let effectiveFPFlag = options.firstPersonFlag ?? .both
        let bodyMaskID = (options.bodyMaskBones?.isEmpty == false)
            ? "attachment.\(handle.id.uuidString)"
            : nil

        try withLock {
            try validateCumulativeLimitsLocked(adding: asset, limits: options.limits)

            let instance = VRMAttachmentInstance(
                handle: handle,
                name: asset.name,
                anchorBone: nil,
                anchorNode: hostSnapshot.anchorRootNode,
                pivotNode: pivotNode,
                nodes: cloned.nodes,
                meshes: cloned.meshes,
                materials: cloned.materials,
                textures: cloned.textures,
                skins: cloned.skins,
                firstPersonFlag: effectiveFPFlag,
                colliderBinding: options.colliderBinding,
                springBone: cloned.springBone,
                isSkinnedAttachment: true,
                parentAttachmentHandle: nil,
                bodyMaskID: bodyMaskID,
                secondaryRoots: secondaryRoots,
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
            if !cloned.skins.isEmpty {
                bumpSkinLayoutRevisionLocked()
            }
            if cloned.springBone != nil {
                bumpPhysicsRevisionLocked()
            }
        }

        finalizeModelLocalBounds()
        return handle
    }
}
