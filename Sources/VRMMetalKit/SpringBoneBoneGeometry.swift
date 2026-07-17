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

/// Pure bone-derived collider geometry shared by the #309 collider augmentor
/// and the cross-avatar contact-set generator. Same math, two callers that
/// cannot disagree (design §2.3). No Metal, no side effects, never mutates the
/// model. Callers own *which* bones to feed and *when* to call; this type owns
/// only the geometry.
enum SpringBoneBoneGeometry {

    /// One end-to-end capsule from `fromBone` to `toBone`, anchored in the
    /// `from` bone's local frame so it rides the limb under animation once the
    /// upload path re-applies the node world transform. Returns `nil` when
    /// either bone does not resolve, the segment is degenerate, or the frame is
    /// singular. Radius is the larger of the author's scale hint (largest
    /// authored sphere radius parented to `from`) and `radiusFraction × length`.
    static func limbCapsule(fromBone: VRMHumanoidBone, toBone: VRMHumanoidBone,
                            radiusFraction: Float, humanoid: VRMHumanoid,
                            model: VRMModel) -> VRMCollider? {
        guard let fromNode = humanoid.getBoneNode(fromBone),
              fromNode >= 0, fromNode < model.nodes.count,
              let toNode = humanoid.getBoneNode(toBone),
              toNode >= 0, toNode < model.nodes.count else {
            return nil
        }
        let fromPos = model.nodes[fromNode].worldPosition
        let toPos = model.nodes[toNode].worldPosition
        let segWorld = toPos - fromPos
        let length = simd_length(segWorld)
        guard length > 1e-4 else { return nil }

        let fromRot = upperLeft3x3(model.nodes[fromNode].worldMatrix)
        guard abs(simd_determinant(fromRot)) > 1e-6 else { return nil }
        let tailLocal = simd_inverse(fromRot) * segWorld

        let fractionFloor = length * radiusFraction
        let authoredHint = maxAuthoredSphereRadius(parentedTo: fromNode, model: model)
        let radius = max(authoredHint, fractionFloor)
        return VRMCollider(node: fromNode, shape: .capsule(offset: .zero, radius: radius, tail: tailLocal))
    }

    /// Head reference radius `rHead`, oracle-blind: largest authored head sphere
    /// radius, else `0.9 ×` head→neck length. `nil` if the head bone or a radius
    /// cannot be derived.
    static func headReferenceRadius(humanoid: VRMHumanoid, model: VRMModel) -> (headNode: Int, rHead: Float)? {
        guard let headNode = humanoid.getBoneNode(.head),
              headNode >= 0, headNode < model.nodes.count else { return nil }
        var rHead: Float = 0
        if let colliders = model.springBone?.colliders {
            for collider in colliders where collider.node == headNode {
                switch collider.shape {
                case .sphere(_, let radius), .insideSphere(_, let radius):
                    if radius > rHead { rHead = radius }
                default: continue
                }
            }
        }
        if rHead <= 0,
           let neckNode = humanoid.getBoneNode(.neck), neckNode >= 0, neckNode < model.nodes.count {
            let headPos = model.nodes[headNode].worldPosition
            let neckPos = model.nodes[neckNode].worldPosition
            rHead = 0.9 * simd_length(headPos - neckPos)
        }
        guard rHead > 0 else { return nil }
        return (headNode, rHead)
    }

    /// Forward head/brow capsule (head-local +Z forward, -Y down). `nil` if the
    /// head reference radius does not resolve.
    static func headBrowCapsule(humanoid: VRMHumanoid, model: VRMModel,
                                ratios: SpringBoneColliderAugmentor.Ratios) -> VRMCollider? {
        guard let (headNode, rHead) = headReferenceRadius(humanoid: humanoid, model: model) else { return nil }
        let offset = SIMD3<Float>(0, ratios.headOffsetUpFraction * rHead, ratios.headOffsetFwdFraction * rHead)
        let tail = SIMD3<Float>(0, -ratios.headDownFraction * rHead, ratios.headForwardFraction * rHead)
        let radius = ratios.headRadiusFraction * rHead
        return VRMCollider(node: headNode, shape: .capsule(offset: offset, radius: radius, tail: tail))
    }

    /// Lateral skull sphere for temple/side coverage. `nil` if the head
    /// reference radius does not resolve.
    static func headSkullSphere(humanoid: VRMHumanoid, model: VRMModel,
                                ratios: SpringBoneColliderAugmentor.Ratios) -> VRMCollider? {
        guard let (headNode, rHead) = headReferenceRadius(humanoid: humanoid, model: model) else { return nil }
        let offset = SIMD3<Float>(0, ratios.headSkullUpFraction * rHead, 0)
        let radius = ratios.headSkullRadiusFraction * rHead
        return VRMCollider(node: headNode, shape: .sphere(offset: offset, radius: radius))
    }

    /// Extracts the upper-left 3x3 of a 4x4 world matrix (mirrors the upload path).
    static func upperLeft3x3(_ m: float4x4) -> simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(m[0][0], m[0][1], m[0][2]),
            SIMD3<Float>(m[1][0], m[1][1], m[1][2]),
            SIMD3<Float>(m[2][0], m[2][1], m[2][2]))
    }

    private static func maxAuthoredSphereRadius(parentedTo node: Int, model: VRMModel) -> Float {
        guard let colliders = model.springBone?.colliders else { return 0 }
        var best: Float = 0
        for collider in colliders where collider.node == node {
            switch collider.shape {
            case .sphere(_, let radius), .insideSphere(_, let radius):
                if radius > best { best = radius }
            default: continue
            }
        }
        return best
    }
}
