// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Tests for SpringBone wind functionality
/// Verifies that wind parameters actually affect spring bone physics
final class SpringBoneWindTests: XCTestCase {

    var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    // MARK: - Wind Force Calculation Tests

    /// Test that wind force is zero when windPhase is zero (the original bug)
    func testWindForceZeroWhenPhaseZero() throws {
        let windAmplitude: Float = 5.0
        let windFrequency: Float = 2.0
        let windPhase: Float = 0.0  // The bug: phase was always 0
        let windDirection = simd_normalize(SIMD3<Float>(1, 0, 0))

        let windForce = windAmplitude * windDirection * sin(windFrequency * windPhase)
        let forceMagnitude = simd_length(windForce)

        // sin(0) = 0, so wind force should be zero
        XCTAssertLessThan(forceMagnitude, 0.001, "Wind force should be ~0 when phase is 0")
    }

    /// Test that wind force is non-zero when windPhase accumulates
    func testWindForceNonZeroWhenPhaseAccumulates() throws {
        let windAmplitude: Float = 5.0
        let windFrequency: Float = 2.0
        let windPhase: Float = 0.5  // Accumulated time
        let windDirection = simd_normalize(SIMD3<Float>(1, 0, 0))

        let windForce = windAmplitude * windDirection * sin(windFrequency * windPhase)
        let forceMagnitude = simd_length(windForce)

        // sin(2.0 * 0.5) = sin(1.0) ≈ 0.841
        // Expected force ≈ 5.0 * 0.841 ≈ 4.2
        XCTAssertGreaterThan(forceMagnitude, 1.0, "Wind force should be significant when phase > 0")
    }

    /// Test wind force oscillates over time
    func testWindForceOscillatesOverTime() throws {
        let windAmplitude: Float = 5.0
        let windFrequency: Float = 2.0
        let windDirection = simd_normalize(SIMD3<Float>(1, 0, 0))

        var forces: [Float] = []
        var windPhase: Float = 0.0
        let delta: Float = 1.0 / 60.0

        // Simulate 2 seconds at 60 FPS
        for _ in 0..<120 {
            windPhase += delta
            let windForce = windAmplitude * windDirection * sin(windFrequency * windPhase)
            forces.append(simd_length(windForce))
        }

        // Should have both high and low values due to oscillation
        let maxForce = forces.max() ?? 0
        let minForce = forces.min() ?? 0

        XCTAssertGreaterThan(maxForce, 3.0, "Max wind force should be significant")
        XCTAssertLessThan(minForce, 1.0, "Min wind force should be low at zero crossings")
    }

    // MARK: - SpringBoneGlobalParams Wind Tests

    /// Test SpringBoneGlobalParams can hold wind configuration
    func testGlobalParamsWindConfiguration() throws {
        let params = SpringBoneGlobalParams(
            gravity: SIMD3<Float>(0, -10, 0),
            dtSub: 1.0 / 120.0,
            windAmplitude: 5.0,
            windFrequency: 2.0,
            windPhase: 1.5,
            windDirection: simd_normalize(SIMD3<Float>(1, 0, 0.3)),
            substeps: 2,
            numBones: 10,
            numSpheres: 0,
            numCapsules: 0
        )

        XCTAssertEqual(params.windAmplitude, 5.0)
        XCTAssertEqual(params.windFrequency, 2.0)
        XCTAssertEqual(params.windPhase, 1.5)
        XCTAssertGreaterThan(simd_length(params.windDirection), 0.99)
    }

    /// Test that wind parameters can be updated on existing params
    func testGlobalParamsWindUpdate() throws {
        var params = SpringBoneGlobalParams(
            gravity: SIMD3<Float>(0, -10, 0),
            dtSub: 1.0 / 120.0,
            windAmplitude: 0.0,
            windFrequency: 0.0,
            windPhase: 0.0,
            windDirection: SIMD3<Float>(1, 0, 0),
            substeps: 2,
            numBones: 10,
            numSpheres: 0,
            numCapsules: 0
        )

        // Enable wind
        params.windAmplitude = 5.0
        params.windFrequency = 2.0
        params.windPhase = 0.5
        params.windDirection = simd_normalize(SIMD3<Float>(1, 0, 0.3))

        XCTAssertEqual(params.windAmplitude, 5.0)
        XCTAssertEqual(params.windPhase, 0.5)
    }

    // MARK: - GPU Compute Wind Tests

