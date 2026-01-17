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

/// Types of AR-triggered reactions
public enum ARReaction: String, Sendable {
    /// No active reaction
    case none
    /// User appeared suddenly or approached quickly
    case surprised
    /// Acknowledging user gesture
    case acknowledge
    /// User approaching (anticipation)
    case anticipate
    /// User too close (defensive)
    case retreat
    /// Friendly wave gesture
    case wave
    /// Acknowledgment nod
    case nod
    /// Gleeful jump (showcases physics)
    case jump
}

/// AR reaction layer providing automatic proximity-based reactions
public class ARReactionLayer: AnimationLayer {
    public let identifier = "ar.reaction"
    public let priority = 3
    public var isEnabled = true

    public var affectedBones: Set<VRMHumanoidBone> {
        [.head, .neck, .chest, .spine, .hips, .leftUpperArm, .rightUpperArm, .leftLowerArm, .rightLowerArm]
    }

    // MARK: - Proximity Thresholds (meters)

    /// Distance at which anticipation reaction triggers
    public var anticipateDistance: Float = 2.0

    /// Distance at which retreat reaction triggers
    public var retreatDistance: Float = 0.5

    /// Speed threshold for surprised reaction (meters/second)
    public var surprisedSpeedThreshold: Float = 2.0

    /// Speed threshold for anticipate reaction (meters/second)
    public var anticipateSpeedThreshold: Float = 0.3

    // MARK: - Reaction Parameters

    /// Default duration of reaction animation (seconds)
    public var reactionDuration: Float = 0.4

    /// Duration for jump reaction (longer to showcase physics)
    public var jumpDuration: Float = 1.2

    /// Enable automatic reaction triggering
    public var autoTriggerEnabled = true

    // MARK: - Head Position Offset

    /// Offset from avatar position to head position
    public var headOffset: SIMD3<Float> = SIMD3<Float>(0, 1.5, 0)

    // MARK: - Private State

    private var currentReaction: ARReaction = .none
    private var reactionProgress: Float = 0
    private var previousDistance: Float = 10.0
    private var distanceChangeRate: Float = 0

    // Pre-allocated output
    private var cachedOutput = LayerOutput(blendMode: .additive)

    // MARK: - Initialization

    public init() {
        // Pre-populate bones
        for bone in affectedBones {
            cachedOutput.bones[bone] = .identity
        }
    }

    // MARK: - Public API

    /// Manually trigger a reaction
    public func triggerReaction(_ reaction: ARReaction) {
        guard currentReaction == .none else { return } // Don't interrupt active reaction
        currentReaction = reaction
        reactionProgress = 0
    }

    /// Get the currently active reaction
    public var activeReaction: ARReaction {
        currentReaction
    }

    /// Check if a reaction is currently playing
    public var isReacting: Bool {
        currentReaction != .none
    }

    // MARK: - AnimationLayer Protocol

    public func update(deltaTime: Float, context: AnimationContext) {
        // Calculate distance to camera
        let headPos = context.avatarPosition + headOffset
        let distance = simd_length(context.cameraPosition - headPos)

        // Calculate rate of change (positive = approaching)
        if deltaTime > 0 {
            distanceChangeRate = (previousDistance - distance) / deltaTime
        }
        previousDistance = distance

        // Auto-trigger reactions based on proximity
        if autoTriggerEnabled && currentReaction == .none {
            checkAutoTriggers(distance: distance)
        }

        // Progress current reaction
        if currentReaction != .none {
            // Use longer duration for jump to showcase physics
            let duration = currentReaction == .jump ? jumpDuration : reactionDuration
            reactionProgress += deltaTime / duration

            if reactionProgress >= 1.0 {
                // Reaction complete
                currentReaction = .none
                reactionProgress = 0
            }
        }
    }

    public func evaluate() -> LayerOutput {
        // Clear previous state
        cachedOutput.bones.removeAll(keepingCapacity: true)
        cachedOutput.morphWeights.removeAll(keepingCapacity: true)

        guard currentReaction != .none else {
            return cachedOutput
        }

        // Calculate eased progress (ease-in-out)
        let t = easeInOut(reactionProgress)

        // Bell curve for return to rest: ramps up then back down
        let intensity = t < 0.5 ? t * 2 : (1 - t) * 2

        switch currentReaction {
        case .surprised:
            evaluateSurprised(intensity: intensity)

        case .acknowledge:
            evaluateAcknowledge(intensity: intensity, progress: t)

        case .anticipate:
            evaluateAnticipate(intensity: intensity)

        case .retreat:
            evaluateRetreat(intensity: intensity)

        case .wave:
            evaluateWave(intensity: intensity, progress: t)

        case .nod:
            evaluateNod(intensity: intensity, progress: t)

        case .jump:
            evaluateJump(intensity: intensity, progress: t)

        case .none:
            break
        }

        return cachedOutput
    }

