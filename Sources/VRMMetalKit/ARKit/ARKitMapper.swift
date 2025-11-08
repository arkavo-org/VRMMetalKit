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

// MARK: - Blend Shape Formula

/// Formula for computing VRM expression weight from ARKit blend shapes
///
/// Defines how one or more ARKit blend shapes map to a single VRM expression.
/// Formulas are data-driven and can be serialized for external configuration.
///
/// ## Examples
///
/// ```swift
/// // Direct 1:1 mapping
/// .direct(ARKitFaceBlendShapes.eyeBlinkLeft)
///
/// // Average of multiple shapes
/// .average([ARKitFaceBlendShapes.eyeBlinkLeft, ARKitFaceBlendShapes.eyeBlinkRight])
///
/// // Weighted combination
/// .weighted([
///     (ARKitFaceBlendShapes.jawOpen, 0.7),
///     (ARKitFaceBlendShapes.mouthFunnel, 0.3)
/// ])
///
/// // Custom function
/// .custom { shapes in
///     let left = shapes.weight(for: ARKitFaceBlendShapes.eyeBlinkLeft)
///     let right = shapes.weight(for: ARKitFaceBlendShapes.eyeBlinkRight)
///     return max(left, right)  // Use stronger blink
/// }
/// ```
public enum BlendShapeFormula: Sendable {
    /// Direct 1:1 mapping from single ARKit blend shape
    case direct(String)

    /// Average of multiple ARKit blend shapes
    case average([String])

    /// Maximum value among multiple shapes
    case max([String])

    /// Minimum value among multiple shapes
    case min([String])

    /// Weighted sum of blend shapes
    /// Format: [(blendShapeKey, weight), ...]
    case weighted([(String, Float)])

    /// Custom evaluation function
    /// Note: Cannot be serialized
    case custom(@Sendable (ARKitFaceBlendShapes) -> Float)

    /// Evaluate formula against blend shape data
    public func evaluate(_ blendShapes: ARKitFaceBlendShapes) -> Float {
        switch self {
        case .direct(let key):
            return blendShapes.weight(for: key)

        case .average(let keys):
            guard !keys.isEmpty else { return 0 }
            let sum = keys.reduce(0.0) { $0 + blendShapes.weight(for: $1) }
            return sum / Float(keys.count)

        case .max(let keys):
            return keys.map { blendShapes.weight(for: $0) }.max() ?? 0

        case .min(let keys):
            return keys.map { blendShapes.weight(for: $0) }.min() ?? 0

        case .weighted(let components):
            return components.reduce(0.0) { sum, component in
                let (key, weight) = component
                return sum + blendShapes.weight(for: key) * weight
            }

        case .custom(let evaluate):
            return evaluate(blendShapes)
        }
    }

    /// Clamp result to [0, 1] range
    func evaluateClamped(_ blendShapes: ARKitFaceBlendShapes) -> Float {
        let value = evaluate(blendShapes)
        return Swift.min(1.0, Swift.max(0.0, value))
    }
}

// MARK: - ARKit to VRM Mapper

/// Maps ARKit face blend shapes to VRM expression presets
///
/// Provides configurable mappings between ARKit's 52 blend shapes and VRM's
/// 18 expression presets. Mappings can be customized or loaded from external data.
///
/// ## Thread Safety
/// **Thread-safe for reading** after initialization. Create separate instances
/// for concurrent modification or protect with locks.
///
/// ## Usage
///
/// ```swift
/// // Use default mappings
/// let mapper = ARKitToVRMMapper.default
///
/// // Evaluate expressions
/// let blendShapes = ARKitFaceBlendShapes(...)
/// let weights = mapper.evaluate(blendShapes)
///
/// // weights[.blink] contains computed blink weight
/// // weights[.happy] contains computed happy weight
/// // etc.
///
/// // Custom mapping
/// var mapper = ARKitToVRMMapper.default
/// mapper.mappings[.happy] = .weighted([
///     (ARKitFaceBlendShapes.mouthSmileLeft, 0.5),
///     (ARKitFaceBlendShapes.mouthSmileRight, 0.5),
///     (ARKitFaceBlendShapes.cheekSquintLeft, 0.2),
///     (ARKitFaceBlendShapes.cheekSquintRight, 0.2)
/// ])
/// ```
public struct ARKitToVRMMapper: Sendable {
    /// Mapping from VRM expression preset to blend shape formula
    public var mappings: [String: BlendShapeFormula]

    public init(mappings: [String: BlendShapeFormula] = [:]) {
        self.mappings = mappings
    }

