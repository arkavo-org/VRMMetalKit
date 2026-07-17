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

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Compositor-level regression for the contact layers' `.additive` blend mode:
/// a yield/brace must multiply ON TOP of a lower-priority clip delta, never
/// replace it. Drives a real model through `AnimationLayerCompositor` with
/// `LocomotionBlendLayer` as the clip-mimicking base (priority −10, `.replace`,
/// rest-relative deltas) and `PosturalContactLayer` engaged above it.
final class LayerCompositionTests: XCTestCase {

    /// This avatar's chest world position; skips the test if the rig lacks a chest.
    @MainActor private func chestWorld(_ model: VRMModel) throws -> SIMD3<Float> {
        guard let humanoid = model.humanoid, let idx = humanoid.getBoneNode(.chest) else {
            throw XCTSkip("rig has no chest bone")
        }
        return model.nodes[idx].worldPosition
    }

    /// A partner torso capsule (vertical axis) whose surface penetrates `chest`.
    private func penetratingPartner(near chest: SIMD3<Float>) -> CapsuleCollider {
        let axis = chest + SIMD3<Float>(0.1, 0, 0)   // 0.1 m to the side of the chest
        return CapsuleCollider(p0: axis - SIMD3<Float>(0, 0.3, 0),
                               p1: axis + SIMD3<Float>(0, 0.3, 0), radius: 0.5, groupMask: 0)  // depth ~0.4
    }

    /// A clip holding a constant spine pose, with the locomotion metadata
    /// `LocomotionBlendLayer` requires.
    private func makeClip(stride: Float, spine: simd_quatf) -> AnimationClip {
        var clip = AnimationClip(duration: 1.0)
        clip.locomotion = LocomotionMetadata(
            version: 1, strideSpeed: stride, inPlace: true, sourceHipsHeight: 0.85)
        clip.addJointTrack(JointTrack(
            bone: .spine,
            rotationSampler: { _ in spine }
        ))
        return clip
    }

    /// The yield must compose onto the clip's spine pose: with the clip layer
    /// emitting the rest-relative delta `rest⁻¹·clipLocal` and the postural
    /// layer emitting `share` additively, the compositor's `base * composite`
    /// yields exactly `clipLocal * share`. With `.blend(1.0)` the composite
    /// becomes the bare share and the bone snaps out of the clip pose
    /// (`base * share`) for the contact's duration.
    @MainActor func testPosturalYield_additive_preservesClipPose() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()
        guard let spineIdx = model.humanoid?.getBoneNode(.spine) else { throw XCTSkip("no spine") }
        let chest = try chestWorld(model)

        // Clip-mimicking base layer: constant spine pose away from rest.
        let clipLocal = simd_quatf(angle: 0.25, axis: SIMD3<Float>(0, 1, 0))
        let locomotion = LocomotionBlendLayer()
        locomotion.setup(model: model)   // captures rest, same moment as compositor.setup
        try locomotion.setClips(idle: makeClip(stride: 0, spine: clipLocal),
                                walk: makeClip(stride: 1.5, spine: clipLocal))
        locomotion.targetSpeed = 0       // pure idle: delta == rest⁻¹·clipLocal

        let postural = PosturalContactLayer()
        postural.initialize(with: model)
        postural.partnerTorso = penetratingPartner(near: chest)

        let compositor = AnimationLayerCompositor()
        compositor.setup(model: model)
        compositor.addLayer(locomotion)
        compositor.addLayer(postural)
        for _ in 0..<40 {
            compositor.update(deltaTime: 1.0 / 60.0, context: AnimationContext())
        }

        let share = try XCTUnwrap(postural.evaluate().bones[.spine]?.rotation,
                                  "postural yield engages on contact")
        XCTAssertGreaterThan(share.angle, 1e-3, "a real yield delta, not a no-op")

        let expected = simd_normalize(clipLocal * share)
        let actual = model.nodes[spineIdx].rotation
        XCTAssertEqual(abs(simd_dot(expected.vector, actual.vector)), 1, accuracy: 1e-3,
                       "spine keeps the clip pose with the yield multiplied on top (clipLocal * share)")
    }
}
