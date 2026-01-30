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

/// Shared coordinate conversion utilities for ARKit to VRM/glTF transformation
///
/// ARKit and VRM/glTF use different coordinate systems:
/// - ARKit: Y-up, right-handed, camera faces -Z
/// - glTF/VRM: Y-up, right-handed, forward is +Z
///
/// This utility provides consistent conversion for both live preview (ARKitBodyDriver)
/// and recording (VRMARecorder).
public struct ARKitCoordinateConverter {

    // MARK: - Parent Hierarchy

    /// ARKit skeleton hierarchy - defines parent-child relationships for local rotation computation
    ///
    /// IMPORTANT: This must match ARKitBodyDriver's hierarchy exactly!
    /// ARKit provides world-space transforms, so we compute local rotations using:
    /// localRot = inverse(parentWorldRot) * childWorldRot
    ///
    /// Note: Upper arms connect directly to upperChest (not through shoulder).
    /// This is because ARKit's shoulder and arm data are independent - the shoulder
    /// is a clavicle rotation, not a parent of the arm in the kinematic chain.
    public static let arkitParentMap: [ARKitJoint: ARKitJoint] = [
        // Spine chain
        .spine: .hips,
        .chest: .spine,
        .upperChest: .chest,
        .neck: .upperChest,
        .head: .neck,
        // Left arm - shoulder and arm both parent to upperChest
        .leftShoulder: .upperChest,
        .leftUpperArm: .upperChest,  // NOT leftShoulder - they're independent in ARKit
        .leftLowerArm: .leftUpperArm,
        .leftHand: .leftLowerArm,
        // Right arm - shoulder and arm both parent to upperChest
        .rightShoulder: .upperChest,
        .rightUpperArm: .upperChest,  // NOT rightShoulder - they're independent in ARKit
        .rightLowerArm: .rightUpperArm,
        .rightHand: .rightLowerArm,
        // Left leg
        .leftUpperLeg: .hips,
        .leftLowerLeg: .leftUpperLeg,
        .leftFoot: .leftLowerLeg,
        .leftToes: .leftFoot,
        // Right leg
        .rightUpperLeg: .hips,
        .rightLowerLeg: .rightUpperLeg,
        .rightFoot: .rightLowerLeg,
        .rightToes: .rightFoot
    ]

    /// Left-side joints that need mirrored correction
    public static let leftSideJoints: Set<ARKitJoint> = [
        .leftShoulder, .leftUpperArm, .leftLowerArm, .leftHand,
        .leftUpperLeg, .leftLowerLeg, .leftFoot, .leftToes
    ]

    // MARK: - Rest Pose Calibration

