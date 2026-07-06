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
        guard joints[.hips] != nil, joints.count >= 2 else { return nil }
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
}