    // MARK: - Private Methods

    private func checkAutoTriggers(distance: Float) {
        if distanceChangeRate > surprisedSpeedThreshold {
            // User approaching fast
            triggerReaction(.surprised)
        } else if distance < retreatDistance {
            // User too close
            triggerReaction(.retreat)
        } else if distance < anticipateDistance && distanceChangeRate > anticipateSpeedThreshold {
            // User approaching slowly
            triggerReaction(.anticipate)
        }
    }

    private func evaluateSurprised(intensity: Float) {
        // Head tilts back slightly
        var headTransform = ProceduralBoneTransform.identity
        headTransform.rotation = simd_quatf(angle: -0.15 * intensity, axis: SIMD3<Float>(1, 0, 0))
        cachedOutput.bones[.head] = headTransform

        // Chest leans back
        var chestTransform = ProceduralBoneTransform.identity
        chestTransform.rotation = simd_quatf(angle: -0.05 * intensity, axis: SIMD3<Float>(1, 0, 0))
        cachedOutput.bones[.chest] = chestTransform

        // Surprised expression
        cachedOutput.morphWeights[VRMExpressionPreset.surprised.rawValue] = intensity * 0.7
    }

    private func evaluateAcknowledge(intensity: Float, progress: Float) {
        // Quick nod - use progress for the nod phase
        let nodPhase = sin(progress * .pi * 2) // Quick oscillation
        var headTransform = ProceduralBoneTransform.identity
        headTransform.rotation = simd_quatf(angle: 0.1 * nodPhase, axis: SIMD3<Float>(1, 0, 0))
        cachedOutput.bones[.head] = headTransform

        // Slight smile
        cachedOutput.morphWeights[VRMExpressionPreset.happy.rawValue] = intensity * 0.3
    }

    private func evaluateAnticipate(intensity: Float) {
        // Lean forward slightly (interested)
        var chestTransform = ProceduralBoneTransform.identity
        chestTransform.rotation = simd_quatf(angle: 0.05 * intensity, axis: SIMD3<Float>(1, 0, 0))
        cachedOutput.bones[.chest] = chestTransform

        // Neck extends forward
        var neckTransform = ProceduralBoneTransform.identity
        neckTransform.rotation = simd_quatf(angle: 0.03 * intensity, axis: SIMD3<Float>(1, 0, 0))
        cachedOutput.bones[.neck] = neckTransform
    }

    private func evaluateRetreat(intensity: Float) {
        // Lean back (defensive)
        var spineTransform = ProceduralBoneTransform.identity
        spineTransform.rotation = simd_quatf(angle: -0.1 * intensity, axis: SIMD3<Float>(1, 0, 0))
        cachedOutput.bones[.spine] = spineTransform

        var chestTransform = ProceduralBoneTransform.identity
        chestTransform.rotation = simd_quatf(angle: -0.05 * intensity, axis: SIMD3<Float>(1, 0, 0))
        cachedOutput.bones[.chest] = chestTransform

        // Arms raise slightly (protective gesture)
        var leftArmTransform = ProceduralBoneTransform.identity
        leftArmTransform.rotation = simd_quatf(angle: 0.1 * intensity, axis: SIMD3<Float>(0, 0, 1))
        cachedOutput.bones[.leftUpperArm] = leftArmTransform

        var rightArmTransform = ProceduralBoneTransform.identity
        rightArmTransform.rotation = simd_quatf(angle: -0.1 * intensity, axis: SIMD3<Float>(0, 0, 1))
        cachedOutput.bones[.rightUpperArm] = rightArmTransform
    }

