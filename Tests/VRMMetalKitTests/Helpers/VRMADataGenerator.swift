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

/// Interpolation types for VRMA generation
public enum InterpolationType: String {
    case linear = "LINEAR"
    case step = "STEP"
    case cubicSpline = "CUBICSPLINE"
}

/// Test Data Generator for VRMA files
///
/// Generates minimal VRMA (.vrma) files for testing purposes.
/// These files use the glTF binary format with VRMC_vrm_animation extension.
enum VRMADataGenerator {
    
    /// Generates a minimal VRMA file with the specified configuration
    static func generateVRMA(
        outputPath: String,
        boneAnimations: [BoneAnimation],
        expressionAnimations: [ExpressionAnimation] = [],
        duration: Float = 1.0,
        interpolation: InterpolationType = .linear
    ) throws {
        let generator = VRMAGenerator(
            duration: duration,
            interpolation: interpolation
        )
        
        // Add bone animations
        for anim in boneAnimations {
            generator.addBoneAnimation(anim)
        }
        
        // Add expression animations
        for expr in expressionAnimations {
            generator.addExpressionAnimation(expr)
        }
        
        // Write to file
        let data = try generator.build()
        try data.write(to: URL(fileURLWithPath: outputPath))
    }
    
    /// Generate a simple walking animation
    static func generateWalkingAnimation(outputPath: String) throws {
        let hipsAnim = BoneAnimation(
            boneName: "hips",
            nodeIndex: 0,
            rotation: nil,
            translation: KeyframeTrack(
                times: [0.0, 0.5, 1.0],
                values: [
                    [0, 0, 0],
                    [0, 0, 0.5],
                    [0, 0, 1.0]
                ]
            ),
            scale: nil
        )
        
        let leftLegAnim = BoneAnimation(
            boneName: "leftUpperLeg",
            nodeIndex: 1,
            rotation: KeyframeTrack(
                times: [0.0, 0.25, 0.5, 0.75, 1.0],
                values: [
                    [0, 0, 0, 1],
                    [0, 0.259, 0, 0.966],  // 30°
                    [0, 0, 0, 1],
                    [0, -0.259, 0, 0.966], // -30°
                    [0, 0, 0, 1]
                ]
            ),
            translation: nil,
            scale: nil
        )
        
        try generateVRMA(
            outputPath: outputPath,
            boneAnimations: [hipsAnim, leftLegAnim],
            duration: 1.0
        )
    }
    
    /// Generate an animation with expressions
    static func generateExpressionAnimation(outputPath: String) throws {
        let happyExpr = ExpressionAnimation(
            name: "happy",
            nodeIndex: 10,
            keyframes: KeyframeTrack(
                times: [0.0, 0.5, 1.0],
                values: [[0], [1], [0]]  // Weight values
            )
        )
        
        let blinkExpr = ExpressionAnimation(
            name: "blink",
            nodeIndex: 11,
            keyframes: KeyframeTrack(
                times: [0.0, 0.1, 0.2],
                values: [[0], [1], [0]]  // Quick blink
            )
        )
        
        try generateVRMA(
            outputPath: outputPath,
            boneAnimations: [],
            expressionAnimations: [happyExpr, blinkExpr],
            duration: 1.0
        )
    }
    
    /// Generate scale animation
    static func generateScaleAnimation(outputPath: String) throws {
        let chestAnim = BoneAnimation(
            boneName: "chest",
            nodeIndex: 2,
            rotation: nil,
            translation: nil,
            scale: KeyframeTrack(
                times: [0.0, 0.5, 1.0],
                values: [
                    [1, 1, 1],
                    [1.1, 1.1, 1.1],
                    [1, 1, 1]
                ]
            )
        )
        
        try generateVRMA(
            outputPath: outputPath,
            boneAnimations: [chestAnim],
            duration: 1.0
        )
    }
    
    /// Generate CUBICSPLINE interpolation test
    static func generateCubicSplineAnimation(outputPath: String) throws {
        let anim = BoneAnimation(
            boneName: "head",
            nodeIndex: 5,
            rotation: KeyframeTrack(
                times: [0.0, 1.0],
                values: [
                    [0, 0, 0, 1],
                    [0, 0.707, 0, 0.707]  // 90°
                ],
                tangents: [
                    // inTangent, value, outTangent for each keyframe
                    [0, 0, 0, 0, 0, 0, 0, 1, 0, 0.5, 0, 1],  // keyframe 0
                    [0, 0.5, 0, 1, 0, 0.707, 0, 0.707, 0, 0, 0, 0]  // keyframe 1
                ]
            ),
            translation: nil,
            scale: nil
        )
        
        try generateVRMA(
            outputPath: outputPath,
            boneAnimations: [anim],
            duration: 1.0,
            interpolation: .cubicSpline
        )
    }
    
