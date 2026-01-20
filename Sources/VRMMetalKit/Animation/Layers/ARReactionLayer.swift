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
    /// Idle/standing pose
    case idle
    /// Walking animation
    case walk
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
        [.head, .neck, .chest, .spine, .hips,
         .leftUpperArm, .rightUpperArm, .leftLowerArm, .rightLowerArm,
         .leftUpperLeg, .rightUpperLeg, .leftLowerLeg, .rightLowerLeg]
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

    /// Duration for walk cycle (loops continuously while held)
    public var walkDuration: Float = 1.0

    /// Enable automatic reaction triggering
    public var autoTriggerEnabled = true

    /// Callback when a reaction completes (not called for looping reactions like walk)
    public var onReactionComplete: ((ARReaction) -> Void)?

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
        // Allow certain transitions:
        // - idle can always be set (stops current animation)
        // - jump can interrupt walk
        // - walk can only start if nothing else is playing
        // - other reactions can't interrupt each other

        if reaction == .idle || reaction == .none {
            // Idle/none always allowed - stops current animation
            currentReaction = reaction
            reactionProgress = 0
            return
        }

        if reaction == .jump && (currentReaction == .walk || currentReaction == .idle || currentReaction == .none) {
            // Jump can interrupt walk or start from idle
            currentReaction = reaction
            reactionProgress = 0
            return
        }

        if reaction == .walk && (currentReaction == .none || currentReaction == .idle) {
            // Walk can only start from idle/none
            currentReaction = reaction
            reactionProgress = 0
            return
        }

        // Other reactions: don't interrupt active reaction
        guard currentReaction == .none || currentReaction == .idle else { return }
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
            // Use appropriate duration for each reaction type
            let duration: Float
            switch currentReaction {
            case .jump:
                duration = jumpDuration
            case .walk:
                duration = walkDuration
            default:
                duration = reactionDuration
            }

            reactionProgress += deltaTime / duration

            if reactionProgress >= 1.0 {
                // Walk loops continuously, other reactions complete
                if currentReaction == .walk {
                    reactionProgress = reactionProgress.truncatingRemainder(dividingBy: 1.0)
                } else {
                    let completedReaction = currentReaction
                    currentReaction = .none
                    reactionProgress = 0
                    // Notify completion (for physics reset, etc.)
                    onReactionComplete?(completedReaction)
                }
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
        // Exception: walk uses constant intensity since it loops
        let intensity: Float
        if currentReaction == .walk {
            intensity = 1.0  // Constant for looping animation
        } else {
            intensity = t < 0.5 ? t * 2 : (1 - t) * 2
        }

        switch currentReaction {
        case .idle:
            evaluateIdle(intensity: intensity, progress: t)

        case .walk:
            evaluateWalk(intensity: 1.0, progress: reactionProgress)

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

        // Arms raise up and out gleefully (rotate around Z to raise)
        // VRM 0.0: negative Z rotation raises left arm, positive Z raises right arm
        let armRaise = jumpPhase * 1.2 * intensity  // Increased arm raise
        var leftArmTransform = ProceduralBoneTransform.identity
        leftArmTransform.rotation = simd_quatf(angle: -armRaise, axis: SIMD3<Float>(0, 0, 1))
        cachedOutput.bones[.leftUpperArm] = leftArmTransform

        var rightArmTransform = ProceduralBoneTransform.identity
        rightArmTransform.rotation = simd_quatf(angle: armRaise, axis: SIMD3<Float>(0, 0, 1))
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

    private func evaluateIdle(intensity: Float, progress: Float) {
        // Subtle breathing motion - very gentle
        let breathPhase = sin(progress * .pi * 2)

        // Chest expands slightly with breath
        var chestTransform = ProceduralBoneTransform.identity
        chestTransform.rotation = simd_quatf(angle: 0.02 * breathPhase * intensity, axis: SIMD3<Float>(1, 0, 0))
        cachedOutput.bones[.chest] = chestTransform

        // Shoulders rise slightly
        var spineTransform = ProceduralBoneTransform.identity
        spineTransform.rotation = simd_quatf(angle: 0.01 * breathPhase * intensity, axis: SIMD3<Float>(1, 0, 0))
        cachedOutput.bones[.spine] = spineTransform
    }

    private func evaluateWalk(intensity: Float, progress: Float) {
        // Walking animation - continuous looping motion
        // Use time-based cycling for continuous walk
        let walkCycle = progress * .pi * 2  // One full gait cycle (left+right step)

        // Leg swing amplitude (radians) - how far legs swing forward/back
        let legSwingAmplitude: Float = 0.4 * intensity

        // Knee bend amplitude - knees bend during swing phase
        let kneeBendAmplitude: Float = 0.5 * intensity

        // Left leg swings forward when sin(walkCycle) > 0
        let leftLegSwing = sin(walkCycle) * legSwingAmplitude
        // Right leg is opposite phase
        let rightLegSwing = sin(walkCycle + .pi) * legSwingAmplitude

        // Upper legs (thighs) swing forward/back around X axis
        // Negative X rotation = leg swings forward in VRM 0.0 coordinate system
        var leftUpperLegTransform = ProceduralBoneTransform.identity
        leftUpperLegTransform.rotation = simd_quatf(angle: -leftLegSwing, axis: SIMD3<Float>(1, 0, 0))
        cachedOutput.bones[.leftUpperLeg] = leftUpperLegTransform

        var rightUpperLegTransform = ProceduralBoneTransform.identity
        rightUpperLegTransform.rotation = simd_quatf(angle: -rightLegSwing, axis: SIMD3<Float>(1, 0, 0))
        cachedOutput.bones[.rightUpperLeg] = rightUpperLegTransform

        // Lower legs (knees) bend during swing phase
        // Knee bends most when leg is swinging forward (passing under body)
        // Negative X rotation bends knee so calf goes backward
        let leftKneeBend = max(0, sin(walkCycle + 0.5)) * kneeBendAmplitude
        let rightKneeBend = max(0, sin(walkCycle + .pi + 0.5)) * kneeBendAmplitude

        var leftLowerLegTransform = ProceduralBoneTransform.identity
        leftLowerLegTransform.rotation = simd_quatf(angle: -leftKneeBend, axis: SIMD3<Float>(1, 0, 0))
        cachedOutput.bones[.leftLowerLeg] = leftLowerLegTransform

        var rightLowerLegTransform = ProceduralBoneTransform.identity
        rightLowerLegTransform.rotation = simd_quatf(angle: -rightKneeBend, axis: SIMD3<Float>(1, 0, 0))
        cachedOutput.bones[.rightLowerLeg] = rightLowerLegTransform

        // Hips bob up and down with each step (twice per cycle)
        let hipBob = sin(walkCycle * 2) * 0.02 * intensity
        var hipsTransform = ProceduralBoneTransform.identity
        hipsTransform.translation = SIMD3<Float>(0, hipBob, 0)
        // Hips also sway side to side (weight shift)
        let hipSway = sin(walkCycle) * 0.04 * intensity
        hipsTransform.rotation = simd_quatf(angle: hipSway, axis: SIMD3<Float>(0, 0, 1))
        cachedOutput.bones[.hips] = hipsTransform

        // Spine counter-rotates for balance
        var spineTransform = ProceduralBoneTransform.identity
        spineTransform.rotation = simd_quatf(angle: -hipSway * 0.5, axis: SIMD3<Float>(0, 0, 1))
        cachedOutput.bones[.spine] = spineTransform

        // Arms swing opposite to legs (natural gait)
        // Left arm swings forward when right leg swings forward (opposite phase)
        // Positive X rotation swings arm forward in VRM 0.0
        let armSwing = sin(walkCycle) * 0.35 * intensity
        var leftArmTransform = ProceduralBoneTransform.identity
        leftArmTransform.rotation = simd_quatf(angle: armSwing, axis: SIMD3<Float>(1, 0, 0))
        cachedOutput.bones[.leftUpperArm] = leftArmTransform

        var rightArmTransform = ProceduralBoneTransform.identity
        rightArmTransform.rotation = simd_quatf(angle: -armSwing, axis: SIMD3<Float>(1, 0, 0))
        cachedOutput.bones[.rightUpperArm] = rightArmTransform

        // Head stays relatively stable but slight bob
        var headTransform = ProceduralBoneTransform.identity
        headTransform.rotation = simd_quatf(angle: sin(walkCycle * 2) * 0.02 * intensity, axis: SIMD3<Float>(1, 0, 0))
        cachedOutput.bones[.head] = headTransform
    }

    private func easeInOut(_ t: Float) -> Float {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }
}
