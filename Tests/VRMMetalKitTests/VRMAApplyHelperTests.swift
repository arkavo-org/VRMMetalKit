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

/// `AnimationPlayer.applyClip(_:atTime:to:expressionController:lookAtController:)`
/// rolls the load → seek → update → applyMorphWeights four-call sequence
/// into one call. These tests verify that all three channels (expression
/// weights, lookAt target, clip-local time) reach their consumers in a
/// single invocation.
final class VRMAApplyHelperTests: XCTestCase {

    private func makeMinimalGLTF() -> GLTFDocument {
        let json: [String: Any] = ["asset": ["version": "2.0", "generator": "Test"]]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(GLTFDocument.self, from: data)
    }

    private func makeFixtureModel() -> VRMModel {
        return VRMModel(
            specVersion: .v1_0,
            meta: VRMMeta(licenseUrl: ""),
            humanoid: nil,
            gltf: makeMinimalGLTF()
        )
    }

    /// The headline integration: a single `applyClip` call sets a preset
    /// expression weight, a registered custom expression weight, and a
    /// look-at target — all three channels reach their consumers.
    func testApplyClipDrivesAllChannelsInOneCall() {
        let model = makeFixtureModel()
        let expressions = VRMExpressionController()
        let lookAt = VRMLookAtController()

        // Register a preset and a custom expression so the weight setters
        // have somewhere to write (setCustomExpressionWeight is a no-op on
        // an unregistered name).
        expressions.registerExpression(VRMExpression(), for: .happy)
        expressions.registerCustomExpression(VRMExpression(), name: "myCustom")

        var clip = AnimationClip(duration: 1.0)
        // MorphTrack is the unified channel: keys that match a
        // VRMExpressionPreset.rawValue route to setExpressionWeight on
        // applyMorphWeights; other keys route to setCustomExpressionWeight.
        clip.morphTracks.append(
            MorphTrack(key: VRMExpressionPreset.happy.rawValue) { _ in 0.5 }
        )
        clip.morphTracks.append(
            MorphTrack(key: "myCustom") { _ in 0.3 }
        )
        clip.lookAtTargetSampler = { _ in SIMD3<Float>(0, 0, -1) }

        let player = AnimationPlayer()
        player.applyClip(
            clip, atTime: 0, to: model,
            expressionController: expressions,
            lookAtController: lookAt
        )

        XCTAssertEqual(expressions.weight(for: .happy), 0.5, accuracy: 1e-5,
            "preset expression weight must be pushed by applyClip")
        let custom = expressions.weight(forCustom: "myCustom")
        XCTAssertNotNil(custom, "custom expression weight must be set after applyClip")
        XCTAssertEqual(custom ?? 0, 0.3, accuracy: 1e-5,
            "custom expression weight value mismatch")

        guard case .headLocalPoint(let target) = lookAt.target else {
            return XCTFail("lookAt.target must be .headLocalPoint after applyClip; got \(lookAt.target)")
        }
        XCTAssertEqual(target.x, 0, accuracy: 1e-5)
        XCTAssertEqual(target.y, 0, accuracy: 1e-5)
        XCTAssertEqual(target.z, -1, accuracy: 1e-5)
    }

    /// The `atTime` parameter must seek the clip — sampling the same clip
    /// at different times must produce different controller state.
    func testApplyClipHonoursAtTimeParameter() {
        let model = makeFixtureModel()
        let expressions = VRMExpressionController()
        expressions.registerExpression(VRMExpression(), for: .happy)

        var clip = AnimationClip(duration: 1.0)
        // Linear ramp: weight(t) = t. At t=0 → 0, at t=0.75 → 0.75.
        clip.morphTracks.append(
            MorphTrack(key: VRMExpressionPreset.happy.rawValue) { t in t }
        )

        let player = AnimationPlayer()

        player.applyClip(clip, atTime: 0, to: model, expressionController: expressions)
        XCTAssertEqual(expressions.weight(for: .happy), 0, accuracy: 1e-5,
            "applyClip at t=0 must sample weight = 0")

        player.applyClip(clip, atTime: 0.75, to: model, expressionController: expressions)
        XCTAssertEqual(expressions.weight(for: .happy), 0.75, accuracy: 1e-5,
            "applyClip at t=0.75 must sample weight = 0.75")
    }

    /// Passing `nil` for `lookAtController` must leave any previously
    /// attached controller in place — callers that wire the controller
    /// once at setup time and then drive playback frame-by-frame with
    /// `applyClip` should not need to re-pass it every call.
    func testApplyClipLeavesAttachedLookAtControllerAloneWhenParameterIsNil() {
        let model = makeFixtureModel()
        let preexistingLookAt = VRMLookAtController()
        let player = AnimationPlayer()
        player.lookAtController = preexistingLookAt

        var clip = AnimationClip(duration: 1.0)
        clip.lookAtTargetSampler = { _ in SIMD3<Float>(0.1, 0.2, 0.3) }

        player.applyClip(clip, atTime: 0, to: model)

        // Sampler drove the still-attached controller.
        guard case .headLocalPoint(let p) = preexistingLookAt.target else {
            return XCTFail("preexisting lookAtController should have been driven; got \(preexistingLookAt.target)")
        }
        XCTAssertEqual(p.x, 0.1, accuracy: 1e-5)
        XCTAssertEqual(p.y, 0.2, accuracy: 1e-5)
        XCTAssertEqual(p.z, 0.3, accuracy: 1e-5)
        // The player still references it (no nilling).
        XCTAssertTrue(player.lookAtController === preexistingLookAt,
            "applyClip with nil lookAtController parameter must not clear the player's existing reference")
    }

