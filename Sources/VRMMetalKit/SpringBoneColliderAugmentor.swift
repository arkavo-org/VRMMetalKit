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

/// Synthesizes tight, bone-derived colliders from the humanoid skeleton to
/// reduce SpringBone clipping (issue #309). Pure value logic — no Metal.
/// Output is ADDITIVE; callers never mutate authored colliders.
public enum SpringBoneColliderAugmentor {

    /// The collider-group mask is 32 bits wide. Augmentation claims one bit for
    /// the synthetic group (the compute path uses `min(colliderGroups.count, 31)`),
    /// which is free as long as fewer than 32 authored groups exist — so up to 31
    /// authored groups are supported, the synthetic group taking the remaining
    /// bit. With 32+ authored groups every bit is claimed; the synthetic bit
    /// would alias an authored group, so augmentation is disabled.
    private static let colliderGroupBitCount = 32

    /// Generator ratios (fractions of a reference scale). The generator emits leg
    /// capsules, one forward head/brow capsule, one lateral skull sphere,
    /// lower-arm→hand capsules, hand spheres, and — for own-body hair protection —
    /// a torso capsule and two upper-arm capsules. All head geometry is expressed
    /// as a fraction of the head's reference radius `rHead` (never raw metres), so
    /// the head colliders scale with the model.
    public struct Ratios: Sendable {
        /// Leg capsule radius as a fraction of the leg segment's length. Legs are
        /// thicker relative to their segment length than arms, so this floor is
        /// larger to ensure the thigh capsule encloses the thigh skin.
        public var legRadiusFractionOfLength: Float = 0.24
        /// Head/brow capsule tail forward reach as a fraction of `rHead`
        /// (head-local +Z). The tail rides forward to the front of the face/brow.
        public var headForwardFraction: Float = 0.60
        /// Head/brow capsule tail drop as a fraction of `rHead` (head-local -Y).
        /// The tail sweeps down toward the brow/upper-face.
        public var headDownFraction: Float = 0.55
        /// Head/brow capsule radius as a fraction of `rHead`.
        public var headRadiusFraction: Float = 0.50
        /// Head/brow capsule anchor (offset) upward placement as a fraction of
        /// `rHead` (head-local +Y).
        public var headOffsetUpFraction: Float = 0.10
        /// Head/brow capsule anchor (offset) forward placement as a fraction of
        /// `rHead` (head-local +Z).
        public var headOffsetFwdFraction: Float = 0.30
        /// Synthetic skull SPHERE radius as a fraction of `rHead`. A midline
        /// forward brow capsule cannot reach a lateral temple strand, so one
        /// skull sphere is appended (into the SEPARATE sphere buffer) to give the
        /// head lateral coverage. Sized oracle-blind from `rHead` (#309
        /// manifestation-1 lateral residual).
        public var headSkullRadiusFraction: Float = 1.0
        /// Synthetic skull sphere center placement upward along head-local +Y as a
        /// fraction of `rHead`. Lifts the sphere from the head node (jaw/neck
        /// height) up to the cranium so it hugs the temple/side strands without
        /// engulfing the face. Matches the authored head sphere, which on
        /// AvatarSample_A centers its skull estimate at +1.0×rHead.
        public var headSkullUpFraction: Float = 1.0
        /// Lower-arm→hand capsule radius as a fraction of that segment's length.
        /// Arms are thinner than legs relative to length, so this floor is
        /// smaller than ``legRadiusFractionOfLength``. Closes hand-poke-through
        /// against the forearm (#321).
        public var armRadiusFractionOfLength: Float = 0.20
        /// Torso (spine→upperChest/chest/neck) capsule radius as a fraction of
        /// that segment's length. The trunk is thick relative to the segment, so
        /// this floor is the largest of the set; sized like the cross-avatar
        /// contact torso (`SpringBoneContactColliderSet`). Keeps hair out of the
        /// chest/breast volume — the gap the original #309 set left uncovered.
        public var torsoRadiusFractionOfLength: Float = 0.5
        /// Upper-arm (upperArm→lowerArm) capsule radius as a fraction of that
        /// segment's length. Same value the contact set uses for the hug surface.
        public var upperArmRadiusFractionOfLength: Float = 0.22
        /// Hand SPHERE radius as a fraction of the lower-arm→hand length. The
        /// sphere caps the palm so a hand placed on the chest/hair pushes cloth
        /// out instead of the fingers interpenetrating it (#321). Tuned down from
        /// 0.55 → 0.40 per QA: 0.55 read as an "invisible forcefield" — hair/cloth
        /// deflected with a visible air gap before the hand made contact. 0.40
        /// hugs the palm so the interaction reads tactile while still keeping the
        /// fingers/palm out of the mesh.
        public var handSphereRadiusFraction: Float = 0.40
        /// Hand sphere center placement toward the fingers as a fraction of the
        /// lower-arm→hand length, expressed in the hand-bone-local +direction of
        /// the lower-arm→hand axis (so it rides over the palm, not the wrist).
        public var handSphereForwardFraction: Float = 0.4
        /// Creates default generator ratios.
        public init() {}
    }

