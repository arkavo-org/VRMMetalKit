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
    /// The detected Perfect Sync capability level
    public let capability: PerfectSyncCapability

    /// Mapping from ARKit names to model's actual expression names
    /// Key: ARKit canonical name (e.g., "eyeBlinkLeft")
    /// Value: Model's expression name (e.g., "EyeBlinkLeft")
    public let nameMapping: [String: String]

    /// Fallback mapper for composite expressions (used in .none and .partial modes)
    public let fallbackMapper: ARKitToVRMMapper

    /// Initialize with capability, name mapping, and optional fallback mapper.
    ///
    /// - Parameters:
    ///   - capability: The model's Perfect Sync capability level
    ///   - nameMapping: Mapping from ARKit names to model's expression names
    ///   - fallbackMapper: Mapper to use for composite expressions (default: `.default`)
    public init(
        capability: PerfectSyncCapability,
        nameMapping: [String: String] = [:],
        fallbackMapper: ARKitToVRMMapper = .default
    ) {
        self.capability = capability
        self.nameMapping = nameMapping
        self.fallbackMapper = fallbackMapper
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

        case .partial(let matched, _):
            for arkitKey in matched {
                let modelKey = nameMapping[arkitKey] ?? arkitKey
                customWeights[modelKey] = blendShapes.weight(for: arkitKey)
            }
            presetWeights = fallbackMapper.evaluate(blendShapes)

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
            return weights

        case .partial(let matched, _):
            var weights: [String: Float] = [:]
            for arkitKey in matched {
                let modelKey = nameMapping[arkitKey] ?? arkitKey
                weights[modelKey] = blendShapes.weight(for: arkitKey)
            }
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

        case .partial, .none:
            return fallbackMapper.evaluate(blendShapes)
        }
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
