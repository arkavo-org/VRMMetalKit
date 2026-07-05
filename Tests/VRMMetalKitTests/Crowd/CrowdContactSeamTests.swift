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

final class CrowdContactSeamTests: XCTestCase {
    @MainActor private func renderer(_ device: MTLDevice, xOffset: Float) async throws -> VRMRenderer {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        // Offset via T/R/S (localMatrix would be clobbered by updateWorldTransform).
        for root in model.nodes where root.parent == nil {
            root.translation = root.translation + SIMD3<Float>(xOffset, 0, 0)
        }
        model.updateNodeTransforms()
        var config = RendererConfig()
        config.synchronousSpringBone = true
        let r = VRMRenderer(device: device, config: config)
        r.loadModel(model)
        r.enableSpringBone = true
        return r
    }

    /// Joining two overlapping avatars to a group and exchanging must inject each
    /// one's contact colliders into the other's spring system (seam wires through).
    @MainActor func testJoinContactGroupInjectsPartnerColliders() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let a = try await renderer(device, xOffset: -0.1)
        let b = try await renderer(device, xOffset: 0.1)   // overlapping (~0.2m apart)

        let group = SpringBoneContactGroup()
        a.joinContactGroup(group)
        b.joinContactGroup(group)
        group.exchange()

        // Drive each system's sync update so the sink writes the injected tail.
        for r in [a, b] {
            r.springBoneComputeSystem?.update(model: r.model!, deltaTime: 1.0/60.0, commandBuffer: nil)
            r.springBoneComputeSystem?.waitForPendingFrame()
        }
        let aForeign = a.springBoneComputeSystem?.activeForeignCapsules ?? 0
        let bForeign = b.springBoneComputeSystem?.activeForeignCapsules ?? 0
        XCTAssertGreaterThan(aForeign, 0, "A must receive B's contact capsules")
        XCTAssertGreaterThan(bForeign, 0, "B must receive A's contact capsules")

        // Leaving clears membership: a subsequent exchange injects nothing new.
        a.leaveContactGroup(group)
        b.leaveContactGroup(group)
        group.exchange()
        for r in [a, b] {
            r.springBoneComputeSystem?.update(model: r.model!, deltaTime: 1.0/60.0, commandBuffer: nil)
            r.springBoneComputeSystem?.waitForPendingFrame()
        }
        XCTAssertEqual(a.springBoneComputeSystem?.activeForeignCapsules, 0, "left group => no foreign")
    }
}
