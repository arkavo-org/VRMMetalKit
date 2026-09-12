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

/// The v1 native anime template: an original stylized low-poly body and head
/// built from lofted cross-sections, sculpted globe eyes with closing lids, a
/// lip ring with an inner mouth, the full VRM 1.0 humanoid rig with
/// distance-based skin weights, blink/viseme/emotion morphs, bone-mode lookAt
/// and first-person annotations.
///
/// The compile then dresses the template: the wearable compiler adds the
/// recipe's hair, garments and accessories (with their spring chains and
/// colliders) and the material compiler resolves every material and renders
/// its textures. Geometry is seed-independent; `seed` only drives texture noise.
public struct NativeAnimeV1Pack: TemplatePack {
    public static let packId = "native-anime-v1"
    public static let version = "1.0.0"
    public static let bodyMeshId = "mesh.body"
    public static let headMeshId = "mesh.head"
    public static let eyeLeftMeshId = "mesh.eyeL"
    public static let eyeRightMeshId = "mesh.eyeR"
    public static let styleProfilePath = "docs/style/profiles/vroid-lineage-anime.json"
    public static let styleProfileSha256 = "7eeb1f41bada650d39b7c32a31c273bbd889cca22d390164b8a7dd9b1f9c1f35"
    static let manifestPlaceholderHash = String(repeating: "0", count: 64)

    public let id = NativeAnimeV1Pack.packId
    public let items: [TemplateItem]
    public let controls: [ControlDescriptor]
    public let sha256: String
    public let defaults: Recipe

    /// Every image id the compile emits for the default recipe: the explicitly
    /// authored face/hair/thumbnail/garment images, plus the role-default
    /// images MaterialCompiler adds for the template's other materials
    /// (body skin, eyes, brow, mouth). Kept in sync with compile by a test
    /// asserting equality with a compiled avatar's `images`, rather than a
    /// hand-maintained list that could drift.
    public var imageIds: Set<String> {
        var ids: Set<String> = [NativeAnimeMaterials.faceImageId, NativeAnimeMaterials.hairImageId, NativeAnimeMaterials.thumbnailImageId]
        ids.formUnion(NativeAnimeMaterials.garmentPalettes.keys)
        for (materialId, role) in NativeAnimeMaterials.roles where NativeAnimeMaterials.templateIds.contains(materialId) && materialId != NativeAnimeMaterials.faceSkin {
            ids.insert(MaterialRoleDefaults.imageId(for: role))
        }
        return ids
    }

    /// Constructs the pack. `items` lists installable hair/outfit/accessory presets;
    /// the manifest (and therefore `sha256`) covers them.
    public init(items: [TemplateItem] = []) {
        self.items = items
        controls = NativeAnimeControls.descriptors
        let placeholder = NativeAnimeV1Pack.makeDefaults(templateHash: NativeAnimeV1Pack.manifestPlaceholderHash)
        let manifest = try! NativeAnimeV1Pack.manifest(controls: controls, items: items, defaults: placeholder)
        sha256 = try! CanonicalJSON.sha256(manifest)
        defaults = NativeAnimeV1Pack.makeDefaults(templateHash: sha256)
    }

    /// Canonical manifest: pack identity, control table, item presets, the
    /// resolved defaults (with the template hash blanked) and geometry constants.
    static func manifest(controls: [ControlDescriptor], items: [TemplateItem], defaults: Recipe) throws -> JSONValue {
        .object([
            "id": .string(packId),
            "version": .string(version),
            "controls": .array(try controls.map { try JSONValue.from($0) }),
            "controlRegions": .object(NativeAnimeControls.regionMasks.mapValues { JSONValue($0) }),
            "items": .array(try items.map { try JSONValue.from($0) }),
            "defaults": try defaults.jsonValue(),
            "morphs": JSONValue(NativeAnimeMorphNames.all),
            "constants": [
                "torsoSegments": .number(Double(NativeAnimeBodyBuilder.torsoSegments)),
                "limbSegments": .number(Double(NativeAnimeBodyBuilder.limbSegments)),
                "handSegments": .number(Double(NativeAnimeBodyBuilder.handSegments)),
                "shellSegments": .number(Double(NativeAnimeHeadBuilder.shellSegments)),
                "shellRings": .number(Double(NativeAnimeHeadBuilder.shellRings)),
                "lidColumns": .number(Double(NativeAnimeHeadBuilder.lidColumns)),
                "lipColumns": .number(Double(NativeAnimeHeadBuilder.lipColumns)),
                "eyeSegments": .number(Double(NativeAnimeEyeBuilder.segments)),
                "irisUVRadius": .number(NativeAnimeEyeBuilder.irisUVRadius),
                "pupilUVRadius": .number(NativeAnimeEyeBuilder.pupilUVRadius),
            ],
        ])
    }

