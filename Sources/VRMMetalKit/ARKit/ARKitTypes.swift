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

// MARK: - ARKit Face Blend Shapes

/// Face blend shape data from ARKit, representing facial expression weights.
///
/// This type is transport-agnostic and can be populated from any source that provides
/// ARKit-compatible blend shape data (USB-C, Wi-Fi, NFC, recorded files).
///
/// ## Usage
///
/// ```swift
/// let blendShapes = ARKitFaceBlendShapes(
///     timestamp: CACurrentMediaTime(),
///     shapes: [
///         ARKitFaceBlendShapes.eyeBlinkLeft: 1.0,
///         ARKitFaceBlendShapes.eyeBlinkRight: 1.0,
///         ARKitFaceBlendShapes.jawOpen: 0.5
///     ]
/// )
/// ```
///
/// - Note: All weights are in the range [0, 1] where 0 is neutral and 1 is fully expressed.
public struct ARKitFaceBlendShapes: Sendable, Codable {
    /// Timestamp when this data was captured (in seconds since reference date)
    public let timestamp: TimeInterval

    /// Dictionary of blend shape names to weights (0-1)
    public let shapes: [String: Float]

    /// Head transform matrix (4x4, column-major) representing head position and rotation
    public let headTransform: simd_float4x4?

    /// Creates a blend shape snapshot from a timestamp, weight dictionary, and optional head transform.
    public init(timestamp: TimeInterval, shapes: [String: Float], headTransform: simd_float4x4? = nil) {
        self.timestamp = timestamp
        self.shapes = shapes
        self.headTransform = headTransform
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case timestamp
        case shapes
        case headTransform
    }

    /// Decodes a snapshot, reconstructing the head transform from a flat 16-element float array if present.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(TimeInterval.self, forKey: .timestamp)
        shapes = try container.decode([String: Float].self, forKey: .shapes)

