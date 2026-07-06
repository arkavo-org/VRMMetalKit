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

/// Read-only balance state for a model's current pose (design §3).
public struct BalanceState: Sendable {
    /// World-space center of mass.
    public let centerOfMass: SIMD3<Float>
    /// CoM projected to the ground plane (xz).
    public let comGround: SIMD2<Float>
    /// Base of support: xz convex hull of the planted feet's ground corners (CCW).
    public let supportPolygon: [SIMD2<Float>]
    /// Centroid of `supportPolygon`.
    public let supportCentroid: SIMD2<Float>
    /// Margin of stability: `> 0` inside the base (stable), `< 0` outside (falling).
    public let margin: Float
    /// Unit xz direction `normalize(comGround − supportCentroid)`; the zero vector is
    /// a valid answer meaning "centered, no imbalance" (`⇒ no step indicated`).
    public let imbalanceDirection: SIMD2<Float>
    /// `margin > 0`.
    public var isBalanced: Bool { margin > 0 }
}

/// Pure, read-only balance sensor (design: 2026-07-05-balance-model-design.md):
/// weighted-segment center of mass, foot support polygon, and margin of stability.
/// Metal-free and non-mutating — the foundation the later procedural staggering
/// increments (recovery stepping, collision stagger, upright recovery) read.
public enum BalanceModel {

    // MARK: - Center of mass

    /// Dempster-derived segment mass fractions, grouped by body region. Summed over a
    /// complete skeleton the fractions are ≈ 1.0; the final normalize in
    /// ``centerOfMass(jointPositions:)`` absorbs the rounding and any absent region.
    public static let massFractions: [VRMHumanoidBone: Float] = [
        // Trunk ≈ 0.50
        .hips: 0.14, .spine: 0.14, .chest: 0.11, .upperChest: 0.11,
        // Head / neck ≈ 0.085
        .neck: 0.015, .head: 0.07,
        // Arms ≈ 0.049 each
        .leftUpperArm: 0.027, .leftLowerArm: 0.016, .leftHand: 0.006,
        .rightUpperArm: 0.027, .rightLowerArm: 0.016, .rightHand: 0.006,
        // Legs ≈ 0.16 each
        .leftUpperLeg: 0.10, .leftLowerLeg: 0.045, .leftFoot: 0.015,
        .rightUpperLeg: 0.10, .rightLowerLeg: 0.045, .rightFoot: 0.015,
    ]

    /// Where a bone's mass folds when the bone is absent: its nearest coarser ancestor
    /// **within the same body region** (design §4.1). Region roots (`hips`, `head`,
    /// each `upperArm`/`upperLeg`) have no entry — their mass, if the root itself is
    /// absent, drops out and the CoM normalize rescales what remains (the safe guard).
    public static let foldParent: [VRMHumanoidBone: VRMHumanoidBone] = [
        .upperChest: .chest, .chest: .spine, .spine: .hips,   // trunk chain → hips
        .neck: .head,                                          // head/neck region → head
        .leftHand: .leftLowerArm, .leftLowerArm: .leftUpperArm,
        .rightHand: .rightLowerArm, .rightLowerArm: .rightUpperArm,
        .leftFoot: .leftLowerLeg, .leftLowerLeg: .leftUpperLeg,
        .rightFoot: .rightLowerLeg, .rightLowerLeg: .rightUpperLeg,
    ]

    /// Effective mass fractions after parent-folding absent bones onto their nearest
    /// present in-region ancestor. Keys are a subset of `present`.
    public static func effectiveFractions(present: Set<VRMHumanoidBone>) -> [VRMHumanoidBone: Float] {
        var eff: [VRMHumanoidBone: Float] = [:]
        for (bone, frac) in massFractions {
            var target: VRMHumanoidBone? = bone
            while let t = target, !present.contains(t) { target = foldParent[t] }
            if let t = target { eff[t, default: 0] += frac }
        }
        return eff
    }

