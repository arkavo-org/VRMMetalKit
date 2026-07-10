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

/// Feature-complete subsystem 2: N>2 crowds. The coordination + physics already
/// generalize; these prove nearest-K partner selection (the memory-safety +
/// correct-physics bound) and multi-avatar stability.
final class CrowdNPlusTests: XCTestCase {

    /// Nearest-K excludes the farthest partners when a crowd exceeds the cap, and
    /// never includes self.
    func testNearestPartnersExcludesFarthestWhenCapped() {
        // 8 avatars on a line at x = 0…7. For avatar 0 the nearest 6 are indices
        // 1…6; index 7 (farthest) is dropped.
        let positions = (0..<8).map { SIMD3<Float>(Float($0), 0, 0) }
        let nearest = Set(SpringBoneContactGroup.nearestPartnerIndices(positions: positions, for: 0, count: 6))
        XCTAssertEqual(nearest, Set([1, 2, 3, 4, 5, 6]))
        XCTAssertFalse(nearest.contains(7), "farthest avatar dropped when capped")
        XCTAssertFalse(nearest.contains(0), "self excluded")
    }

    /// Under the cap, every partner is kept (small crowds contact each other fully).
    func testNearestPartnersKeepsAllUnderCap() {
        let positions = (0..<4).map { SIMD3<Float>(Float($0), 0, 0) }   // 3 partners < cap 6
        let nearest = Set(SpringBoneContactGroup.nearestPartnerIndices(positions: positions, for: 1, count: 6))
        XCTAssertEqual(nearest, Set([0, 2, 3]), "under the cap all partners kept")
    }

    /// Nearest-K is distance-ranked, not index-ordered: a far avatar with a low
    /// index is dropped before a near avatar with a high index.
    func testNearestPartnersRanksByDistanceNotIndex() {
        // Avatar 0 at origin. Index 1 is far (x=100); indices 2…8 are near (x=2…8).
        var positions = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(100, 0, 0)]
        positions += (2...8).map { SIMD3<Float>(Float($0), 0, 0) }
        let nearest = Set(SpringBoneContactGroup.nearestPartnerIndices(positions: positions, for: 0, count: 6))
        XCTAssertFalse(nearest.contains(1), "the far low-index avatar is dropped despite its low index")
        XCTAssertTrue(nearest.contains(2), "a near high-index avatar is kept")
    }

    /// A participant with an empty contact snapshot (no humanoid → origin-defaulted
    /// centroid) must not be selected as a nearest-K partner and displace a
    /// genuinely nearby one from the fixed-size slot set (Gitar review).
    func testEmptySnapshotParticipantExcludedFromPartners() {
        // Avatar 0 at origin. Index 1 is an EMPTY participant that also sits at the
        // origin (its centroid fell back to (0,0,0)); indices 2…8 are real neighbours.
        var positions = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 0, 0)]
        positions += (2...8).map { SIMD3<Float>(Float($0), 0, 0) }
        var empty = [Bool](repeating: false, count: positions.count)
        empty[1] = true

        let excluded = Set(SpringBoneContactGroup.nearestPartnerIndices(
            positions: positions, for: 0, count: 6, excludingEmpty: empty))
        XCTAssertFalse(excluded.contains(1), "an empty-snapshot participant must not be selected as a partner")
        XCTAssertTrue(excluded.contains(7), "excluding the empty participant frees its slot for a real neighbour")
        XCTAssertEqual(excluded, Set([2, 3, 4, 5, 6, 7]))

        // Without the mask the origin-sitting empty participant would win a slot and
        // push the farthest real neighbour (index 8, then 7) out — the bug.
        let unmasked = Set(SpringBoneContactGroup.nearestPartnerIndices(
            positions: positions, for: 0, count: 6))
        XCTAssertTrue(unmasked.contains(1), "sanity: unmasked selection would pick the origin empty participant")
    }

    /// Three overlapping avatars in a contracted ring: contact injects for each,
    /// and the sim stays finite over many frames (the multi-way 'sandwich' stress).
    @MainActor func testThreeAvatarContactStable() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        var systems: [(SpringBoneComputeSystem, VRMModel)] = []
        let group = SpringBoneContactGroup()
        for i in 0..<3 {
            let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
            let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                options: VRMLoadingOptions(augmentSpringBoneColliders: true))
            for root in model.nodes where root.parent == nil {
                root.rotation = CrowdPlacement.facing(avatarIndex: i, avatarCount: 3)
                root.translation = root.translation
                    + CrowdPlacement.rootTranslation(avatarIndex: i, avatarCount: 3, halfSeparation: 0.12)
            }
            model.updateNodeTransforms()
            try model.initializeSpringBoneGPUSystem(device: device)
            let sys = try SpringBoneComputeSystem(device: device)
            try sys.populateSpringBoneData(model: model)
            group.add(system: sys, model: model)
            systems.append((sys, model))
        }

        for _ in 0..<60 {
            group.exchange()
            for (sys, model) in systems {
                sys.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
                sys.waitForPendingFrame()
            }
        }

        // Each avatar has 2 partners (< cap), both nearby => contact active.
        XCTAssertGreaterThan(systems[0].0.activeForeignCapsules, 0,
            "3-avatar ring injects neighbour contact colliders")
        for (_, model) in systems {
            let positions = model.springBoneBuffers?.getCurrentPositions() ?? []
            XCTAssertFalse(positions.isEmpty)
            for p in positions {
                XCTAssertTrue(p.x.isFinite && p.y.isFinite && p.z.isFinite,
                    "3-avatar contact stays finite (no explosion)")
            }
        }
    }
}
