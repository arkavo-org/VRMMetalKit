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

/// Solves VRM node constraints (twist bones, aim constraints, rotation constraints).
///
/// This solver runs after animation updates but before world transform propagation.
/// It distributes rotation from parent bones to twist bones to prevent the "candy wrapper"
/// mesh collapse artifact.
///
/// ## Supported Constraint Types
/// - **Roll**: Transfers rotation around a specific axis (for twist bones)
/// - **Aim**: Orients target to point at source (not yet implemented)
/// - **Rotation**: Copies full rotation from source (not yet implemented)
///
/// ## Usage
/// ```swift
/// let solver = ConstraintSolver()
/// solver.solve(constraints: model.nodeConstraints, nodes: model.nodes)
/// ```
public final class ConstraintSolver: @unchecked Sendable {

    public init() {}

    /// Solve all constraints for the given nodes.
    ///
    /// Call this after animation updates but before world transform propagation.
    ///
    /// - Parameters:
    ///   - constraints: The constraints to solve
    ///   - nodes: The model's nodes (will be modified)
    public func solve(constraints: [VRMNodeConstraint], nodes: [VRMNode]) {
        for constraint in constraints {
            guard constraint.targetNode < nodes.count else { continue }

            switch constraint.constraint {
            case .roll(let sourceNode, let axis, let weight):
                guard sourceNode < nodes.count else { continue }
                solveRollConstraint(
                    source: nodes[sourceNode],
                    target: nodes[constraint.targetNode],
                    axis: axis,
                    weight: weight
                )

            case .aim(_, _, _):
                break

            case .rotation(_, _):
                break
            }
        }
    }

    /// Solve a roll constraint by transferring rotation around an axis.
    ///
    /// Roll constraints are used for twist bones. They extract the rotation
    /// component around a specific axis from the source bone and apply a
    /// weighted portion of it to the target bone.
    ///
    /// - Parameters:
    ///   - source: The source node to read rotation from
    ///   - target: The target node to apply rotation to
    ///   - axis: The axis to transfer rotation around (in local space)
    ///   - weight: How much of the rotation to transfer (0.0 to 1.0)
    private func solveRollConstraint(source: VRMNode, target: VRMNode, axis: SIMD3<Float>, weight: Float) {
        let twist = extractTwist(rotation: source.rotation, axis: axis)
        let weightedTwist = simd_slerp(simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), twist, weight)
        target.rotation = weightedTwist
        target.updateLocalMatrix()
    }

    // MARK: - Swing-Twist Decomposition

    /// Decomposes a quaternion into swing and twist components around a given axis.
    /// Returns only the twist component (rotation around the axis).
    ///
    /// Mathematical basis: Any rotation Q can be decomposed as Q = Swing * Twist
    /// where Twist is rotation around the specified axis.
    ///
    /// The algorithm:
    /// 1. Project the quaternion's vector part onto the twist axis
    /// 2. Construct a quaternion from this projection + the original scalar part
    /// 3. Normalize to get a valid unit quaternion
    ///
    /// - Parameters:
    ///   - rotation: The quaternion to decompose
    ///   - axis: The axis to extract twist rotation around (must be normalized)
    /// - Returns: The twist component as a unit quaternion
    private func extractTwist(rotation q: simd_quatf, axis: SIMD3<Float>) -> simd_quatf {
        let ra = SIMD3<Float>(q.imag.x, q.imag.y, q.imag.z)
        let p = simd_dot(ra, axis) * axis

        var twist = simd_quatf(ix: p.x, iy: p.y, iz: p.z, r: q.real)

        let lengthSquared = simd_length_squared(twist.vector)
        if lengthSquared < 1e-10 {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }

        twist = simd_normalize(twist)

        if twist.real < 0 {
            twist = simd_quatf(ix: -twist.imag.x, iy: -twist.imag.y,
                              iz: -twist.imag.z, r: -twist.real)
        }

        return twist
    }
}