    /// Generate finger animation
    static func generateFingerAnimation(outputPath: String) throws {
        let fingers = [
            ("leftIndexProximal", 20),
            ("leftIndexIntermediate", 21),
            ("leftMiddleProximal", 22),
            ("rightIndexProximal", 30),
            ("rightIndexIntermediate", 31),
        ]
        
        var animations: [BoneAnimation] = []
        
        for (name, nodeIndex) in fingers {
            let anim = BoneAnimation(
                boneName: name,
                nodeIndex: nodeIndex,
                rotation: KeyframeTrack(
                    times: [0.0, 0.5, 1.0],
                    values: [
                        [0, 0, 0, 1],
                        [0, 0, 0.259, 0.966],  // 30° curl
                        [0, 0, 0, 1]
                    ]
                ),
                translation: nil,
                scale: nil
            )
            animations.append(anim)
        }
        
        try generateVRMA(
            outputPath: outputPath,
            boneAnimations: animations,
            duration: 1.0
        )
    }
    
    /// Generate all standard test files
    static func generateAllTestFiles(outputDirectory: String) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(atPath: outputDirectory, 
                                       withIntermediateDirectories: true)
        
        // Generate VRMA_01 through VRMA_07 (various test animations)
        for i in 1...7 {
            let path = "\(outputDirectory)/VRMA_0\(i).vrma"
            
            switch i {
            case 1:
                // Walking animation
                try generateWalkingAnimation(outputPath: path)
            case 2:
                // Arm wave
                try generateArmWaveAnimation(outputPath: path)
            case 3:
                // Head turn
                try generateHeadTurnAnimation(outputPath: path)
            case 4:
                // Idle breathing
                try generateIdleAnimation(outputPath: path)
            case 5:
                // Jump
                try generateJumpAnimation(outputPath: path)
            case 6:
                // Sitting
                try generateSittingAnimation(outputPath: path)
            case 7:
                // Complex mixed animation
                try generateComplexAnimation(outputPath: path)
            default:
                break
            }
        }
        
        // Generate specialized test files
        try generateExpressionAnimation(
            outputPath: "\(outputDirectory)/VRMA_expressions.vrma"
        )
        try generateScaleAnimation(
            outputPath: "\(outputDirectory)/VRMA_scale.vrma"
        )
        try generateCubicSplineAnimation(
            outputPath: "\(outputDirectory)/VRMA_cubicspline.vrma"
        )
        try generateFingerAnimation(
            outputPath: "\(outputDirectory)/VRMA_fingers.vrma"
        )
        
