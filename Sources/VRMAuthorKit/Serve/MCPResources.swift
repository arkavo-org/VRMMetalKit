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

/// MCP resources: starter Recipe documents an agent reads, edits and passes
/// to `vrm_recipe apply`. They are generated from the installed pack on every
/// read, so `template.sha256` always matches the pack the session can build.
public enum MCPResources {
    public static let scheme = "recipe"
    public static let resourceNotFound = -32002
    public static let mimeType = "application/json"

    static let bases: [(uri: String, base: NativeAnimeStarterBase, description: String)] = [
        ("recipe://native-anime-v1/female", .female, "Female starter Recipe for the native-anime-v1 pack (seed 42): bob, top, skirt, footwear."),
        ("recipe://native-anime-v1/male", .male, "Male starter Recipe for the native-anime-v1 pack (seed 42): short bob, top, bottom, footwear."),
    ]

    public static var uris: [String] { bases.map(\.uri) }

    public static func list() -> JSONValue {
        ["resources": .array(bases.map { entry in
            ["uri": .string(entry.uri), "name": .string(entry.base.rawValue), "title": .string("Starter recipe: \(entry.base.rawValue)"),
             "description": .string(entry.description), "mimeType": .string(mimeType)]
        })]
    }

    public static func read(uri: String, templates: TemplateRegistry) throws -> JSONValue {
        guard let entry = bases.first(where: { $0.uri == uri }) else {
            throw RPCError(code: resourceNotFound, message: "Resource not found: \(uri)", data: ["availableResources": JSONValue(uris)])
        }
        let recipe: Recipe
        do { recipe = try NativeAnimeStarters.starterRecipe(base: entry.base, registry: templates) }
        catch let error as AuthorError { throw RPCError(code: RPCError.internalError, message: error.message, data: ["code": .string(error.code.rawValue)]) }
        let text = try CanonicalJSON.string(try recipe.jsonValue())
        return ["contents": [["uri": .string(uri), "mimeType": .string(mimeType), "text": .string(text)]]]
    }
}