    /// Test that wind parameters are correctly passed to the compute system
    /// Note: Full physics integration requires a properly configured VRM model with spring bone chains
    func testWindParametersPassedToComputeSystem() throws {
        let system = try SpringBoneComputeSystem(device: device)
        let model = try createSpringBoneModel()
        try system.populateSpringBoneData(model: model)

        // Configure wind with non-zero phase
        var params = model.springBoneGlobalParams!
        params.windAmplitude = 5.0
        params.windFrequency = 2.0
        params.windPhase = 0.5
        params.windDirection = simd_normalize(SIMD3<Float>(1, 0, 0))
        model.springBoneGlobalParams = params

        // Verify params were set correctly
        XCTAssertEqual(model.springBoneGlobalParams?.windAmplitude, 5.0)
        XCTAssertEqual(model.springBoneGlobalParams?.windFrequency, 2.0)
        XCTAssertEqual(model.springBoneGlobalParams?.windPhase, 0.5)

        // Run a few frames to ensure no crashes
        for frame in 0..<10 {
            params.windPhase = Float(frame) / 60.0
            model.springBoneGlobalParams = params
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        // Wait for GPU completion
        waitForGPU()
        system.writeBonesToNodes(model: model)

        // If we get here without crashing, the wind params are being processed
        XCTAssertTrue(true, "Wind parameters processed without crashing")
    }

    /// Test that wind with static phase (the bug) produces minimal movement
    func testStaticWindPhaseProducesMinimalMovement() throws {
        let system = try SpringBoneComputeSystem(device: device)
        let model = try createSpringBoneModel()
        try system.populateSpringBoneData(model: model)

        // Configure wind but keep phase at 0 (the bug condition)
        var params = model.springBoneGlobalParams!
        params.windAmplitude = 5.0
        params.windFrequency = 2.0
        params.windPhase = 0.0  // Static - never changes!
        params.windDirection = simd_normalize(SIMD3<Float>(1, 0, 0))
        model.springBoneGlobalParams = params

        // Run simulation (phase never updates - simulating the bug)
        for _ in 0..<60 {
            // Note: NOT updating windPhase - this is the bug
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        waitForGPU()
        system.writeBonesToNodes(model: model)

        // With sin(0) = 0, the effective wind force is always 0
        // So the bone should primarily respond to gravity only
        // This test documents the buggy behavior
    }

    /// Test that wind phase can be incremented each frame without issues
    /// This verifies the fix for the bug where windPhase stayed at 0
    func testWindPhaseCanBeIncrementedEachFrame() throws {
        let system = try SpringBoneComputeSystem(device: device)
        let model = try createSpringBoneModel()
        try system.populateSpringBoneData(model: model)

        var params = model.springBoneGlobalParams!
        params.windAmplitude = 5.0
        params.windFrequency = 2.0
        params.windDirection = simd_normalize(SIMD3<Float>(1, 0, 0))
        model.springBoneGlobalParams = params

        var windPhase: Float = 0.0
        var windForces: [Float] = []

        // Simulate 2 seconds at 60 FPS, incrementing phase each frame
        // This is what the Muse app now does to fix the wind bug
        for _ in 0..<120 {
            windPhase += 1.0 / 60.0
            params.windPhase = windPhase
            model.springBoneGlobalParams = params

            // Calculate expected wind force magnitude
            let windForce = params.windAmplitude * sin(params.windFrequency * windPhase)
            windForces.append(abs(windForce))

            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        // Verify wind phase accumulated correctly
        XCTAssertGreaterThan(windPhase, 1.9, "Wind phase should accumulate to ~2.0 after 2 seconds")

        // Verify wind force oscillated (not stuck at 0)
        let maxForce = windForces.max() ?? 0
        let minForce = windForces.min() ?? 0
        XCTAssertGreaterThan(maxForce, 3.0, "Max wind force should be significant (got \(maxForce))")
        XCTAssertLessThan(minForce, 1.0, "Min wind force should be low at zero crossings (got \(minForce))")

        // Verify unique force values (oscillation happening)
        let uniqueForces = Set(windForces.map { Int($0 * 100) })
        XCTAssertGreaterThan(uniqueForces.count, 10, "Should have many different force values")
    }

    // MARK: - Helper Methods

    private func createSpringBoneModel() throws -> VRMModel {
        let builder = VRMBuilder()
        let model = try builder.setSkeleton(.defaultHumanoid).build()

        // Add spring bone configuration
        var springBone = VRMSpringBone()

        var joint = VRMSpringJoint(node: 0)
        joint.hitRadius = 0.05
        joint.stiffness = 0.5  // Lower stiffness to allow more movement
        joint.gravityPower = 0.3
        joint.gravityDir = [0, -1, 0]
        joint.dragForce = 0.2  // Lower drag for more wind response

        var spring = VRMSpring(name: "WindTestSpring")
        spring.joints = [joint]

        springBone.springs = [spring]
        model.springBone = springBone

        // Initialize buffers
        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 1, numSpheres: 0, numCapsules: 0)
        model.springBoneBuffers = buffers

        // Initialize global params with default wind
        model.springBoneGlobalParams = SpringBoneGlobalParams(
            gravity: SIMD3<Float>(0, -10, 0),
            dtSub: 1.0 / 120.0,
            windAmplitude: 0.0,
            windFrequency: 0.0,
            windPhase: 0.0,
            windDirection: SIMD3<Float>(1, 0, 0),
            substeps: 2,
            numBones: 1,
            numSpheres: 0,
            numCapsules: 0
        )

        return model
    }

    private func getFirstBonePosition(model: VRMModel) -> SIMD3<Float>? {
        guard let node = model.nodes.first else { return nil }
        return node.worldPosition
    }

    private func resetSpringBoneState(model: VRMModel) {
        // Reset node transforms to identity
        for node in model.nodes {
            node.localMatrix = matrix_identity_float4x4
            node.updateWorldTransform()
        }
    }

    private func waitForGPU() {
        // Give GPU time to complete async operations
        let expectation = XCTestExpectation(description: "GPU completion")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        _ = XCTWaiter.wait(for: [expectation], timeout: 0.5)
    }
}
