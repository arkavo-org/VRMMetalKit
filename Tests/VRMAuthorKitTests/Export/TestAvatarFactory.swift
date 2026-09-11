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

/// A small but complete CompiledAvatar: a cube body skinned to three bones with
/// every required humanoid bone mapped, blink/aa morphs, two MToon materials, one
/// 2x2 PNG, one hair spring chain, one head collider and group, lookAt,
/// firstPerson and complete meta.
enum TestAvatarFactory {
    static let png2x2: Data = Data([
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xb6, 0x0d, 0x24, 0x00, 0x00, 0x00, 0x14, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0xf8, 0xcf, 0xc0, 0x00,
        0x46, 0x40, 0x82, 0xe1, 0x3f, 0x90, 0x02, 0x02, 0x00, 0x51, 0xc2, 0x09, 0xf7, 0xc8, 0x66, 0x12, 0x1f, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,
        0x44, 0xae, 0x42, 0x60, 0x82,
    ])

    static let height: Float = 1.6

    static func meta() -> VRMMeta {
        VRMMeta(name: "Test Avatar", version: "1.0.0", authors: ["Test Author"], copyrightInformation: "(c) Test", contactInformation: "test@example.com",
                references: [], thirdPartyLicenses: "", licenseUrl: VRMMeta.vrm10LicenseUrl, avatarPermission: .onlyAuthor,
                allowExcessivelyViolentUsage: false, allowExcessivelySexualUsage: false, commercialUsage: .personalNonProfit,
                allowPoliticalOrReligiousUsage: false, allowAntisocialOrHateUsage: false, creditNotation: .required, allowRedistribution: false, modification: .prohibited)
    }

    static func nodes() -> [CompiledNode] {
        func n(_ id: String, _ parent: String?, _ t: SIMD3<Float>, _ bone: VRMHumanBone? = nil) -> CompiledNode {
            CompiledNode(id: "node:\(id)", name: id, parentId: parent.map { "node:\($0)" }, translation: t, humanoidBone: bone)
        }
        return [
            n("hips", nil, [0, 0.9, 0], .hips),
            n("spine", "hips", [0, 0.1, 0], .spine),
            n("chest", "spine", [0, 0.15, 0], .chest),
            n("neck", "chest", [0, 0.2, 0], .neck),
            n("head", "neck", [0, 0.1, 0], .head),
            n("hair0", "head", [0, 0.1, -0.05]),
            n("hair1", "hair0", [0, -0.1, 0]),
            n("hair2", "hair1", [0, -0.1, 0]),
            n("leftUpperLeg", "hips", [0.1, -0.05, 0], .leftUpperLeg),
            n("leftLowerLeg", "leftUpperLeg", [0, -0.4, 0], .leftLowerLeg),
            n("leftFoot", "leftLowerLeg", [0, -0.4, 0], .leftFoot),
            n("rightUpperLeg", "hips", [-0.1, -0.05, 0], .rightUpperLeg),
            n("rightLowerLeg", "rightUpperLeg", [0, -0.4, 0], .rightLowerLeg),
            n("rightFoot", "rightLowerLeg", [0, -0.4, 0], .rightFoot),
            n("leftUpperArm", "chest", [0.2, 0.1, 0], .leftUpperArm),
            n("leftLowerArm", "leftUpperArm", [0.25, 0, 0], .leftLowerArm),
            n("leftHand", "leftLowerArm", [0.25, 0, 0], .leftHand),
            n("rightUpperArm", "chest", [-0.2, 0.1, 0], .rightUpperArm),
            n("rightLowerArm", "rightUpperArm", [-0.25, 0, 0], .rightLowerArm),
            n("rightHand", "rightLowerArm", [-0.25, 0, 0], .rightHand),
            n("body", nil, .zero),
        ]
    }

