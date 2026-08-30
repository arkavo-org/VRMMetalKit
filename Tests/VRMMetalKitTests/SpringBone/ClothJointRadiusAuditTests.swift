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

/// Audit guard for measured joint radii (spec §6, slice 2): pins the invariants
/// and per-chain aggregates so drift and sparse skinning are loud, and prints
/// the full per-joint table for the report. Mirrors ColliderDimensionAudit's
/// role on the collider side.
final class ClothJointRadiusAuditTests: XCTestCase {

    @MainActor private func load(_ filename: String) async throws -> VRMModel {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let path = getTestModelPath(filename)
        try requireFixture(path, hint: filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()
        return model
    }

    /// The invariants every measurement must satisfy, on every fixture:
    /// effective ∈ [authored, max(authored, ceiling)], ceiling formula honored,
    /// measured joints actually measured something.
    @MainActor func testInvariantsHoldOnAllFixtures() async throws {
        for f in ["AvatarSample_A_1.0.vrm.glb", "AvatarSample_U_1.0.vrm.glb", "AvatarSample_M_1.0.vrm"] {
            let model = try await load(f)
            let rows = SpringBoneJointRadiusMeasure.measure(model: model)
            XCTAssertFalse(rows.isEmpty, "\(f): no spring joints measured")
            for r in rows {
                XCTAssertGreaterThanOrEqual(r.effective, r.authored,
                    "\(f) spring \(r.springIndex) joint \(r.jointIndex): effective below authored — the floor must never reduce")
                XCTAssertLessThanOrEqual(r.effective, max(r.authored, r.ceiling) + 1e-6,
                    "\(f) spring \(r.springIndex) joint \(r.jointIndex): effective above ceiling")
                XCTAssertLessThanOrEqual(r.ceiling, 0.05 + 1e-6, "\(f): absolute cap violated")
                if let m = r.measured {
                    XCTAssertGreaterThan(m, 0, "\(f): a computed measurement must be positive")
                    XCTAssertGreaterThanOrEqual(r.dominantVertexCount, 0)
                }
                XCTAssertFalse(r.effective.isNaN)
            }
            print("[RADIUSAUDIT] \(f): \(rows.count) joints, "
                + "measured=\(rows.filter { $0.measured != nil && $0.dominantVertexCount >= 8 }.count), "
                + "inherited/sparse=\(rows.filter { $0.dominantVertexCount < 8 }.count)")
            for r in rows {
                print(String(format: "[RADIUSROW] %@ s%02d j%d node=%d auth=%.4f meas=%@ n=%d ceil=%.4f eff=%.4f",
                    f, r.springIndex, r.jointIndex, r.node, r.authored,
                    r.measured.map { String(format: "%.4f", $0) } ?? "-",
                    r.dominantVertexCount, r.ceiling, r.effective))
            }
        }
    }

    /// M's Hair chains are the evidence base (authored median 3.7mm for
    /// centimetre-wide cards): the measurement must raise them substantially.
    /// The bound is derived from the defect data, not chosen round: authored
    /// median is 0.0037; a floor that fails to at least triple it cannot close
    /// a gap the 18mm experiment showed needs ~15mm.
    @MainActor func testHairRadiiRiseOnAvatarSampleM() async throws {
        let model = try await load("AvatarSample_M_1.0.vrm")
        let rows = SpringBoneJointRadiusMeasure.measure(model: model)
        guard let sb = model.springBone else { return XCTFail("no springbone") }
        let hairRows = rows.filter { (sb.springs[$0.springIndex].name ?? "").contains("Hair") && $0.jointIndex > 0 }
        XCTAssertFalse(hairRows.isEmpty)
        let effs = hairRows.map(\.effective).sorted()
        let median = effs[effs.count / 2]
        XCTAssertGreaterThan(median, 0.0037 * 3,
            "measured hair median \(median) is not meaningfully above the authored 3.7mm — the measurement is not doing its job")
    }
}
