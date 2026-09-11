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

/// Acceptance pack for the Materials area: schema leaf coverage, role
/// defaults against the pinned profile, `material shading` and `style attach`.
final class MaterialsPackTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try MaterialsTestSupport.tempDir() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: Schema leaf coverage (answer key from glTF 2.0 + VRMC_materials_mtoon 1.0)

    static let textureReferenceLeaves = [
        "/imageId",
        "/sampler/magFilter", "/sampler/minFilter", "/sampler/wrapS", "/sampler/wrapT",
        "/texCoord",
        "/transform/offset", "/transform/rotation", "/transform/scale", "/transform/texCoord",
    ]

    static func textureLeaves(_ slot: String, extra: [String] = []) -> [String] {
        (textureReferenceLeaves + extra).map { slot + $0 }.sorted()
    }

    static let expectedMaterialLeaves: [String] = [
        "/gltf/alphaCutoff",
        "/gltf/alphaMode",
        "/gltf/doubleSided",
        "/gltf/emissiveFactor",
    ] + textureLeaves("/gltf/emissiveTexture") + [
        "/gltf/extensions/KHR_materials_emissive_strength/emissiveStrength",
        "/gltf/name",
    ] + textureLeaves("/gltf/normalTexture", extra: ["/scale"])
      + textureLeaves("/gltf/occlusionTexture", extra: ["/strength"]) + [
        "/gltf/pbrMetallicRoughness/baseColorFactor",
    ] + textureLeaves("/gltf/pbrMetallicRoughness/baseColorTexture") + [
        "/gltf/pbrMetallicRoughness/metallicFactor",
    ] + textureLeaves("/gltf/pbrMetallicRoughness/metallicRoughnessTexture") + [
        "/gltf/pbrMetallicRoughness/roughnessFactor",
        "/id",
        "/mtoon/giEqualizationFactor",
        "/mtoon/matcapFactor",
    ] + textureLeaves("/mtoon/matcapTexture") + [
        "/mtoon/outlineColorFactor",
        "/mtoon/outlineLightingMixFactor",
        "/mtoon/outlineWidthFactor",
        "/mtoon/outlineWidthMode",
    ] + textureLeaves("/mtoon/outlineWidthMultiplyTexture") + [
        "/mtoon/parametricRimColorFactor",
        "/mtoon/parametricRimFresnelPowerFactor",
        "/mtoon/parametricRimLiftFactor",
        "/mtoon/renderQueueOffsetNumber",
        "/mtoon/rimLightingMixFactor",
    ] + textureLeaves("/mtoon/rimMultiplyTexture") + [
        "/mtoon/shadeColorFactor",
    ] + textureLeaves("/mtoon/shadeMultiplyTexture") + [
        "/mtoon/shadingShiftFactor",
    ] + textureLeaves("/mtoon/shadingShiftTexture", extra: ["/scale"]) + [
        "/mtoon/shadingToonyFactor",
        "/mtoon/specVersion",
        "/mtoon/transparentWithZWrite",
    ] + textureLeaves("/mtoon/uvAnimationMaskTexture") + [
        "/mtoon/uvAnimationRotationSpeedFactor",
        "/mtoon/uvAnimationScrollXSpeedFactor",
        "/mtoon/uvAnimationScrollYSpeedFactor",
        "/role",
    ]

    func testSchemaShowMaterialEnumeratesEveryLeaf() throws {
        XCTAssertEqual(MaterialsPackTests.expectedMaterialLeaves.count, 143)
        let envelope = MaterialsTestSupport.invoke("schema show", ["name": "Material"], context: MaterialsTestSupport.context())
        XCTAssertEqual(envelope.exitCode, .success)
        let leaves = try XCTUnwrap(envelope.result?["leaves"]?.array?.compactMap { $0.string })
        XCTAssertEqual(leaves, MaterialsPackTests.expectedMaterialLeaves)
        XCTAssertEqual(MaterialObject.schema.leafPointers(), MaterialsPackTests.expectedMaterialLeaves)
        XCTAssertEqual(envelope.result?["kind"], "model")
        XCTAssertEqual(envelope.result?["schemaHash"]?.string?.count, 64)
    }

    func testSchemaRejectsUnknownFieldsAndExtensions() throws {
        let unknown = MaterialObject(id: "m", role: .cloth, gltf: ["alphaMode": "OPAQUE", "shininess": 1], mtoon: [:])
        XCTAssertThrowsError(try MaterialCompiler.validate(unknown)) { error in
            let errors = (error as? ModelValidationError)?.errors ?? []
            XCTAssertEqual(errors.first?.code, .unknownField)
            XCTAssertEqual(errors.first?.path, "/m/gltf/shininess")
            XCTAssertEqual(errors.first?.objectId, "m")
        }
        let unlit = MaterialObject(id: "m", role: .cloth, gltf: ["extensions": ["KHR_materials_unlit": [:]]], mtoon: [:])
        XCTAssertThrowsError(try MaterialCompiler.validate(unlit)) { error in
            XCTAssertEqual((error as? ModelValidationError)?.errors.first?.path, "/m/gltf/extensions/KHR_materials_unlit")
        }
        let allowed = MaterialObject(id: "m", role: .cloth, gltf: ["extensions": ["KHR_materials_emissive_strength": ["emissiveStrength": 2]]], mtoon: [:])
        XCTAssertNoThrow(try MaterialCompiler.validate(allowed))
        let badEnum = MaterialObject(id: "m", role: .cloth, gltf: [:], mtoon: ["outlineWidthMode": "world"])
        XCTAssertThrowsError(try MaterialCompiler.validate(badEnum))
        let badRange = MaterialObject(id: "m", role: .cloth, gltf: [:], mtoon: ["shadingToonyFactor": 1.5])
        XCTAssertThrowsError(try MaterialCompiler.validate(badRange))
        let badVersion = MaterialObject(id: "m", role: .cloth, gltf: [:], mtoon: ["specVersion": "0.9"])
        XCTAssertThrowsError(try MaterialCompiler.validate(badVersion))
        let texture = MaterialObject(id: "m", role: .cloth, gltf: ["pbrMetallicRoughness": ["baseColorTexture": ["imageId": "image:x", "sampler": ["wrapS": 33071], "transform": ["offset": [0.5, 0], "rotation": 1.5]]]], mtoon: [:])
        XCTAssertNoThrow(try MaterialCompiler.validate(texture))
        let badSampler = MaterialObject(id: "m", role: .cloth, gltf: ["pbrMetallicRoughness": ["baseColorTexture": ["imageId": "image:x", "sampler": ["wrapS": 1]]]], mtoon: [:])
        XCTAssertThrowsError(try MaterialCompiler.validate(badSampler))
    }

    // MARK: Role defaults against the pinned profile

    private func metrics(for material: MaterialObject) -> [String: JSONValue] {
        let g = material.gltf, m = material.mtoon
        let base = g["pbrMetallicRoughness"]?["baseColorFactor"]?.array?.compactMap(\.number) ?? [1, 1, 1, 1]
        let shade = m["shadeColorFactor"]?.array?.compactMap(\.number) ?? [1, 1, 1]
        let toony = m["shadingToonyFactor"]!.number!, shift = m["shadingShiftFactor"]!.number!
        let rim = m["parametricRimColorFactor"]!.array!.compactMap(\.number)
        let outline = m["outlineColorFactor"]!.array!.compactMap(\.number)
        let emissive = g["emissiveFactor"]!.array!.compactMap(\.number)
        let mode = m["outlineWidthMode"]!.string!
        let alphaMode = g["alphaMode"]!.string!
        let L = MaterialsTestSupport.luminance
        var out: [String: JSONValue] = [
            "shadow_end": .number(-1 + toony - shift),
            "lit_start": .number(1 - toony - shift),
            "terminator_width": .number(2 * (1 - toony)),
            "shade_luminance_ratio": .number(L(shade) / max(L(Array(base[0..<3])), 1e-6)),
            "shade_warmth": .number((shade[0] / max(shade[1], 1e-6)) / max(base[0] / max(base[1], 1e-6), 1e-6)),
            "rim_luminance": .number(L(rim)),
            "outline_luminance": .number(L(outline)),
            "outline_warm": .bool(outline[0] >= outline[2]),
            "emissive_luminance": .number(L(emissive)),
            "outlineWidthMode": .string(mode),
            "alphaMode": .string(alphaMode),
            "renderQueueOffsetNumber": m["renderQueueOffsetNumber"]!,
            "transparentWithZWrite": m["transparentWithZWrite"]!,
            "doubleSided": g["doubleSided"]!,
            "giEqualizationFactor": m["giEqualizationFactor"]!,
            "parametricRimFresnelPowerFactor": m["parametricRimFresnelPowerFactor"]!,
        ]
        if mode == "worldCoordinates" { out["outline_width_m"] = m["outlineWidthFactor"] }
        if alphaMode == "MASK" { out["alphaCutoff"] = g["alphaCutoff"] }
        return out
    }

    private func check(_ check: JSONValue, _ value: JSONValue?) -> Bool {
        guard let value else { return false }
        switch check["type"]?.string {
        case "range":
            guard let n = value.number else { return false }
            if let lo = check["min"]?.number, n < lo { return false }
            if let hi = check["max"]?.number, n > hi { return false }
            return true
        case "equals": return value == check["value"]
        case "enum": return check["values"]?.array?.contains(value) ?? false
        default: return false
        }
    }

    func testRoleDefaultsSatisfyEveryMaterialRuleOfThePinnedProfile() throws {
        let profile = try JSONValue.parse(try Data(contentsOf: MaterialsTestSupport.pinnedProfile))
        XCTAssertEqual(profile["material_roles"]?["roles"]?.array?.compactMap(\.string).sorted(), MaterialRole.allCases.map(\.rawValue).sorted())
        var groups: [String: [String]] = [:]
        for (name, members) in profile["material_roles"]?["groups"]?.object ?? [:] { groups[name] = members.array?.compactMap(\.string) }
        let resolved = try MaterialRole.allCases.map { try MaterialCompiler.resolve(MaterialObject(id: "material:\($0.rawValue)", role: $0, gltf: [:], mtoon: [:])) }
        var checked = 0
        for rule in profile["rules"]?.array ?? [] where rule["scope"] == "material" && (rule["severity"] == "must" || rule["severity"] == "should") {
            let roles = Set((rule["roles"]?.array ?? []).compactMap(\.string).flatMap { groups[$0] ?? [$0] })
            let filter = rule["filter"]?.object ?? [:]
            for material in resolved where roles.isEmpty || roles.contains(material.role.rawValue) {
                let metrics = metrics(for: material)
                guard filter.allSatisfy({ metrics[$0.key] == $0.value }) else { continue }
                let metric = rule["metric"]!.string!
                XCTAssertTrue(check(rule["check"]!, metrics[metric]), "\(rule["id"]!.string!) fails for \(material.role.rawValue): \(metric)=\(String(describing: metrics[metric])) check=\(rule["check"]!)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 60)
    }

    func testRoleDefaultNumericProperties() throws {
        let face = try MaterialCompiler.resolve(MaterialObject(id: "f", role: .faceSkin, gltf: [:], mtoon: [:]))
        let shade = face.mtoon["shadeColorFactor"]!.array!.compactMap(\.number)
        let base = face.gltf["pbrMetallicRoughness"]!["baseColorFactor"]!.array!.compactMap(\.number)
        XCTAssertLessThan(MaterialsTestSupport.luminance(shade), MaterialsTestSupport.luminance(base))
        let faceRaster = MaterialRoleDefaults.raster(for: .faceSkin, width: 8, height: 8, seed: 0)
        let centre = faceRaster[4, 4]
        XCTAssertLessThan(Double(centre.x) * shade[0] + Double(centre.y) * shade[1] + Double(centre.z) * shade[2], Double(centre.x + centre.y + centre.z))
        XCTAssertEqual(face.mtoon["shadingToonyFactor"], 0.95)
        XCTAssertEqual(face.mtoon["shadingShiftFactor"], 0.75)
        XCTAssertEqual(MaterialShading.derive(toony: 0.95, shift: 0.75).shadowEnd, -0.8)

        let eyeWhite = MaterialRoleDefaults.raster(for: .eyeWhite, width: 16, height: 16, seed: 0)[8, 8]
        XCTAssertGreaterThan(eyeWhite.x, 0.9)
        XCTAssertGreaterThan(eyeWhite.y, 0.9)
        XCTAssertGreaterThan(eyeWhite.z, 0.9)
        XCTAssertEqual(eyeWhite.w, 1)
        let eyeWhiteMaterial = try MaterialCompiler.resolve(MaterialObject(id: "w", role: .eyeWhite, gltf: [:], mtoon: [:]))
        XCTAssertEqual(eyeWhiteMaterial.gltf["pbrMetallicRoughness"]?["baseColorFactor"], [1, 1, 1, 1])
        XCTAssertEqual(eyeWhiteMaterial.gltf["doubleSided"], false)

        let profile = try JSONValue.parse(try Data(contentsOf: MaterialsTestSupport.pinnedProfile))
        let widthRule = try XCTUnwrap(profile["rules"]?.array?.first { $0["id"] == "outline.surface_width" })
        let hair = try MaterialCompiler.resolve(MaterialObject(id: "h", role: .hair, gltf: [:], mtoon: [:]))
        XCTAssertEqual(hair.mtoon["outlineWidthMode"], "worldCoordinates")
        let width = try XCTUnwrap(hair.mtoon["outlineWidthFactor"]?.number)
        XCTAssertGreaterThanOrEqual(width, widthRule["check"]!["min"]!.number!)
        XCTAssertLessThanOrEqual(width, widthRule["check"]!["max"]!.number!)
        XCTAssertEqual(hair.gltf["alphaMode"], "MASK")
        XCTAssertEqual(hair.gltf["doubleSided"], true)

        let iris = try MaterialCompiler.resolve(MaterialObject(id: "i", role: .iris, gltf: [:], mtoon: [:]))
        XCTAssertEqual(iris.mtoon["outlineWidthMode"], "none")
        XCTAssertEqual(iris.gltf["alphaMode"], "BLEND")
        XCTAssertEqual(MaterialRoleDefaults.imageSpec(for: .iris).width, 256)
        XCTAssertEqual(MaterialRoleDefaults.imageSpec(for: .cloth).width, 512)
        let irisRaster = MaterialRoleDefaults.raster(for: .iris, width: 64, height: 64, seed: 0)
        XCTAssertEqual(irisRaster[0, 0].w, 0)
        XCTAssertEqual(irisRaster[32, 32].w, 1)
        XCTAssertLessThan(irisRaster[32, 32].x, 0.05)
        XCTAssertEqual(irisRaster[23, 21], SIMD4(1, 1, 1, 1))
        XCTAssertGreaterThan(irisRaster[32, 44].z, irisRaster[32, 61].z)
        for role in MaterialRole.allCases {
            XCTAssertEqual(MaterialRoleDefaults.role(forImageId: MaterialRoleDefaults.imageId(for: role)), role)
            XCTAssertNoThrow(try MaterialCompiler.validate(MaterialRoleDefaults.material(id: "m", role: role)))
        }
    }

    // MARK: material shading

    func testShadingProbes() throws {
        let a = try MaterialShading.solve(shadowEnd: -0.8, terminatorWidth: 0.18)
        XCTAssertEqual(a.shadingToonyFactor, 0.91)
        XCTAssertEqual(a.shadingShiftFactor, 0.71)
        XCTAssertEqual(a.shadowEnd, -0.8)
        XCTAssertEqual(a.terminatorWidth, 0.18)
        let b = try MaterialShading.solve(shadowEnd: -0.7, terminatorWidth: 0.1)
        XCTAssertEqual(b.shadingToonyFactor, 0.95)
        XCTAssertEqual(b.shadingShiftFactor, 0.65)
        let c = try MaterialShading.solve(shadowEnd: 0, terminatorWidth: 0.4)
        XCTAssertEqual(c.shadingToonyFactor, 0.8)
        XCTAssertEqual(c.shadingShiftFactor, -0.2)
        let edge = try MaterialShading.solve(shadowEnd: -1, terminatorWidth: 0)
        XCTAssertEqual(edge.shadingToonyFactor, 1)
        XCTAssertEqual(edge.shadingShiftFactor, 1)
        XCTAssertThrowsError(try MaterialShading.solve(shadowEnd: 0.9, terminatorWidth: 0.5)) { error in
            let e = error as? AuthorError
            XCTAssertEqual(e?.code, .validationFailed)
            XCTAssertEqual(e?.path, "/mtoon/shadingShiftFactor")
            XCTAssertEqual(e?.observed, -1.15)
            XCTAssertEqual(e?.required, [-1, 1])
        }
        XCTAssertThrowsError(try MaterialShading.solve(shadowEnd: 0.5, terminatorWidth: 1.9)) { error in
            XCTAssertEqual((error as? AuthorError)?.observed, -1.45)
        }
        XCTAssertThrowsError(try MaterialShading.solve(shadowEnd: 0, terminatorWidth: 2.5)) { XCTAssertEqual(($0 as? AuthorError)?.code, .invalidRequest) }
        XCTAssertThrowsError(try MaterialShading.solve(shadowEnd: 0, terminatorWidth: .nan)) { XCTAssertEqual(($0 as? AuthorError)?.code, .invalidRequest) }
    }

    func testShadingSolvesAtTheLegalParameterCorners() throws {
        let corners: [(shadowEnd: Double, terminatorWidth: Double)] = [
            (-1.0, 0.0), (-1.0, 2.0), (0.0, 0.0), (0.0, 2.0),
        ]
        for point in corners {
            let solved = try MaterialShading.solve(shadowEnd: point.shadowEnd, terminatorWidth: point.terminatorWidth)
            XCTAssertTrue((-1.0...1.0).contains(solved.shadingShiftFactor), "shift out of range at \(point)")
            XCTAssertTrue((0.0...1.0).contains(solved.shadingToonyFactor), "toony out of range at \(point)")
        }
    }

    func testEveryRoleDefaultRoundTripsThroughTheShadingSolver() throws {
        for role in MaterialRole.allCases {
            let declared = MaterialRoleDefaults.shading(for: role)
            let derived = MaterialShading.derive(toony: declared.toony, shift: declared.shift)
            let solved = try MaterialShading.solve(shadowEnd: derived.shadowEnd, terminatorWidth: derived.terminatorWidth)
            XCTAssertEqual(solved.shadingToonyFactor, declared.toony, accuracy: 1e-9, "\(role) toony")
            XCTAssertEqual(solved.shadingShiftFactor, declared.shift, accuracy: 1e-9, "\(role) shift")
            XCTAssertEqual(solved.shadowEnd, derived.shadowEnd, accuracy: 1e-9, "\(role) shadow end")
            XCTAssertEqual(solved.terminatorWidth, derived.terminatorWidth, accuracy: 1e-9, "\(role) terminator width")
        }
    }

    func testMaterialShadingCommandMutatesProjectMaterial() throws {
        let projectURL = root.appendingPathComponent("avatar.vrmauthor")
        let store = try MaterialsTestSupport.makeProject(at: projectURL, materials: [MaterialRoleDefaults.material(id: "material:face", role: .faceSkin)])
        let context = MaterialsTestSupport.context(projectPath: projectURL)
        let request: JSONValue = ["project": .string(projectURL.path), "material": "material:face", "shadowEnd": -0.8, "terminatorWidth": 0.18, "requestId": "shade-1"]

        let dry = MaterialsTestSupport.invoke("material shading", request.merging(["dryRun": true]), context: context)
        XCTAssertEqual(dry.exitCode, .success)
        XCTAssertEqual(dry.revisionAfter, 1)
        XCTAssertEqual(dry.plan?.edits.map(\.pointer), ["/mtoon/shadingToonyFactor", "/mtoon/shadingShiftFactor"])
        XCTAssertEqual(try store.state().revision, 1)

        let envelope = MaterialsTestSupport.invoke("material shading", request, context: context)
        XCTAssertEqual(envelope.exitCode, .success, "\(envelope.errors)")
        XCTAssertEqual(envelope.status, .succeeded)
        XCTAssertEqual(envelope.revisionBefore, 1)
        XCTAssertEqual(envelope.revisionAfter, 2)
        XCTAssertEqual(envelope.result?["shadingToonyFactor"], 0.91)
        XCTAssertEqual(envelope.result?["shadingShiftFactor"], 0.71)
        XCTAssertEqual(envelope.plan?.invalidations, ["material:material:face", "build", "qa"])
        XCTAssertEqual(envelope.plan?.planHash, dry.plan?.planHash)
        let object = try XCTUnwrap(try store.state().object(id: "material:face"))
        XCTAssertEqual(object.fields["mtoon"]?["shadingToonyFactor"], 0.91)
        XCTAssertEqual(object.fields["mtoon"]?["shadingShiftFactor"], 0.71)
        XCTAssertEqual(object.revision, 2)
        let material = try MaterialCompiler.material(from: object)
        XCTAssertEqual(material.role, .faceSkin)
        XCTAssertEqual(MaterialShading.derive(toony: 0.91, shift: 0.71).shadowEnd, -0.8)

        let replay = MaterialsTestSupport.invoke("material shading", request, context: context)
        XCTAssertEqual(replay.revisionAfter, 2)
        XCTAssertEqual(try store.state().revision, 2)

        let rejected = MaterialsTestSupport.invoke("material shading", ["project": .string(projectURL.path), "material": "material:face", "shadowEnd": 0.9, "terminatorWidth": 0.5], context: context)
        XCTAssertEqual(rejected.status, .failed)
        XCTAssertEqual(rejected.exitCode, .gateFailed)
        XCTAssertEqual(rejected.errors.first?.code, .validationFailed)
        XCTAssertEqual(rejected.errors.first?.observed, -1.15)
        XCTAssertEqual(rejected.errors.first?.required, [-1, 1])
        XCTAssertEqual(try store.state().revision, 2)

        let outOfSchema = MaterialsTestSupport.invoke("material shading", ["project": .string(projectURL.path), "material": "material:face", "shadowEnd": 0, "terminatorWidth": 3], context: context)
        XCTAssertEqual(outOfSchema.exitCode, .invalidRequest)

        let missing = MaterialsTestSupport.invoke("material shading", ["project": .string(projectURL.path), "material": "material:nope", "shadowEnd": 0, "terminatorWidth": 0.2], context: context)
        XCTAssertEqual(missing.errors.first?.code, .objectNotFound)
        XCTAssertEqual(missing.exitCode, .invalidRequest)

        let stale = MaterialsTestSupport.invoke("material shading", ["project": .string(projectURL.path), "material": "material:face", "shadowEnd": 0, "terminatorWidth": 0.2, "expectedRevision": 0], context: context)
        XCTAssertEqual(stale.exitCode, .conflict)
    }

    // MARK: style attach

    func testStyleAttachVerifiesHashCopiesAssetAndRecordsStyle() throws {
        let projectURL = root.appendingPathComponent("avatar.vrmauthor")
        let store = try MaterialsTestSupport.makeProject(at: projectURL, materials: [MaterialRoleDefaults.material(id: "material:hair", role: .hair)])
        let context = MaterialsTestSupport.context(projectPath: projectURL)
        let profilePath = MaterialsTestSupport.pinnedProfile.path
        let good: JSONValue = ["project": .string(projectURL.path), "profile": ["path": .string(profilePath), "sha256": .string(StyleToolchain.pinnedProfileSHA256)], "requestId": "attach-1"]

        let dry = MaterialsTestSupport.invoke("style attach", good.merging(["dryRun": true]), context: context)
        XCTAssertEqual(dry.exitCode, .success, "\(dry.errors)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.assetsDirectory.appendingPathComponent(StyleToolchain.pinnedProfileSHA256).path))
        XCTAssertEqual(try store.state().revision, 1)

        let envelope = MaterialsTestSupport.invoke("style attach", good, context: context)
        XCTAssertEqual(envelope.exitCode, .success, "\(envelope.errors)")
        XCTAssertEqual(envelope.revisionAfter, 2)
        XCTAssertEqual(envelope.result?["invalidations"], ["qa"])
        XCTAssertTrue(envelope.warnings.isEmpty, "\(envelope.warnings)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.assetsDirectory.appendingPathComponent(StyleToolchain.pinnedProfileSHA256).path))
        let state = try store.state()
        XCTAssertEqual(state.style?["profile"]?["id"], "vroid-lineage-anime")
        XCTAssertEqual(state.style?["profile"]?["version"], "0.1.0")
        XCTAssertEqual(state.style?["profile"]?["sha256"], .string(StyleToolchain.pinnedProfileSHA256))
        XCTAssertEqual(state.style?["profile"]?["pinned"], true)
        XCTAssertEqual(state.style?["roles"]?.array?.count, 13)
        XCTAssertEqual(state.style?["materialRoles"], [["id": "material:hair", "role": "hair"]])
        XCTAssertEqual(state.object(id: "material:hair")?.fields["role"], "hair")

        let wrongHash = MaterialsTestSupport.invoke("style attach", ["project": .string(projectURL.path), "profile": ["path": .string(profilePath), "sha256": .string(String(repeating: "0", count: 64))]], context: context)
        XCTAssertEqual(wrongHash.exitCode, .invalidRequest)
        XCTAssertEqual(wrongHash.errors.first?.observed, .string(StyleToolchain.pinnedProfileSHA256))
        XCTAssertEqual(wrongHash.errors.first?.required, .string(String(repeating: "0", count: 64)))
        XCTAssertEqual(try store.state().revision, 2)

        let missing = MaterialsTestSupport.invoke("style attach", ["project": .string(projectURL.path), "profile": ["path": "nope.json", "sha256": .string(String(repeating: "0", count: 64))]], context: context)
        XCTAssertEqual(missing.exitCode, .missingCapability)
        XCTAssertEqual(missing.errors.first?.code, .missingInput)

        let notProfile = root.appendingPathComponent("not-a-profile.json")
        try Data("{\"id\":\"x\"}".utf8).write(to: notProfile)
        let invalid = MaterialsTestSupport.invoke("style attach", ["project": .string(projectURL.path), "profile": ["path": .string(notProfile.path), "sha256": .string(try SHA256Hex.hex(fileAt: notProfile))]], context: context)
        XCTAssertEqual(invalid.errors.first?.code, .validationFailed)
        XCTAssertEqual(try store.state().revision, 2)
    }

    func testHandlersAreRegisteredAndPinsMatchVerificationTable() throws {
        let registry = Registry.v1()
        for name in MaterialsHandlers.names { XCTAssertTrue(registry.operation(named: name)?.isRunnable ?? false, name) }
        XCTAssertEqual(StyleToolchain.pinnedLinterSHA256, "01679f040546fa76b6c4b8f6c84244388201ad04f0f449157c5ec634716b5881")
        XCTAssertEqual(StyleToolchain.pinnedProfileSHA256, "7eeb1f41bada650d39b7c32a31c273bbd889cca22d390164b8a7dd9b1f9c1f35")
        let diagnosis = StyleToolchain.diagnose(context: MaterialsTestSupport.context())
        XCTAssertEqual(diagnosis["styleLinter"]?["matches"], true)
        XCTAssertEqual(diagnosis["styleProfile"]?["matches"], true)
    }
}
