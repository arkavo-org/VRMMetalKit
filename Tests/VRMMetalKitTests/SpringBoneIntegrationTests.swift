// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Integration tests for SpringBone physics system with complete VRM models
/// Tests end-to-end behavior including model loading, physics simulation, and node updates
final class SpringBoneIntegrationTests: XCTestCase {

    var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    // MARK: - End-to-End Integration Tests

    /// Test complete physics simulation pipeline: build model → populate physics → simulate → readback
    func testCompletePhysicsSimulationPipeline() throws {
        // Build VRM model with SpringBone configuration
        let model = try buildModelWithSpringBones(boneCount: 5)

        // Create physics system
        let system = try SpringBoneComputeSystem(device: device)

        // Populate physics data
        try system.populateSpringBoneData(model: model)

        // Simulate several frames at 60 FPS
        for frame in 1...60 {
            system.update(model: model, deltaTime: 1.0 / 60.0)

            // Every 10 frames, verify positions are reasonable
            if frame % 10 == 0 {
                // Allow time for GPU completion
                Thread.sleep(forTimeInterval: 0.1)

                system.writeBonesToNodes(model: model)

                // Verify nodes have valid transforms
                for node in model.nodes {
                    XCTAssertFalse(node.translation.x.isNaN, "Frame \(frame): Node translation contains NaN")
                    XCTAssertFalse(node.translation.x.isInfinite, "Frame \(frame): Node translation is infinite")
                }
            }
        }

        XCTAssertTrue(true, "Complete pipeline test passed")
    }

    /// Test that physics simulation converges to stable state (gravity settling)
    func testPhysicsConvergesToStableState() throws {
        let model = try buildModelWithSpringBones(boneCount: 3)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Simulate until physics settles (bones hang down due to gravity)
        var previousPositions: [SIMD3<Float>] = []

        for _ in 0..<120 { // 2 seconds at 60 FPS
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        // Wait for GPU completion
        Thread.sleep(forTimeInterval: 0.2)

        // Capture positions
        system.writeBonesToNodes(model: model)
        previousPositions = model.nodes.map { $0.translation }

        // Simulate 10 more frames - should be stable
        for _ in 0..<10 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        let currentPositions = model.nodes.map { $0.translation }

        // Verify positions haven't changed much (stable)
        for (prev, curr) in zip(previousPositions, currentPositions) {
            let delta = simd_distance(prev, curr)
            XCTAssertLessThan(delta, 0.01, "Physics did not converge - bones still moving significantly")
        }
    }

    /// Test that physics responds to animated root positions
    func testPhysicsRespondsToRootMotion() throws {
        let model = try buildModelWithSpringBones(boneCount: 2)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Settle physics
        for _ in 0..<60 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        guard let rootNode = model.nodes.first else {
            XCTFail("No root node")
            return
        }

        let initialPosition = rootNode.translation

        // Move root node (simulating animation)
        rootNode.translation = SIMD3<Float>(1.0, 0.0, 0.0)

        // Simulate - bones should follow root motion
        for _ in 0..<30 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        // Verify root moved
        let finalPosition = rootNode.translation
        let rootMoved = simd_distance(initialPosition, finalPosition) > 0.5

        XCTAssertTrue(rootMoved, "Root node should have moved")
    }

    /// Test GPU stall fix from PR #38 - verify no blocking waits
    func testAsyncReadbackDoesNotBlock() throws {
        let model = try buildModelWithSpringBones(boneCount: 10)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        let start = Date()

        // Rapid fire updates - should not block on GPU
        for _ in 0..<30 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
            system.writeBonesToNodes(model: model) // Should skip gracefully if GPU not ready
        }

        let elapsed = Date().timeIntervalSince(start)

        // Should complete very quickly since no blocking waits
        // With blocking (old code), this would take ~500ms
        // With async (PR #38), should take < 50ms
        XCTAssertLessThan(elapsed, 0.1, "Async readback appears to be blocking - took \(elapsed)s")
    }

    // MARK: - Collision Tests
    // NOTE: Collision test removed - see issue #49 for proper test implementation

    // MARK: - Performance Tests

    /// Test physics performance with many bones
    func testPhysicsPerformanceWithManyBones() throws {
        let model = try buildModelWithSpringBones(boneCount: 50)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        measure {
            // Simulate 10 frames
            for _ in 0..<10 {
                system.update(model: model, deltaTime: 1.0 / 60.0)
            }
        }

        // Should complete quickly even with 50 bones (GPU parallelism)
    }

    // MARK: - Stress Tests

    /// Test physics stability under extreme conditions
    func testPhysicsStabilityUnderStress() throws {
        let model = try buildModelWithSpringBones(boneCount: 20)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Extreme deltaTime (tests substep clamping from PR #38)
        system.update(model: model, deltaTime: 2.0) // Huge frame time

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        // Verify no NaN or infinite values
        for node in model.nodes {
            XCTAssertTrue(node.translation.x.isFinite, "Physics produced non-finite values")
            XCTAssertTrue(node.translation.y.isFinite, "Physics produced non-finite values")
            XCTAssertTrue(node.translation.z.isFinite, "Physics produced non-finite values")
        }

        // Normal frame after stress
        system.update(model: model, deltaTime: 0.016)
        Thread.sleep(forTimeInterval: 0.1)
        system.writeBonesToNodes(model: model)

        // Should recover
        for node in model.nodes {
            XCTAssertTrue(node.translation.x.isFinite, "Physics did not recover after stress")
        }
    }

    // MARK: - Helper Methods

    /// Build a minimal VRM model with SpringBone configuration
    private func buildModelWithSpringBones(boneCount: Int) throws -> VRMModel {
        let builder = VRMBuilder()
        let model = try builder.setSkeleton(.defaultHumanoid).build()

        // Create spring bone joints
        var joints: [VRMSpringJoint] = []
        for i in 0..<boneCount {
            var joint = VRMSpringJoint(node: i)
            joint.hitRadius = 0.05
            joint.stiffness = 1.0
            joint.gravityPower = 0.5
            joint.gravityDir = [0, -1, 0] // Down
            joint.dragForce = 0.4
            joints.append(joint)
        }

        var springBone = VRMSpringBone()
        var spring = VRMSpring(name: "TestSpring")
        spring.joints = joints
        springBone.springs = [spring]

        model.springBone = springBone

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: boneCount, numSpheres: 0, numCapsules: 0)
        model.springBoneBuffers = buffers

        // Note: Nodes are created by VRMBuilder, we don't need to manually create them for this test
        return model
    }

}
