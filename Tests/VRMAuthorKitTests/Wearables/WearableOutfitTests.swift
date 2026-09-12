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

final class WearableOutfitTests: XCTestCase {
    let host = SyntheticHost()

    func compile(_ outfits: [OutfitItem]) throws -> WearableOutput {
        try WearableCompiler.compile(host: host, hair: [], outfits: outfits, accessories: [], materialsById: Fixtures.materials)
    }

    func garment(_ out: WearableOutput, _ id: String) throws -> CompiledPrimitive {
        try XCTUnwrap(out.meshes.first { $0.id == "mesh:garment:\(id)" }).primitives[0]
    }

    func minimumBodyClearance(_ prim: CompiledPrimitive) -> Float {
        let probe = SurfaceProbe(positions: host.bodyPositions, normals: host.bodyNormals, indices: host.bodyTriangles)
        return prim.positions.compactMap { probe.signedDistance(to: $0) }.min() ?? .infinity
    }

    func testSkirtHangsFromTheWaistAndClearsTheBody() throws {
        let out = try compile([Fixtures.skirt()])
        let prim = try garment(out, "skirt")
        let info = try XCTUnwrap(out.garments.first { $0.id == "skirt" })
        XCTAssertEqual(info.preset, "skirt-v1")
        XCTAssertEqual(info.hiddenRegions, ["waist", "hips"])
        // The waistband hugs the waist; the hem flares past the hips' widest
        // point and drops below the hip line, longer with length=1.
        let waistMax = host.region("waist").map { abs(host.bodyPositions[$0].x) }.max()!
        let hipsBottom = host.region("hips").map { host.bodyPositions[$0].y }.min()!
        let topRingX = prim.positions.filter { $0.y > prim.positions.map(\.y).max()! - 0.001 }.map(\.x).map(abs).max()!
        XCTAssertEqual(topRingX, waistMax + Float(OutfitPresets.baseClearanceM), accuracy: 0.01)
        let hemY = prim.positions.map(\.y).min()!
        XCTAssertLessThan(hemY, hipsBottom - 0.05)
        let long = try garment(try compile([Fixtures.skirt(length: 1)]), "skirt")
        XCTAssertLessThan(long.positions.map(\.y).min()!, hemY - 0.05)
        XCTAssertGreaterThanOrEqual(minimumBodyClearance(prim), Float(OutfitPresets.minClearanceM))
        // A skirt and shorts are both bottoms: same layer conflicts.
        XCTAssertThrowsError(try compile([Fixtures.skirt(layer: 0), Fixtures.bottom(layer: 0)]))
        XCTAssertNoThrow(try compile([Fixtures.skirt(layer: 1), Fixtures.bottom(layer: 0)]))
    }

    func testEveryGarmentVertexClearsTheBodyAlongTheNormal() throws {
        let out = try compile([Fixtures.top(), Fixtures.bottom(), Fixtures.footwear()])
        for id in ["shirt", "pants", "shoes"] {
            let prim = try garment(out, id)
            XCTAssertGreaterThanOrEqual(minimumBodyClearance(prim), Float(OutfitPresets.minClearanceM), id)
            let info = try XCTUnwrap(out.garments.first { $0.id == id })
            XCTAssertGreaterThanOrEqual(info.minClearanceM, OutfitPresets.minClearanceM)
            XCTAssertEqual(info.offsetM, OutfitPresets.baseClearanceM, accuracy: 1e-9)
        }
    }

