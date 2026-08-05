//
// Copyright 2025 Arkavo
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

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// The predicate decides which primitives are "body". Getting it wrong is
/// silent in both directions: too few and every joint reads clean, too many and
/// a garment's own simulated joints read as permanently penetrating.
final class BodySurfacePredicateTests: XCTestCase {

    @MainActor private func load(_ filename: String) async throws -> VRMModel {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let path = getTestModelPath(filename)
        try requireFixture(path, hint: filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()
        return model
    }

    private func allMaterialNames(model: VRMModel) -> [String] {
        var names = Set<String>()
        for mesh in model.meshes {
            for primitive in mesh.primitives {
                guard let mi = primitive.materialIndex, mi < model.materials.count else { continue }
                names.insert(model.materials[mi].name ?? "")
            }
        }
        return names.sorted()
    }

    func testPredicateAcceptsSkinRejectsClothAndHair() {
        XCTAssertTrue(BodySurfacePredicate.includes(materialName: "Body_00_SKIN"))
        XCTAssertTrue(BodySurfacePredicate.includes(materialName: "F00_000_Face_00_SKIN"))
        XCTAssertFalse(BodySurfacePredicate.includes(materialName: "Onepiece_00_CLOTH"),
                       "CLOTH is simulated garment surface — excluded categorically, not by " +
                       "per-material judgement, per §3")
        XCTAssertFalse(BodySurfacePredicate.includes(materialName: "Hair_00_HAIR"))
        XCTAssertFalse(BodySurfacePredicate.includes(materialName: "SKIN_HAIR_accessory"),
                       "HAIR wins over SKIN — a hair mesh is not a body surface even if misnamed")
        XCTAssertFalse(BodySurfacePredicate.includes(materialName: nil))
        XCTAssertFalse(BodySurfacePredicate.includes(materialName: "EyeIris"))
    }

    /// Ranges over ALL meshes, not the first one named "body" — that scoping
    /// drops the Face mesh's SKIN primitives entirely.
    @MainActor func testInventoryIncludesFaceMeshNotJustBodyMesh() async throws {
        let model = try await load(testVRM10Filename)
        let inv = BodySurfacePredicate.inventory(model: model)
        XCTAssertFalse(inv.isEmpty, "the fixture must contribute body surface")
        let meshNames = Set(inv.map { (model.meshes[$0.meshIndex].name ?? "").lowercased() })
        XCTAssertGreaterThan(meshNames.count, 1,
                             "more than one mesh contributes; scoping to a single 'body' mesh is the bug")
    }

    /// Pins both directions: the included set (so a material rename that drops
    /// coverage fails loudly) and the excluded set (so a rename or predicate
    /// change that starts flooding garment surfaces into the oracle fails
    /// loudly too, not just a silently-passing non-empty check).
    private func assertPinnedInventory(model: VRMModel, fixture: String,
                                       expectedIncluded: [String], expectedExcluded: [String],
                                       file: StaticString = #filePath, line: UInt = #line) {
        let inv = BodySurfacePredicate.inventory(model: model)
        for entry in inv {
            XCTAssertTrue(entry.isTriangleTopology,
                          "\(entry.materialName): strip topology would be silently skipped",
                          file: file, line: line)
            XCTAssertGreaterThan(entry.vertexCount, 0, file: file, line: line)
        }
        let included = inv.map { "\($0.materialName):\($0.vertexCount)" }.sorted()
        let excluded = allMaterialNames(model: model)
            .filter { !BodySurfacePredicate.includes(materialName: $0) }
            .sorted()
        print("[BODYSURFACE] \(fixture) included=\(included)")
        print("[BODYSURFACE] \(fixture) boundaryEdges=\(inv.map { "\($0.materialName):\($0.boundaryEdgeCount)" })")
        XCTAssertEqual(included, expectedIncluded.sorted(),
                       "\(fixture): included set drifted from the pinned set — a material rename " +
                       "or a predicate that silently narrows must fail here",
                       file: file, line: line)
        XCTAssertEqual(excluded, expectedExcluded.sorted(),
                       "\(fixture): excluded set drifted from the pinned set — a predicate that " +
                       "starts flooding garment surfaces into the oracle must fail here",
                       file: file, line: line)
    }

    @MainActor func testInventoryExactSetIsPinnedForAvatarSampleA() async throws {
        let model = try await load(testVRM10Filename)
        assertPinnedInventory(model: model, fixture: "AvatarSample_A",
            expectedIncluded: [
                "N00_000_00_Body_00_SKIN (Instance):7964",
                "N00_000_00_Face_00_SKIN (Instance):4060",
            ],
            expectedExcluded: [
                "N00_000_00_EyeHighlight_00_EYE (Instance)",
                "N00_000_00_EyeIris_00_EYE (Instance)",
                "N00_000_00_EyeWhite_00_EYE (Instance)",
                "N00_000_00_FaceBrow_00_FACE (Instance)",
                "N00_000_00_FaceEyeline_00_FACE (Instance)",
                "N00_000_00_FaceMouth_00_FACE (Instance)",
                "N00_000_Hair_00_HAIR_01 (Instance)",
                "N00_000_Hair_00_HAIR_02 (Instance)",
                "N00_000_Hair_00_HAIR_03 (Instance)",
                "N00_000_Hair_00_HAIR_04 (Instance)",
                "N00_001_01_Shoes_01_CLOTH (Instance)",
                "N00_001_02_Bottoms_01_CLOTH (Instance)",
                "N00_005_01_Tops_01_CLOTH (Instance)",
            ])
    }

    @MainActor func testInventoryExactSetIsPinnedForAvatarSampleU() async throws {
        let model = try await load("AvatarSample_U_1.0.vrm.glb")
        assertPinnedInventory(model: model, fixture: "AvatarSample_U",
            expectedIncluded: [
                "N00_000_00_Body_00_SKIN (Instance):9377",
                "N00_000_00_Face_00_SKIN (Instance):4241",
            ],
            expectedExcluded: [
                "Accessory_CatEar_01_CLOTH (Instance)",
                "Accessory_CatTail_01_CLOTH (Instance)",
                "N00_000_00_EyeHighlight_00_EYE (Instance)",
                "N00_000_00_EyeIris_00_EYE (Instance)",
                "N00_000_00_EyeWhite_00_EYE (Instance)",
                "N00_000_00_FaceBrow_00_FACE (Instance)",
                "N00_000_00_FaceEyelash_00_FACE (Instance)",
                "N00_000_00_FaceEyeline_00_FACE (Instance)",
                "N00_000_00_FaceMouth_00_FACE (Instance)",
                "N00_000_Hair_00_HAIR (Instance)",
                "N00_002_01_Tops_01_CLOTH_01 (Instance)",
                "N00_002_01_Tops_01_CLOTH_02 (Instance)",
                "N00_002_01_Tops_01_CLOTH_03 (Instance)",
                "N00_002_01_Tops_01_CLOTH_04 (Instance)",
                "N00_002_01_Tops_01_CLOTH_05 (Instance)",
                "N00_007_01_Tops_01_CLOTH (Instance)",
                "N00_008_01_Shoes_01_CLOTH (Instance)",
                "N00_010_01_Onepiece_00_CLOTH (Instance)",
            ])
    }

    @MainActor func testOracleBuildsFromRig() async throws {
        let model = try await load(testVRM10Filename)
        let oracle = try XCTUnwrap(SkinMeshOracle.build(model: model))
        XCTAssertGreaterThan(oracle.triangleCount, 1_000)

        // A point at the hips must be inside the body; a point a metre to the
        // side must not be. This is the smallest end-to-end sanity check that
        // the skinning and the sign are both right.
        let humanoid = try XCTUnwrap(model.humanoid)
        let hips = try XCTUnwrap(humanoid.getBoneNode(.hips))
        let inside = model.nodes[hips].worldPosition
        XCTAssertNotNil(oracle.penetration(of: inside, radius: 0), "the hips are inside the body")
        XCTAssertNil(oracle.penetration(of: inside + SIMD3<Float>(1, 0, 0), radius: 0),
                     "a metre to the side is outside")
    }
}