        if let transformValues = try container.decodeIfPresent([Float].self, forKey: .headTransform),
           transformValues.count == 16 {
            headTransform = simd_float4x4(
                simd_float4(transformValues[0], transformValues[1], transformValues[2], transformValues[3]),
                simd_float4(transformValues[4], transformValues[5], transformValues[6], transformValues[7]),
                simd_float4(transformValues[8], transformValues[9], transformValues[10], transformValues[11]),
                simd_float4(transformValues[12], transformValues[13], transformValues[14], transformValues[15])
            )
        } else {
            headTransform = nil
        }
    }

    /// Encodes the snapshot, flattening any head transform into a 16-element float array.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(shapes, forKey: .shapes)

        if let matrix = headTransform {
            let values: [Float] = [
                matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z, matrix.columns.0.w,
                matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z, matrix.columns.1.w,
                matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z, matrix.columns.2.w,
                matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z, matrix.columns.3.w
            ]
            try container.encode(values, forKey: .headTransform)
        }
    }

    /// Get weight for a specific blend shape (returns 0 if not present)
    public func weight(for key: String) -> Float {
        return shapes[key] ?? 0
    }

    // MARK: - ARKit Blend Shape Keys (52 total)

    // Eyes
    /// ARKit blend shape key for left eyelid closing.
    public static let eyeBlinkLeft = "eyeBlinkLeft"
    /// ARKit blend shape key for right eyelid closing.
    public static let eyeBlinkRight = "eyeBlinkRight"
    /// ARKit blend shape key for left eye looking down.
    public static let eyeLookDownLeft = "eyeLookDownLeft"
    /// ARKit blend shape key for right eye looking down.
    public static let eyeLookDownRight = "eyeLookDownRight"
    /// ARKit blend shape key for left eye looking toward the nose.
    public static let eyeLookInLeft = "eyeLookInLeft"
    /// ARKit blend shape key for right eye looking toward the nose.
    public static let eyeLookInRight = "eyeLookInRight"
    /// ARKit blend shape key for left eye looking away from the nose.
    public static let eyeLookOutLeft = "eyeLookOutLeft"
    /// ARKit blend shape key for right eye looking away from the nose.
    public static let eyeLookOutRight = "eyeLookOutRight"
    /// ARKit blend shape key for left eye looking up.
    public static let eyeLookUpLeft = "eyeLookUpLeft"
    /// ARKit blend shape key for right eye looking up.
    public static let eyeLookUpRight = "eyeLookUpRight"
    /// ARKit blend shape key for left eye squinting (narrowing).
    public static let eyeSquintLeft = "eyeSquintLeft"
    /// ARKit blend shape key for right eye squinting (narrowing).
    public static let eyeSquintRight = "eyeSquintRight"
    /// ARKit blend shape key for left eye widening.
    public static let eyeWideLeft = "eyeWideLeft"
    /// ARKit blend shape key for right eye widening.
    public static let eyeWideRight = "eyeWideRight"

    // Jaw
    /// ARKit blend shape key for jaw thrust forward.
    public static let jawForward = "jawForward"
    /// ARKit blend shape key for jaw shifted to the subject's left.
    public static let jawLeft = "jawLeft"
    /// ARKit blend shape key for jaw open.
    public static let jawOpen = "jawOpen"
    /// ARKit blend shape key for jaw shifted to the subject's right.
    public static let jawRight = "jawRight"

    // Mouth
    /// ARKit blend shape key for closing the mouth (counteracts jaw open).
    public static let mouthClose = "mouthClose"
    /// ARKit blend shape key for left mouth-corner dimple.
    public static let mouthDimpleLeft = "mouthDimpleLeft"
    /// ARKit blend shape key for right mouth-corner dimple.
    public static let mouthDimpleRight = "mouthDimpleRight"
    /// ARKit blend shape key for left mouth-corner frown (downward pull).
    public static let mouthFrownLeft = "mouthFrownLeft"
    /// ARKit blend shape key for right mouth-corner frown (downward pull).
    public static let mouthFrownRight = "mouthFrownRight"
    /// ARKit blend shape key for funnel-shaped lip protrusion.
    public static let mouthFunnel = "mouthFunnel"
    /// ARKit blend shape key for mouth shifted to the subject's left.
    public static let mouthLeft = "mouthLeft"
    /// ARKit blend shape key for left lower lip pulled down.
    public static let mouthLowerDownLeft = "mouthLowerDownLeft"
    /// ARKit blend shape key for right lower lip pulled down.
    public static let mouthLowerDownRight = "mouthLowerDownRight"
    /// ARKit blend shape key for left lip press (lips pressed together).
    public static let mouthPressLeft = "mouthPressLeft"
    /// ARKit blend shape key for right lip press (lips pressed together).
    public static let mouthPressRight = "mouthPressRight"
    /// ARKit blend shape key for pursed-lip pucker.
    public static let mouthPucker = "mouthPucker"
    /// ARKit blend shape key for mouth shifted to the subject's right.
    public static let mouthRight = "mouthRight"
    /// ARKit blend shape key for rolling the lower lip inward.
    public static let mouthRollLower = "mouthRollLower"
    /// ARKit blend shape key for rolling the upper lip inward.
    public static let mouthRollUpper = "mouthRollUpper"
    /// ARKit blend shape key for lower lip shrug (pushed up over teeth).
    public static let mouthShrugLower = "mouthShrugLower"
    /// ARKit blend shape key for upper lip shrug (pushed up).
    public static let mouthShrugUpper = "mouthShrugUpper"
    /// ARKit blend shape key for left mouth-corner smile (upward pull).
    public static let mouthSmileLeft = "mouthSmileLeft"
    /// ARKit blend shape key for right mouth-corner smile (upward pull).
    public static let mouthSmileRight = "mouthSmileRight"
    /// ARKit blend shape key for left mouth-corner stretch (sideways pull).
    public static let mouthStretchLeft = "mouthStretchLeft"
    /// ARKit blend shape key for right mouth-corner stretch (sideways pull).
    public static let mouthStretchRight = "mouthStretchRight"
    /// ARKit blend shape key for left upper lip raised.
    public static let mouthUpperUpLeft = "mouthUpperUpLeft"
    /// ARKit blend shape key for right upper lip raised.
    public static let mouthUpperUpRight = "mouthUpperUpRight"

    // Nose
    /// ARKit blend shape key for left nostril sneer.
    public static let noseSneerLeft = "noseSneerLeft"
    /// ARKit blend shape key for right nostril sneer.
    public static let noseSneerRight = "noseSneerRight"

    // Cheek
    /// ARKit blend shape key for cheek puff (both cheeks outward).
    public static let cheekPuff = "cheekPuff"
    /// ARKit blend shape key for left cheek squint (raised toward eye).
    public static let cheekSquintLeft = "cheekSquintLeft"
    /// ARKit blend shape key for right cheek squint (raised toward eye).
    public static let cheekSquintRight = "cheekSquintRight"

    // Brow
    /// ARKit blend shape key for left inner brow pulled down.
    public static let browDownLeft = "browDownLeft"
    /// ARKit blend shape key for right inner brow pulled down.
    public static let browDownRight = "browDownRight"
    /// ARKit blend shape key for inner brow raised.
    public static let browInnerUp = "browInnerUp"
    /// ARKit blend shape key for left outer brow raised.
    public static let browOuterUpLeft = "browOuterUpLeft"
    /// ARKit blend shape key for right outer brow raised.
    public static let browOuterUpRight = "browOuterUpRight"

    // Tongue
    /// ARKit blend shape key for tongue protruding past the lips.
    public static let tongueOut = "tongueOut"

    /// Canonical list of all 52 ARKit blend shape keys, ordered eyes → jaw → mouth → nose → cheek → brow → tongue.
    public static let allKeys: [String] = [
        eyeBlinkLeft, eyeBlinkRight,
        eyeLookDownLeft, eyeLookDownRight,
        eyeLookInLeft, eyeLookInRight,
        eyeLookOutLeft, eyeLookOutRight,
        eyeLookUpLeft, eyeLookUpRight,
        eyeSquintLeft, eyeSquintRight,
        eyeWideLeft, eyeWideRight,
        jawForward, jawLeft, jawOpen, jawRight,
        mouthClose, mouthDimpleLeft, mouthDimpleRight,
        mouthFrownLeft, mouthFrownRight, mouthFunnel,
        mouthLeft, mouthLowerDownLeft, mouthLowerDownRight,
        mouthPressLeft, mouthPressRight, mouthPucker,
        mouthRight, mouthRollLower, mouthRollUpper,
        mouthShrugLower, mouthShrugUpper,
        mouthSmileLeft, mouthSmileRight,
        mouthStretchLeft, mouthStretchRight,
        mouthUpperUpLeft, mouthUpperUpRight,
        noseSneerLeft, noseSneerRight,
        cheekPuff, cheekSquintLeft, cheekSquintRight,
        browDownLeft, browDownRight, browInnerUp,
        browOuterUpLeft, browOuterUpRight,
        tongueOut
    ]
}