    func testShellReusesBodySkinWeightsAndUVs() throws {
        let out = try compile([Fixtures.top()])
        let prim = try garment(out, "shirt")
        let joints = try XCTUnwrap(prim.joints0)
        let covered = Set(host.region("chest") + host.region("torso") + host.region("waist") + host.region("upperArmL") + host.region("upperArmR"))
        // Shell vertices come first (sorted covered order); collar/cuff/hem
        // trim vertices follow.
        XCTAssertEqual(prim.positions.count, covered.count + 192)
        var matched = 0
        for (v, p) in prim.positions.enumerated() {
            let base = covered.min { V3.distance(host.bodyPositions[$0], p) < V3.distance(host.bodyPositions[$1], p) }!
            let shellDistance = V3.distance(host.bodyPositions[base], p)
            XCTAssertGreaterThanOrEqual(shellDistance, Float(OutfitPresets.baseClearanceM) - 1e-5)
            guard v < covered.count else { continue }
            XCTAssertLessThanOrEqual(shellDistance, Float(OutfitPresets.baseClearanceM) + 0.02, "cuff/hem shaping stays a small outward offset")
            XCTAssertEqual(joints[v], host.bodyJoints[base])
            XCTAssertEqual(prim.uv0[v], host.bodyUV0[base])
            XCTAssertLessThan(V3.distance(prim.normals[v], host.bodyNormals[base]), 1e-5)
            matched += 1
        }
        XCTAssertEqual(matched, covered.count)
        let instance = try XCTUnwrap(out.meshInstances.first { $0.meshId == "mesh:garment:shirt" })
        XCTAssertEqual(instance.skinId, "skin:body")
        XCTAssertTrue(out.skins.isEmpty)
    }

    func testLayerAndFitChangeTheOffset() throws {
        let base = try garment(try compile([Fixtures.top()]), "shirt")
        let layered = try garment(try compile([Fixtures.top(layer: 3)]), "shirt")
        let loose = try garment(try compile([Fixtures.top(fit: 1)]), "shirt")
        let tight = try garment(try compile([Fixtures.top(fit: -1)]), "shirt")
        let chestVertex = host.region("chest")[0]
        let bodyP = host.bodyPositions[chestVertex]
        func offset(_ prim: CompiledPrimitive) -> Float {
            prim.positions.map { V3.distance($0, bodyP) }.min()!
        }
        XCTAssertEqual(offset(base), 0.008, accuracy: 1e-5)
        XCTAssertEqual(offset(layered), 0.017, accuracy: 1e-5)
        XCTAssertEqual(offset(loose), 0.012, accuracy: 1e-5)
        XCTAssertEqual(offset(tight), 0.004, accuracy: 1e-5)
        XCTAssertGreaterThanOrEqual(minimumBodyClearance(tight), Float(OutfitPresets.minClearanceM))
    }

    func testLengthExtendsAndContractsAlongTheLimb() throws {
        let short = try garment(try compile([Fixtures.top(length: -1)]), "shirt")
        let base = try garment(try compile([Fixtures.top()]), "shirt")
        let long = try garment(try compile([Fixtures.top(length: 1)]), "shirt")
        XCTAssertLessThan(short.positions.count, base.positions.count)
        XCTAssertLessThan(base.positions.count, long.positions.count)
        let forearm = Set(host.region("forearmL"))
        XCTAssertEqual(long.positions.count, base.positions.count + forearm.count * 2)
        XCTAssertGreaterThan(long.positions.map(\.x).max()!, 0.55)
        XCTAssertLessThan(base.positions.map(\.x).max()!, 0.40)
        XCTAssertLessThan(short.positions.map(\.x).max()!, base.positions.map(\.x).max()!)
        let longInfo = try XCTUnwrap(try compile([Fixtures.top(length: 1)]).garments.first)
        XCTAssertEqual(longInfo.coveredRegions, ["chest", "torso", "waist", "upperArmL", "upperArmR", "forearmL", "forearmR"])
        XCTAssertEqual(longInfo.hiddenRegions, ["chest", "torso", "waist", "upperArmL", "upperArmR"])
        let pants = try garment(try compile([Fixtures.bottom(length: 1)]), "pants")
        XCTAssertLessThanOrEqual(pants.positions.map(\.y).min()!, 0.10 + 1e-4)
        XCTAssertGreaterThan(try garment(try compile([Fixtures.bottom()]), "pants").positions.map(\.y).min()!, 0.40)
    }

    func testPenetrationIsATypedGateError() {
        XCTAssertThrowsError(try compile([Fixtures.bottom(layer: 8, fit: 1)])) { error in
            guard let e = error as? AuthorError else { return XCTFail("\(error)") }
            XCTAssertEqual(e.code, .garmentPenetration)
            XCTAssertEqual(e.code.rawValue, "GARMENT_PENETRATION")
            XCTAssertEqual(e.objectId, "garment:pants")
            XCTAssertEqual(e.path, "/fit/minClearanceM")
            XCTAssertEqual(e.required, .number(0.002))
            let observed = e.observed?.number ?? 1
            XCTAssertLessThan(observed, 0.002)
            XCTAssertEqual(observed, -0.004, accuracy: 0.0015)
            XCTAssertEqual(e.suggestedCommands, ["control set", "recipe apply", "qa run"])
            XCTAssertTrue(e.message.contains("thigh"), e.message)
            XCTAssertEqual(e.code.exitCode, .gateFailed)
        }
        XCTAssertNoThrow(try compile([Fixtures.bottom(layer: 2, fit: 0)]))
    }

