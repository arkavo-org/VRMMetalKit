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

/// Character recipe - declarative format for VRM character creation
///
/// This format matches the training data used to fine-tune the VRM LLM.
/// The LLM can generate these recipes from natural language descriptions.
///
/// Example JSON:
/// ```json
/// {
///   "skeleton": "default_humanoid",
///   "morphs": {
///     "height": 1.15,
///     "muscle_definition": 0.7,
///     "shoulder_width": 1.1
///   },
///   "materials": {
///     "hairColor": [0.35, 0.25, 0.15],
///     "eyeColor": [0.2, 0.4, 0.8],
///     "skinTone": 0.5
///   },
///   "expressions": ["happy", "sad", "angry", "blink"]
/// }
/// ```
public struct CharacterRecipe: Codable {

    // MARK: - Properties

    /// Skeleton preset to use
    public var skeleton: String

    /// Morph target values (0.0-2.0 for most, 0.0-1.0 for percentages)
    public var morphs: [String: Float]

    /// Material configuration (colors, tones)
    public var materials: MaterialConfig

    /// Expression presets to include
    public var expressions: [String]

    /// Optional accessories
    public var accessories: AccessoryConfig?

    // MARK: - Initialization

    public init(
        skeleton: String = "default_humanoid",
        morphs: [String: Float] = [:],
        materials: MaterialConfig = MaterialConfig(),
        expressions: [String] = [],
        accessories: AccessoryConfig? = nil
    ) {
        self.skeleton = skeleton
        self.morphs = morphs
        self.materials = materials
        self.expressions = expressions
        self.accessories = accessories
    }

    // MARK: - Validation

    /// Validate the recipe against VRM constraints
    public func validate() throws {
        // Validate skeleton
        guard SkeletonPresetMapper.isValid(skeleton) else {
            throw RecipeError.invalidSkeleton(skeleton)
        }

        // Validate morph ranges
        for (name, value) in morphs {
            switch name {
            case "height":
                guard (0.5...2.0).contains(value) else {
                    throw RecipeError.morphOutOfRange(name, value, 0.5...2.0)
                }
            case "muscle_definition", "body_width", "shoulder_width":
                guard (0.5...2.0).contains(value) else {
                    throw RecipeError.morphOutOfRange(name, value, 0.5...2.0)
                }
            case "eye_size", "nose_size", "mouth_size", "jaw_width":
                guard (0.5...1.5).contains(value) else {
                    throw RecipeError.morphOutOfRange(name, value, 0.5...1.5)
                }
            case "face_roundness", "hair_length":
                guard (0.0...1.0).contains(value) else {
                    throw RecipeError.morphOutOfRange(name, value, 0.0...1.0)
                }
            default:
                // Unknown morph - warn but allow
                print("⚠️ Unknown morph target: \(name)")
            }
        }

        // Validate material colors (RGB values should be 0-1)
        try materials.validate()

        // Validate expressions
        for expr in expressions {
            guard ExpressionMapper.isValid(expr) else {
                throw RecipeError.invalidExpression(expr)
            }
        }
    }
}

// MARK: - Material Configuration

public struct MaterialConfig: Codable {
    /// Hair color (RGB 0-1)
    public var hairColor: [Float]

    /// Eye color (RGB 0-1)
    public var eyeColor: [Float]

    /// Skin tone (0 = lightest, 1 = darkest)
    public var skinTone: Float

    public init(
        hairColor: [Float] = [0.35, 0.25, 0.15], // Default brown
        eyeColor: [Float] = [0.4, 0.3, 0.2],     // Default brown
        skinTone: Float = 0.5                    // Default medium
    ) {
        self.hairColor = hairColor
        self.eyeColor = eyeColor
        self.skinTone = skinTone
    }

    func validate() throws {
        guard hairColor.count == 3, hairColor.allSatisfy({ (0...1).contains($0) }) else {
            throw RecipeError.invalidColor("hairColor", hairColor)
        }
        guard eyeColor.count == 3, eyeColor.allSatisfy({ (0...1).contains($0) }) else {
            throw RecipeError.invalidColor("eyeColor", eyeColor)
        }
        guard (0...1).contains(skinTone) else {
            throw RecipeError.invalidSkinTone(skinTone)
        }
    }

    var hairColorSIMD: SIMD3<Float> {
        SIMD3(hairColor[0], hairColor[1], hairColor[2])
    }

    var eyeColorSIMD: SIMD3<Float> {
        SIMD3(eyeColor[0], eyeColor[1], eyeColor[2])
    }
}