    static func makeDefaults(templateHash: String) -> Recipe {
        let skinTone = Colour(rgba: [0.35, 0.22, 0.15, 1])
        let hair = HairItem(id: "hair.main", preset: "bob-v1", controls: HairControls(widthScale: 1.25),
                            texture: HairTexture(baseColour: skinTone, rootColour: Colour(rgba: [0.28, 0.17, 0.12, 1]), tipColour: Colour(rgba: [0.42, 0.28, 0.20, 1])))
        let outfits = [
            OutfitItem(id: "outfit.top", preset: "top-v1", layer: 1, materialIds: [NativeAnimeMaterials.clothTop]),
            OutfitItem(id: "outfit.bottom", preset: "bottom-v1", layer: 0, materialIds: [NativeAnimeMaterials.clothBottom]),
            OutfitItem(id: "outfit.footwear", preset: "footwear-v1", layer: 0, materialIds: [NativeAnimeMaterials.clothFootwear]),
        ]
        let meta = VRMMeta(name: "Native Anime Avatar", version: version, authors: ["native-anime-v1"], thumbnailImage: NativeAnimeMaterials.thumbnailImageId,
                           licenseUrl: VRMMeta.vrm10LicenseUrl)
        let rights = RightsDeclaration(id: "rights.native-anime-v1", declarant: "native-anime-v1", evidence: [], authors: meta.authors, meta: meta)
        return Recipe(name: "Native Anime Avatar", template: TemplateRef(id: packId, sha256: templateHash), body: NativeAnimeControls.defaultBody,
                      face: NativeAnimeControls.defaultFace, hair: [hair], outfits: outfits, accessories: [], textures: [],
                      materials: NativeAnimeMaterials.placeholders, expressions: NativeAnimeExpressions.defaults, lookAt: LookAtObject(),
                      springs: [], colliders: [], colliderGroups: [], style: Blob(path: styleProfilePath, sha256: styleProfileSha256), rights: rights)
    }

    public func compile(_ recipe: Recipe, seed: UInt64) throws -> CompiledAvatar {
        try compileWithAttachments(recipe, seed: seed).avatar
    }

