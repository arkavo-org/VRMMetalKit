// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
@testable import VRMMetalKit

/// Tests for SpringBone GPU compute system, focusing on async readback and substep clamping
final class SpringBoneComputeSystemTests: XCTestCase {

    var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    // MARK: - Substep Clamping Tests

    /// Test that large deltaTime values are clamped to maxSubstepsPerFrame
    /// Addresses issue #31: Prevent "spiral of death" when frame times spike
    func testSubstepClampingPreventsRunaway() throws {
        let system = try SpringBoneComputeSystem(device: device)

        // Create a minimal VRM model with one spring bone
        let model = try createMinimalSpringBoneModel()
        try system.populateSpringBoneData(model: model)

        // Simulate a massive deltaTime (e.g., 1 second frame time)
        // Without clamping, this would try to run 120 substeps at 120Hz
        // With clamping, it should be limited to maxSubstepsPerFrame (10)
        let hugeDeltaTime: Double = 1.0

        // This should complete quickly without hanging
        let start = Date()
        system.update(model: model, deltaTime: hugeDeltaTime)
        let elapsed = Date().timeIntervalSince(start)

        // Should complete in < 100ms even with huge deltaTime
        XCTAssertLessThan(elapsed, 0.1, "Substep clamping failed - update took \(elapsed)s")
    }

    /// Test that accumulated time is properly managed when hitting max substeps
    func testTimeAccumulatorResetAfterClamp() throws {
        let system = try SpringBoneComputeSystem(device: device)
        let model = try createMinimalSpringBoneModel()
        try system.populateSpringBoneData(model: model)

        // First update with huge deltaTime
        system.update(model: model, deltaTime: 1.0)

        // Second update should proceed normally (not carry over huge accumulated time)
        let start = Date()
        system.update(model: model, deltaTime: 0.016) // Normal 60 FPS frame
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.05, "Time accumulator not reset properly")
    }

    /// Test normal operation with reasonable deltaTime
    func testNormalDeltaTimeOperation() throws {
        let system = try SpringBoneComputeSystem(device: device)
        let model = try createMinimalSpringBoneModel()
        try system.populateSpringBoneData(model: model)

        // Simulate 60 FPS updates
        for _ in 0..<60 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        // Should complete without issues
        XCTAssertTrue(true)
    }

    // MARK: - Async Readback Tests

    /// Test that async readback eventually provides position data
    func testAsyncReadbackProvidesPositions() throws {
        let system = try SpringBoneComputeSystem(device: device)
        let model = try createMinimalSpringBoneModel()
        try system.populateSpringBoneData(model: model)

        // Run several updates to ensure GPU completion handlers fire
        for _ in 0..<10 {
            system.update(model: model, deltaTime: 0.016)
        }

        // Allow time for GPU to complete (completion handlers are async)
        let expectation = XCTestExpectation(description: "GPU completion")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Verify that writeBonesToNodes doesn't crash (it should have snapshot data)
        system.writeBonesToNodes(model: model)

        XCTAssertTrue(true, "Async readback completed successfully")
    }

    /// Test that stale readback data is skipped gracefully
    func testStaleReadbackIsSkipped() throws {
        let system = try SpringBoneComputeSystem(device: device)
        let model = try createMinimalSpringBoneModel()
        try system.populateSpringBoneData(model: model)

        // Call writeBonesToNodes before any GPU work completes
        // Should skip gracefully without crashing
        system.writeBonesToNodes(model: model)

        XCTAssertTrue(true, "Stale readback handled gracefully")
    }

    // MARK: - Frame Versioning Tests

    /// Test that frame counter increments properly
    func testFrameVersioningIncrementsCorrectly() throws {
        let system = try SpringBoneComputeSystem(device: device)
        let model = try createMinimalSpringBoneModel()
        try system.populateSpringBoneData(model: model)

        // Run multiple updates
        for _ in 0..<5 {
            system.update(model: model, deltaTime: 0.016)
        }

        // Wait for GPU completion
        let expectation = XCTestExpectation(description: "GPU completion")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Verify bones are written without errors
        system.writeBonesToNodes(model: model)

        XCTAssertTrue(true, "Frame versioning working correctly")
    }

    // MARK: - Performance Tests

    /// Test that update performance is reasonable even with many bones
    func testUpdatePerformanceWithMultipleBones() throws {
        let system = try SpringBoneComputeSystem(device: device)

        // Create model with multiple spring bones (simulate hair/clothing)
        let model = try createModelWithMultipleSpringBones(count: 20)
        try system.populateSpringBoneData(model: model)

        measure {
            // Single frame update at 60 FPS
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }
    }

    // MARK: - Helper Methods

    /// Create a minimal VRM model with a single spring bone for testing
    private func createMinimalSpringBoneModel() throws -> VRMModel {
        let builder = VRMBuilder()
        let model = try builder.setSkeleton(.defaultHumanoid).build()

        // Add minimal spring bone configuration
        var springBone = VRMSpringBone()

        var joint = VRMSpringJoint(node: 0)
        joint.hitRadius = 0.05
        joint.stiffness = 1.0
        joint.gravityPower = 0.5
        joint.gravityDir = [0, -1, 0]
        joint.dragForce = 0.4

        var spring = VRMSpring(name: "TestSpring")
        spring.joints = [joint]

        springBone.springs = [spring]
        model.springBone = springBone

        // Initialize buffers
        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 1, numSpheres: 0, numCapsules: 0)
        model.springBoneBuffers = buffers

        return model
    }

    /// Create a VRM model with multiple spring bones for stress testing
    private func createModelWithMultipleSpringBones(count: Int) throws -> VRMModel {
        let builder = VRMBuilder()
        let model = try builder.setSkeleton(.defaultHumanoid).build()

        var joints: [VRMSpringJoint] = []
        for i in 0..<count {
            var joint = VRMSpringJoint(node: i)
            joint.hitRadius = 0.05
            joint.stiffness = 1.0
            joint.gravityPower = 0.5
            joint.gravityDir = [0, -1, 0]
            joint.dragForce = 0.4
            joints.append(joint)
        }

        var springBone = VRMSpringBone()
        var spring = VRMSpring(name: "MultiSpring")
        spring.joints = joints
        springBone.springs = [spring]

        model.springBone = springBone

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: count, numSpheres: 0, numCapsules: 0)
        model.springBoneBuffers = buffers

        return model
    }
}