    /// One end-to-end limb segment to synthesize a capsule for, anchored at
    /// `from` and ending at `to` (the child bone).
    private struct LimbSegment {
        let from: VRMHumanoidBone
        let to: VRMHumanoidBone
    }

    private static let limbSegments: [LimbSegment] = [
        LimbSegment(from: .leftUpperLeg, to: .leftLowerLeg),
        LimbSegment(from: .leftLowerLeg, to: .leftFoot),
        LimbSegment(from: .rightUpperLeg, to: .rightLowerLeg),
        LimbSegment(from: .rightLowerLeg, to: .rightFoot),
    ]

    /// Lower-arm→hand segments for the hand-poke-through fix (#321, per the
    /// ADR-007 amendment). Appended AFTER the leg+head colliders so the synthetic
    /// capsules take buffer slots 5+ and never disturb the validated leg (0–3) /
    /// head (4) ordering the XPBD solver depends on.
    private static let armHandSegments: [LimbSegment] = [
        LimbSegment(from: .leftLowerArm, to: .leftHand),
        LimbSegment(from: .rightLowerArm, to: .rightHand),
    ]

    /// Upper-arm segments (own-body hair protection — the hair-vs-upper-arm gap
    /// in the original #309 set). Appended AFTER the torso so the synthetic
    /// capsules take buffer slots 8+, preserving every validated slot below.
    private static let upperArmSegments: [LimbSegment] = [
        LimbSegment(from: .leftUpperArm, to: .leftLowerArm),
        LimbSegment(from: .rightUpperArm, to: .rightLowerArm),
    ]