    func testLayerConflictsAreTyped() {
        func conflict(_ outfits: [OutfitItem], file: StaticString = #filePath, line: UInt = #line) -> AuthorError? {
            do {
                _ = try compile(outfits)
                XCTFail("expected OUTFIT_LAYER_CONFLICT", file: file, line: line)
                return nil
            } catch let e as AuthorError {
                XCTAssertEqual(e.code, .outfitLayerConflict, file: file, line: line)
                return e
            } catch {
                XCTFail("\(error)", file: file, line: line)
                return nil
            }
        }
        let sameLayer = conflict([Fixtures.top("a"), Fixtures.top("b")])
        XCTAssertEqual(sameLayer?.objectId, "garment:b")
        XCTAssertEqual(sameLayer?.path, "/layer")
        XCTAssertEqual(sameLayer?.code.rawValue, "OUTFIT_LAYER_CONFLICT")
        let footwearHigh = conflict([Fixtures.footwear(layer: 3)])
        XCTAssertEqual(footwearHigh?.required, .array([0, 1, 2]))
        XCTAssertNoThrow(try compile([Fixtures.top("a"), Fixtures.top("b", layer: 1), Fixtures.bottom(), Fixtures.footwear()]))
        XCTAssertNoThrow(try compile([Fixtures.top("a"), Fixtures.top("b", enabled: false)]))
        XCTAssertThrowsError(try compile([OutfitItem(id: "x", preset: "cape-v1", materialIds: [])])) { error in
            XCTAssertEqual((error as? AuthorError)?.code, .invalidRequest)
        }
    }

    func testFootwearExposesFitOnly() throws {
        let d = try XCTUnwrap(OutfitPresets.descriptor("footwear-v1"))
        XCTAssertEqual(d.supportedControls, ["fit"])
        XCTAssertEqual(OutfitPresets.permittedLayers, ["top-v1": Array(0...8), "bottom-v1": Array(0...8), "skirt-v1": Array(0...8), "footwear-v1": [0, 1, 2]])
        let item = OutfitItem(id: "shoes", preset: "footwear-v1", layer: 1, controls: OutfitControls(length: 1, fit: 0.5), materialIds: ["material:shoes"])
        let out = try compile([item])
        XCTAssertEqual(out.warnings.map(\.code), ["CONTROL_UNSUPPORTED"])
        let shoes = try garment(out, "shoes")
        XCTAssertEqual(shoes.positions.count, host.region("footL").count + host.region("footR").count)
        XCTAssertEqual(out.hiddenRegions, ["footL", "footR"])
    }

    func testMissingHostRegionIsTyped() {
        var partial = host
        partial.regions["chest"] = []
        XCTAssertThrowsError(try WearableCompiler.compile(host: partial, hair: [], outfits: [Fixtures.top()], accessories: [], materialsById: [:])) { error in
            let e = error as? AuthorError
            XCTAssertEqual(e?.code, .hostRegionMissing)
            XCTAssertEqual(e?.observed, .string("chest"))
        }
    }

    func testMaterialWarnings() throws {
        var item = Fixtures.top()
        item.materialIds = []
        let out = try WearableCompiler.compile(host: host, hair: [], outfits: [item], accessories: [], materialsById: [:])
        XCTAssertEqual(out.warnings.map(\.code), ["MATERIAL_MISSING"])
        XCTAssertEqual(out.meshes[0].primitives[0].materialId, WearableCompiler.garmentMaterialFallbackId)
        let unknown = try WearableCompiler.compile(host: host, hair: [], outfits: [Fixtures.top()], accessories: [], materialsById: [:])
        XCTAssertEqual(unknown.warnings.map(\.code), ["MATERIAL_UNKNOWN"])
    }
}
