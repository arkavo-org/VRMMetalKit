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
import XCTest
@testable import VRMAuthorKit

/// Shared fixtures for the native-anime-v1 suites.
enum NativeAnimeFixture {
    static let pack = NativeAnimeV1Pack()

    /// Template-only compile (body, head, eyes, rig, morphs): what the geometry,
    /// rig and morph suites inspect.
    static func compiled(_ mutate: (inout Recipe) -> Void = { _ in }) throws -> (avatar: CompiledAvatar, attachments: TemplateAttachments) {
        var recipe = pack.defaults
        mutate(&recipe)
        return try pack.compileTemplate(recipe, seed: 0)
    }

    /// Full compile including wearables and materials.
    static func integrated(_ mutate: (inout Recipe) -> Void = { _ in }) throws -> (avatar: CompiledAvatar, attachments: TemplateAttachments) {
        var recipe = pack.defaults
        mutate(&recipe)
        return try pack.compileWithAttachments(recipe, seed: 0)
    }

    static func primitive(_ avatar: CompiledAvatar, mesh: String, primitive: Int = 0) -> CompiledPrimitive {
        avatar.meshes.first { $0.id == mesh }!.primitives[primitive]
    }

    static func morph(_ prim: CompiledPrimitive, _ name: String) -> [SIMD3<Float>] {
        prim.morphTargets.first { $0.name == name }!.positionDeltas
    }
}

final class TemplatePackTests: XCTestCase {
    private let pack = NativeAnimeFixture.pack

    /// Cross-process pin of the default compile; verified identical over separate `swift test` invocations.
    static let goldenDefaultBuildHash = "7b9a28d3dbc13af012452f0639da60945322ce5a9ccce936c01f42f970518ae3"

    static let expectedKeys: [String] = {
        var keys = ["body.heightM", "body.headCount"]
        keys += ["shoulderWidth", "torsoLength", "armLength", "legLength", "hipWidth"].map { "body.proportion.\($0)" }
        keys += ["chest", "waist", "hip", "muscle"].map { "body.shape.\($0)" }
        keys += ["face.head.width", "face.head.depth", "face.jaw.width", "face.chin.length", "face.chin.pointedness"]
        for side in ["left", "right"] { keys += ["height", "width", "spacing", "tilt"].map { "face.eye.\(side).\($0)" } }
        for side in ["left", "right"] { keys.append("face.iris.\(side).size") }
        for side in ["left", "right"] { keys.append("face.pupil.\(side).size") }
        for side in ["left", "right"] { keys += ["height", "angle", "thickness"].map { "face.brow.\(side).\($0)" } }
        keys += ["face.nose.height", "face.nose.width", "face.nose.projection"]
        keys += ["face.mouth.width", "face.mouth.height", "face.lip.fullness"]
        for side in ["left", "right"] { keys += ["size", "angle"].map { "face.ear.\(side).\($0)" } }
        return keys
    }()

    func testPackIsRegisteredWithStableManifestHash() {
        let registry = TemplateRegistry.standard()
        XCTAssertEqual(registry.ids, ["native-anime-v1"])
        XCTAssertNotNil(registry.pack(id: "native-anime-v1"))
        XCTAssertTrue(SHA256Hex.isValid(pack.sha256))
        XCTAssertEqual(registry.templateHashes()["native-anime-v1"], pack.sha256)
        XCTAssertEqual(NativeAnimeV1Pack().sha256, pack.sha256)
        XCTAssertNotEqual(NativeAnimeV1Pack(items: [TemplateItem(id: "bob-v1", category: .hair, sha256: pack.sha256, controls: [])]).sha256, pack.sha256)
        XCTAssertEqual(pack.category, .avatar)
        XCTAssertEqual(pack.id, NativeAnimeV1Pack.packId)
    }

