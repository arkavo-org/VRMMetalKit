// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Behavioral wind tests for the SpringBone compute system.
///
/// The existing `SpringBoneWindTests` verifies the wind *formula*
/// (`amplitude * sin(freq * phase)`) and that the params reach the
/// compute system without crashing, but does not assert that wind force
/// actually displaces a spring joint. The test-suite review called this
/// out as a P2 gap.
///
/// These tests run two otherwise-identical springs — one with wind, one
/// without — and assert that wind produces a measurable, directionally
/// correct deflection of the physics joint.
///
/// Determinism: per-frame host-owned `MTLCommandBuffer.waitUntilCompleted()`.
final class SpringBoneWindBehaviorTests: XCTestCase {

    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Could not create Metal command queue")
        }
        self.device = device
        self.commandQueue = queue
    }

    /// A spring exposed to constant wind in `+X` for 2 seconds should
    /// drift in `+X` by more than the no-wind control. This is the
    /// minimum-viable assertion that wind affects the simulation.
    func testWindDriftsJointInWindDirectionOverTime() throws {
        let modelWind = try makeSingleJointModel(stiffness: 0.0,
                                                 gravityPower: 0.0,
                                                 dragForce: 0.4)
        let modelNoWind = try makeSingleJointModel(stiffness: 0.0,
                                                   gravityPower: 0.0,
                                                   dragForce: 0.4)

        let sysWind = try SpringBoneComputeSystem(device: device)
        try sysWind.populateSpringBoneData(model: modelWind)
        let sysNoWind = try SpringBoneComputeSystem(device: device)
        try sysNoWind.populateSpringBoneData(model: modelNoWind)

        let initial = SpringBoneTestFixtures.readBonePosition(
            model: modelWind, boneIndex: 1)

        // 120 frames at 60 FPS = 2 seconds. Wind phase advances each frame
        // so the wind force oscillates, with the mean in +X.
        let totalFrames = 120
        let dtFrame: Float = 1.0 / 60.0
        var phase: Float = 0.0
        let windAmp: Float = 20.0
        let windFreq: Float = 1.0
        let windDir = SIMD3<Float>(1, 0, 0)

        for _ in 0..<totalFrames {
            phase += dtFrame
            var p = modelWind.springBoneGlobalParams!
            p.windAmplitude = windAmp
            p.windFrequency = windFreq
            p.windPhase = phase
            p.windDirection = windDir
            modelWind.springBoneGlobalParams = p
            try SpringBoneTestFixtures.runFrame(system: sysWind,
                                                model: modelWind,
                                                commandQueue: commandQueue,
                                                deltaTime: TimeInterval(dtFrame))

            try SpringBoneTestFixtures.runFrame(system: sysNoWind,
                                                model: modelNoWind,
                                                commandQueue: commandQueue,
                                                deltaTime: TimeInterval(dtFrame))
        }

        let finalWind = SpringBoneTestFixtures.readBonePosition(
            model: modelWind, boneIndex: 1)
        let finalNoWind = SpringBoneTestFixtures.readBonePosition(
            model: modelNoWind, boneIndex: 1)

        let driftWindAlongDir = simd_dot(finalWind - initial, windDir)
        let driftNoWindAlongDir = simd_dot(finalNoWind - initial, windDir)

        // The windy run should travel further along the wind direction
        // than the no-wind run, by at least 5 mm.
        let directionalDelta = driftWindAlongDir - driftNoWindAlongDir
        XCTAssertGreaterThan(directionalDelta, 0.005,
            "Wind in +X must drive the joint further along +X than the " +
            "no-wind control. Initial=\(initial), windFinal=\(finalWind), " +
            "noWindFinal=\(finalNoWind). " +
            "Drift along +X with wind=\(driftWindAlongDir), without=\(driftNoWindAlongDir), " +
            "delta=\(directionalDelta) (expected > 5 mm). " +
            "If delta ≈ 0, the wind force is not reaching the GPU kernel " +
            "or is being canceled by drag/stiffness.")

        SpringBoneTestFixtures.assertNoNaNPositions(model: modelWind)
    }

    /// Wind at higher amplitude must produce a *larger* tip deflection
    /// than wind at lower amplitude. This guards against the wind term
    /// being clamped or saturated somewhere in the kernel.
    func testWindAmplitudeScalesJointDeflection() throws {
        let amplitudes: [Float] = [5.0, 30.0]
        var deflections: [Float] = []

        for amp in amplitudes {
            let model = try makeSingleJointModel(stiffness: 0.0,
                                                 gravityPower: 0.0,
                                                 dragForce: 0.4)
            let sys = try SpringBoneComputeSystem(device: device)
            try sys.populateSpringBoneData(model: model)

            let initial = SpringBoneTestFixtures.readBonePosition(
                model: model, boneIndex: 1)

            var phase: Float = 0.0
            let dtFrame: Float = 1.0 / 60.0
            for _ in 0..<60 {
                phase += dtFrame
                var p = model.springBoneGlobalParams!
                p.windAmplitude = amp
                p.windFrequency = 0.5
                p.windPhase = phase
                p.windDirection = SIMD3<Float>(1, 0, 0)
                model.springBoneGlobalParams = p
                try SpringBoneTestFixtures.runFrame(system: sys, model: model,
                                                    commandQueue: commandQueue,
                                                    deltaTime: TimeInterval(dtFrame))
            }

            let final = SpringBoneTestFixtures.readBonePosition(model: model, boneIndex: 1)
            deflections.append(simd_distance(final, initial))
        }

        XCTAssertGreaterThan(deflections[1], deflections[0] * 1.5,
            "Wind amplitude 30 must deflect the joint significantly more " +
            "than amplitude 5 (≥ 1.5×). Got deflections=\(deflections). " +
            "Saturation here would imply the wind term is clipped " +
            "somewhere in the pipeline.")
    }

    /// Advancing `windPhase` over a settled run must produce a measurable
    /// oscillation in the joint's lateral position — not the constant
    /// drift you'd see if the gust factor were locked.
    ///
    /// The compute kernel's `gustFactor = 0.7 + 0.3 * (0.5 + 0.5*sin(0.5·freq·t)
    /// + 0.3·sin(1.3·freq·t)*0.5)` is intentionally always positive (gusts
    /// don't reverse direction), but it *does* vary with phase. Locking
    /// phase produces a steady-state offset; advancing phase produces an
    /// oscillation around that offset. We assert the latter.
    func testAdvancingPhaseProducesOscillatingDeflection() throws {
        let model = try makeSingleJointModel(stiffness: 0.0,
                                             gravityPower: 0.0,
                                             dragForce: 0.4)
        let sys = try SpringBoneComputeSystem(device: device)
        try sys.populateSpringBoneData(model: model)

        // Settle 30 frames at constant wind so we're sampling the
        // oscillating steady state, not the startup transient.
        var phase: Float = 0.0
        let dtFrame: Float = 1.0 / 60.0
        let amp: Float = 20.0
        let freq: Float = 3.0
        let dir = SIMD3<Float>(1, 0, 0)

        for _ in 0..<30 {
            phase += dtFrame
            var p = model.springBoneGlobalParams!
            p.windAmplitude = amp
            p.windFrequency = freq
            p.windPhase = phase
            p.windDirection = dir
            model.springBoneGlobalParams = p
            try SpringBoneTestFixtures.runFrame(system: sys, model: model,
                                                commandQueue: commandQueue,
                                                deltaTime: TimeInterval(dtFrame))
        }

        // Sample the joint's X coordinate over 120 frames.
        var samples: [Float] = []
        for _ in 0..<120 {
            phase += dtFrame
            var p = model.springBoneGlobalParams!
            p.windAmplitude = amp
            p.windFrequency = freq
            p.windPhase = phase
            p.windDirection = dir
            model.springBoneGlobalParams = p
            try SpringBoneTestFixtures.runFrame(system: sys, model: model,
                                                commandQueue: commandQueue,
                                                deltaTime: TimeInterval(dtFrame))
            samples.append(SpringBoneTestFixtures.readBonePosition(
                model: model, boneIndex: 1).x)
        }

        let minX = samples.min() ?? 0
        let maxX = samples.max() ?? 0
        let peakToPeak = maxX - minX

        XCTAssertGreaterThan(peakToPeak, 0.01,
            "Advancing windPhase at \(freq) Hz must produce ≥ 1 cm of " +
            "peak-to-peak lateral oscillation in the joint over 2 s. " +
            "Got min=\(minX), max=\(maxX), peak-to-peak=\(peakToPeak). " +
            "A flat trace would indicate the gust modulation is being " +
            "lost between the CPU `windPhase` advance and the GPU kernel.")
    }

    // MARK: - Model builder

    /// Single physics joint hanging from an anchor at `(0, 1, 0)`.
    /// Joint starts at world origin. No collider, configurable forces.
    private func makeSingleJointModel(stiffness: Float,
                                      gravityPower: Float,
                                      dragForce: Float) throws -> VRMModel {
        let model = try SpringBoneTestFixtures.makeChainModel(
            device: device,
            names: ["anchor", "joint"],
            translations: [SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, -1, 0)]
        )

        var anchor = SpringBoneTestFixtures.defaultJoint(node: 0)
        anchor.stiffness = 0.0
        anchor.gravityPower = 0.0
        anchor.dragForce = dragForce
        var phys = SpringBoneTestFixtures.defaultJoint(node: 1)
        phys.stiffness = stiffness
        phys.gravityPower = gravityPower
        phys.dragForce = dragForce

        var spring = VRMSpring(name: "WindBehaviorSpring")
        spring.joints = [anchor, phys]

        var sb = VRMSpringBone()
        sb.springs = [spring]
        model.springBone = sb

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 2, numSpheres: 0, numCapsules: 0)
        model.springBoneBuffers = buffers
        model.springBoneGlobalParams = SpringBoneTestFixtures.defaultGlobalParams(numBones: 2)

        return model
    }
}
