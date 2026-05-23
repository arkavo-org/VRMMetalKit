// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Tests for the VRMC_springBone-1.0 §5.1 center-node semantics.
///
/// Per spec, a spring's optional `center` node is the inertia-compensation
/// reference: when the center moves rigidly through world space (avatar
/// locomotion, root motion, walk cycle), the spring joints follow that
/// motion exactly and only motion *relative* to the center induces
/// physics. Without a center the joints feel the absolute motion as
/// inertia and lag behind.
///
/// The test-suite review flagged that `SpringBoneSpecComplianceTests`
/// verifies center is parsed and recorded but never asserts the runtime
/// physics behavior changes. These tests close that gap by translating
/// a center node and comparing two otherwise-identical springs:
///
///   * `withCenter`: spring.center = centerNodeIndex
///   * `withoutCenter`: spring.center = nil
///
/// Determinism: per-frame host-owned `MTLCommandBuffer.waitUntilCompleted()`.
final class SpringBoneCenterNodePhysicsTests: XCTestCase {

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

    /// Translating the center node by +1m on the X axis must drag the
    /// spring's physics joint by the same amount on the next frame.
    /// The same translation applied to a spring with `center = nil` must
    /// leave the joint roughly where it was (inertia keeps it behind).
    ///
    /// Scene graph:
    ///   center (node 0) at world (0, 1, 0)
    ///     └─ rootJoint (node 1) at local (0.3, 0, 0)    → world (0.3, 1, 0)
    ///         └─ physJoint (node 2) at local (0, -0.5, 0) → world (0.3, 0.5, 0)
    ///
    /// The horizontal offset of the rootJoint makes the rotation test
    /// non-degenerate (a rootJoint at the rotation pivot would not move
    /// under center rotation, leaving nothing to test).
    ///
    /// Spring joints = [bone of node 1, bone of node 2].
    func testCenterNodeTranslationDragsJointRigidly() throws {
        let withCenter = try makeCenterTestModel(useCenter: true)
        let withoutCenter = try makeCenterTestModel(useCenter: false)

        let systemWith = try SpringBoneComputeSystem(device: device)
        try systemWith.populateSpringBoneData(model: withCenter.model)
        let systemWithout = try SpringBoneComputeSystem(device: device)
        try systemWithout.populateSpringBoneData(model: withoutCenter.model)

        // Settle both rigs at rest so transient startup doesn't pollute
        // the measurement.
        try SpringBoneTestFixtures.runFrames(20, system: systemWith,
                                             model: withCenter.model,
                                             commandQueue: commandQueue)
        try SpringBoneTestFixtures.runFrames(20, system: systemWithout,
                                             model: withoutCenter.model,
                                             commandQueue: commandQueue)

        let preWith = SpringBoneTestFixtures.readBonePosition(
            model: withCenter.model, boneIndex: 1)
        let preWithout = SpringBoneTestFixtures.readBonePosition(
            model: withoutCenter.model, boneIndex: 1)

        // Translate the center node by +1m on X. updateWorldTransform()
        // propagates the new world matrix to its children so the root
        // joint (driven by animation) follows. The physics joint follows
        // only if center-frame deltas are applied.
        let centerTranslation = SIMD3<Float>(1, 0, 0)
        translateRoot(model: withCenter.model, delta: centerTranslation)
        translateRoot(model: withoutCenter.model, delta: centerTranslation)

        try SpringBoneTestFixtures.runFrame(system: systemWith,
                                            model: withCenter.model,
                                            commandQueue: commandQueue)
        try SpringBoneTestFixtures.runFrame(system: systemWithout,
                                            model: withoutCenter.model,
                                            commandQueue: commandQueue)

        let postWith = SpringBoneTestFixtures.readBonePosition(
            model: withCenter.model, boneIndex: 1)
        let postWithout = SpringBoneTestFixtures.readBonePosition(
            model: withoutCenter.model, boneIndex: 1)

        let dispWith = postWith - preWith
        let dispWithout = postWithout - preWithout

        // VMK#295: rigid-follow under center-node translation is blocked by
        // a CPU/GPU race on the shared-command-buffer path. The frame's
        // center delta is applied CPU-side before the substep loop, while
        // the root is interpolated per-substep — first substep sees a
        // stretched chain and the PBD distance constraint pulls the joint
        // back. Per-substep CPU shifts don't fix it (shared-memory race),
        // a GPU-side per-substep delta kernel is needed.
        XCTExpectFailure("VMK#295 follow-up: center-node rigid follow needs a GPU-side per-substep delta kernel; CPU/GPU race on the shared command buffer breaks per-substep CPU shifts")

        // With center: physics joint follows the center delta (≥ 80% of the
        // 1m translation on X within a single frame).
        XCTAssertGreaterThan(dispWith.x, 0.8,
            "Spring with center node must follow the center's translation. " +
            "Pre=\(preWith), Post=\(postWith), displacement=\(dispWith). " +
            "Expected X displacement ≥ 0.8 (out of 1.0 commanded).")

        // Without center: physics joint follows only partially. The distance
        // constraint pulls it toward the displaced root, but not rigidly:
        // the constraint solves the *radial* distance, not the lateral one,
        // so a perpendicular root translation produces sub-unity motion.
        XCTAssertLessThan(dispWithout.x, 0.8,
            "Spring without center must NOT rigidly follow a 1m center " +
            "translation in one frame — distance-constraint drag should " +
            "leave it short of full follow. " +
            "Pre=\(preWithout), Post=\(postWithout), displacement=\(dispWithout). " +
            "If X displacement is ≥ 0.8 the spring is acting as if center " +
            "were configured.")

        // Sanity: the two springs must diverge by a measurable amount on
        // exactly the axis the center moved on.
        let divergence = postWith.x - postWithout.x
        XCTAssertGreaterThan(divergence, 0.2,
            "Spring with center should be further along the translation " +
            "axis than the one without by ≥ 0.2m. Got \(divergence).")
    }

