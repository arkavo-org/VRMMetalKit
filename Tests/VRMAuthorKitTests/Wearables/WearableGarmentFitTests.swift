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

/// Garment fit on the real native-anime host with the female starter, where
/// the thigh and torso lofts overlap and the clearance gate cannot see a
/// skirt cutting through the thigh tops.
final class WearableGarmentFitTests: XCTestCase {
    static func female() throws -> (avatar: CompiledAvatar, attachments: TemplateAttachments, recipe: Recipe) {
        let recipe = try NativeAnimeStarters.starterRecipe(base: .female, registry: TemplateRegistry.standard())
        let (avatar, attachments) = try NativeAnimeFixture.pack.compileWithAttachments(recipe, seed: NativeAnimeStarters.seed)
        return (avatar, attachments, recipe)
    }

    func testSkirtClearsTheLowerBodyAtEveryVertex() throws {
        let (avatar, attachments, recipe) = try Self.female()
        let item = try XCTUnwrap(recipe.outfits.first { $0.preset == "skirt-v1" })
        let skirt = try XCTUnwrap(avatar.meshes.first { $0.id == "mesh:garment:\(item.id)" }).primitives[0]
        let body = NativeAnimeFixture.primitive(avatar, mesh: "mesh.body")
        let lower = Set(["waist", "hips", "thighL", "thighR", "shinL", "shinR"].flatMap { attachments.indices(of: $0, mesh: "mesh.body") })
        let probe = SurfaceProbe(positions: body.positions, normals: body.normals, indices: body.indices) { a, b, c in
            lower.contains(a) && lower.contains(b) && lower.contains(c)
        }
        var worst = Float.infinity
        for p in skirt.positions { worst = min(worst, try XCTUnwrap(probe.signedDistance(to: p))) }
        XCTAssertGreaterThanOrEqual(worst, Float(OutfitPresets.minClearanceM), "skirt penetrates the lower body by \(worst)")
        let rings = Set(skirt.positions.map { ($0.y * 1000).rounded() })
        XCTAssertGreaterThanOrEqual(rings.count, 7, "six rings plus the hem band")
    }

    func testCollarClosesOnTheNeckWithoutCrossingIt() throws {
        let (avatar, attachments, recipe) = try Self.female()
        let top = try XCTUnwrap(recipe.outfits.first { $0.preset == "top-v1" })
        let info = try XCTUnwrap(attachments.garments.first { $0.id == top.id })
        let gap = try XCTUnwrap(info.collarGapM)
        XCTAssertLessThanOrEqual(gap, 0.002 + 1e-4, "front collar gap \(gap)")
        let shirt = try XCTUnwrap(avatar.meshes.first { $0.id == info.meshId }).primitives[0]
        let outerV = GarmentUVLayout.trim.map(SIMD2(0, 0.9)).y
        let shellTop = shirt.positions.indices.filter { !GarmentUVLayout.trim.contains(shirt.uv0[$0]) && shirt.uv0[$0].x < 0.5 }.map { shirt.positions[$0].y }.max()!
        let outerRowMin = shirt.positions.indices.filter { abs(shirt.uv0[$0].y - outerV) < 1e-4 && abs(shirt.positions[$0].x) < 0.10 && shirt.positions[$0].y > shellTop - 0.05 }.map { shirt.positions[$0].y }.min()!
        XCTAssertGreaterThanOrEqual(outerRowMin, shellTop - 0.001, "collar band must sit on the shell's top edge, not below it")
        let body = NativeAnimeFixture.primitive(avatar, mesh: "mesh.body")
        let neck = attachments.indices(of: "neck", mesh: "mesh.body")
        for (k, p) in shirt.positions.enumerated() where GarmentUVLayout.trim.contains(shirt.uv0[k]) && p.y > attachments.jointWorldPositions[.neck]!.y - 0.01 {
            let neckR = neck.filter { abs(body.positions[$0].y - p.y) < 0.01 }.map { hypot(body.positions[$0].x, body.positions[$0].z) }.max() ?? 0
            XCTAssertGreaterThanOrEqual(hypot(p.x, p.z), neckR - 1e-4, "collar vertex \(k) is inside the neck shell")
        }
    }
}