    /// Evaluate all mapped expressions from ARKit blend shapes
    /// Returns dictionary of VRM expression keys to weights [0-1]
    public func evaluate(_ blendShapes: ARKitFaceBlendShapes) -> [String: Float] {
        var result: [String: Float] = [:]
        for (vrmExpression, formula) in mappings {
            result[vrmExpression] = formula.evaluateClamped(blendShapes)
        }
        return result
    }

    /// Evaluate single expression
    public func evaluate(_ blendShapes: ARKitFaceBlendShapes, expression: String) -> Float {
        guard let formula = mappings[expression] else { return 0 }
        return formula.evaluateClamped(blendShapes)
    }

    // MARK: - Default Mappings

    /// Default ARKit → VRM expression mappings
    ///
    /// Carefully tuned to provide good results for most VRM avatars.
    /// Based on VRM specification and common usage patterns.
    public static let `default` = ARKitToVRMMapper(mappings: [
        // Emotions
        "happy": .weighted([
            (ARKitFaceBlendShapes.mouthSmileLeft, Float(0.4)),
            (ARKitFaceBlendShapes.mouthSmileRight, Float(0.4)),
            (ARKitFaceBlendShapes.cheekSquintLeft, Float(0.1)),
            (ARKitFaceBlendShapes.cheekSquintRight, Float(0.1))
        ]),

        "angry": .weighted([
            (ARKitFaceBlendShapes.browDownLeft, Float(0.3)),
            (ARKitFaceBlendShapes.browDownRight, Float(0.3)),
            (ARKitFaceBlendShapes.mouthFrownLeft, Float(0.2)),
            (ARKitFaceBlendShapes.mouthFrownRight, Float(0.2))
        ]),

        "sad": .weighted([
            (ARKitFaceBlendShapes.browInnerUp, Float(0.4)),
            (ARKitFaceBlendShapes.mouthFrownLeft, Float(0.3)),
            (ARKitFaceBlendShapes.mouthFrownRight, Float(0.3))
        ]),

        "relaxed": .custom { shapes in
            // Relaxed = neutral with slight smile
            let smile = (shapes.weight(for: ARKitFaceBlendShapes.mouthSmileLeft) +
                        shapes.weight(for: ARKitFaceBlendShapes.mouthSmileRight)) * 0.3
            let open = shapes.weight(for: ARKitFaceBlendShapes.jawOpen)
            return Swift.min(1.0, smile * (1.0 - open))
        },

        "surprised": .weighted([
            (ARKitFaceBlendShapes.browInnerUp, Float(0.3)),
            (ARKitFaceBlendShapes.browOuterUpLeft, Float(0.15)),
            (ARKitFaceBlendShapes.browOuterUpRight, Float(0.15)),
            (ARKitFaceBlendShapes.eyeWideLeft, Float(0.2)),
            (ARKitFaceBlendShapes.eyeWideRight, Float(0.2))
        ]),

        // Visemes (vowel shapes)
        "aa": .weighted([
            (ARKitFaceBlendShapes.jawOpen, Float(0.8)),
            (ARKitFaceBlendShapes.mouthFunnel, Float(0.2))
        ]),

        "ih": .weighted([
            (ARKitFaceBlendShapes.jawOpen, Float(0.3)),
            (ARKitFaceBlendShapes.mouthSmileLeft, Float(0.35)),
            (ARKitFaceBlendShapes.mouthSmileRight, Float(0.35))
        ]),

        "ou": .weighted([
            (ARKitFaceBlendShapes.mouthFunnel, Float(0.5)),
            (ARKitFaceBlendShapes.mouthPucker, Float(0.5))
        ]),

        "ee": .weighted([
            (ARKitFaceBlendShapes.mouthSmileLeft, Float(0.5)),
            (ARKitFaceBlendShapes.mouthSmileRight, Float(0.5))
        ]),

        "oh": .weighted([
            (ARKitFaceBlendShapes.jawOpen, Float(0.5)),
            (ARKitFaceBlendShapes.mouthFunnel, Float(0.5))
        ]),

        // Blink
        "blink": .average([
            ARKitFaceBlendShapes.eyeBlinkLeft,
            ARKitFaceBlendShapes.eyeBlinkRight
        ]),

        "blinkLeft": .direct(ARKitFaceBlendShapes.eyeBlinkLeft),

        "blinkRight": .direct(ARKitFaceBlendShapes.eyeBlinkRight),

        // Eye gaze
        "lookUp": .average([
            ARKitFaceBlendShapes.eyeLookUpLeft,
            ARKitFaceBlendShapes.eyeLookUpRight
        ]),

        "lookDown": .average([
            ARKitFaceBlendShapes.eyeLookDownLeft,
            ARKitFaceBlendShapes.eyeLookDownRight
        ]),

        "lookLeft": .weighted([
            (ARKitFaceBlendShapes.eyeLookInLeft, Float(0.5)),
            (ARKitFaceBlendShapes.eyeLookOutRight, Float(0.5))
        ]),

        "lookRight": .weighted([
            (ARKitFaceBlendShapes.eyeLookOutLeft, Float(0.5)),
            (ARKitFaceBlendShapes.eyeLookInRight, Float(0.5))
        ]),

        // Neutral (default expression)
        "neutral": .custom { shapes in
            // Neutral = no strong expressions active
            let allWeights = ARKitFaceBlendShapes.allKeys.map { shapes.weight(for: $0) }
            let totalActivation = allWeights.reduce(0, +) / Float(allWeights.count)
            return Swift.max(0, 1.0 - totalActivation * 3.0)
        }
    ])

