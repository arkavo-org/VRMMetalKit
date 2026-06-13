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
/// - **Aim**: Orients target to point at source
/// - **Rotation**: Copies full rotation from source
///
/// ## Usage
/// ```swift
/// let solver = ConstraintSolver()
/// solver.solve(constraints: model.nodeConstraints, nodes: model.nodes)
/// ```
/// Thread-safety: the solver caches the topological sort of the most recently
/// seen constraint array. The cached arrays are immutable after assignment, so
/// `Sendable` conformance is preserved via `@unchecked Sendable`; the cache is
/// only mutated during `solve(constraints:nodes:)` and the solver instance is
/// not shared across concurrency domains.
public final class ConstraintSolver: @unchecked Sendable {

    /// Cached constraint array used to detect when the topological sort can be reused.
    private var cachedConstraints: [VRMNodeConstraint]?

    /// Cached topological sort result. Immutable after assignment.
    private var cachedSorted: [VRMNodeConstraint]?

    /// Creates a constraint solver. The solver is safe to reuse across frames and models.
    public init() {}

    /// Compares two constraint arrays element-wise.
    ///
    /// `VRMNodeConstraint` does not conform to `Equatable`, so the cache check
    /// uses this explicit comparison to avoid depending on the public API of
    /// the loader types.
    private func constraintsEqual(_ lhs: [VRMNodeConstraint], _ rhs: [VRMNodeConstraint]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (l, r) in zip(lhs, rhs) {
            guard l.targetNode == r.targetNode else { return false }
            switch (l.constraint, r.constraint) {
            case (.roll(let ls, let la, let lw), .roll(let rs, let ra, let rw)):
                guard ls == rs, la == ra, lw == rw else { return false }
            case (.aim(let ls, let la, let lw), .aim(let rs, let ra, let rw)):
                guard ls == rs, la == ra, lw == rw else { return false }
            case (.rotation(let ls, let lw), .rotation(let rs, let rw)):
                guard ls == rs, lw == rw else { return false }
            default:
                return false
            }
        }
        return true
    }

