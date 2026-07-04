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
/// and head. A *second caller* of the shared bone->capsule geometry
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

    static func synthesize(model: VRMModel) -> [VRMCollider] {
        guard let humanoid = model.humanoid else { return [] }
        let ratios = SpringBoneColliderAugmentor.Ratios()
        var out: [VRMCollider] = []

        // Torso: spine -> (upperChest ?? chest ?? neck). The single vertical
        // trunk capsule — the primary hug surface #309 omits.
        let torsoTo: VRMHumanoidBone = {
            if humanoid.getBoneNode(.upperChest) != nil { return .upperChest }
            if humanoid.getBoneNode(.chest) != nil { return .chest }
            return .neck
        }()
        if let torso = SpringBoneBoneGeometry.limbCapsule(
            fromBone: .spine, toBone: torsoTo, radiusFraction: torsoRadiusFractionOfLength,
            humanoid: humanoid, model: model) {
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

        // Head: brow capsule + skull sphere, identical to #309's head geometry.
        if let brow = SpringBoneBoneGeometry.headBrowCapsule(humanoid: humanoid, model: model, ratios: ratios) {
            out.append(brow)
        }
        if let skull = SpringBoneBoneGeometry.headSkullSphere(humanoid: humanoid, model: model, ratios: ratios) {
            out.append(skull)
        }
        return out
    }
}