    /// Compiles the recipe (template body/face, then wearables and materials)
    /// and returns the semantic attachment data alongside the dressed avatar.
    public func compileWithAttachments(_ recipe: Recipe, seed: UInt64) throws -> (avatar: CompiledAvatar, attachments: TemplateAttachments) {
        let (template, attachments) = try compileTemplate(recipe, seed: seed)
        let host = try NativeAnimeWearableHost(avatar: template, attachments: attachments)
        var materialsById: [String: MaterialRole] = [:]
        for material in template.materials { materialsById[material.id] = material.role }
        let wearables = try WearableCompiler.compile(host: host, hair: recipe.hair, outfits: recipe.outfits, accessories: recipe.accessories,
                                                     materialsById: materialsById)
        var avatar = wearables.merged(into: template)
        var annotations = avatar.firstPerson.meshAnnotations
        for mesh in wearables.meshes where !annotations.contains(where: { $0.mesh == mesh.id }) {
            annotations.append(MeshAnnotation(mesh: mesh.id, type: mesh.id.hasPrefix("mesh:hair:") ? .thirdPersonOnly : .auto))
        }
        avatar.firstPerson.meshAnnotations = annotations

        let hairTexture = CompiledAvatar.sortedById(recipe.hair, \.id).first?.texture ?? Self.makeDefaults(templateHash: sha256).hair[0].texture
        let scalpUnderlay = recipe.hair.isEmpty ? nil : hairTexture
        let headSkin = template.meshes.first { $0.id == Self.headMeshId }!.primitives[HeadPrimitive.skin.rawValue]
        let scalp = Set(attachments.indices(of: "scalp", mesh: Self.headMeshId) + attachments.indices(of: "nape", mesh: Self.headMeshId))
        // Cheek anchors: below and outside each eye, mapped to the nearest
        // face-region vertex's UV so the blush lands on the shell's face band.
        let faceVerts = attachments.indices(of: "face", mesh: Self.headMeshId)
        let cheekUVs: [SIMD2<Float>] = attachments.eyes.compactMap { eye in
            let sign: Float = eye.side == "left" ? 1 : -1
            let anchor = eye.center + SIMD3(sign * 1.55 * eye.lidRadius, -1.15 * eye.lidRadius, 0.25 * eye.lidRadius)
            var best = -1, bestD = Float.infinity
            for v in faceVerts where v < headSkin.positions.count && v < headSkin.uv0.count {
                let d = V3.distance(headSkin.positions[v], anchor)
                if d < bestD { bestD = d; best = v }
            }
            return best >= 0 ? headSkin.uv0[best] : nil
        }
        let faceSize = MaterialRoleDefaults.imageSize(for: .faceSkin)
        let clothSize = MaterialRoleDefaults.imageSize(for: .cloth)
        var images = [
            ImageSpec(id: NativeAnimeMaterials.faceImageId, width: faceSize, height: faceSize, colourSpace: .srgb, usage: .colour),
            ImageSpec(id: NativeAnimeMaterials.hairImageId, width: NativeAnimeTextures.hairImageSize, height: NativeAnimeTextures.hairImageSize, colourSpace: .srgb, usage: .colour),
            ImageSpec(id: NativeAnimeMaterials.thumbnailImageId, width: NativeAnimeTextures.thumbnailSize, height: NativeAnimeTextures.thumbnailSize, colourSpace: .srgb, usage: .colour),
        ]
        var sources: [String: RasterImage] = [
            NativeAnimeMaterials.faceImageId: NativeAnimeTextures.faceRaster(head: headSkin, scalp: scalp, cheeks: cheekUVs, hair: scalpUnderlay, seed: seed),
            NativeAnimeMaterials.hairImageId: NativeAnimeTextures.hairRaster(texture: hairTexture, seed: seed),
            NativeAnimeMaterials.thumbnailImageId: NativeAnimeTextures.thumbnailRaster(hair: hairTexture, skin: MaterialRoleDefaults.baseColour(for: .faceSkin)),
        ]
        for (imageId, palette) in NativeAnimeMaterials.garmentPalettes {
            images.append(ImageSpec(id: imageId, width: clothSize, height: clothSize, colourSpace: .srgb, usage: .colour))
            sources[imageId] = MaterialRoleDefaults.raster(for: .cloth, base: palette, width: clothSize, height: clothSize, seed: seed)
        }
        let compiled = try MaterialCompiler.compile(materials: avatar.materials, textures: recipe.textures, images: images, seed: seed, sources: sources)
        avatar.images = compiled.images
        avatar.materials = compiled.materials
        return (avatar.sorted(), attachments)
    }