    /// Simplified mappings (fewer dependencies, faster evaluation)
    public static let simplified = ARKitToVRMMapper(mappings: [
        "happy": .average([ARKitFaceBlendShapes.mouthSmileLeft, ARKitFaceBlendShapes.mouthSmileRight]),
        "angry": .average([ARKitFaceBlendShapes.browDownLeft, ARKitFaceBlendShapes.browDownRight]),
        "sad": .direct(ARKitFaceBlendShapes.browInnerUp),
        "surprised": .average([ARKitFaceBlendShapes.eyeWideLeft, ARKitFaceBlendShapes.eyeWideRight]),
        "aa": .direct(ARKitFaceBlendShapes.jawOpen),
        "ou": .direct(ARKitFaceBlendShapes.mouthFunnel),
        "blink": .average([ARKitFaceBlendShapes.eyeBlinkLeft, ARKitFaceBlendShapes.eyeBlinkRight]),
        "blinkLeft": .direct(ARKitFaceBlendShapes.eyeBlinkLeft),
        "blinkRight": .direct(ARKitFaceBlendShapes.eyeBlinkRight),
        "lookUp": .average([ARKitFaceBlendShapes.eyeLookUpLeft, ARKitFaceBlendShapes.eyeLookUpRight]),
        "lookDown": .average([ARKitFaceBlendShapes.eyeLookDownLeft, ARKitFaceBlendShapes.eyeLookDownRight])
    ])

    /// Aggressive mappings (stronger expression response)
    public static let aggressive = ARKitToVRMMapper(mappings: [
        "happy": .custom { shapes in
            let smile = (shapes.weight(for: ARKitFaceBlendShapes.mouthSmileLeft) +
                        shapes.weight(for: ARKitFaceBlendShapes.mouthSmileRight)) * 0.75
            return Swift.min(1.0, smile * 1.5)  // Amplify
        },
        "angry": .custom { shapes in
            let brow = (shapes.weight(for: ARKitFaceBlendShapes.browDownLeft) +
                       shapes.weight(for: ARKitFaceBlendShapes.browDownRight)) * 0.75
            return Swift.min(1.0, brow * 1.5)
        },
        "blink": .average([ARKitFaceBlendShapes.eyeBlinkLeft, ARKitFaceBlendShapes.eyeBlinkRight]),
        "blinkLeft": .direct(ARKitFaceBlendShapes.eyeBlinkLeft),
        "blinkRight": .direct(ARKitFaceBlendShapes.eyeBlinkRight)
    ])
}

// MARK: - Skeleton Mapper

/// Maps ARKit skeleton joints to VRM humanoid bones
///
/// Provides retargeting from ARKit's body tracking skeleton to VRM's humanoid rig.
/// Handles differences in joint hierarchies and coordinate systems.
public struct ARKitSkeletonMapper: Sendable {
    /// Mapping from ARKit joint to VRM humanoid bone
    public var jointMap: [ARKitJoint: String]

    public init(jointMap: [ARKitJoint: String] = [:]) {
        self.jointMap = jointMap
    }

    /// Get VRM bone name for ARKit joint
    public func vrmBone(for joint: ARKitJoint) -> String? {
        return jointMap[joint]
    }

    /// Check if joint is mapped
    public func isMapped(_ joint: ARKitJoint) -> Bool {
        return jointMap[joint] != nil
    }

    // MARK: - Default Mapping

