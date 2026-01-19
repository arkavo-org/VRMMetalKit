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
    public static let eyeBlinkLeft = "eyeBlinkLeft"
    public static let eyeBlinkRight = "eyeBlinkRight"
    public static let eyeLookDownLeft = "eyeLookDownLeft"
    public static let eyeLookDownRight = "eyeLookDownRight"
    public static let eyeLookInLeft = "eyeLookInLeft"
    public static let eyeLookInRight = "eyeLookInRight"
    public static let eyeLookOutLeft = "eyeLookOutLeft"
    public static let eyeLookOutRight = "eyeLookOutRight"
    public static let eyeLookUpLeft = "eyeLookUpLeft"
    public static let eyeLookUpRight = "eyeLookUpRight"
    public static let eyeSquintLeft = "eyeSquintLeft"
    public static let eyeSquintRight = "eyeSquintRight"
    public static let eyeWideLeft = "eyeWideLeft"
    public static let eyeWideRight = "eyeWideRight"

    // Jaw
    public static let jawForward = "jawForward"
    public static let jawLeft = "jawLeft"
    public static let jawOpen = "jawOpen"
    public static let jawRight = "jawRight"

    // Mouth
    public static let mouthClose = "mouthClose"
    public static let mouthDimpleLeft = "mouthDimpleLeft"
    public static let mouthDimpleRight = "mouthDimpleRight"
    public static let mouthFrownLeft = "mouthFrownLeft"
    public static let mouthFrownRight = "mouthFrownRight"
    public static let mouthFunnel = "mouthFunnel"
    public static let mouthLeft = "mouthLeft"
    public static let mouthLowerDownLeft = "mouthLowerDownLeft"
    public static let mouthLowerDownRight = "mouthLowerDownRight"
    public static let mouthPressLeft = "mouthPressLeft"
    public static let mouthPressRight = "mouthPressRight"
    public static let mouthPucker = "mouthPucker"
    public static let mouthRight = "mouthRight"
    public static let mouthRollLower = "mouthRollLower"
    public static let mouthRollUpper = "mouthRollUpper"
    public static let mouthShrugLower = "mouthShrugLower"
    public static let mouthShrugUpper = "mouthShrugUpper"
    public static let mouthSmileLeft = "mouthSmileLeft"
    public static let mouthSmileRight = "mouthSmileRight"
    public static let mouthStretchLeft = "mouthStretchLeft"
    public static let mouthStretchRight = "mouthStretchRight"
    public static let mouthUpperUpLeft = "mouthUpperUpLeft"
    public static let mouthUpperUpRight = "mouthUpperUpRight"

    // Nose
    public static let noseSneerLeft = "noseSneerLeft"
    public static let noseSneerRight = "noseSneerRight"

    // Cheek
    public static let cheekPuff = "cheekPuff"
    public static let cheekSquintLeft = "cheekSquintLeft"
    public static let cheekSquintRight = "cheekSquintRight"

    // Brow
    public static let browDownLeft = "browDownLeft"
    public static let browDownRight = "browDownRight"
    public static let browInnerUp = "browInnerUp"
    public static let browOuterUpLeft = "browOuterUpLeft"
    public static let browOuterUpRight = "browOuterUpRight"

    // Tongue
    public static let tongueOut = "tongueOut"

    /// All 52 ARKit blend shape keys
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
    case root

    // Torso
    case hips
    case spine
    case chest
    case upperChest
    case neck
    case head

    // Left arm
    case leftShoulder
    case leftUpperArm
    case leftLowerArm
    case leftHand

    // Right arm
    case rightShoulder
    case rightUpperArm
    case rightLowerArm
    case rightHand

    // Left leg
    case leftUpperLeg
    case leftLowerLeg
    case leftFoot
    case leftToes

    // Right leg
    case rightUpperLeg
    case rightLowerLeg
    case rightFoot
    case rightToes

    // Optional finger joints (if available)
    case leftHandThumb1, leftHandThumb2, leftHandThumb3, leftHandThumb4
    case leftHandIndex1, leftHandIndex2, leftHandIndex3, leftHandIndex4
    case leftHandMiddle1, leftHandMiddle2, leftHandMiddle3, leftHandMiddle4
    case leftHandRing1, leftHandRing2, leftHandRing3, leftHandRing4
    case leftHandPinky1, leftHandPinky2, leftHandPinky3, leftHandPinky4

    case rightHandThumb1, rightHandThumb2, rightHandThumb3, rightHandThumb4
    case rightHandIndex1, rightHandIndex2, rightHandIndex3, rightHandIndex4
    case rightHandMiddle1, rightHandMiddle2, rightHandMiddle3, rightHandMiddle4
    case rightHandRing1, rightHandRing2, rightHandRing3, rightHandRing4
    case rightHandPinky1, rightHandPinky2, rightHandPinky3, rightHandPinky4
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