    /// The template alone: body, head and eye meshes, rig, morphs, lookAt,
    /// first-person annotations and the recipe's (unresolved) materials, with
    /// no images, wearables, springs or colliders.
    func compileTemplate(_ recipe: Recipe, seed: UInt64) throws -> (avatar: CompiledAvatar, attachments: TemplateAttachments) {
        guard recipe.template.id == id else {
            throw AuthorError.invalidRequest("Recipe targets template '\(recipe.template.id)', not '\(id)'.", path: "/template/id",
                                             observed: .string(recipe.template.id), required: .string(id))
        }
        let controls = try NativeAnimeControlSet(body: recipe.body, face: recipe.face)
        let layout = NativeAnimeLayout(controls: controls)

        var body = NativeAnimeBodyBuilder(layout: layout).build()
        var headParts = NativeAnimeHeadBuilder(layout: layout).build()
        let eyeLeft = NativeAnimeEyeBuilder(eye: layout.eyes["left"]!).build()
        let eyeRight = NativeAnimeEyeBuilder(eye: layout.eyes["right"]!).build()

        NativeAnimeShapeOffsets(layout: layout, controls: controls, handles: headParts.handles).apply(body: &body, head: &headParts.primitives)

        let rig = NativeAnimeRig(layout: layout, handles: headParts.handles)
        let morphs = NativeAnimeMorphBuilder(layout: layout, handles: headParts.handles, head: headParts.primitives).build()

        let bodySkin = rig.bodySkinning(body)
        let bodyMesh = CompiledMesh(id: Self.bodyMeshId, name: "Body", primitives: [
            body.emit(materialId: NativeAnimeMaterials.bodySkin, joints: bodySkin.joints, weights: bodySkin.weights, morphs: []),
        ])
        var headPrims: [CompiledPrimitive] = []
        for (pi, prim) in headParts.primitives.enumerated() {
            let skin = rig.rigidSkinning(prim, bone: .head)
            headPrims.append(prim.emit(materialId: HeadPrimitive(rawValue: pi)!.materialId, joints: skin.joints, weights: skin.weights, morphs: morphs[pi]))
        }
        let headMesh = CompiledMesh(id: Self.headMeshId, name: "Head", primitives: headPrims)
        func eyeMesh(_ parts: [BuildMesh], id: String, name: String, bone: VRMHumanBone, eye: NativeAnimeLayout.EyeParams) -> CompiledMesh {
            let looks = NativeAnimeMorphBuilder.lookTargets(prims: parts, eye: eye)
            return CompiledMesh(id: id, name: name, primitives: parts.enumerated().map { pi, prim in
                let skin = rig.rigidSkinning(prim, bone: bone)
                return prim.emit(materialId: EyePrimitive(rawValue: pi)!.materialId, joints: skin.joints, weights: skin.weights, morphs: looks[pi])
            })
        }
        let eyeLeftMesh = eyeMesh(eyeLeft, id: Self.eyeLeftMeshId, name: "EyeL", bone: .leftEye, eye: layout.eyes["left"]!)
        let eyeRightMesh = eyeMesh(eyeRight, id: Self.eyeRightMeshId, name: "EyeR", bone: .rightEye, eye: layout.eyes["right"]!)
        let meshes = [bodyMesh, headMesh, eyeLeftMesh, eyeRightMesh]

        let nodes = rig.nodes()
        let skin = rig.skin()
        let instances = [
            CompiledMeshInstance(nodeId: NativeAnimeNodes.bodyMesh, meshId: Self.bodyMeshId, skinId: skin.id),
            CompiledMeshInstance(nodeId: NativeAnimeNodes.headMesh, meshId: Self.headMeshId, skinId: skin.id),
            CompiledMeshInstance(nodeId: NativeAnimeNodes.eyeLeftMesh, meshId: Self.eyeLeftMeshId, skinId: skin.id),
            CompiledMeshInstance(nodeId: NativeAnimeNodes.eyeRightMesh, meshId: Self.eyeRightMeshId, skinId: skin.id),
        ]
        var humanoid: [VRMHumanBone: String] = [:]
        for bone in NativeAnimeRig.bones { humanoid[bone] = NativeAnimeNodes.bone(bone) }

        let expressions = try Self.validatedExpressions(recipe.expressions, meshes: meshes)
        let eyeMid = (layout.eyes["left"]!.center + layout.eyes["right"]!.center) * 0.5 - layout.joint(.head)
        var lookAt = recipe.lookAt
        lookAt.type = .bone
        lookAt.offsetFromHeadBone = [eyeMid.x, eyeMid.y, eyeMid.z]
        let firstPerson = FirstPersonObject(meshAnnotations: [
            MeshAnnotation(mesh: Self.bodyMeshId, type: .auto),
            MeshAnnotation(mesh: Self.headMeshId, type: .auto),
            MeshAnnotation(mesh: Self.eyeLeftMeshId, type: .thirdPersonOnly),
            MeshAnnotation(mesh: Self.eyeRightMeshId, type: .thirdPersonOnly),
        ])
        var materials = recipe.materials
        let present = Set(materials.map(\.id))
        for placeholder in NativeAnimeMaterials.placeholders where NativeAnimeMaterials.templateIds.contains(placeholder.id) && !present.contains(placeholder.id) {
            materials.append(placeholder)
        }

        let avatar = CompiledAvatar(nodes: nodes, meshes: meshes, skins: [skin], meshInstances: instances, images: [], materials: materials,
                                    humanoid: humanoid, expressions: expressions, lookAt: lookAt, firstPerson: firstPerson, springs: [], colliders: [],
                                    colliderGroups: [], meta: recipe.rights.meta)
        let attachments = Self.attachments(layout: layout, body: body, head: headParts, eyeLeft: eyeLeft, eyeRight: eyeRight, headHandles: headParts.handles,
                                           headMesh: headMesh)
        return (avatar, attachments)
    }

