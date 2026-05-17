// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Tests for VMK#270: when the avatar (or just its head) rotates, the
/// spring-bone chain must follow the parent's rotated rest direction —
/// i.e. the stiffness target derived from `parentWorldRotation` must
/// pull the chain back toward "body-relative rest" as the parent
/// rotates.
///
/// Defect signature reported by QA: twin-tails / side-locks render
/// rigidly horizontal (helicopter-blade pose) as the character rotates
/// and never return to a natural hanging orientation.
///
/// Spec (`VRMC_springBone-1.0` §SpringBone Algorithm):
///
///   stiffness = deltaTime · parentWorldRotation · initialLocalRotation
///             · boneAxis · stiffnessForce
///
/// `parentWorldRotation` is the parent's CURRENT world rotation — read
/// fresh every frame. If the implementation caches it at avatar load,
/// the spring locks toward a world-fixed direction and the symptom
/// reproduces exactly.
@MainActor
final class SpringBoneRotationStiffnessTests: XCTestCase {

    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Could not create command queue")
        }
        self.device = device
        self.commandQueue = queue
    }

    /// A vertical spring chain hanging from an anchor: under pure
    /// gravity at rest the tip is directly below the anchor. After a
    /// 90° rotation of the anchor around Y the bind direction rotates
    /// with it — gravity continues to pull the tip down, so the
    /// stiffness force toward "below the anchor" and gravity both
    /// agree. After settling for 1 s post-rotation the tip must be
    /// **below** the anchor, not horizontal.
    func testChainTipReturnsBelowAnchorAfter90DegreeRotation() throws {
        let model = try makeVerticalSpringChainAnchoredAt(world: SIMD3<Float>(0, 1.0, 0))
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Settle the chain at the original orientation so the test
        // measures rotation-induced behavior, not first-frame transient.
        try runFrames(60, system: system, model: model)
        let preTip = readBonePosCurr(model: model, boneIndex: 3)
        let anchor = model.nodes[0]
        let preDrop = anchor.worldPosition.y - preTip.y
        XCTAssertGreaterThan(preDrop, 0.15,
            "Sanity: at rest the tip must hang well below the anchor under " +
            "gravity. Got tip y = \(preTip.y), anchor y = \(anchor.worldPosition.y), " +
            "drop = \(preDrop). Adjust gravity/stiffness defaults if this fails.")

        // Rotate the anchor +90° around Y over 30 frames (0.5 s @ 60 fps).
        // After the rotation, gravity still points −Y, so the tip should
        // still hang downward — the stiffness target rotates with the
        // parent and the gravity force is independent of orientation.
        let rotationDuration = 30
        let totalAngle: Float = .pi / 2  // 90°
        for i in 1...rotationDuration {
            let t = Float(i) / Float(rotationDuration)
            anchor.rotation = simd_quatf(angle: t * totalAngle,
                                          axis: SIMD3<Float>(0, 1, 0))
            anchor.updateLocalMatrix()
            anchor.updateWorldTransform()
            try runFrame(system: system, model: model)
        }

        // Hold the rotation and let physics settle for another 1 s.
        for _ in 0..<60 {
            try runFrame(system: system, model: model)
        }

        let postTip = readBonePosCurr(model: model, boneIndex: 3)
        let postDrop = anchor.worldPosition.y - postTip.y
        let horizontalRadius = sqrt(
            postTip.x * postTip.x + postTip.z * postTip.z
        )

        XCTAssertGreaterThan(postDrop, 0.15,
            "VMK#270: after rotating the anchor 90° around Y and holding for " +
            "1 s, the chain tip must hang downward. Got post-rotation drop = " +
            "\(postDrop) m, expected > 0.15 m. " +
            "horizontal radius = \(horizontalRadius). Tip = \(postTip). " +
            "If drop ≈ 0 and horizontal radius ≈ chainLength, the chain is " +
            "stuck in the helicopter-blade pose — gravity is not pulling " +
            "the tip down because the stiffness target is locked to a " +
            "world-fixed direction (parent rotation cached at load time) " +
            "and overrides gravity.")
    }

    /// A faster rotation (180° in 0.25 s) followed by a stop. The tip
    /// will swing outward during the rotation, but after a 2 s settle
    /// the gravity restoring force must bring it back below the anchor.
    func testChainTipRecoversAfterFastRotation() throws {
        let model = try makeVerticalSpringChainAnchoredAt(world: SIMD3<Float>(0, 1.0, 0))
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        try runFrames(60, system: system, model: model)

        let anchor = model.nodes[0]
        let rotationFrames = 15  // 180° / 15 frames = 12°/frame — fast
        let totalAngle: Float = .pi
        for i in 1...rotationFrames {
            let t = Float(i) / Float(rotationFrames)
            anchor.rotation = simd_quatf(angle: t * totalAngle,
                                          axis: SIMD3<Float>(0, 1, 0))
            anchor.updateLocalMatrix()
            anchor.updateWorldTransform()
            try runFrame(system: system, model: model)
        }
        // Settle for 2 s.
        for _ in 0..<120 {
            try runFrame(system: system, model: model)
        }

        let tip = readBonePosCurr(model: model, boneIndex: 3)
        let drop = anchor.worldPosition.y - tip.y
        XCTAssertGreaterThan(drop, 0.15,
            "VMK#270 (fast rotation recovery): after a 180° rotation in " +
            "0.25 s and 2 s of settle, the tip must hang below the anchor. " +
            "Got drop = \(drop) m, tip = \(tip). If drop ≈ 0 the chain has " +
            "settled into the helicopter-blade pose and never recovered — " +
            "the gravity restoring force is being overridden by a " +
            "stiffness force that points horizontally.")
    }

    /// Twin-tail / side-lock signature: a HORIZONTAL spring chain
    /// attached to the head, extending +X (avatar's own left). At rest
    /// the chain bind direction is +X. Gravity should pull it down so
    /// the tip settles somewhere between +X and −Y.
    ///
    /// QA report: after the head rotates, twin-tails render rigidly
    /// horizontal ("helicopter blade") and never return to a natural
    /// hanging orientation. This test reproduces by:
    /// 1. Settling the chain — gravity should bring the tip well below
    ///    the head, even though the bind direction is horizontal.
    /// 2. Rotating the head 90° around Y and holding.
    /// 3. Asserting the tip remains predominantly downward, not stuck
    ///    pointing along the rotated bind direction.
    func testHorizontalChainSettlesDownwardEvenWithRotatedAnchor() throws {
        let model = try makeHorizontalSpringChainAnchoredAt(world: SIMD3<Float>(0, 1.5, 0))
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Settle the chain under gravity — the bind direction is +X but
        // gravity should drag the tip downward despite stiffness pulling
        // toward the (horizontal) bind.
        try runFrames(180, system: system, model: model)
        let restTip = readBonePosCurr(model: model, boneIndex: 3)
        let anchor = model.nodes[0]
        let restDrop = anchor.worldPosition.y - restTip.y
        XCTAssertGreaterThan(restDrop, 0.05,
            "Spec: with gravityPower=1.0 and stiffness=0.5, a horizontal " +
            "twin-tail chain settles with the tip hanging below the head — " +
            "gravity restoration overcomes the horizontal stiffness target. " +
            "Got tip = \(restTip), anchor y = \(anchor.worldPosition.y), " +
            "drop = \(restDrop). If drop ≈ 0 the chain is stuck horizontal " +
            "even before any rotation, suggesting stiffness is too high " +
            "relative to gravity (or gravity is being silently zeroed).")

        // Rotate the head 90° around Y over 30 frames, then hold for 2 s.
        let totalAngle: Float = .pi / 2
        for i in 1...30 {
            let t = Float(i) / 30.0
            anchor.rotation = simd_quatf(angle: t * totalAngle,
                                          axis: SIMD3<Float>(0, 1, 0))
            anchor.updateLocalMatrix()
            anchor.updateWorldTransform()
            try runFrame(system: system, model: model)
        }
        for _ in 0..<120 {
            try runFrame(system: system, model: model)
        }

        let postTip = readBonePosCurr(model: model, boneIndex: 3)
        let postDrop = anchor.worldPosition.y - postTip.y

        XCTAssertGreaterThan(postDrop, 0.05,
            "VMK#270: after head rotates 90° and holds for 2 s, the " +
            "twin-tail tip must STILL hang below the head (gravity > " +
            "stiffness-horizontal). Got tip = \(postTip), drop = \(postDrop). " +
            "If drop ≈ 0 the chain is stuck in the helicopter-blade pose — " +
            "the bind direction tracks the parent rotation correctly but " +
            "stiffness toward the horizontal bind overpowers gravity.")
    }

    // MARK: - Helpers

    /// Build a 4-bone HORIZONTAL chain extending +X from the anchor —
    /// the twin-tail / side-lock signature shape.
    private func makeHorizontalSpringChainAnchoredAt(world: SIMD3<Float>) throws -> VRMModel {
        let model = try SpringBoneTestFixtures.makeChainModel(
            device: device,
            names: ["anchor", "j1", "j2", "j3"],
            translations: [
                world,
                SIMD3<Float>(0.1, 0, 0),
                SIMD3<Float>(0.1, 0, 0),
                SIMD3<Float>(0.1, 0, 0),
            ]
        )

        var anchorJ = SpringBoneTestFixtures.defaultJoint(node: 0)
        anchorJ.stiffness = 0.0
        anchorJ.gravityPower = 0.0
        var j1 = SpringBoneTestFixtures.defaultJoint(node: 1)
        j1.stiffness = 0.5
        j1.gravityPower = 1.0
        j1.dragForce = 0.4
        var j2 = SpringBoneTestFixtures.defaultJoint(node: 2)
        j2.stiffness = 0.5
        j2.gravityPower = 1.0
        j2.dragForce = 0.4
        var j3 = SpringBoneTestFixtures.defaultJoint(node: 3)
        j3.stiffness = 0.5
        j3.gravityPower = 1.0
        j3.dragForce = 0.4

        var spring = VRMSpring(name: "HorizontalTwinTail")
        spring.joints = [anchorJ, j1, j2, j3]
        var sb = VRMSpringBone()
        sb.springs = [spring]
        model.springBone = sb

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 4, numSpheres: 0, numCapsules: 0)
        model.springBoneBuffers = buffers
        model.springBoneGlobalParams = SpringBoneTestFixtures.defaultGlobalParams(numBones: 4)

        return model
    }

    /// Build a 4-bone vertical chain: anchor (root, animation-driven) +
    /// 3 physics joints hanging below at 0.1 m intervals. Stiffness and
    /// gravity tuned for typical hair-strand behavior.
    private func makeVerticalSpringChainAnchoredAt(world: SIMD3<Float>) throws -> VRMModel {
        let model = try SpringBoneTestFixtures.makeChainModel(
            device: device,
            names: ["anchor", "j1", "j2", "j3"],
            translations: [
                world,
                SIMD3<Float>(0, -0.1, 0),
                SIMD3<Float>(0, -0.1, 0),
                SIMD3<Float>(0, -0.1, 0),
            ]
        )

        var anchorJ = SpringBoneTestFixtures.defaultJoint(node: 0)
        anchorJ.stiffness = 0.0
        anchorJ.gravityPower = 0.0
        var j1 = SpringBoneTestFixtures.defaultJoint(node: 1)
        j1.stiffness = 0.5
        j1.gravityPower = 1.0
        j1.dragForce = 0.4
        var j2 = SpringBoneTestFixtures.defaultJoint(node: 2)
        j2.stiffness = 0.5
        j2.gravityPower = 1.0
        j2.dragForce = 0.4
        var j3 = SpringBoneTestFixtures.defaultJoint(node: 3)
        j3.stiffness = 0.5
        j3.gravityPower = 1.0
        j3.dragForce = 0.4

        var spring = VRMSpring(name: "VerticalChain")
        spring.joints = [anchorJ, j1, j2, j3]
        var sb = VRMSpringBone()
        sb.springs = [spring]
        model.springBone = sb

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 4, numSpheres: 0, numCapsules: 0)
        model.springBoneBuffers = buffers
        model.springBoneGlobalParams = SpringBoneTestFixtures.defaultGlobalParams(numBones: 4)

        return model
    }

    private func runFrame(system: SpringBoneComputeSystem, model: VRMModel,
                          deltaTime: TimeInterval = 1.0 / 60.0) throws {
        guard let cb = commandQueue.makeCommandBuffer() else {
            throw XCTSkip("Could not create command buffer")
        }
        system.update(model: model, deltaTime: deltaTime, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
    }

    private func runFrames(_ count: Int, system: SpringBoneComputeSystem,
                           model: VRMModel) throws {
        for _ in 0..<count {
            try runFrame(system: system, model: model)
        }
    }

    private func readBonePosCurr(model: VRMModel, boneIndex: Int) -> SIMD3<Float> {
        guard let buffers = model.springBoneBuffers,
              let buf = buffers.bonePosCurr,
              boneIndex < buffers.numBones else { return .zero }
        let ptr = buf.contents().bindMemory(to: SIMD3<Float>.self,
                                            capacity: buffers.numBones)
        return ptr[boneIndex]
    }
}
