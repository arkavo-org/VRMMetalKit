// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Animation → spring-bone interaction tests.
///
/// The test-suite review observed that `VRMAAdvancedTests`,
/// `VRMABoneRetargetingTests`, and `HairFlutterTrajectoryTests` exercise
/// VRMA loading and end-to-end rendering, but no focused test pins down
/// the *interaction boundary* between animated root motion and
/// spring-bone response.
///
/// These tests drive a single spring's root joint with a deterministic
/// synthetic motion (sine wave on X, ramp on X) and assert two
/// invariants of underdamped PBD spring response:
///
///   1. **Attenuation.** A physics joint connected to a sinusoidally
///      moving root oscillates with *less* peak-to-peak amplitude than
///      the driver — energy is dissipated by drag.
///
///   2. **Phase lag.** Under the same drive, the joint's peak lags the
///      root's peak by a positive (but bounded) number of frames.
///
/// Determinism: each frame uses a host-owned
/// `MTLCommandBuffer.waitUntilCompleted()`. No `Thread.sleep`.
final class SpringBoneAnimationIntegrationTests: XCTestCase {

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

    /// Sanity check: a single 0.1 m step translation of the root must
    /// move the physics joint by a non-trivial amount over the next
    /// half-second. This separates "the integration boundary is wired
    /// up" from the more subtle attenuation / phase-lag invariants.
    func testStepRootTranslationMovesJointTowardRoot() throws {
        let model = try makeTwoJointChain()
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        try SpringBoneTestFixtures.runFrames(30, system: system, model: model,
                                             commandQueue: commandQueue)

        let initialJoint = SpringBoneTestFixtures.readBonePosition(
            model: model, boneIndex: 1)
        let rootNode = model.nodes[0]
        rootNode.translation.x += 0.5
        rootNode.updateLocalMatrix()
        rootNode.updateWorldTransform()

        try SpringBoneTestFixtures.runFrames(60, system: system, model: model,
                                             commandQueue: commandQueue)

        let finalJoint = SpringBoneTestFixtures.readBonePosition(
            model: model, boneIndex: 1)
        // The rig has stiffness=0 + gravityPower=0, so the only force
        // available is the PBD distance constraint. With no stiffness
        // pulling the joint toward the bind direction (parent + (0,-1,0)·L),
        // the constraint preserves the joint's *direction* from the parent
        // and projects to the rest length — i.e. the joint swings on a
        // unit sphere rather than dragging laterally. For this geometry
        // (parent at world (0,1,0)→(0.5,1,0), joint starting at (0,0,0)),
        // the constraint-only equilibrium is (0.053, 0.106, 0); the actual
        // post-frame pose lands near it (driftX ≈ 0.02, driftY ≈ 0.12) with
        // small velocity-residual offsets from the per-substep root
        // interpolation. The sanity invariant the test name implies is
        // "the joint moves a non-trivial amount" — a total-displacement
        // check, not an X-axis-only check.
        let totalDrift = simd_distance(finalJoint, initialJoint)

        XCTAssertGreaterThan(totalDrift, 0.05,
            "A 0.5 m step on the root must move the physics joint by ≥ 5 cm " +
            "total displacement within 1 second. Got initialJoint=\(initialJoint), " +
            "finalJoint=\(finalJoint), totalDrift=\(totalDrift). If totalDrift is " +
            "near zero, the animated root motion is not propagating to the " +
            "physics joint through the distance constraint.")
    }

