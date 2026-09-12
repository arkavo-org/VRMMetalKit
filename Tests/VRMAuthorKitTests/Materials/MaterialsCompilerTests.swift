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

final class MaterialsCompilerTests: XCTestCase {
    func code(_ body: () throws -> Void) -> AuthorErrorCode? {
        do { try body() } catch let e as AuthorError { return e.code } catch let e as ModelValidationError { return e.errors.first?.code } catch { return nil }
        return nil
    }

    func testRoleDefaultsFillAbsentFieldsAndDefaultImagesAreCompiled() throws {
        let materials = [MaterialObject(id: "material:face", role: .faceSkin, gltf: [:], mtoon: [:]),
                         MaterialObject(id: "material:iris", role: .iris, gltf: [:], mtoon: ["shadingToonyFactor": 0.5])]
        let out = try MaterialCompiler.compile(materials: materials, textures: [], images: [], seed: 3)
        XCTAssertEqual(out.materials.map(\.id), ["material:face", "material:iris"])
        XCTAssertEqual(out.images.map(\.id), ["image:face_skin", "image:iris"])
        let face = out.materials[0]
        XCTAssertEqual(face.gltf["pbrMetallicRoughness"]?["baseColorTexture"]?["imageId"], "image:face_skin")
        XCTAssertEqual(face.gltf["pbrMetallicRoughness"]?["baseColorTexture"]?["texCoord"], 0)
        XCTAssertEqual(face.gltf["pbrMetallicRoughness"]?["metallicFactor"], 0)
        XCTAssertEqual(face.mtoon["specVersion"], "1.0")
        XCTAssertEqual(face.mtoon["shadeMultiplyTexture"]?["imageId"], "image:face_skin")
        XCTAssertEqual(face.mtoon["outlineWidthMode"], "worldCoordinates")
        XCTAssertEqual(face.gltf["extensions"]?["KHR_materials_emissive_strength"], nil, "schema defaults never invent extension objects")
        XCTAssertEqual(out.materials[1].mtoon["shadingToonyFactor"], 0.5, "recipe values win over role defaults")
        XCTAssertEqual(out.materials[1].mtoon["shadingShiftFactor"], 0.75)
        XCTAssertEqual(out.roles, ["material:face": .faceSkin, "material:iris": .iris])
        for leaf in MaterialSchemas.mtoon.leafPointers() where !leaf.contains("Texture") {
            XCTAssertNotNil(try JSONPointer(leaf).get(in: face.mtoon), leaf)
        }
        let facePNG = try PNGEncoder.chunks(of: out.images[0].pngData)
        XCTAssertEqual(facePNG[0].payload[0..<8].map { $0 }, [0, 0, 4, 0, 0, 0, 4, 0], "1024×1024")
        XCTAssertEqual(try PNGEncoder.chunks(of: out.images[1].pngData)[0].payload[0..<8].map { $0 }, [0, 0, 4, 0, 0, 0, 4, 0], "iris 1024×1024")
        XCTAssertEqual(out.images[0].colourSpace, .srgb)
        XCTAssertEqual(out.images[0].usage, .colour)
        XCTAssertEqual(out.rasters["image:iris"]?.width, 1024)
        let again = try MaterialCompiler.compile(materials: materials, textures: [], images: [], seed: 3)
        XCTAssertEqual(again.images.map(\.pngData), out.images.map(\.pngData), "deterministic bytes")
        XCTAssertEqual(again.materials, out.materials)
    }

