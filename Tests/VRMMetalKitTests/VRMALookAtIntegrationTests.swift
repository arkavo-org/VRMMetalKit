//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

import XCTest
import simd
@testable import VRMMetalKit

/// Tests for VRMA `lookAt` channel → `VRMLookAtController` integration (#165 / m10).
///
/// PR #168 (B1) parses `lookAt` from VRMA and exposes
/// `AnimationClip.lookAtTargetSampler`. This file verifies that the data is
/// actually consumed by the renderer's look-at pipeline when a player runs
/// the clip — closing the end-to-end loop.
final class VRMALookAtIntegrationTests: XCTestCase {

    private func makeMinimalGLTF() -> GLTFDocument {
        let json: [String: Any] = ["asset": ["version": "2.0", "generator": "Test"]]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(GLTFDocument.self, from: data)
    }

    private func makeFixtureModel() -> VRMModel {
        let model = VRMModel(
            specVersion: .v1_0,
            meta: VRMMeta(licenseUrl: ""),
            humanoid: nil,
            gltf: makeMinimalGLTF()
        )
        return model
    }

    /// Player attached to a controller drives `target = .headLocalPoint(sampler(t))` when
    /// the clip carries a `lookAtTargetSampler` (VRMC_vrm_animation-1.0 specifies the
    /// sampled value is in head-bone-local space; see issue #190).
    func testPlayerDrivesLookAtControllerFromVRMASampler() {
        let model = makeFixtureModel()
        let controller = VRMLookAtController()

        var clip = AnimationClip(duration: 1.0)
        // Sampler maps t → (10t, 5t, 2t). At t=0.25 → (2.5, 1.25, 0.5).
        clip.lookAtTargetSampler = { t in
            SIMD3<Float>(10 * t, 5 * t, 2 * t)
        }

        let player = AnimationPlayer()
        player.lookAtController = controller
        player.load(clip)
        player.play()

        player.update(deltaTime: 0.25, model: model)

        guard case .headLocalPoint(let pos) = controller.target else {
            return XCTFail("Expected controller.target to be .headLocalPoint after VRMA-driven update; got \(controller.target)")
        }
        XCTAssertEqual(pos.x, 2.5, accuracy: 1e-5)
        XCTAssertEqual(pos.y, 1.25, accuracy: 1e-5)
        XCTAssertEqual(pos.z, 0.5, accuracy: 1e-5)
    }

    /// When `clip.lookAtTargetSampler` is nil, the player must not touch
    /// `controller.target` — preserving any user-set target (camera/user/forward).
    func testPlayerLeavesControllerTargetAloneWhenSamplerAbsent() {
        let model = makeFixtureModel()
        let controller = VRMLookAtController()
        controller.target = .camera

        let clip = AnimationClip(duration: 1.0) // no lookAtTargetSampler

        let player = AnimationPlayer()
        player.lookAtController = controller
        player.load(clip)
        player.play()

        player.update(deltaTime: 0.1, model: model)

        guard case .camera = controller.target else {
            return XCTFail("Player must not overwrite controller.target when clip has no lookAt sampler; got \(controller.target)")
        }
    }

    /// When `player.lookAtController` is nil, having a sampler on the clip is
    /// inert — no crash, no observable effect on any controller.
    func testNoControllerNoIntegration() {
        let model = makeFixtureModel()

        var clip = AnimationClip(duration: 1.0)
        clip.lookAtTargetSampler = { _ in SIMD3<Float>(1, 2, 3) }

        let player = AnimationPlayer()
        player.load(clip)
        player.play()

        // Must not crash.
        player.update(deltaTime: 0.5, model: model)
    }

    // MARK: - Head-local resolution (issue #190)

    /// Builds a minimal `GLTFNode` via the JSON decoder so a `VRMNode` can be
    /// constructed without a full glTF file. All transforms default to identity.
    private func makeGLTFNode(name: String) throws -> GLTFNode {
        let json: [String: Any] = ["name": name]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(GLTFNode.self, from: data)
    }

    /// Builds a tiny rig: head at the supplied world transform, with leftEye and
    /// rightEye as parent-less siblings, all wired through `VRMHumanoid`. The
    /// returned controller is set up with `smoothing = 0` and saccades disabled
    /// so `update(deltaTime:)` is deterministic. The eye nodes are returned so
    /// the caller can read `localRotation` after `update`.
    private func makeRig(
        headWorld: simd_float4x4
    ) throws -> (model: VRMModel, controller: VRMLookAtController, leftEye: VRMNode, rightEye: VRMNode) {
        let head = try VRMNode(index: 0, gltfNode: makeGLTFNode(name: "head"))
        let leftEye = try VRMNode(index: 1, gltfNode: makeGLTFNode(name: "leftEye"))
        let rightEye = try VRMNode(index: 2, gltfNode: makeGLTFNode(name: "rightEye"))
        head.worldMatrix = headWorld
        head.localMatrix = headWorld // parent-less, so updateWorldTransform() preserves the value

        let humanoid = VRMHumanoid()
        humanoid.humanBones[.head] = VRMHumanoid.VRMHumanBone(node: 0)
        humanoid.humanBones[.leftEye] = VRMHumanoid.VRMHumanBone(node: 1)
        humanoid.humanBones[.rightEye] = VRMHumanoid.VRMHumanBone(node: 2)

        let model = VRMModel(
            specVersion: .v1_0,
            meta: VRMMeta(licenseUrl: ""),
            humanoid: humanoid,
            gltf: makeMinimalGLTF()
        )
        model.nodes = [head, leftEye, rightEye]
        model.lookAt = VRMLookAt()
        model.lookAt?.type = .bone

        let controller = VRMLookAtController()
        controller.smoothing = 0          // instant — no frame-rate-dependent lerp
        controller.saccadeEnabled = false // remove jitter from the comparison
        controller.setup(model: model)
        controller.mode = .bone           // force bone path regardless of model detection

        return (model, controller, leftEye, rightEye)
    }

