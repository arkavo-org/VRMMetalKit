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
import VRMMetalKit

/// Examples of custom expression and skeleton mapping configurations
///
/// This file demonstrates how to customize the mapping between ARKit blend shapes
/// and VRM expressions, as well as ARKit skeleton joints and VRM humanoid bones.
///
/// Use cases:
/// - Subtle expressions for realistic avatars
/// - Exaggerated expressions for cartoon characters
/// - Custom expressions not in the default mapping
/// - Partial skeleton mapping for desk scenarios
/// - Adding finger tracking to hand bones
class CustomMappingExamples {

    // MARK: - Expression Mapping Examples

    /// Create a mapper with subtle expressions (50% strength)
    ///
    /// Use case: Realistic avatar that shouldn't over-emote
    static func createSubtleMapper() -> ARKitToVRMMapper {
        var mapper = ARKitToVRMMapper.default

        // Reduce strength of all weighted expressions by 50%
        for (expression, formula) in mapper.mappings {
            if case .weighted(let components) = formula {
                let adjusted = components.map { (key, weight) in
                    (key, weight * 0.5)
                }
                mapper.mappings[expression] = .weighted(adjusted)
            }
        }

        print("Created subtle mapper (50% expression strength)")
        return mapper
    }

    /// Create a mapper with exaggerated expressions (150% strength)
    ///
    /// Use case: Cartoon or anime-style avatar with big reactions
    static func createExaggeratedMapper() -> ARKitToVRMMapper {
        var mapper = ARKitToVRMMapper.default

        // Amplify all weighted expressions by 150%
        for (expression, formula) in mapper.mappings {
            if case .weighted(let components) = formula {
                let adjusted = components.map { (key, weight) in
                    (key, min(weight * 1.5, 1.0))  // Clamp to 1.0
                }
                mapper.mappings[expression] = .weighted(adjusted)
            }
        }

        print("Created exaggerated mapper (150% expression strength)")
        return mapper
    }

    /// Create a mapper with custom wink expression
    ///
    /// The default mapper doesn't have a dedicated wink, but we can add one
    static func createMapperWithWink() -> ARKitToVRMMapper {
        var mapper = ARKitToVRMMapper.default

        // Add custom wink expression: one eye closed, other open
        mapper.mappings["wink"] = .custom { shapes in
            let leftBlink = shapes.weight(for: ARKitFaceBlendShapes.eyeBlinkLeft)
            let rightBlink = shapes.weight(for: ARKitFaceBlendShapes.eyeBlinkRight)

            // Wink = asymmetric blink
            // High when one eye is closed and the other is open
            return max(
                leftBlink * (1 - rightBlink),
                rightBlink * (1 - leftBlink)
            )
        }

        print("Created mapper with custom wink expression")
        return mapper
    }

    /// Create a mapper optimized for speech/lip sync
    ///
    /// Focuses on mouth visemes with reduced other expressions
    static func createSpeechMapper() -> ARKitToVRMMapper {
        var mapper = ARKitToVRMMapper.default

        // Amplify visemes (aa, ih, ou, ee, oh) for clearer speech
        let visemes = ["aa", "ih", "ou", "ee", "oh"]
        for viseme in visemes {
            if let formula = mapper.mappings[viseme],
               case .weighted(let components) = formula {
                let amplified = components.map { (key, weight) in
                    (key, min(weight * 1.3, 1.0))
                }
                mapper.mappings[viseme] = .weighted(amplified)
            }
        }

        // Reduce emotional expressions to 30% during speech
        let emotions = ["happy", "angry", "sad", "surprised"]
        for emotion in emotions {
            if let formula = mapper.mappings[emotion],
               case .weighted(let components) = formula {
                let reduced = components.map { (key, weight) in
                    (key, weight * 0.3)
                }
                mapper.mappings[emotion] = .weighted(reduced)
            }
        }

        print("Created speech-optimized mapper (amplified visemes, reduced emotions)")
        return mapper
    }

    /// Create a minimal mapper with only essential expressions
    ///
    /// Use case: Performance optimization or simple avatar
    static func createMinimalMapper() -> ARKitToVRMMapper {
        // Start fresh instead of modifying default
        ARKitToVRMMapper(mappings: [
            // Eyes
            "blink": .average([
                ARKitFaceBlendShapes.eyeBlinkLeft,
                ARKitFaceBlendShapes.eyeBlinkRight
            ]),

            // Mouth
            "aa": .direct(ARKitFaceBlendShapes.jawOpen),

            // Basic emotions
            "happy": .weighted([
                (ARKitFaceBlendShapes.mouthSmileLeft, Float(0.5)),
                (ARKitFaceBlendShapes.mouthSmileRight, Float(0.5))
            ]),

            // Neutral (important for VRM)
            "neutral": .custom { shapes in
                let allWeights = ARKitFaceBlendShapes.allKeys.map { shapes.weight(for: $0) }
                let totalActivation = allWeights.reduce(0, +) / Float(allWeights.count)
                return 1.0 - totalActivation
            }
        ])
    }