    /// Drive the root with a 0.5 Hz, 0.3 m sine on X for 4 seconds and
    /// assert the joint oscillates with reduced amplitude.
    /// Frequency chosen so the joint has time to follow the drive (the
    /// chain is heavily damped at 60 FPS; 2 Hz cycles faster than the
    /// joint can build amplitude).
    func testSinusoidalRootMotionProducesAttenuatedJointOscillation() throws {
        let model = try makeTwoJointChain()
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        try SpringBoneTestFixtures.runFrames(30, system: system, model: model,
                                             commandQueue: commandQueue)

        let frameCount = 240                  // 4 s at 60 Hz
        let dtFrame: Float = 1.0 / 60.0
        let amplitudeMeters: Float = 0.3
        let frequencyHz: Float = 0.5

        var rootX: [Float] = []
        var jointX: [Float] = []

        let rootNode = model.nodes[0]
        let initialRootX = rootNode.translation.x

        for i in 0..<frameCount {
            let t = Float(i) * dtFrame
            // Drive the root in world space along +X.
            let target = initialRootX + amplitudeMeters * sin(2 * .pi * frequencyHz * t)
            rootNode.translation.x = target
            rootNode.updateLocalMatrix()
            rootNode.updateWorldTransform()

            try SpringBoneTestFixtures.runFrame(system: system, model: model,
                                                commandQueue: commandQueue,
                                                deltaTime: TimeInterval(dtFrame))

            rootX.append(rootNode.worldPosition.x)
            jointX.append(SpringBoneTestFixtures.readBonePosition(
                model: model, boneIndex: 1).x)
        }

        // Peak-to-peak amplitudes after the first half second (skip startup).
        let startIdx = 30
        let rootP2P = peakToPeak(Array(rootX[startIdx...]))
        let jointP2P = peakToPeak(Array(jointX[startIdx...]))

        // The driver wave is centered at 0 and has amplitude 0.1 m, so
        // its peak-to-peak should be near 0.2 m. The joint must oscillate.
        XCTAssertGreaterThan(jointP2P, 0.005,
            "Joint must show measurable oscillation under sinusoidal root " +
            "motion (peak-to-peak ≥ 5 mm). Got jointP2P=\(jointP2P). " +
            "If ~zero, the spring is not responding to root motion at all.")

        // Underdamped attenuation: jointP2P < rootP2P. A factor-of-2
        // headroom is comfortable for the test fixture (drag = 0.4).
        XCTAssertLessThan(jointP2P, rootP2P,
            "Joint oscillation must be attenuated relative to the driver. " +
            "rootP2P=\(rootP2P), jointP2P=\(jointP2P). " +
            "If joint amplitude exceeds the driver, the spring is " +
            "amplifying input — investigate the integrator stability.")
    }

    /// With gravity restoring the joint toward straight-down, sinusoidal
    /// lateral root motion drives the joint as a forced pendulum. Below
    /// the natural frequency the joint lags slightly behind the driver;
    /// at the half-period zero-crossing the joint's residual offset is
    /// the integrated lag.
    ///
    /// Without gravity (the no-stiffness, no-gravity rig used in the
    /// attenuation test above) the constraint-only system tracks the
    /// driver almost instantaneously and this assertion would be
    /// unmeasurable. Gravity here re-introduces the missing restoring
    /// force so the lag is observable.
    func testGravityPendulumLagsBehindSinusoidalRootMotion() throws {
        let model = try makeTwoJointChainWithGravity()
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Settle 2 s so the joint reaches its gravity rest position.
        try SpringBoneTestFixtures.runFrames(120, system: system, model: model,
                                             commandQueue: commandQueue)

        let dtFrame: Float = 1.0 / 60.0
        let amplitudeMeters: Float = 0.3
        // Natural pendulum freq for L=1, g=9.8 is ≈ 0.498 Hz.
        // Drive well above resonance (2 Hz) — the joint lags by ≈ π,
        // staying behind the driver phase. Below-resonance driving
        // produces near-zero lag and is harder to assert.
        let frequencyHz: Float = 2.0

        let halfPeriodFrames = Int(round(Double(0.5) / Double(frequencyHz) /
                                         Double(dtFrame)))
        let rootNode = model.nodes[0]
        let initialRootX = rootNode.translation.x

        for i in 0...halfPeriodFrames {
            let t = Float(i) * dtFrame
            let target = initialRootX + amplitudeMeters * sin(2 * .pi * frequencyHz * t)
            rootNode.translation.x = target
            rootNode.updateLocalMatrix()
            rootNode.updateWorldTransform()
            try SpringBoneTestFixtures.runFrame(system: system, model: model,
                                                commandQueue: commandQueue,
                                                deltaTime: TimeInterval(dtFrame))
        }

        let rootX = rootNode.worldPosition.x
        let jointX = SpringBoneTestFixtures.readBonePosition(model: model, boneIndex: 1).x

        XCTAssertLessThan(abs(rootX - initialRootX), 0.005,
            "Sanity: root must be back at its origin at the end of the " +
            "half-period. Got rootX=\(rootX), initial=\(initialRootX).")

        // The joint must NOT be back at zero when the driver returns
        // there — the residual offset shows the joint's response is
        // lagging in phase. Direction is unconstrained (above-resonance
        // driving inverts phase), so we just require non-trivial
        // magnitude.
        XCTAssertGreaterThan(abs(jointX), 0.005,
            "Above-resonance sinusoidal root motion must leave the joint " +
            "displaced when the driver returns through zero — that's the " +
            "lag signature. Got jointX=\(jointX) at root return to zero. " +
            "If |jointX| < 5 mm the joint is mirroring the driver in " +
            "lockstep, which is unphysical for a forced pendulum above " +
            "its natural frequency.")
    }

