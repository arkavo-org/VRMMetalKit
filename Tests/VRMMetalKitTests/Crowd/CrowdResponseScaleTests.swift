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

/// Feature-complete subsystem 4: per-partner response scaling. A `responseScale`
/// on the collider structs (Swift + Metal, byte-matched) scales how firmly a
/// foreign body pushes a joint out; the coordinator tags each partner's
/// colliders with that partner's firmness (per-source). 1.0 = full, 0.0 = ghost.
final class CrowdResponseScaleTests: XCTestCase {

    /// The kernel scales the push by responseScale: full pushes most, a soft
    /// scale less, a ghost (0) not at all. Proves the shader change end to end.
    @MainActor func testResponseScaleScalesTheKernelPush() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }

        func run(scale: Float?, center: SIMD3<Float>?) async throws -> [SIMD3<Float>] {
            let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
            let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                options: VRMLoadingOptions(augmentSpringBoneColliders: true))
            model.updateNodeTransforms()
            try model.initializeSpringBoneGPUSystem(device: device)
            let sys = try SpringBoneComputeSystem(device: device)
            try sys.populateSpringBoneData(model: model)
            for _ in 0..<30 {
                if let scale, let center {
                    var s = SphereCollider(center: center, radius: 0.5, groupMask: 0)
                    s.responseScale = scale
                    sys.setForeignColliders(ForeignColliderSnapshot(spheres: [s], capsules: []))
                } else {
                    sys.setForeignColliders(ForeignColliderSnapshot())
                }
                sys.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
                sys.waitForPendingFrame()
            }
            return model.springBoneBuffers?.getCurrentPositions() ?? []
        }

        // Baseline (no foreign); use its centroid as the push center.
        let baseline = try await run(scale: nil, center: nil)
        XCTAssertFalse(baseline.isEmpty)
        let center = baseline.reduce(SIMD3<Float>(0, 0, 0), +) / Float(baseline.count)

        let full = try await run(scale: 1.0, center: center)
        let soft = try await run(scale: 0.3, center: center)
        let ghost = try await run(scale: 0.0, center: center)

        func displacementFromBaseline(_ p: [SIMD3<Float>]) -> Float {
            var d: Float = 0
            for i in baseline.indices where i < p.count { d += simd_distance(p[i], baseline[i]) }
            return d
        }
        let dFull = displacementFromBaseline(full)
        let dSoft = displacementFromBaseline(soft)
        let dGhost = displacementFromBaseline(ghost)

        XCTAssertGreaterThan(dFull, 1e-3, "full-scale foreign push measurably moves bones")
        XCTAssertLessThan(dSoft, dFull, "responseScale 0.3 pushes less than 1.0")
        XCTAssertLessThan(dGhost, dSoft, "responseScale 0.0 (ghost) pushes least (≈ no push)")
    }

    private struct Avatar {
        let renderer: VRMRenderer
        let model: VRMModel
        var system: SpringBoneComputeSystem { renderer.springBoneComputeSystem! }
    }
    @MainActor private func makeAvatar(_ device: MTLDevice, index: Int) async throws -> Avatar {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: true))
        for root in model.nodes where root.parent == nil {
            root.rotation = CrowdPlacement.facing(avatarIndex: index, avatarCount: 2)
        }
        model.updateNodeTransforms()
        var config = RendererConfig(); config.synchronousSpringBone = true
        let r = VRMRenderer(device: device, config: config)
        r.loadModel(model); r.enableSpringBone = true
        return Avatar(renderer: r, model: model)
    }

    /// The coordinator applies each partner's firmness per-source: avatar A yields
    /// differently to a firm partner B (1.0) than to a gentle B (0.2). Proves the
    /// setContactResponseScale seam + exchange tagging + kernel end to end.
    @MainActor func testCoordinatorAppliesPerSourceFirmness() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }

        func runAYieldingTo(bScale: Float) async throws -> [SIMD3<Float>] {
            let a = try await makeAvatar(device, index: 0)
            let b = try await makeAvatar(device, index: 1)   // overlapping bodies
            let group = SpringBoneContactGroup()
            a.renderer.joinContactGroup(group)
            b.renderer.joinContactGroup(group)
            b.renderer.setContactResponseScale(bScale, in: group)   // how firmly B pushes A
            for _ in 0..<30 {
                group.exchange()
                for av in [a, b] {
                    av.system.update(model: av.model, deltaTime: 1.0 / 60.0, commandBuffer: nil)
                    av.system.waitForPendingFrame()
                }
            }
            return a.model.springBoneBuffers?.getCurrentPositions() ?? []
        }

        let firm = try await runAYieldingTo(bScale: 1.0)
        let soft = try await runAYieldingTo(bScale: 0.2)
        var diff: Float = 0
        for i in firm.indices where i < soft.count { diff += simd_distance(firm[i], soft[i]) }
        XCTAssertGreaterThan(diff, 1e-3,
            "A yields measurably differently to a firm vs a gentle partner (per-source responseScale)")
    }
}