// MARK: - ARKit Body Skeleton

/// ARKit body joint identifiers
///
/// Maps to ARKit's body tracking joints. Not all joints may be available
/// depending on tracking quality and device capabilities.
public enum ARKitJoint: String, CaseIterable, Sendable, Codable {
    // Root
    /// Scene-graph root joint.
    case root

    // Torso
    /// Hips joint (pelvis); the kinematic root of the humanoid in ``ARKitCoordinateConverter/arkitParentMap``.
    case hips
    /// Lower spine joint, parented to ``hips``.
    case spine
    /// Mid-spine (chest) joint, parented to ``spine``.
    case chest
    /// Upper chest joint, parented to ``chest``; parent of shoulders and upper arms.
    case upperChest
    /// Neck joint, parented to ``upperChest``.
    case neck
    /// Head joint, parented to ``neck``.
    case head

    // Left arm
    /// Left clavicle joint; in ARKit's hierarchy this is independent of ``leftUpperArm``.
    case leftShoulder
    /// Left upper arm joint, parented to ``upperChest`` (not the shoulder) in this implementation.
    case leftUpperArm
    /// Left forearm joint.
    case leftLowerArm
    /// Left wrist joint.
    case leftHand

    // Right arm
    /// Right clavicle joint; in ARKit's hierarchy this is independent of ``rightUpperArm``.
    case rightShoulder
    /// Right upper arm joint, parented to ``upperChest`` (not the shoulder) in this implementation.
    case rightUpperArm
    /// Right forearm joint.
    case rightLowerArm
    /// Right wrist joint.
    case rightHand