    func testLayersCompositeOntoDefaultsAndDeclaredImages() throws {
        let cloth = MaterialObject(id: "material:top", role: .cloth, gltf: [:], mtoon: [:])
        let plain = try MaterialCompiler.compile(materials: [cloth], textures: [], images: [], seed: 1)
        let tinted = try MaterialCompiler.compile(materials: [cloth], textures: [
            TextureLayer(id: "layer:tint", targetImage: "image:cloth", kind: .solid, colour: Colour(rgba: [1, 0, 0, 1]), opacity: 0.5, blend: .multiply),
        ], images: [], seed: 1)
        XCTAssertNotEqual(plain.images[0].pngData, tinted.images[0].pngData)
        let base = plain.rasters["image:cloth"]![10, 10]
        let mixed = tinted.rasters["image:cloth"]![10, 10]
        XCTAssertEqual(mixed.x, base.x, accuracy: 1e-6)
        XCTAssertEqual(mixed.y, base.y * 0.5, accuracy: 1e-6)
        XCTAssertEqual(mixed.z, base.z * 0.5, accuracy: 1e-6)

        let custom = ImageSpec(id: "image:custom", width: 4, height: 4, colourSpace: .srgb, usage: .colour)
        let material = MaterialObject(id: "material:acc", role: .accessory, gltf: ["pbrMetallicRoughness": ["baseColorTexture": ["imageId": "image:custom"]]], mtoon: [:])
        let out = try MaterialCompiler.compile(materials: [material], textures: [
            TextureLayer(id: "layer:fill", targetImage: "image:custom", kind: .solid, colour: Colour(rgba: [0.5, 0.5, 0.5, 1])),
            TextureLayer(id: "layer:from-default", targetImage: "image:custom", kind: .image, image: "image:iris", opacity: 1),
        ], images: [custom], seed: 1)
        XCTAssertEqual(out.images.map(\.id), ["image:accessory", "image:custom"], "shadeMultiplyTexture still references the role default")
        XCTAssertEqual(out.imageSpecs.map(\.id), ["image:accessory", "image:custom"])
        let corner = out.rasters["image:custom"]![0, 0]
        XCTAssertEqual(corner, SIMD4(0.5, 0.5, 0.5, 1), "iris default is transparent at the corner so the fill shows")
        XCTAssertEqual(out.rasters["image:custom"]![2, 2].w, 1)
        XCTAssertLessThan(out.rasters["image:custom"]![2, 2].x, 0.5, "iris disc composited over the fill")
    }

