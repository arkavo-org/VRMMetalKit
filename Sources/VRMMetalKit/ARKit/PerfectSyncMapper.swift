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

/// Mapper for Perfect Sync models providing direct ARKit → custom expression passthrough.
///
/// Perfect Sync enables 1:1 mapping of ARKit's 52 facial blend shapes to VRM avatar
/// expressions. This provides much higher fidelity facial animation compared to
/// the standard composite mapping that collapses 52 shapes down to 18 VRM presets.
///
/// ## Pipeline
/// ```
/// ARKit (52 blend shapes) → PerfectSyncMapper →
///   - Full: Direct 1:1 passthrough to custom expressions
///   - Partial: Direct for matched + composite for presets
///   - None: Standard composite mapping (18 VRM presets)
/// ```
///
/// ## Naming Convention Support
/// Different VRM tools use different naming conventions:
/// - ARKit: `eyeBlinkLeft` (camelCase)
/// - VRoid/HANA_Tool: `EyeBlinkLeft` (PascalCase)
///
/// The mapper uses a name mapping to translate between ARKit names and
/// the model's actual expression names.
///
/// ## Usage
/// ```swift
/// let result = PerfectSyncCapability.detect(from: model)
/// let mapper = PerfectSyncMapper(
///     capability: result.capability,
///     nameMapping: result.nameMapping
/// )
///
/// let (custom, preset) = mapper.evaluate(blendShapes)
/// // custom: Uses model's actual expression names (e.g., "EyeBlinkLeft")
/// // preset: Composite mappings for standard VRM expressions
/// ```
public struct PerfectSyncMapper: Sendable {
    /// ARKit blend shape channels that directly drive jaw/mouth deformation.
    public static let directMouthKeys: Set<String> = [
        ARKitFaceBlendShapes.jawOpen,
        ARKitFaceBlendShapes.mouthFunnel,
        ARKitFaceBlendShapes.mouthPucker,
        ARKitFaceBlendShapes.mouthSmileLeft,
        ARKitFaceBlendShapes.mouthSmileRight,
        ARKitFaceBlendShapes.mouthStretchLeft,
        ARKitFaceBlendShapes.mouthStretchRight,
        ARKitFaceBlendShapes.mouthFrownLeft,
        ARKitFaceBlendShapes.mouthFrownRight,
        ARKitFaceBlendShapes.mouthLowerDownLeft,
        ARKitFaceBlendShapes.mouthLowerDownRight,
        ARKitFaceBlendShapes.mouthUpperUpLeft,
        ARKitFaceBlendShapes.mouthUpperUpRight,
    ]

    /// The detected Perfect Sync capability level
    public let capability: PerfectSyncCapability

    /// Mapping from ARKit names to model's actual expression names
    /// Key: ARKit canonical name (e.g., "eyeBlinkLeft")
    /// Value: Model's expression name (e.g., "EyeBlinkLeft")
    public let nameMapping: [String: String]

    /// Fallback mapper for composite expressions (used in .none and .partial modes)
    public let fallbackMapper: ARKitToVRMMapper

    /// Groups of custom/preset expressions that bind to the same `(meshIndex, morphIndex)`
    /// on the bound model, mapped to their relative bind weights.
    public let sharedBindGroups: [[String: Float]]

    /// Initialize with capability, name mapping, and optional fallback mapper.
    ///
    /// - Parameters:
    ///   - capability: The model's Perfect Sync capability level
    ///   - nameMapping: Mapping from ARKit names to model's expression names
    ///   - fallbackMapper: Mapper to use for composite expressions (default: `.default`)
    ///   - sharedBindGroups: Optional groups of expression names sharing a morph bind
    public init(
        capability: PerfectSyncCapability,
        nameMapping: [String: String] = [:],
        fallbackMapper: ARKitToVRMMapper = .default,
        sharedBindGroups: [[String: Float]] = []
    ) {
        self.capability = capability
        self.nameMapping = nameMapping
        self.fallbackMapper = fallbackMapper
        self.sharedBindGroups = sharedBindGroups
    }