    // Left leg
    /// Left thigh joint, parented to ``hips``.
    case leftUpperLeg
    /// Left shin joint.
    case leftLowerLeg
    /// Left foot joint.
    case leftFoot
    /// Left toes joint.
    case leftToes

    // Right leg
    /// Right thigh joint, parented to ``hips``.
    case rightUpperLeg
    /// Right shin joint.
    case rightLowerLeg
    /// Right foot joint.
    case rightFoot
    /// Right toes joint.
    case rightToes

    // Optional finger joints (if available)
    /// Left thumb proximal joint (closest to palm); maps to VRM `leftThumbProximal`.
    case leftHandThumb1
    /// Left thumb intermediate joint; maps to VRM `leftThumbIntermediate`.
    case leftHandThumb2
    /// Left thumb distal joint; maps to VRM `leftThumbDistal`.
    case leftHandThumb3
    /// Left thumb tip joint (no VRM humanoid bone mapping).
    case leftHandThumb4
    /// Left index proximal joint (closest to palm); maps to VRM `leftIndexProximal`.
    case leftHandIndex1
    /// Left index intermediate joint; maps to VRM `leftIndexIntermediate`.
    case leftHandIndex2
    /// Left index distal joint; maps to VRM `leftIndexDistal`.
    case leftHandIndex3
    /// Left index tip joint (no VRM humanoid bone mapping).
    case leftHandIndex4
    /// Left middle proximal joint (closest to palm); maps to VRM `leftMiddleProximal`.
    case leftHandMiddle1
    /// Left middle intermediate joint; maps to VRM `leftMiddleIntermediate`.
    case leftHandMiddle2
    /// Left middle distal joint; maps to VRM `leftMiddleDistal`.
    case leftHandMiddle3
    /// Left middle tip joint (no VRM humanoid bone mapping).
    case leftHandMiddle4
    /// Left ring proximal joint (closest to palm); maps to VRM `leftRingProximal`.
    case leftHandRing1
    /// Left ring intermediate joint; maps to VRM `leftRingIntermediate`.
    case leftHandRing2
    /// Left ring distal joint; maps to VRM `leftRingDistal`.
    case leftHandRing3
    /// Left ring tip joint (no VRM humanoid bone mapping).
    case leftHandRing4
    /// Left pinky (little) proximal joint (closest to palm); maps to VRM `leftLittleProximal`.
    case leftHandPinky1
    /// Left pinky (little) intermediate joint; maps to VRM `leftLittleIntermediate`.
    case leftHandPinky2
    /// Left pinky (little) distal joint; maps to VRM `leftLittleDistal`.
    case leftHandPinky3
    /// Left pinky (little) tip joint (no VRM humanoid bone mapping).
    case leftHandPinky4

    /// Right thumb proximal joint (closest to palm); maps to VRM `rightThumbProximal`.
    case rightHandThumb1
    /// Right thumb intermediate joint; maps to VRM `rightThumbIntermediate`.
    case rightHandThumb2
    /// Right thumb distal joint; maps to VRM `rightThumbDistal`.
    case rightHandThumb3
    /// Right thumb tip joint (no VRM humanoid bone mapping).
    case rightHandThumb4
    /// Right index proximal joint (closest to palm); maps to VRM `rightIndexProximal`.
    case rightHandIndex1
    /// Right index intermediate joint; maps to VRM `rightIndexIntermediate`.
    case rightHandIndex2
    /// Right index distal joint; maps to VRM `rightIndexDistal`.
    case rightHandIndex3
    /// Right index tip joint (no VRM humanoid bone mapping).
    case rightHandIndex4
    /// Right middle proximal joint (closest to palm); maps to VRM `rightMiddleProximal`.
    case rightHandMiddle1
    /// Right middle intermediate joint; maps to VRM `rightMiddleIntermediate`.
    case rightHandMiddle2
    /// Right middle distal joint; maps to VRM `rightMiddleDistal`.
    case rightHandMiddle3
    /// Right middle tip joint (no VRM humanoid bone mapping).
    case rightHandMiddle4
    /// Right ring proximal joint (closest to palm); maps to VRM `rightRingProximal`.
    case rightHandRing1
    /// Right ring intermediate joint; maps to VRM `rightRingIntermediate`.
    case rightHandRing2
    /// Right ring distal joint; maps to VRM `rightRingDistal`.
    case rightHandRing3
    /// Right ring tip joint (no VRM humanoid bone mapping).
    case rightHandRing4
    /// Right pinky (little) proximal joint (closest to palm); maps to VRM `rightLittleProximal`.
    case rightHandPinky1
    /// Right pinky (little) intermediate joint; maps to VRM `rightLittleIntermediate`.
    case rightHandPinky2
    /// Right pinky (little) distal joint; maps to VRM `rightLittleDistal`.
    case rightHandPinky3
    /// Right pinky (little) tip joint (no VRM humanoid bone mapping).
    case rightHandPinky4
}

