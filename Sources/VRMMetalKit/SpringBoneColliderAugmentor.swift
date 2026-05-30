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

    /// Maximum number of authored collider groups for which augmentation is
    /// supported. The compute path encodes the synthetic group as
    /// `min(colliderGroups.count, 31)`; on a model with this many groups that
    /// index aliases the clamped group-31 bit, so augmentation is disabled to
    /// avoid silently corrupting authored collision filtering.
    private static let maxSupportedColliderGroups = 31

    /// Generator ratios (fractions of a reference scale). Limb geometry is filled
    /// in Task 7; head geometry in Task 8.
    public struct Ratios {
        /// Arm capsule radius as a fraction of the arm segment's length. Floors
        /// the radius so the capsule comfortably encloses the arm skin with margin
        /// for motion-transient cloth lag. Tuned near the stable optimum: larger
        /// values destabilize fast-swing whip (cloth shoved into the other arm).
        public var armRadiusFractionOfLength: Float = 0.34
        /// Leg capsule radius as a fraction of the leg segment's length. Legs are
        /// thicker relative to their segment length than arms, so this floor is
        /// larger to ensure the thigh capsule encloses the thigh skin.
        public var legRadiusFractionOfLength: Float = 0.24
        /// Forward offset of the head sphere as a fraction of head height.
        public var headForwardFraction: Float = 0.60
        /// Downward offset of the head sphere as a fraction of head height.
        public var headDownFraction: Float = 0.50
        /// Head sphere radius as a fraction of head height.
        public var headRadiusFraction: Float = 0.55
        /// Creates default generator ratios.
        public init() {}
    }

    /// One end-to-end limb segment to synthesize a capsule for, anchored at
    /// `from` and ending at `to` (the child bone).
    private struct LimbSegment {
        let from: VRMHumanoidBone
        let to: VRMHumanoidBone
        let isLeg: Bool
    }

    private static let limbSegments: [LimbSegment] = [
        LimbSegment(from: .leftUpperArm, to: .leftLowerArm, isLeg: false),
        LimbSegment(from: .leftLowerArm, to: .leftHand, isLeg: false),
        LimbSegment(from: .rightUpperArm, to: .rightLowerArm, isLeg: false),
        LimbSegment(from: .rightLowerArm, to: .rightHand, isLeg: false),
        LimbSegment(from: .leftUpperLeg, to: .leftLowerLeg, isLeg: true),
        LimbSegment(from: .leftLowerLeg, to: .leftFoot, isLeg: true),
        LimbSegment(from: .rightUpperLeg, to: .rightLowerLeg, isLeg: true),
        LimbSegment(from: .rightLowerLeg, to: .rightFoot, isLeg: true),
    ]

    /// Generates additive bone-derived colliders for the given model.
    ///
    /// Emits one end-to-end capsule per limb segment (upper/lower arms and legs,
    /// both sides — eight in total on a fully-rigged humanoid). Each capsule is
    /// anchored at its `from` bone with its far end pointing at the `to` bone
    /// expressed in the `from` bone's local frame, so it rides the limb under
    /// animation once the upload path re-applies the node's world transform.
    ///
    /// The radius is derived oracle-blind: the larger of (a) the largest authored
    /// sphere/insideSphere radius parented to the `from` bone (the author's own
    /// scale hint) and (b) a fraction of the segment length (`Ratios`). This
    /// guarantees the capsule encloses the limb skin so cloth is pushed out before
    /// reaching it.
    ///
    /// Augmentation is skipped (returns `[]`) when the model has no humanoid or
    /// when it declares `>= maxSupportedColliderGroups` authored collider groups
    /// (see ``maxSupportedColliderGroups``).
    ///
    /// - Parameters:
    ///   - model: The model whose humanoid skeleton drives generation.
    ///   - ratios: Tunable fractions controlling synthesized collider sizes.
    /// - Returns: Additive colliders to append to authored colliders. Never
    ///   mutates `model`.
    public static func synthesize(model: VRMModel, ratios: Ratios = Ratios()) -> [VRMCollider] {
        guard let humanoid = model.humanoid else { return [] }

        // Fail-safe: the synthetic group index is `min(colliderGroups.count, 31)`.
        // On a model with >= 31 authored groups that aliases the clamped group-31
        // bit, so disable augmentation rather than corrupt authored filtering.
        let groupCount = model.springBone?.colliderGroups.count ?? 0
        if groupCount >= maxSupportedColliderGroups {
            vrmLogPhysics("⚠️ [SpringBoneColliderAugmentor] Disabling collider augmentation (issue #309): model declares \(groupCount) authored collider groups (>= \(maxSupportedColliderGroups)); the synthetic group bit would alias an authored group. This is a documented limitation.")
            return []
        }

        var out: [VRMCollider] = []
        for segment in limbSegments {
            appendLimbCapsule(segment, humanoid: humanoid, model: model, ratios: ratios, into: &out)
        }
        return out
    }

    /// Appends one end-to-end capsule for `segment` if both bones resolve.
    private static func appendLimbCapsule(
        _ segment: LimbSegment,
        humanoid: VRMHumanoid,
        model: VRMModel,
        ratios: Ratios,
        into out: inout [VRMCollider]
    ) {
        guard let fromNode = humanoid.getBoneNode(segment.from),
              fromNode >= 0, fromNode < model.nodes.count,
              let toNode = humanoid.getBoneNode(segment.to),
              toNode >= 0, toNode < model.nodes.count else {
            return
        }

        let fromPos = model.nodes[fromNode].worldPosition
        let toPos = model.nodes[toNode].worldPosition
        let segWorld = toPos - fromPos
        let length = simd_length(segWorld)
        guard length > 1e-4 else { return }

        // World delta → from-bone local frame, so the capsule tail tracks the
        // bone under animation once the upload path re-applies the world rotation.
        // Mirror the upload path's rotation extraction (upper-left 3x3 of
        // worldMatrix); use the true inverse so the round-trip is exact even if
        // the node carries scale.
        let fromRot = upperLeft3x3(model.nodes[fromNode].worldMatrix)
        let tailLocal = simd_inverse(fromRot) * segWorld

        let radius = radiusFor(segment, length: length, fromNode: fromNode, model: model, ratios: ratios)
        out.append(VRMCollider(node: fromNode, shape: .capsule(offset: .zero, radius: radius, tail: tailLocal)))
    }

    /// Derives the capsule radius oracle-blind: the larger of the author's scale
    /// hint (largest authored sphere/insideSphere radius parented to `fromNode`)
    /// and a fraction-of-length floor that guarantees the capsule encloses the
    /// limb skin.
    private static func radiusFor(
        _ segment: LimbSegment,
        length: Float,
        fromNode: Int,
        model: VRMModel,
        ratios: Ratios
    ) -> Float {
        let fraction = segment.isLeg ? ratios.legRadiusFractionOfLength : ratios.armRadiusFractionOfLength
        let fractionFloor = length * fraction
        let authoredHint = maxAuthoredSphereRadius(parentedTo: fromNode, model: model)
        return max(authoredHint, fractionFloor)
    }

    /// Largest authored sphere/insideSphere radius among authored colliders
    /// parented to `node`. Returns 0 when none exist.
    private static func maxAuthoredSphereRadius(parentedTo node: Int, model: VRMModel) -> Float {
        guard let colliders = model.springBone?.colliders else { return 0 }
        var best: Float = 0
        for collider in colliders where collider.node == node {
            switch collider.shape {
            case .sphere(_, let radius), .insideSphere(_, let radius):
                if radius > best { best = radius }
            default:
                continue
            }
        }
        return best
    }

    /// Extracts the upper-left 3x3 rotation/scale block of a 4x4 world matrix,
    /// mirroring the upload path in `SpringBoneComputeSystem`.
    private static func upperLeft3x3(_ m: float4x4) -> simd_float3x3 {
        return simd_float3x3(
            SIMD3<Float>(m[0][0], m[0][1], m[0][2]),
            SIMD3<Float>(m[1][0], m[1][1], m[1][2]),
            SIMD3<Float>(m[2][0], m[2][1], m[2][2])
        )
    }
}