    /// Evaluate blend shapes and return separate custom and preset weights.
    ///
    /// - Parameter blendShapes: ARKit face blend shape data
    /// - Returns: Tuple of (custom expression weights, preset expression weights)
    ///
    /// ## Return Values
    /// - `custom`: Dictionary using model's expression names (not ARKit names) to weights.
    ///   Empty for `.none` capability.
    /// - `preset`: Dictionary of VRM preset names to weights from composite mapping.
    ///   Empty for `.full` capability.
    public func evaluate(_ blendShapes: ARKitFaceBlendShapes) -> (
        custom: [String: Float],
        preset: [String: Float]
    ) {
        var customWeights: [String: Float] = [:]
        var presetWeights: [String: Float] = [:]

        switch capability {
        case .full:
            // Use name mapping to translate ARKit names to model's names
            for arkitKey in ARKitFaceBlendShapes.allKeys {
                let modelKey = nameMapping[arkitKey] ?? arkitKey
                customWeights[modelKey] = blendShapes.weight(for: arkitKey)
            }
            applySharedBindBudget(custom: &customWeights, preset: &presetWeights)

        case .partial(let matched, _):
            for arkitKey in matched {
                let modelKey = nameMapping[arkitKey] ?? arkitKey
                customWeights[modelKey] = blendShapes.weight(for: arkitKey)
            }
            presetWeights = evaluatePartialPresets(blendShapes, matched: matched)
            applySharedBindBudget(custom: &customWeights, preset: &presetWeights)

        case .none:
            presetWeights = fallbackMapper.evaluate(blendShapes)
        }

        return (custom: customWeights, preset: presetWeights)
    }

    /// Evaluate only custom expression weights (direct mapping).
    ///
    /// More efficient than `evaluate()` when only custom weights are needed.
    ///
    /// - Parameter blendShapes: ARKit face blend shape data
    /// - Returns: Dictionary using model's expression names to weights
    public func evaluateCustomOnly(_ blendShapes: ARKitFaceBlendShapes) -> [String: Float] {
        switch capability {
        case .full:
            var weights: [String: Float] = [:]
            for arkitKey in ARKitFaceBlendShapes.allKeys {
                let modelKey = nameMapping[arkitKey] ?? arkitKey
                weights[modelKey] = blendShapes.weight(for: arkitKey)
            }
            var emptyPresets: [String: Float] = [:]
            applySharedBindBudget(custom: &weights, preset: &emptyPresets)
            return weights

        case .partial(let matched, _):
            var weights: [String: Float] = [:]
            for arkitKey in matched {
                let modelKey = nameMapping[arkitKey] ?? arkitKey
                weights[modelKey] = blendShapes.weight(for: arkitKey)
            }
            var emptyPresets: [String: Float] = [:]
            applySharedBindBudget(custom: &weights, preset: &emptyPresets)
            return weights

        case .none:
            return [:]
        }
    }

    /// Evaluate only preset expression weights (composite mapping).
    ///
    /// More efficient than `evaluate()` when only preset weights are needed.
    ///
    /// - Parameter blendShapes: ARKit face blend shape data
    /// - Returns: Dictionary of VRM preset names to weights
    public func evaluatePresetOnly(_ blendShapes: ARKitFaceBlendShapes) -> [String: Float] {
        switch capability {
        case .full:
            return [:]

        case .partial(let matched, _):
            return evaluatePartialPresets(blendShapes, matched: matched)

        case .none:
            return fallbackMapper.evaluate(blendShapes)
        }
    }

    private func evaluatePartialPresets(
        _ blendShapes: ARKitFaceBlendShapes,
        matched: Set<String>
    ) -> [String: Float] {
        // Build a per-preset filtered mapper that retains full `blendShapes` context for
        // gating/inhibitory channels (e.g. `jawOpen` gating `ee` or inhibiting `relaxed`)
        // while zeroing out matched primary channels so matched deformations never duplicate.
        let unmatchedShapes = blendShapes.shapes.filter { !matched.contains($0.key) }
        let unmatchedInput = ARKitFaceBlendShapes(
            timestamp: blendShapes.timestamp,
            shapes: unmatchedShapes,
            headTransform: blendShapes.headTransform
        )

        var partialMapper = fallbackMapper
        for (presetKey, formula) in fallbackMapper.mappings {
            if presetKey == "neutral" { continue }
            if let primaryKeys = fallbackMapper.knownPrimaryKeys(for: presetKey, formula: formula) {
                let unmatchedPrimary = primaryKeys.subtracting(matched)
                if unmatchedPrimary.isEmpty {
                    partialMapper.mappings[presetKey] = .custom { _ in 0.0 }
                } else if unmatchedPrimary.count < primaryKeys.count {
                    // Some primary drivers of this preset are matched (handled by custom expressions)
                    // and some are unmatched. Zero only the matched primary drivers so contextual/gating
                    // channels (not in `primaryKeys`) remain intact.
                    let matchedPrimary = primaryKeys.intersection(matched)
                    partialMapper.mappings[presetKey] = .custom { fullShapes in
                        var filtered = fullShapes.shapes
                        for key in matchedPrimary {
                            filtered.removeValue(forKey: key)
                        }
                        let contextInput = ARKitFaceBlendShapes(
                            timestamp: fullShapes.timestamp,
                            shapes: filtered,
                            headTransform: fullShapes.headTransform
                        )
                        return formula.evaluate(contextInput)
                    }
                }
            } else {
                // User-supplied `.custom` closure whose dependencies cannot be introspected:
                // evaluate against unmatched input only so matched channels never duplicate.
                partialMapper.mappings[presetKey] = .custom { _ in
                    formula.evaluate(unmatchedInput)
                }
            }
        }

        var presetWeights = partialMapper.evaluate(blendShapes)

        // Reserve mouth budget for matched direct jaw/mouth channels so unmatched
        // fallback mouth presets cannot stack on top of custom mouth deformation.
        let directMouthActivation = matched
            .intersection(Self.directMouthKeys)
            .map { blendShapes.weight(for: $0) }
            .max() ?? 0
        if directMouthActivation > 1e-4 {
            let remainingBudget = Swift.max(0, fallbackMapper.visemeBudget - directMouthActivation)
            var mouthKeys: [String] = []
            var fallbackMouthLoad: Float = 0
            for (key, weight) in presetWeights where weight > 1e-4 {
                let alpha = fallbackMapper.mouthOverlapWeights[key]
                    ?? (ARKitToVRMMapper.visemePresets.contains(key) ? 1.0 : 0.0)
                if alpha > 1e-4 {
                    mouthKeys.append(key)
                    fallbackMouthLoad += alpha * weight
                }
            }
            if remainingBudget <= 1e-4 {
                for key in mouthKeys {
                    presetWeights[key] = 0
                }
            } else if fallbackMouthLoad > remainingBudget {
                let scale = remainingBudget / fallbackMouthLoad
                for key in mouthKeys {
                    if let w = presetWeights[key] {
                        presetWeights[key] = w * scale
                    }
                }
            }
        }

        return presetWeights
    }