/// Body skeleton data from ARKit
///
/// Contains joint transforms in world space. Not all joints may be tracked at all times.
///
/// ## Usage
///
/// ```swift
/// let skeleton = ARKitBodySkeleton(
///     timestamp: CACurrentMediaTime(),
///     joints: [
///         .hips: hipsTransform,
///         .leftUpperArm: leftArmTransform,
///         // ...
///     ],
///     isTracked: true
/// )
/// ```
public struct ARKitBodySkeleton: Sendable {
    /// Timestamp when this data was captured
    public let timestamp: TimeInterval

    /// Joint transforms (world space, 4x4 matrices)
    public let joints: [ARKitJoint: simd_float4x4]

    /// Whether body tracking is currently active and reliable
    public let isTracked: Bool

    /// Tracking confidence (0-1), if available
    public let confidence: Float?

    /// Creates a skeleton snapshot from a timestamp, joint transform map, tracking flag, and optional confidence.
    public init(
        timestamp: TimeInterval,
        joints: [ARKitJoint: simd_float4x4],
        isTracked: Bool,
        confidence: Float? = nil
    ) {
        self.timestamp = timestamp
        self.joints = joints
        self.isTracked = isTracked
        self.confidence = confidence
    }

    /// Get transform for a specific joint (returns nil if not tracked)
    public func transform(for joint: ARKitJoint) -> simd_float4x4? {
        return joints[joint]
    }

    /// Check if a specific joint is tracked
    public func hasJoint(_ joint: ARKitJoint) -> Bool {
        return joints[joint] != nil
    }

    /// Get subset of skeleton with only specified joints
    public func subset(joints: Set<ARKitJoint>) -> ARKitBodySkeleton {
        let filtered = self.joints.filter { joints.contains($0.key) }
        return ARKitBodySkeleton(
            timestamp: timestamp,
            joints: filtered,
            isTracked: isTracked && !filtered.isEmpty,
            confidence: confidence
        )
    }
}

// MARK: - ARKitBodySkeleton Codable Conformance

extension ARKitBodySkeleton: Codable {
    enum CodingKeys: String, CodingKey {
        case timestamp
        case joints
        case isTracked
        case confidence
    }

    /// Decodes a skeleton snapshot, rebuilding each joint's 4×4 matrix from a flat 16-float string array.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(TimeInterval.self, forKey: .timestamp)
        isTracked = try container.decode(Bool.self, forKey: .isTracked)
        confidence = try container.decodeIfPresent(Float.self, forKey: .confidence)

        // Decode dictionary as array of pairs
        let jointPairs = try container.decode([[String]].self, forKey: .joints)
        var jointsDict: [ARKitJoint: simd_float4x4] = [:]
        for pair in jointPairs {
            guard pair.count == 17 else { continue } // 1 key + 16 matrix values
            guard let joint = ARKitJoint(rawValue: pair[0]) else { continue }

            // Reconstruct 4x4 matrix from 16 floats
            let values = pair[1...].compactMap { Float($0) }
            guard values.count == 16 else { continue }

            let matrix = simd_float4x4(
                simd_float4(values[0], values[1], values[2], values[3]),
                simd_float4(values[4], values[5], values[6], values[7]),
                simd_float4(values[8], values[9], values[10], values[11]),
                simd_float4(values[12], values[13], values[14], values[15])
            )
            jointsDict[joint] = matrix
        }
        joints = jointsDict
    }

    /// Encodes the skeleton snapshot, flattening each joint's matrix into a 16-float string array.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(isTracked, forKey: .isTracked)
        try container.encodeIfPresent(confidence, forKey: .confidence)

        // Encode dictionary as array of pairs
        let jointPairs: [[String]] = joints.map { joint, matrix in
            var pair = [joint.rawValue]
            // Flatten 4x4 matrix to 16 floats
            for col in 0..<4 {
                for row in 0..<4 {
                    pair.append(String(matrix[col][row]))
                }
            }
            return pair
        }
        try container.encode(jointPairs, forKey: .joints)
    }
}

