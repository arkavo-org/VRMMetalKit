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

final class ModelTests: XCTestCase {
    private func code(_ block: () throws -> Void) -> AuthorErrorCode? {
        do { try block(); return nil } catch let e as AuthorError { return e.code } catch let e as ModelValidationError { return e.errors.first?.code } catch { return nil }
    }

    func testDefaultsFromSchemaAndUnknownKeysRejected() throws {
        let colour = try Colour.decode(["rgba": [1, 0.5, 0, 1]])
        XCTAssertEqual(colour.space, .linear)
        XCTAssertEqual(code { _ = try Colour.decode(["rgba": [1, 0.5, 0, 1], "alpha": 1]) }, .unknownField)
        XCTAssertEqual(code { _ = try Colour.decode(["rgba": [1, 0.5, 0]]) }, .invalidRequest)
        XCTAssertEqual(code { _ = try Colour.decode(["rgba": [1, 0.5, 0, 2]]) }, .invalidRequest)
        let hair = try HairControls.decode([:])
        XCTAssertEqual(hair.lengthM, 0.18)
        XCTAssertEqual(hair.tipBendDeg, 12)
        XCTAssertEqual(code { _ = try HairControls.decode(["lengthM": 0.5]) }, .invalidRequest)
        XCTAssertEqual(code { _ = try OutfitControls.decode(["fit": -1.5]) }, .invalidRequest)
        XCTAssertNoThrow(try OutfitControls.decode(["fit": -1, "length": 1]))
    }

    func testTransformRequiresUnitQuaternionAndPositiveScale() {
        XCTAssertNoThrow(try Transform.decode([:]))
        XCTAssertEqual(code { _ = try Transform.decode(["rotation": [0, 0, 0, 0.5]]) }, .invalidRequest)
        XCTAssertEqual(code { _ = try Transform.decode(["scale": [1, 0, 1]]) }, .invalidRequest)
        XCTAssertEqual(code { _ = try Transform.decode(["translation": [1, 2]]) }, .invalidRequest)
        XCTAssertEqual(code { try Transform(rotation: [Double.nan, 0, 0, 1]).validate() }, .invalidRequest)
    }

    func testLayerKindRequirements() {
        XCTAssertEqual(code { _ = try TextureLayer.decode(["id": "l", "targetImage": "i", "kind": "solid"]) }, .invalidRequest)
        XCTAssertEqual(code { _ = try TextureLayer.decode(["id": "l", "targetImage": "i", "kind": "image"]) }, .invalidRequest)
        XCTAssertNoThrow(try TextureLayer.decode(["id": "l", "targetImage": "i", "kind": "image", "image": "img"]))
        XCTAssertNoThrow(try TextureLayer.decode(["id": "l", "targetImage": "i", "kind": "solid", "colour": ["rgba": [0, 0, 0, 1]], "blend": "screen"]))
        XCTAssertEqual(code { _ = try TextureLayer.decode(["id": "l", "targetImage": "i", "kind": "solid", "colour": ["rgba": [0, 0, 0, 1]], "blend": "overlay"]) }, .invalidRequest)
    }

    func testExpressionExactlyOneOfPresetOrName() {
        XCTAssertNoThrow(try ExpressionObject.decode(["id": "e", "preset": "blink"]))
        XCTAssertNoThrow(try ExpressionObject.decode(["id": "e", "name": "custom"]))
        XCTAssertEqual(code { _ = try ExpressionObject.decode(["id": "e"]) }, .invalidRequest)
        XCTAssertEqual(code { _ = try ExpressionObject.decode(["id": "e", "preset": "blink", "name": "x"]) }, .invalidRequest)
        XCTAssertEqual(code { _ = try ExpressionObject.decode(["id": "e", "preset": "wink"]) }, .invalidRequest)
        XCTAssertEqual(ExpressionPreset.allCases.count, 18)
        let e = try? ExpressionObject.decode(["id": "e", "preset": "aa", "morphTargetBinds": [["mesh": "m", "target": "aa", "weight": 1]]])
        XCTAssertEqual(e?.overrideBlink, ExpressionOverride.none)
        XCTAssertEqual(e?.morphTargetBinds.count, 1)
    }

