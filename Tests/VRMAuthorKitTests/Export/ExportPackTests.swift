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

final class ExportPackTests: XCTestCase {
    private var project: TestProject!

    override func setUpWithError() throws { project = try TestProject.make() }
    override func tearDownWithError() throws { project.cleanup() }

    private func assertResultSchema(_ envelope: ResultEnvelope, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        guard envelope.status == .succeeded, let result = envelope.result, let op = project.registry.operation(named: name) else { return }
        let violations = op.resultSchema.validate(result)
        XCTAssertTrue(violations.isEmpty, "\(name) result violates its schema: \(violations.map(\.message))", file: file, line: line)
    }

    // MARK: GLBWriter

    func testGLBWriterIsByteDeterministicAndIgnoresThreads() throws {
        let avatar = TestAvatarFactory.make()
        let first = try GLBWriter.write(avatar, threads: 1)
        let second = try GLBWriter.write(avatar, threads: 4)
        let shuffled = CompiledAvatar(nodes: avatar.nodes.reversed(), meshes: avatar.meshes, skins: avatar.skins, meshInstances: avatar.meshInstances, images: avatar.images,
                                      materials: avatar.materials.reversed(), humanoid: avatar.humanoid, expressions: avatar.expressions.reversed(), lookAt: avatar.lookAt,
                                      firstPerson: avatar.firstPerson, springs: avatar.springs, colliders: avatar.colliders, colliderGroups: avatar.colliderGroups, meta: avatar.meta)
        let third = try GLBWriter.write(shuffled)
        XCTAssertEqual(first.data, second.data)
        XCTAssertEqual(first.data, third.data)
        XCTAssertEqual(try avatar.buildHash(), try shuffled.buildHash())
        XCTAssertEqual(first.data.count % 4, 0)
        let parsed = try GLBFile.parse(first.data)
        XCTAssertEqual(try parsed.serialize(), first.data)
        XCTAssertEqual(parsed.json, first.json)
        XCTAssertFalse(String(decoding: first.data, as: UTF8.self).contains(project.root.path))
    }

