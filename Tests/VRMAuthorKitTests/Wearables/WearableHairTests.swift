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

final class WearableHairTests: XCTestCase {
    let host = SyntheticHost()

    func compileHair(_ controls: HairControls = HairControls()) throws -> WearableOutput {
        try WearableCompiler.compile(host: host, hair: [Fixtures.hair(controls: controls)], outfits: [], accessories: [], materialsById: Fixtures.materials)
    }

    func hairPrimitive(_ out: WearableOutput) throws -> CompiledPrimitive {
        let mesh = try XCTUnwrap(out.meshes.first { $0.id == "mesh:hair:bob" })
        XCTAssertEqual(mesh.primitives.count, 1)
        return mesh.primitives[0]
    }

    func worldPosition(_ nodeId: String, in out: WearableOutput) -> SIMD3<Float> {
        var byId: [String: CompiledNode] = [:]
        for n in out.nodes { byId[n.id] = n }
        var p = SIMD3<Float>.zero
        var cursor: String? = nodeId
        while let id = cursor, let node = byId[id] {
            p += node.translation
            cursor = node.parentId
        }
        if let parent = cursor, let w = host.worlds[parent] { p += w }
        return p
    }

    func testClumpLayoutIsPackConstant() throws {
        let out = try compileHair()
        XCTAssertEqual(out.hairClumps.count, HairBobV1.Layout.clumpCount)
        XCTAssertEqual(out.hairClumps.count, HairBobV1.Layout.clumpCount)
        XCTAssertGreaterThanOrEqual(out.hairClumps.filter(\.isBang).count, HairBobV1.Layout.bangAzimuthsDeg.count)
        XCTAssertEqual(out.hairClumps.map(\.id), (0..<HairBobV1.Layout.clumpCount).map { String(format: "hair:bob:c%02d", $0) })
        XCTAssertEqual(Set(out.hairClumps.map(\.rootSampleIndex)).count, HairBobV1.Layout.clumpCount)
        XCTAssertEqual(out.nodes.count, 1 + HairBobV1.Layout.clumpCount * HairBobV1.Layout.nodesPerClump)
    }

    func testEveryClumpRootIsOnAScalpSample() throws {
        let out = try compileHair()
        let prim = try hairPrimitive(out)
        for clump in out.hairClumps {
            let sample = host.scalpSamples[clump.rootSampleIndex]
            XCTAssertLessThan(V3.distance(clump.rootPosition, sample.position), 0.001, clump.id)
            let rootNode = worldPosition(clump.nodeIds[0], in: out)
            XCTAssertLessThan(V3.distance(rootNode, sample.position), 0.001, clump.id)
            let centre = (prim.positions[clump.vertexStart] + prim.positions[clump.vertexStart + 2]) / 2
            XCTAssertLessThan(V3.distance(centre, sample.position), 0.001, clump.id)
            let nearest = host.scalpSamples.map { V3.distance($0.position, rootNode) }.min()!
            XCTAssertLessThan(nearest, 0.001)
        }
    }

    func testStripAndBoneSegmentsAreContinuous() throws {
        let out = try compileHair()
        let prim = try hairPrimitive(out)
        for clump in out.hairClumps {
            let sections = clump.vertexCount / 3
            var lengths: [Float] = []
            for i in 0..<(sections - 1) {
                let a = (prim.positions[clump.vertexStart + 3 * i] + prim.positions[clump.vertexStart + 3 * i + 2]) / 2
                let b = (prim.positions[clump.vertexStart + 3 * i + 3] + prim.positions[clump.vertexStart + 3 * i + 5]) / 2
                lengths.append(V3.distance(a, b))
            }
            for i in 1..<lengths.count {
                XCTAssertLessThanOrEqual(abs(lengths[i] - lengths[i - 1]) / lengths[i - 1], 0.10, "\(clump.id) strip segment \(i)")
            }
            let joints = clump.nodeIds.map { worldPosition($0, in: out) }
            var bones: [Float] = []
            for i in 1..<joints.count { bones.append(V3.distance(joints[i], joints[i - 1])) }
            for i in 1..<bones.count {
                XCTAssertLessThanOrEqual(abs(bones[i] - bones[i - 1]) / bones[i - 1], 0.10, "\(clump.id) bone \(i)")
            }
            let expected = Float(HairControls().lengthM) * (clump.isBang ? HairBobV1.Layout.bangLengthRatio : 1)
            XCTAssertEqual(lengths.reduce(0, +), expected, accuracy: 0.003, clump.id)
        }
    }

