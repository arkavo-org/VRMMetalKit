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

/// Result of compiling a recipe's materials, texture layers and image specs.
public struct MaterialCompilation: Sendable {
    public var images: [CompiledImage]
    public var materials: [CompiledMaterial]
    public var rasters: [String: RasterImage]
    public var imageSpecs: [ImageSpec]
    /// Material ID → role, frozen for the compiled report.
    public var roles: [String: MaterialRole]

    public init(images: [CompiledImage], materials: [CompiledMaterial], rasters: [String: RasterImage], imageSpecs: [ImageSpec], roles: [String: MaterialRole]) {
        self.images = images
        self.materials = materials
        self.rasters = rasters
        self.imageSpecs = imageSpecs
        self.roles = roles
    }
}

/// Compiles `materials` + `textures` + `images` into PNG-backed `CompiledImage`s
/// and fully resolved `CompiledMaterial`s. Role defaults fill every field the
/// recipe leaves absent, every leaf is validated against `MaterialObject.schema`
/// (unknown fields and unknown material extensions are rejected), and texture
/// slots must resolve to a compiled image with a compatible usage.
public enum MaterialCompiler {
    public static let version = "materials/1"
    public static let writablePointers = ["/role", "/gltf", "/mtoon"]

    public static func compile(materials: [MaterialObject], textures: [TextureLayer], images: [ImageSpec], seed: UInt64,
                               sources: [String: RasterImage] = [:]) throws -> MaterialCompilation {
        try ModelCheck.uniqueIds(materials.map(\.id), "/materials")
        try ModelCheck.uniqueIds(images.map(\.id), "/images")
        try ModelCheck.uniqueIds(textures.map(\.id), "/textures")

        var resolved: [MaterialObject] = []
        for material in materials {
            try validate(material, path: "/materials")
            resolved.append(try resolve(material))
        }

        var specs = images
        var specIds = Set(images.map(\.id))
        func ensureDefault(_ id: String) {
            guard !specIds.contains(id), sources[id] == nil, let role = MaterialRoleDefaults.role(forImageId: id) else { return }
            specs.append(MaterialRoleDefaults.imageSpec(for: role))
            specIds.insert(id)
        }
        for material in resolved {
            for (_, reference) in textureReferences(of: material) { ensureDefault(reference.imageId) }
        }
        for layer in textures { ensureDefault(layer.targetImage) }
        for layer in textures where !specIds.contains(layer.targetImage) {
            throw AuthorError(code: .validationFailed, objectId: layer.id, path: "/targetImage", observed: .string(layer.targetImage),
                              message: "Layer '\(layer.id)' targets image '\(layer.targetImage)' which is not declared.", suggestedCommands: ["object list"])
        }

        var rasters: [String: RasterImage] = sources
        var defaultRasters: [String: RasterImage] = [:]
        func resolveSource(_ id: String) -> RasterImage? {
            if let existing = rasters[id] { return existing }
            if let cached = defaultRasters[id] { return cached }
            guard let role = MaterialRoleDefaults.role(forImageId: id) else { return nil }
            let size = MaterialRoleDefaults.imageSize(for: role)
            let generated = MaterialRoleDefaults.raster(for: role, width: size, height: size, seed: seed)
            defaultRasters[id] = generated
            return generated
        }
        var compiledImages: [CompiledImage] = []
        for spec in specs {
            let violations = ImageSpec.schema.validate(try spec.jsonValue())
            if !violations.isEmpty {
                throw ModelValidationError(errors: violations.map { violation in
                    var error = violation.authorError
                    error.objectId = spec.id
                    error.path = "/images/" + spec.id + violation.pointer
                    return error
                })
            }
            var base: RasterImage?
            if let role = MaterialRoleDefaults.role(forImageId: spec.id) {
                base = MaterialRoleDefaults.raster(for: role, width: spec.width, height: spec.height, seed: seed)
            } else if let external = sources[spec.id] {
                base = external
            }
            let raster = try TextureCompositor.composite(spec: spec, layers: textures, base: base, sources: resolveSource)
            rasters[spec.id] = raster
            compiledImages.append(CompiledImage(id: spec.id, pngData: try raster.png(colourSpace: spec.colourSpace, usage: spec.usage), colourSpace: spec.colourSpace, usage: spec.usage))
        }

        let specById = Dictionary(uniqueKeysWithValues: specs.map { ($0.id, $0) })
        for material in resolved {
            try checkSlots(of: material, specs: specById)
            try checkRenderQueue(of: material)
        }

        let roles = Dictionary(uniqueKeysWithValues: resolved.map { ($0.id, $0.role) })
        return MaterialCompilation(images: CompiledAvatar.sortedById(compiledImages, \.id), materials: CompiledAvatar.sortedById(resolved, \.id),
                                   rasters: rasters, imageSpecs: CompiledAvatar.sortedById(specs, \.id), roles: roles)
    }

    // MARK: Validation and resolution

    public static func validate(_ material: MaterialObject, path: String = "") throws {
        let json = try material.jsonValue()
        let violations = MaterialObject.schema.validate(json)
        guard violations.isEmpty else {
            throw ModelValidationError(errors: violations.map { violation in
                var error = violation.authorError
                error.objectId = material.id
                error.path = path + "/" + material.id + (violation.pointer.isEmpty ? "" : violation.pointer)
                return error
            })
        }
        try material.validate()
    }

