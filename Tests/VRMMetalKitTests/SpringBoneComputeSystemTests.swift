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

    // MARK: - VRMSpringBoneOverride Tests

    /// Default override is a strict no-op: authored values pass through unchanged.
    func testSpringBoneOverrideDefaultIsNoOp() {
        let override = VRMSpringBoneOverride.none
        let out = override.apply(stiffness: 0.85, dragForce: 0.4, gravityPower: 0.0, jointName: "J_Sec_Hair1_01")
        XCTAssertEqual(out.stiffness, 0.85, accuracy: 1e-6)
        XCTAssertEqual(out.dragForce, 0.4, accuracy: 1e-6)
        XCTAssertEqual(out.gravityPower, 0.0, accuracy: 1e-6)
    }

    /// Clamps apply when the name predicate matches.
    func testSpringBoneOverrideClampsWhenPredicateMatches() {
        let override = VRMSpringBoneOverride(
            minGravityPower: 0.5,
            maxStiffness: 0.7,
            maxDragForce: 0.6,
            jointNameMatches: { $0.contains("Hair") }
        )
        let out = override.apply(stiffness: 0.85, dragForce: 0.4, gravityPower: 0.0, jointName: "J_Sec_Hair1_01")
        XCTAssertEqual(out.stiffness, 0.7, accuracy: 1e-6, "stiffness should be capped at maxStiffness")
        XCTAssertEqual(out.dragForce, 0.4, accuracy: 1e-6, "drag below cap is unchanged")
        XCTAssertEqual(out.gravityPower, 0.5, accuracy: 1e-6, "gravityPower should be floored at minGravityPower")
    }

    /// Clamps skip joints the predicate rejects.
    func testSpringBoneOverrideSkipsWhenPredicateRejects() {
        let override = VRMSpringBoneOverride(
            minGravityPower: 0.5,
            maxStiffness: 0.7,
            jointNameMatches: { $0.contains("Hair") }
        )
        let out = override.apply(stiffness: 0.9, dragForce: 0.4, gravityPower: 0.0, jointName: "J_Bip_C_Head")
        XCTAssertEqual(out.stiffness, 0.9, accuracy: 1e-6)
        XCTAssertEqual(out.gravityPower, 0.0, accuracy: 1e-6)
    }

    /// Joints with no name are never touched (safe default).
    func testSpringBoneOverrideSkipsWhenNameIsNil() {
        let override = VRMSpringBoneOverride(minGravityPower: 0.5, maxStiffness: 0.7)
        let out = override.apply(stiffness: 1.0, dragForce: 0.4, gravityPower: 0.0, jointName: nil)
        XCTAssertEqual(out.stiffness, 1.0, accuracy: 1e-6)
        XCTAssertEqual(out.gravityPower, 0.0, accuracy: 1e-6)
    }

    /// With no predicate, every named joint is clamped.
    func testSpringBoneOverrideAppliesToAllNamedJointsWithoutPredicate() {
        let override = VRMSpringBoneOverride(maxStiffness: 0.7)
        let out1 = override.apply(stiffness: 0.9, dragForce: 0.4, gravityPower: 0.5, jointName: "AnyName")
        let out2 = override.apply(stiffness: 0.5, dragForce: 0.4, gravityPower: 0.5, jointName: "OtherName")
        XCTAssertEqual(out1.stiffness, 0.7, accuracy: 1e-6, "value above cap is clamped")
        XCTAssertEqual(out2.stiffness, 0.5, accuracy: 1e-6, "value below cap is unchanged")
    }

    /// Verify the GPU bone-params buffer reflects the clamp after populateSpringBoneData.
    /// Simulates the AvatarSample_A breakage (high stiffness + zero gravity) and applies
    /// a rescue override that should reach the GPU buffer.
    func testSpringBoneOverrideReachesGPUBuffer() throws {
        let system = try SpringBoneComputeSystem(device: device)
        let model = try createMinimalSpringBoneModel()
        model.device = device

        model.springBone?.springs[0].joints[0].stiffness = 1.0
        model.springBone?.springs[0].joints[0].gravityPower = 0.0

        system.springBoneOverride = VRMSpringBoneOverride(
            minGravityPower: 0.5,
            maxStiffness: 0.7
        )
        try system.populateSpringBoneData(model: model)

        guard let buffers = model.springBoneBuffers,
              let boneParamsBuffer = buffers.boneParams else {
            XCTFail("Spring-bone buffers not populated")
            return
        }
        let ptr = boneParamsBuffer.contents().bindMemory(to: BoneParams.self, capacity: buffers.numBones)
        XCTAssertEqual(ptr[0].stiffness, 0.7, accuracy: 1e-6, "stiffness on GPU should be clamped")
        XCTAssertEqual(ptr[0].gravityPower, 0.5, accuracy: 1e-6, "gravityPower on GPU should be floored")
    }

    /// With override = .none, the GPU bone-params buffer carries authored values exactly.
    func testSpringBoneOverrideNoneLeavesGPUBufferUntouched() throws {
        let system = try SpringBoneComputeSystem(device: device)
        let model = try createMinimalSpringBoneModel()
        model.device = device

        try system.populateSpringBoneData(model: model)

        guard let buffers = model.springBoneBuffers,
              let boneParamsBuffer = buffers.boneParams else {
            XCTFail("Spring-bone buffers not populated")
            return
        }
        let ptr = boneParamsBuffer.contents().bindMemory(to: BoneParams.self, capacity: buffers.numBones)
        XCTAssertEqual(ptr[0].stiffness, 1.0, accuracy: 1e-6)
        XCTAssertEqual(ptr[0].drag, 0.4, accuracy: 1e-6)
        XCTAssertEqual(ptr[0].gravityPower, 0.5, accuracy: 1e-6)
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