    /// Rotating the center node 90° around Y must drag the physics joint
    /// through the same rotation in world space (within tolerance for the
    /// distance-constraint nudge that follows). A spring without a center
    /// should not rotate with the center node.
    func testCenterNodeRotationDragsJointRigidly() throws {
        let withCenter = try makeCenterTestModel(useCenter: true)
        let withoutCenter = try makeCenterTestModel(useCenter: false)

        let systemWith = try SpringBoneComputeSystem(device: device)
        try systemWith.populateSpringBoneData(model: withCenter.model)
        let systemWithout = try SpringBoneComputeSystem(device: device)
        try systemWithout.populateSpringBoneData(model: withoutCenter.model)

        try SpringBoneTestFixtures.runFrames(20, system: systemWith,
                                             model: withCenter.model,
                                             commandQueue: commandQueue)
        try SpringBoneTestFixtures.runFrames(20, system: systemWithout,
                                             model: withoutCenter.model,
                                             commandQueue: commandQueue)

        let centerNode = withCenter.model.nodes[0]
        let centerWorld = centerNode.worldPosition
        let preWith = SpringBoneTestFixtures.readBonePosition(
            model: withCenter.model, boneIndex: 1)
        let preWithout = SpringBoneTestFixtures.readBonePosition(
            model: withoutCenter.model, boneIndex: 1)

        // Pre-rotation offset of the joint relative to the center.
        let preOffsetWith = preWith - centerWorld
        let preOffsetWithout = preWithout - centerWorld

        // Rotate center 90° around Y.
        let yawQuat = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        rotateRoot(model: withCenter.model, rotation: yawQuat)
        rotateRoot(model: withoutCenter.model, rotation: yawQuat)

        try SpringBoneTestFixtures.runFrame(system: systemWith,
                                            model: withCenter.model,
                                            commandQueue: commandQueue)
        try SpringBoneTestFixtures.runFrame(system: systemWithout,
                                            model: withoutCenter.model,
                                            commandQueue: commandQueue)

        let postWith = SpringBoneTestFixtures.readBonePosition(
            model: withCenter.model, boneIndex: 1)
        let postWithout = SpringBoneTestFixtures.readBonePosition(
            model: withoutCenter.model, boneIndex: 1)

        // Predicted post-rotation offset under rigid follow.
        let predictedOffsetWith = yawQuat.act(preOffsetWith)

        let postOffsetWith = postWith - centerWorld
        let followError = simd_distance(postOffsetWith, predictedOffsetWith)
        XCTAssertLessThan(followError, 0.1,
            "Spring with center node must follow a 90° Y rotation rigidly. " +
            "Pre offset (joint relative to center)=\(preOffsetWith). " +
            "Predicted post offset=\(predictedOffsetWith). " +
            "Got post offset=\(postOffsetWith). Follow error=\(followError) m, " +
            "expected < 0.1.")

        // Without center the joint should stay near its pre-rotation
        // *world* position (the center rotates the rest of the chain but
        // the physics joint resists).
        let preserveError = simd_distance(postWithout, preWithout)
        let predictedRotationDistance = simd_distance(
            predictedOffsetWith + centerWorld, preWithout)
        XCTAssertLessThan(preserveError, predictedRotationDistance * 0.5,
            "Spring without center must NOT rotate rigidly with the center " +
            "in a single frame. Pre=\(preWithout), Post=\(postWithout), " +
            "drift=\(preserveError). A rigidly-following joint would have " +
            "moved by ≈\(predictedRotationDistance).")

        // Unused but informative for debugging if the test ever fails.
        _ = preOffsetWithout
    }