    /// Generates additive bone-derived colliders for the given model.
    ///
    /// Emits one end-to-end capsule per leg segment (upper/lower legs, both
    /// sides — four in total on a fully-rigged humanoid) PLUS one forward
    /// head/brow capsule anchored at the head bone, PLUS a torso capsule and two
    /// upper-arm capsules for own-body hair protection (hair through the
    /// chest/breast volume and the upper arms was the coverage gap left by the
    /// original set; full-arm capsules for CLOTH SLEEVES were dropped — a
    /// frequency sweep showed they could not be validated as an improvement for
    /// the stiff sleeve whip, a PBD-without-CCD limitation tracked as a
    /// CCD/substep follow-up on #309). Each leg capsule is anchored at its
    /// `from` bone with its far end pointing at the `to` bone expressed in the
    /// `from` bone's local frame, so it rides the limb under animation once the
    /// upload path re-applies the node's world transform.
    ///
    /// The head capsule sweeps from the upper face forward and down to the brow
    /// (head-local +Z forward, -Y down) so that short head-hugging hair chains
    /// rest on the brow instead of sinking into the forehead when the head tips
    /// back (#309 manifestation 1). Its size is derived oracle-blind from the
    /// head's reference radius `rHead` (largest authored head sphere radius, else
    /// a fraction of the head→neck length); all head geometry is a fraction of
    /// `rHead`. It is APPENDED AFTER the leg capsules: the synthetic colliders are
    /// uploaded in array order and the XPBD solver is sensitive to buffer-index
    /// order, so head must occupy slot 4 to preserve the validated leg slots 0–3.
    ///
    /// The radius is derived oracle-blind: the larger of (a) the largest authored
    /// sphere/insideSphere radius parented to the `from` bone (the author's own
    /// scale hint) and (b) a fraction of the segment length (`Ratios`). This
    /// guarantees the capsule encloses the limb skin so cloth is pushed out before
    /// reaching it.
    ///
    /// Augmentation is skipped (returns `[]`) when the model has no humanoid or
    /// when it declares 32 or more authored collider groups (the 32-bit
    /// collider-group mask then has no free bit for the synthetic group; up to
    /// 31 authored groups are supported — see ``colliderGroupBitCount``).
    ///
    /// - Parameters:
    ///   - model: The model whose humanoid skeleton drives generation.
    ///   - ratios: Tunable fractions controlling synthesized collider sizes.
    /// - Returns: Additive colliders to append to authored colliders. Never
    ///   mutates `model`.
    public static func synthesize(model: VRMModel, ratios: Ratios = Ratios()) -> [VRMCollider] {
        guard let humanoid = model.humanoid else { return [] }

        // Fail-safe: augmentation claims one bit of the 32-bit collider-group
        // mask for the synthetic group. With 32+ authored groups no bit is free,
        // so disable augmentation rather than alias an authored group's bit.
        // (Up to 31 authored groups are supported — the synthetic group takes
        // the remaining bit.)
        let groupCount = model.springBone?.colliderGroups.count ?? 0
        if groupCount >= colliderGroupBitCount {
            vrmLogPhysics("⚠️ [SpringBoneColliderAugmentor] Disabling collider augmentation (issue #309): model declares \(groupCount) authored collider groups; the 32-bit collider-group mask has no free bit for the synthetic group (supported up to \(colliderGroupBitCount - 1)). This is a documented limitation.")
            return []
        }

        var out: [VRMCollider] = []
        for segment in limbSegments {
            appendLimbCapsule(segment, humanoid: humanoid, model: model,
                              radiusFraction: ratios.legRadiusFractionOfLength, into: &out)
        }
        // CRITICAL: the head capsule MUST be appended AFTER the leg capsules so it
        // occupies buffer slot 4 — the XPBD solver applies corrections in
        // buffer-index order and the validated leg result depends on slots 0–3.
        appendHeadCapsule(humanoid: humanoid, model: model, ratios: ratios, into: &out)
        // Arm/hand capsules occupy capsule-buffer slots 5+ (appended AFTER the
        // head capsule) so they never disturb the validated leg (0–3) / head (4)
        // slots. They close the hand-poke-through (#321): a slow hand gesture into
        // the chest ribbon / hair / skirt now collides with the forearm.
        for segment in armHandSegments {
            appendLimbCapsule(segment, humanoid: humanoid, model: model,
                              radiusFraction: ratios.armRadiusFractionOfLength, into: &out)
        }
        // Torso (slot 7) and upper arms (slots 8–9): own-body hair protection for
        // the chest/breast volume and the upper arms. Pure append after the
        // validated slots; the torso mirrors the contact set's spine →
        // (upperChest ?? chest ?? neck) fallback chain.
        appendTorsoCapsule(humanoid: humanoid, model: model, ratios: ratios, into: &out)
        for segment in upperArmSegments {
            appendLimbCapsule(segment, humanoid: humanoid, model: model,
                              radiusFraction: ratios.upperArmRadiusFractionOfLength, into: &out)
        }
        // The skull SPHERE is a SPHERE, so it lands in the SEPARATE sphere
        // collider buffer (not the capsule buffer). Its position in `out` does
        // NOT affect the capsule buffer order, so the validated leg/head capsule
        // slots are untouched. It gives the head LATERAL coverage the midline
        // brow capsule cannot reach (temple side-bang strands, #309).
        appendHeadSkullSphere(humanoid: humanoid, model: model, ratios: ratios, into: &out)
        // Hand SPHERES cap the palms (sphere buffer, after the skull sphere) so a
        // hand placed on the body pushes cloth out instead of the fingers
        // interpenetrating it (#321). Sphere-buffer order does not affect the
        // validated capsule slots.
        appendHandSpheres(humanoid: humanoid, model: model, ratios: ratios, into: &out)
        return out
    }

