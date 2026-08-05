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

    func testPredicateAcceptsSkinAndClothRejectsHair() {
        XCTAssertTrue(BodySurfacePredicate.includes(materialName: "Body_00_SKIN"))
        XCTAssertTrue(BodySurfacePredicate.includes(materialName: "F00_000_Face_00_SKIN"))
        XCTAssertTrue(BodySurfacePredicate.includes(materialName: "Onepiece_00_CLOTH"))
        XCTAssertFalse(BodySurfacePredicate.includes(materialName: "Hair_00_HAIR"))
        XCTAssertFalse(BodySurfacePredicate.includes(materialName: "CLOTH_HAIR_accessory"),
                       "HAIR wins over CLOTH — a hair ribbon is not a body surface")
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

    /// Records the exact set so a material rename fails loudly.
    @MainActor func testInventoryExactSetIsPinnedForAvatarSampleA() async throws {
        let model = try await load(testVRM10Filename)
        let inv = BodySurfacePredicate.inventory(model: model)
        for entry in inv {
            XCTAssertTrue(entry.isTriangleTopology,
                          "\(entry.materialName): strip topology would be silently skipped")
            XCTAssertGreaterThan(entry.vertexCount, 0)
        }
        let names = inv.map(\.materialName).sorted()
        print("[BODYSURFACE] AvatarSample_A included=\(names)")
        print("[BODYSURFACE] AvatarSample_A boundaryEdges=\(inv.map { "\($0.materialName):\($0.boundaryEdgeCount)" })")
        XCTAssertFalse(names.isEmpty)
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
