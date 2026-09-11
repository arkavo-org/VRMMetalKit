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
import simd

/// Skeleton-derived body contact set for cross-avatar collision (design §5):
/// the huggable surfaces a partner's spring bones yield to — torso, upper arms,
/// head, and thigh capsules, plus up to 8 authored body colliders (subsystem 3).
/// A *second caller* of the shared bone->capsule geometry
/// (`SpringBoneBoneGeometry`), independent of the #309 augmentor's trigger and
/// enable flag: it fires because a contact-group participant needs its contact
/// surface, computed from the humanoid skeleton every VRM 1.0 avatar has.
///
/// Output is local-space, node-anchored `VRMCollider`s (the world transform is
/// re-applied at snapshot time). Empty when the model has no humanoid.
enum SpringBoneContactColliderSet {

    /// Torso capsule radius as a fraction of the spine->chest segment length.
    /// The torso is thick relative to its segment, so this floor is larger than
    /// the limb fractions. NEW geometry with no #309 precedent — this value is
    /// the visual-calibration target for the hug spike (design §5.3), not
    /// inherited from a validated #309 ratio.
    static let torsoRadiusFractionOfLength: Float = 0.5

    /// Upper-arm capsule radius as a fraction of the upperArm->lowerArm length.
    static let upperArmRadiusFractionOfLength: Float = 0.22

    /// Thigh (upperLeg->lowerLeg) capsule radius as a fraction of that length.
    /// This is the surface a SKIRT deflects off; sized larger than the #309 leg
    /// floor (0.24) so a partner's thigh visibly engages the skirt panels during
    /// close contact rather than only grazing them. (Measured: at 0.24 the skirt
    /// already deflects up to ~10cm — this widens it to read clearly.)
    static let thighRadiusFractionOfLength: Float = 0.34

    /// Max authored body colliders folded into the contact set per avatar
    /// (subsystem 3). Bounds the contact set so the reserved foreign tail stays
    /// fixed for any avatar; most avatars author fewer than this. Largest-radius
    /// authored colliders win when capped.
    static let maxAuthoredContactColliders: Int = 8

    /// Builds the contact set. `includeAuthored` (default true) folds in the
    /// avatar's own authored body colliders (subsystem 3); pass false for the
    /// pure skeleton-derived set (torso + arms + head).
    static func synthesize(model: VRMModel, includeAuthored: Bool = true) -> [VRMCollider] {
        guard let humanoid = model.humanoid else { return [] }
        let ratios = SpringBoneColliderAugmentor.Ratios()
        var out: [VRMCollider] = []

        // Torso: the single vertical trunk capsule — the primary hug surface #309
        // omits, and the surface the postural yield (design §3) leans away from.
        if let torso = torsoCollider(model: model) {
            out.append(torso)
        }

        // Upper arms: the arm surface a hug wraps.
        for (from, to) in [(VRMHumanoidBone.leftUpperArm, VRMHumanoidBone.leftLowerArm),
                           (VRMHumanoidBone.rightUpperArm, VRMHumanoidBone.rightLowerArm)] {
            if let arm = SpringBoneBoneGeometry.limbCapsule(
                fromBone: from, toBone: to, radiusFraction: upperArmRadiusFractionOfLength,
                humanoid: humanoid, model: model) {
                out.append(arm)
            }
        }

        // Thighs: the lower-body surface a SKIRT deflects off during close
        // contact — the torso capsule sits at chest height and leaves the
        // hip/thigh skirt region uncovered otherwise.
        for (from, to) in [(VRMHumanoidBone.leftUpperLeg, VRMHumanoidBone.leftLowerLeg),
                           (VRMHumanoidBone.rightUpperLeg, VRMHumanoidBone.rightLowerLeg)] {
            if let thigh = SpringBoneBoneGeometry.limbCapsule(
                fromBone: from, toBone: to, radiusFraction: thighRadiusFractionOfLength,
                humanoid: humanoid, model: model) {
                out.append(thigh)
            }
        }

        // Head: brow capsule + skull sphere, identical to #309's head geometry.
        if let brow = SpringBoneBoneGeometry.headBrowCapsule(humanoid: humanoid, model: model, ratios: ratios) {
            out.append(brow)
        }
        if let skull = SpringBoneBoneGeometry.headSkullSphere(humanoid: humanoid, model: model, ratios: ratios) {
            out.append(skull)
        }

        // Subsystem 3: fold in the avatar's own AUTHORED body colliders for
        // precision around custom clothing/proportions the standard capsules
        // miss. Appended AFTER the skeleton set so, if ever clamped, the reliable
        // skeleton survives and only excess authored is dropped.
        if includeAuthored {
            out.append(contentsOf: filteredAuthoredBodyColliders(
                model.springBone?.colliders ?? [],
                humanoidNodes: humanoidNodeIndices(humanoid),
                cap: maxAuthoredContactColliders))
        }
        return out
    }

