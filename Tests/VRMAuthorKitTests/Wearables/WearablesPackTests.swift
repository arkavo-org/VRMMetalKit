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

/// Acceptance pack for Phase 1C: full compile against the synthetic host.
final class WearablesPackTests: XCTestCase {
    let host = SyntheticHost()

    func compileAll() throws -> WearableOutput {
        try WearableCompiler.compile(host: host, hair: [Fixtures.hair()], outfits: [Fixtures.top(), Fixtures.bottom(), Fixtures.footwear()],
                                     accessories: [Fixtures.glasses(), Fixtures.earring("ringL", attachment: "node:earL"), Fixtures.earring("ringR", attachment: "node:earR")],
                                     materialsById: Fixtures.materials)
    }

    func testSyntheticHostIsSelfConsistent() throws {
        XCTAssertEqual(host.bodyPositions.count, host.bodyNormals.count)
        XCTAssertEqual(host.bodyPositions.count, host.bodyJoints.count)
        XCTAssertEqual(host.bodyTriangles.count % 3, 0)
        for name in [WearableRegion.chest, WearableRegion.torso, WearableRegion.waist, WearableRegion.hips, WearableRegion.thighL, WearableRegion.thighR,
                     WearableRegion.shinL, WearableRegion.footL, WearableRegion.upperArmL, WearableRegion.forearmR, WearableRegion.scalp, WearableRegion.forehead] {
            XCTAssertFalse(host.region(name).isEmpty, name)
        }
        XCTAssertGreaterThan(host.scalpSamples.count, 100)
        let bodyMesh = CompiledMesh(id: "mesh:body", name: "body", primitives: [
            CompiledPrimitive(materialId: "m", positions: host.bodyPositions, normals: host.bodyNormals, uv0: host.bodyUV0, joints0: host.bodyJoints,
                              weights0: host.bodyWeights, indices: host.bodyTriangles),
        ])
        XCTAssertNoThrow(try WearableValidation.validateMesh(bodyMesh))
    }

    func testCompileProducesEveryWearableKind() throws {
        let out = try compileAll()
        XCTAssertEqual(out.meshes.map(\.id), ["mesh:accessory:ringL", "mesh:accessory:ringR", "mesh:accessory:specs", "mesh:garment:pants", "mesh:garment:shirt",
                                              "mesh:garment:shoes", "mesh:hair:bob"])
        XCTAssertEqual(out.skins.map(\.id), ["skin:accessory:ringL", "skin:accessory:ringR", "skin:accessory:specs", "skin:hair:bob"])
        XCTAssertEqual(out.meshInstances.count, out.meshes.count)
        for instance in out.meshInstances where instance.meshId.hasPrefix("mesh:garment:") {
            XCTAssertEqual(instance.skinId, host.bodySkin.id)
        }
        XCTAssertEqual(out.springs.count, HairBobV1.Layout.clumpCount)
        XCTAssertEqual(out.colliders.map(\.id), ["collider:chest", "collider:head", "collider:neck"])
        XCTAssertEqual(out.colliderGroups.map(\.id), ["colliderGroup:body", "colliderGroup:head"])
        XCTAssertEqual(out.hiddenRegions, ["chest", "footL", "footR", "hips", "thighL", "thighR", "torso", "upperArmL", "upperArmR", "waist"])
        XCTAssertEqual(out.permittedLayers["footwear-v1"], [0, 1, 2])
        XCTAssertEqual(out.permittedLayers["top-v1"], Array(0...8))
        XCTAssertTrue(out.warnings.isEmpty, "\(out.warnings)")
        for mesh in out.meshes { XCTAssertNoThrow(try WearableValidation.validateMesh(mesh), mesh.id) }
    }

    func testDeterministicAcrossRuns() throws {
        let a = try compileAll()
        let b = try compileAll()
        XCTAssertEqual(a, b)
        XCTAssertEqual(try a.buildHash(), try b.buildHash())
        XCTAssertEqual(a.hairClumps.map(\.id), b.hairClumps.map(\.id))
        let reordered = try WearableCompiler.compile(host: host, hair: [Fixtures.hair()], outfits: [Fixtures.footwear(), Fixtures.bottom(), Fixtures.top()],
                                                     accessories: [Fixtures.earring("ringR", attachment: "node:earR"), Fixtures.glasses(), Fixtures.earring("ringL", attachment: "node:earL")],
                                                     materialsById: Fixtures.materials)
        XCTAssertEqual(try reordered.buildHash(), try a.buildHash())
    }

    func testMergesIntoCompiledAvatar() throws {
        let out = try compileAll()
        let base = CompiledAvatar(nodes: host.nodes, meshes: [], skins: [host.bodySkin], meshInstances: [], images: [], materials: [], humanoid: [:], expressions: [],
                                  lookAt: LookAtObject(), firstPerson: FirstPersonObject(), springs: [], colliders: [], colliderGroups: [],
                                  meta: VRMMeta(name: "synthetic", authors: ["test"]))
        let merged = out.merged(into: base)
        XCTAssertEqual(merged.nodes.count, host.nodes.count + out.nodes.count)
        XCTAssertEqual(merged.skins.count, 1 + out.skins.count)
        let nodeIds = Set(merged.nodes.map(\.id))
        for node in merged.nodes { if let p = node.parentId { XCTAssertTrue(nodeIds.contains(p), "parent \(p) of \(node.id)") } }
        for skin in merged.skins { for j in skin.jointNodeIds { XCTAssertTrue(nodeIds.contains(j), j) } }
        for instance in merged.meshInstances {
            XCTAssertTrue(nodeIds.contains(instance.nodeId))
            XCTAssertTrue(merged.meshes.contains { $0.id == instance.meshId })
            if let s = instance.skinId { XCTAssertTrue(merged.skins.contains { $0.id == s }, s) }
        }
        let colliderIds = Set(merged.colliders.map(\.id))
        for g in merged.colliderGroups { for c in g.colliders { XCTAssertTrue(colliderIds.contains(c)) } }
        let groupIds = Set(merged.colliderGroups.map(\.id))
        for s in merged.springs { for g in s.colliderGroups { XCTAssertTrue(groupIds.contains(g)) } }
        XCTAssertNoThrow(try WearableValidation.validateSprings(merged.springs, nodes: merged.nodes))
        XCTAssertNoThrow(try merged.buildHash())
    }

    func testEmptyInputsProduceEmptyOutput() throws {
        let out = try WearableCompiler.compile(host: host, hair: [], outfits: [], accessories: [], materialsById: [:])
        XCTAssertTrue(out.meshes.isEmpty)
        XCTAssertTrue(out.colliders.isEmpty)
        XCTAssertTrue(out.springs.isEmpty)
        XCTAssertEqual(out.permittedLayers.count, 4)
    }
}