        print("✅ Generated all test files in \(outputDirectory)")
    }
    
    // MARK: - Animation Presets
    
    static func generateArmWaveAnimation(outputPath: String) throws {
        let armAnim = BoneAnimation(
            boneName: "rightUpperArm",
            nodeIndex: 15,
            rotation: KeyframeTrack(
                times: [0.0, 0.5, 1.0],
                values: [
                    [0, 0, 0, 1],
                    [0, 0, 0.707, 0.707],  // 90°
                    [0, 0, 0, 1]
                ]
            ),
            translation: nil,
            scale: nil
        )
        
        try generateVRMA(
            outputPath: outputPath,
            boneAnimations: [armAnim],
            duration: 1.0
        )
    }
    
    static func generateHeadTurnAnimation(outputPath: String) throws {
        let headAnim = BoneAnimation(
            boneName: "head",
            nodeIndex: 5,
            rotation: KeyframeTrack(
                times: [0.0, 0.5, 1.0],
                values: [
                    [0, 0, 0, 1],
                    [0, 0.259, 0, 0.966],  // 30°
                    [0, 0, 0, 1]
                ]
            ),
            translation: nil,
            scale: nil
        )
        
        try generateVRMA(
            outputPath: outputPath,
            boneAnimations: [headAnim],
            duration: 1.0
        )
    }
    
    static func generateIdleAnimation(outputPath: String) throws {
        let chestAnim = BoneAnimation(
            boneName: "chest",
            nodeIndex: 2,
            rotation: KeyframeTrack(
                times: [0.0, 1.0, 2.0],
                values: [
                    [0, 0, 0, 1],
                    [0.044, 0, 0, 0.999],  // Small pitch
                    [0, 0, 0, 1]
                ]
            ),
            translation: nil,
            scale: nil
        )
        
        try generateVRMA(
            outputPath: outputPath,
            boneAnimations: [chestAnim],
            duration: 2.0
        )
    }
    
    static func generateJumpAnimation(outputPath: String) throws {
        let hipsAnim = BoneAnimation(
            boneName: "hips",
            nodeIndex: 0,
            rotation: nil,
            translation: KeyframeTrack(
                times: [0.0, 0.25, 0.5, 0.75, 1.0],
                values: [
                    [0, 0, 0],
                    [0, 0.3, 0],
                    [0, 0, 0],
                    [0, -0.1, 0],
                    [0, 0, 0]
                ]
            ),
            scale: nil
        )
        
        try generateVRMA(
            outputPath: outputPath,
            boneAnimations: [hipsAnim],
            duration: 1.0
        )
    }
    
    static func generateSittingAnimation(outputPath: String) throws {
        // Simplified sitting pose
        let hipsAnim = BoneAnimation(
            boneName: "hips",
            nodeIndex: 0,
            rotation: nil,
            translation: KeyframeTrack(
                times: [0.0, 1.0],
                values: [
                    [0, 0, 0],
                    [0, -0.5, 0]  // Lower hips
                ]
            ),
            scale: nil
        )
        
        try generateVRMA(
            outputPath: outputPath,
            boneAnimations: [hipsAnim],
            duration: 1.0
        )
    }
    
    static func generateComplexAnimation(outputPath: String) throws {
        // Multiple bones animated
        var animations: [BoneAnimation] = []
        
        // Hips sway
        animations.append(BoneAnimation(
            boneName: "hips",
            nodeIndex: 0,
            rotation: KeyframeTrack(
                times: [0.0, 0.5, 1.0],
                values: [
                    [0, 0, 0, 1],
                    [0, 0.087, 0, 0.996],  // 10°
                    [0, 0, 0, 1]
                ]
            ),
            translation: nil,
            scale: nil
        ))
        
        // Arms swinging
        animations.append(BoneAnimation(
            boneName: "leftUpperArm",
            nodeIndex: 10,
            rotation: KeyframeTrack(
                times: [0.0, 0.5, 1.0],
                values: [
                    [0, 0, 0, 1],
                    [0, 0, -0.259, 0.966],
                    [0, 0, 0, 1]
                ]
            ),
            translation: nil,
            scale: nil
        ))
        
        animations.append(BoneAnimation(
            boneName: "rightUpperArm",
            nodeIndex: 15,
            rotation: KeyframeTrack(
                times: [0.0, 0.5, 1.0],
                values: [
                    [0, 0, 0, 1],
                    [0, 0, 0.259, 0.966],
                    [0, 0, 0, 1]
                ]
            ),
            translation: nil,
            scale: nil
        ))
        
        try generateVRMA(
            outputPath: outputPath,
            boneAnimations: animations,
            duration: 1.0
        )
    }
}

// MARK: - Data Types

struct BoneAnimation {
    let boneName: String
    let nodeIndex: Int
    let rotation: KeyframeTrack?  // Quaternion values [x, y, z, w]
    let translation: KeyframeTrack?  // Vector values [x, y, z]
    let scale: KeyframeTrack?  // Vector values [x, y, z]
}

struct ExpressionAnimation {
    let name: String
    let nodeIndex: Int
    let keyframes: KeyframeTrack  // Scalar values [weight]
}

struct KeyframeTrack {
    let times: [Float]
    let values: [[Float]]
    let tangents: [[Float]]?  // For CUBICSPLINE
    
    init(times: [Float], values: [[Float]], tangents: [[Float]]? = nil) {
        self.times = times
        self.values = values
        self.tangents = tangents
    }
}



// MARK: - VRMA File Builder

private class VRMAGenerator {
    let duration: Float
    let interpolation: InterpolationType
    private var boneAnimations: [BoneAnimation] = []
    private var expressionAnimations: [ExpressionAnimation] = []
    
    init(duration: Float, interpolation: InterpolationType) {
        self.duration = duration
        self.interpolation = interpolation
    }
    
    func addBoneAnimation(_ anim: BoneAnimation) {
        boneAnimations.append(anim)
    }
    