    /// The avatar's torso capsule: spine -> (upperChest ?? chest ?? neck), a
    /// local-space node-anchored `VRMCollider`. The single source of truth for
    /// "what is the torso" — both ``synthesize(model:includeAuthored:)`` (as its
    /// first emitted capsule) and the world-space contact accessor
    /// (`SpringBoneComputeSystem.contactTorsoCapsule`) build on it, so the two
    /// can never disagree about which capsule the postural yield (design §3)
    /// leans away from. `nil` when the model has no humanoid.
    static func torsoCollider(model: VRMModel) -> VRMCollider? {
        guard let humanoid = model.humanoid else { return nil }
        let torsoTo: VRMHumanoidBone = {
            if humanoid.getBoneNode(.upperChest) != nil { return .upperChest }
            if humanoid.getBoneNode(.chest) != nil { return .chest }
            return .neck
        }()
        return SpringBoneBoneGeometry.limbCapsule(
            fromBone: .spine, toBone: torsoTo, radiusFraction: torsoRadiusFractionOfLength,
            humanoid: humanoid, model: model)
    }

    /// This avatar's torso capsule in world space, or `nil` when the rig has no
    /// humanoid / spine. The model-only accessor Component A (`CrowdFrameStepper`)
    /// and Component B (`PosturalContactLayer`) both read — no compute system
    /// required. Shares ``torsoCollider(model:)`` and ``worldCapsule(_:model:)``
    /// with the snapshot path, so the world torso can never disagree with the
    /// snapshot's first capsule.
    static func worldTorsoCapsule(model: VRMModel) -> CapsuleCollider? {
        guard let torso = torsoCollider(model: model) else { return nil }
        return worldCapsule(torso, model: model)
    }

    /// Transforms a local-space, node-anchored capsule `VRMCollider` into a
    /// world-space `CapsuleCollider` via the anchor node's world matrix. The one
    /// transform path shared by `SpringBoneComputeSystem.contactColliderSnapshot`
    /// and the torso accessors. `groupMask` is left 0 (untagged); the sink
    /// assigns the foreign group bit.
    static func worldCapsule(_ collider: VRMCollider, model: VRMModel) -> CapsuleCollider? {
        guard case .capsule(let offset, let radius, let tail) = collider.shape,
              collider.node >= 0, collider.node < model.nodes.count else { return nil }
        let node = model.nodes[collider.node]
        let wm = node.worldMatrix
        let rot = simd_float3x3(
            SIMD3<Float>(wm[0][0], wm[0][1], wm[0][2]),
            SIMD3<Float>(wm[1][0], wm[1][1], wm[1][2]),
            SIMD3<Float>(wm[2][0], wm[2][1], wm[2][2]))
        // `tail` is a local-space position like `offset` (VRMC_springBone-1.0),
        // not a vector from `offset`.
        let p0 = node.worldPosition + rot * offset
        let p1 = node.worldPosition + rot * tail
        return CapsuleCollider(p0: p0, p1: p1, radius: radius, groupMask: 0)
    }

    /// The node indices mapped to humanoid bones. An authored collider counts as
    /// a *body* collider only if it is anchored to one of these (hair/accessory
    /// colliders live on non-humanoid nodes and are excluded).
    static func humanoidNodeIndices(_ humanoid: VRMHumanoid) -> Set<Int> {
        var nodes = Set<Int>()
        for bone in VRMHumanoidBone.allCases {
            if let n = humanoid.getBoneNode(bone) { nodes.insert(n) }
        }
        return nodes
    }

    /// Filters authored colliders to genuine body-contact surfaces (subsystem 3),
    /// pure and testable: keeps only OUTSIDE sphere/capsule colliders anchored to
    /// a humanoid bone, dropping hair/accessory colliders (non-humanoid nodes),
    /// containment (`inside*`) colliders (wrong semantics — push in), and planes.
    /// Returns the `cap` largest by radius (most significant body volumes win).
    static func filteredAuthoredBodyColliders(_ colliders: [VRMCollider],
                                              humanoidNodes: Set<Int>, cap: Int) -> [VRMCollider] {
        var entries: [(collider: VRMCollider, radius: Float)] = []
        for c in colliders {
            guard humanoidNodes.contains(c.node) else { continue }
            switch c.shape {
            case .sphere(_, let r): entries.append((c, r))
            case .capsule(_, let r, _): entries.append((c, r))
            default: continue   // insideSphere / insideCapsule / plane — excluded
            }
        }
        entries.sort { $0.radius > $1.radius }
        return entries.prefix(cap).map { $0.collider }
    }
}