    func testLengthControlDrivesClumpLength() throws {
        let short = try compileHair(HairControls(lengthM: 0.12))
        let long = try compileHair(HairControls(lengthM: 0.30))
        for (a, b) in zip(short.hairClumps, long.hairClumps) where !a.isBang {
            let la = zip(a.sectionCentres.dropFirst(), a.sectionCentres).map { V3.distance($0, $1) }.reduce(0, +)
            let lb = zip(b.sectionCentres.dropFirst(), b.sectionCentres).map { V3.distance($0, $1) }.reduce(0, +)
            XCTAssertEqual(la, 0.12, accuracy: 0.003)
            XCTAssertEqual(lb, 0.30, accuracy: 0.003)
        }
    }

    func testSpringsHaveTerminalTailsAndNoOverlap() throws {
        let out = try compileHair()
        XCTAssertEqual(out.springs.count, HairBobV1.Layout.clumpCount)
        XCTAssertNoThrow(try WearableValidation.noOverlappingChains(out.springs))
        XCTAssertNoThrow(try WearableValidation.terminalTailPresent(out.springs, nodes: out.nodes))
        let nodeIds = Set(out.nodes.map(\.id))
        var byId: [String: CompiledNode] = [:]
        for n in out.nodes { byId[n.id] = n }
        for spring in out.springs {
            XCTAssertEqual(spring.joints.count, HairBobV1.Layout.nodesPerClump)
            XCTAssertNoThrow(try spring.validate())
            let tail = spring.joints.last!.node
            XCTAssertTrue(nodeIds.contains(tail))
            XCTAssertFalse(out.nodes.contains { $0.parentId == tail }, "tail \(tail) must be a leaf")
            XCTAssertEqual(byId[spring.joints[0].node]?.parentId, host.headNodeId)
            for i in 1..<spring.joints.count { XCTAssertEqual(byId[spring.joints[i].node]?.parentId, spring.joints[i - 1].node) }
            XCTAssertEqual(spring.colliderGroups, ["colliderGroup:head", "colliderGroup:body"])
            for j in spring.joints {
                XCTAssertGreaterThan(j.hitRadius, 0)
                XCTAssertGreaterThan(j.stiffness, 0)
                XCTAssertEqual(j.gravityDir, [0, -1, 0])
            }
        }
    }

    func testCollidersAreParentedToRigNodesAndCarryNoCCDFlag() throws {
        let out = try compileHair()
        let head = try XCTUnwrap(out.colliders.first { $0.id == "collider:head" })
        XCTAssertEqual(head.node, host.headNodeId)
        let sphere = try XCTUnwrap(head.shape.sphere)
        XCTAssertEqual(sphere.radius, Double(host.headRadius + HairBobV1.Layout.headColliderPaddingM), accuracy: 1e-6)
        let headLocalCentre = host.headCentre - host.worlds[host.headNodeId]!
        XCTAssertEqual(Float(sphere.offset[1]), headLocalCentre.y, accuracy: 1e-5)
        let neck = try XCTUnwrap(out.colliders.first { $0.id == "collider:neck" })
        XCTAssertEqual(neck.node, host.neckNodeId)
        XCTAssertNotNil(neck.shape.capsule)
        let chest = try XCTUnwrap(out.colliders.first { $0.id == "collider:chest" })
        XCTAssertEqual(chest.node, host.chestNodeId)
        let capsule = try XCTUnwrap(chest.shape.capsule)
        XCTAssertEqual(Float(capsule.tail[1]), host.worlds[host.neckNodeId]!.y - host.worlds[host.chestNodeId]!.y, accuracy: 1e-5)
        XCTAssertEqual(capsule.radius, Double(SyntheticHost.torsoRadius), accuracy: 0.01)
        for collider in out.colliders {
            XCTAssertNoThrow(try collider.validate())
            for child in Mirror(reflecting: collider).children {
                let label = (child.label ?? "").lowercased()
                XCTAssertFalse(label.contains("ccd") || label.contains("swept") || label.contains("synthetic") || label.contains("continuous"), label)
            }
            let shapeLabels = Mirror(reflecting: collider.shape).children.compactMap(\.label)
            XCTAssertEqual(Set(shapeLabels), ["sphere", "capsule"])
        }
        let json = try collidersJSON(out.colliders)
        XCTAssertFalse(json.contains("ccd") || json.contains("swept") || json.contains("synthetic"))
        XCTAssertEqual(out.colliderGroups.map { ($0.id, $0.colliders) }.map { "\($0.0)=\($0.1)" },
                       ["colliderGroup:body=[\"collider:neck\", \"collider:chest\"]", "colliderGroup:head=[\"collider:head\"]"])
    }

    private func collidersJSON(_ colliders: [ColliderObject]) throws -> String {
        String(decoding: try CanonicalJSON.data(try JSONValue.from(colliders)), as: UTF8.self).lowercased()
    }