    func testGLBStructureMatchesVRM10Shape() throws {
        let export = try GLBWriter.write(TestAvatarFactory.make())
        let json = export.json
        XCTAssertEqual(json["asset"]?["version"], "2.0")
        XCTAssertEqual(json["asset"]?["generator"], .string("vrm-author \(ToolInfo.current.version)"))
        XCTAssertEqual(Set(json["extensionsUsed"]?.array?.compactMap(\.string) ?? []), ["VRMC_vrm", "VRMC_materials_mtoon", "VRMC_springBone", "KHR_texture_transform"])
        let nodes = try XCTUnwrap(json["nodes"]?.array)
        XCTAssertEqual(nodes.count, 21)
        XCTAssertEqual(nodes.map { $0["name"]?.string ?? "" }, TestAvatarFactory.nodes().map(\.id).sorted { CompiledAvatar.precedes($0, $1) }.map { String($0.dropFirst(5)) })
        let hips = try XCTUnwrap(export.idMap.nodes["node:hips"])
        XCTAssertEqual(nodes[hips]["translation"], [0, 0.8999999761581421, 0])
        XCTAssertEqual(Set(nodes[hips]["children"]?.array?.compactMap(\.int) ?? []), Set(["node:spine", "node:leftUpperLeg", "node:rightUpperLeg"].map { export.idMap.nodes[$0]! }))
        let body = try XCTUnwrap(export.idMap.nodes["node:body"])
        XCTAssertEqual(nodes[body]["mesh"], 0)
        XCTAssertEqual(nodes[body]["skin"], 0)
        XCTAssertEqual(Set(json["scenes"]?[0]?["nodes"]?.array?.compactMap(\.int) ?? []), [hips, body])

        let mesh = try XCTUnwrap(json["meshes"]?[0])
        XCTAssertEqual(mesh["extras"]?["targetNames"], ["blink", "aa"])
        XCTAssertEqual(export.idMap.morphTargets["mesh:body"], ["blink": 0, "aa": 1])
        let primitives = try XCTUnwrap(mesh["primitives"]?.array)
        XCTAssertEqual(primitives.count, 2)
        let accessors = try XCTUnwrap(json["accessors"]?.array)
        let position = try XCTUnwrap(primitives[0]["attributes"]?["POSITION"]?.int)
        XCTAssertEqual(accessors[position]["min"], [-0.25, 0, -0.15000000596046448])
        XCTAssertEqual(accessors[position]["max"], [0.25, 1.600000023841858, 0.15000000596046448])
        XCTAssertEqual(accessors[position]["componentType"], 5126)
        XCTAssertEqual(accessors[primitives[0]["attributes"]!["JOINTS_0"]!.int!]["componentType"], 5123)
        XCTAssertEqual(accessors[primitives[0]["attributes"]!["WEIGHTS_0"]!.int!]["type"], "VEC4")
        XCTAssertEqual(accessors[primitives[0]["indices"]!.int!]["componentType"], 5125)
        XCTAssertEqual(primitives[0]["targets"]?.array?.count, 2)
        XCTAssertNotNil(accessors[primitives[0]["targets"]![0]!["POSITION"]!.int!]["min"])
        XCTAssertEqual(primitives[0]["material"]?.int, export.idMap.materials["material:body"])
        XCTAssertEqual(primitives[1]["material"]?.int, export.idMap.materials["material:face"])
        for view in json["bufferViews"]?.array ?? [] { XCTAssertEqual((view["byteOffset"]?.int ?? 0) % 4, 0) }
        XCTAssertEqual(json["buffers"]?[0]?["byteLength"]?.int, export.bin.count)

        let skin = try XCTUnwrap(json["skins"]?[0])
        XCTAssertEqual(skin["joints"]?.array?.compactMap(\.int), ["node:hips", "node:spine", "node:head"].map { export.idMap.nodes[$0]! })
        XCTAssertEqual(accessors[skin["inverseBindMatrices"]!.int!]["type"], "MAT4")

        XCTAssertEqual(json["images"]?[0]?["mimeType"], "image/png")
        XCTAssertEqual(json["samplers"]?.array?.count, 1)
        XCTAssertEqual(json["textures"]?[0]?["source"], 0)
        let imageView = try XCTUnwrap(json["bufferViews"]?[json["images"]![0]!["bufferView"]!.int!])
        XCTAssertEqual(export.bin.subdata(in: imageView["byteOffset"]!.int!..<(imageView["byteOffset"]!.int! + imageView["byteLength"]!.int!)), TestAvatarFactory.png2x2)

        let materials = try XCTUnwrap(json["materials"]?.array)
        let bodyMaterial = materials[export.idMap.materials["material:body"]!]
        XCTAssertEqual(bodyMaterial["pbrMetallicRoughness"]?["baseColorTexture"]?["index"], 0)
        XCTAssertNil(bodyMaterial["pbrMetallicRoughness"]?["baseColorTexture"]?["image"])
        XCTAssertEqual(bodyMaterial["extensions"]?["VRMC_materials_mtoon"]?["specVersion"], "1.0")
        XCTAssertEqual(bodyMaterial["extensions"]?["VRMC_materials_mtoon"]?["shadingToonyFactor"], 0.9)
        let faceMaterial = materials[export.idMap.materials["material:face"]!]
        XCTAssertEqual(faceMaterial["extensions"]?["VRMC_materials_mtoon"]?["shadeMultiplyTexture"]?["index"], 0)
        XCTAssertNotNil(faceMaterial["pbrMetallicRoughness"]?["baseColorTexture"]?["extensions"]?["KHR_texture_transform"])

        let vrm = try XCTUnwrap(json["extensions"]?["VRMC_vrm"])
        XCTAssertEqual(vrm["specVersion"], "1.0")
        XCTAssertEqual(vrm["meta"]?["name"], "Test Avatar")
        XCTAssertEqual(vrm["meta"]?["authors"], ["Test Author"])
        XCTAssertEqual(vrm["meta"]?["licenseUrl"], .string(VRMMeta.vrm10LicenseUrl))
        XCTAssertEqual(vrm["meta"]?["avatarPermission"], "onlyAuthor")
        XCTAssertEqual(vrm["humanoid"]?["humanBones"]?.object?.count, 17)
        XCTAssertEqual(vrm["humanoid"]?["humanBones"]?["head"]?["node"]?.int, export.idMap.nodes["node:head"])
        let blink = try XCTUnwrap(vrm["expressions"]?["preset"]?["blink"])
        XCTAssertEqual(blink["morphTargetBinds"], [["node": .number(Double(body)), "index": 0, "weight": 1]])
        XCTAssertEqual(blink["isBinary"], false)
        XCTAssertEqual(blink["overrideBlink"], "none")
        XCTAssertEqual(vrm["expressions"]?["preset"]?["aa"]?["overrideMouth"], "blend")
        let happy = try XCTUnwrap(vrm["expressions"]?["preset"]?["happy"])
        XCTAssertEqual(happy["materialColorBinds"]?[0]?["material"]?.int, export.idMap.materials["material:face"])
        XCTAssertEqual(happy["materialColorBinds"]?[0]?["type"], "color")
        XCTAssertEqual(happy["textureTransformBinds"]?[0]?["offset"], [0.1, 0])
        XCTAssertEqual(vrm["expressions"]?["custom"]?["wink"]?["isBinary"], true)
        XCTAssertEqual(export.idMap.expressions["expression:wink"], "custom/wink")
        XCTAssertEqual(vrm["lookAt"]?["type"], "bone")
        XCTAssertEqual(vrm["lookAt"]?["offsetFromHeadBone"], [0, 0.06, 0])
        XCTAssertEqual(vrm["lookAt"]?["rangeMapHorizontalInner"]?["inputMaxValue"], 90)
        XCTAssertEqual(vrm["firstPerson"]?["meshAnnotations"], [["node": .number(Double(body)), "type": "both"]])

        let springBone = try XCTUnwrap(json["extensions"]?["VRMC_springBone"])
        XCTAssertEqual(springBone["specVersion"], "1.0")
        XCTAssertEqual(springBone["colliders"]?[0]?["node"]?.int, export.idMap.nodes["node:head"])
        XCTAssertEqual(springBone["colliders"]?[0]?["shape"]?["sphere"]?["radius"], 0.1)
        XCTAssertEqual(springBone["colliderGroups"]?[0]?["colliders"], [0])
        XCTAssertEqual(springBone["colliderGroups"]?[0]?["name"], "head")
        let spring = try XCTUnwrap(springBone["springs"]?[0])
        XCTAssertEqual(spring["name"], "hair")
        XCTAssertEqual(spring["joints"]?.array?.count, 3)
        XCTAssertEqual(spring["joints"]?[0]?["node"]?.int, export.idMap.nodes["node:hair0"])
        XCTAssertEqual(spring["joints"]?[0]?["gravityDir"], [0, -1, 0])
        XCTAssertEqual(spring["joints"]?[2]?["hitRadius"], 0.01)
        XCTAssertEqual(spring["colliderGroups"], [0])
        XCTAssertNil(spring["center"])
    }