    /// Weighted-segment center of mass from humanoid joint world positions. `nil`
    /// unless `hips` and at least one further bone are present (a CoM is never a bare
    /// point). Shifts with torso lean AND limb swing — the property staggering needs.
    public static func centerOfMass(jointPositions joints: [VRMHumanoidBone: SIMD3<Float>]) -> SIMD3<Float>? {
        // Require hips plus at least one further MASS-BEARING bone, so a CoM is never a
        // bare single point (a non-mass bone like an eye/finger contributes nothing).
        guard joints[.hips] != nil else { return nil }
        guard joints.keys.filter({ massFractions[$0] != nil }).count >= 2 else { return nil }
        let eff = effectiveFractions(present: Set(joints.keys))
        var sum = SIMD3<Float>(repeating: 0)
        var total: Float = 0
        for (bone, frac) in eff {
            guard let p = joints[bone] else { continue }
            sum += p * frac
            total += frac
        }
        guard total > 0 else { return nil }
        return sum / total
    }

    // MARK: - Support polygon

    /// CCW convex hull (Andrew's monotone chain) of foot ground corners in the xz
    /// plane. Returns the input (≤2 unique points) unchanged for degenerate cases.
    public static func supportPolygon(footCorners: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let pts = footCorners.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard pts.count >= 3 else { return pts }

        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }

        var lower: [SIMD2<Float>] = []
        for p in pts {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [SIMD2<Float>] = []
        for p in pts.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper   // CCW
    }

    // MARK: - Stability margin