    /// Role defaults under the recipe's values, then schema defaults for the rest.
    public static func resolve(_ material: MaterialObject) throws -> MaterialObject {
        let gltf = MaterialSchemas.gltf.applyingDefaults(to: merge(base: MaterialRoleDefaults.gltf(for: material.role), over: material.gltf))
        let mtoon = MaterialSchemas.mtoon.applyingDefaults(to: merge(base: MaterialRoleDefaults.mtoon(for: material.role), over: material.mtoon))
        let out = MaterialObject(id: material.id, role: material.role, gltf: gltf, mtoon: mtoon)
        try validate(out, path: "/materials")
        return out
    }

    static func merge(base: JSONValue, over: JSONValue) -> JSONValue {
        guard var b = base.object, let o = over.object else { return over }
        for (key, value) in o { b[key] = merge(base: b[key] ?? .null, over: value) }
        return .object(b)
    }

    public struct TextureReference: Hashable, Sendable {
        public var imageId: String
        public var texCoord: Int
        public var transformTexCoord: Int?
    }

    /// Every populated texture slot as (pointer, reference).
    public static func textureReferences(of material: MaterialObject) -> [(String, TextureReference)] {
        let root: JSONValue = ["gltf": material.gltf, "mtoon": material.mtoon]
        var out: [(String, TextureReference)] = []
        for slot in MaterialSchemas.textureSlots {
            guard let pointer = try? JSONPointer(slot), let value = pointer.get(in: root), let imageId = value["imageId"]?.string else { continue }
            out.append((slot, TextureReference(imageId: imageId, texCoord: value["texCoord"]?.int ?? 0, transformTexCoord: value["transform"]?["texCoord"]?.int)))
        }
        return out
    }

    static func checkSlots(of material: MaterialObject, specs: [String: ImageSpec]) throws {
        for (slot, reference) in textureReferences(of: material) {
            guard let spec = specs[reference.imageId] else {
                throw AuthorError(code: .validationFailed, objectId: material.id, path: slot + "/imageId", observed: .string(reference.imageId),
                                  message: "Material '\(material.id)' slot \(slot) references image '\(reference.imageId)' which is not compiled.", suggestedCommands: ["object list"])
            }
            if reference.texCoord != 0 || (reference.transformTexCoord ?? 0) != 0 {
                throw AuthorError(code: .validationFailed, objectId: material.id, path: slot + "/texCoord", observed: .number(Double(reference.transformTexCoord ?? reference.texCoord)), required: 0,
                                  message: "Material '\(material.id)' slot \(slot) uses a UV set other than 0; v1 geometry carries TEXCOORD_0 only.", suggestedCommands: ["schema show Material"])
            }
            let isNormalSlot = slot == "/gltf/normalTexture"
            if isNormalSlot != (spec.usage == .normal) {
                throw AuthorError(code: .validationFailed, objectId: material.id, path: slot + "/imageId", observed: .string(spec.usage.rawValue), required: .string(isNormalSlot ? "normal" : "colour|mask"),
                                  message: "Material '\(material.id)' slot \(slot) references image '\(spec.id)' with usage \(spec.usage.rawValue).", suggestedCommands: ["schema show Image"])
            }
        }
    }

    static func checkRenderQueue(of material: MaterialObject) throws {
        guard material.gltf["alphaMode"]?.string == "BLEND" else { return }
        let zWrite = material.mtoon["transparentWithZWrite"]?.bool ?? false
        let offset = material.mtoon["renderQueueOffsetNumber"]?.int ?? 0
        let range = zWrite ? 0...9 : (-9)...0
        guard range.contains(offset) else {
            throw AuthorError(code: .validationFailed, objectId: material.id, path: "/mtoon/renderQueueOffsetNumber", observed: .number(Double(offset)),
                              required: [.number(Double(range.lowerBound)), .number(Double(range.upperBound))],
                              message: "BLEND material '\(material.id)' renderQueueOffsetNumber must be within \(range) when transparentWithZWrite is \(zWrite).",
                              suggestedCommands: ["object set"])
        }
    }

    // MARK: Project objects

    public static func projectObject(for material: MaterialObject, provenance: JSONValue, revision: Int = 0) throws -> ProjectObject {
        try ProjectObject(id: material.id, kind: .material, revision: revision, provenance: provenance, writablePointers: writablePointers,
                          fields: ["role": .string(material.role.rawValue), "gltf": material.gltf, "mtoon": material.mtoon])
    }

    public static func material(from object: ProjectObject) throws -> MaterialObject {
        guard object.kind == .material else {
            throw AuthorError(code: .invalidRequest, objectId: object.id, path: "/material", observed: .string(object.kind.rawValue), required: "material",
                              message: "Object '\(object.id)' is a \(object.kind.rawValue), not a material.", suggestedCommands: ["object list --kind material"])
        }
        var fields = object.fields
        fields["id"] = .string(object.id)
        return try MaterialObject.decode(.object(fields))
    }
}