// MARK: - Accessory Configuration

public struct AccessoryConfig: Codable {
    public var glasses: Bool
    public var beard: Bool

    public init(glasses: Bool = false, beard: Bool = false) {
        self.glasses = glasses
        self.beard = beard
    }
}

// MARK: - Recipe Errors

public enum RecipeError: Error, LocalizedError {
    case invalidSkeleton(String)
    case morphOutOfRange(String, Float, ClosedRange<Float>)
    case invalidColor(String, [Float])
    case invalidSkinTone(Float)
    case invalidExpression(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSkeleton(let name):
            return "Invalid skeleton preset: '\(name)'. Valid options: default_humanoid, tall, short, stocky"
        case .morphOutOfRange(let name, let value, let range):
            return "Morph '\(name)' value \(value) is out of valid range \(range.lowerBound)...\(range.upperBound)"
        case .invalidColor(let name, let values):
            return "Invalid color '\(name)': \(values). RGB values must be 0-1 and have exactly 3 components"
        case .invalidSkinTone(let value):
            return "Invalid skin tone: \(value). Must be between 0.0 (lightest) and 1.0 (darkest)"
        case .invalidExpression(let name):
            return "Invalid expression preset: '\(name)'. Check VRM 1.0 expression presets"
        }
    }
}

// MARK: - Mappers

/// Maps recipe skeleton names to valid presets
public enum SkeletonPresetMapper {
    public static func isValid(_ name: String) -> Bool {
        let validSkeletons = ["default_humanoid", "default", "normal", "tall", "short", "stocky", "wide"]
        return validSkeletons.contains(name.lowercased())
    }
}

/// Maps recipe expression names to valid VRM expression presets
public enum ExpressionMapper {
    public static func isValid(_ name: String) -> Bool {
        let validExpressions = [
            "happy", "joy", "angry", "sad", "sorrow", "relaxed", "fun",
            "surprised", "aa", "a", "ih", "i", "ou", "u", "ee", "e", "oh", "o",
            "blink", "blinkleft", "blink_l", "blinkright", "blink_r",
            "lookup", "look_up", "lookdown", "look_down",
            "lookleft", "look_left", "lookright", "look_right", "neutral"
        ]
        return validExpressions.contains(name.lowercased())
    }
}

// MARK: - Convenience Initializers

public extension CharacterRecipe {

    /// Create a recipe from JSON string
    static func from(json: String) throws -> CharacterRecipe {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(CharacterRecipe.self, from: data)
    }

    /// Convert recipe to JSON string
    func toJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8)!
    }
}

// MARK: - Common Presets

public extension CharacterRecipe {

    /// Tall athletic warrior
    static var tallWarrior: CharacterRecipe {
        CharacterRecipe(
            skeleton: "tall",
            morphs: [
                "height": 1.15,
                "muscle_definition": 0.8,
                "shoulder_width": 1.15
            ],
            materials: MaterialConfig(
                hairColor: [0.1, 0.1, 0.1],      // Black
                eyeColor: [0.5, 0.4, 0.25],      // Hazel
                skinTone: 0.6                     // Medium-dark
            ),
            expressions: ["neutral", "angry", "happy", "blink"]
        )
    }

    /// Short slender mage
    static var slenderMage: CharacterRecipe {
        CharacterRecipe(
            skeleton: "short",
            morphs: [
                "height": 0.95,
                "muscle_definition": 0.3,
                "body_width": 0.85
            ],
            materials: MaterialConfig(
                hairColor: [0.9, 0.9, 0.9],      // White
                eyeColor: [0.6, 0.3, 0.8],       // Violet
                skinTone: 0.2                     // Pale
            ),
            expressions: ["neutral", "surprised", "happy", "blink"]
        )
    }

    /// Stocky dwarf blacksmith
    static var stockyBlacksmith: CharacterRecipe {
        CharacterRecipe(
            skeleton: "stocky",
            morphs: [
                "height": 0.85,
                "muscle_definition": 0.7,
                "shoulder_width": 1.3
            ],
            materials: MaterialConfig(
                hairColor: [0.65, 0.25, 0.15],   // Red
                eyeColor: [0.35, 0.25, 0.15],    // Brown
                skinTone: 0.5                     // Medium
            ),
            expressions: ["neutral", "angry", "relaxed", "blink"],
            accessories: AccessoryConfig(glasses: false, beard: true)
        )
    }
}