    func addExpressionAnimation(_ anim: ExpressionAnimation) {
        expressionAnimations.append(anim)
    }
    
    func build() throws -> Data {
        // This is a simplified implementation
        // In practice, this would build a proper glTF binary file
        
        var json: [String: Any] = [
            "asset": [
                "version": "2.0",
                "generator": "VRMADataGenerator"
            ],
            "extensionsUsed": ["VRMC_vrm_animation"],
            "extensions": [
                "VRMC_vrm_animation": [
                    "specVersion": "1.0",
                    "humanoid": [
                        "humanBones": buildHumanBones()
                    ],
                    "expressions": [
                        "preset": buildExpressions()
                    ]
                ]
            ]
        ]
        
        if !boneAnimations.isEmpty || !expressionAnimations.isEmpty {
            json["animations"] = [buildAnimation()]
        }
        
        // For now, return JSON data (not actual GLB)
        // A full implementation would create proper GLB binary format
        let jsonData = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
        return jsonData
    }
    
    private func buildHumanBones() -> [String: [String: Any]] {
        var bones: [String: [String: Any]] = [:]
        
        for anim in boneAnimations {
            // Map bone names to VRM humanoid bone names
            let vrmBoneName = mapBoneName(anim.boneName)
            bones[vrmBoneName] = ["node": anim.nodeIndex]
        }
        
        return bones
    }
    
    private func buildExpressions() -> [String: [String: Any]] {
        var expressions: [String: [String: Any]] = [:]
        
        for expr in expressionAnimations {
            expressions[expr.name] = ["node": expr.nodeIndex]
        }
        
        return expressions
    }
    
    private func buildAnimation() -> [String: Any] {
        var channels: [[String: Any]] = []
        var samplers: [[String: Any]] = []
        
        var samplerIndex = 0
        
        // Add bone animation channels
        for anim in boneAnimations {
            if anim.rotation != nil {
                channels.append([
                    "sampler": samplerIndex,
                    "target": [
                        "node": anim.nodeIndex,
                        "path": "rotation"
                    ]
                ])
                samplers.append(buildSampler(for: anim.rotation!))
                samplerIndex += 1
            }
            
            if anim.translation != nil {
                channels.append([
                    "sampler": samplerIndex,
                    "target": [
                        "node": anim.nodeIndex,
                        "path": "translation"
                    ]
                ])
                samplers.append(buildSampler(for: anim.translation!))
                samplerIndex += 1
            }
            
            if anim.scale != nil {
                channels.append([
                    "sampler": samplerIndex,
                    "target": [
                        "node": anim.nodeIndex,
                        "path": "scale"
                    ]
                ])
                samplers.append(buildSampler(for: anim.scale!))
                samplerIndex += 1
            }
        }
        
        // Add expression animation channels
        for expr in expressionAnimations {
            channels.append([
                "sampler": samplerIndex,
                "target": [
                    "node": expr.nodeIndex,
                    "path": "translation"
                ]
            ])
            samplers.append(buildSampler(for: expr.keyframes))
            samplerIndex += 1
        }
        
        return [
            "channels": channels,
            "samplers": samplers
        ]
    }
    
    private func buildSampler(for track: KeyframeTrack) -> [String: Any] {
        var sampler: [String: Any] = [
            "input": 0,  // Reference to time accessor
            "interpolation": interpolation.rawValue,
            "output": 1  // Reference to value accessor
        ]
        
        if interpolation == .cubicSpline && track.tangents != nil {
            sampler["interpolation"] = "CUBICSPLINE"
        }
        
        return sampler
    }
    
    private func mapBoneName(_ name: String) -> String {
        // Map various naming conventions to VRM spec names
        let mapping: [String: String] = [
            "hips": "hips",
            "spine": "spine",
            "chest": "chest",
            "neck": "neck",
            "head": "head",
            "leftUpperArm": "leftUpperArm",
            "leftLowerArm": "leftLowerArm",
            "leftHand": "leftHand",
            "rightUpperArm": "rightUpperArm",
            "rightLowerArm": "rightLowerArm",
            "rightHand": "rightHand",
            "leftUpperLeg": "leftUpperLeg",
            "leftLowerLeg": "leftLowerLeg",
            "leftFoot": "leftFoot",
            "rightUpperLeg": "rightUpperLeg",
            "rightLowerLeg": "rightLowerLeg",
            "rightFoot": "rightFoot",
        ]
        
        return mapping[name] ?? name
    }
}