    private static func appendHeadCapsule(
        humanoid: VRMHumanoid, model: VRMModel, ratios: Ratios, into out: inout [VRMCollider]
    ) {
        if let c = SpringBoneBoneGeometry.headBrowCapsule(humanoid: humanoid, model: model, ratios: ratios) {
            out.append(c)
        }
    }

    /// Torso capsule: spine → (upperChest ?? chest ?? neck) — the same fallback
    /// chain the cross-avatar contact set uses, sized by
    /// ``Ratios/torsoRadiusFractionOfLength`` (with the authored-hint floor from
    /// `limbCapsule`, so an authored chest sphere still wins).
    private static func appendTorsoCapsule(
        humanoid: VRMHumanoid, model: VRMModel, ratios: Ratios, into out: inout [VRMCollider]
    ) {
        let torsoTo: VRMHumanoidBone = {
            if humanoid.getBoneNode(.upperChest) != nil { return .upperChest }
            if humanoid.getBoneNode(.chest) != nil { return .chest }
            return .neck
        }()
        if let c = SpringBoneBoneGeometry.limbCapsule(
            fromBone: .spine, toBone: torsoTo,
            radiusFraction: ratios.torsoRadiusFractionOfLength,
            humanoid: humanoid, model: model) {
            out.append(c)
        }
    }

    private static func appendHeadSkullSphere(
        humanoid: VRMHumanoid, model: VRMModel, ratios: Ratios, into out: inout [VRMCollider]
    ) {
        if let c = SpringBoneBoneGeometry.headSkullSphere(humanoid: humanoid, model: model, ratios: ratios) {
            out.append(c)
        }
    }

    private static func appendLimbCapsule(
        _ segment: LimbSegment, humanoid: VRMHumanoid, model: VRMModel,
        radiusFraction: Float, into out: inout [VRMCollider]
    ) {
        if let c = SpringBoneBoneGeometry.limbCapsule(
            fromBone: segment.from, toBone: segment.to, radiusFraction: radiusFraction,
            humanoid: humanoid, model: model) {
            out.append(c)
        }
    }

    /// Appends one synthetic palm SPHERE per hand (left/right) if the hand and
    /// its parent lower-arm both resolve. The sphere is centered on the hand node
    /// and pushed toward the fingers along the lower-arm→hand axis (hand-local),
    /// sized as a fraction of the lower-arm→hand length so it scales with the
    /// model. Emitted as `.sphere` (separate sphere buffer), so it never disturbs
    /// the validated leg/head/arm capsule ordering (#321).
    private static func appendHandSpheres(
        humanoid: VRMHumanoid,
        model: VRMModel,
        ratios: Ratios,
        into out: inout [VRMCollider]
    ) {
        for (lowerArm, hand) in [(VRMHumanoidBone.leftLowerArm, VRMHumanoidBone.leftHand),
                                 (VRMHumanoidBone.rightLowerArm, VRMHumanoidBone.rightHand)] {
            guard let handNode = humanoid.getBoneNode(hand),
                  handNode >= 0, handNode < model.nodes.count,
                  let lowerArmNode = humanoid.getBoneNode(lowerArm),
                  lowerArmNode >= 0, lowerArmNode < model.nodes.count else {
                continue
            }
            let handPos = model.nodes[handNode].worldPosition
            let lowerArmPos = model.nodes[lowerArmNode].worldPosition
            let segWorld = handPos - lowerArmPos
            let length = simd_length(segWorld)
            guard length > 1e-4 else { continue }

            // Forward (toward fingers) = the lower-arm→hand direction expressed in
            // the hand bone's local frame, so the offset rides over the palm under
            // animation once the upload path re-applies the hand's world rotation.
            let handRot = SpringBoneBoneGeometry.upperLeft3x3(model.nodes[handNode].worldMatrix)
            guard abs(simd_determinant(handRot)) > 1e-6 else { continue }
            let forwardLocal = simd_normalize(simd_inverse(handRot) * segWorld)
            let offset = forwardLocal * (ratios.handSphereForwardFraction * length)
            let radius = ratios.handSphereRadiusFraction * length
            out.append(VRMCollider(node: handNode, shape: .sphere(offset: offset, radius: radius)))
        }
    }
}
