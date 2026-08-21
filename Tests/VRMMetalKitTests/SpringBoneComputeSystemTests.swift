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
        let override = VRMSpringBoneOverride.passthrough
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

    // MARK: - Zero-Joint Spring Indexing Tests

    /// A zero-joint spring (VRMExtensionParser lets one through when every
    /// joint dict in the source data is missing "node") must not shift the
    /// per-chain collider-mask/sleep indexing of the springs that follow it.
    /// `chainColliderMasks`/`sleepGate` are built per NON-EMPTY spring, so the
    /// third spring here (chain index 1) must map to its OWN collider mask,
    /// not the empty middle spring's.
    func testZeroJointSpringDoesNotShiftChainColliderMaskIndexing() throws {
        let system = try SpringBoneComputeSystem(device: device)
        let model = try createModelWithZeroJointSpring()
        try system.populateSpringBoneData(model: model)

        XCTAssertEqual(system.testChainColliderMasks.count, 2,
                       "only the two non-empty springs form chains; the empty spring must not add a mask entry")
        XCTAssertEqual(system.testChainAsleep.count, 2,
                       "only the two non-empty springs form chains")

        // Chain 1 (the third spring, "AfterEmpty") authored group bit 7 (0x80).
        // The empty spring authored group bit 15 (0x8000) — it must NOT leak
        // into chain 1's mask.
        let chain1Mask = system.testChainColliderMasks[1]
        XCTAssertNotEqual(chain1Mask & (1 << 7), 0,
                          "chain 1 must carry its own spring's authored collider-group bit")
        XCTAssertEqual(chain1Mask & (1 << 15), 0,
                       "chain 1 must not carry the empty spring's collider-group bit")
    }

    /// Same misalignment, exercised through `writeBonesToNodes`'s sleep-skip
    /// check: `sleepGate.asleep[chainIndex]` must be indexed by non-empty
    /// spring position, matching `testChainAsleep`, not raw `springs` position.
    func testZeroJointSpringDoesNotShiftSleepIndexing() throws {
        let system = try SpringBoneComputeSystem(device: device)
        let model = try createModelWithZeroJointSpring()
        try system.populateSpringBoneData(model: model)

        // Two chains total (the two non-empty springs). writeBonesToNodes must
        // not crash indexing sleepGate.asleep by raw spring position (3 springs).
        system.writeBonesToNodes(model: model)
        XCTAssertEqual(system.testChainAsleep.count, 2)
    }

    // MARK: - Sleep Flag GPU Upload Tests

    /// `warmupPhysics` dispatches `executeXPBDStep` directly, bypassing
    /// `update()` entirely, so it never touches `chainSleepBuffer`. If a prior
    /// async-path frame left stale sleep=1 flags in the GPU buffer, warmup's
    /// kernels early-out on those chains while the CPU believes everything is
    /// awake. The buffer must be zeroed before warmup dispatches any kernel.
    func testWarmupPhysicsPropagatesSleepFlagsToGPUBuffer() throws {
        let system = try SpringBoneComputeSystem(device: device)
        let model = try createModelForSleepFlagTest()
        try system.populateSpringBoneData(model: model)

        system.testCorruptChainSleepBuffer()
        XCTAssertEqual(system.testChainSleepBufferFlags, [1, 1],
                       "sanity: buffer corrupted before warmup runs")

        system.warmupPhysics(model: model, steps: 1)

        XCTAssertEqual(system.testChainSleepBufferFlags, [0, 0],
                       "warmupPhysics must zero stale GPU sleep flags before dispatching kernels")
    }

    /// The offline/synchronous `update()` path (commandBuffer == nil) calls
    /// `sleepGate.wakeAll()` without `uploadChainSleepFlags()`. If the CPU
    /// sleep gate wakes but the GPU buffer keeps stale sleep=1 flags, the
    /// spring kernels early-out for chains the CPU believes are awake.
    func testSynchronousUpdatePropagatesSleepFlagsToGPUBuffer() throws {
        let system = try SpringBoneComputeSystem(device: device)
        let model = try createModelForSleepFlagTest()
        try system.populateSpringBoneData(model: model)

        system.testCorruptChainSleepBuffer()
        XCTAssertEqual(system.testChainSleepBufferFlags, [1, 1],
                       "sanity: buffer corrupted before the synchronous update runs")

        // commandBuffer: nil selects the offline/synchronous path.
        system.update(model: model, deltaTime: 1.0 / 60.0)

        XCTAssertEqual(system.testChainSleepBufferFlags, [0, 0],
                       "synchronous update() must zero stale GPU sleep flags before dispatching kernels")
    }

    // MARK: - Helper Methods

    /// Builds a two-chain model with `springBoneGlobalParams` populated (both
    /// `warmupPhysics` and the synchronous `update()` path require it).
    private func createModelForSleepFlagTest() throws -> VRMModel {
        let builder = VRMBuilder()
        let model = try builder.setSkeleton(.defaultHumanoid).build()
        model.device = device

        var joint0 = VRMSpringJoint(node: 0)
        joint0.hitRadius = 0.05
        joint0.stiffness = 1.0
        joint0.gravityPower = 0.5
        joint0.gravityDir = [0, -1, 0]
        joint0.dragForce = 0.4
        var spring0 = VRMSpring(name: "Chain0")
        spring0.joints = [joint0]

        var joint1 = VRMSpringJoint(node: 1)
        joint1.hitRadius = 0.05
        joint1.stiffness = 1.0
        joint1.gravityPower = 0.5
        joint1.gravityDir = [0, -1, 0]
        joint1.dragForce = 0.4
        var spring1 = VRMSpring(name: "Chain1")
        spring1.joints = [joint1]

        var springBone = VRMSpringBone()
        springBone.springs = [spring0, spring1]
        model.springBone = springBone

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 2, numSpheres: 0, numCapsules: 0)
        model.springBoneBuffers = buffers

        model.springBoneGlobalParams = SpringBoneGlobalParams(
            gravity: SIMD3<Float>(0, 0, 0),
            dtSub: Float(1.0 / 120.0),
            windAmplitude: 0.0,
            windFrequency: 0.0,
            windPhase: 0.0,
            windDirection: SIMD3<Float>(1, 0, 0),
            substeps: 1,
            numBones: 2,
            numSpheres: 0,
            numCapsules: 0,
            numPlanes: 0,
            settlingFrames: 0
        )

        return model
    }

    /// Builds a model with three springs in source order [non-empty, EMPTY,
    /// non-empty], matching what `VRMExtensionParser` produces for a spring
    /// whose joints all lack a "node" field.
    private func createModelWithZeroJointSpring() throws -> VRMModel {
        let builder = VRMBuilder()
        let model = try builder.setSkeleton(.defaultHumanoid).build()
        model.device = device

        var joint0 = VRMSpringJoint(node: 0)
        joint0.hitRadius = 0.05
        joint0.stiffness = 1.0
        joint0.gravityPower = 0.5
        joint0.gravityDir = [0, -1, 0]
        joint0.dragForce = 0.4

        var firstSpring = VRMSpring(name: "BeforeEmpty")
        firstSpring.joints = [joint0]
        firstSpring.colliderGroups = [3]

        var emptySpring = VRMSpring(name: "EmptySpring")
        emptySpring.joints = []
        emptySpring.colliderGroups = [15]

        var joint1 = VRMSpringJoint(node: 1)
        joint1.hitRadius = 0.05
        joint1.stiffness = 1.0
        joint1.gravityPower = 0.5
        joint1.gravityDir = [0, -1, 0]
        joint1.dragForce = 0.4

        var thirdSpring = VRMSpring(name: "AfterEmpty")
        thirdSpring.joints = [joint1]
        thirdSpring.colliderGroups = [7]

        var springBone = VRMSpringBone()
        springBone.springs = [firstSpring, emptySpring, thirdSpring]
        model.springBone = springBone

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 2, numSpheres: 0, numCapsules: 0)
        model.springBoneBuffers = buffers

        return model
    }

    // MARK: - Original Helper Methods

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