    /// Signed distance from `comGround` to the boundary of the (CCW) support polygon,
    /// with the polygon centroid. `margin > 0` inside (distance to nearest edge),
    /// `margin < 0` outside (−distance to nearest edge). Degenerate polygons (≤2
    /// vertices) return a negative margin (no stable base).
    public static func stabilityMargin(comGround p: SIMD2<Float>,
                                       polygon poly: [SIMD2<Float>]) -> (margin: Float, centroid: SIMD2<Float>) {
        let centroid = poly.isEmpty
            ? SIMD2<Float>(repeating: 0)
            : poly.reduce(SIMD2<Float>(repeating: 0), +) / Float(poly.count)
        guard poly.count >= 3 else { return (-simd_distance(p, centroid), centroid) }

        var inside = true
        var minDist = Float.greatestFiniteMagnitude
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let e = b - a
            // For a CCW polygon a point is inside when it is left of every edge.
            let side = e.x * (p.y - a.y) - e.y * (p.x - a.x)
            if side < 0 { inside = false }
            let len2 = simd_length_squared(e)
            let t = len2 > 1e-12 ? simd_clamp(simd_dot(p - a, e) / len2, 0, 1) : 0
            let closest = a + e * t
            minDist = min(minDist, simd_distance(p, closest))
        }
        return (inside ? minDist : -minDist, centroid)
    }

    /// Unit xz direction from the support centroid toward the CoM ground projection —
    /// the imbalance direction a recovery step follows. The **zero vector** is the
    /// defined answer for a centered CoM (`⇒ no step indicated`), returned when the
    /// two points coincide (within 1e-5).
    public static func imbalanceDirection(comGround: SIMD2<Float>, centroid: SIMD2<Float>) -> SIMD2<Float> {
        let d = comGround - centroid
        return simd_length(d) > 1e-5 ? d / simd_length(d) : SIMD2<Float>(repeating: 0)
    }

    // MARK: - Foot support corners

    /// Which foot a support contribution comes from.
    public enum Foot: Sendable { case left, right }

    /// The four ground corners (heel±width, toe±width) of `foot` in the xz plane, or
    /// `nil` when the foot bone is absent. `footForward` comes from the reliable
    /// skeletal heel→toe vector when the rig has toes; otherwise from a
    /// sanity-checked hips-forward fallback (VRM does not standardize a foot-forward
    /// local axis, so a per-bone axis guess would silently rotate the polygon).
    public static func footGroundCorners(model: VRMModel, foot: Foot, groundY: Float,
                                         footLength: Float = 0.15,
                                         halfWidth: Float = 0.04) -> [SIMD2<Float>]? {
        guard let humanoid = model.humanoid else { return nil }
        let footBone: VRMHumanoidBone = foot == .left ? .leftFoot : .rightFoot
        let toesBone: VRMHumanoidBone = foot == .left ? .leftToes : .rightToes
        guard let footIdx = humanoid.getBoneNode(footBone), footIdx < model.nodes.count else { return nil }

        let footPos = model.nodes[footIdx].worldPosition
        let heel = SIMD2<Float>(footPos.x, footPos.z)

        let toe: SIMD2<Float>
        let forward: SIMD2<Float>
        if let toesIdx = humanoid.getBoneNode(toesBone), toesIdx < model.nodes.count {
            let toesPos = model.nodes[toesIdx].worldPosition
            toe = SIMD2<Float>(toesPos.x, toesPos.z)
            let d = toe - heel
            forward = simd_length(d) > 1e-5 ? d / simd_length(d) : hipsForward(humanoid, model)
        } else {
            forward = hipsForward(humanoid, model)
            toe = heel + forward * footLength
        }

        let perp = SIMD2<Float>(-forward.y, forward.x)   // perpendicular in the xz plane
        return [
            heel + perp * halfWidth, heel - perp * halfWidth,
            toe + perp * halfWidth, toe - perp * halfWidth,
        ]
    }

    /// Rig-independent forward direction (hips local +Z projected to xz), the fallback
    /// when a foot has no toes bone. Defaults to +z if the hips axis is degenerate.
    private static func hipsForward(_ humanoid: VRMHumanoid, _ model: VRMModel) -> SIMD2<Float> {
        guard let hipsIdx = humanoid.getBoneNode(.hips), hipsIdx < model.nodes.count else {
            return SIMD2<Float>(0, 1)
        }
        let m = model.nodes[hipsIdx].worldMatrix
        let fz = SIMD2<Float>(m[2][0], m[2][2])          // world xz of the hips local +Z axis
        let len = simd_length(fz)
        return len > 1e-5 ? fz / len : SIMD2<Float>(0, 1)
    }

    // MARK: - Assembly

    /// Full balance state for `model`'s current pose. `nil` when the rig lacks the
    /// humanoid bones for a CoM or has no planted foot to form a support base.
    public static func evaluate(model: VRMModel, groundY: Float = 0,
                                plantedFeet: Set<Foot> = [.left, .right]) -> BalanceState? {
        guard let humanoid = model.humanoid else { return nil }

        var joints: [VRMHumanoidBone: SIMD3<Float>] = [:]
        for bone in massFractions.keys {
            if let idx = humanoid.getBoneNode(bone), idx < model.nodes.count {
                joints[bone] = model.nodes[idx].worldPosition
            }
        }
        guard let com = centerOfMass(jointPositions: joints) else { return nil }

        var corners: [SIMD2<Float>] = []
        for foot in [Foot.left, .right] where plantedFeet.contains(foot) {
            if let c = footGroundCorners(model: model, foot: foot, groundY: groundY) {
                corners.append(contentsOf: c)
            }
        }
        guard corners.count >= 3 else { return nil }

        let poly = supportPolygon(footCorners: corners)
        let comGround = SIMD2<Float>(com.x, com.z)
        let (margin, centroid) = stabilityMargin(comGround: comGround, polygon: poly)
        let imbalance = imbalanceDirection(comGround: comGround, centroid: centroid)

        return BalanceState(centerOfMass: com, comGround: comGround, supportPolygon: poly,
                            supportCentroid: centroid, margin: margin, imbalanceDirection: imbalance)
    }
}