    func testControlTableMatchesParametersContract() {
        XCTAssertEqual(pack.controls.count, 44)
        XCTAssertEqual(pack.controls.map(\.key), Self.expectedKeys)
        XCTAssertEqual(Set(pack.controls.map(\.key)).count, 44)
        for d in pack.controls {
            XCTAssertEqual(d.validRange.count, 2, d.key)
            XCTAssertEqual(d.recommendedRange.count, 2, d.key)
            XCTAssertGreaterThanOrEqual(d.recommendedRange[0], d.validRange[0], d.key)
            XCTAssertLessThanOrEqual(d.recommendedRange[1], d.validRange[1], d.key)
            XCTAssertTrue(d.accepts(d.defaultValue), d.key)
            XCTAssertFalse(d.affects.isEmpty, d.key)
            XCTAssertFalse(d.dependencies.isEmpty, d.key)
            XCTAssertFalse(d.description.isEmpty, d.key)
            if d.key.contains(".left.") {
                XCTAssertEqual(d.side, .left, d.key)
                XCTAssertEqual(d.mirrorKey, d.key.replacingOccurrences(of: ".left.", with: ".right."), d.key)
            } else if d.key.contains(".right.") {
                XCTAssertEqual(d.side, .right, d.key)
                XCTAssertEqual(d.mirrorKey, d.key.replacingOccurrences(of: ".right.", with: ".left."), d.key)
            } else {
                XCTAssertEqual(d.side, .none, d.key)
                XCTAssertNil(d.mirrorKey, d.key)
            }
            XCTAssertNotNil(pack.control(d.key))
            if let mirror = d.mirrorKey { XCTAssertNotNil(pack.control(mirror), d.key) }
        }
        let height = pack.control("body.heightM")!
        XCTAssertEqual(height.unit, .metres)
        XCTAssertEqual(height.validRange, [1.2, 2.0])
        XCTAssertEqual(height.defaultValue, 1.65)
        XCTAssertTrue(height.dependencies.contains("rig"))
        XCTAssertTrue(height.dependencies.contains("fit"))
        XCTAssertTrue(height.dependencies.contains("springs"))
        let heads = pack.control("body.headCount")!
        XCTAssertEqual(heads.unit, .ratio)
        XCTAssertEqual(heads.validRange, [4.5, 8])
        XCTAssertEqual(heads.defaultValue, 6.3)
        for d in pack.controls where d.key.hasPrefix("face.iris.") || d.key.hasPrefix("face.pupil.") {
            XCTAssertEqual(d.unit, .normalized, d.key)
            XCTAssertEqual(d.validRange, [0, 1], d.key)
            XCTAssertTrue(d.affects.contains(.image), d.key)
        }
        for d in pack.controls where !["body.heightM", "body.headCount"].contains(d.key) && !d.key.hasPrefix("face.iris.") && !d.key.hasPrefix("face.pupil.") {
            XCTAssertEqual(d.unit, .normalized, d.key)
            XCTAssertEqual(d.validRange, [-1, 1], d.key)
            XCTAssertEqual(d.defaultValue, 0, d.key)
        }
        XCTAssertEqual(Set(NativeAnimeControls.regionMasks.keys), Set(Self.expectedKeys))
    }

    func testDefaultsAreCompleteAndDecodeThroughRecipeSchema() throws {
        let defaults = pack.defaults
        XCTAssertEqual(defaults.template.id, pack.id)
        XCTAssertEqual(defaults.template.sha256, pack.sha256)
        XCTAssertEqual(Set(defaults.body.keys), Set(Self.expectedKeys.filter { $0.hasPrefix("body.") }))
        XCTAssertEqual(Set(defaults.face.keys), Set(Self.expectedKeys.filter { $0.hasPrefix("face.") }))
        for d in pack.controls {
            let value = d.key.hasPrefix("body.") ? defaults.body[d.key] : defaults.face[d.key]
            XCTAssertEqual(value, d.defaultValue, d.key)
        }
        XCTAssertEqual(defaults.hair.map(\.preset), ["bob-v1"])
        XCTAssertEqual(defaults.outfits.map(\.preset), ["top-v1", "bottom-v1", "footwear-v1"])
        XCTAssertEqual(defaults.accessories, [])
        XCTAssertEqual(defaults.lookAt.type, .bone)
        let materialIds = Set(defaults.materials.map(\.id))
        for outfit in defaults.outfits { for m in outfit.materialIds { XCTAssertTrue(materialIds.contains(m), m) } }
        XCTAssertEqual(defaults.expressions.count, 14)
        XCTAssertEqual(Set(defaults.expressions.compactMap(\.preset)),
                       Set([.blink, .blinkLeft, .blinkRight, .aa, .ih, .ou, .ee, .oh, .happy, .angry, .sad, .relaxed, .surprised, .neutral]))
        XCTAssertEqual(defaults.style.sha256, NativeAnimeV1Pack.styleProfileSha256)
        XCTAssertNoThrow(try defaults.validate())
        let json = try defaults.jsonValue()
        let decoded = try Recipe.decode(json)
        XCTAssertEqual(decoded, defaults)
        let resolvedRoles = Set(defaults.materials.map(\.role))
        for role: MaterialRole in [.faceSkin, .bodySkin, .iris, .eyeWhite, .eyeHighlight, .eyeline, .eyelash, .brow, .mouth, .hair, .cloth] {
            XCTAssertTrue(resolvedRoles.contains(role), role.rawValue)
        }
    }