/// Source of ARKit face tracking data
public final class ARFaceSource: ARMetadataSource, @unchecked Sendable {
    public let sourceID: UUID
    public let name: String
    public private(set) var lastUpdate: TimeInterval
    public var metadata: [String: String]

    /// Maximum age before source is considered stale (default: 150ms)
    public var maxAge: TimeInterval = 0.150

    public var isActive: Bool {
        let now = Date().timeIntervalSinceReferenceDate
        return now - lastUpdate < maxAge
    }

    /// Latest blend shapes (thread-safe access)
    private var _blendShapes: ARKitFaceBlendShapes?
    private let lock = NSLock()

    public var blendShapes: ARKitFaceBlendShapes? {
        lock.lock()
        defer { lock.unlock() }
        return _blendShapes
    }

    public init(sourceID: UUID = UUID(), name: String, metadata: [String: String] = [:]) {
        self.sourceID = sourceID
        self.name = name
        self.lastUpdate = 0
        self.metadata = metadata
    }

    /// Update with new blend shape data
    public func update(blendShapes: ARKitFaceBlendShapes) {
        lock.lock()
        defer { lock.unlock() }
        _blendShapes = blendShapes
        lastUpdate = blendShapes.timestamp
    }
}

// MARK: - Body Source

/// Source of ARKit body tracking data
public final class ARBodySource: ARMetadataSource, @unchecked Sendable {
    public let sourceID: UUID
    public let name: String
    public private(set) var lastUpdate: TimeInterval
    public var metadata: [String: String]

    public var maxAge: TimeInterval = 0.150

    public var isActive: Bool {
        let now = Date().timeIntervalSinceReferenceDate
        return now - lastUpdate < maxAge
    }

    private var _skeleton: ARKitBodySkeleton?
    private let lock = NSLock()

    public var skeleton: ARKitBodySkeleton? {
        lock.lock()
        defer { lock.unlock() }
        return _skeleton
    }

    public init(sourceID: UUID = UUID(), name: String, metadata: [String: String] = [:]) {
        self.sourceID = sourceID
        self.name = name
        self.lastUpdate = 0
        self.metadata = metadata
    }

    public func update(skeleton: ARKitBodySkeleton) {
        lock.lock()
        defer { lock.unlock() }
        _skeleton = skeleton
        lastUpdate = skeleton.timestamp
    }
}

// MARK: - Combined Source

/// Source providing both face and body tracking
public final class ARCombinedSource: ARMetadataSource, @unchecked Sendable {
    public let sourceID: UUID
    public let name: String
    public private(set) var lastUpdate: TimeInterval
    public var metadata: [String: String]

    public var maxAge: TimeInterval = 0.150

    public var isActive: Bool {
        let now = Date().timeIntervalSinceReferenceDate
        return now - lastUpdate < maxAge
    }

    private var _blendShapes: ARKitFaceBlendShapes?
    private var _skeleton: ARKitBodySkeleton?
    private let lock = NSLock()

    public var blendShapes: ARKitFaceBlendShapes? {
        lock.lock()
        defer { lock.unlock() }
        return _blendShapes
    }

    public var skeleton: ARKitBodySkeleton? {
        lock.lock()
        defer { lock.unlock() }
        return _skeleton
    }

    public init(sourceID: UUID = UUID(), name: String, metadata: [String: String] = [:]) {
        self.sourceID = sourceID
        self.name = name
        self.lastUpdate = 0
        self.metadata = metadata
    }

    public func update(blendShapes: ARKitFaceBlendShapes) {
        lock.lock()
        defer { lock.unlock() }
        _blendShapes = blendShapes
        lastUpdate = max(lastUpdate, blendShapes.timestamp)
    }

    public func update(skeleton: ARKitBodySkeleton) {
        lock.lock()
        defer { lock.unlock() }
        _skeleton = skeleton
        lastUpdate = max(lastUpdate, skeleton.timestamp)
    }
}