    func testSpringDefaultsAndConstraints() throws {
        let joint = try SpringJoint.decode(["node": "n"])
        XCTAssertEqual(joint.stiffness, 1)
        XCTAssertEqual(joint.dragForce, 0.5)
        XCTAssertEqual(joint.gravityDir, [0, -1, 0])
        XCTAssertNoThrow(try SpringJoint.decode(["node": "n", "stiffness": 40, "gravityPower": 3]))
        XCTAssertEqual(code { _ = try SpringJoint.decode(["node": "n", "dragForce": 1.5]) }, .invalidRequest)
        XCTAssertEqual(code { _ = try SpringObject.decode(["id": "s", "joints": [["node": "a"]]]) }, .invalidRequest)
        XCTAssertNoThrow(try SpringObject.decode(["id": "s", "joints": [["node": "a"], ["node": "tail"]]]))
        XCTAssertNoThrow(try ColliderObject.decode(["id": "c", "node": "n", "shape": ["sphere": ["radius": 0.1]]]))
        XCTAssertNoThrow(try ColliderObject.decode(["id": "c", "node": "n", "shape": ["capsule": ["radius": 0.1, "tail": [0, 0.1, 0]]]]))
        XCTAssertEqual(code { _ = try ColliderObject.decode(["id": "c", "node": "n", "shape": ["sphere": ["radius": 0.1], "capsule": ["radius": 0.1, "tail": [0, 0.1, 0]]]]) }, .invalidRequest)
        XCTAssertEqual(code { _ = try ColliderObject.decode(["id": "c", "node": "n", "shape": ["sphere": ["radius": -0.1]]]) }, .invalidRequest)
    }

    func testRightsDeclarationAndTrainingClaims() throws {
        let meta: JSONValue = ["name": "Avatar", "authors": ["Ada"]]
        let ok = try RightsDeclaration.decode(["id": "r", "declarant": "Ada", "evidence": [], "authors": ["Ada"], "meta": meta,
                                                "training": ["cawg.ai_training": ["use": "notAllowed"], "cawg.data_mining": ["use": "constrained", "constraint_info": "research only"]]])
        XCTAssertEqual(ok.meta.licenseUrl, VRMMeta.vrm10LicenseUrl)
        XCTAssertEqual(ok.meta.avatarPermission, .onlyAuthor)
        XCTAssertEqual(ok.meta.modification, .prohibited)
        XCTAssertEqual(ok.training?.aiTraining?.use, .notAllowed)
        XCTAssertNil(ok.training?.aiInference)
        let json = try ok.jsonValue()
        XCTAssertNotNil(json["training"]?["cawg.ai_training"])
        XCTAssertEqual(json["training"]?["cawg.data_mining"]?["constraint_info"], "research only")
        XCTAssertEqual(code { _ = try RightsDeclaration.decode(["id": "r", "declarant": "Ada", "evidence": [], "authors": ["Bob"], "meta": meta]) }, .validationFailed)
        XCTAssertEqual(code { _ = try TrainingClaims.decode(["cawg.ai_training": ["use": "constrained"]]) }, .invalidRequest)
        XCTAssertEqual(code { _ = try TrainingClaims.decode(["cawg.other": ["use": "allowed"]]) }, .unknownField)
        XCTAssertEqual(code { _ = try VRMMeta.decode(["name": "x", "authors": [], "licenseUrl": "u"]) }, .invalidRequest)
        XCTAssertEqual(code { _ = try VRMMeta.decode(["name": "x", "authors": ["a"], "commercialUsage": "yes"]) }, .invalidRequest)
        XCTAssertEqual(VRMMeta.schema.properties.count, 19)
    }

