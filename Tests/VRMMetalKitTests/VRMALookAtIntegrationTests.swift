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

    /// Player attached to a controller drives `target = .point(sampler(t))` when
    /// the clip carries a `lookAtTargetSampler`.
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

        guard case .point(let pos) = controller.target else {
            return XCTFail("Expected controller.target to be .point after VRMA-driven update; got \(controller.target)")
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