    private func assertQuatEqual(
        _ a: simd_quatf, _ b: simd_quatf,
        accuracy tol: Float,
        _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a.real,   b.real,   accuracy: tol, message, file: file, line: line)
        XCTAssertEqual(a.imag.x, b.imag.x, accuracy: tol, message, file: file, line: line)
        XCTAssertEqual(a.imag.y, b.imag.y, accuracy: tol, message, file: file, line: line)
        XCTAssertEqual(a.imag.z, b.imag.z, accuracy: tol, message, file: file, line: line)
    }

    /// With the head at a known non-identity world transform, `.headLocalPoint(p)`
    /// must produce the same eye rotations as `.point(head_world * p)`. This is
    /// the core invariant from VRMC_vrm_animation-1.0 §lookAt; pre-#190 the
    /// controller treated `.point` as world-space and silently dropped the head
    /// transform, so VRMA-authored gaze pointed in the wrong direction whenever
    /// the head was rotated or translated.
    func testHeadLocalPointResolvesThroughHeadWorldMatrix() throws {
        // Head translated up + rotated 90° around Y (head-local +Z → world +X).
        let translation = float4x4(translation: SIMD3<Float>(0.3, 1.6, 0.0))
        let rotation    = float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0)))
        let headWorld   = translation * rotation

        let localPoint  = SIMD3<Float>(0, 0, 1)              // 1 m forward in head-local
        let world4      = headWorld * SIMD4<Float>(localPoint, 1)
        let worldPoint  = SIMD3<Float>(world4.x, world4.y, world4.z)

        // Path A: world-space target.
        let rigA = try makeRig(headWorld: headWorld)
        rigA.controller.target = .point(worldPoint)
        rigA.controller.update(deltaTime: 1.0 / 60.0)

        // Path B: head-local target. Equivalent if (and only if) the controller
        // resolves through the head's world matrix.
        let rigB = try makeRig(headWorld: headWorld)
        rigB.controller.target = .headLocalPoint(localPoint)
        rigB.controller.update(deltaTime: 1.0 / 60.0)

        let tol: Float = 1e-5
        assertQuatEqual(rigA.leftEye.rotation,  rigB.leftEye.rotation,  accuracy: tol,
                        "left eye rotation must match between .point(head_world*p) and .headLocalPoint(p)")
        assertQuatEqual(rigA.rightEye.rotation, rigB.rightEye.rotation, accuracy: tol,
                        "right eye rotation must match between .point(head_world*p) and .headLocalPoint(p)")
    }

    /// Sanity check the fixture itself: with an identity head transform,
    /// `.point(p)` and `.headLocalPoint(p)` are degenerate and must agree.
    /// Catches setup errors that would otherwise let the non-identity test
    /// pass for the wrong reason.
    func testHeadLocalPointMatchesPointWhenHeadIsIdentity() throws {
        let p = SIMD3<Float>(0.5, 1.4, 1.0)

        let rigA = try makeRig(headWorld: matrix_identity_float4x4)
        rigA.controller.target = .point(p)
        rigA.controller.update(deltaTime: 1.0 / 60.0)

        let rigB = try makeRig(headWorld: matrix_identity_float4x4)
        rigB.controller.target = .headLocalPoint(p)
        rigB.controller.update(deltaTime: 1.0 / 60.0)

        assertQuatEqual(rigA.leftEye.rotation,  rigB.leftEye.rotation,  accuracy: 1e-5,
                        "identity-head fixture: left eye paths must agree")
        assertQuatEqual(rigA.rightEye.rotation, rigB.rightEye.rotation, accuracy: 1e-5,
                        "identity-head fixture: right eye paths must agree")
    }

    /// `AnimationPlayer.time` must expose the internal `currentTime` so consumers
    /// who want to drive the controller manually (e.g. via a different sampler)
    /// can read where playback currently sits.
    func testPlayerExposesCurrentTime() {
        let model = makeFixtureModel()
        let clip = AnimationClip(duration: 10.0)

        let player = AnimationPlayer()
        player.load(clip)
        player.play()

        XCTAssertEqual(player.time, 0, accuracy: 1e-6, "newly-loaded player must report time = 0")

        player.update(deltaTime: 0.42, model: model)
        XCTAssertEqual(player.time, 0.42, accuracy: 1e-6, "player.time must reflect accumulated deltaTime")

        player.seek(to: 3.0)
        XCTAssertEqual(player.time, 3.0, accuracy: 1e-6, "player.time must reflect seek")
    }
}