    static func cube(height: Float = height, blinkDelta: Float = -0.02) -> CompiledMesh {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var joints: [SIMD4<UInt16>] = []
        var weights: [SIMD4<Float>] = []
        for i in 0..<8 {
            let x: Float = (i & 1) == 0 ? -0.25 : 0.25
            let y: Float = (i & 2) == 0 ? 0 : height
            let z: Float = (i & 4) == 0 ? -0.15 : 0.15
            positions.append([x, y, z])
            let centred = SIMD3<Float>(x, y - height / 2, z)
            normals.append(centred / (centred * centred).sum().squareRoot())
            uvs.append([(x + 0.25) / 0.5, y / height])
            joints.append([0, 1, 2, 0])
            weights.append(y == 0 ? [1, 0, 0, 0] : [0, 0.25, 0.75, 0])
        }
        let faces: [(String, [UInt32])] = [
            ("body", [0, 2, 1, 1, 2, 3, 4, 5, 6, 5, 7, 6, 2, 6, 3, 3, 6, 7, 0, 1, 4, 1, 5, 4]),
            ("face", [0, 4, 2, 2, 4, 6, 1, 3, 5, 3, 7, 5]),
        ]
        let blink = CompiledMorph(name: "blink", positionDeltas: positions.map { $0.y > 0 ? [0, blinkDelta, 0] : .zero })
        let aa = CompiledMorph(name: "aa", positionDeltas: positions.map { $0.y > 0 ? [0, 0, 0.01] : .zero })
        return CompiledMesh(id: "mesh:body", name: "body", primitives: faces.map { material, indices in
            CompiledPrimitive(materialId: "material:\(material)", positions: positions, normals: normals, uv0: uvs, joints0: joints, weights0: weights, indices: indices,
                              morphTargets: [blink, aa])
        })
    }

    static func skin() -> CompiledSkin {
        func inverseTranslation(_ y: Float) -> SIMD16<Float> {
            var m = SIMD16<Float>(repeating: 0)
            m[0] = 1; m[5] = 1; m[10] = 1; m[15] = 1
            m[13] = -y
            return m
        }
        return CompiledSkin(id: "skin:body", jointNodeIds: ["node:hips", "node:spine", "node:head"], inverseBindMatrices: [inverseTranslation(0.9), inverseTranslation(1.0), inverseTranslation(1.45)])
    }

    static func materials() -> [MaterialObject] {
        let mtoon: JSONValue = [
            "shadeColorFactor": [0.8, 0.6, 0.5], "shadingToonyFactor": 0.9, "shadingShiftFactor": 0, "giEqualizationFactor": 0.9,
            "outlineWidthMode": "none", "outlineWidthFactor": 0, "outlineColorFactor": [0, 0, 0], "outlineLightingMixFactor": 1,
            "matcapFactor": [1, 1, 1], "parametricRimColorFactor": [0, 0, 0], "parametricRimFresnelPowerFactor": 5, "parametricRimLiftFactor": 0,
            "rimLightingMixFactor": 0, "renderQueueOffsetNumber": 0, "transparentWithZWrite": false,
            "uvAnimationScrollXSpeedFactor": 0, "uvAnimationScrollYSpeedFactor": 0, "uvAnimationRotationSpeedFactor": 0,
        ]
        let body = MaterialObject(id: "material:body", role: .bodySkin, gltf: [
            "pbrMetallicRoughness": ["baseColorFactor": [1, 0.85, 0.75, 1], "baseColorTexture": ["image": "image:skin", "texCoord": 0], "metallicFactor": 0, "roughnessFactor": 1],
            "alphaMode": "OPAQUE", "doubleSided": false,
        ], mtoon: mtoon)
        let face = MaterialObject(id: "material:face", role: .faceSkin, gltf: [
            "pbrMetallicRoughness": [
                "baseColorFactor": [1, 0.9, 0.85, 1],
                "baseColorTexture": ["image": "image:skin", "extensions": ["KHR_texture_transform": ["offset": [0, 0], "scale": [1, 1]]]],
                "metallicFactor": 0, "roughnessFactor": 1,
            ],
            "alphaMode": "OPAQUE", "doubleSided": false,
        ], mtoon: mtoon.merging(["shadingToonyFactor": 0.95, "shadingShiftFactor": -0.1, "shadeMultiplyTexture": ["image": "image:skin"]]))
        return [body, face]
    }

