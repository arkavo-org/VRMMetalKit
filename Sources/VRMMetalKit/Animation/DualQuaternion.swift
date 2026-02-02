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

import simd

/// Dual quaternion for volume-preserving skinning.
///
/// Memory layout matches Metal's DualQuaternion struct exactly:
/// - `real`: 16 bytes (float4) - rotation quaternion
/// - `dual`: 16 bytes (float4) - translation encoding
/// - Total: 32 bytes, 16-byte aligned
///
/// Component order: [real.x, real.y, real.z, real.w, dual.x, dual.y, dual.z, dual.w]
///
/// ## Usage
/// ```swift
/// // From rotation and translation
/// let dq = DualQuaternion(rotation: rot, translation: trans)
///
/// // From transformation matrix
/// let dq = DualQuaternion(matrix: skinMatrix)
/// ```
public struct DualQuaternion: Sendable {
    /// Rotation component (unit quaternion)
    public var real: simd_quatf

    /// Translation encoding: Q_dual = 0.5 * T_quat * Q_real
    public var dual: simd_quatf

    /// Identity dual quaternion (no rotation, no translation)
    public static let identity = DualQuaternion(
        real: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
        dual: simd_quatf(ix: 0, iy: 0, iz: 0, r: 0)
    )

    /// Create from separate rotation and translation
    ///
    /// - Parameters:
    ///   - rotation: Unit quaternion representing rotation
    ///   - translation: Translation vector
    public init(rotation: simd_quatf, translation: SIMD3<Float>) {
        self.real = simd_normalize(rotation)
        let t = simd_quatf(ix: translation.x, iy: translation.y, iz: translation.z, r: 0)
        self.dual = simd_mul(t, self.real) * 0.5
    }

    /// Create from raw quaternion values
    public init(real: simd_quatf, dual: simd_quatf) {
        self.real = real
        self.dual = dual
    }

    /// Create from a 4x4 transformation matrix
    ///
    /// Extracts rotation and translation from the matrix.
    /// Note: Non-uniform scale is not preserved in DQS.
    ///
    /// - Parameter matrix: Transformation matrix
    public init(matrix: float4x4) {
        let translation = SIMD3<Float>(
            matrix.columns.3.x,
            matrix.columns.3.y,
            matrix.columns.3.z
        )

        let rotation = simd_quatf(matrix)
        self.init(rotation: rotation, translation: translation)
    }

    /// Extract translation vector from dual quaternion
    ///
    /// Formula: t = 2 * Q_dual * conjugate(Q_real)
    public var translation: SIMD3<Float> {
        let t = simd_mul(dual, simd_conjugate(real)) * 2.0
        return SIMD3<Float>(t.imag.x, t.imag.y, t.imag.z)
    }

    /// Extract rotation quaternion (already stored as real component)
    public var rotation: simd_quatf {
        return real
    }

    /// Transform a point by this dual quaternion
    ///
    /// - Parameter point: Point to transform
    /// - Returns: Transformed point
    public func transformPoint(_ point: SIMD3<Float>) -> SIMD3<Float> {
        let rotated = simd_act(real, point)
        return rotated + translation
    }

    /// Transform a normal/direction by this dual quaternion (rotation only)
    ///
    /// - Parameter normal: Normal to transform
    /// - Returns: Rotated normal
    public func transformNormal(_ normal: SIMD3<Float>) -> SIMD3<Float> {
        return simd_act(real, normal)
    }

    /// Normalize this dual quaternion
    ///
    /// - Returns: Normalized dual quaternion
    public func normalized() -> DualQuaternion {
        let norm = simd_length(real.vector)
        guard norm > 1e-10 else { return .identity }
        return DualQuaternion(
            real: simd_quatf(vector: real.vector / norm),
            dual: simd_quatf(vector: dual.vector / norm)
        )
    }

    /// Blend multiple dual quaternions with weights
    ///
    /// Handles antipodality: ensures all quaternions are in the same hemisphere
    /// before blending by negating quaternions in the opposite hemisphere.
    ///
    /// - Parameters:
    ///   - dualQuaternions: Array of dual quaternions to blend
    ///   - weights: Corresponding weights (should sum to 1.0)
    /// - Returns: Blended and normalized dual quaternion
    public static func blend(_ dualQuaternions: [DualQuaternion], weights: [Float]) -> DualQuaternion {
        guard !dualQuaternions.isEmpty, dualQuaternions.count == weights.count else {
            return .identity
        }

        var resultReal = SIMD4<Float>(0, 0, 0, 0)
        var resultDual = SIMD4<Float>(0, 0, 0, 0)
        let reference = dualQuaternions[0].real.vector

        for i in 0..<dualQuaternions.count {
            let w = weights[i]
            if w <= 0 { continue }

            var dq = dualQuaternions[i]

            // Antipodality check: negate quaternion if in opposite hemisphere
            // q and -q represent the same rotation, but we need them in the
            // same hemisphere for correct blending
            if simd_dot(reference, dq.real.vector) < 0 {
                dq.real = simd_quatf(vector: -dq.real.vector)
                dq.dual = simd_quatf(vector: -dq.dual.vector)
            }

            resultReal += w * dq.real.vector
            resultDual += w * dq.dual.vector
        }

        // Normalize
        let norm = simd_length(resultReal)
        if norm > 1e-10 {
            resultReal /= norm
            resultDual /= norm
        } else {
            return .identity
        }

        return DualQuaternion(
            real: simd_quatf(vector: resultReal),
            dual: simd_quatf(vector: resultDual)
        )
    }
}