    func testQARequestIsExactlyOneForm() {
        XCTAssertNoThrow(try QARequest.decode(["file": "a.vrm", "suite": "spec+style"]))
        let sha: JSONValue = .string(String(repeating: "a", count: 64))
        XCTAssertNoThrow(try QARequest.decode(["plan": ["path": "p.json", "sha256": sha]]))
        XCTAssertNoThrow(try QARequest.decode(["acceptance": ["pack": ["path": "p.json", "sha256": sha], "candidateBuild": .string(String(repeating: "b", count: 64))]]))
        XCTAssertEqual(code { _ = try QARequest.decode(["file": "a.vrm"]) }, .invalidRequest)
        XCTAssertEqual(code { _ = try QARequest.decode(["file": "a.vrm", "suite": "spec+style", "plan": ["path": "p", "sha256": sha]]) }, .invalidRequest)
        XCTAssertEqual(code { _ = try QARequest.decode([:]) }, .invalidRequest)
        XCTAssertEqual(code { _ = try Blob.decode(["path": "p", "sha256": "ABC"]) }, .invalidRequest)
    }

    func testRecipeDecodesWithDefaultsAndRejectsDuplicateIds() throws {
        let sha = String(repeating: "c", count: 64)
        var recipe: JSONValue = [
            "schemaVersion": "1.0", "name": "A", "template": ["id": "native-anime-v1", "sha256": .string(sha)],
            "body": ["body.heightM": 1.65], "face": [:], "hair": [], "outfits": [], "textures": [], "materials": [], "expressions": [],
            "lookAt": [:], "springs": [], "colliders": [], "colliderGroups": [],
            "style": ["path": "s.json", "sha256": .string(sha)],
            "rights": ["id": "r", "declarant": "d", "evidence": [], "authors": ["d"], "meta": ["name": "A", "authors": ["d"]]],
        ]
        let decoded = try Recipe.decode(recipe)
        XCTAssertEqual(decoded.target, "portable-vrm1")
        XCTAssertEqual(decoded.seed, 0)
        XCTAssertEqual(decoded.accessories, [])
        XCTAssertEqual(decoded.lookAt.rangeMapVerticalUp.inputMaxValue, 90)
        XCTAssertEqual(decoded.lookAt.type, .bone)
        recipe = recipe.merging(["schemaVersion": "2.0"])
        XCTAssertEqual(code { _ = try Recipe.decode(recipe) }, .invalidRequest)
        recipe = recipe.merging(["schemaVersion": "1.0", "seed": 9007199254740992])
        XCTAssertEqual(code { _ = try Recipe.decode(recipe) }, .invalidRequest)
        recipe = recipe.merging(["seed": 1, "springs": [["id": "dup", "joints": [["node": "a"], ["node": "b"]]]], "colliderGroups": [["id": "dup", "colliders": []]]])
        XCTAssertEqual(code { _ = try Recipe.decode(recipe) }, .invalidRequest)
        recipe = recipe.merging(["colliderGroups": [], "body": ["body.heightM": "tall"]])
        XCTAssertEqual(code { _ = try Recipe.decode(recipe) }, .invalidRequest)
    }

    func testObjectAndControlEdits() {
        XCTAssertNoThrow(try ObjectEdit.decode(["id": "m", "values": ["/mtoon/shadingToonyFactor": 0.9]]))
        XCTAssertEqual(code { _ = try ObjectEdit.decode(["id": "m", "values": ["mtoon": 0.9]]) }, .invalidRequest)
        XCTAssertEqual(code { _ = try ObjectEdit.decode(["id": "m", "values": [:]]) }, .invalidRequest)
        XCTAssertEqual(code { _ = try ControlEdit.decode(["object": "a", "values": ["body.heightM": 1.7], "extra": 1]) }, .unknownField)
        XCTAssertEqual(ObjectKind.allCases.count, 16)
        XCTAssertEqual(ObjectKind.textureLayer.rawValue, "texture-layer")
        XCTAssertEqual(MaterialRole.allCases.count, 13)
    }