    // MARK: - VMK#294: gaze propagates to bones / expression weights

    /// VMK#294 — Setting `controller.target` is necessary but not sufficient
    /// for an offline render to show the gaze. The controller's "resolve target
    /// into eye-bone rotations" pass also needs to fire before the next draw,
    /// otherwise the rendered eyes stay at identity even though `look_at.yaw_deg`
    /// reads correctly from the controller's stored angles. Pre-fix the
    /// `vrma_lookat_*` conformance corpus rendered 10 byte-identical PNGs across
    /// the entire sweep because `applyClip` set `target` and never invoked
    /// `applyToBones`/`applyToExpressions`.
    func testApplyClipResolvesGazeToEyeBoneRotations() throws {
        let rig = try makeBoneModeRig()
        let player = AnimationPlayer()

        var clip = AnimationClip(duration: 1.0)
        // Look 1 m to the right of the head in head-local space — well
        // outside the controller's 0.02 rad deadband on either axis.
        clip.lookAtTargetSampler = { _ in SIMD3<Float>(1, 0, 0) }

        player.applyClip(
            clip, atTime: 0, to: rig.model,
            lookAtController: rig.controller
        )

        XCTAssertNotEqual(rig.leftEye.rotation, simd_quatf(real: 1, imag: SIMD3<Float>(0, 0, 0)),
            "VMK#294: left eye must rotate after applyClip with a non-forward sampler — got identity, which is the regression signature")
        XCTAssertNotEqual(rig.rightEye.rotation, simd_quatf(real: 1, imag: SIMD3<Float>(0, 0, 0)),
            "VMK#294: right eye must rotate after applyClip with a non-forward sampler — got identity, which is the regression signature")
    }

    /// VMK#294 — the expression-driven leg of the same fix. When the model
    /// declares `lookAt.type == .expression` and the controller has working
    /// `LookLeft/Right/Up/Down` custom expressions, `applyClip` must drive the
    /// matching preset weight, not leave them all at 0.
    func testApplyClipResolvesGazeToExpressionWeights() throws {
        let rig = try makeExpressionModeRig()
        let player = AnimationPlayer()

        var clip = AnimationClip(duration: 1.0)
        // Same head-local 1 m to the right — must drive LookRight.
        clip.lookAtTargetSampler = { _ in SIMD3<Float>(1, 0, 0) }

        player.applyClip(
            clip, atTime: 0, to: rig.model,
            expressionController: rig.expressions,
            lookAtController: rig.controller
        )

        let lookRight = rig.expressions.weight(forCustom: "LookRight") ?? 0
        XCTAssertGreaterThan(lookRight, 0,
            "VMK#294: LookRight weight must be > 0 after applyClip with a head-local rightward sampler — got 0, the regression signature")
    }

    // MARK: - Rig helpers for #294

    private func makeGLTFNode(name: String) throws -> GLTFNode {
        let json: [String: Any] = ["name": name]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(GLTFNode.self, from: data)
    }

    private struct BoneModeRig {
        let model: VRMModel
        let controller: VRMLookAtController
        let leftEye: VRMNode
        let rightEye: VRMNode
    }

    /// Bone-mode fixture: head + leftEye + rightEye, with `lookAt.type = .bone`.
    /// Smoothing and saccades disabled so the resolved eye rotations are a pure
    /// function of `target`, not of frame-rate-derived lerp state.
    private func makeBoneModeRig() throws -> BoneModeRig {
        let head = try VRMNode(index: 0, gltfNode: makeGLTFNode(name: "head"))
        let leftEye = try VRMNode(index: 1, gltfNode: makeGLTFNode(name: "leftEye"))
        let rightEye = try VRMNode(index: 2, gltfNode: makeGLTFNode(name: "rightEye"))

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
        controller.smoothing = 0
        controller.saccadeEnabled = false
        controller.setup(model: model)
        controller.mode = .bone

        return BoneModeRig(model: model, controller: controller,
                            leftEye: leftEye, rightEye: rightEye)
    }

    private struct ExpressionModeRig {
        let model: VRMModel
        let controller: VRMLookAtController
        let expressions: VRMExpressionController
    }

    /// Expression-mode fixture: head bone only (no eye bones), `lookAt.type =
    /// .expression`, and `LookLeft/Right/Up/Down` registered as custom
    /// expressions on the expression controller. With no eye bones the
    /// controller's `setup` auto-detects expression mode.
    private func makeExpressionModeRig() throws -> ExpressionModeRig {
        let head = try VRMNode(index: 0, gltfNode: makeGLTFNode(name: "head"))

        let humanoid = VRMHumanoid()
        humanoid.humanBones[.head] = VRMHumanoid.VRMHumanBone(node: 0)

        let model = VRMModel(
            specVersion: .v1_0,
            meta: VRMMeta(licenseUrl: ""),
            humanoid: humanoid,
            gltf: makeMinimalGLTF()
        )
        model.nodes = [head]
        model.lookAt = VRMLookAt()
        model.lookAt?.type = .expression

        let expressions = VRMExpressionController()
        for name in ["LookLeft", "LookRight", "LookUp", "LookDown"] {
            expressions.registerCustomExpression(VRMExpression(), name: name)
        }

        let controller = VRMLookAtController()
        controller.smoothing = 0
        controller.saccadeEnabled = false
        controller.setup(model: model, expressionController: expressions)
        controller.mode = .expression

        return ExpressionModeRig(model: model, controller: controller, expressions: expressions)
    }
}
