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

// MARK: - Body Tracking Driver

/// Primary API for driving VRM skeleton from ARKit body tracking data
///
/// Handles retargeting ARKit skeleton joints to VRM humanoid bones with smoothing,
/// transform decomposition, and multi-source support.
///
/// ## Thread Safety
/// **Thread-safe for updates.** Can be called from AR tracking threads or main thread.
/// Internal state is protected with locks where necessary.
///
/// ## Usage
///
/// ```swift
/// // Single-source tracking
/// let driver = ARKitBodyDriver(
///     mapper: .default,
///     smoothing: .default
/// )
///
/// func onBodyTracking(_ skeleton: ARKitBodySkeleton) {
///     driver.update(
///         skeleton: skeleton,
///         nodes: vrmModel.nodes,
///         humanoid: vrmModel.vrm?.humanoid
///     )
/// }
///
/// // Multi-source with priority
/// let driver = ARKitBodyDriver(
///     mapper: .default,
///     smoothing: .default,
///     priority: .latestActive
/// )
///
/// driver.updateMulti(
///     skeletons: [
///         "iPhone": iPhoneSkeleton,
///         "iPad": iPadSkeleton
///     ],
///     nodes: vrmModel.nodes,
///     humanoid: vrmModel.vrm?.humanoid
/// )
/// ```
///
/// ## Performance Characteristics
/// - Single-source update: ~50-100µs for full skeleton (50 joints)
/// - Multi-source merge: +20-50µs overhead
/// - Transform decomposition: ~2µs per joint
/// - Smoothing overhead: ~0.5µs per joint (EMA), ~1µs (Kalman)
/// - Memory: <10 KB for filters and state
public final class ARKitBodyDriver: @unchecked Sendable {
    /// Skeleton mapper (ARKit joints → VRM bones)
    public let mapper: ARKitSkeletonMapper

    /// Smoothing configuration
    private let smoothing: SkeletonSmoothingConfig

    /// Filter manager for smoothing (lazy initialized)
    private var filterManager: SkeletonFilterManager?

    /// Multi-source priority strategy
    public var priority: SourcePriority

    /// Staleness threshold (seconds)
    public var stalenessThreshold: TimeInterval

    /// Statistics
    private var updateCount: Int = 0
    private var skipCount: Int = 0
    private var lastUpdateTime: TimeInterval = 0

    /// Cached node lookups (invalidated on model change)
    private var cachedNodesByName: [String: VRMNode]?
    private var cachedHumanoidNodes: [String: VRMNode]?
    private var cachedRootNodes: [VRMNode]?

    /// Lock for thread safety
    private let lock = NSLock()

    /// Parent hierarchy for computing local rotations from world-space
    static let arkitParentMap: [ARKitJoint: ARKitJoint] = [
        .spine: .hips,
        .chest: .spine,
        .upperChest: .chest,
        .neck: .upperChest,
        .head: .neck,
        .leftShoulder: .upperChest,
        .leftUpperArm: .upperChest,  // ARKit doesn't provide leftShoulder, connect directly to upperChest
        .leftLowerArm: .leftUpperArm,
        .leftHand: .leftLowerArm,
        .rightShoulder: .upperChest,
        .rightUpperArm: .upperChest,  // ARKit doesn't provide rightShoulder, connect directly to upperChest
        .rightLowerArm: .rightUpperArm,
        .rightHand: .rightLowerArm,
        .leftUpperLeg: .hips,
        .leftLowerLeg: .leftUpperLeg,
        .leftFoot: .leftLowerLeg,
        .leftToes: .leftFoot,
        .rightUpperLeg: .hips,
        .rightLowerLeg: .rightUpperLeg,
        .rightFoot: .rightLowerLeg,
        .rightToes: .rightFoot,
    ]

