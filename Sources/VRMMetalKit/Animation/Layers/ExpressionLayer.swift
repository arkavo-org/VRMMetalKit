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
    public var transitionSpeed: Float = 3.0

    // MARK: - Private State

    private var currentExpression: VRMExpressionPreset = .neutral
    private var currentIntensity: Float = 0
    private var targetIntensity: Float = 0

    // Blink state
    private var blinkTimer: Float = 0
    private var nextBlinkTime: Float = 3.0
    private var blinkProgress: Float = 0
    private var isBlinking = false

    // Pre-allocated output
    private var cachedOutput = LayerOutput(blendMode: .additive)

    // MARK: - Initialization

    public init() {
        scheduleNextBlink()
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

    // MARK: - AnimationLayer Protocol

    public func update(deltaTime: Float, context: AnimationContext) {
        // Update expression from context sentiment if provided
        if let preset = context.sentimentPreset {
            currentExpression = preset
            targetIntensity = context.sentimentIntensity
        }

        // Smooth intensity transition
        let diff = targetIntensity - currentIntensity
        currentIntensity += diff * min(1.0, transitionSpeed * deltaTime)

        // Clamp very small values to zero
        if abs(currentIntensity) < 0.001 {
            currentIntensity = 0
        }

        // Update blink animation
        if blinkEnabled {
            updateBlink(deltaTime: deltaTime)
        }
    }

    public func evaluate() -> LayerOutput {
        // Clear previous morphs
        cachedOutput.morphWeights.removeAll(keepingCapacity: true)

        // Apply current expression
        if currentIntensity > 0.01 {
            cachedOutput.morphWeights[currentExpression.rawValue] = currentIntensity
        }

        // Apply blink (bell curve: 0 → 1 → 0)
        if isBlinking {
            // Use sine for smooth bell curve
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
}
