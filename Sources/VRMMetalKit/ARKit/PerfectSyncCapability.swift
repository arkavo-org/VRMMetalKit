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

/// Represents the model's Perfect Sync capability level.
///
/// Perfect Sync models have custom expressions named after ARKit blend shapes
/// (e.g., `eyeBlinkLeft`, `mouthSmileRight`), enabling 1:1 mapping for higher
/// fidelity facial animation than composite mapping.
///
/// ## Capability Levels
/// - `.none`: Standard VRM model with only preset expressions (18 VRM presets).
///   Uses composite mapping from 52 ARKit shapes to VRM expressions.
/// - `.partial`: Model has some ARKit-named custom expressions but not all 52.
///   Uses direct mapping for matched shapes, composite for the rest.
/// - `.full`: Model has all 52 ARKit blend shapes as custom expressions.
///   Uses direct 1:1 passthrough for maximum fidelity.
///
/// ## Naming Conventions
/// Different tools use different naming conventions:
/// - ARKit: `eyeBlinkLeft` (camelCase)
/// - VRoid/HANA_Tool: `EyeBlinkLeft` (PascalCase)
/// - Some tools: `eye_blink_left` (snake_case)
///
/// This implementation supports case-insensitive matching and maintains a
/// mapping from ARKit names to the model's actual expression names.
///
/// ## Usage
/// ```swift
/// let result = PerfectSyncCapability.detect(from: model)
/// switch result.capability {
/// case .full:
///     print("Full Perfect Sync - 52 direct mappings")
/// case .partial(let matched, let missing):
///     print("\(matched.count) direct, \(missing.count) composite")
/// case .none:
///     print("Standard composite mapping")
/// }
/// // Use result.nameMapping to get model's actual expression names
/// ```
public enum PerfectSyncCapability: Equatable, Sendable {
    case none
    case partial(matched: Set<String>, missing: Set<String>)
    case full

    /// Minimum number of matched ARKit shapes to qualify as partial Perfect Sync
    public static let partialThreshold = 30

    /// Result of Perfect Sync detection including capability and name mapping
    public struct DetectionResult: Sendable {
        /// The detected capability level
        public let capability: PerfectSyncCapability
        /// Mapping from ARKit names to model's actual expression names
        /// Key: ARKit canonical name (e.g., "eyeBlinkLeft")
        /// Value: Model's expression name (e.g., "EyeBlinkLeft")
        public let nameMapping: [String: String]
    }

    /// Detect capability from VRM model's custom expressions.
    ///
    /// Uses normalized matching to support different naming conventions:
    /// - camelCase: `eyeBlinkLeft` (ARKit)
    /// - PascalCase: `EyeBlinkLeft` (VRoid/HANA_Tool)
    /// - snake_case: `eye_blink_left`
    ///
    /// - Parameter model: The VRM model to analyze
    /// - Returns: Detection result with capability level and name mapping
    public static func detect(from model: VRMModel) -> DetectionResult {
        guard let expressions = model.expressions else {
            return DetectionResult(capability: .none, nameMapping: [:])
        }

        let arkitNames = ARKitFaceBlendShapes.allKeys
        let customNames = expressions.custom.keys

        // Build normalized lookup table: normalized -> original name
        // Normalization: lowercase + remove underscores
        var customLookup: [String: String] = [:]
        for name in customNames {
            customLookup[normalize(name)] = name
        }

        // Match ARKit names to model's expressions (normalized)
        var nameMapping: [String: String] = [:]
        for arkitName in arkitNames {
            let normalizedARKit = normalize(arkitName)
            if let modelName = customLookup[normalizedARKit] {
                nameMapping[arkitName] = modelName
            }
        }

        let matchedCount = nameMapping.count
        let matchedARKitNames = Set(nameMapping.keys)
        let missingARKitNames = Set(arkitNames).subtracting(matchedARKitNames)

        let capability: PerfectSyncCapability
        if matchedCount == arkitNames.count {
            capability = .full
        } else if matchedCount >= partialThreshold {
            capability = .partial(matched: matchedARKitNames, missing: missingARKitNames)
        } else {
            capability = .none
        }

        return DetectionResult(capability: capability, nameMapping: nameMapping)
    }

    /// Normalize a blend shape name for comparison.
    /// Converts to lowercase and removes underscores to match across conventions.
    private static func normalize(_ name: String) -> String {
        return name.lowercased().replacingOccurrences(of: "_", with: "")
    }

    /// Legacy detection method that returns only capability (for compatibility)
    @available(*, deprecated, message: "Use detect(from:) which returns DetectionResult with nameMapping")
    public static func detectCapabilityOnly(from model: VRMModel) -> PerfectSyncCapability {
        return detect(from: model).capability
    }

    /// Check if direct mapping should be used for a blend shape.
    ///
    /// - Parameter name: The ARKit blend shape name
    /// - Returns: `true` if this shape should use direct passthrough mapping
    public func usesDirectMapping(for name: String) -> Bool {
        switch self {
        case .none:
            return false
        case .partial(let matched, _):
            return matched.contains(name)
        case .full:
            return true
        }
    }

    /// Human-readable description for logging
    public var description: String {
        switch self {
        case .none:
            return "none (standard composite mapping)"
        case .partial(let matched, let missing):
            return "partial (\(matched.count) direct, \(missing.count) composite)"
        case .full:
            return "full (52 direct mappings)"
        }
    }

    /// Number of shapes that use direct mapping
    public var directMappingCount: Int {
        switch self {
        case .none:
            return 0
        case .partial(let matched, _):
            return matched.count
        case .full:
            return ARKitFaceBlendShapes.allKeys.count
        }
    }
}