    func testCompileIsDeterministicAndSeedOnlyChangesTextures() throws {
        let a = try pack.compile(pack.defaults, seed: 0)
        let b = try pack.compile(pack.defaults, seed: 0)
        let c = try pack.compile(pack.defaults, seed: 42)
        XCTAssertEqual(a, b)
        XCTAssertEqual(try a.buildHash(), try b.buildHash())
        XCTAssertEqual(a.nodes, c.nodes)
        XCTAssertEqual(a.meshes, c.meshes)
        XCTAssertEqual(a.skins, c.skins)
        XCTAssertEqual(a.springs, c.springs)
        XCTAssertEqual(a.colliders, c.colliders)
        XCTAssertEqual(a.materials, c.materials)
        XCTAssertEqual(a.images.map(\.id), c.images.map(\.id))
        XCTAssertNotEqual(a.images, c.images)
        XCTAssertNotEqual(try a.buildHash(), try c.buildHash())
        XCTAssertEqual(try a.sorted().buildHash(), try a.buildHash())
        XCTAssertEqual(try a.buildHash(), TemplatePackTests.goldenDefaultBuildHash,
                       "default build hash changed across processes or geometry; update goldenDefaultBuildHash only for an intentional template change")
    }

    func testControlAtDefaultIsExactNoOp() throws {
        let baseline = try pack.compile(pack.defaults, seed: 0)
        var explicit = pack.defaults
        for d in pack.controls {
            if d.key.hasPrefix("body.") { explicit.body[d.key] = d.defaultValue } else { explicit.face[d.key] = d.defaultValue }
        }
        XCTAssertEqual(try pack.compile(explicit, seed: 0), baseline)
        var sparse = pack.defaults
        sparse.body = [:]
        sparse.face = [:]
        XCTAssertEqual(try pack.compile(sparse, seed: 0), baseline)
        var signedZero = pack.defaults
        signedZero.face["face.chin.length"] = -0.0
        XCTAssertEqual(try pack.compile(signedZero, seed: 0), baseline)
    }

    func testCompileRejectsUnknownKeysOutOfRangeAndWrongTemplate() throws {
        func code(_ mutate: (inout Recipe) -> Void) -> AuthorErrorCode? {
            var r = pack.defaults
            mutate(&r)
            do { _ = try pack.compile(r, seed: 0) } catch let e as AuthorError { return e.code } catch { return nil }
            return nil
        }
        XCTAssertEqual(code { $0.body["body.unknown"] = 1 }, .unknownField)
        XCTAssertEqual(code { $0.face["body.heightM"] = 1.6 }, .unknownField)
        XCTAssertEqual(code { $0.body["body.heightM"] = 2.5 }, .invalidRequest)
        XCTAssertEqual(code { $0.face["face.iris.left.size"] = -0.1 }, .invalidRequest)
        XCTAssertEqual(code { $0.face["face.chin.length"] = 1.5 }, .invalidRequest)
        XCTAssertEqual(code { $0.template = TemplateRef(id: "other", sha256: $0.template.sha256) }, .invalidRequest)
        XCTAssertEqual(code { $0.expressions[0].morphTargetBinds = [MorphTargetBind(mesh: "mesh.head", target: "nope", weight: 1)] }, .validationFailed)
        XCTAssertEqual(code { $0.expressions[0].morphTargetBinds = [MorphTargetBind(mesh: "mesh.nope", target: "blink", weight: 1)] }, .validationFailed)
    }