    // MARK: - Skeleton Mapping Examples

    /// Create a skeleton mapper for desk/seated scenario (upper body + fingers)
    static func createDeskMapper() -> ARKitSkeletonMapper {
        var mapper = ARKitSkeletonMapper.upperBodyOnly

        // Add finger tracking for hand gestures
        // Left hand
        mapper.jointMap[.leftHandThumb1] = "leftThumbProximal"
        mapper.jointMap[.leftHandThumb2] = "leftThumbIntermediate"
        mapper.jointMap[.leftHandThumb3] = "leftThumbDistal"

        mapper.jointMap[.leftHandIndex1] = "leftIndexProximal"
        mapper.jointMap[.leftHandIndex2] = "leftIndexIntermediate"
        mapper.jointMap[.leftHandIndex3] = "leftIndexDistal"

        mapper.jointMap[.leftHandMiddle1] = "leftMiddleProximal"
        mapper.jointMap[.leftHandMiddle2] = "leftMiddleIntermediate"
        mapper.jointMap[.leftHandMiddle3] = "leftMiddleDistal"

        mapper.jointMap[.leftHandRing1] = "leftRingProximal"
        mapper.jointMap[.leftHandRing2] = "leftRingIntermediate"
        mapper.jointMap[.leftHandRing3] = "leftRingDistal"

        mapper.jointMap[.leftHandLittle1] = "leftLittleProximal"
        mapper.jointMap[.leftHandLittle2] = "leftLittleIntermediate"
        mapper.jointMap[.leftHandLittle3] = "leftLittleDistal"

        // Right hand (mirror of left)
        mapper.jointMap[.rightHandThumb1] = "rightThumbProximal"
        mapper.jointMap[.rightHandThumb2] = "rightThumbIntermediate"
        mapper.jointMap[.rightHandThumb3] = "rightThumbDistal"

        mapper.jointMap[.rightHandIndex1] = "rightIndexProximal"
        mapper.jointMap[.rightHandIndex2] = "rightIndexIntermediate"
        mapper.jointMap[.rightHandIndex3] = "rightIndexDistal"

        mapper.jointMap[.rightHandMiddle1] = "rightMiddleProximal"
        mapper.jointMap[.rightHandMiddle2] = "rightMiddleIntermediate"
        mapper.jointMap[.rightHandMiddle3] = "rightMiddleDistal"

        mapper.jointMap[.rightHandRing1] = "rightRingProximal"
        mapper.jointMap[.rightHandRing2] = "rightRingIntermediate"
        mapper.jointMap[.rightHandRing3] = "rightRingDistal"

        mapper.jointMap[.rightHandLittle1] = "rightLittleProximal"
        mapper.jointMap[.rightHandLittle2] = "rightLittleIntermediate"
        mapper.jointMap[.rightHandLittle3] = "rightLittleDistal"

        print("Created desk mapper (upper body + fingers, \(mapper.jointMap.count) joints)")
        return mapper
    }

    /// Create a minimal skeleton mapper (core + head only)
    ///
    /// Use case: VTuber-style (head tracking only) or performance optimization
    static func createHeadOnlyMapper() -> ARKitSkeletonMapper {
        ARKitSkeletonMapper(jointMap: [
            .hips: "hips",
            .spine: "spine",
            .chest: "chest",
            .neck: "neck",
            .head: "head"
        ])
    }

    // MARK: - Smoothing Configuration Examples

    /// Create smoothing config optimized for live performance
    ///
    /// Low latency, instant blinks, smooth mouth movements
    static func createPerformanceSmoothingConfig() -> SmoothingConfig {
        var config = SmoothingConfig.lowLatency  // Base: EMA alpha=0.5 (responsive)

        // No smoothing for blinks (instant reaction)
        config.perExpression["blink"] = .none
        config.perExpression["blinkLeft"] = .none
        config.perExpression["blinkRight"] = .none

        // Minimal smoothing for eyebrows (expressive)
        config.perExpression["surprised"] = .ema(alpha: 0.7)

        // Moderate smoothing for mouth (reduce speech jitter but stay responsive)
        config.perExpression["aa"] = .ema(alpha: 0.4)
        config.perExpression["ih"] = .ema(alpha: 0.4)
        config.perExpression["ou"] = .ema(alpha: 0.4)
        config.perExpression["ee"] = .ema(alpha: 0.4)
        config.perExpression["oh"] = .ema(alpha: 0.4)

        return config
    }

