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

final class WearableAccessoryTests: XCTestCase {
    let host = SyntheticHost()

    func compile(_ accessories: [AccessoryItem]) throws -> WearableOutput {
        try WearableCompiler.compile(host: host, hair: [], outfits: [], accessories: accessories, materialsById: Fixtures.materials)
    }

    func centroid(_ prim: CompiledPrimitive) -> SIMD3<Float> { prim.positions.reduce(SIMD3<Float>.zero, +) / Float(prim.positions.count) }

    func testGlassesAttachToHeadAtEyeHeight() throws {
        let out = try compile([Fixtures.glasses()])
        let mesh = try XCTUnwrap(out.meshes.first { $0.id == "mesh:accessory:specs" })
        XCTAssertEqual(mesh.primitives.count, 2)
        XCTAssertEqual(mesh.primitives[0].materialId, "material:frame")
        XCTAssertEqual(mesh.primitives[1].materialId, "material:lens")
        let skin = try XCTUnwrap(out.skins.first { $0.id == "skin:accessory:specs" })
        XCTAssertEqual(skin.jointNodeIds, ["node:head"])
        let node = try XCTUnwrap(out.nodes.first { $0.id == "node:accessory:specs" })
        XCTAssertEqual(node.parentId, "node:head")
        XCTAssertEqual(out.meshInstances, [CompiledMeshInstance(nodeId: "node:accessory:specs", meshId: "mesh:accessory:specs", skinId: "skin:accessory:specs")])
        let lenses = mesh.primitives[1]
        XCTAssertEqual(lenses.positions.count, 8)
        let c = centroid(lenses)
        XCTAssertEqual(c.y, SyntheticHost.eyeHeight, accuracy: 1e-4)
        XCTAssertEqual(c.x, 0, accuracy: 1e-4)
        XCTAssertGreaterThan(c.z, host.leftEyeCentre.z + HairBobV1.Layout.eyeRadiusM)
        let leftLens = lenses.positions[0..<4].reduce(SIMD3<Float>.zero, +) / 4
        XCTAssertEqual(leftLens.x, host.leftEyeCentre.x, accuracy: 1e-4)
        for prim in mesh.primitives {
            for j in try XCTUnwrap(prim.joints0) { XCTAssertEqual(j, SIMD4(0, 0, 0, 0)) }
            for w in try XCTUnwrap(prim.weights0) { XCTAssertEqual(w, SIMD4(1, 0, 0, 0)) }
        }
        let inv = Mat4(skin.inverseBindMatrices[0])
        XCTAssertLessThan(V3.length(inv.transformPoint(host.worlds["node:head"]!)), 1e-5)
        XCTAssertGreaterThan(mesh.primitives[0].positions.map(\.z).min()!, host.headCentre.z - host.headRadius - 0.03)
    }

    func testTransformIsBakedIntoGlassesGeometry() throws {
        let base = try compile([Fixtures.glasses()])
        let moved = try compile([Fixtures.glasses(transform: Transform(translation: [0, 0.01, 0.005], rotation: [0, 0, 0, 1], scale: [1.5, 1.5, 1.5]))])
        let a = centroid(base.meshes[0].primitives[1])
        let b = centroid(moved.meshes[0].primitives[1])
        let headLocalA = a - host.worlds["node:head"]!
        let expected = headLocalA * 1.5 + SIMD3(0, 0.01, 0.005) + host.worlds["node:head"]!
        XCTAssertLessThan(V3.distance(b, expected), 1e-4)
        XCTAssertEqual(moved.skins[0].inverseBindMatrices, base.skins[0].inverseBindMatrices)
        let quarterTurn = Transform(rotation: [0, sin(Double.pi / 4), 0, cos(Double.pi / 4)])
        let turned = try compile([Fixtures.glasses(transform: quarterTurn)])
        let n = turned.meshes[0].primitives[1].normals[0]
        XCTAssertEqual(abs(n.x), 1, accuracy: 1e-4)
    }

    func testEarringsAttachToTheirEarNodes() throws {
        let out = try compile([Fixtures.earring("ringL", attachment: "node:earL"), Fixtures.earring("ringR", attachment: "node:earR")])
        for (id, ear) in [("ringL", "node:earL"), ("ringR", "node:earR")] {
            let skin = try XCTUnwrap(out.skins.first { $0.id == "skin:accessory:\(id)" })
            XCTAssertEqual(skin.jointNodeIds, [ear])
            let node = try XCTUnwrap(out.nodes.first { $0.id == "node:accessory:\(id)" })
            XCTAssertEqual(node.parentId, ear)
            let prim = try XCTUnwrap(out.meshes.first { $0.id == "mesh:accessory:\(id)" }).primitives[0]
            let earWorld = host.worlds[ear]!
            let c = centroid(prim)
            XCTAssertLessThan(c.y, earWorld.y - 0.005)
            XCTAssertGreaterThan(c.y, earWorld.y - 0.03)
            XCTAssertEqual(c.x, earWorld.x, accuracy: 0.002)
            XCTAssertLessThanOrEqual(prim.positions.map(\.y).max()!, earWorld.y + 1e-5)
            XCTAssertNoThrow(try WearableValidation.validateMesh(CompiledMesh(id: id, name: id, primitives: [prim])))
        }
    }

    func testCatEarsSitOnTheCrown() throws {
        let out = try compile([Fixtures.catEars()])
        let mesh = try XCTUnwrap(out.meshes.first { $0.id == "mesh:accessory:ears" })
        XCTAssertEqual(mesh.primitives.count, 2)
        XCTAssertEqual(mesh.primitives[0].materialId, "material:fur")
        XCTAssertEqual(mesh.primitives[1].materialId, "material:innerEar")
        let skin = try XCTUnwrap(out.skins.first { $0.id == "skin:accessory:ears" })
        XCTAssertEqual(skin.jointNodeIds, ["node:head"])
        // Both ears sit on the crown: above the head centre, one per side,
        // symmetric about x = 0.
        let c = centroid(mesh.primitives[0])
        XCTAssertGreaterThan(c.y, host.headCentre.y)
        XCTAssertEqual(c.x, 0, accuracy: 1e-4)
        let topY = mesh.primitives[0].positions.map(\.y).max()!
        XCTAssertGreaterThan(topY, host.headCentre.y + host.headRadius + 0.03)
        XCTAssertNoThrow(try WearableValidation.validateMesh(mesh))
    }

    func testUnknownAttachmentIsTyped() {
        XCTAssertThrowsError(try compile([Fixtures.earring("x", attachment: "node:toeL")])) { error in
            let e = error as? AuthorError
            XCTAssertEqual(e?.code, .attachmentNotFound)
            XCTAssertEqual(e?.objectId, "accessory:x")
            XCTAssertEqual(e?.path, "/attachment")
            XCTAssertEqual(e?.observed, .string("node:toeL"))
        }
    }

    func testDisabledAccessoriesAreSkipped() throws {
        var item = Fixtures.glasses()
        item.enabled = false
        let out = try compile([item])
        XCTAssertTrue(out.meshes.isEmpty)
    }
}