    /// ARKit rest pose local rotations (A-pose bind pose)
    ///
    /// ARKit's skeleton is in A-pose: arms at ~45° down, legs slightly spread.
    /// VRM expects T-pose: arms horizontal, legs straight down.
    ///
    /// These quaternions represent the LOCAL rotation of each joint in ARKit's
    /// rest pose. We subtract these from measured rotations to get the delta
    /// from rest pose, which is what VRM expects.
    ///
    /// Values derived from real ARKit capture data of person standing in T-pose.
    /// The large rotations (especially legs ~97°) are because ARKit's skeleton
    /// bone directions differ from the identity orientation.
    public static let arkitRestPoseLocal: [ARKitJoint: simd_quatf] = {
        // Rest pose local rotations from REAL captured ARKit data.
        // These are the LOCAL rotations (child relative to parent) when a person
        // stands in neutral stance. ARKit's skeleton has large built-in rotations
        // because bone orientations differ from identity.
        //
        // Values are stored BEFORE left-side mirroring correction.
        // The conversion pipeline will: 1) subtract rest pose, 2) apply mirroring.
        //
        // Source: pipeline_capture_2026-01-29_00-15-38Z.json

        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

        return [
            // Spine chain - small rotations (spine is roughly aligned with world Y)
            .spine: identity,
            .chest: identity,
            .upperChest: identity,
            .neck: identity,
            .head: identity,

            // Shoulders - DISABLED (capture was in A-pose, not T-pose)
            // TODO: Re-capture with person in T-pose for proper calibration
            .leftShoulder: identity,
            .rightShoulder: identity,

            // Upper Arms - DISABLED (capture was in A-pose)
            // The captured values included the person's arm position, not just bone orientation
            .leftUpperArm: identity,
            .rightUpperArm: identity,

            // Forearms - DISABLED (capture was in A-pose)
            .leftLowerArm: identity,
            .rightLowerArm: identity,

            .leftHand: identity,
            .rightHand: identity,

            // Upper Legs - FROM REAL CAPTURE DATA
            // Left: 146° from identity, Right: 109° from identity
            .leftUpperLeg: simd_quatf(ix: 0.6504981, iy: -0.29361698, iz: 0.637561, r: -0.29009876),
            .rightUpperLeg: simd_quatf(ix: 0.4644171, iy: 0.43504587, iz: 0.5109663, r: 0.57789755),

            // Lower legs, feet - identity for now
            .leftLowerLeg: identity,
            .rightLowerLeg: identity,
            .leftFoot: identity,
            .rightFoot: identity,
            .leftToes: identity,
            .rightToes: identity,
        ]
    }()

    /// Whether rest pose calibration is enabled
    ///
    /// When true, the converter subtracts ARKit's rest pose from measured
    /// rotations to produce T-pose-relative deltas for VRM.
    ///
    /// Note: This is safe as it's only toggled for testing purposes.
    nonisolated(unsafe) public static var restPoseCalibrationEnabled: Bool = true

    // MARK: - Root Rotation Correction

    /// Combined rotation to transform ARKit world coordinates to glTF/VRM
    ///
    /// ARKit: Y-up, camera faces -Z (right-handed), person facing camera faces -Z
    /// glTF: Y-up, forward is +Z (right-handed), character should face +Z
    ///
    /// Both coordinate systems are Y-up, so we only need to flip the facing direction.
    /// A 180° rotation around Y flips forward from -Z to +Z while preserving Y-up.
    ///
    /// Only applied to the ROOT joint (hips) - child joints use local rotations.
    ///
    /// FIXED: Previous implementation used -90° X then -90° Y which incorrectly
    /// rotated the UP vector to point along X axis (causing 90° sideways tilt).
    public static let rootRotationCorrection: simd_quatf = {
        // 180° rotation around Y axis only - flips forward direction while preserving Y-up
        return simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
    }()

    // MARK: - Conversion Functions

    /// Convert root (hips) rotation from ARKit to glTF/VRM coordinate system
    public static func convertRootRotation(_ rotation: simd_quatf) -> simd_quatf {
        return simd_mul(rootRotationCorrection, rotation)
    }

    /// Convert local rotation for child joints
    ///
    /// Pipeline:
    /// 1. Normalize to positive w (short path interpolation)
    /// 2. Left-side mirroring: negate X and Z to match right-side behavior
    ///
    /// Note: Rest pose compensation (A-pose → T-pose) is handled separately
    /// via `aposeToTposeOffsets` in `computeVRMRotation`.
    public static func convertLocalRotation(_ rotation: simd_quatf, joint: ARKitJoint) -> simd_quatf {
        var q = rotation

        // Normalize to positive w (short path)
        if q.real < 0 {
            q = simd_quatf(real: -q.real, imag: -q.imag)
        }

        // Left-side mirroring: negate X and Z to match right-side behavior
        if leftSideJoints.contains(joint) {
            q = simd_quatf(real: q.real, imag: SIMD3<Float>(-q.imag.x, q.imag.y, -q.imag.z))
        }

        // REMOVED: Arm axis swap hack (x,z,y)
        // The axis swap was incorrect - it was swapping Y↔Z which caused arm raise
        // to go forward/back instead of up/down. The real issue is the A-pose vs
        // T-pose rest position difference, which is now handled by aposeToTposeOffsets.

        return q
    }