    /// Default ARKit → VRM humanoid bone mapping
    ///
    /// Maps ARKit's skeleton to VRM's humanoid bones using standard naming.
    /// Some ARKit joints may not have direct VRM equivalents and are omitted.
    public static let `default` = ARKitSkeletonMapper(jointMap: [
        // Torso
        .hips: "hips",
        .spine: "spine",
        .chest: "chest",
        .upperChest: "upperChest",
        .neck: "neck",
        .head: "head",

        // Left arm
        .leftShoulder: "leftShoulder",
        .leftUpperArm: "leftUpperArm",
        .leftLowerArm: "leftLowerArm",
        .leftHand: "leftHand",

        // Right arm
        .rightShoulder: "rightShoulder",
        .rightUpperArm: "rightUpperArm",
        .rightLowerArm: "rightLowerArm",
        .rightHand: "rightHand",

        // Left leg
        .leftUpperLeg: "leftUpperLeg",
        .leftLowerLeg: "leftLowerLeg",
        .leftFoot: "leftFoot",
        .leftToes: "leftToes",

        // Right leg
        .rightUpperLeg: "rightUpperLeg",
        .rightLowerLeg: "rightLowerLeg",
        .rightFoot: "rightFoot",
        .rightToes: "rightToes",

        // Fingers - left hand
        .leftHandThumb1: "leftThumbProximal",
        .leftHandThumb2: "leftThumbIntermediate",
        .leftHandThumb3: "leftThumbDistal",

        .leftHandIndex1: "leftIndexProximal",
        .leftHandIndex2: "leftIndexIntermediate",
        .leftHandIndex3: "leftIndexDistal",

        .leftHandMiddle1: "leftMiddleProximal",
        .leftHandMiddle2: "leftMiddleIntermediate",
        .leftHandMiddle3: "leftMiddleDistal",

        .leftHandRing1: "leftRingProximal",
        .leftHandRing2: "leftRingIntermediate",
        .leftHandRing3: "leftRingDistal",

        .leftHandPinky1: "leftLittleProximal",
        .leftHandPinky2: "leftLittleIntermediate",
        .leftHandPinky3: "leftLittleDistal",

        // Fingers - right hand
        .rightHandThumb1: "rightThumbProximal",
        .rightHandThumb2: "rightThumbIntermediate",
        .rightHandThumb3: "rightThumbDistal",

        .rightHandIndex1: "rightIndexProximal",
        .rightHandIndex2: "rightIndexIntermediate",
        .rightHandIndex3: "rightIndexDistal",

        .rightHandMiddle1: "rightMiddleProximal",
        .rightHandMiddle2: "rightMiddleIntermediate",
        .rightHandMiddle3: "rightMiddleDistal",

        .rightHandRing1: "rightRingProximal",
        .rightHandRing2: "rightRingIntermediate",
        .rightHandRing3: "rightRingDistal",

        .rightHandPinky1: "rightLittleProximal",
        .rightHandPinky2: "rightLittleIntermediate",
        .rightHandPinky3: "rightLittleDistal"
    ])

    /// Upper body only mapping (for desk/seated scenarios)
    public static let upperBodyOnly = ARKitSkeletonMapper(jointMap: [
        .hips: "hips",
        .spine: "spine",
        .chest: "chest",
        .upperChest: "upperChest",
        .neck: "neck",
        .head: "head",
        .leftShoulder: "leftShoulder",
        .leftUpperArm: "leftUpperArm",
        .leftLowerArm: "leftLowerArm",
        .leftHand: "leftHand",
        .rightShoulder: "rightShoulder",
        .rightUpperArm: "rightUpperArm",
        .rightLowerArm: "rightLowerArm",
        .rightHand: "rightHand"
    ])

    /// Core bones only (minimal tracking)
    public static let coreOnly = ARKitSkeletonMapper(jointMap: [
        .hips: "hips",
        .spine: "spine",
        .chest: "chest",
        .neck: "neck",
        .head: "head",
        .leftUpperArm: "leftUpperArm",
        .leftLowerArm: "leftLowerArm",
        .leftHand: "leftHand",
        .rightUpperArm: "rightUpperArm",
        .rightLowerArm: "rightLowerArm",
        .rightHand: "rightHand",
        .leftUpperLeg: "leftUpperLeg",
        .leftLowerLeg: "leftLowerLeg",
        .leftFoot: "leftFoot",
        .rightUpperLeg: "rightUpperLeg",
        .rightLowerLeg: "rightLowerLeg",
        .rightFoot: "rightFoot"
    ])
}