// MARK: - Metadata Source Protocol

/// Represents a source of AR metadata (face, body, or combined)
///
/// Sources can be remote devices (iPhone via Continuity Camera), local recordings,
/// or any other provider of ARKit-compatible data.
///
/// ## Thread Safety
/// **Thread-safe.** All properties can be read from any thread. Updates should use
/// thread-safe mechanisms (locks, actors, or atomic operations).
public protocol ARMetadataSource: Sendable {
    /// Unique identifier for this source
    var sourceID: UUID { get }

    /// Human-readable name (e.g., "iPhone 15 Pro", "iPad Side Camera")
    var name: String { get }

    /// Timestamp of last received update
    var lastUpdate: TimeInterval { get }

    /// Whether this source is currently active (not stale)
    /// Typically true if lastUpdate is within 150ms of current time
    var isActive: Bool { get }

    /// Optional metadata about the source (device model, connection type, etc.)
    var metadata: [String: String] { get }
}

// MARK: - Face Source

/// Source of ARKit face tracking data, holding the latest ``ARKitFaceBlendShapes`` snapshot under an internal lock.
///
/// Push new snapshots in via ``update(blendShapes:)`` from any thread; readers fetch the most recent via
/// ``blendShapes``. Marked `@unchecked Sendable` because the `NSLock` is held over every mutating access.
public final class ARFaceSource: ARMetadataSource, @unchecked Sendable {
    /// Stable identifier used by ``ARKitFaceDriver`` priority strategies to select among multiple sources.
    public let sourceID: UUID
    /// Human-readable name (e.g., "iPhone 15 Pro").
    public let name: String
    /// Timestamp of the most recent ``update(blendShapes:)`` call.
    public private(set) var lastUpdate: TimeInterval
    /// Free-form metadata about the source (device model, connection type, etc.).
    public var metadata: [String: String]

    /// Maximum age before source is considered stale (default: 150ms)
    public var maxAge: TimeInterval = 0.150

    /// Whether ``lastUpdate`` is within ``maxAge`` of the current time.
    public var isActive: Bool {
        let now = Date().timeIntervalSinceReferenceDate
        return now - lastUpdate < maxAge
    }

    /// Latest blend shapes (thread-safe access)
    private var _blendShapes: ARKitFaceBlendShapes?
    private let lock = NSLock()

    /// Latest pushed ``ARKitFaceBlendShapes`` snapshot, or `nil` if none has arrived. Safe to read from any thread.
    public var blendShapes: ARKitFaceBlendShapes? {
        lock.lock()
        defer { lock.unlock() }
        return _blendShapes
    }

    /// Creates a face source with an identifier, display name, and optional metadata. `lastUpdate` starts at 0.
    public init(sourceID: UUID = UUID(), name: String, metadata: [String: String] = [:]) {
        self.sourceID = sourceID
        self.name = name
        self.lastUpdate = 0
        self.metadata = metadata
    }

    /// Replaces the stored blend shapes and advances ``lastUpdate`` to the snapshot's timestamp.
    public func update(blendShapes: ARKitFaceBlendShapes) {
        lock.lock()
        defer { lock.unlock() }
        _blendShapes = blendShapes
        lastUpdate = blendShapes.timestamp
    }
}

// MARK: - Body Source

/// Source of ARKit body tracking data, holding the latest ``ARKitBodySkeleton`` snapshot under an internal lock.
///
/// Companion to ``ARFaceSource`` for body-only producers. Marked `@unchecked Sendable` because the
/// `NSLock` guards every mutating access.
public final class ARBodySource: ARMetadataSource, @unchecked Sendable {
    /// Stable identifier used to disambiguate multiple body sources.
    public let sourceID: UUID
    /// Human-readable name for the source.
    public let name: String
    /// Timestamp of the most recent ``update(skeleton:)`` call.
    public private(set) var lastUpdate: TimeInterval
    /// Free-form metadata about the source.
    public var metadata: [String: String]

