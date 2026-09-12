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

/// Test-only template pack: two body/face controls and a complete defaults
/// recipe; `compile` is not implemented.
struct StubTemplatePack: TemplatePack {
    static let packId = "stub-v1"
    static let zeroHash = String(repeating: "0", count: 64)

    let id = StubTemplatePack.packId
    let sha256 = SHA256Hex.hex("stub-v1 manifest")

    let controls: [ControlDescriptor] = [
        ControlDescriptor(key: "body.heightM", unit: .metres, validRange: [1.2, 2.0], recommendedRange: [1.4, 1.9], defaultValue: 1.65,
                          affects: [.avatar, .garment], dependencies: ["body.headCount"], description: "Overall stature"),
        ControlDescriptor(key: "face.eye.left.height", unit: .normalized, validRange: [-1, 1], recommendedRange: [-0.5, 0.5], defaultValue: 0, side: .left,
                          mirrorKey: "face.eye.right.height", affects: [.avatar, .expression], description: "Left eyelid/globe height blend"),
    ]

    var templateRef: TemplateRef { TemplateRef(id: id, sha256: sha256) }

    var defaults: Recipe {
        let grey = Colour(rgba: [0.5, 0.5, 0.5, 1])
        return Recipe(
            name: "stub", template: templateRef, seed: 0,
            body: ["body.heightM": 1.65], face: ["face.eye.left.height": 0],
            hair: [HairItem(id: "hair:bob", controls: HairControls(), texture: HairTexture(baseColour: grey, rootColour: grey, tipColour: grey))],
            outfits: [OutfitItem(id: "garment:top", preset: "top-v1", materialIds: ["material:cloth"])],
            textures: [TextureLayer(id: "layer:skin", targetImage: "image:skin", kind: .solid, colour: grey),
                       TextureLayer(id: "layer:blush", targetImage: "image:skin", kind: .solid, colour: grey, opacity: 0.3, blend: .multiply)],
            materials: [MaterialObject(id: "material:cloth", role: .cloth, gltf: ["doubleSided": false], mtoon: ["shadingToonyFactor": 0.9]),
                        MaterialObject(id: "material:hair", role: .hair, gltf: [:], mtoon: [:])],
            expressions: [ExpressionObject(id: "expression:blink", preset: .blink, isBinary: true)],
            lookAt: LookAtObject(),
            springs: [SpringObject(id: "spring:hair", joints: [SpringJoint(node: "node:hair0"), SpringJoint(node: "node:hair1", hitRadius: 0.01)], colliderGroups: ["group:head"])],
            colliders: [ColliderObject(id: "collider:head", node: "node:head", shape: ColliderShape(sphere: SphereShape(radius: 0.1)))],
            colliderGroups: [ColliderGroupObject(id: "group:head", colliders: ["collider:head"])],
            style: Blob(path: "style.json", sha256: StubTemplatePack.zeroHash),
            rights: RightsDeclaration(id: "rights:main", declarant: "tester", evidence: [], authors: ["tester"], meta: VRMMeta(name: "stub", authors: ["tester"])))
    }

    func compile(_ recipe: Recipe, seed: UInt64) throws -> CompiledAvatar {
        throw AuthorError.notImplemented("stub-v1 compile")
    }
}

/// Shared fixture plumbing: a temp root, a stub-bearing context and an
/// initialized project.
enum ProjectTestHarness {
    static func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("vrmauthor-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func context(cwd: URL, projectPath: URL? = nil, env: [String: String] = [:], evidence: EvidenceRegistry = EvidenceRegistry(),
                        registry: Registry = Registry.v1(),
                        templates: TemplateRegistry = TemplateRegistry(packs: [StubTemplatePack()])) -> OperationContext {
        OperationContext(projectPath: projectPath, cwd: cwd, env: env, evidenceRegistry: evidence, registry: registry, templates: templates)
    }

    /// A schema-only v1 registry with just the given installers applied, so a
    /// test can rely on every other operation being handler-less.
    static func registry(installing installers: [RegistryInstaller]) -> Registry {
        var registry = Registry.v1SchemaOnly()
        for installer in installers { installer(&registry) }
        return registry
    }

    static func invoke(_ context: OperationContext, _ name: String, _ request: JSONValue) -> ResultEnvelope {
        context.registry.invoke(name, request: request, context: context)
    }

    @discardableResult
    static func initProject(_ context: OperationContext, dir: URL, seed: Int = 7, file: StaticString = #filePath, line: UInt = #line) throws -> ResultEnvelope {
        let envelope = invoke(context, "project init", ["dir": .string(dir.path), "template": .string(StubTemplatePack.packId), "seed": .number(Double(seed))])
        XCTAssertEqual(envelope.status, .succeeded, "\(envelope.errors)", file: file, line: line)
        return envelope
    }

    static func request(_ dir: URL, _ fields: [String: JSONValue]) -> JSONValue {
        var o = fields
        o["project"] = .string(dir.path)
        return .object(o)
    }
}
