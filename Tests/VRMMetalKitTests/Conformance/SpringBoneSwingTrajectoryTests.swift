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
import Metal
import simd
@testable import VRMMetalKit

/// vrm-conformance VMK#283: the swing-mode `animate_root_transform` flow must
/// be deterministic — the same fixture simulated twice must yield byte-identical
/// joint positions.
///
/// This replicates the conformance flow at the **sim level** — load,
/// `warmupPhysics(steps: 30)`, then a per-frame `animate_root_transform` loop
/// (root translation 0 → (0.15, 0, 0) over 0.25 s at 60 fps) — and reads joint
/// positions from `bonePosCurr` after draining the spring system's command
/// queue. It runs each `swing_springbone_stiffness_*` fixture twice and asserts
/// the two runs match exactly.
///
/// An earlier revision asserted the four stiffness values produced *distinct*
/// trajectories. That held only because the harness drained an unrelated
/// command queue and read a racy pre-equilibrium state; with a correct drain
/// the swing fixtures settle to gravity equilibrium where stiffness no longer
/// differentiates the final pose (VMK#240). #283 resolved the underlying
/// CPU/GPU race; this test now guards the determinism that race violated.
final class SpringBoneSwingTrajectoryTests: XCTestCase {

    /// Swing animation parameters mirroring the conformance fixture's
    /// `animation.root_transform` block.
    private let swingTranslationEnd = SIMD3<Float>(0.15, 0, 0)
    private let swingDurationSeconds: Float = 0.25
    private let swingFPS: Int = 60
    private let warmupSteps: Int = 30

    func testStiffnessSweepTrajectoriesAreDeterministic() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }

        let fixtures = [
            "swing_springbone_stiffness_0",
            "swing_springbone_stiffness_0p2",
            "swing_springbone_stiffness_0p8",
            "swing_springbone_stiffness_1"
        ]

        for fixture in fixtures {
            let first = try await simulateSwingAndCaptureJoints(
                fixture: fixture, device: device)
            let second = try await simulateSwingAndCaptureJoints(
                fixture: fixture, device: device)

            XCTAssertEqual(first.count, second.count,
                "\(fixture): joint count differs between identical runs")
            XCTAssertFalse(first.isEmpty, "\(fixture): no joints captured")
            for (index, (a, b)) in zip(first, second).enumerated() {
                XCTAssertEqual(a.x.bitPattern, b.x.bitPattern,
                    "\(fixture): joint \(index).x diverged between identical " +
                    "runs — animated spring-bone path is non-deterministic (#283)")
                XCTAssertEqual(a.y.bitPattern, b.y.bitPattern,
                    "\(fixture): joint \(index).y diverged between identical " +
                    "runs — animated spring-bone path is non-deterministic (#283)")
                XCTAssertEqual(a.z.bitPattern, b.z.bitPattern,
                    "\(fixture): joint \(index).z diverged between identical " +
                    "runs — animated spring-bone path is non-deterministic (#283)")
            }
        }
    }

    // MARK: - Harness

    private func simulateSwingAndCaptureJoints(
        fixture: String,
        device: MTLDevice
    ) async throws -> [SIMD3<Float>] {
        guard let url = Bundle.module.url(
            forResource: fixture,
            withExtension: "vrm",
            subdirectory: "TestData/Conformance"
        ) else {
            throw XCTSkip("\(fixture).vrm not bundled in Conformance/")
        }

        let model = try await VRMModel.load(from: url, device: device)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        system.warmupPhysics(model: model, steps: warmupSteps)

        // Root-transform animation: snapshot original root translations,
        // then for each frame set translation = original + offset and tick
        // the compute system once. Mirrors the conformance adapter's
        // `animate_root_transform` loop.
        let rootNodes = model.nodes.filter { $0.parent == nil }
        let originals = rootNodes.map { $0.translation }
        let totalFrames = max(1, Int((swingDurationSeconds * Float(swingFPS)).rounded()))
        for frame in 1...totalFrames {
            let t = Float(frame) / Float(totalFrames)
            let offset = swingTranslationEnd * t
            for (idx, root) in rootNodes.enumerated() {
                root.translation = originals[idx] + offset
                root.updateWorldTransform()
            }
            system.update(model: model, deltaTime: 1.0 / Double(swingFPS))
        }

        // Drain the spring system's own command queue so bonePosCurr reflects
        // the final substep. `waitForPendingFrame()` blocks on the last
        // self-committed command buffer; a fresh buffer on an unrelated queue
        // would not serialise against the spring system's work.
        system.waitForPendingFrame()

        guard let buffers = model.springBoneBuffers,
              let bonePosCurr = buffers.bonePosCurr,
              buffers.numBones > 0 else {
            XCTFail("\(fixture): no spring-bone buffers after simulation")
            return []
        }
        let ptr = bonePosCurr.contents().bindMemory(
            to: SIMD3<Float>.self,
            capacity: buffers.numBones
        )
        return (0..<buffers.numBones).map { ptr[$0] }
    }
}