    static func expressions() -> [ExpressionObject] {
        [
            ExpressionObject(id: "expression:blink", preset: .blink, isBinary: false, overrideBlink: .none, morphTargetBinds: [MorphTargetBind(mesh: "mesh:body", target: "blink", weight: 1)]),
            ExpressionObject(id: "expression:aa", preset: .aa, overrideMouth: .blend, morphTargetBinds: [MorphTargetBind(mesh: "mesh:body", target: "aa", weight: 1)]),
            ExpressionObject(id: "expression:happy", preset: .happy, materialColorBinds: [MaterialColorBind(material: "material:face", type: .color, targetValue: [1, 0.8, 0.8, 1])],
                             textureTransformBinds: [TextureTransformBind(material: "material:face", scale: [1, 1], offset: [0.1, 0])]),
            ExpressionObject(id: "expression:wink", name: "wink", isBinary: true, morphTargetBinds: [MorphTargetBind(mesh: "mesh:body", target: "blink", weight: 0.5)]),
        ]
    }

    static func make(height: Float = height, blinkDelta: Float = -0.02, meta: VRMMeta = meta()) -> CompiledAvatar {
        var humanoid: [VRMHumanBone: String] = [:]
        for node in nodes() { if let bone = node.humanoidBone { humanoid[bone] = node.id } }
        return CompiledAvatar(
            nodes: nodes(), meshes: [cube(height: height, blinkDelta: blinkDelta)], skins: [skin()],
            meshInstances: [CompiledMeshInstance(nodeId: "node:body", meshId: "mesh:body", skinId: "skin:body")],
            images: [CompiledImage(id: "image:skin", pngData: png2x2, colourSpace: .srgb, usage: .colour)],
            materials: materials(), humanoid: humanoid, expressions: expressions(),
            lookAt: LookAtObject(offsetFromHeadBone: [0, 0.06, 0], type: .bone),
            firstPerson: FirstPersonObject(meshAnnotations: [MeshAnnotation(mesh: "mesh:body", type: .both)]),
            springs: [SpringObject(id: "spring:hair", name: "hair", center: nil, joints: [
                SpringJoint(node: "node:hair0", hitRadius: 0.02, stiffness: 1, gravityPower: 0.1, dragForce: 0.4),
                SpringJoint(node: "node:hair1", hitRadius: 0.02, stiffness: 0.8, gravityPower: 0.1, dragForce: 0.4),
                SpringJoint(node: "node:hair2", hitRadius: 0.01, stiffness: 0.5, gravityPower: 0.1, dragForce: 0.4),
            ], colliderGroups: ["cgroup:head"])],
            colliders: [ColliderObject(id: "collider:head", node: "node:head", shape: ColliderShape(sphere: SphereShape(offset: [0, 0.05, 0], radius: 0.1)))],
            colliderGroups: [ColliderGroupObject(id: "cgroup:head", name: "head", colliders: ["collider:head"])],
            meta: meta)
    }
}

/// A template pack whose compile() returns the factory avatar, scaled by the
/// `body.heightM` control and carrying the recipe's resolved meta.
struct StubTemplatePack: TemplatePack {
    static let packSha256 = "5f0c1a7e3d2b4c6a8e9f0123456789abcdef0123456789abcdef0123456789ab"
    static let profileSha256 = QAPins.defaultProfileSha256

    var id: String { "stub-v1" }
    var sha256: String { StubTemplatePack.packSha256 }
    var ignoresControls = false
    var blinkDelta: Float = -0.02