    func testBangsKeepClearanceAcrossTipSweep() throws {
        for clearance in [0.005, 0.012] {
            let controls = HairControls(bangClearanceM: clearance)
            let out = try compileHair(controls)
            let prim = try hairPrimitive(out)
            let bend = Float(controls.tipBendDeg) * .pi / 180
            var bangCount = 0
            for clump in out.hairClumps where clump.isBang {
                bangCount += 1
                XCTAssertEqual(clump.clearanceVertexStart, clump.vertexStart + 3 * HairBobV1.Layout.sectionsPerBone)
                for v in clump.clearanceVertexStart..<(clump.vertexStart + clump.vertexCount) {
                    let p = prim.positions[v]
                    XCTAssertGreaterThanOrEqual(host.faceClearance(p), Float(clearance) - 1e-5, "\(clump.id) vertex \(v) at rest")
                    guard v >= clump.tipVertexStart else { continue }
                    for angle in [-bend, bend] {
                        let q = V3.rotate(p, about: clump.sweepPivot, axis: clump.sweepAxis, angle: angle)
                        XCTAssertGreaterThanOrEqual(host.faceClearance(q), Float(clearance) - 1e-5, "\(clump.id) vertex \(v) swept \(angle)")
                    }
                }
            }
            XCTAssertGreaterThanOrEqual(bangCount, 6)
        }
    }

    func testNoHairVertexIsInsideTheHead() throws {
        let out = try compileHair()
        let prim = try hairPrimitive(out)
        for (i, p) in prim.positions.enumerated() {
            XCTAssertGreaterThan(V3.distance(p, host.headCentre), host.headRadius - 1e-4, "vertex \(i)")
        }
    }

    func testHairMeshIsSkinnedWithLongitudinalUVs() throws {
        let out = try compileHair()
        let prim = try hairPrimitive(out)
        XCTAssertEqual(prim.materialId, "material:hairA")
        let joints = try XCTUnwrap(prim.joints0)
        let weights = try XCTUnwrap(prim.weights0)
        let skin = try XCTUnwrap(out.skins.first { $0.id == "skin:hair:bob" })
        XCTAssertEqual(skin.jointNodeIds.count, skin.inverseBindMatrices.count)
        XCTAssertEqual(skin.jointNodeIds.count, HairBobV1.Layout.clumpCount * HairBobV1.Layout.nodesPerClump)
        for clump in out.hairClumps {
            XCTAssertEqual(prim.uv0[clump.vertexStart].y, 0)
            XCTAssertEqual(prim.uv0[clump.vertexStart + clump.vertexCount - 1].y, 1)
            XCTAssertEqual(prim.uv0[clump.vertexStart].x, 0)
            XCTAssertEqual(prim.uv0[clump.vertexStart + 2].x, 1)
            let clumpJoints = Set(clump.nodeIds.compactMap { skin.jointNodeIds.firstIndex(of: $0) }.map { UInt16($0) })
            for v in clump.vertexStart..<(clump.vertexStart + clump.vertexCount) {
                XCTAssertEqual(weights[v].sum(), 1, accuracy: 1e-5)
                for lane in 0..<4 where weights[v][lane] > 0 { XCTAssertTrue(clumpJoints.contains(joints[v][lane]), "vertex \(v) bound outside its clump") }
            }
            XCTAssertEqual(weights[clump.vertexStart], SIMD4(1, 0, 0, 0))
        }
        for (i, ibm) in skin.inverseBindMatrices.enumerated() {
            let world = worldPosition(skin.jointNodeIds[i], in: out)
            let inv = Mat4(ibm)
            let origin = inv.transformPoint(world)
            XCTAssertLessThan(V3.length(origin), 1e-4, "IBM of \(skin.jointNodeIds[i])")
        }
        XCTAssertNoThrow(try WearableValidation.validateMesh(out.meshes[0]))
    }

    func testHairFallsBackWhenNoHairMaterialExists() throws {
        let out = try WearableCompiler.compile(host: host, hair: [Fixtures.hair()], outfits: [], accessories: [], materialsById: [:])
        XCTAssertEqual(out.meshes[0].primitives[0].materialId, WearableCompiler.hairMaterialFallbackId)
        XCTAssertEqual(out.warnings.map(\.code), ["MATERIAL_ROLE_MISSING"])
    }

    func testUnknownPresetAndMissingScalpAreTypedErrors() {
        var item = Fixtures.hair()
        item.preset = "mohawk-v1"
        XCTAssertThrowsError(try WearableCompiler.compile(host: host, hair: [item], outfits: [], accessories: [], materialsById: [:])) { error in
            XCTAssertEqual((error as? AuthorError)?.code, .invalidRequest)
        }
        var bald = host
        bald.scalpSamples = []
        XCTAssertThrowsError(try WearableCompiler.compile(host: bald, hair: [Fixtures.hair()], outfits: [], accessories: [], materialsById: [:])) { error in
            XCTAssertEqual((error as? AuthorError)?.code, .hostRegionMissing)
        }
    }
}
