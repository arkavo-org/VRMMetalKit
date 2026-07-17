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

/// Headless integration for `PosturalContactLayer` (design §3/§6): the solver
/// wired to a real model's spine/chest, applied via the §3.1 direct post-multiply.
final class PosturalContactLayerTests: XCTestCase {

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
                               p1: axis + SIMD3<Float>(0, 0.3, 0), radius: 0.5)  // depth ~0.4
    }

    @MainActor func testPenetratingPartner_leansSpineAndChest_thenRecovers() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()
        let chest = try chestWorld(model)

        let layer = PosturalContactLayer()
        layer.initialize(with: model)
        layer.partnerTorso = penetratingPartner(near: chest)

        // Drive contact for enough frames to build a lean.
        for _ in 0..<40 {
            layer.update(deltaTime: 1.0 / 60.0, context: AnimationContext())
            layer.applyDirect(to: model)
            model.updateNodeTransforms()
        }
        let out = layer.evaluate()
        XCTAssertNotNil(out.bones[.spine], "spine yields on contact")
        XCTAssertNotNil(out.bones[.chest], "chest yields on contact")
        XCTAssertGreaterThan(layer.currentLeanAngle, 0.02, "a visible lean accumulates")

        // Partner leaves: the layer recovers to identity.
        layer.partnerTorso = CapsuleCollider(p0: SIMD3<Float>(9, 0, 0), p1: SIMD3<Float>(9, 1, 0), radius: 0.5)
        for _ in 0..<200 {
            layer.update(deltaTime: 1.0 / 60.0, context: AnimationContext())
            layer.applyDirect(to: model)
            model.updateNodeTransforms()
        }
        XCTAssertEqual(layer.currentLeanAngle, 0, accuracy: 1e-3, "recovers to identity on separation")
    }

    @MainActor func testZeroBlendAndDisabled_areExactNoOp() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()
        let chest = try chestWorld(model)
        guard let spineIdx = model.humanoid?.getBoneNode(.spine) else { throw XCTSkip("no spine") }
        let before = model.nodes[spineIdx].rotation

        // blendWeight = 0: penetrating partner, but no bone is touched.
        let layer = PosturalContactLayer(params: PosturalContactParams(blendWeight: 0))
        layer.initialize(with: model)
        layer.partnerTorso = penetratingPartner(near: chest)
        for _ in 0..<10 {
            layer.update(deltaTime: 1.0 / 60.0, context: AnimationContext())
            layer.applyDirect(to: model)
        }
        XCTAssertTrue(layer.evaluate().bones.isEmpty, "blendWeight 0 emits no bones")
        XCTAssertEqual(model.nodes[spineIdx].rotation, before, "spine rotation bit-unchanged")

        // isEnabled = false: same guarantee.
        let disabled = PosturalContactLayer()
        disabled.initialize(with: model)
        disabled.isEnabled = false
        disabled.partnerTorso = penetratingPartner(near: chest)
        disabled.update(deltaTime: 1.0 / 60.0, context: AnimationContext())
        disabled.applyDirect(to: model)
        XCTAssertTrue(disabled.evaluate().bones.isEmpty, "disabled emits no bones")
        XCTAssertEqual(model.nodes[spineIdx].rotation, before, "disabled leaves spine untouched")
    }

    /// §3D (load-bearing): `applyDirect` post-multiplies onto the CURRENT animated
    /// local rotation, not a captured base. Applying the same frame's yield onto
    /// two different animated spine rotations must leave the SAME residual delta
    /// (`base⁻¹ · result`) — impossible if it overwrote with a fixed base pose.
    @MainActor func testApplyDirect_composesOntoCurrentAnimatedRotation() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()
        let chest = try chestWorld(model)
        guard let spineIdx = model.humanoid?.getBoneNode(.spine) else { throw XCTSkip("no spine") }

        let layer = PosturalContactLayer()
        layer.initialize(with: model)
        layer.partnerTorso = penetratingPartner(near: chest)
        // Build a steady-state lean so the yield delta is non-trivial.
        for _ in 0..<40 {
            layer.update(deltaTime: 1.0 / 60.0, context: AnimationContext())
            model.updateNodeTransforms()
        }

        // Two distinct "animated" spine rotations, same yield frame.
        let rotA = simd_quatf(angle: 0.10, axis: SIMD3<Float>(0, 1, 0))
        let rotB = simd_quatf(angle: 0.30, axis: SIMD3<Float>(1, 0, 0))

        model.nodes[spineIdx].rotation = rotA
        layer.applyDirect(to: model)
        let resultA = model.nodes[spineIdx].rotation

        model.nodes[spineIdx].rotation = rotB
        layer.applyDirect(to: model)
        let resultB = model.nodes[spineIdx].rotation

        // The residual delta (share) is identical → it multiplied onto the live pose.
        let shareA = rotA.inverse * resultA
        let shareB = rotB.inverse * resultB
        XCTAssertGreaterThan(shareA.angle, 1e-3, "a real yield delta was applied, not a no-op")
        let diff = (shareA.inverse * shareB).angle
        XCTAssertEqual(diff, 0, accuracy: 1e-4, "same share onto both bases → post-multiply, not fixed-base overwrite")
    }

    /// §3.1 world-space exactness under an animated pose: with the spine rotated
    /// AWAY from identity (a clip pose), the post-multiplied yield must realize
    /// the lean in world space exactly — the spine's world rotation becomes
    /// `qShare · W_before`, tipping the trunk directly away from the partner.
    /// Parent-frame conjugation deflects the lean axis by the bone's local
    /// rotation; own-world conjugation (`W⁻¹·q·W`) is exact at any pose.
    @MainActor func testApplyDirect_animatedPose_worldLeanAxisExact() async throws {
        let path = getTestVRM10ModelPath(); try requireFixture(path, hint: testVRM10Filename)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device,
                                            options: VRMLoadingOptions(augmentSpringBoneColliders: false))
        model.updateNodeTransforms()
        guard let spineIdx = model.humanoid?.getBoneNode(.spine) else { throw XCTSkip("no spine") }
        guard let chestIdx = model.humanoid?.getBoneNode(.chest) else { throw XCTSkip("rig has no chest bone") }

        // Simulate a clip pose: yaw the spine well away from bind. The yaw axis
        // is (near-)perpendicular to the lean axis computed below, so a
        // parent-frame conjugation would deflect the world lean by ~0.6 rad.
        model.nodes[spineIdx].rotation = simd_quatf(angle: 0.6, axis: SIMD3<Float>(0, 1, 0))
        model.updateNodeTransforms()

        let spinePos = model.nodes[spineIdx].worldPosition
        let chest = model.nodes[chestIdx].worldPosition
        let spineUp = simd_normalize(chest - spinePos)

        let layer = PosturalContactLayer()
        layer.initialize(with: model)
        // Partner axis 0.1 m to the chest's +X → outward push is exactly −X.
        layer.partnerTorso = penetratingPartner(near: chest)
        // One long step: alpha = min(k·dt, 1) = 1 → the lean is at target.
        layer.update(deltaTime: 0.5, context: AnimationContext())
        let share = try XCTUnwrap(layer.evaluate().bones[.spine]?.rotation,
                                  "spine yield engages on contact")
        XCTAssertGreaterThan(share.angle, 0.05, "a real lean, not a no-op")

        let wBefore = worldRotation(model.nodes[spineIdx].worldMatrix)
        layer.applyDirect(to: model)
        model.updateNodeTransforms()
        let wAfter = worldRotation(model.nodes[spineIdx].worldMatrix)

        // The residual world rotation must BE the world-space share: same angle
        // (conjugation preserves it) about the solver's axis cross(spineUp, push).
        let residual = simd_normalize(wAfter * wBefore.inverse)
        XCTAssertEqual(residual.angle, share.angle, accuracy: 1e-3,
                       "applied world rotation magnitude matches the share")
        let push = SIMD3<Float>(-1, 0, 0)
        let expectedAxis = simd_normalize(simd_cross(spineUp, push))
        XCTAssertEqual(abs(simd_dot(residual.axis, expectedAxis)), 1, accuracy: 1e-3,
                       "lean axis is undeflected by the animated local pose")
        // Geometric intent: the top of the spine tips AWAY from the partner.
        let tipped = residual.act(spineUp)
        XCTAssertGreaterThan(simd_dot(tipped, push), 0.1,
                             "trunk leans along the outward push, away from the partner")
    }

    /// Orthonormalized rotation quaternion from a (possibly scaled) world matrix
    /// — mirrors the layer's own extraction so the test measures the same frame.
    private func worldRotation(_ m: simd_float4x4) -> simd_quatf {
        let c0 = simd_normalize(SIMD3<Float>(m[0][0], m[0][1], m[0][2]))
        let c1 = simd_normalize(SIMD3<Float>(m[1][0], m[1][1], m[1][2]))
        let c2 = simd_normalize(SIMD3<Float>(m[2][0], m[2][1], m[2][2]))
        return simd_quatf(simd_float3x3(c0, c1, c2))
    }
}