    // MARK: - T-Pose Calibration System

    /// Calibrated T-pose rotations captured from user standing in T-pose
    ///
    /// When the user calibrates by standing in T-pose, we capture the LOCAL
    /// rotations of each joint. These become the "zero point" - subsequent
    /// rotations are computed relative to this calibrated pose.
    ///
    /// If nil, falls back to default A-pose offsets.
    /// Thread-safe: Use `calibrateTpose(_:)` and `clearCalibration()` to modify.
    nonisolated(unsafe) private static var _calibratedTposeRotations: [ARKitJoint: simd_quatf]?

    /// Whether T-pose calibration is active
    public static var isCalibrated: Bool {
        return _calibratedTposeRotations != nil
    }

    /// Get the current calibration (nil if not calibrated)
    public static var calibratedTposeRotations: [ARKitJoint: simd_quatf]? {
        return _calibratedTposeRotations
    }

    /// Calibrate T-pose from a skeleton captured while user stands in T-pose
    ///
    /// Call this when the user is standing with arms horizontal (T-pose).
    /// The captured rotations become the reference - subsequent frames
    /// will be computed relative to this pose.
    ///
    /// - Parameter skeleton: The ARKit skeleton captured during T-pose
    public static func calibrateTpose(_ skeleton: ARKitBodySkeleton) {
        var calibration: [ARKitJoint: simd_quatf] = [:]

        // Capture local rotations for each joint
        for (joint, transform) in skeleton.joints {
            let childRot = extractRotation(from: transform)

            if let parentJoint = arkitParentMap[joint],
               let parentTransform = skeleton.joints[parentJoint] {
                // Compute local rotation relative to parent
                let parentRot = extractRotation(from: parentTransform)
                let localRot = simd_mul(simd_inverse(parentRot), childRot)
                calibration[joint] = localRot
            } else if joint == .hips {
                // Root joint uses world rotation
                calibration[joint] = childRot
            }
        }

        _calibratedTposeRotations = calibration

        #if DEBUG
        print("[ARKitCoordinateConverter] T-pose calibrated with \(calibration.count) joints")
        #endif
    }

    /// Clear T-pose calibration, reverting to default A-pose offsets
    public static func clearCalibration() {
        _calibratedTposeRotations = nil
        #if DEBUG
        print("[ARKitCoordinateConverter] T-pose calibration cleared")
        #endif
    }

    // MARK: - Default A-Pose to T-Pose Offsets

    /// Default rotation offsets when not calibrated
    ///
    /// These are approximate values for ARKit's A-pose (~35° below horizontal).
    /// For best results, use `calibrateTpose(_:)` with actual user data.
    ///
    /// Based on empirical observation:
    /// - ARKit A-pose arms are approximately 30-35° below horizontal
    /// - Z axis is the rotation axis for raising/lowering arms
    public static let defaultAposeOffsets: [ARKitJoint: simd_quatf] = {
        // A-pose arms are approximately 35° below horizontal
        // Using 35° instead of 45° based on typical ARKit observations
        let armAngle: Float = 35 * .pi / 180  // 35 degrees

        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

        return [
            // Left arm: negative Z rotation to compensate for A-pose
            // (A-pose is below T-pose, so we subtract the angle)
            .leftUpperArm: simd_quatf(angle: -armAngle, axis: SIMD3<Float>(0, 0, 1)),
            .leftLowerArm: identity,
            .leftHand: identity,

            // Right arm: positive Z rotation (mirrored)
            .rightUpperArm: simd_quatf(angle: armAngle, axis: SIMD3<Float>(0, 0, 1)),
            .rightLowerArm: identity,
            .rightHand: identity,

            // Other joints: no offset needed (similar in A and T pose)
            .leftShoulder: identity,
            .rightShoulder: identity,
            .spine: identity,
            .chest: identity,
            .upperChest: identity,
            .neck: identity,
            .head: identity,
        ]
    }()

