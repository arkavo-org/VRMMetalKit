// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Verifies that spring-bone gravity is applied at the VRM spec scale (#324):
/// `external = gravityDir · gravityPower · dt`, with `gravityPower` the strength
/// directly — matching UniVRM (both 0.x and 1.0 paths), three-vrm, and godot-vrm.
///
/// The pre-#324 implementation multiplied `gravityPower` by
/// `length(globalParams.gravity)` (= 9.8, Earth gravity) plus an up-to-5×
/// settling boost, over-driving gravity ~9.8× relative to every other renderer.
final class SpringBoneGravityScaleTests: XCTestCase {

    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Could not create Metal command queue")
        }
        self.device = device
        self.commandQueue = queue
    }

    /// Build a vertical chain (hanging −Y) with sideways gravity so the first
    /// physics step bends the chain measurably. Long bones (1 m) keep the tiny
    /// first-step move well inside the rest length, so the distance constraint
    /// is a negligible correction and the measured sideways displacement is the
    /// clean gravity signal.
    private func buildSidewaysGravityChain(
        boneCount: Int,
        gravityPower: Float
    ) throws -> VRMModel {
        let boneLength: Float = 1.0
        let model = try SpringBoneTestFixtures.makeVerticalChain(
            device: device,
            boneCount: boneCount,
            boneLength: boneLength,
            rootY: Float(boneCount)
        )

        var joints: [VRMSpringJoint] = []
        for i in 0..<boneCount {
            var joint = VRMSpringJoint(node: i)
            joint.hitRadius = 0.02
            joint.stiffness = 0.0                       // isolate gravity from bind-pose pull
            joint.gravityPower = gravityPower
            joint.gravityDir = SIMD3<Float>(1, 0, 0)    // sideways: bends the vertical chain
            joint.dragForce = 0.0
            joints.append(joint)
        }
        var spring = VRMSpring(name: "SidewaysGravityChain")
        spring.joints = joints
        var springBone = VRMSpringBone()
        springBone.springs = [spring]
        model.springBone = springBone

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: boneCount, numSpheres: 0, numCapsules: 0)
        model.springBoneBuffers = buffers

        // settlingFrames = 0 → settling boost is inert, so the only scale under
        // test is the gravity term itself. We deliberately ship the historical
        // Earth-gravity vector [0,−9.8,0] (now an additive external force in the
        // −Y channel): the *sideways* (X) response must come solely from
        // per-joint gravityPower at spec scale, regardless of that vector. The
        // pre-#324 code folded its 9.8 magnitude into the X response; the spec
        // code must not. X is measured; the −Y external force does not touch it.
        model.springBoneGlobalParams = SpringBoneTestFixtures.defaultGlobalParams(
            numBones: boneCount,
            gravity: SIMD3<Float>(0, -9.8, 0)
        )
        return model
    }

    /// Acceptance (#324): per-step sideways displacement matches
    /// `gravityPower · dtSub` (spec scale), NOT 9.8× that.
    func testFirstStepGravityMatchesSpecScale() throws {
        let boneCount = 4
        let gravityPower: Float = 0.5
        let dtSub: Float = 1.0 / 120.0

        let model = try buildSidewaysGravityChain(boneCount: boneCount, gravityPower: gravityPower)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        let tip = boneCount - 1
        let initialX = SpringBoneTestFixtures.readBonePosition(model: model, boneIndex: tip).x

        // Exactly one 120 Hz substep.
        try SpringBoneTestFixtures.runFrame(
            system: system, model: model, commandQueue: commandQueue, deltaTime: 1.0 / 120.0)

        let tipX = SpringBoneTestFixtures.readBonePosition(model: model, boneIndex: tip).x
        let displacement = tipX - initialX

        let expected = gravityPower * dtSub               // spec: 0.5/120 ≈ 0.004167 m
        let nonSpec9p8 = 9.8 * gravityPower * dtSub        // pre-#324: ≈ 0.0408 m

        // Within 25% of the spec value — comfortably excludes the 9.8× value.
        XCTAssertEqual(
            displacement, expected, accuracy: expected * 0.25,
            "First-step sideways displacement \(displacement) m should match spec scale " +
            "gravityPower·dtSub = \(expected) m (UniVRM/three-vrm/godot), not the Earth-gravity " +
            "value \(nonSpec9p8) m.")
    }

    /// gravityPower must scale gravity linearly (doubling power doubles the
    /// per-step displacement), with no Earth-gravity constant folded in.
    func testGravityScalesLinearlyWithPower() throws {
        let dtSub: Float = 1.0 / 120.0
        let tip = 3

        func firstStepDisplacement(gravityPower: Float) throws -> Float {
            let model = try buildSidewaysGravityChain(boneCount: 4, gravityPower: gravityPower)
            let system = try SpringBoneComputeSystem(device: device)
            try system.populateSpringBoneData(model: model)
            let initialX = SpringBoneTestFixtures.readBonePosition(model: model, boneIndex: tip).x
            try SpringBoneTestFixtures.runFrame(
                system: system, model: model, commandQueue: commandQueue, deltaTime: 1.0 / 120.0)
            return SpringBoneTestFixtures.readBonePosition(model: model, boneIndex: tip).x - initialX
        }

        let half = try firstStepDisplacement(gravityPower: 0.5)
        let full = try firstStepDisplacement(gravityPower: 1.0)

        XCTAssertEqual(full, 2 * half, accuracy: half * 0.1,
            "Doubling gravityPower should double per-step displacement (\(half) → \(full)).")
        XCTAssertEqual(full, 1.0 * dtSub, accuracy: 1.0 * dtSub * 0.25,
            "gravityPower=1.0 should give dtSub (\(dtSub) m) of sideways move per substep, " +
            "not 9.8× that.")
    }
}