    public init(
        mapper: ARKitSkeletonMapper = .default,
        smoothing: SkeletonSmoothingConfig = .default,
        priority: SourcePriority = .latestActive,
        stalenessThreshold: TimeInterval = 0.15
    ) {
        self.mapper = mapper
        self.smoothing = smoothing
        self.priority = priority
        self.stalenessThreshold = stalenessThreshold
    }

    // MARK: - Single Source Updates

    /// Update VRM skeleton from single ARKit body tracking source
    ///
    /// Retargets ARKit joint transforms to VRM humanoid bones and applies smoothing.
    ///
    /// - Parameters:
    ///   - skeleton: ARKit body skeleton data
    ///   - nodes: VRM model nodes (will be mutated)
    ///   - humanoid: VRM humanoid mapping (optional, uses node names if nil)
    public func update(
        skeleton: ARKitBodySkeleton,
        nodes: [VRMNode],
        humanoid: VRMHumanoid? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }

        // Check staleness
        if !skeleton.isTracked {
            skipCount += 1
            return
        }

        // Initialize filter manager lazily
        if filterManager == nil {
            filterManager = SkeletonFilterManager(config: smoothing)
        }

        // Build node lookup lazily (cached across frames)
        if cachedNodesByName == nil {
            var lookup: [String: VRMNode] = [:]
            for node in nodes {
                if let name = node.name {
                    lookup[name] = node
                }
            }
            cachedNodesByName = lookup
        }
        let nodesByName = cachedNodesByName!

        // Build humanoid nodes lazily (cached across frames)
        if cachedHumanoidNodes == nil, let humanoid = humanoid {
            var lookup: [String: VRMNode] = [:]
            for (boneType, boneInfo) in humanoid.humanBones {
                let nodeIndex = boneInfo.node
                if nodeIndex >= 0 && nodeIndex < nodes.count {
                    lookup[boneType.rawValue] = nodes[nodeIndex]
                }
            }
            cachedHumanoidNodes = lookup
        }
        let humanoidNodes = cachedHumanoidNodes ?? [:]

        // Log skeleton contents periodically
        #if DEBUG
        if updateCount % 60 == 0 {
            let joints = skeleton.joints.keys.map { $0.rawValue }.sorted()
            print("[BodyDriver] Skeleton has \(joints.count) joints: \(joints.joined(separator: ", "))")
        }
        #endif

