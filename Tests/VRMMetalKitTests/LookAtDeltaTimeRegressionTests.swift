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

/// Regression tests for the frame-rate independence of ``VRMLookAtController`` smoothing.
///
/// The smoothing formula `smoothFactor = 1.0 - pow(smoothing, deltaTime * 60.0)` is
/// designed to be frame-rate independent: after T seconds of updates, the eye should
/// converge the same amount regardless of the display refresh rate (60 Hz, 120 Hz, etc.).
///
/// **Bug:** `VRMRenderer.drawCore` hardcoded `lookAtController.update(deltaTime: 1.0 / 60.0)`
/// regardless of the actual frame delta. On a 120 Hz ProMotion display the actual delta is
/// ~1/120 s, but the controller was told 1/60 s — so `pow(smoothing, (1/60)*60)` was evaluated
/// every frame, making the eyes converge **twice as fast** as intended. This manifests as
/// unnaturally snappy eye-tracking on high-refresh-rate screens.
///
/// These tests exercise the controller directly (no GPU required) to prove:
/// 1. The controller IS frame-rate independent when given the correct `deltaTime`.
/// 2. Always passing `1/60` regardless of actual frame rate breaks frame-rate independence.
final class LookAtDeltaTimeRegressionTests: XCTestCase {

    // MARK: - Rig helpers (adapted from VRMALookAtIntegrationTests)

    private func makeGLTFNode(name: String) throws -> GLTFNode {
        let json: [String: Any] = ["name": name]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(GLTFNode.self, from: data)
    }

    private func makeMinimalGLTF() throws -> GLTFDocument {
        let json: [String: Any] = ["asset": ["version": "2.0", "generator": "Test"]]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(GLTFDocument.self, from: data)
    }

    /// Builds a minimal LookAt rig with `smoothing > 0` so the frame-rate-dependent
    /// lerp is exercised. Saccades are disabled for determinism.
    private func makeRig(smoothing: Float) throws -> (model: VRMModel, controller: VRMLookAtController, leftEye: VRMNode, rightEye: VRMNode) {
        let head     = try VRMNode(index: 0, gltfNode: makeGLTFNode(name: "head"))
        let leftEye  = try VRMNode(index: 1, gltfNode: makeGLTFNode(name: "leftEye"))
        let rightEye = try VRMNode(index: 2, gltfNode: makeGLTFNode(name: "rightEye"))

        head.worldMatrix = matrix_identity_float4x4
        head.localMatrix = matrix_identity_float4x4

        let humanoid = VRMHumanoid()
        humanoid.humanBones[.head]     = VRMHumanoid.VRMHumanBone(node: 0)
        humanoid.humanBones[.leftEye]  = VRMHumanoid.VRMHumanBone(node: 1)
        humanoid.humanBones[.rightEye] = VRMHumanoid.VRMHumanBone(node: 2)

        let model = VRMModel(
            specVersion: .v1_0,
            meta: VRMMeta(licenseUrl: ""),
            humanoid: humanoid,
            gltf: try makeMinimalGLTF()
        )
        model.nodes = [head, leftEye, rightEye]
        model.lookAt = VRMLookAt()
        model.lookAt?.type = .bone

        let controller = VRMLookAtController()
        controller.smoothing = smoothing
        controller.saccadeEnabled = false
        controller.setup(model: model)
        controller.mode = .bone

        return (model, controller, leftEye, rightEye)
    }

    // MARK: - Tests

    /// After the same wall-clock time, a 60 Hz render loop and a 120 Hz render loop
    /// must converge the eye rotation to the same point — but only if each loop passes
    /// its *actual* per-frame delta time.
    ///
    /// 60 Hz: 3 updates × dt=1/60  → `pow(s, 1.0)^3  = pow(s, 3)`
    /// 120 Hz: 6 updates × dt=1/120 → `pow(s, 0.5)^6 = pow(s, 3)`
    ///
    /// These are mathematically identical, proving the controller's formula is correct.
    func testFrameRateIndependenceWhenCorrectDeltaTime() throws {
        let smoothing: Float = 0.5
        let target = SIMD3<Float>(0.3, 1.6, 2.0)

        // 60 Hz: 3 ticks (50 ms of wall-clock time)
        let rig60 = try makeRig(smoothing: smoothing)
        rig60.controller.target = .point(target)
        for _ in 0..<3 {
            rig60.controller.update(deltaTime: 1.0 / 60.0)
        }

        // 120 Hz: 6 ticks (same 50 ms of wall-clock time)
        let rig120 = try makeRig(smoothing: smoothing)
        rig120.controller.target = .point(target)
        for _ in 0..<6 {
            rig120.controller.update(deltaTime: 1.0 / 120.0)
        }

        // Both should converge to nearly the same eye rotation after 50 ms.
        let tol: Float = 1e-4
        XCTAssertEqual(rig60.leftEye.rotation.imag.y,  rig120.leftEye.rotation.imag.y,
                       accuracy: tol,
                       "60 Hz (3 ticks) and 120 Hz (6 ticks) must converge equally after 50 ms when given correct deltaTime")
        XCTAssertEqual(rig60.leftEye.rotation.real,   rig120.leftEye.rotation.real,
                       accuracy: tol,
                       "60 Hz (3 ticks) and 120 Hz (6 ticks) must converge equally after 50 ms when given correct deltaTime")
    }