    func testRejectsBrokenReferencesAndIllegalCombinations() throws {
        let undeclared = MaterialObject(id: "m", role: .cloth, gltf: ["pbrMetallicRoughness": ["baseColorTexture": ["imageId": "image:missing"]]], mtoon: [:])
        XCTAssertEqual(code { _ = try MaterialCompiler.compile(materials: [undeclared], textures: [], images: [], seed: 0) }, .validationFailed)

        let uv1 = MaterialObject(id: "m", role: .cloth, gltf: ["pbrMetallicRoughness": ["baseColorTexture": ["imageId": "image:cloth", "texCoord": 1]]], mtoon: [:])
        XCTAssertEqual(code { _ = try MaterialCompiler.compile(materials: [uv1], textures: [], images: [], seed: 0) }, .validationFailed)

        let normalOnColour = MaterialObject(id: "m", role: .cloth, gltf: ["normalTexture": ["imageId": "image:cloth"]], mtoon: [:])
        XCTAssertEqual(code { _ = try MaterialCompiler.compile(materials: [normalOnColour], textures: [], images: [], seed: 0) }, .validationFailed)

        let normalSpec = ImageSpec(id: "image:n", width: 2, height: 2, colourSpace: .linear, usage: .normal)
        let normalOK = MaterialObject(id: "m", role: .cloth, gltf: ["normalTexture": ["imageId": "image:n", "scale": 0.8]], mtoon: [:])
        let out = try MaterialCompiler.compile(materials: [normalOK], textures: [
            TextureLayer(id: "l", targetImage: "image:n", kind: .solid, colour: Colour(rgba: [0.5, 0.5, 1, 1])),
        ], images: [normalSpec], seed: 0)
        XCTAssertEqual(out.images.first { $0.id == "image:n" }?.usage, .normal)
        XCTAssertEqual(out.rasters["image:n"]?.rgba8(colourSpace: .linear, usage: .normal), Array(repeating: [128, 128, 255, 255], count: 4).flatMap { $0 })
        let colourOnNormal = MaterialObject(id: "m", role: .cloth, gltf: ["emissiveTexture": ["imageId": "image:n"]], mtoon: [:])
        XCTAssertEqual(code { _ = try MaterialCompiler.compile(materials: [colourOnNormal], textures: [], images: [normalSpec], seed: 0) }, .validationFailed)

        let badQueue = MaterialObject(id: "m", role: .iris, gltf: [:], mtoon: ["renderQueueOffsetNumber": 2])
        XCTAssertEqual(code { _ = try MaterialCompiler.compile(materials: [badQueue], textures: [], images: [], seed: 0) }, .validationFailed)
        let zWriteQueue = MaterialObject(id: "m", role: .iris, gltf: [:], mtoon: ["renderQueueOffsetNumber": 2, "transparentWithZWrite": true])
        XCTAssertNoThrow(try MaterialCompiler.compile(materials: [zWriteQueue], textures: [], images: [], seed: 0))

        let unknown = MaterialObject(id: "m", role: .cloth, gltf: ["extensions": ["KHR_materials_clearcoat": [:]]], mtoon: [:])
        XCTAssertEqual(code { _ = try MaterialCompiler.compile(materials: [unknown], textures: [], images: [], seed: 0) }, .unknownField)

        let orphanLayer = TextureLayer(id: "l", targetImage: "image:nowhere", kind: .solid, colour: Colour(rgba: [1, 1, 1, 1]))
        XCTAssertEqual(code { _ = try MaterialCompiler.compile(materials: [], textures: [orphanLayer], images: [], seed: 0) }, .validationFailed)
        let duplicate = [MaterialObject(id: "m", role: .cloth, gltf: [:], mtoon: [:]), MaterialObject(id: "m", role: .hair, gltf: [:], mtoon: [:])]
        XCTAssertEqual(code { _ = try MaterialCompiler.compile(materials: duplicate, textures: [], images: [], seed: 0) }, .invalidRequest)
        let big = ImageSpec(id: "image:big", width: 5000, height: 1, colourSpace: .srgb, usage: .colour)
        XCTAssertEqual(code { _ = try MaterialCompiler.compile(materials: [], textures: [], images: [big], seed: 0) }, .invalidRequest)
    }

    func testExternalSourcesAndProjectObjectRoundTrip() throws {
        let external = RasterImage(width: 2, height: 2, fill: SIMD4(0, 1, 0, 1))
        let material = MaterialObject(id: "material:x", role: .other, gltf: ["pbrMetallicRoughness": ["baseColorTexture": ["imageId": "image:imported"]]], mtoon: [:])
        let spec = ImageSpec(id: "image:imported", width: 2, height: 2, colourSpace: .srgb, usage: .colour)
        let out = try MaterialCompiler.compile(materials: [material], textures: [], images: [spec], seed: 0, sources: ["image:imported": external])
        XCTAssertEqual(out.rasters["image:imported"]?[1, 1], SIMD4(0, 1, 0, 1))
        XCTAssertEqual(out.images.map(\.id), ["image:imported", "image:other"])

        let object = try MaterialCompiler.projectObject(for: MaterialRoleDefaults.material(id: "material:hair", role: .hair), provenance: ["source": "pack"])
        XCTAssertEqual(object.kind, .material)
        XCTAssertEqual(object.writablePointers.map(\.description), ["/role", "/gltf", "/mtoon"])
        XCTAssertTrue(object.isWritable(try JSONPointer("/mtoon/shadingToonyFactor")))
        let decoded = try MaterialCompiler.material(from: object)
        XCTAssertEqual(try MaterialCompiler.resolve(decoded), try MaterialCompiler.resolve(MaterialRoleDefaults.material(id: "material:hair", role: .hair)))
        let node = try ProjectObject(id: "node:x", kind: .node, provenance: .null, writablePointers: [], fields: [:])
        XCTAssertEqual(code { _ = try MaterialCompiler.material(from: node) }, .invalidRequest)
    }
}
