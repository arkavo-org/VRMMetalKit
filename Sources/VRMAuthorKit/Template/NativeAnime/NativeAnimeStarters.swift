//
// Copyright 2026 Arkavo
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

public enum NativeAnimeStarterBase: String, CaseIterable, Sendable {
    case female, male
}

/// Two human bases over the native-anime pack defaults. Each is the default
/// recipe with seed 42, the base's name and an ordered override table applied
/// by JSON pointer; every pointer must already exist in the default recipe.
public enum NativeAnimeStarters {
    public static let seed: UInt64 = 42

    public static func overrides(for base: NativeAnimeStarterBase) -> [(pointer: String, value: JSONValue)] {
        switch base {
        case .female:
            return [
                ("/body/body.heightM", 1.60), ("/body/body.headCount", 6.6),
                ("/body/body.proportion.shoulderWidth", -0.20), ("/body/body.proportion.hipWidth", 0.30),
                ("/body/body.proportion.torsoLength", 0),
                ("/body/body.shape.chest", 0.45), ("/body/body.shape.waist", -0.35), ("/body/body.shape.hip", 0.35), ("/body/body.shape.muscle", -0.10),
                ("/face/face.jaw.width", -0.25), ("/face/face.chin.length", -0.15), ("/face/face.chin.pointedness", 0.20),
                ("/face/face.eye.left.height", 0.25), ("/face/face.eye.right.height", 0.25),
                ("/face/face.brow.left.thickness", -0.20), ("/face/face.brow.right.thickness", -0.20),
                ("/face/face.lip.fullness", 0.20),
                ("/hair/0/preset", "bob-v1"), ("/hair/0/controls/lengthM", 0.20), ("/hair/0/controls/tipBendDeg", 12),
                ("/outfits/1/preset", "skirt-v1"),
            ]
        case .male:
            return [
                ("/body/body.heightM", 1.74), ("/body/body.headCount", 7.2),
                ("/body/body.proportion.shoulderWidth", 0.45), ("/body/body.proportion.hipWidth", -0.20),
                ("/body/body.proportion.torsoLength", 0.10),
                ("/body/body.shape.chest", -0.10), ("/body/body.shape.waist", 0.10), ("/body/body.shape.hip", -0.15), ("/body/body.shape.muscle", 0.35),
                ("/face/face.jaw.width", 0.35), ("/face/face.chin.length", 0.20), ("/face/face.chin.pointedness", -0.10),
                ("/face/face.eye.left.height", -0.15), ("/face/face.eye.right.height", -0.15),
                ("/face/face.brow.left.thickness", 0.35), ("/face/face.brow.right.thickness", 0.35),
                ("/face/face.lip.fullness", -0.20),
                ("/hair/0/preset", "bob-v1"), ("/hair/0/controls/lengthM", 0.13), ("/hair/0/controls/tipBendDeg", 0),
                ("/outfits/1/preset", "bottom-v1"),
            ]
        }
    }

    public static func starterRecipe(base: NativeAnimeStarterBase, registry: TemplateRegistry) throws -> Recipe {
        guard let pack = registry.pack(id: NativeAnimeV1Pack.packId) else {
            throw AuthorError(code: .missingCapability, path: "/template", observed: .string(NativeAnimeV1Pack.packId),
                              message: "Template pack '\(NativeAnimeV1Pack.packId)' is not installed.", suggestedCommands: ["template list"])
        }
        var json = try pack.defaults.jsonValue()
        for override in overrides(for: base) {
            let pointer = try JSONPointer(override.pointer)
            guard pointer.get(in: json) != nil else {
                throw AuthorError(code: .internalError, path: override.pointer, message: "Starter override does not resolve in the pack default recipe.", suggestedCommands: ["template list"])
            }
            try pointer.set(in: &json, to: override.value)
        }
        var recipe = try Recipe.decode(json)
        recipe.seed = seed
        recipe.name = base.rawValue
        try recipe.validate()
        return recipe
    }
}
