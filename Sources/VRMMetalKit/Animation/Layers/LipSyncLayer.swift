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

/// LipSyncLayer manages viseme (mouth shape) animations for speech.
///
/// This layer receives viseme weights from external lip sync systems (like the Muse app)
/// and outputs them through the animation layer system. This ensures visemes are
/// properly composited with other expression layers and reach the expression controller.
///
/// ## Usage
///
/// ```swift
/// let lipSyncLayer = LipSyncLayer()
/// compositor.addLayer(lipSyncLayer)
///
/// // During speech, set visemes based on audio analysis
/// lipSyncLayer.setViseme(.aa, weight: 0.8)
/// lipSyncLayer.setViseme(.ih, weight: 0.3)
/// ```
///
/// ## Viseme Presets
///
/// VRM defines 5 viseme presets for lip sync:
/// - `aa`: Mouth open wide (as in "father")
/// - `ih`: Mouth slightly open, teeth visible (as in "bit")
/// - `ou`: Lips rounded (as in "boot")
/// - `ee`: Mouth spread wide (as in "beet")
/// - `oh`: Lips rounded, mouth open (as in "boat")
///
/// ## Thread Safety
///
/// **NOT thread-safe.** All methods should be called from the main thread,
/// typically within the animation update loop.
public final class LipSyncLayer: AnimationLayer {
    public let identifier = "lipSync"

    /// Higher priority than ExpressionLayer (1) to ensure visemes take precedence
    public let priority = 10

    public var isEnabled = true

    /// Lip sync uses morph targets only, no bones
    public var affectedBones: Set<VRMHumanoidBone> { [] }

    // MARK: - Viseme State

    /// Current target viseme weights (set externally)
    private var targetVisemeWeights: [String: Float] = [:]

    /// Current actual viseme weights (after smoothing)
    private var currentVisemeWeights: [String: Float] = [:]

    // MARK: - Configuration

    /// Speed of viseme transitions (higher = faster)
    public var transitionSpeed: Float = 20.0

    /// Pre-allocated output to avoid per-frame allocations
    private var cachedOutput = LayerOutput(blendMode: .additive)

    // MARK: - Initialization

    public init() {}

    // MARK: - Public API

    /// Set a viseme weight by preset.
    ///
    /// The weight is applied immediately for responsive lip sync.
    /// When setting to 0, the weight will decay naturally rather than snapping.
 /// Smoothing/decay happens automatically when visemes are cleared.
    ///
    /// - Parameters:
    ///   - viseme: The viseme preset (aa, ih, ou, ee, oh)
    ///   - weight: The weight in range [0, 1], will be clamped
    public func setViseme(_ viseme: VRMExpressionPreset, weight: Float) {
        guard isViseme(viseme) else { return }
        let clampedWeight = clamp(weight, min: 0, max: 1)
        let name = viseme.rawValue
        targetVisemeWeights[name] = clampedWeight

        // Apply immediately for positive weights, allow decay for zero
        if clampedWeight > 0 {
            currentVisemeWeights[name] = clampedWeight
        }
        // If weight is 0, we only update target, allowing natural decay in update()
    }

    /// Set a viseme weight by name.
    ///
    /// This method allows setting visemes using string names, which is useful
    /// when integrating with external lip sync systems that use string identifiers.
    /// The weight is applied immediately for responsive lip sync.
    /// When setting to 0, the weight will decay naturally rather than snapping.
    ///
    /// - Parameters:
    ///   - name: The viseme name ("aa", "ih", "ou", "ee", "oh", or custom)
    ///   - weight: The weight in range [0, 1], will be clamped
    public func setViseme(named name: String, weight: Float) {
        let clampedWeight = clamp(weight, min: 0, max: 1)
        targetVisemeWeights[name] = clampedWeight

        // Apply immediately for positive weights, allow decay for zero
        if clampedWeight > 0 {
            currentVisemeWeights[name] = clampedWeight
        }
        // If weight is 0, we only update target, allowing natural decay in update()
    }

    /// Clear all viseme weights.
    ///
    /// Call this when speech ends to reset the mouth to neutral.
    /// This immediately clears both target and current weights.
    public func clearAllVisemes() {
        targetVisemeWeights.removeAll(keepingCapacity: true)
        currentVisemeWeights.removeAll(keepingCapacity: true)
    }

    /// Remove a specific viseme.
    ///
    /// - Parameter name: The viseme name to remove
    public func clearViseme(named name: String) {
        targetVisemeWeights.removeValue(forKey: name)
    }

    /// Get the current weight for a viseme.
    ///
    /// - Parameter name: The viseme name
    /// - Returns: The current weight, or 0 if not set
    public func weight(for name: String) -> Float {
        return currentVisemeWeights[name] ?? 0
    }

    // MARK: - AnimationLayer Protocol

    public func update(deltaTime: Float, context: AnimationContext) {
        // Smooth transitions to target weights
        for (name, targetWeight) in targetVisemeWeights {
            let currentWeight = currentVisemeWeights[name] ?? 0
            let diff = targetWeight - currentWeight

            if abs(diff) < 0.001 {
                currentVisemeWeights[name] = targetWeight
            } else {
                let step = diff * min(1.0, transitionSpeed * deltaTime)
                currentVisemeWeights[name] = currentWeight + step
            }
        }

        // Remove visemes that are no longer targeted and have decayed to near-zero
        var visemesToRemove: [String] = []
        for (name, currentWeight) in currentVisemeWeights {
            if targetVisemeWeights[name] == nil && currentWeight < 0.001 {
                visemesToRemove.append(name)
            }
        }
        for name in visemesToRemove {
            currentVisemeWeights.removeValue(forKey: name)
        }
    }

    public func evaluate() -> LayerOutput {
        // Clear previous morphs
        cachedOutput.morphWeights.removeAll(keepingCapacity: true)

        // Add all current viseme weights to output
        for (name, weight) in currentVisemeWeights where weight > 0.001 {
            cachedOutput.morphWeights[name] = weight
        }

        return cachedOutput
    }

    // MARK: - Private Methods

    private func isViseme(_ preset: VRMExpressionPreset) -> Bool {
        switch preset {
        case .aa, .ih, .ou, .ee, .oh:
            return true
        default:
            return false
        }
    }
}

// MARK: - Helper Functions

private func clamp(_ value: Float, min: Float, max: Float) -> Float {
    return Swift.max(min, Swift.min(max, value))
}
