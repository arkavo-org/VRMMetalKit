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

/// Two-bone IK solver for leg chains (hip → knee → ankle).
///
/// Uses the law of cosines to solve the triangle formed by:
/// - Upper bone (thigh): from root (hip) to mid (knee)
/// - Lower bone (shin): from mid (knee) to end (ankle)
/// - Target distance: from root (hip) to target foot position
///
/// The pole vector constrains the knee bend direction (typically forward).
///
/// The result is a pair of **local deltas** meant to be right-multiplied onto
/// each bone's current rotation (`node.rotation = current * delta`, the way
/// ``AnimationLayerCompositor`` composes layer output). The caller passes the
/// world orientation each bone has in the pose the joint positions describe;
/// with identity world rotations the deltas are world-space rotations.
///
/// ``CaptureStepController`` carries a sibling in-place solver for the
/// capture-step pipeline; this one serves ``IKLayer``.
public struct TwoBoneIKSolver {

    /// Result of an IK solve containing rotations for root and mid joints
    public struct SolveResult {
        /// Local delta for the root joint (hip), right-multiplied onto its current rotation.
        public let rootRotation: simd_quatf
        /// Local delta for the mid joint (knee), right-multiplied onto its current rotation.
        public let midRotation: simd_quatf

        /// Creates a solve result with the given root and mid joint rotations.
        public init(rootRotation: simd_quatf, midRotation: simd_quatf) {
            self.rootRotation = rootRotation
            self.midRotation = midRotation
        }
    }

    /// Solve two-bone IK for a leg chain.
    ///
    /// - Parameters:
    ///   - rootPos: World position of root joint (hip)
    ///   - midPos: World position of mid joint (knee)
    ///   - endPos: World position of end joint (ankle)
    ///   - targetPos: Desired world position for end joint
    ///   - poleVector: Direction for mid joint bend (knee direction), normalized
    ///   - upperLength: Optional override for upper bone length (auto-calculated if nil)
    ///   - lowerLength: Optional override for lower bone length (auto-calculated if nil)
    ///   - rootWorldRotation: World orientation of the root bone in the pose `midPos` describes
    ///   - midWorldRotation: World orientation of the mid bone in the pose `endPos` describes
    /// - Returns: SolveResult with local deltas, or nil if solve fails
    public static func solve(
        rootPos: SIMD3<Float>,
        midPos: SIMD3<Float>,
        endPos: SIMD3<Float>,
        targetPos: SIMD3<Float>,
        poleVector: SIMD3<Float>,
        upperLength: Float? = nil,
        lowerLength: Float? = nil,
        rootWorldRotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
        midWorldRotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    ) -> SolveResult? {
        let upperDir = midPos - rootPos
        let lowerDir = endPos - midPos
        let a = upperLength ?? simd_length(upperDir)
        let b = lowerLength ?? simd_length(lowerDir)

        guard a > 0.0001 && b > 0.0001,
              simd_length(upperDir) > 0.0001, simd_length(lowerDir) > 0.0001 else { return nil }

        let rootToTarget = targetPos - rootPos
        var c = simd_length(rootToTarget)

        guard c > 0.0001 else { return nil }

        let minReach = abs(a - b) + 0.001
        let maxReach = a + b - 0.001
        c = simd_clamp(c, minReach, maxReach)

        // Angle at the hip between the hip→target line and the thigh.
        let cosHipAngle = (a * a + c * c - b * b) / (2.0 * a * c)
        let hipAngle = acos(simd_clamp(cosHipAngle, -1.0, 1.0))

        let targetDir = simd_normalize(rootToTarget)

        // Bend axis: rotating targetDir about cross(targetDir, pole) by a
        // positive angle moves it toward the pole, so the knee lands on the
        // pole side of the hip→target line.
        let poleNorm = simd_normalize(poleVector)
        let bendAxis: SIMD3<Float>
        if abs(simd_dot(targetDir, poleNorm)) > 0.999 {
            let fallbackUp = abs(simd_dot(targetDir, SIMD3<Float>(0, 1, 0))) > 0.999
                ? SIMD3<Float>(1, 0, 0)
                : SIMD3<Float>(0, 1, 0)
            bendAxis = simd_normalize(simd_cross(targetDir, fallbackUp))
        } else {
            bendAxis = simd_normalize(simd_cross(targetDir, poleNorm))
        }

        // World-space rotation for the thigh: aim it at the target, then swing
        // it off the line by the hip angle toward the pole.
        let aim = aimAt(from: upperDir, to: targetDir)
        let thighDelta = simd_quatf(angle: hipAngle, axis: bendAxis) * aim
        let newMid = rootPos + thighDelta.act(upperDir)
        let newEnd = rootPos + targetDir * c

        // World-space rotation for the shin, on top of the thigh's change.
        let shinDelta = aimAt(from: thighDelta.act(lowerDir), to: newEnd - newMid)

        // Convert world deltas into right-multiplied local deltas: the new
        // world orientation W' = delta * W must equal W * local, so
        // local = inverse(W) * delta * W. The knee inherits the thigh delta.
        let rootRotation = rootWorldRotation.inverse * thighDelta * rootWorldRotation
        let midWorldAfterThigh = thighDelta * midWorldRotation
        let midRotation = midWorldAfterThigh.inverse * shinDelta * midWorldAfterThigh

        return SolveResult(rootRotation: simd_normalize(rootRotation), midRotation: simd_normalize(midRotation))
    }

    /// Calculate bone length between two joints
    public static func boneLength(from: SIMD3<Float>, to: SIMD3<Float>) -> Float {
        simd_length(to - from)
    }

    private static func aimAt(from: SIMD3<Float>, to: SIMD3<Float>) -> simd_quatf {
        let fromNorm = simd_normalize(from)
        let toNorm = simd_normalize(to)

        let dot = simd_dot(fromNorm, toNorm)

        if dot > 0.9999 {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }

        if dot < -0.9999 {
            var perp = simd_cross(SIMD3<Float>(1, 0, 0), fromNorm)
            if simd_length(perp) < 0.001 {
                perp = simd_cross(SIMD3<Float>(0, 1, 0), fromNorm)
            }
            perp = simd_normalize(perp)
            return simd_quatf(ix: perp.x, iy: perp.y, iz: perp.z, r: 0)
        }

        let axis = simd_normalize(simd_cross(fromNorm, toNorm))
        let angle = acos(simd_clamp(dot, -1.0, 1.0))
        return simd_quatf(angle: angle, axis: axis)
    }
}