        // Retarget each ARKit joint to VRM bone
        for (arkitJoint, transform) in skeleton.joints {
            // Get VRM bone name from mapper
            guard let vrmBoneName = mapper.vrmBone(for: arkitJoint) else {
                continue
            }

            // Find VRM node (prefer humanoid mapping, fallback to name match)
            let node: VRMNode? = humanoidNodes[vrmBoneName] ?? nodesByName[vrmBoneName]
            guard let node = node else {
                continue
            }

            // Debug: Log joint rotations (every 30 frames)
            #if DEBUG
            if updateCount % 30 == 0 {
                let logJoints: Set<ARKitJoint> = [.hips, .leftUpperLeg, .rightUpperLeg, .leftUpperArm, .rightUpperArm]
                if logJoints.contains(arkitJoint) {
                    let inputRot = extractRotation(from: transform)
                    print("[BodyDriver] \(arkitJoint) INPUT: w=\(String(format: "%.3f", inputRot.real)), x=\(String(format: "%.3f", inputRot.imag.x)), y=\(String(format: "%.3f", inputRot.imag.y)), z=\(String(format: "%.3f", inputRot.imag.z))")
                }
            }
            #endif

            // Compute local rotation with coordinate conversion
            // Returns nil if parent transform is missing (skip to avoid incorrect pose)
            guard let localRotation = computeLocalRotation(
                joint: arkitJoint,
                childTransform: transform,
                skeleton: skeleton
            ) else {
                #if DEBUG
                if updateCount % 30 == 0 {
                    let logJoints: Set<ARKitJoint> = [.leftUpperArm, .rightUpperArm, .leftShoulder, .rightShoulder]
                    if logJoints.contains(arkitJoint) {
                        if let parentJoint = Self.arkitParentMap[arkitJoint] {
                            print("[BodyDriver] \(arkitJoint) SKIPPED - missing parent: \(parentJoint)")
                        }
                    }
                }
                #endif
                continue  // Skip joint when parent data is missing
            }

            // Debug: Log joint output rotations (every 30 frames)
            #if DEBUG
            if updateCount % 30 == 0 {
                let logJoints: Set<ARKitJoint> = [.hips, .leftUpperLeg, .rightUpperLeg, .leftUpperArm, .rightUpperArm]
                if logJoints.contains(arkitJoint) {
                    print("[BodyDriver] \(arkitJoint) OUTPUT: w=\(String(format: "%.3f", localRotation.real)), x=\(String(format: "%.3f", localRotation.imag.x)), y=\(String(format: "%.3f", localRotation.imag.y)), z=\(String(format: "%.3f", localRotation.imag.z))")
                }
            }
            #endif

            // Apply smoothing
            let smoothedRotation: simd_quatf
            if let filter = filterManager {
                smoothedRotation = filter.updateRotation(joint: vrmBoneName, rotation: localRotation)
            } else {
                smoothedRotation = localRotation
            }

            // CRITICAL: Normalize quaternion to prevent vertex explosion
            // VRMNode.updateLocalMatrix() converts quaternion to matrix using a formula
            // that assumes the quaternion is normalized (x²+y²+z²+w² = 1).
            // Unnormalized quaternions cause scaling artifacts in the rotation matrix,
            // leading to mesh distortion ("vertex explosion") on the GPU.
            let normalizedRotation = simd_normalize(smoothedRotation)

            // Additional safety: Check for NaN (can occur with degenerate input)
            if normalizedRotation.real.isNaN || normalizedRotation.imag.x.isNaN ||
               normalizedRotation.imag.y.isNaN || normalizedRotation.imag.z.isNaN {
                // Skip this joint - preserves previous valid rotation
                continue
            }

            // Apply rotation only (preserve node's rest position)
            node.rotation = normalizedRotation
            node.updateLocalMatrix()
        }

        // Update world matrices for all affected nodes
        // Find root nodes lazily (cached across frames)
        if cachedRootNodes == nil {
            cachedRootNodes = nodes.filter { $0.parent == nil }
        }
        let rootNodes = cachedRootNodes!
        for root in rootNodes {
            root.updateWorldTransform()
        }

