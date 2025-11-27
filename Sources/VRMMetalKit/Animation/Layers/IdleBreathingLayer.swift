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

/// Idle animation layer providing subtle breathing and weight shift movements
public class IdleBreathingLayer: AnimationLayer {
    public let identifier = "idle.breathing"
    public let priority = 0
    public var isEnabled = true

    public var affectedBones: Set<VRMHumanoidBone> {
        [.chest, .spine, .upperChest, .leftShoulder, .rightShoulder, .hips,
         .leftUpperArm, .rightUpperArm, .leftLowerArm, .rightLowerArm]
    }

    // MARK: - Breathing Parameters

    /// Duration of one full breath cycle in seconds
    public var breathingPeriod: Float = 4.0

    /// Maximum rotation amplitude for breathing (radians)
    public var breathingAmplitude: Float = 0.02

    // MARK: - Weight Shift Parameters

    /// Duration of one weight shift cycle in seconds
    public var weightShiftPeriod: Float = 6.0

    /// Maximum rotation amplitude for weight shift (radians)
    public var weightShiftAmplitude: Float = 0.01

    // MARK: - Micro-Movement Parameters

    /// Enable perlin-ish noise for subtle liveliness
    public var microMovementEnabled = true

    /// Amplitude of micro-movements (radians)
    public var microMovementAmplitude: Float = 0.005

    // MARK: - Private State

    private var time: Float = 0
    private let noiseOffset: Float

    // Pre-allocated output to avoid per-frame allocations
    private var cachedOutput = LayerOutput(blendMode: .blend(1.0))

    // MARK: - Initialization

    public init() {
        noiseOffset = Float.random(in: 0...1000)

        // Pre-populate affected bones in cached output
        for bone in affectedBones {
            cachedOutput.bones[bone] = .identity
        }
    }

    // MARK: - AnimationLayer Protocol

    public func update(deltaTime: Float, context: AnimationContext) {
        time = context.time
    }

    public func evaluate() -> LayerOutput {
        // Calculate breathing phase (0 to 2π)
        let breathPhase = (time / breathingPeriod) * 2 * .pi
        let breathValue = sin(breathPhase) * breathingAmplitude

        // Calculate weight shift phase
        let swayPhase = (time / weightShiftPeriod) * 2 * .pi
        let swayValue = sin(swayPhase) * weightShiftAmplitude

        // Chest rotates slightly forward on inhale
        var chestTransform = ProceduralBoneTransform.identity
        chestTransform.rotation = simd_quatf(angle: breathValue, axis: SIMD3<Float>(1, 0, 0))

        // Add micro-movement to chest for liveliness
        if microMovementEnabled {
            let noise = simplerNoise(time + noiseOffset) * microMovementAmplitude
            let microRot = simd_quatf(angle: noise, axis: SIMD3<Float>(0, 1, 0))
            chestTransform.rotation = simd_mul(chestTransform.rotation, microRot)
        }
        cachedOutput.bones[.chest] = chestTransform

        // Upper chest follows with reduced amplitude
        var upperChestTransform = ProceduralBoneTransform.identity
        upperChestTransform.rotation = simd_quatf(angle: breathValue * 0.5, axis: SIMD3<Float>(1, 0, 0))
        cachedOutput.bones[.upperChest] = upperChestTransform

        // Shoulders rise slightly on inhale
        let shoulderLift = breathValue * 0.3

        var leftShoulderTransform = ProceduralBoneTransform.identity
        leftShoulderTransform.rotation = simd_quatf(angle: shoulderLift, axis: SIMD3<Float>(0, 0, 1))
        cachedOutput.bones[.leftShoulder] = leftShoulderTransform

        var rightShoulderTransform = ProceduralBoneTransform.identity
        rightShoulderTransform.rotation = simd_quatf(angle: -shoulderLift, axis: SIMD3<Float>(0, 0, 1))
        cachedOutput.bones[.rightShoulder] = rightShoulderTransform

        // Hips sway for weight shift
        var hipsTransform = ProceduralBoneTransform.identity
        hipsTransform.rotation = simd_quatf(angle: swayValue, axis: SIMD3<Float>(0, 0, 1))
        cachedOutput.bones[.hips] = hipsTransform

        // Spine counter-rotates to keep head stable
        var spineTransform = ProceduralBoneTransform.identity
        spineTransform.rotation = simd_quatf(angle: -swayValue * 0.5, axis: SIMD3<Float>(0, 0, 1))
        cachedOutput.bones[.spine] = spineTransform

        // Arms down from T-pose - rotate upper arms down ~70 degrees
        // In VRM, upper arm X-axis points along the arm, Z-axis points forward
        // Rotate around Z-axis to bring arms down to sides
        var leftUpperArmTransform = ProceduralBoneTransform.identity
        leftUpperArmTransform.rotation = simd_quatf(angle: 1.2, axis: SIMD3<Float>(0, 0, 1))  // ~70° down
        cachedOutput.bones[.leftUpperArm] = leftUpperArmTransform

        var rightUpperArmTransform = ProceduralBoneTransform.identity
        rightUpperArmTransform.rotation = simd_quatf(angle: -1.2, axis: SIMD3<Float>(0, 0, 1))  // ~70° down (opposite direction)
        cachedOutput.bones[.rightUpperArm] = rightUpperArmTransform

        // Bend elbows slightly for natural pose (~20 degrees)
        var leftLowerArmTransform = ProceduralBoneTransform.identity
        leftLowerArmTransform.rotation = simd_quatf(angle: -0.35, axis: SIMD3<Float>(0, 1, 0))  // Bend elbow
        cachedOutput.bones[.leftLowerArm] = leftLowerArmTransform

        var rightLowerArmTransform = ProceduralBoneTransform.identity
        rightLowerArmTransform.rotation = simd_quatf(angle: 0.35, axis: SIMD3<Float>(0, 1, 0))  // Bend elbow (opposite)
        cachedOutput.bones[.rightLowerArm] = rightLowerArmTransform

        return cachedOutput
    }

    // MARK: - Private Methods

    /// Simple multi-frequency noise function for organic movement
    private func simplerNoise(_ t: Float) -> Float {
        let a = sin(t * 1.1) * 0.5
        let b = sin(t * 2.3 + 1.7) * 0.3
        let c = sin(t * 4.7 + 3.2) * 0.2
        return a + b + c
    }
}
