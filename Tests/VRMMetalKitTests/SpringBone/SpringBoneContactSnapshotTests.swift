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

final class SpringBoneContactSnapshotTests: XCTestCase {
    @MainActor func testSnapshotProducesWorldSpaceContactColliders() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()
        let system = try SpringBoneComputeSystem(device: device)
        let snap = system.contactColliderSnapshot(model: model)
        // Skeleton floor: >= 6 capsules (torso + 2 arms + brow + 2 thighs) and
        // >= 1 sphere (skull). Authored body colliders may fold in more; all must
        // be finite world-space.
        XCTAssertGreaterThanOrEqual(snap.capsules.count, 6)
        XCTAssertGreaterThanOrEqual(snap.spheres.count, 1)
        for s in snap.spheres {
            XCTAssertTrue(s.center.x.isFinite && s.center.y.isFinite && s.center.z.isFinite)
            XCTAssertTrue(s.radius.isFinite && s.radius > 0)
        }
        for c in snap.capsules {
            XCTAssertTrue(c.p0.x.isFinite && c.p1.x.isFinite && c.radius > 0)
            XCTAssertNotEqual(c.p0, c.p1, "world capsule endpoints differ")
        }
    }

    @MainActor func testContactTorsoCapsuleMatchesFirstSnapshotCapsule() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()
        let system = try SpringBoneComputeSystem(device: device)
        // The dedicated accessor (design §3.1) returns THIS avatar's torso capsule
        // in world space, so Components A/B never guess which capsule is the torso.
        let torso = try XCTUnwrap(system.contactTorsoCapsule(model: model),
                                  "a humanoid avatar yields a torso capsule")
        // Single source of truth: it is exactly the capsule `synthesize` emits
        // first (the trunk), so it can't drift from the snapshot's contents.
        let snap = system.contactColliderSnapshot(model: model)
        let first = try XCTUnwrap(snap.capsules.first)
        XCTAssertEqual(torso.p0, first.p0)
        XCTAssertEqual(torso.p1, first.p1)
        XCTAssertEqual(torso.radius, first.radius)
        XCTAssertNotEqual(torso.p0, torso.p1, "torso capsule spans spine -> chest")
    }

    @MainActor func testSnapshotIsPure_doesNotAdvanceOrPerturbSim() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        model.updateNodeTransforms()
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)
        // Advance one frame.
        system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
        system.waitForPendingFrame()
        let before = model.springBoneBuffers?.getCurrentPositions() ?? []
        // Calling snapshot repeatedly must not change sim state.
        for _ in 0..<5 { _ = system.contactColliderSnapshot(model: model) }
        let after = model.springBoneBuffers?.getCurrentPositions() ?? []
        XCTAssertEqual(before.count, after.count)
        for i in before.indices {
            XCTAssertEqual(before[i], after[i], "snapshot must not perturb bone positions")
        }
    }
}