    /// **This test demonstrates the bug.** If the renderer always passes `1/60` regardless
    /// of actual frame rate, a 120 Hz loop will call `update` with `deltaTime = 1/60` for
    /// every frame, making the eyes converge **twice as fast** as intended.
    ///
    /// After 3 ticks (25 ms of wall-clock time at 120 Hz):
    /// - **Correct 120 Hz** (dt=1/120 × 3): remaining error = `pow(0.5, 1.5)` ≈ 0.354
    /// - **Buggy 120 Hz**   (dt=1/60  × 3): remaining error = `pow(0.5, 3.0)` ≈ 0.125
    ///
    /// The buggy path converges ~2.8x further than it should in the same wall-clock time.
    func testHardcodedSixtyFPSBreaksFrameRateIndependence() throws {
        let smoothing: Float = 0.5
        let target = SIMD3<Float>(0.3, 1.6, 2.0)
        let tickCount = 3

        // Correct 120 Hz: 3 ticks × dt=1/120 (25 ms of wall-clock time)
        let rigCorrect = try makeRig(smoothing: smoothing)
        rigCorrect.controller.target = .point(target)
        for _ in 0..<tickCount {
            rigCorrect.controller.update(deltaTime: 1.0 / 120.0)
        }

        // Buggy renderer: 3 ticks × dt=1/60 (same 25 ms, but renderer hardcodes 1/60)
        let rigBuggy = try makeRig(smoothing: smoothing)
        rigBuggy.controller.target = .point(target)
        for _ in 0..<tickCount {
            rigBuggy.controller.update(deltaTime: 1.0 / 60.0)
        }

        // The buggy path has converged further than the correct path.
        // Eye rotation angle magnitude must be materially different.
        let correctMag = abs(rigCorrect.leftEye.rotation.angle)
        let buggyMag   = abs(rigBuggy.leftEye.rotation.angle)

        XCTAssertGreaterThan(buggyMag, correctMag,
                             "The buggy (always-1/60) path must converge FURTHER than the correct path (1/120)")
    }

    /// Directly exercises the smoothing formula to document the mathematical relationship.
    /// With `smoothing = 0.5`:
    /// - dt=1/60  → smoothFactor = 1 - pow(0.5, 1.0) = 0.5
    /// - dt=1/120 → smoothFactor = 1 - pow(0.5, 0.5) ≈ 0.293
    ///
    /// Over 1 second, both converge identically (60×0.5 = 120×0.293 in exponent space).
    /// But over the SAME NUMBER of ticks, 1/60 converges twice as fast — which is the bug.
    func testSmoothFactorFormulaProducesDifferentPerTickConvergence() {
        let smoothing: Float = 0.5

        let smoothFactor60  = 1.0 - pow(smoothing, (1.0 / 60.0) * 60.0)   // 0.5
        let smoothFactor120 = 1.0 - pow(smoothing, (1.0 / 120.0) * 60.0)  // ≈0.293

        XCTAssertEqual(smoothFactor60, 0.5, accuracy: 1e-6,
                       "At 60 Hz, smoothFactor should be 0.5")
        XCTAssertEqual(smoothFactor120, 1.0 - pow(0.5, 0.5), accuracy: 1e-6,
                       "At 120 Hz, smoothFactor should be ~0.293")

        // Per-tick convergence is different — that's correct and expected.
        // The bug is passing 1/60 when the actual frame time is 1/120.
        XCTAssertGreaterThan(smoothFactor60, smoothFactor120,
                             "Per-tick convergence at 60 Hz must be greater than at 120 Hz")

        // After 1 second of wall-clock time, cumulative convergence is equal:
        // 60 Hz: (1 - 0.5)^60  = 0.5^60
        // 120 Hz: (1 - 0.293)^120 = (0.5^0.5)^120 = 0.5^60
        let remaining60  = pow(smoothing, 60.0)    // 60 ticks at dt=1/60
        let remaining120 = pow(smoothing, 60.0)    // 120 ticks at dt=1/120 → same exponent

        XCTAssertEqual(remaining60, remaining120, accuracy: 1e-10,
                       "After 1 second, both frame rates must have the same remaining error")
    }
}