    static func validatedExpressions(_ expressions: [ExpressionObject], meshes: [CompiledMesh]) throws -> [ExpressionObject] {
        var targets: [String: Set<String>] = [:]
        for mesh in meshes {
            targets[mesh.id] = Set(mesh.primitives.first?.morphTargets.map(\.name) ?? [])
        }
        for (ei, e) in expressions.enumerated() {
            for (bi, bind) in e.morphTargetBinds.enumerated() {
                guard let names = targets[bind.mesh] else {
                    throw AuthorError(code: .validationFailed, objectId: e.id, path: "/expressions/\(ei)/morphTargetBinds/\(bi)/mesh", observed: .string(bind.mesh),
                                      required: JSONValue(meshes.map(\.id)), message: "Expression '\(e.id)' binds a mesh the template does not compile.",
                                      suggestedCommands: ["object get --id \(e.id)"])
                }
                guard names.contains(bind.target) else {
                    throw AuthorError(code: .validationFailed, objectId: e.id, path: "/expressions/\(ei)/morphTargetBinds/\(bi)/target", observed: .string(bind.target),
                                      required: JSONValue(names.sorted()), message: "Expression '\(e.id)' binds morph '\(bind.target)' which mesh '\(bind.mesh)' does not carry.",
                                      suggestedCommands: ["object get --id \(e.id)"])
                }
            }
        }
        return expressions
    }

