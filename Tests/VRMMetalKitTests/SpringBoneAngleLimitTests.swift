// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Functional tests for `VRMC_springBone_extended_collider.angleLimit`.
///
/// The angle-limit clamp lives in `SpringBonePredict.metal` (lines ~255-283).
/// It restricts a joint's swing direction to a cone of half-angle
/// `angleLimit` (in radians) around the bind direction. The
/// `BoneParamsLayoutTests` verify the field is plumbed through to the GPU
/// struct, but no existing test exercises the clamp's *functional*
/// behavior — the test-suite review called this a P2 gap (the
/// conformance fixtures only round-trip it as opaque render bundles).
///
/// These tests drive a single hanging joint with a strong lateral
/// gravity vector and verify:
///   * with `angleLimit = 0` (sentinel "no limit"), the joint swings
///     well past the cone we'll test against, establishing the negative
///     case;
///   * with `angleLimit = 30°`, the joint's swing angle from the bind
///     direction stays within the cone (modulo a small tolerance for
///     PBD overshoot and root interpolation).
///
/// Determinism: per-frame host-owned `MTLCommandBuffer.waitUntilCompleted()`.
final class SpringBoneAngleLimitTests: XCTestCase {

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

    // MARK: - Tests

    /// Sanity case: with no angle limit the joint must swing past the
    /// 30° cone under lateral gravity. If this fails the test geometry
    /// is too weak and the positive case (next test) would be vacuous.
    func testNoAngleLimitJointSwingsPastConeUnderLateralForce() throws {
        let model = try makeAngleLimitModel(angleLimitRadians: 0.0)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        try SpringBoneTestFixtures.runFrames(180, system: system, model: model,
                                             commandQueue: commandQueue)

        let angle = settledJointAngleFromBindDirection(model: model)
        let coneRadians = Float.pi / 6  // 30°
        XCTAssertGreaterThan(angle, coneRadians,
            "Unbounded joint must swing past the 30° cone under lateral " +
            "gravity for the angle-limit test to be meaningful. " +
            "Got angle=\(angle) rad (\(angle * 180 / .pi)°), expected > " +
            "\(coneRadians) rad. Adjust the test fixture forces if this " +
            "fails.")
    }

    /// Positive case: with `angleLimit = 30°`, the joint's swing angle
    /// from the bind direction must stay within the cone under the same
    /// lateral force that caused the unbounded version to overshoot.
    func test30DegreeAngleLimitConstrainsJointSwing() throws {
        let coneRadians = Float.pi / 6  // 30°
        let model = try makeAngleLimitModel(angleLimitRadians: coneRadians)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        try SpringBoneTestFixtures.runFrames(180, system: system, model: model,
                                             commandQueue: commandQueue)

        let angle = settledJointAngleFromBindDirection(model: model)
        // PBD allows small per-substep overshoot before the next clamp.
        // 5° tolerance is comfortable.
        let tolerance: Float = 5.0 * .pi / 180.0

        XCTAssertLessThanOrEqual(angle, coneRadians + tolerance,
            "Joint swing angle must be clamped within the 30° cone " +
            "(±5° tolerance). Got angle=\(angle) rad " +
            "(\(angle * 180 / .pi)°), expected ≤ " +
            "\(coneRadians + tolerance) rad. The angle-limit clamp in " +
            "SpringBonePredict.metal appears not to be enforcing the cone.")

        SpringBoneTestFixtures.assertNoNaNPositions(model: model)
    }

    /// A tighter cone (10°) must produce a tighter swing than the looser
    /// cone (60°) under the same force. This is a relative assertion
    /// that's robust to the absolute clamp-precision of the kernel:
    /// even if both runs overshoot a little, the smaller cone must
    /// confine the joint more.
    func testTighterAngleLimitProducesTighterSwingThanLooser() throws {
        let tightModel = try makeAngleLimitModel(angleLimitRadians: 10.0 * .pi / 180.0)
        let looseModel = try makeAngleLimitModel(angleLimitRadians: 60.0 * .pi / 180.0)

        let tightSys = try SpringBoneComputeSystem(device: device)
        try tightSys.populateSpringBoneData(model: tightModel)
        let looseSys = try SpringBoneComputeSystem(device: device)
        try looseSys.populateSpringBoneData(model: looseModel)

        try SpringBoneTestFixtures.runFrames(180, system: tightSys,
                                             model: tightModel,
                                             commandQueue: commandQueue)
        try SpringBoneTestFixtures.runFrames(180, system: looseSys,
                                             model: looseModel,
                                             commandQueue: commandQueue)

        let tightAngle = settledJointAngleFromBindDirection(model: tightModel)
        let looseAngle = settledJointAngleFromBindDirection(model: looseModel)

        XCTAssertLessThan(tightAngle, looseAngle - 0.1,
            "A 10° cone must produce a noticeably tighter swing than a 60° " +
            "cone under identical lateral force. Got tight=\(tightAngle) rad " +
            "(\(tightAngle * 180 / .pi)°), loose=\(looseAngle) rad " +
            "(\(looseAngle * 180 / .pi)°). Difference must be > 0.1 rad " +
            "(~5.7°) — anything less indicates the angle-limit term is not " +
            "scaling with `angleLimit`.")
    }

    // MARK: - Helpers

    /// Build a 2-bone chain with a configurable per-joint `angleLimit`.
    /// Root anchored at `(0, 1, 0)`, joint hanging at `(0, 0, 0)`.
    /// Strong gravity in the `+X` direction tries to swing the joint
    /// out laterally; the angle-limit clamp must keep it within the cone.
    private func makeAngleLimitModel(angleLimitRadians: Float) throws -> VRMModel {
        let model = try SpringBoneTestFixtures.makeChainModel(
            device: device,
            names: ["anchor", "joint"],
            translations: [SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, -1, 0)]
        )

        // Root anchor (no gravity, no stiffness — driven by animation).
        var anchor = SpringBoneTestFixtures.defaultJoint(node: 0)
        anchor.stiffness = 0.0
        anchor.gravityPower = 0.0
        anchor.dragForce = 0.4

        // Physics joint with strong lateral gravity.
        var phys = SpringBoneTestFixtures.defaultJoint(node: 1)
        phys.stiffness = 0.0           // no restoring force — only the cone clamps
        phys.gravityPower = 5.0
        // Mostly horizontal so the joint wants to swing well past any cone.
        phys.gravityDir = simd_normalize(SIMD3<Float>(1, -0.1, 0))
        phys.dragForce = 0.4
        phys.angleLimit = angleLimitRadians

        var spring = VRMSpring(name: "AngleLimitSpring")
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

    /// Angle (in radians) between the joint's current direction-from-parent
    /// and the bind direction the kernel uses (which is the root-to-joint
    /// vector in the rest pose: `(0, -1, 0)` for our setup).
    private func settledJointAngleFromBindDirection(model: VRMModel) -> Float {
        let root = SpringBoneTestFixtures.readBonePosition(model: model, boneIndex: 0)
        let joint = SpringBoneTestFixtures.readBonePosition(model: model, boneIndex: 1)
        let toJoint = simd_normalize(joint - root)
        let bindDir = SIMD3<Float>(0, -1, 0)
        let cosTheta = simd_dot(toJoint, bindDir)
        // Clamp for acos numerical safety.
        let clamped = max(-1.0, min(1.0, cosTheta))
        return acos(clamped)
    }
}
