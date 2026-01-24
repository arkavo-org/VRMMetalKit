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

/// Expression layer managing facial expressions and automatic blinking
public class ExpressionLayer: AnimationLayer {
    public let identifier = "expression"
    public let priority = 1
    public var isEnabled = true

    // Expressions use morph targets only, no bones
    public var affectedBones: Set<VRMHumanoidBone> { [] }

    // MARK: - Blink Parameters

    /// Enable automatic blinking
    public var blinkEnabled = true

    /// Minimum time between blinks (seconds)
    public var blinkMinInterval: Float = 2.0

    /// Maximum time between blinks (seconds)
    public var blinkMaxInterval: Float = 5.0

    /// Duration of a single blink (seconds)
    public var blinkDuration: Float = 0.15

    // MARK: - Expression Parameters

    /// Speed of expression transitions (higher = faster)
    public var transitionSpeed: Float = 8.0

    /// Time to hold peak expression before starting decay (seconds)
    public var holdDuration: Float = 0.5

    /// Delay before returning to neutral after expression change (seconds)
    public var returnToNeutralDelay: Float = 0.3

    // MARK: - Playful Idle Parameters

    /// Enable playful idle behaviors (random smiles)
    public var playfulIdleEnabled = true

    /// Minimum time between idle smiles (seconds)
    public var smileMinInterval: Float = 5.0

    /// Maximum time between idle smiles (seconds)
    public var smileMaxInterval: Float = 12.0

    /// Duration of an idle smile (seconds)
    public var smileDuration: Float = 1.2

    /// Duration of a wink (seconds)
    public var winkDuration: Float = 0.25

    // MARK: - Private State

    private var currentExpression: VRMExpressionPreset = .neutral
    private var currentIntensity: Float = 0
    private var targetIntensity: Float = 0

    // Hold/delay state
    private var holdTimer: Float = 0
    private var isHolding: Bool = false
    private var returnTimer: Float = 0
    private var isWaitingToReturn: Bool = false
    private var previousExpression: VRMExpressionPreset = .neutral
    private var lastProcessedSentiment: VRMExpressionPreset? = nil  // Prevent re-triggering same sentiment

    // Blink state
    private var blinkTimer: Float = 0
    private var nextBlinkTime: Float = 3.0
    private var blinkProgress: Float = 0
    private var isBlinking = false

    // Idle smile state
    private var smileTimer: Float = 0
    private var nextSmileTime: Float = 6.0
    private var smileProgress: Float = 0
    private var isSmiling = false

    // Wink state (triggered by flirty context, not random)
    private var winkProgress: Float = 0
    private var isWinking = false
    private var winkLeft = true  // Alternate eyes

    // Pre-allocated output
    private var cachedOutput = LayerOutput(blendMode: .additive)

    // MARK: - Initialization

    public init() {
        scheduleNextBlink()
        scheduleNextSmile()
    }

    // MARK: - Public API

    /// Set the target expression and intensity
    public func setExpression(_ preset: VRMExpressionPreset, intensity: Float) {
        currentExpression = preset
        targetIntensity = max(0, min(1, intensity))
    }

    /// Get the current expression preset
    public var expression: VRMExpressionPreset {
        currentExpression
    }

    /// Get the current intensity
    public var intensity: Float {
        currentIntensity
    }

    /// Trigger an immediate blink
    public func triggerBlink() {
        guard !isBlinking else { return }
        isBlinking = true
        blinkProgress = 0
    }

    /// Trigger a flirty wink (call when flirty context detected)
    public func triggerWink() {
        guard !isWinking && !isBlinking else { return }
        isWinking = true
        winkProgress = 0
        winkLeft.toggle()  // Alternate eyes each time
    }

    // MARK: - AnimationLayer Protocol