    var controls: [ControlDescriptor] {
        [ControlDescriptor(key: "body.heightM", unit: .metres, validRange: [0.5, 3.0], recommendedRange: [1.4, 1.8], defaultValue: 1.6, affects: [.mesh, .node], description: "Overall height")]
    }

    var defaults: Recipe {
        let meta = TestAvatarFactory.meta()
        return Recipe(name: "stub avatar", template: TemplateRef(id: id, sha256: sha256), seed: 0, body: ["body.heightM": 1.6], face: [:], hair: [], outfits: [],
                      textures: [], materials: [], expressions: [], lookAt: LookAtObject(), springs: [], colliders: [], colliderGroups: [],
                      style: Blob(path: QAPins.defaultProfilePath, sha256: StubTemplatePack.profileSha256),
                      rights: RightsDeclaration(id: "rights:stub", declarant: "Test Author", evidence: [], authors: meta.authors, meta: meta))
    }

    func compile(_ recipe: Recipe, seed: UInt64) throws -> CompiledAvatar {
        let height = ignoresControls ? TestAvatarFactory.height : Float(recipe.body["body.heightM"] ?? 1.6)
        var avatar = TestAvatarFactory.make(height: height, blinkDelta: blinkDelta, meta: recipe.rights.meta)
        for material in recipe.materials { avatar.materials.removeAll { $0.id == material.id }; avatar.materials.append(material) }
        return avatar
    }
}

/// Project fixture helpers shared by the export and QA suites.
struct TestProject {
    let root: URL
    let projectURL: URL
    let store: ProjectStore
    var templates: TemplateRegistry
    var registry: Registry
    var env: [String: String]

    static func registry(rights: any RecipeRightsHook = NoRightsHook(), render: any RenderAdapter = NoRenderer(),
                         consumer: any ConsumerImporter = SelfReimportConsumer(), extra: [RegistryInstaller] = []) -> Registry {
        var registry = Registry.v1SchemaOnly()
        DiscoveryHandlers.install(&registry)
        ExportQAInstaller.installer(rights: rights, render: render, consumer: consumer)(&registry)
        for installer in extra { installer(&registry) }
        return registry
    }

    static func make(pack: any TemplatePack = StubTemplatePack(), registry: Registry = TestProject.registry(), env: [String: String] = [:]) throws -> TestProject {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vrmauthor-e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projectURL = root.appendingPathComponent("avatar.vrmauthor")
        let store = try ProjectStore.create(at: projectURL, name: "avatar", template: TemplateRef(id: pack.id, sha256: pack.sha256), seed: 0,
                                            lock: ["tool": "vrm-author", "version": .string(ToolInfo.current.version), "template": .string(pack.sha256)])
        return TestProject(root: root, projectURL: projectURL, store: store, templates: TemplateRegistry(packs: [pack]), registry: registry, env: env)
    }

    var context: OperationContext {
        OperationContext(projectPath: projectURL, cwd: root, env: env, registry: registry, templates: templates)
    }

    func invoke(_ name: String, _ request: JSONValue) -> ResultEnvelope {
        var merged = request.object ?? [:]
        if registry.operation(named: name)?.kind != .projectFree { merged["project"] = .string(projectURL.path) }
        return registry.invoke(name, request: .object(merged), context: context)
    }

    func path(_ name: String) -> String { root.appendingPathComponent(name).path }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func applyDefaultRecipe(requestId: String = "apply-1", mutate: (inout Recipe) -> Void = { _ in }) throws -> ResultEnvelope {
        var recipe = StubTemplatePack().defaults
        mutate(&recipe)
        let envelope = invoke("recipe apply", ["requestId": .string(requestId), "recipe": try recipe.jsonValue()])
        guard envelope.status == .succeeded else { throw AuthorError(code: .internalError, message: "recipe apply failed: \(envelope.errors)") }
        return envelope
    }
}