    func testGLBWriterRejectsDanglingReferences() throws {
        var avatar = TestAvatarFactory.make()
        avatar.meshes[0].primitives[0].materialId = "material:missing"
        XCTAssertThrowsError(try GLBWriter.write(avatar)) { XCTAssertEqual(($0 as? AuthorError)?.code, .exportFailed) }
        avatar = TestAvatarFactory.make()
        avatar.humanoid[.hips] = nil
        XCTAssertThrowsError(try GLBWriter.write(avatar)) { XCTAssertTrue(($0 as? AuthorError)?.message.contains("hips") ?? false) }
        avatar = TestAvatarFactory.make()
        avatar.nodes[0].parentId = "node:nope"
        XCTAssertThrowsError(try GLBWriter.write(avatar))
        avatar = TestAvatarFactory.make()
        avatar.expressions[0].morphTargetBinds[0].target = "smile"
        XCTAssertThrowsError(try GLBWriter.write(avatar)) { XCTAssertTrue(($0 as? AuthorError)?.message.contains("smile") ?? false) }
        avatar = TestAvatarFactory.make()
        avatar.meshInstances.append(CompiledMeshInstance(nodeId: "node:body", meshId: "mesh:body"))
        XCTAssertThrowsError(try GLBWriter.write(avatar))
        avatar = TestAvatarFactory.make()
        avatar.materials[0].gltf = ["pbrMetallicRoughness": ["baseColorTexture": ["image": "image:missing"]]]
        XCTAssertThrowsError(try GLBWriter.write(avatar)) { XCTAssertTrue(($0 as? AuthorError)?.message.contains("image:missing") ?? false) }
    }