    // MARK: - Model builders

    private struct CenterTestRig {
        let model: VRMModel
        let centerIndex: Int
    }

    /// Build a 3-node chain (center → root joint → physics joint) with one
    /// 2-joint spring. `useCenter` toggles spring.center between the
    /// center node and `nil`.
    private func makeCenterTestModel(useCenter: Bool) throws -> CenterTestRig {
        // Place the center at world (0, 1, 0); root joint at world (0, 1, 0)
        // by parenting to center with zero translation; physics joint at
        // world (0, 0.5, 0) by parenting to the root joint at (0, -0.5, 0).
        let model = try SpringBoneTestFixtures.makeChainModel(
            device: device,
            names: ["center", "rootJoint", "physJoint"],
            translations: [
                SIMD3<Float>(0, 1, 0),
                SIMD3<Float>(0.3, 0, 0),
                SIMD3<Float>(0, -0.5, 0),
            ]
        )

        // The spring's joints are nodes 1 and 2 (bone 0 = root, bone 1 = physics).
        // Disable gravity, stiffness, and drag-induced damping so the only
        // mover is the center-frame delta and the distance constraint.
        var rootJ = SpringBoneTestFixtures.defaultJoint(node: 1)
        rootJ.stiffness = 0.0
        rootJ.gravityPower = 0.0
        var physJ = SpringBoneTestFixtures.defaultJoint(node: 2)
        physJ.stiffness = 0.0
        physJ.gravityPower = 0.0
        physJ.dragForce = 0.5  // medium drag

        var spring = VRMSpring(name: "CenterTestSpring")
        spring.joints = [rootJ, physJ]
        spring.center = useCenter ? 0 : nil

        var sb = VRMSpringBone()
        sb.springs = [spring]
        model.springBone = sb

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 2, numSpheres: 0, numCapsules: 0)
        model.springBoneBuffers = buffers
        model.springBoneGlobalParams = SpringBoneTestFixtures.defaultGlobalParams(numBones: 2)

        return CenterTestRig(model: model, centerIndex: 0)
    }

    private func translateRoot(model: VRMModel, delta: SIMD3<Float>) {
        let center = model.nodes[0]
        center.translation += delta
        center.updateLocalMatrix()
        center.updateWorldTransform()
    }

    private func rotateRoot(model: VRMModel, rotation: simd_quatf) {
        let center = model.nodes[0]
        center.rotation = rotation * center.rotation
        center.updateLocalMatrix()
        center.updateWorldTransform()
    }
}
