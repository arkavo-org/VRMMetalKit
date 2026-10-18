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

/// Same-bone size guard for fraction-derived synthetic SpringBone colliders (#381).
///
/// The radius written on an authored outside sphere or capsule is the size.
/// A synthetic that `synthesize` built for that same node — from a fraction of
/// bone length — must not exceed it. ``ceiling`` is 1: no slack past the file.
/// ``knownOversized`` names the nodes still allowed to exceed it. An empty set
/// means none are, and a pin that is no longer oversized fails the audit.
///
/// Mesh-measured colliders (breast, deltoid, upper torso) are not in this
/// audit. Their radius is the skinned surface in the same file, which is why
/// they exist: the authored sphere does not reach that surface.
enum ColliderDimensionAudit {

    /// Synthetic radius / authored radius above which a fraction-derived collider is oversized.
    static let ceiling: Float = 1

    /// Node names whose fraction-derived synthetics may still exceed ``ceiling``.
    static let knownOversized: Set<String> = []

    struct Offender: Equatable {
        let nodeName: String
        let node: Int
        let syntheticRadius: Float
        let authoredRadius: Float
    }

    /// Largest authored outside sphere on `node`, the one whose radius wins.
    static func authoredSphere(node: Int, model: VRMModel) -> (offset: SIMD3<Float>, radius: Float)? {
        guard let colliders = model.springBone?.colliders else { return nil }
        var best: (offset: SIMD3<Float>, radius: Float)?
        for collider in colliders where collider.node == node {
            guard case .sphere(let offset, let radius) = collider.shape else { continue }
            if best == nil || radius > best!.radius { best = (offset, radius) }
        }
        return best
    }

    /// Fraction-derived synthetics (the `synthesize` prefix) whose radius
    /// exceeds ``ceiling`` × the largest authored outside sphere or capsule on
    /// the same node. A node with no such authored collider is not an offender.
    /// Leg capsules are not offenders: see ``SpringBoneSegmentFit``.
    static func offenders(model: VRMModel) -> [Offender] {
        let all = model.springBone?.syntheticColliders ?? []
        let prefixCount = SpringBoneColliderAugmentor.synthesize(model: model).count
        let prefix = Array(all.prefix(prefixCount)).filter {
            !SpringBoneSegmentFit.keepsFractionRadius(node: $0.node, model: model)
        }
        return offenders(synthetic: prefix, model: model)
    }

    static func offenders(synthetic: [VRMCollider], model: VRMModel) -> [Offender] {
        var out: [Offender] = []
        for collider in synthetic {
            guard let authored = maxAuthoredOutsideRadius(node: collider.node, model: model),
                  let radius = collider.shape.radius,
                  radius > authored * ceiling + 1e-4 else { continue }
            let name: String
            if collider.node >= 0, collider.node < model.nodes.count {
                name = model.nodes[collider.node].name ?? "#\(collider.node)"
            } else {
                name = "#\(collider.node)"
            }
            out.append(Offender(nodeName: name, node: collider.node,
                                syntheticRadius: radius, authoredRadius: authored))
        }
        return out
    }

    /// Shrinks the fraction-derived prefix down to ``ceiling`` × the authored
    /// radius. Does not grow a collider, and does not touch mesh-measured
    /// colliders appended after the prefix.
    static func enforce(_ synthetic: inout [VRMCollider], prefixCount: Int, model: VRMModel) {
        let count = min(prefixCount, synthetic.count)
        for index in 0..<count {
            if SpringBoneSegmentFit.keepsFractionRadius(node: synthetic[index].node, model: model) { continue }
            guard let authored = maxAuthoredOutsideRadius(node: synthetic[index].node, model: model) else { continue }
            synthetic[index].shape = synthetic[index].shape.clampedRadius(authored * ceiling)
        }
    }

    /// Largest authored outside sphere or capsule radius parented to `node`.
    /// Containment shapes are not a size hint for an outside synthetic.
    static func maxAuthoredOutsideRadius(node: Int, model: VRMModel) -> Float? {
        guard let colliders = model.springBone?.colliders else { return nil }
        var best: Float = 0
        var found = false
        for collider in colliders where collider.node == node {
            switch collider.shape {
            case .sphere(_, let radius), .capsule(_, let radius, _):
                if radius > best { best = radius; found = true }
            default:
                continue
            }
        }
        return found && best > 0 ? best : nil
    }
}