    func testSpecValidatorPassesFactoryAvatarAndRejectsBrokenGLB() throws {
        let export = try GLBWriter.write(TestAvatarFactory.make())
        let checks = SpecValidator.validate(data: export.data)
        XCTAssertEqual(checks.filter { $0.status != .pass }.map(\.id), [], checks.filter { $0.status != .pass }.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(Set(checks.map(\.scenario)), ["spec.structure", "spec.humanoid", "spec.expressions", "spec.springs", "spec.meta"])
        var truncated = export.data
        truncated.removeLast(8)
        XCTAssertEqual(SpecValidator.validate(data: truncated).first?.status, .fail)
        XCTAssertEqual(SpecValidator.validate(data: Data("glTF".utf8)).first?.code, "MALFORMED_GLB")
        var glb = try GLBFile.parse(export.data)
        var json = glb.json.object!
        json["extensionsUsed"] = ["VRMC_vrm"]
        glb.json = .object(json)
        let missing = SpecValidator.validate(data: try glb.serialize()).first { $0.id == "spec.structure.extensionsUsed" }
        XCTAssertEqual(missing?.status, .fail)
    }

    // MARK: recipe export

    func testRecipeExportRoundTripIsByteIdenticalAndIncludesPackDefaults() throws {
        let missing = project.invoke("recipe export", ["out": .string(project.path("recipe.json"))])
        XCTAssertEqual(missing.exitCode, .missingCapability)
        XCTAssertEqual(missing.errors.first?.code, .missingInput)

        try project.applyDefaultRecipe { recipe in
            recipe.name = "custom"
            recipe.body = ["body.heightM": 1.7]
        }
        let out = project.path("recipe.json")
        let envelope = project.invoke("recipe export", ["out": .string(out)])
        XCTAssertEqual(envelope.exitCode, .success, "\(envelope.errors)")
        assertResultSchema(envelope, "recipe export")
        XCTAssertEqual(envelope.artifacts.first?.role, "recipe")
        let bytes = try Data(contentsOf: URL(fileURLWithPath: out))
        XCTAssertEqual(SHA256Hex.hex(bytes), envelope.artifacts.first?.sha256)
        let recipe = try Recipe.decode(bytes)
        XCTAssertEqual(recipe.name, "custom")
        XCTAssertEqual(recipe.body["body.heightM"], 1.7)
        XCTAssertEqual(recipe.template.sha256, ExportStubTemplatePack.packSha256)
        XCTAssertEqual(recipe.style.sha256, QAPins.defaultProfileSha256)
        XCTAssertEqual(try CanonicalJSON.data(try recipe.jsonValue()), bytes)
        XCTAssertEqual(envelope.result?["recipe"], try JSONValue.parse(bytes))

        let again = project.invoke("recipe export", ["out": .string(out)])
        XCTAssertEqual(again.errors.first?.code, .outputExists)
        let replaced = project.invoke("recipe export", ["out": .string(out), "replace": true, "resolved": false])
        XCTAssertEqual(replaced.exitCode, .success)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: out)), bytes)

        var state = try project.store.state()
        var partial = state.recipe!.object!
        partial["body"] = [:]
        partial["name"] = "partial"
        state.recipe = .object(partial)
        try project.store.atomicWrite(try CanonicalJSON.data(try JSONValue.from(state)), to: project.store.projectFile)
        let resolved = project.invoke("recipe export", ["out": .string(project.path("resolved.json"))])
        XCTAssertEqual(resolved.exitCode, .success, "\(resolved.errors)")
        XCTAssertEqual(resolved.result?["recipe"]?["body"]?["body.heightM"], 1.6)
        XCTAssertEqual(resolved.result?["recipe"]?["name"], "partial")
    }

    // MARK: recipe apply

    func testRecipeApplyMaterializesObjectsInvalidationsAndRevision() throws {
        var recipe = ExportStubTemplatePack().defaults
        let dry = project.invoke("recipe apply", ["requestId": "dry", "recipe": try recipe.jsonValue(), "dryRun": true])
        XCTAssertEqual(dry.exitCode, .success, "\(dry.errors)")
        XCTAssertEqual(dry.revisionAfter, 0)
        XCTAssertEqual(try project.store.state().revision, 0)
        XCTAssertEqual(dry.plan?.invalidations, ["geometry", "rig", "morphs", "fit", "textures", "materials", "springs", "qa", "build"])
        XCTAssertFalse(dry.plan?.edits.isEmpty ?? true)
        XCTAssertNil(try project.store.receipt(requestId: "dry"))

        let envelope = project.invoke("recipe apply", ["requestId": "a1", "recipe": try recipe.jsonValue(), "expectedPlanHash": .string(dry.plan!.planHash)])
        XCTAssertEqual(envelope.exitCode, .success, "\(envelope.errors)")
        assertResultSchema(envelope, "recipe apply")
        XCTAssertEqual(envelope.revisionBefore, 0)
        XCTAssertEqual(envelope.revisionAfter, 1)
        XCTAssertEqual(envelope.result?["invalidations"]?.array?.count, 9)
        XCTAssertEqual(envelope.artifacts.first?.role, "compiled")
        let buildHash = try XCTUnwrap(envelope.artifacts.first?.buildHash)
        XCTAssertTrue(FileManager.default.fileExists(atPath: BuildSupport.compiledURL(project.store, buildHash).path))
        let state = try project.store.state()
        XCTAssertEqual(state.revision, 1)
        XCTAssertNotNil(state.recipe)
        let kinds = Dictionary(grouping: state.objectIds.compactMap { state.object(id: $0) }, by: \.kind).mapValues(\.count)
        XCTAssertEqual(kinds[.avatar], 1)
        XCTAssertEqual(kinds[.material], 2)
        XCTAssertEqual(kinds[.image], 1)
        XCTAssertEqual(kinds[.expression], 4)
        XCTAssertEqual(kinds[.lookat], 1)
        XCTAssertEqual(kinds[.firstperson], 1)
        XCTAssertEqual(kinds[.spring], 1)
        XCTAssertEqual(kinds[.collider], 1)
        XCTAssertEqual(kinds[.colliderGroup], 1)
        XCTAssertEqual(kinds[.node], 21)
        XCTAssertEqual(kinds[.mesh], 1)
        XCTAssertEqual(kinds[.humanoid], 1)
        XCTAssertEqual(state.object(id: "avatar:main")?.fields["buildHash"], .string(buildHash))
        XCTAssertEqual(state.object(id: "material:face")?.writablePointers.map(\.description), ["/gltf", "/mtoon"])
        XCTAssertEqual(state.object(id: "node:head")?.writablePointers, [])
        XCTAssertEqual(state.object(id: "humanoid:main")?.fields["humanBones"]?["head"], "node:head")

        let replay = project.invoke("recipe apply", ["requestId": "a1", "recipe": try recipe.jsonValue()])
        XCTAssertEqual(replay, envelope)
        XCTAssertEqual(try project.store.state().revision, 1)

        recipe.body = ["body.heightM": 1.75]
        recipe.materials = [MaterialObject(id: "material:extra", role: .cloth, gltf: ["alphaMode": "OPAQUE"], mtoon: ["shadingToonyFactor": 0.5])]
        let second = project.invoke("recipe apply", ["requestId": "a2", "recipe": try recipe.jsonValue(), "expectedRevision": 1])
        XCTAssertEqual(second.exitCode, .success, "\(second.errors)")
        XCTAssertEqual(second.revisionAfter, 2)
        XCTAssertEqual(second.plan?.invalidations, ["geometry", "rig", "morphs", "fit", "springs", "materials", "qa", "build"])
        XCTAssertNotNil(try project.store.state().object(id: "material:extra"))
        XCTAssertNotEqual(try project.store.state().object(id: "avatar:main")?.fields["buildHash"], .string(buildHash))

        let stale = project.invoke("recipe apply", ["requestId": "a3", "recipe": try recipe.jsonValue(), "expectedRevision": 1])
        XCTAssertEqual(stale.exitCode, .conflict)

        recipe.template = TemplateRef(id: "stub-v1", sha256: String(repeating: "0", count: 64))
        let mismatch = project.invoke("recipe apply", ["requestId": "a4", "recipe": try recipe.jsonValue()])
        XCTAssertEqual(mismatch.errors.first?.code, .validationFailed)
        XCTAssertEqual(mismatch.errors.first?.path, "/template/sha256")
        recipe.template = TemplateRef(id: "other", sha256: ExportStubTemplatePack.packSha256)
        XCTAssertEqual(project.invoke("recipe apply", ["requestId": "a5", "recipe": try recipe.jsonValue()]).errors.first?.code, .missingCapability)
        XCTAssertEqual(project.invoke("recipe apply", ["requestId": "a6", "recipe": ["schemaVersion": "1.0"]]).exitCode, .invalidRequest)
        XCTAssertEqual(try project.store.state().revision, 2)
    }

    private struct ConflictingRights: RecipeRightsHook {
        func resolve(declaration: RightsDeclaration, recipe: Recipe, context: OperationContext) throws -> RecipeRightsResolution {
            RecipeRightsResolution(meta: declaration.meta, conflicts: [AuthorError(code: .validationFailed, path: "/rights/meta/authors", message: "Author attribution conflicts with the ingredient ledger.")])
        }
    }

    private struct RenamingRights: RecipeRightsHook {
        func resolve(declaration: RightsDeclaration, recipe: Recipe, context: OperationContext) throws -> RecipeRightsResolution {
            var meta = declaration.meta
            meta.name = "Resolved Name"
            return RecipeRightsResolution(meta: meta, attribution: ["name": "ledger"])
        }
    }

    func testRecipeApplyInvokesRightsHook() throws {
        let conflicting = try TestProject.make(registry: TestProject.registry(rights: ConflictingRights()))
        defer { conflicting.cleanup() }
        let refused = conflicting.invoke("recipe apply", ["requestId": "r1", "recipe": try ExportStubTemplatePack().defaults.jsonValue()])
        XCTAssertEqual(refused.exitCode, .gateFailed)
        XCTAssertEqual(refused.errors.first?.path, "/rights/meta/authors")
        XCTAssertEqual(try conflicting.store.state().revision, 0)

        let renaming = try TestProject.make(registry: TestProject.registry(rights: RenamingRights()))
        defer { renaming.cleanup() }
        XCTAssertEqual(renaming.invoke("recipe apply", ["requestId": "r1", "recipe": try ExportStubTemplatePack().defaults.jsonValue()]).exitCode, .success)
        XCTAssertEqual(try renaming.store.state().recipe?["rights"]?["meta"]?["name"], "Resolved Name")
        let build = renaming.invoke("build", ["out": .string(renaming.path("a.vrm"))])
        XCTAssertEqual(build.exitCode, .success)
        let document = try VRMReader.read(fileAt: URL(fileURLWithPath: renaming.path("a.vrm")))
        XCTAssertEqual(document.vrm?["meta"]?["name"], "Resolved Name")
    }

    // MARK: build

    func testBuildWritesArtifactsIdMapAndReusesUnchangedInputs() throws {
        XCTAssertEqual(project.invoke("build", ["out": .string(project.path("draft.vrm"))]).errors.first?.code, .missingInput)
        let apply = try project.applyDefaultRecipe()
        let buildHash = try XCTUnwrap(apply.artifacts.first?.buildHash)
        let out = project.path("draft.vrm")
        let envelope = project.invoke("build", ["out": .string(out)])
        XCTAssertEqual(envelope.exitCode, .success, "\(envelope.errors)")
        assertResultSchema(envelope, "build")
        XCTAssertEqual(envelope.result?["buildHash"], .string(buildHash))
        XCTAssertEqual(envelope.revisionBefore, 1)
        XCTAssertEqual(envelope.revisionAfter, 1)
        XCTAssertEqual(envelope.warnings.map(\.code), ["BUILD_REUSED"])
        let artifact = try XCTUnwrap(envelope.artifacts.first)
        XCTAssertEqual(artifact.role, "draft")
        XCTAssertEqual(artifact.mediaType, "model/gltf-binary")
        XCTAssertEqual(artifact.buildHash, buildHash)
        let data = try Data(contentsOf: URL(fileURLWithPath: out))
        XCTAssertEqual(SHA256Hex.hex(data), artifact.sha256)
        XCTAssertEqual(artifact.sizeBytes, data.count)
        XCTAssertEqual(try Data(contentsOf: BuildSupport.avatarURL(project.store, buildHash)), data)
        let idMap = try JSONValue.parse(try Data(contentsOf: BuildSupport.idMapURL(project.store, buildHash)))
        XCTAssertEqual(idMap["nodes"]?["node:hips"]?.int, envelope.result?["idMap"]?["nodes"]?["node:hips"]?.int)
        let info = try XCTUnwrap(try BuildSupport.buildInfo(project.store, buildHash))
        XCTAssertEqual(info.artifactSha256, artifact.sha256)
        XCTAssertEqual(info.backend, "portable-strict/1")
        XCTAssertEqual(info.revision, 1)
        XCTAssertNil(info.previousBuildHash)
        XCTAssertEqual(BuildSupport.latestBuildHash(project.store), buildHash)
        XCTAssertEqual(SpecValidator.validate(data: data).filter { $0.status == .fail }, [])

        XCTAssertEqual(project.invoke("build", ["out": .string(out)]).errors.first?.code, .outputExists)
        let rebuilt = project.invoke("build", ["out": .string(out), "replace": true, "threads": 4])
        XCTAssertEqual(rebuilt.exitCode, .success)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: out)), data)

        try project.applyDefaultRecipe(requestId: "apply-2") { $0.body = ["body.heightM": 1.7] }
        let taller = project.invoke("build", ["out": .string(project.path("taller.vrm"))])
        XCTAssertEqual(taller.exitCode, .success, "\(taller.errors)")
        XCTAssertNotEqual(taller.result?["buildHash"], .string(buildHash))
        XCTAssertEqual(try BuildSupport.buildInfo(project.store, taller.result!["buildHash"]!.string!)?.previousBuildHash, buildHash)
    }

    func testBuildRejectsStaleDependencies() throws {
        try project.applyDefaultRecipe()
        _ = try project.store.mutate(requestId: "stale", payload: [:], expectedRevision: 1, dryRun: false, expectedPlanHash: nil, operation: "test") { tx in
            var object = try tx.object(id: "spring:hair")
            object.fields["stale"] = true
            try tx.replace(object)
            return nil
        }
        let envelope = project.invoke("build", ["out": .string(project.path("draft.vrm"))])
        XCTAssertEqual(envelope.exitCode, .gateFailed)
        XCTAssertEqual(envelope.errors.first?.code, .staleDependency)
        XCTAssertEqual(envelope.errors.first?.observed, ["spring:hair"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.path("draft.vrm")))
        XCTAssertEqual(project.invoke("export vrm", ["out": .string(project.path("final.vrm"))]).errors.first?.code, .staleDependency)
    }

    // MARK: export vrm

    func testExportVRMRequiresResolvedMandatoryMeta() throws {
        try project.applyDefaultRecipe { recipe in
            recipe.rights.meta.version = nil
        }
        let refused = project.invoke("export vrm", ["out": .string(project.path("final.vrm"))])
        XCTAssertEqual(refused.exitCode, .gateFailed)
        XCTAssertEqual(refused.errors.map(\.path), ["/meta/version"])
        XCTAssertEqual(refused.errors.first?.code, .validationFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.path("final.vrm")))

        try project.applyDefaultRecipe(requestId: "apply-2")
        let out = project.path("final.vrm")
        let envelope = project.invoke("export vrm", ["out": .string(out)])
        XCTAssertEqual(envelope.exitCode, .success, "\(envelope.errors)")
        assertResultSchema(envelope, "export vrm")
        XCTAssertEqual(envelope.artifacts.map(\.role), ["final", "export-report"])
        XCTAssertEqual(envelope.result?["lossReport"]?["lost"], [])
        XCTAssertEqual(envelope.result?["meta"]?["version"], "1.0.0")
        let data = try Data(contentsOf: URL(fileURLWithPath: out))
        XCTAssertEqual(SHA256Hex.hex(data), envelope.artifacts[0].sha256)
        let report = try JSONValue.parse(try Data(contentsOf: URL(fileURLWithPath: project.path("final.export-report.json"))))
        XCTAssertEqual(report["file"]?["sha256"], .string(envelope.artifacts[0].sha256))
        XCTAssertEqual(report["lossReport"]?["lost"], [])
        XCTAssertEqual(report["buildHash"], envelope.result?["buildHash"])
        XCTAssertEqual(data, try GLBWriter.write(try ExportStubTemplatePack().compile(ExportStubTemplatePack().defaults, seed: 0)).data)
    }

    func testMissingMandatoryMetaVocabulary() {
        XCTAssertEqual(SpecValidator.mandatoryMetaFields.count, 13)
        var meta = TestAvatarFactory.meta()
        XCTAssertEqual(BuildSupport.missingMandatoryMeta(meta), [])
        meta.name = ""
        meta.version = ""
        meta.authors = []
        meta.licenseUrl = ""
        XCTAssertEqual(BuildSupport.missingMandatoryMeta(meta), ["name", "version", "authors", "licenseUrl"])
    }
}