    func testTemplateCompileShapeAndMetadata() throws {
        let (avatar, attachments) = try NativeAnimeFixture.compiled()
        XCTAssertEqual(avatar.meshes.map(\.id), ["mesh.body", "mesh.head", "mesh.eyeL", "mesh.eyeR"])
        XCTAssertEqual(avatar.skins.count, 1)
        XCTAssertEqual(avatar.meshInstances.count, 4)
        for instance in avatar.meshInstances {
            XCTAssertEqual(instance.skinId, avatar.skins[0].id)
            XCTAssertTrue(avatar.nodes.contains { $0.id == instance.nodeId }, instance.nodeId)
            XCTAssertTrue(avatar.meshes.contains { $0.id == instance.meshId }, instance.meshId)
        }
        XCTAssertEqual(avatar.springs, [])
        XCTAssertEqual(avatar.colliders, [])
        XCTAssertEqual(avatar.colliderGroups, [])
        XCTAssertEqual(avatar.images, [])
        XCTAssertEqual(avatar.meta, pack.defaults.rights.meta)
        XCTAssertEqual(avatar.meta.thumbnailImage, NativeAnimeMaterials.thumbnailImageId)
        XCTAssertEqual(avatar.lookAt.type, .bone)
        XCTAssertEqual(avatar.lookAt.rangeMapHorizontalInner.inputMaxValue, 90)
        XCTAssertEqual(avatar.lookAt.rangeMapHorizontalInner.outputScale, 10)
        XCTAssertEqual(avatar.lookAt.rangeMapVerticalUp.inputMaxValue, 90)
        let annotations = Dictionary(uniqueKeysWithValues: avatar.firstPerson.meshAnnotations.map { ($0.mesh, $0.type) })
        XCTAssertEqual(annotations, ["mesh.body": .auto, "mesh.head": .auto, "mesh.eyeL": .thirdPersonOnly, "mesh.eyeR": .thirdPersonOnly])
        let materialIds = Set(avatar.materials.map(\.id))
        for mesh in avatar.meshes { for p in mesh.primitives { XCTAssertTrue(materialIds.contains(p.materialId), p.materialId) } }
        for id in NativeAnimeMaterials.templateIds { XCTAssertTrue(materialIds.contains(id), id) }
        let usedRoles = Set(avatar.meshes.flatMap { $0.primitives.map(\.materialId) }.compactMap { id in avatar.materials.first { $0.id == id }?.role })
        XCTAssertEqual(usedRoles, [.faceSkin, .bodySkin, .iris, .eyeWhite, .eyeHighlight, .eyeline, .eyelash, .brow, .mouth])
        for m in avatar.materials {
            XCTAssertNotNil(m.gltf["pbrMetallicRoughness"]?["baseColorFactor"]?.array, m.id)
            XCTAssertEqual(m.mtoon["specVersion"], "1.0", m.id)
            XCTAssertNoThrow(try m.validate())
        }
        XCTAssertEqual(attachments.bodyMeshId, "mesh.body")
        XCTAssertEqual(attachments.headMeshId, "mesh.head")
        XCTAssertEqual(attachments.eyeMeshIds, ["mesh.eyeL", "mesh.eyeR"])
        XCTAssertEqual(attachments.skinId, avatar.skins[0].id)
        XCTAssertEqual(attachments.heightM, 1.65)
        XCTAssertEqual(attachments.controlRegions.count, 44)
    }