        // Update statistics
        updateCount += 1
        lastUpdateTime = skeleton.timestamp
    }

    // MARK: - Multi-Source Updates

    /// Update VRM skeleton from multiple ARKit body tracking sources
    ///
    /// Merges data from multiple cameras/sources using configured priority strategy.
    ///
    /// - Parameters:
    ///   - skeletons: Dictionary of source ID to skeleton data
    ///   - nodes: VRM model nodes (will be mutated)
    ///   - humanoid: VRM humanoid mapping (optional)
    public func updateMulti(
        skeletons: [String: ARKitBodySkeleton],
        nodes: [VRMNode],
        humanoid: VRMHumanoid? = nil
    ) {
        // Select source based on priority strategy
        guard let selectedSkeleton = selectSource(from: skeletons) else {
            lock.lock()
            skipCount += 1
            lock.unlock()
            return
        }

        // Use single-source update
        update(skeleton: selectedSkeleton, nodes: nodes, humanoid: humanoid)
    }

    // MARK: - Source Priority Strategies

    /// Strategy for selecting source when multiple are available
    public enum SourcePriority: Sendable {
        /// Use most recently updated source
        case latestActive

        /// Use primary source with fallback
        case primary(String, fallback: String?)

        /// Weighted blend of multiple sources (future)
        /// Note: Blending skeleton transforms is complex, deferred to Phase 4
        case weighted([String: Float])

        /// Use source with highest confidence
        case highestConfidence
    }

    private func selectSource(from skeletons: [String: ARKitBodySkeleton]) -> ARKitBodySkeleton? {
        switch priority {
        case .latestActive:
            return skeletons.values.max(by: { $0.timestamp < $1.timestamp })

        case .primary(let primaryID, let fallbackID):
            if let primary = skeletons[primaryID], primary.isTracked {
                return primary
            }
            if let fallbackID = fallbackID, let fallback = skeletons[fallbackID] {
                return fallback
            }
            // Last resort: any active source
            return skeletons.values.first(where: { $0.isTracked })

        case .weighted:
            // TODO: Implement weighted blending of transforms
            // For now, fallback to latestActive
            return skeletons.values.max(by: { $0.timestamp < $1.timestamp })

        case .highestConfidence:
            return skeletons.values
                .filter { $0.isTracked && $0.confidence != nil }
                .max(by: { ($0.confidence ?? 0) < ($1.confidence ?? 0) })
                ?? skeletons.values.first(where: { $0.isTracked })
        }
    }

    // MARK: - Transform Decomposition

    /// Decompose 4×4 transform matrix into position, rotation, and scale
    ///
    /// Uses Gram-Schmidt orthogonalization for robust scale extraction.
    ///
    /// - Parameter transform: 4×4 transformation matrix
    /// - Returns: Tuple of (position, rotation, scale)
    private func decomposeTransform(_ transform: simd_float4x4) -> (SIMD3<Float>, simd_quatf, SIMD3<Float>) {
        // Extract translation (4th column)
        let position = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )

        // Extract basis vectors (first 3 columns)
        var basisX = SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
        var basisY = SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
        var basisZ = SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)

        // Extract scale (magnitude of basis vectors)
        let scaleX = length(basisX)
        let scaleY = length(basisY)
        let scaleZ = length(basisZ)
        let scale = SIMD3<Float>(scaleX, scaleY, scaleZ)

        // Normalize basis vectors to extract rotation
        if scaleX > 0.0001 { basisX /= scaleX }
        if scaleY > 0.0001 { basisY /= scaleY }
        if scaleZ > 0.0001 { basisZ /= scaleZ }

        // Build rotation matrix from normalized basis vectors
        let rotationMatrix = simd_float3x3(
            basisX,
            basisY,
            basisZ
        )

        // Convert rotation matrix to quaternion
        let rotation = simd_quatf(rotationMatrix)

        return (position, rotation, scale)
    }

    // MARK: - Coordinate System Conversion

    /// Correction quaternion: -90° X then -90° Y rotation
    /// This corrects for the coordinate system difference between ARKit body tracking
    /// and glTF/VRM.
    ///
    /// Diagnostic results:
    /// - -90° X alone: avatar upright but head facing right, legs wrong
    /// - Need additional -90° Y to fix facing direction
    ///
    /// Only applied to the ROOT joint (hips) - child joints use local rotations.
    private static let rootRotationCorrection: simd_quatf = {
        let rotX = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))  // -90° around X
        let rotY = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(0, 1, 0))  // -90° around Y
        return simd_mul(rotY, rotX)  // Apply X first, then Y
    }()

    /// Convert root (hips) rotation from ARKit to glTF/VRM coordinate system
    private func convertRootRotationToGLTF(_ rotation: simd_quatf) -> simd_quatf {
        return simd_mul(Self.rootRotationCorrection, rotation)
    }

    /// Convert local rotation for child joints
    /// Direct mapping for right side, negate X for left side to fix flexion direction
    private func convertLocalRotationToGLTF(_ rotation: simd_quatf, joint: ARKitJoint) -> simd_quatf {
        // Normalize to positive w (short path) for consistent representation
        var q = rotation
        if q.real < 0 {
            q = simd_quatf(real: -q.real, imag: -q.imag)
        }

        // Left-side joints: negate X and Z to mirror to match right-side pattern
        // ARKit reports mirrored values for left vs right (x and z have opposite signs)
        if Self.leftSideJoints.contains(joint) {
            return simd_quatf(real: q.real, imag: SIMD3<Float>(-q.imag.x, q.imag.y, -q.imag.z))
        }
        return q
    }

    /// Left-side joints that need Z negation
    private static let leftSideJoints: Set<ARKitJoint> = [
        .leftShoulder, .leftUpperArm, .leftLowerArm, .leftHand,
        .leftUpperLeg, .leftLowerLeg, .leftFoot, .leftToes
    ]

    /// Compute local rotation from world-space transforms
    ///
    /// Returns `nil` if the joint has a parent in the hierarchy but that parent's
    /// transform is missing from the skeleton data. This prevents incorrect poses
    /// from using world rotation as local rotation.
    private func computeLocalRotation(
        joint: ARKitJoint,
        childTransform: simd_float4x4,
        skeleton: ARKitBodySkeleton
    ) -> simd_quatf? {
        let childRot = extractRotation(from: childTransform)

        // Check if this joint has a parent in the hierarchy
        guard let parentJoint = Self.arkitParentMap[joint] else {
            // Root joint (hips) - apply world coordinate correction
            return convertRootRotationToGLTF(childRot)
        }

        // Joint has a parent - require parent transform to compute local rotation
        guard let parentTransform = skeleton.joints[parentJoint] else {
            // Parent transform missing - skip this joint to avoid incorrect pose
            return nil
        }

        // Compute local: inverse(parentWorld) * childWorld
        let parentRot = extractRotation(from: parentTransform)
        let localRot = simd_mul(simd_inverse(parentRot), childRot)
        // Apply any joint-specific corrections (e.g., left-side mirroring)
        return convertLocalRotationToGLTF(localRot, joint: joint)
    }

    /// Extract rotation quaternion from transform matrix (for local rotation computation)
    private func extractRotation(from transform: simd_float4x4) -> simd_quatf {
        var basisX = SIMD3<Float>(
            transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
        var basisY = SIMD3<Float>(
            transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
        var basisZ = SIMD3<Float>(
            transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)

        let scaleX = length(basisX)
        let scaleY = length(basisY)
        let scaleZ = length(basisZ)

        if scaleX > 0.0001 { basisX /= scaleX }
        if scaleY > 0.0001 { basisY /= scaleY }
        if scaleZ > 0.0001 { basisZ /= scaleZ }

        return simd_quatf(simd_float3x3(basisX, basisY, basisZ))
    }

    // MARK: - Reset and Utilities

    /// Reset all smoothing filters
    public func resetFilters() {
        lock.lock()
        filterManager?.resetAll()
        lock.unlock()
    }

    /// Reset filters for specific joint
    public func resetFilters(for joint: String) {
        lock.lock()
        filterManager?.reset(joint: joint)
        lock.unlock()
    }

    /// Invalidate cached node lookups
    ///
    /// Call this method when the VRM model changes (e.g., new model loaded,
    /// nodes added/removed, humanoid mapping changed).
    ///
    /// Thread-safe: Uses internal lock for synchronization.
    public func invalidateCache() {
        lock.lock()
        cachedNodesByName = nil
        cachedHumanoidNodes = nil
        cachedRootNodes = nil
        lock.unlock()
    }

    /// Get statistics
    public func getStatistics() -> Statistics {
        lock.lock()
        defer { lock.unlock() }

        return Statistics(
            updateCount: updateCount,
            skipCount: skipCount,
            lastUpdateTime: lastUpdateTime
        )
    }

    /// Reset statistics
    public func resetStatistics() {
        lock.lock()
        updateCount = 0
        skipCount = 0
        lastUpdateTime = 0
        lock.unlock()
    }

    // MARK: - Statistics

    public struct Statistics: Sendable {
        public let updateCount: Int
        public let skipCount: Int
        public let lastUpdateTime: TimeInterval

        public var skipRate: Float {
            let total = updateCount + skipCount
            return total > 0 ? Float(skipCount) / Float(total) : 0
        }
    }
}