    /// Create smoothing config optimized for video recording
    ///
    /// Smooth, stable motion without jitter
    static func createRecordingSmoothingConfig() -> SmoothingConfig {
        var config = SmoothingConfig.smooth  // Base: EMA alpha=0.2 (heavy smoothing)

        // Still instant blinks (looks better on camera)
        config.perExpression["blink"] = .none
        config.perExpression["blinkLeft"] = .none
        config.perExpression["blinkRight"] = .none

        // Use Kalman filter for mouth (best quality, slightly slower)
        config.perExpression["aa"] = .kalman(processNoise: 0.01, measurementNoise: 0.1)
        config.perExpression["ih"] = .kalman(processNoise: 0.01, measurementNoise: 0.1)
        config.perExpression["ou"] = .kalman(processNoise: 0.01, measurementNoise: 0.1)
        config.perExpression["ee"] = .kalman(processNoise: 0.01, measurementNoise: 0.1)
        config.perExpression["oh"] = .kalman(processNoise: 0.01, measurementNoise: 0.1)

        return config
    }

    /// Create skeleton smoothing optimized for full-body performance capture
    static func createPerformanceSkeletonSmoothing() -> SkeletonSmoothingConfig {
        SkeletonSmoothingConfig(
            positionFilter: .ema(alpha: 0.5),  // Responsive position
            rotationFilter: .ema(alpha: 0.4),  // Slightly smoother rotation (SLERP'd)
            scaleFilter: .none  // No scale filtering (usually not needed)
        )
    }

    /// Create skeleton smoothing optimized for desk/VTuber scenario
    static func createDeskSkeletonSmoothing() -> SkeletonSmoothingConfig {
        SkeletonSmoothingConfig(
            positionFilter: .ema(alpha: 0.3),  // Smooth position (less movement in desk scenario)
            rotationFilter: .kalman(processNoise: 0.01, measurementNoise: 0.1),  // Very smooth rotation
            scaleFilter: .none
        )
    }

    // MARK: - Complete Integration Examples

    /// Create a driver configuration for realistic VTuber
    static func createVTuberDriver() -> ARKitFaceDriver {
        let mapper = createSubtleMapper()  // 50% expression strength
        let smoothing = createRecordingSmoothingConfig()  // Smooth for streaming

        return ARKitFaceDriver(
            mapper: mapper,
            smoothing: smoothing
        )
    }

    /// Create a driver configuration for cartoon character
    static func createCartoonDriver() -> ARKitFaceDriver {
        let mapper = createExaggeratedMapper()  // 150% expression strength
        let smoothing = createPerformanceSmoothingConfig()  // Responsive

        return ARKitFaceDriver(
            mapper: mapper,
            smoothing: smoothing
        )
    }

    /// Create a driver configuration for desk worker with hand gestures
    static func createDeskWorkerDriver() -> ARKitBodyDriver {
        let mapper = createDeskMapper()  // Upper body + fingers
        let smoothing = createDeskSkeletonSmoothing()  // Smooth for seated

        return ARKitBodyDriver(
            mapper: mapper,
            smoothing: smoothing,
            priority: .latestActive
        )
    }

    /// Create a driver configuration for full-body performance capture
    static func createPerformanceCaptureDriver() -> ARKitBodyDriver {
        let mapper = ARKitSkeletonMapper.default  // Full skeleton
        let smoothing = createPerformanceSkeletonSmoothing()  // Responsive

        return ARKitBodyDriver(
            mapper: mapper,
            smoothing: smoothing,
            priority: .highestConfidence  // Use best tracking source
        )
    }
}

// MARK: - Usage Examples

/*
 Usage examples for the above configurations:

 // VTuber setup (face only, subtle expressions, smooth)
 let faceDriver = CustomMappingExamples.createVTuberDriver()

 // Cartoon character (exaggerated, responsive)
 let faceDriver = CustomMappingExamples.createCartoonDriver()

 // Desk worker (upper body + hands)
 let bodyDriver = CustomMappingExamples.createDeskWorkerDriver()

 // Performance capture (full body, multi-camera)
 let bodyDriver = CustomMappingExamples.createPerformanceCaptureDriver()

 // Custom combination
 let customMapper = CustomMappingExamples.createMapperWithWink()
 let customSmoothing = CustomMappingExamples.createPerformanceSmoothingConfig()
 let faceDriver = ARKitFaceDriver(
     mapper: customMapper,
     smoothing: customSmoothing
 )
 */