    static func attachments(layout: NativeAnimeLayout, body: BuildMesh, head: HeadParts, eyeLeft: [BuildMesh], eyeRight: [BuildMesh],
                            headHandles: HeadHandles, headMesh: CompiledMesh) -> TemplateAttachments {
        var regions: [String: [TemplateAttachments.RegionRef]] = [:]
        func collect(_ mesh: BuildMesh, meshId: String, primitive: Int) {
            for name in mesh.regions.keys.sorted() {
                let indices = Array(Set(mesh.regions[name]!)).sorted()
                regions[name, default: []].append(TemplateAttachments.RegionRef(meshId: meshId, primitiveIndex: primitive, indices: indices))
            }
        }
        collect(body, meshId: bodyMeshId, primitive: 0)
        for (pi, prim) in head.primitives.enumerated() { collect(prim, meshId: headMeshId, primitive: pi) }
        for (pi, prim) in eyeLeft.enumerated() { collect(prim, meshId: eyeLeftMeshId, primitive: pi) }
        for (pi, prim) in eyeRight.enumerated() { collect(prim, meshId: eyeRightMeshId, primitive: pi) }

        let skinPrim = headMesh.primitives[HeadPrimitive.skin.rawValue]
        let scalp = Array(Set(head.primitives[HeadPrimitive.skin.rawValue].indices(in: "scalp"))).sorted()
        let scalpSamples = scalp.map { TemplateAttachments.SurfaceSample(position: skinPrim.positions[$0], normal: skinPrim.normals[$0], vertexIndex: $0) }

        var lidEdges: [String: TemplateAttachments.RegionRef] = [:]
        for side in ["left", "right"] {
            let sfx = NativeAnimeControls.suffix(side)
            let verts = headHandles.lids[side] ?? []
            let upper = verts.filter { $0.upper && $0.row == 0 && $0.primitive == HeadPrimitive.eyelash.rawValue }.sorted { $0.column < $1.column }
            let lower = verts.filter { !$0.upper && $0.row == 0 && $0.primitive == HeadPrimitive.eyeline.rawValue }.sorted { $0.column < $1.column }
            lidEdges["upper\(sfx)"] = TemplateAttachments.RegionRef(meshId: headMeshId, primitiveIndex: HeadPrimitive.eyelash.rawValue, indices: upper.map(\.index))
            lidEdges["lower\(sfx)"] = TemplateAttachments.RegionRef(meshId: headMeshId, primitiveIndex: HeadPrimitive.eyeline.rawValue, indices: lower.map(\.index))
        }

        let eyes = ["left", "right"].map { side -> TemplateAttachments.EyeGeometry in
            let e = layout.eyes[side]!
            return TemplateAttachments.EyeGeometry(side: side, meshId: side == "left" ? eyeLeftMeshId : eyeRightMeshId,
                                                   boneNodeId: NativeAnimeNodes.bone(side == "left" ? .leftEye : .rightEye), center: NAMath.f(e.center),
                                                   globeRadius: Float(e.globeRadius), lidRadius: Float(e.lidRadius), openingHalfWidth: Float(e.openingHalfWidth),
                                                   upperOpeningHeight: Float(e.upperHeight), lowerOpeningHeight: Float(e.lowerHeight),
                                                   irisAngleRadians: Float(e.irisAngle), pupilAngleRadians: Float(e.pupilAngle),
                                                   irisUVRadius: Float(NativeAnimeEyeBuilder.irisUVRadius), pupilUVRadius: Float(NativeAnimeEyeBuilder.pupilUVRadius))
        }

        let attachmentNodes: [String: String] = [
            "root": NativeAnimeNodes.root,
            "hips": NativeAnimeNodes.bone(.hips),
            "spine": NativeAnimeNodes.bone(.spine),
            "chest": NativeAnimeNodes.bone(.chest),
            "upperChest": NativeAnimeNodes.bone(.upperChest),
            "neck": NativeAnimeNodes.bone(.neck),
            "head": NativeAnimeNodes.bone(.head),
            "leftEye": NativeAnimeNodes.bone(.leftEye),
            "rightEye": NativeAnimeNodes.bone(.rightEye),
            "leftHand": NativeAnimeNodes.bone(.leftHand),
            "rightHand": NativeAnimeNodes.bone(.rightHand),
            "leftFoot": NativeAnimeNodes.bone(.leftFoot),
            "rightFoot": NativeAnimeNodes.bone(.rightFoot),
            "earLeft": NativeAnimeNodes.earLeft,
            "earRight": NativeAnimeNodes.earRight,
            "glasses": NativeAnimeNodes.glasses,
        ]

        var joints: [VRMHumanBone: SIMD3<Float>] = [:]
        for (bone, p) in layout.joints { joints[bone] = NAMath.f(p) }

        return TemplateAttachments(regions: regions, scalpSamples: scalpSamples, attachmentNodes: attachmentNodes, eyes: eyes,
                                   controlRegions: NativeAnimeControls.regionMasks, lidEdges: lidEdges, bodyMeshId: bodyMeshId, headMeshId: headMeshId,
                                   eyeMeshIds: [eyeLeftMeshId, eyeRightMeshId], skinId: NativeAnimeNodes.skin, jointWorldPositions: joints,
                                   heightM: Float(layout.height), headHeightM: Float(layout.headHeight), headCenter: NAMath.f(layout.headCenter),
                                   headRadii: NAMath.f(layout.headRadii))
    }
}
