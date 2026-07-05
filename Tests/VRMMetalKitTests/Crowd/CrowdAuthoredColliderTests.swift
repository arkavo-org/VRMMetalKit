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

/// Feature-complete subsystem 3: authored-collider inclusion. Each avatar's
/// contact set folds in its own authored BODY colliders (outside shapes on
/// humanoid bones), bounded and largest-first, for precision the standard
/// skeleton capsules miss.
final class CrowdAuthoredColliderTests: XCTestCase {

    /// The filter keeps outside colliders on humanoid bones; drops hair-anchored
    /// (non-humanoid node) and containment (`inside`) colliders.
    func testFilterKeepsOutsideBodyDropsHairAndContainment() {
        let humanoidNodes: Set<Int> = [10, 11]     // body bones
        let colliders = [
            VRMCollider(node: 10, shape: .sphere(offset: .zero, radius: 0.1)),                          // keep
            VRMCollider(node: 11, shape: .capsule(offset: .zero, radius: 0.2, tail: SIMD3(0, 1, 0))),   // keep
            VRMCollider(node: 10, shape: .insideSphere(offset: .zero, radius: 0.3)),                    // drop (containment)
            VRMCollider(node: 99, shape: .sphere(offset: .zero, radius: 0.4)),                          // drop (hair / non-humanoid node)
            VRMCollider(node: 10, shape: .plane(offset: .zero, normal: SIMD3(0, 1, 0))),                // drop (plane)
        ]
        let kept = SpringBoneContactColliderSet.filteredAuthoredBodyColliders(
            colliders, humanoidNodes: humanoidNodes, cap: 8)
        XCTAssertEqual(kept.count, 2)
        XCTAssertTrue(kept.allSatisfy { humanoidNodes.contains($0.node) }, "only body-bone colliders kept")
        for c in kept {
            switch c.shape {
            case .sphere, .capsule: break
            default: XCTFail("containment/plane collider leaked into the contact set")
            }
        }
    }

    /// When an avatar authors more body colliders than the cap, the largest by
    /// radius win (most significant body volumes).
    func testFilterCapsAtLargestRadius() {
        let humanoidNodes: Set<Int> = [1]
        let colliders = (0..<12).map {
            VRMCollider(node: 1, shape: .sphere(offset: .zero, radius: Float($0) * 0.01))
        }
        let kept = SpringBoneContactColliderSet.filteredAuthoredBodyColliders(
            colliders, humanoidNodes: humanoidNodes, cap: 8)
        XCTAssertEqual(kept.count, 8, "capped at M")
        let radii = kept.compactMap { c -> Float? in
            if case .sphere(_, let r) = c.shape { return r } else { return nil }
        }
        // Radii were 0.00…0.11; the 8 largest are 0.04…0.11.
        XCTAssertEqual(radii.min()!, 0.04, accuracy: 1e-6, "keeps the 8 largest radii")
        XCTAssertEqual(radii.max()!, 0.11, accuracy: 1e-6)
    }

    /// End to end on a real fixture: the contact set contains the skeleton set,
    /// folds in the model's authored body colliders (up to the cap), stays
    /// bounded, and never leaks a containment/plane shape.
    @MainActor func testContactSetFoldsInAuthoredBodyColliders() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()
        let humanoid = try XCTUnwrap(model.humanoid)

        let set = SpringBoneContactColliderSet.synthesize(model: model)
        let expectedAuthored = SpringBoneContactColliderSet.filteredAuthoredBodyColliders(
            model.springBone?.colliders ?? [],
            humanoidNodes: SpringBoneContactColliderSet.humanoidNodeIndices(humanoid),
            cap: SpringBoneContactColliderSet.maxAuthoredContactColliders)

        // Skeleton (up to 5) + the authored body colliders.
        XCTAssertGreaterThanOrEqual(set.count, expectedAuthored.count,
            "contact set includes the authored body colliders")
        // Each authored body collider's anchor node appears in the set.
        for authored in expectedAuthored {
            XCTAssertTrue(set.contains { $0.node == authored.node },
                "authored body collider on node \(authored.node) is folded into the contact set")
        }
        // Bounded and clean: no containment/plane shapes ever reach the contact set.
        XCTAssertLessThanOrEqual(set.count, 5 + SpringBoneContactColliderSet.maxAuthoredContactColliders)
        for c in set {
            switch c.shape {
            case .insideSphere, .insideCapsule, .plane:
                XCTFail("non-body/containment shape in the contact set")
            default: break
            }
        }
    }
}