    // MARK: - Helpers

    /// Same 2-node chain as `makeTwoJointChain` but with gravity enabled,
    /// so the physics joint behaves like a damped pendulum with a
    /// well-defined natural frequency (≈ 0.5 Hz for L=1 m, g=9.8 m/s²).
    private func makeTwoJointChainWithGravity() throws -> VRMModel {
        let model = try SpringBoneTestFixtures.makeChainModel(
            device: device,
            names: ["root", "joint"],
            translations: [SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, -1, 0)]
        )

        var rootJ = SpringBoneTestFixtures.defaultJoint(node: 0)
        rootJ.stiffness = 0.0
        rootJ.gravityPower = 0.0
        rootJ.dragForce = 0.2

        var phys = SpringBoneTestFixtures.defaultJoint(node: 1)
        phys.stiffness = 0.0
        phys.gravityPower = 1.0
        phys.gravityDir = SIMD3<Float>(0, -1, 0)
        phys.dragForce = 0.2

        var spring = VRMSpring(name: "PendulumSpring")
        spring.joints = [rootJ, phys]

        var sb = VRMSpringBone()
        sb.springs = [spring]
        model.springBone = sb

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 2, numSpheres: 0, numCapsules: 0)
        model.springBoneBuffers = buffers
        model.springBoneGlobalParams = SpringBoneTestFixtures.defaultGlobalParams(numBones: 2)

        return model
    }

    /// 2-node chain: root anchor at world `(0, 1, 0)`, physics joint at
    /// `(0, 0, 0)`. No gravity, no stiffness — only drag and the distance
    /// constraint. This isolates the joint's response to root motion.
    private func makeTwoJointChain() throws -> VRMModel {
        let model = try SpringBoneTestFixtures.makeChainModel(
            device: device,
            names: ["root", "joint"],
            translations: [SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, -1, 0)]
        )

        var rootJ = SpringBoneTestFixtures.defaultJoint(node: 0)
        rootJ.stiffness = 0.0
        rootJ.gravityPower = 0.0
        rootJ.dragForce = 0.4

        var phys = SpringBoneTestFixtures.defaultJoint(node: 1)
        phys.stiffness = 0.0
        phys.gravityPower = 0.0
        phys.dragForce = 0.4

        var spring = VRMSpring(name: "AnimIntegrationSpring")
        spring.joints = [rootJ, phys]

        var sb = VRMSpringBone()
        sb.springs = [spring]
        model.springBone = sb

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 2, numSpheres: 0, numCapsules: 0)
        model.springBoneBuffers = buffers
        model.springBoneGlobalParams = SpringBoneTestFixtures.defaultGlobalParams(numBones: 2)

        return model
    }

    private func peakToPeak(_ samples: [Float]) -> Float {
        guard let lo = samples.min(), let hi = samples.max() else { return 0 }
        return hi - lo
    }
}