    private func applySharedBindBudget(
        custom: inout [String: Float],
        preset: inout [String: Float]
    ) {
        guard !sharedBindGroups.isEmpty else { return }
        // Compute per-key minimum scale across all groups first so results are order-independent.
        var keyScale: [String: Float] = [:]
        for group in sharedBindGroups {
            var activeKeys: [String] = []
            var groupLoad: Float = 0
            for (key, factor) in group where factor > 1e-4 {
                let w = custom[key] ?? preset[key] ?? 0
                if w > 1e-4 {
                    activeKeys.append(key)
                    groupLoad += factor * w
                }
            }
            guard activeKeys.count > 1, groupLoad > 1.0 else { continue }
            let scale = 1.0 / groupLoad
            for key in activeKeys {
                keyScale[key] = Swift.min(keyScale[key] ?? 1.0, scale)
            }
        }
        for (key, scale) in keyScale {
            if let cw = custom[key] {
                custom[key] = cw * scale
            }
            if let pw = preset[key] {
                preset[key] = pw * scale
            }
        }
    }

    /// Finds groups of custom and/or preset expressions on `model` that bind to the same `(meshIndex, morphIndex)`.
    public static func sharedBindGroups(for model: VRMModel) -> [[String: Float]] {
        guard let expressions = model.expressions else { return [] }
        struct MorphBindKey: Hashable, Comparable {
            let meshIndex: Int
            let morphIndex: Int

            static func < (lhs: MorphBindKey, rhs: MorphBindKey) -> Bool {
                if lhs.meshIndex != rhs.meshIndex { return lhs.meshIndex < rhs.meshIndex }
                return lhs.morphIndex < rhs.morphIndex
            }
        }
        var byTarget: [MorphBindKey: [String: Float]] = [:]
        for (preset, expr) in expressions.preset {
            for bind in expr.morphTargetBinds where abs(bind.weight) > 1e-5 {
                let key = MorphBindKey(meshIndex: bind.meshIndex, morphIndex: bind.index)
                let current = byTarget[key]?[preset.rawValue] ?? 0
                byTarget[key, default: [:]][preset.rawValue] = Swift.max(current, abs(bind.weight))
            }
        }
        for (name, expr) in expressions.custom {
            for bind in expr.morphTargetBinds where abs(bind.weight) > 1e-5 {
                let key = MorphBindKey(meshIndex: bind.meshIndex, morphIndex: bind.index)
                let current = byTarget[key]?[name] ?? 0
                byTarget[key, default: [:]][name] = Swift.max(current, abs(bind.weight))
            }
        }
        var groups: [[String: Float]] = []
        for targetKey in byTarget.keys.sorted() {
            guard let contributors = byTarget[targetKey], contributors.count > 1,
                  let maxBind = contributors.values.max(), maxBind > 1e-5 else { continue }
            var normalized: [String: Float] = [:]
            for (exprKey, weight) in contributors {
                normalized[exprKey] = weight / maxBind
            }
            groups.append(normalized)
        }
        return groups
    }

    /// Check if this mapper will produce any custom expression weights.
    public var hasCustomMappings: Bool {
        switch capability {
        case .none:
            return false
        case .partial, .full:
            return true
        }
    }

    /// Check if this mapper will produce any preset expression weights.
    public var hasPresetMappings: Bool {
        switch capability {
        case .full:
            return false
        case .partial, .none:
            return true
        }
    }
}