/// Load-time correction for synthetic colliders whose size was guessed (#381).
///
/// `synthesize` sizes a limb as `max(authored radius, fraction × bone length)`.
/// The fraction is a body-proportion guess, so it silently wins whenever it is
/// larger than the collider the file already defines. On AvatarSample_A that
/// is the palm sphere at 91 mm against an authored 24 mm, and the forearm
/// capsule at 45 mm against authored spheres of 26–30 mm.
///
/// Where the file has an outside collider on the same node, the fraction
/// collider takes that radius. The palm also takes the authored offset, so the
/// sphere sits on the author's palm instead of a fraction of the way down the
/// forearm. Capsule slots 0–9 are not reordered.
///
/// Leg capsules keep the fraction even when the file has a smaller sphere on
/// that bone. AvatarSample_U authors the thigh at 78 mm; the fraction is 87 mm.
/// Clamping to 78 mm lets the skirt stay inside the leg for 6 frames of a fast
/// march instead of 1. The authored spheres stay in the file and still collide.
enum SpringBoneSegmentFit {

    /// Upper and lower leg capsules are the #309 skirt capsules. Their fraction
    /// radius is load-bearing for `testU_legMarch_augmented_noPenetration`.
    static func keepsFractionRadius(node: Int, model: VRMModel) -> Bool {
        guard let humanoid = model.humanoid else { return false }
        let legs: [VRMHumanoidBone] = [
            .leftUpperLeg, .leftLowerLeg, .rightUpperLeg, .rightLowerLeg
        ]
        return legs.contains { humanoid.getBoneNode($0) == node }
    }

    /// How many spheres `apply` appends. The correction changes radii in place
    /// and appends nothing; the count stays available so load-time assertions
    /// can add it.
    static func appendedSphereCount(model: VRMModel) -> Int {
        var base = SpringBoneColliderAugmentor.synthesize(model: model)
        base.append(contentsOf: SpringBoneBreastCollider.computeBreastColliders(model: model))
        base.append(contentsOf: SpringBoneBreastCollider.computeShoulderColliders(model: model))
        base.append(contentsOf: SpringBoneBreastCollider.computeTorsoCollider(model: model))
        let before = base.count
        apply(to: &base, model: model)
        return base.count - before
    }

    /// Copies authored hand spheres onto the fraction-derived palms and clamps
    /// every other fraction-derived collider to the authored radius on its node.
    static func apply(to synthetic: inout [VRMCollider], model: VRMModel) {
        let prefixCount = min(SpringBoneColliderAugmentor.synthesize(model: model).count, synthetic.count)
        copyAuthoredHandSpheres(into: &synthetic, prefixCount: prefixCount, model: model)
        ColliderDimensionAudit.enforce(&synthetic, prefixCount: prefixCount, model: model)
    }

    /// The palm sphere keeps the fraction-of-length offset unless it is
    /// replaced by the sphere the file actually authors.
    private static func copyAuthoredHandSpheres(into synthetic: inout [VRMCollider],
                                                prefixCount: Int, model: VRMModel) {
        guard let humanoid = model.humanoid else { return }
        for bone in [VRMHumanoidBone.leftHand, .rightHand] {
            guard let node = humanoid.getBoneNode(bone),
                  let authored = ColliderDimensionAudit.authoredSphere(node: node, model: model),
                  let index = synthetic.prefix(prefixCount).firstIndex(where: {
                      $0.node == node && $0.shape.isSphere
                  }) else { continue }
            synthetic[index].shape = .sphere(offset: authored.offset, radius: authored.radius)
        }
    }
}

private extension VRMColliderShape {
    var radius: Float? {
        switch self {
        case .sphere(_, let radius), .capsule(_, let radius, _),
             .insideSphere(_, let radius), .insideCapsule(_, let radius, _):
            return radius
        case .plane:
            return nil
        }
    }

    var isSphere: Bool {
        if case .sphere = self { return true }
        return false
    }

    func clampedRadius(_ limit: Float) -> VRMColliderShape {
        guard let radius, radius > limit else { return self }
        return replacingRadius(limit)
    }

    private func replacingRadius(_ radius: Float) -> VRMColliderShape {
        switch self {
        case .sphere(let offset, _):
            return .sphere(offset: offset, radius: radius)
        case .capsule(let offset, _, let tail):
            return .capsule(offset: offset, radius: radius, tail: tail)
        case .insideSphere(let offset, _):
            return .insideSphere(offset: offset, radius: radius)
        case .insideCapsule(let offset, _, let tail):
            return .insideCapsule(offset: offset, radius: radius, tail: tail)
        case .plane:
            return self
        }
    }
}
