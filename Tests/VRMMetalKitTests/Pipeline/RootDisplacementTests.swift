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

final class RootDisplacementTests: XCTestCase {
    func testNoRequestsLeavesBaseUntouched() {
        let d = RootDisplacement()
        XCTAssertEqual(d.resolve(base: SIMD3<Float>(1, 2, 3)), SIMD3<Float>(1, 2, 3))
    }

    func testAbsoluteReplacesBase() {
        var d = RootDisplacement()
        d.setAbsolute(SIMD3<Float>(10, 0, 0))
        XCTAssertEqual(d.resolve(base: SIMD3<Float>(1, 2, 3)), SIMD3<Float>(10, 0, 0))
    }

    func testDeltasAccumulateOnTopOfAbsolute() {
        var d = RootDisplacement()
        d.setAbsolute(SIMD3<Float>(10, 0, 0))
        d.addDelta(SIMD3<Float>(0.5, 0, 0.25))
        XCTAssertEqual(d.resolve(base: .zero), SIMD3<Float>(10.5, 0, 0.25))
    }

    func testDeltasApplyToBaseWhenNoAbsoluteRequested() {
        var d = RootDisplacement()
        d.addDelta(SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(d.resolve(base: SIMD3<Float>(0, 0, 2)), SIMD3<Float>(0, 0, 3))
    }

    func testAccumulationIsSequentialNotReassociated() {
        var d = RootDisplacement()
        d.addDelta(SIMD3<Float>(1.0, 0, 0))
        d.addDelta(SIMD3<Float>(-1.0, 0, 0))
        d.addDelta(SIMD3<Float>(1e-8, 0, 0))
        let result = d.resolve(base: .zero)

        XCTAssertEqual(result.x.bitPattern, Float(1e-8).bitPattern,
                       "Sequential accumulation preserves final small delta: ((0 + 1.0) + (-1.0)) + 1e-8 = 1e-8")
    }

    func testHasAbsoluteReportsRequestState() {
        var d = RootDisplacement()
        XCTAssertFalse(d.hasAbsolute)
        d.setAbsolute(.zero)
        XCTAssertTrue(d.hasAbsolute)
    }

    func testBitIdentityWithExpressionForm() {
        let base = SIMD3<Float>(0.37, 1.11, -0.29)
        let placement = SIMD3<Float>(0.813, 0, -0.447)
        let shove = SIMD2<Float>(0.0231, -0.0177)

        var literal = base + placement
        literal.x += shove.x
        literal.z += shove.y

        var d = RootDisplacement()
        d.setAbsolute(base + placement)
        d.addDelta(SIMD3<Float>(shove.x, 0, shove.y))
        let result = d.resolve(base: base)

        XCTAssertEqual(result.x.bitPattern, literal.x.bitPattern)
        XCTAssertEqual(result.y.bitPattern, literal.y.bitPattern)
        XCTAssertEqual(result.z.bitPattern, literal.z.bitPattern)
    }

    func testBitIdentityWithTwoDeltaForm() {
        let base = SIMD3<Float>(0.37, 1.11, -0.29)
        let placement = SIMD3<Float>(0.813, 0, -0.447)
        let shove = SIMD3<Float>(0.0231, 0.0189, -0.0177)
        let goalApproach = SIMD3<Float>(-0.0113, 0, 0.00824)

        var literal = base + placement
        literal += shove
        literal += goalApproach

        var d = RootDisplacement()
        d.setAbsolute(base + placement)
        d.addDelta(shove)
        d.addDelta(goalApproach)
        let result = d.resolve(base: base)

        XCTAssertEqual(result.x.bitPattern, literal.x.bitPattern)
        XCTAssertEqual(result.y.bitPattern, literal.y.bitPattern)
        XCTAssertEqual(result.z.bitPattern, literal.z.bitPattern)
    }
}

extension RootDisplacementTests {
    /// `PoseStage.place` and `PoseStage.displace` used to each build their own,
    /// unlinked `RootDisplacement` — so a second absolute request landing in
    /// `displace` could never trip the type's one-absolute-per-frame
    /// `precondition`, the exact case it exists for. This pins the fix: `place`
    /// seeds `avatar.rootDisplacements` (one accumulator per top-level root) and
    /// `displace` must continue those SAME instances, not start fresh ones.
    @MainActor func testPoseStageThreadsRootDisplacementAcrossPlaceAndDisplace() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let path = getTestVRM10ModelPath()
        try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: false))

        var baseTranslations: [ObjectIdentifier: SIMD3<Float>] = [:]
        for root in model.nodes where root.parent == nil {
            baseTranslations[ObjectIdentifier(root)] = root.translation
        }

        var avatar = PipelineAvatar(index: 0, model: model, player: AnimationPlayer(),
                                    baseTranslations: baseTranslations)
        XCTAssertTrue(avatar.rootDisplacements.isEmpty, "no beat has run yet")

        let roots = model.nodes.filter { $0.parent == nil }
        XCTAssertFalse(roots.isEmpty, "fixture precondition: at least one scene root")

        PoseStage.place(avatar: &avatar, placement: SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(avatar.rootDisplacements.count, roots.count,
                       "place must seed one accumulator per top-level root")
        for root in roots {
            let seeded = try XCTUnwrap(avatar.rootDisplacements[ObjectIdentifier(root)])
            XCTAssertTrue(seeded.hasAbsolute, "place's accumulator must carry its absolute request")
        }

        let snapshot = FrozenSnapshot(torsos: [:], indices: [0])
        PoseStage.displace(avatar: &avatar, partners: snapshot, dt: 1.0 / 60.0, staggerEnabled: false)

        for root in roots {
            let continued = try XCTUnwrap(avatar.rootDisplacements[ObjectIdentifier(root)])
            XCTAssertTrue(continued.hasAbsolute,
                          "displace must continue place's accumulator — a fresh one would never have seen the absolute request")
        }
    }
}