    func testHumanoidBonesAndCompiledAvatarHash() throws {
        XCTAssertEqual(VRMHumanBone.allCases.count, 55)
        XCTAssertEqual(VRMHumanBone.required.count, 15)
        XCTAssertTrue(VRMHumanBone.hips.isRequired)
        XCTAssertFalse(VRMHumanBone.leftEye.isRequired)
        let meta = VRMMeta(name: "A", authors: ["d"])
        let material = MaterialObject(id: "material:b", role: .bodySkin, gltf: ["alphaMode": "OPAQUE"], mtoon: ["shadingToonyFactor": 0.9])
        let image = CompiledImage(id: "image:a", pngData: Data([1, 2, 3]), colourSpace: .srgb, usage: .colour)
        let primitive = CompiledPrimitive(materialId: "material:b", positions: [SIMD3(0, 0.1, 0)], normals: [SIMD3(0, 1, 0)], uv0: [SIMD2(0.5, 0.5)],
                                          joints0: [SIMD4(0, 0, 0, 0)], weights0: [SIMD4(1, 0, 0, 0)], indices: [0, 0, 0],
                                          morphTargets: [CompiledMorph(name: "blink", positionDeltas: [SIMD3(0, -0.01, 0)])])
        let avatar = CompiledAvatar(
            nodes: [CompiledNode(id: "node:b", name: "spine", parentId: "node:a", humanoidBone: .spine), CompiledNode(id: "node:a", name: "hips", humanoidBone: .hips)],
            meshes: [CompiledMesh(id: "mesh:body", name: "body", primitives: [primitive])],
            skins: [CompiledSkin(id: "skin:body", jointNodeIds: ["node:a"], inverseBindMatrices: [SIMD16(repeating: 0)])],
            meshInstances: [CompiledMeshInstance(nodeId: "node:a", meshId: "mesh:body", skinId: "skin:body")],
            images: [image], materials: [material], humanoid: [.hips: "node:a", .spine: "node:b"],
            expressions: [ExpressionObject(id: "expression:blink", preset: .blink)], lookAt: LookAtObject(), firstPerson: FirstPersonObject(),
            springs: [], colliders: [], colliderGroups: [], meta: meta)
        let hash = try avatar.buildHash()
        XCTAssertEqual(hash.count, 64)
        XCTAssertEqual(hash, try avatar.buildHash())
        let sorted = avatar.sorted()
        XCTAssertEqual(sorted.nodes.map(\.id), ["node:a", "node:b"])
        XCTAssertEqual(try sorted.buildHash(), hash, "hash is order-independent because it sorts first")
        var changed = avatar
        changed.images[0].pngData = Data([1, 2, 4])
        XCTAssertNotEqual(try changed.buildHash(), hash)
        var renamed = avatar
        renamed.meta.name = "B"
        XCTAssertNotEqual(try renamed.buildHash(), hash)
        let json = try avatar.hashableJSON()
        XCTAssertEqual(json["images"]?[0]?["pngSha256"], .string(SHA256Hex.hex(Data([1, 2, 3]))))
        XCTAssertNil(json["images"]?[0]?["pngData"])
        XCTAssertEqual(json["humanoid"]?["hips"], "node:a")
        XCTAssertEqual(CompiledAvatar.exportIndex(of: "node:b", in: avatar.nodes, \.id), 1)
        let roundTrip = try JSONDecoder().decode(CompiledAvatar.self, from: try JSONEncoder().encode(avatar))
        XCTAssertEqual(roundTrip, avatar)
    }

    func testTemplateRegistryListsBuiltinPacks() {
        let registry = TemplateRegistry.standard()
        XCTAssertEqual(registry.ids, ["native-anime-v1"])
        XCTAssertNotNil(registry.pack(id: "native-anime-v1"))
        XCTAssertEqual(registry.templateHashes().count, 1)
        XCTAssertTrue(SHA256Hex.isValid(registry.templateHashes()["native-anime-v1"] ?? ""))
        XCTAssertNil(registry.pack(id: "missing"))
        let descriptor = ControlDescriptor(key: "body.heightM", unit: .metres, validRange: [1.2, 2.0], recommendedRange: [1.4, 1.8], defaultValue: 1.65, affects: [.avatar, .garment], description: "Stature")
        XCTAssertTrue(descriptor.accepts(1.65))
        XCTAssertFalse(descriptor.accepts(2.5))
        XCTAssertEqual(descriptor.schema.json["x-unit"], "metres")
        XCTAssertEqual(descriptor.schema.json["x-recommendedRange"], [1.4, 1.8])
    }
}