    /// Maximum age before this source is considered stale (default: 150 ms).
    public var maxAge: TimeInterval = 0.150

    /// Whether ``lastUpdate`` is within ``maxAge`` of the current time.
    public var isActive: Bool {
        let now = Date().timeIntervalSinceReferenceDate
        return now - lastUpdate < maxAge
    }

    private var _skeleton: ARKitBodySkeleton?
    private let lock = NSLock()

    /// Latest pushed ``ARKitBodySkeleton`` snapshot, or `nil` if none has arrived. Safe to read from any thread.
    public var skeleton: ARKitBodySkeleton? {
        lock.lock()
        defer { lock.unlock() }
        return _skeleton
    }

    /// Creates a body source with an identifier, display name, and optional metadata. `lastUpdate` starts at 0.
    public init(sourceID: UUID = UUID(), name: String, metadata: [String: String] = [:]) {
        self.sourceID = sourceID
        self.name = name
        self.lastUpdate = 0
        self.metadata = metadata
    }

    /// Replaces the stored skeleton and advances ``lastUpdate`` to the snapshot's timestamp.
    public func update(skeleton: ARKitBodySkeleton) {
        lock.lock()
        defer { lock.unlock() }
        _skeleton = skeleton
        lastUpdate = skeleton.timestamp
    }
}

// MARK: - Combined Source

/// Source providing both face blend shapes and body skeleton under a single identifier.
///
/// Use when a single hardware producer (e.g., one iPhone running an `ARFaceTrackingConfiguration` plus body
/// tracking) supplies both modalities. ``lastUpdate`` advances monotonically with whichever stream is newer.
public final class ARCombinedSource: ARMetadataSource, @unchecked Sendable {
    /// Stable identifier used to disambiguate sources.
    public let sourceID: UUID
    /// Human-readable name for the source.
    public let name: String
    /// Timestamp of the most recent update across either stream (max of face and body timestamps).
    public private(set) var lastUpdate: TimeInterval
    /// Free-form metadata about the source.
    public var metadata: [String: String]

    /// Maximum age before this source is considered stale (default: 150 ms).
    public var maxAge: TimeInterval = 0.150

    /// Whether ``lastUpdate`` is within ``maxAge`` of the current time.
    public var isActive: Bool {
        let now = Date().timeIntervalSinceReferenceDate
        return now - lastUpdate < maxAge
    }

    private var _blendShapes: ARKitFaceBlendShapes?
    private var _skeleton: ARKitBodySkeleton?
    private let lock = NSLock()

    /// Latest pushed face blend shapes, or `nil` if none has arrived. Safe to read from any thread.
    public var blendShapes: ARKitFaceBlendShapes? {
        lock.lock()
        defer { lock.unlock() }
        return _blendShapes
    }

    /// Latest pushed body skeleton, or `nil` if none has arrived. Safe to read from any thread.
    public var skeleton: ARKitBodySkeleton? {
        lock.lock()
        defer { lock.unlock() }
        return _skeleton
    }

    /// Creates a combined source with an identifier, display name, and optional metadata.
    public init(sourceID: UUID = UUID(), name: String, metadata: [String: String] = [:]) {
        self.sourceID = sourceID
        self.name = name
        self.lastUpdate = 0
        self.metadata = metadata
    }

    /// Replaces the face snapshot and advances ``lastUpdate`` to the newer of its timestamp or the previous value.
    public func update(blendShapes: ARKitFaceBlendShapes) {
        lock.lock()
        defer { lock.unlock() }
        _blendShapes = blendShapes
        lastUpdate = max(lastUpdate, blendShapes.timestamp)
    }

    /// Replaces the body snapshot and advances ``lastUpdate`` to the newer of its timestamp or the previous value.
    public func update(skeleton: ARKitBodySkeleton) {
        lock.lock()
        defer { lock.unlock() }
        _skeleton = skeleton
        lastUpdate = max(lastUpdate, skeleton.timestamp)
    }
}
