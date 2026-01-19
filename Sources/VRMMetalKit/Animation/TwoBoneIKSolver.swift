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
public struct TwoBoneIKSolver {

    /// Result of an IK solve containing rotations for root and mid joints
    public struct SolveResult {
        /// Local rotation for root joint (hip)
        public let rootRotation: simd_quatf
        /// Local rotation for mid joint (knee)
        public let midRotation: simd_quatf

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
    /// - Returns: SolveResult with rotations, or nil if solve fails
    public static func solve(
        rootPos: SIMD3<Float>,
        midPos: SIMD3<Float>,
        endPos: SIMD3<Float>,
        targetPos: SIMD3<Float>,
        poleVector: SIMD3<Float>,
        upperLength: Float? = nil,
        lowerLength: Float? = nil
    ) -> SolveResult? {
        let a = upperLength ?? simd_length(midPos - rootPos)
        let b = lowerLength ?? simd_length(endPos - midPos)

        guard a > 0.0001 && b > 0.0001 else { return nil }

        let rootToTarget = targetPos - rootPos
        var c = simd_length(rootToTarget)

        guard c > 0.0001 else { return nil }

        let minReach = abs(a - b) + 0.001
        let maxReach = a + b - 0.001
        c = simd_clamp(c, minReach, maxReach)

        let cosKneeAngle = (a * a + b * b - c * c) / (2.0 * a * b)
        let clampedCosKnee = simd_clamp(cosKneeAngle, -1.0, 1.0)
        let kneeAngle = acos(clampedCosKnee)

        let cosHipAngle = (a * a + c * c - b * b) / (2.0 * a * c)
        let clampedCosHip = simd_clamp(cosHipAngle, -1.0, 1.0)
        let hipAngle = acos(clampedCosHip)

        let targetDir = simd_normalize(rootToTarget)

        let right: SIMD3<Float>
        let poleNorm = simd_normalize(poleVector)
        let dotPole = abs(simd_dot(targetDir, poleNorm))

        if dotPole > 0.999 {
            let fallbackUp = abs(simd_dot(targetDir, SIMD3<Float>(0, 1, 0))) > 0.999
                ? SIMD3<Float>(1, 0, 0)
                : SIMD3<Float>(0, 1, 0)
            right = simd_normalize(simd_cross(targetDir, fallbackUp))
        } else {
            right = simd_normalize(simd_cross(targetDir, poleNorm))
        }

        let bendAxis = right

        let hipRotation = rotationFromAxisAngle(axis: bendAxis, angle: -hipAngle)
        let aimRotation = aimAt(from: SIMD3<Float>(0, 1, 0), to: targetDir)
        let rootRotation = simd_mul(aimRotation, hipRotation)

        let kneeBendAngle = .pi - kneeAngle
        let midRotation = rotationFromAxisAngle(axis: SIMD3<Float>(1, 0, 0), angle: kneeBendAngle)

        return SolveResult(rootRotation: rootRotation, midRotation: midRotation)
    }

    /// Calculate bone length between two joints
    public static func boneLength(from: SIMD3<Float>, to: SIMD3<Float>) -> Float {
        simd_length(to - from)
    }

    private static func rotationFromAxisAngle(axis: SIMD3<Float>, angle: Float) -> simd_quatf {
        let halfAngle = angle * 0.5
        let sinHalf = sin(halfAngle)
        let cosHalf = cos(halfAngle)
        return simd_quatf(ix: axis.x * sinHalf, iy: axis.y * sinHalf, iz: axis.z * sinHalf, r: cosHalf)
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
        return rotationFromAxisAngle(axis: axis, angle: angle)
    }
}