    /// Get the effective rest pose offset for a joint
    ///
    /// If calibrated, returns the inverse of the calibrated T-pose rotation.
    /// Otherwise, returns the default A-pose offset.
    private static func getRestPoseOffset(for joint: ARKitJoint) -> simd_quatf? {
        if let calibration = _calibratedTposeRotations,
           let tposeRot = calibration[joint] {
            // When calibrated: offset = inverse of T-pose rotation
            // This makes T-pose input → identity output
            return simd_inverse(tposeRot)
        }

        // Fall back to default A-pose offsets
        return defaultAposeOffsets[joint]
    }

    // MARK: - Legacy Compatibility

    /// Legacy accessor for A-pose offsets (for existing tests)
    public static var aposeToTposeOffsets: [ARKitJoint: simd_quatf] {
        return defaultAposeOffsets
    }

    /// Extract rotation quaternion from a 4x4 transform matrix
    ///
    /// Handles non-uniform scale by normalizing each basis vector.
    public static func extractRotation(from transform: simd_float4x4) -> simd_quatf {
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

    /// Convert hips translation from ARKit to glTF coordinate system
    ///
    /// Negates Z to convert from ARKit's -Z forward to glTF's +Z forward.
    public static func convertHipsTranslation(from transform: simd_float4x4) -> simd_float3 {
        return simd_float3(
            transform.columns.3.x,
            transform.columns.3.y,
            -transform.columns.3.z
        )
    }

    // MARK: - Complete Conversion Pipeline

    /// Compute the final VRM rotation for a joint given its world transform and skeleton
    ///
    /// Pipeline:
    /// 1. Extract rotation from world transform
    /// 2. For non-root joints: compute local rotation relative to parent
    /// 3. Apply A-pose → T-pose compensation (arms need ~45° offset)
    /// 4. Apply joint-specific corrections (left-side mirroring)
    ///
    /// - Parameters:
    ///   - joint: The ARKit joint to convert
    ///   - childTransform: The world-space transform of this joint
    ///   - skeleton: The full skeleton for parent lookups
    /// - Returns: The converted rotation, or nil if parent transform is missing
    public static func computeVRMRotation(
        joint: ARKitJoint,
        childTransform: simd_float4x4,
        skeleton: ARKitBodySkeleton
    ) -> simd_quatf? {
        let childRot = extractRotation(from: childTransform)

        // Check if this joint has a parent in the hierarchy
        guard let parentJoint = arkitParentMap[joint] else {
            // Root joint (hips) - apply world coordinate correction
            return convertRootRotation(childRot)
        }

        // Joint has a parent - need parent transform to compute local rotation
        guard let parentTransform = skeleton.joints[parentJoint] else {
            // Parent transform missing - fall back to identity (T-pose rest position)
            // This is better than returning nil which would freeze the joint entirely.
            // The joint will stay at its rest pose until the parent becomes available.
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }

        // Compute local: inverse(parentWorld) * childWorld
        let parentRot = extractRotation(from: parentTransform)
        var localRot = simd_mul(simd_inverse(parentRot), childRot)

        // Apply rest pose compensation (A-pose → T-pose or calibrated T-pose)
        //
        // If calibrated: Uses captured T-pose rotations as reference
        // If not calibrated: Uses default ~35° A-pose offset for arms
        //
        // This converts ARKit's rotation to VRM's T-pose reference frame.
        if let restPoseOffset = getRestPoseOffset(for: joint) {
            // Apply offset: correctedRot = arkitLocalRot * offset
            localRot = simd_mul(localRot, restPoseOffset)
        }

        // Apply joint-specific corrections (left-side mirroring)
        return convertLocalRotation(localRot, joint: joint)
    }
}