    /// Solve all constraints for the given nodes.
    ///
    /// Constraints are solved in topological dependency order so that a source node's
    /// rotation is finalised before any target that reads from it. Cycles are detected
    /// and skipped (with a compile-flag-gated warning).
    ///
    /// The topological sort is cached and reused when the constraints array matches
    /// the previous call, avoiding an O(n log n) re-sort every frame for models whose
    /// constraint graph does not change.
    ///
    /// - Parameters:
    ///   - constraints: The constraints to solve
    ///   - nodes: The model's nodes (will be modified)
    public func solve(constraints: [VRMNodeConstraint], nodes: [VRMNode]) {
        let sorted: [VRMNodeConstraint]
        if let cached = cachedConstraints, constraintsEqual(cached, constraints) {
            sorted = cachedSorted ?? []
        } else {
            sorted = topologicalSort(constraints: constraints, nodeCount: nodes.count)
            cachedConstraints = constraints
            cachedSorted = sorted
        }

        for constraint in sorted {
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

            case .aim(let sourceNode, let aimAxis, let weight):
                guard sourceNode < nodes.count else { continue }
                solveAimConstraint(
                    source: nodes[sourceNode],
                    target: nodes[constraint.targetNode],
                    aimAxis: aimAxis,
                    weight: weight
                )

            case .rotation(let sourceNode, let weight):
                guard sourceNode < nodes.count else { continue }
                solveRotationConstraint(
                    source: nodes[sourceNode],
                    target: nodes[constraint.targetNode],
                    weight: weight
                )
            }
        }
    }

    // MARK: - Topological Sort

    /// Sort constraints so each target is solved after all its direct sources.
    ///
    /// Uses Kahn's algorithm. Constraints that form part of a cycle are omitted
    /// from the result (their targets keep their current rotation for this frame).
    private func topologicalSort(constraints: [VRMNodeConstraint], nodeCount: Int) -> [VRMNodeConstraint] {
        guard constraints.count > 1 else { return constraints }

        // Build a map from constraintIndex → sourceNodeIndex for dependency tracking.
        // A constraint at index i has an edge: sourceNode → targetNode
        // We want to process constraints whose source has no pending constraint targeting it first.

        let n = constraints.count
        var inDegree = [Int](repeating: 0, count: n)
        // adjacency: when constraint[i]'s target is the source of constraint[j], j depends on i
        var adj = [[Int]](repeating: [], count: n)

        // VRMC_node_constraint-1.0: at most one constraint per target node.
        // If two constraints share a target, the later one wins (the dictionary overwrites).
        var nodeToConstraintIndex = [Int: Int]()
        for (i, c) in constraints.enumerated() {
            #if VRM_METALKIT_ENABLE_LOGS
            if let existing = nodeToConstraintIndex[c.targetNode] {
                vrmLog("[ConstraintSolver] Warning: duplicate constraint target node \(c.targetNode); constraint #\(existing) shadowed by #\(i)")
            }
            #endif
            nodeToConstraintIndex[c.targetNode] = i
        }

        for (j, c) in constraints.enumerated() {
            let srcNode = sourceNodeIndex(of: c)
            if let i = nodeToConstraintIndex[srcNode] {
                adj[i].append(j)
                inDegree[j] += 1
            }
        }

        var queue = [Int]()
        for i in 0..<n where inDegree[i] == 0 {
            queue.append(i)
        }

        var result = [VRMNodeConstraint]()
        result.reserveCapacity(n)
        var head = 0

        while head < queue.count {
            let i = queue[head]; head += 1
            result.append(constraints[i])
            for j in adj[i] {
                inDegree[j] -= 1
                if inDegree[j] == 0 {
                    queue.append(j)
                }
            }
        }

        if result.count < n {
            #if VRM_METALKIT_ENABLE_LOGS
            let skipped = n - result.count
            vrmLog("[ConstraintSolver] Warning: \(skipped) constraint(s) skipped due to dependency cycle")
            #endif
        }

        return result
    }

    /// Extract the source node index from any constraint type.
    private func sourceNodeIndex(of constraint: VRMNodeConstraint) -> Int {
        switch constraint.constraint {
        case .roll(let s, _, _): return s
        case .aim(let s, _, _): return s
        case .rotation(let s, _): return s
        }
    }

    // MARK: - Roll Constraint

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

    // MARK: - Aim Constraint

    /// Solve an aim constraint: rotate the target so its aimAxis points toward the source.
    ///
    /// Per the VRMC_node_constraint-1.0 spec, the aimAxis is expressed in target-local space.
    /// The constraint rotates the target (in its parent's frame) so that the aimAxis direction
    /// in world space aligns with the vector from target's world position to source's world position.
    ///
    /// - Parameters:
    ///   - source: The source node whose world position is the aim target
    ///   - target: The target node to rotate
    ///   - aimAxis: Unit vector in target-local space indicating the aim direction
    ///   - weight: Blend factor (0 = no effect, 1 = full aim)
    private func solveAimConstraint(source: VRMNode, target: VRMNode, aimAxis: SIMD3<Float>, weight: Float) {
        let targetWorldPos = target.worldPosition
        let sourceWorldPos = source.worldPosition

        let delta = sourceWorldPos - targetWorldPos
        let deltaLength = simd_length(delta)
        guard deltaLength > 1e-6 else { return }
        let aimVecWorld = delta / deltaLength

        // Convert the world-space aim vector into the target's parent frame.
        // If target has no parent, parent frame == world frame.
        let parentWorldRot: simd_quatf
        if let parent = target.parent {
            parentWorldRot = simd_quatf(parent.worldMatrix)
        } else {
            parentWorldRot = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }

        let invParentRot = parentWorldRot.inverse
        let aimVecInParent = invParentRot.act(aimVecWorld)

        // Compute the rotation that maps aimAxis → aimVecInParent.
        let aimRotation = simd_quatf(from: aimAxis, to: aimVecInParent)

        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let weighted = simd_slerp(identity, aimRotation, weight)

        target.rotation = weighted
        target.updateLocalMatrix()
    }

    // MARK: - Rotation Constraint

    /// Solve a rotation constraint: copy source's local rotation to target.
    ///
    /// Per the VRMC_node_constraint-1.0 spec, the source's local rotation is copied
    /// directly (not a delta from rest), blended by weight using slerp from identity.
    ///
    /// - Parameters:
    ///   - source: The source node to read rotation from
    ///   - target: The target node to write rotation to
    ///   - weight: Blend factor (0 = identity, 1 = full source rotation)
    private func solveRotationConstraint(source: VRMNode, target: VRMNode, weight: Float) {
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let weighted = simd_slerp(identity, source.rotation, weight)
        target.rotation = weighted
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

// MARK: - simd_quatf helpers

private extension simd_quatf {
    /// Extract a quaternion from the rotation part of a 4×4 column-major matrix.
    ///
    /// Each basis column is normalized first so that any non-uniform scale baked into
    /// the matrix (common on intermediate VRM nodes, especially after VRM 0.0 → 1.0
    /// conversion) does not contaminate the resulting rotation.
    init(_ m: float4x4) {
        let c0v = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let c1v = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let c2v = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let l0 = simd_length(c0v), l1 = simd_length(c1v), l2 = simd_length(c2v)
        guard l0 > 1e-8, l1 > 1e-8, l2 > 1e-8 else {
            self.init(ix: 0, iy: 0, iz: 0, r: 1)
            return
        }
        let r = float3x3(c0v / l0, c1v / l1, c2v / l2)
        self = simd_quatf(r)
    }
}