    private func evaluateWave(intensity: Float, progress: Float) {
        // Right arm raises for wave
        var rightUpperArmTransform = ProceduralBoneTransform.identity
        rightUpperArmTransform.rotation = simd_quatf(angle: -0.8 * intensity, axis: SIMD3<Float>(0, 0, 1))
        cachedOutput.bones[.rightUpperArm] = rightUpperArmTransform

        // Lower arm waves back and forth
        let wavePhase = sin(progress * .pi * 4) // Multiple waves during the reaction
        var rightLowerArmTransform = ProceduralBoneTransform.identity
        rightLowerArmTransform.rotation = simd_quatf(angle: wavePhase * 0.3 * intensity, axis: SIMD3<Float>(0, 1, 0))
        cachedOutput.bones[.rightLowerArm] = rightLowerArmTransform

        // Happy expression during wave
        cachedOutput.morphWeights[VRMExpressionPreset.happy.rawValue] = intensity * 0.5
    }

    private func evaluateNod(intensity: Float, progress: Float) {
        // Quick nod motion - head bobs down and up
        let nodPhase = sin(progress * .pi * 2)
        var headTransform = ProceduralBoneTransform.identity
        headTransform.rotation = simd_quatf(angle: 0.1 * nodPhase, axis: SIMD3<Float>(1, 0, 0))
        cachedOutput.bones[.head] = headTransform

        // Slight smile during nod
        cachedOutput.morphWeights[VRMExpressionPreset.happy.rawValue] = intensity * 0.3
    }

    private func evaluateJump(intensity: Float, progress: Float) {
        // Parabolic jump curve: starts at 0, peaks at 0.5, returns to 0
        let jumpPhase = sin(progress * .pi)  // 0 -> 1 -> 0

        // Hips translate up for the jump - large value for visible jump
        let jumpHeight: Float = 0.25 * intensity  // 25cm jump height

        // Debug: Log jump parameters
        if jumpPhase > 0.1 {
            print("🦘 Jump: progress=\(progress), intensity=\(intensity), jumpPhase=\(jumpPhase), height=\(jumpHeight * jumpPhase)m")
        }

        var hipsTransform = ProceduralBoneTransform.identity
        hipsTransform.translation = SIMD3<Float>(0, jumpHeight * jumpPhase, 0)
        cachedOutput.bones[.hips] = hipsTransform

        // Spine bends back during jump
        var spineTransform = ProceduralBoneTransform.identity
        spineTransform.rotation = simd_quatf(angle: -0.15 * jumpPhase * intensity, axis: SIMD3<Float>(1, 0, 0))
        cachedOutput.bones[.spine] = spineTransform

        // Chest arches back during jump peak
        var chestTransform = ProceduralBoneTransform.identity
        chestTransform.rotation = simd_quatf(angle: -0.1 * jumpPhase * intensity, axis: SIMD3<Float>(1, 0, 0))
        cachedOutput.bones[.chest] = chestTransform

        // Head tilts back with joy
        var headTransform = ProceduralBoneTransform.identity
        headTransform.rotation = simd_quatf(angle: -0.2 * jumpPhase * intensity, axis: SIMD3<Float>(1, 0, 0))
        cachedOutput.bones[.head] = headTransform

        // Arms raise up and out gleefully (rotate around Z to raise, X to spread)
        let armRaise = jumpPhase * 1.2 * intensity  // Increased arm raise
        var leftArmTransform = ProceduralBoneTransform.identity
        // Rotate around Z (roll) to raise arm up, positive for left arm
        leftArmTransform.rotation = simd_quatf(angle: armRaise, axis: SIMD3<Float>(0, 0, 1))
        cachedOutput.bones[.leftUpperArm] = leftArmTransform

        var rightArmTransform = ProceduralBoneTransform.identity
        // Rotate around Z (roll) to raise arm up, negative for right arm
        rightArmTransform.rotation = simd_quatf(angle: -armRaise, axis: SIMD3<Float>(0, 0, 1))
        cachedOutput.bones[.rightUpperArm] = rightArmTransform

        // Forearms bend for excited gesture
        let forearmBend = jumpPhase * 0.5 * intensity
        var leftLowerArmTransform = ProceduralBoneTransform.identity
        leftLowerArmTransform.rotation = simd_quatf(angle: -forearmBend, axis: SIMD3<Float>(1, 0, 0))
        cachedOutput.bones[.leftLowerArm] = leftLowerArmTransform

        var rightLowerArmTransform = ProceduralBoneTransform.identity
        rightLowerArmTransform.rotation = simd_quatf(angle: -forearmBend, axis: SIMD3<Float>(1, 0, 0))
        cachedOutput.bones[.rightLowerArm] = rightLowerArmTransform

        // Big happy expression during jump
        cachedOutput.morphWeights[VRMExpressionPreset.happy.rawValue] = intensity * 0.95
    }

    private func easeInOut(_ t: Float) -> Float {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }
}