    func testIntegratedCompileDressesTheTemplate() throws {
        let (avatar, attachments) = try NativeAnimeFixture.integrated()
        XCTAssertEqual(avatar.meshes.map(\.id), ["mesh.body", "mesh.eyeL", "mesh.eyeR", "mesh.head", "mesh:garment:outfit.bottom", "mesh:garment:outfit.footwear",
                                                 "mesh:garment:outfit.top", "mesh:hair:hair.main"])
        XCTAssertEqual(avatar.skins.map(\.id), ["skin.body", "skin:hair:hair.main"])
        XCTAssertEqual(avatar.meshInstances.count, 8)
        for instance in avatar.meshInstances {
            XCTAssertTrue(avatar.skins.contains { $0.id == instance.skinId }, instance.meshId)
            XCTAssertTrue(avatar.nodes.contains { $0.id == instance.nodeId }, instance.nodeId)
        }
        for garment in avatar.meshInstances where garment.meshId.hasPrefix("mesh:garment:") { XCTAssertEqual(garment.skinId, attachments.skinId) }
        XCTAssertEqual(avatar.springs.count, HairBobV1.Layout.clumpCount)
        XCTAssertEqual(Set(avatar.springs.map { $0.joints.count }), [HairBobV1.Layout.nodesPerClump])
        XCTAssertEqual(avatar.colliders.map(\.id), [HairBobV1.chestColliderId, HairBobV1.headColliderId, HairBobV1.neckColliderId])
        XCTAssertEqual(avatar.colliderGroups.map(\.id), [HairBobV1.bodyColliderGroupId, HairBobV1.headColliderGroupId])
        let head = avatar.colliders.first { $0.id == HairBobV1.headColliderId }!
        XCTAssertEqual(head.node, attachments.attachmentNodes["head"])
        let headRadius = try XCTUnwrap(head.shape.sphere?.radius)
        XCTAssertGreaterThan(headRadius, 0.05)
        XCTAssertLessThan(headRadius, 0.2)
        let nodeIds = Set(avatar.nodes.map(\.id))
        for spring in avatar.springs {
            for joint in spring.joints {
                XCTAssertTrue(nodeIds.contains(joint.node), joint.node)
                XCTAssertLessThanOrEqual(joint.stiffness, 4)
                XCTAssertLessThanOrEqual(joint.dragForce, 1)
                XCTAssertLessThanOrEqual(joint.gravityPower, 1)
                XCTAssertLessThanOrEqual(joint.hitRadius, 0.12)
            }
            let rootJoint = try XCTUnwrap(spring.joints.first)
            XCTAssertEqual(avatar.nodes.first { $0.id == rootJoint.node }?.parentId, attachments.attachmentNodes["head"], spring.id)
        }
        XCTAssertEqual(avatar.images.map(\.id), ["image:body_skin", "image:brow", "image:cloth.bottom", "image:cloth.footwear", "image:cloth.top", "image:eye_highlight", "image:eye_white", "image:eyelash", "image:eyeline",
                                                 NativeAnimeMaterials.faceImageId, NativeAnimeMaterials.hairImageId, "image:iris", "image:mouth", NativeAnimeMaterials.thumbnailImageId])
        for image in avatar.images { XCTAssertTrue(image.pngData.starts(with: [0x89, 0x50, 0x4E, 0x47]), image.id) }
        XCTAssertEqual(avatar.meta.thumbnailImage, NativeAnimeMaterials.thumbnailImageId)
        let imageIds = Set(avatar.images.map(\.id))
        for material in avatar.materials {
            XCTAssertEqual(material.gltf["name"], .string(NativeAnimeMaterials.names[material.id]!), material.id)
            let references = MaterialCompiler.textureReferences(of: material)
            XCTAssertFalse(references.isEmpty, material.id)
            for (slot, reference) in references { XCTAssertTrue(imageIds.contains(reference.imageId), "\(material.id) \(slot)") }
        }
        let hair = avatar.materials.first { $0.id == NativeAnimeMaterials.hair }!
        XCTAssertEqual(hair.gltf["pbrMetallicRoughness"]?["baseColorTexture"]?["imageId"], .string(NativeAnimeMaterials.hairImageId))
        let usedRoles = Set(avatar.meshes.flatMap { $0.primitives.map(\.materialId) }.compactMap { id in avatar.materials.first { $0.id == id }?.role })
        XCTAssertEqual(usedRoles, [.faceSkin, .bodySkin, .iris, .eyeWhite, .eyeHighlight, .eyeline, .eyelash, .brow, .mouth, .hair, .cloth])
        let annotations = Dictionary(uniqueKeysWithValues: avatar.firstPerson.meshAnnotations.map { ($0.mesh, $0.type) })
        XCTAssertEqual(annotations["mesh:hair:hair.main"], .thirdPersonOnly)
        XCTAssertEqual(annotations["mesh:garment:outfit.top"], .auto)
        XCTAssertEqual(annotations.count, avatar.meshes.count)
    }

    func testPlaceholderMaterialsAreOnlyAddedWhenMissing() throws {
        var recipe = pack.defaults
        recipe.materials = recipe.materials.filter { $0.id != NativeAnimeMaterials.mouth }
        var custom = NativeAnimeMaterials.placeholders.first { $0.id == NativeAnimeMaterials.faceSkin }!
        custom.gltf = custom.gltf.merging(["alphaMode": "MASK"])
        recipe.materials = recipe.materials.map { $0.id == custom.id ? custom : $0 }
        let avatar = try pack.compile(recipe, seed: 0)
        XCTAssertEqual(avatar.materials.filter { $0.id == NativeAnimeMaterials.mouth }.count, 1)
        XCTAssertEqual(avatar.materials.first { $0.id == NativeAnimeMaterials.faceSkin }?.gltf["alphaMode"], "MASK")
        XCTAssertEqual(avatar.materials.count, recipe.materials.count + 1)
    }
}