    public func update(deltaTime: Float, context: AnimationContext) {
        // Update expression from context sentiment if provided
        if let preset = context.sentimentPreset {
            // Only trigger if this is a NEW sentiment (not the same one we already processed)
            if preset != lastProcessedSentiment {
                lastProcessedSentiment = preset
                previousExpression = currentExpression
                currentExpression = preset
                targetIntensity = context.sentimentIntensity
                isHolding = false
                holdTimer = 0
                isWaitingToReturn = false
                returnTimer = 0
            }
            // Don't override targetIntensity if we're holding, waiting to return, or decaying
            // This allows the expression to naturally return to neutral
        } else {
            // No sentiment in context - allow new sentiments to trigger
            lastProcessedSentiment = nil
        }

        // Handle hold at peak intensity
        if currentIntensity >= targetIntensity - 0.01 && targetIntensity > 0.01 && !isHolding && !isWaitingToReturn {
            // Reached target, start holding
            isHolding = true
            holdTimer = 0
        }

        if isHolding {
            holdTimer += deltaTime
            if holdTimer >= holdDuration {
                isHolding = false
                // Start return-to-neutral delay if we should decay
                if currentExpression != .neutral {
                    isWaitingToReturn = true
                    returnTimer = 0
                }
            }
        }

        // Handle return-to-neutral delay
        if isWaitingToReturn {
            returnTimer += deltaTime
            if returnTimer >= returnToNeutralDelay {
                isWaitingToReturn = false
                // Decay to neutral - set target intensity to 0
                targetIntensity = 0
                // Clear last processed so new sentiments can trigger
                lastProcessedSentiment = nil
            }
        }

        // Smooth intensity transition (skip if holding or waiting)
        if !isHolding && !isWaitingToReturn {
            let diff = targetIntensity - currentIntensity
            currentIntensity += diff * min(1.0, transitionSpeed * deltaTime)
        }

        // Clamp very small values to zero
        if abs(currentIntensity) < 0.001 {
            currentIntensity = 0
        }

        // Update blink animation
        if blinkEnabled {
            updateBlink(deltaTime: deltaTime)
        }

        // Update playful idle behaviors (only when truly idle)
        let isIdle = currentIntensity < 0.01 && !isHolding && !isWaitingToReturn
        if playfulIdleEnabled && isIdle {
            updateIdleSmile(deltaTime: deltaTime)
        } else {
            // Reset idle timers when not idle
            if !isIdle {
                smileTimer = 0
                isSmiling = false
            }
        }

        // Progress wink animation if active (triggered by flirty context)
        if isWinking {
            winkProgress += deltaTime / winkDuration
            if winkProgress >= 1.0 {
                isWinking = false
                winkProgress = 0
            }
        }

        // Check for flirty context and trigger wink
        if context.isFlirty && !isWinking && !isBlinking {
            triggerWink()
        }
    }

    public func evaluate() -> LayerOutput {
        // Clear previous morphs - ensures clean slate each frame
        cachedOutput.morphWeights.removeAll(keepingCapacity: true)

        // Apply current expression
        if currentIntensity > 0.01 {
            cachedOutput.morphWeights[currentExpression.rawValue] = currentIntensity
        }

        // Apply idle smile (soft bell curve)
        if isSmiling {
            let smileValue = sin(smileProgress * .pi) * 0.4  // Subtle smile, max 40%
            cachedOutput.morphWeights[VRMExpressionPreset.happy.rawValue] = smileValue
        }

        // Apply wink (quick asymmetric blink)
        if isWinking {
            let winkValue = sin(winkProgress * .pi)
            if winkLeft {
                cachedOutput.morphWeights[VRMExpressionPreset.blinkLeft.rawValue] = winkValue
            } else {
                cachedOutput.morphWeights[VRMExpressionPreset.blinkRight.rawValue] = winkValue
            }
        }

        // Apply blink (bell curve: 0 → 1 → 0)
        if isBlinking && !isWinking {  // Don't blink during wink
            let blinkValue = sin(blinkProgress * .pi)
            cachedOutput.morphWeights[VRMExpressionPreset.blink.rawValue] = blinkValue
        }

        return cachedOutput
    }

    // MARK: - Private Methods

    private func updateBlink(deltaTime: Float) {
        blinkTimer += deltaTime

        // Check if it's time to blink
        if !isBlinking && blinkTimer >= nextBlinkTime {
            isBlinking = true
            blinkProgress = 0
        }

        // Progress active blink
        if isBlinking {
            blinkProgress += deltaTime / blinkDuration

            if blinkProgress >= 1.0 {
                // Blink complete
                isBlinking = false
                blinkProgress = 0
                scheduleNextBlink()
            }
        }
    }

    private func scheduleNextBlink() {
        blinkTimer = 0
        nextBlinkTime = Float.random(in: blinkMinInterval...blinkMaxInterval)
    }

    // MARK: - Idle Smile

    private func updateIdleSmile(deltaTime: Float) {
        smileTimer += deltaTime

        // Check if it's time to smile
        if !isSmiling && smileTimer >= nextSmileTime {
            isSmiling = true
            smileProgress = 0
        }

        // Progress active smile
        if isSmiling {
            smileProgress += deltaTime / smileDuration

            if smileProgress >= 1.0 {
                isSmiling = false
                smileProgress = 0
                scheduleNextSmile()
            }
        }
    }

    private func scheduleNextSmile() {
        smileTimer = 0
        nextSmileTime = Float.random(in: smileMinInterval...smileMaxInterval)
    }
}
