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

public struct TemplateRef: AuthorModel {
    public var id: String
    public var sha256: String

    public init(id: String, sha256: String) {
        self.id = id
        self.sha256 = sha256
    }

    public static let modelName = "TemplateRef"
    public static let schema = JSONSchema.object(properties: ["id": .id, "sha256": .hash], required: ["id", "sha256"], description: "Pinned template pack")

    public func validate() throws {
        guard SHA256Hex.isValid(sha256) else { throw AuthorError.invalidRequest("Template sha256 must be lowercase hex.", path: "/sha256", observed: .string(sha256)) }
    }
}

public typealias ControlValues = [String: Double]

public struct Recipe: AuthorModel {
    public var schemaVersion: String
    public var name: String
    public var template: TemplateRef
    public var target: String
    public var seed: UInt64
    public var body: ControlValues
    public var face: ControlValues
    public var hair: [HairItem]
    public var outfits: [OutfitItem]
    public var accessories: [AccessoryItem]
    public var textures: [TextureLayer]
    public var materials: [MaterialObject]
    public var expressions: [ExpressionObject]
    public var lookAt: LookAtObject
    public var springs: [SpringObject]
    public var colliders: [ColliderObject]
    public var colliderGroups: [ColliderGroupObject]
    public var style: Blob
    public var rights: RightsDeclaration

    public static let currentSchemaVersion = "1.0"
    public static let portableTarget = "portable-vrm1"
    public static let maxSeed: UInt64 = 9_007_199_254_740_991

    public init(name: String, template: TemplateRef, target: String = Recipe.portableTarget, seed: UInt64 = 0, body: ControlValues, face: ControlValues,
                hair: [HairItem], outfits: [OutfitItem], accessories: [AccessoryItem] = [], textures: [TextureLayer], materials: [MaterialObject],
                expressions: [ExpressionObject], lookAt: LookAtObject, springs: [SpringObject], colliders: [ColliderObject],
                colliderGroups: [ColliderGroupObject], style: Blob, rights: RightsDeclaration) {
        self.schemaVersion = Recipe.currentSchemaVersion
        self.name = name
        self.template = template
        self.target = target
        self.seed = seed
        self.body = body
        self.face = face
        self.hair = hair
        self.outfits = outfits
        self.accessories = accessories
        self.textures = textures
        self.materials = materials
        self.expressions = expressions
        self.lookAt = lookAt
        self.springs = springs
        self.colliders = colliders
        self.colliderGroups = colliderGroups
        self.style = style
        self.rights = rights
    }

    public static let modelName = "Recipe"
    public static var schema: JSONSchema {
        JSONSchema.object(properties: [
            "schemaVersion": .const(.string(Recipe.currentSchemaVersion)),
            "name": .string(minLength: 1),
            "template": TemplateRef.schema,
            "target": .enumeration([Recipe.portableTarget]).defaulting(to: .string(Recipe.portableTarget)),
            "seed": .integer(minimum: 0, maximum: Int(Recipe.maxSeed)).defaulting(to: 0).described("uint53 deterministic seed"),
            "body": .map(of: .number().described("Body control value"), description: "body.* control values"),
            "face": .map(of: .number().described("Face control value"), description: "face.* control values"),
            "hair": .array(of: HairItem.schema),
            "outfits": .array(of: OutfitItem.schema),
            "accessories": .array(of: AccessoryItem.schema).defaulting(to: []),
            "textures": .array(of: TextureLayer.schema),
            "materials": .array(of: MaterialObject.schema),
            "expressions": .array(of: ExpressionObject.schema),
            "lookAt": LookAtObject.schema,
            "springs": .array(of: SpringObject.schema),
            "colliders": .array(of: ColliderObject.schema),
            "colliderGroups": .array(of: ColliderGroupObject.schema),
            "style": Blob.schema,
            "rights": RightsDeclaration.schema,
        ], required: ["schemaVersion", "name", "template", "body", "face", "hair", "outfits", "textures", "materials", "expressions", "lookAt",
                      "springs", "colliders", "colliderGroups", "style", "rights"], description: "Complete production recipe")
    }

    public func validate() throws {
        guard schemaVersion == Recipe.currentSchemaVersion else { throw AuthorError.invalidRequest("Unsupported recipe schemaVersion.", path: "/schemaVersion", observed: .string(schemaVersion)) }
        guard target == Recipe.portableTarget else { throw AuthorError.invalidRequest("Unsupported target.", path: "/target", observed: .string(target)) }
        guard seed <= Recipe.maxSeed else { throw AuthorError.invalidRequest("seed exceeds uint53.", path: "/seed") }
        try template.validate()
        for (k, v) in body { try ModelCheck.finite(v, "/body/\(JSONPointer.escape(k))") }
        for (k, v) in face { try ModelCheck.finite(v, "/face/\(JSONPointer.escape(k))") }
        for h in hair { try h.validate() }
        for o in outfits { try o.validate() }
        for a in accessories { try a.validate() }
        for t in textures { try t.validate() }
        for m in materials { try m.validate() }
        for e in expressions { try e.validate() }
        try lookAt.validate()
        for s in springs { try s.validate() }
        for c in colliders { try c.validate() }
        for g in colliderGroups { try g.validate() }
        try style.validate()
        try rights.validate()
        try ModelCheck.uniqueIds(hair.map(\.id) + outfits.map(\.id) + accessories.map(\.id) + textures.map(\.id) + materials.map(\.id)
                                 + expressions.map(\.id) + springs.map(\.id) + colliders.map(\.id) + colliderGroups.map(\.id), "/")
    }
}
