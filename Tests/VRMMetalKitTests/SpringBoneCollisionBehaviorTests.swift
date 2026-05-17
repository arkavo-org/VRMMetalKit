// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Quantitative collision-behavior tests for the SpringBone compute system.
///
/// These tests are the P0 follow-up to the spring-bone test-suite review,
/// which flagged that `SpringBoneCollisionGroupTests` performs extensive
/// setup but ends most tests with `verifyNoNaNPositions(model:)` — a
/// crash detector, not a correctness assertion.
///
/// The tests here assert observable geometric invariants that follow
/// directly from the VRMC_springBone spec:
///
///   * After settling, a joint inside a sphere collider must be pushed to
///     (or beyond) the sphere's surface, accounting for `hitRadius`.
///   * A joint behind a plane collider must end up on the half-space the
///     normal points into.
///   * A collision group mask of 0x0 must produce a measurably different
///     trajectory from 0xFFFFFFFF — otherwise the mask is a no-op.
///
/// Determinism: every frame uses a host-owned `MTLCommandBuffer` whose
/// `waitUntilCompleted()` is awaited before reading bone state. No
/// `Thread.sleep`.
final class SpringBoneCollisionBehaviorTests: XCTestCase {

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

    // MARK: - Sphere collider: bone pushed to surface

    /// Place a single physics-driven joint inside a sphere collider and assert
    /// that after enough simulation frames the joint is at (or beyond) the
    /// sphere's surface — not merely "didn't crash."
    ///
    /// Geometry: root anchored at `(0, 5, 0)`, joint placed at `(0, 0, 0)`
    /// with rest length 5 so the distance constraint is satisfied there.
    /// A sphere of radius `0.2` is centered at `(0.1, 0, 0)`, so the joint
    /// starts `0.1` inside the surface along the `-X` direction (push-out
    /// direction is well-defined). All other forces (gravity, stiffness)
    /// are disabled so the only thing acting on the joint is the collision
    /// constraint plus the distance constraint to the anchor.
    func testJointStartingInsideSphereIsPushedToSurface() throws {
        let sphereCenter = SIMD3<Float>(0.1, 0, 0)
        let sphereRadius: Float = 0.2
        let hitRadius: Float = 0.0
        let model = try makeSingleJointModelWithSphere(
            sphereCenter: sphereCenter,
            sphereRadius: sphereRadius,
            hitRadius: hitRadius,
            colliderGroupMask: 0xFFFFFFFF
        )

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Initial geometry is already inside the sphere: verify the test setup.
        let initialJoint = SpringBoneTestFixtures.readBonePosition(model: model, boneIndex: 1)
        let initialDistance = simd_distance(initialJoint, sphereCenter)
        XCTAssertLessThan(initialDistance, sphereRadius,
            "Test geometry must start with the joint INSIDE the sphere " +
            "(distance \(initialDistance) < radius \(sphereRadius)) so the " +
            "collision response is observable. Adjust the fixture if this fails.")

        try SpringBoneTestFixtures.runFrames(60, system: system, model: model,
                                             commandQueue: commandQueue)

        let finalJoint = SpringBoneTestFixtures.readBonePosition(model: model, boneIndex: 1)
        let finalDistance = simd_distance(finalJoint, sphereCenter)
        let requiredDistance = sphereRadius + hitRadius
        // 5% tolerance: PBD relaxation may leave a small steady-state residual,
        // and root-interpolation tweens the joint between substep targets.
        let tolerance: Float = 0.05 * sphereRadius

        XCTAssertGreaterThanOrEqual(finalDistance, requiredDistance - tolerance,
            "After 60 frames the joint must be at or outside the sphere " +
            "surface. Sphere center=\(sphereCenter), radius=\(sphereRadius), " +
            "hitRadius=\(hitRadius). Initial joint=\(initialJoint) " +
            "(distance \(initialDistance)). Final joint=\(finalJoint) " +
            "(distance \(finalDistance)). Required: distance ≥ " +
            "\(requiredDistance) - \(tolerance).")

        SpringBoneTestFixtures.assertNoNaNPositions(model: model)
    }

    /// `hitRadius > 0`: the joint must be pushed `sphereRadius + hitRadius`
    /// from the sphere center, not just to the sphere surface.
    func testJointHitRadiusIsAddedToSphereSurfacePushDistance() throws {
        let sphereCenter = SIMD3<Float>(0.1, 0, 0)
        let sphereRadius: Float = 0.2
        let hitRadius: Float = 0.05
        let model = try makeSingleJointModelWithSphere(
            sphereCenter: sphereCenter,
            sphereRadius: sphereRadius,
            hitRadius: hitRadius,
            colliderGroupMask: 0xFFFFFFFF
        )

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        try SpringBoneTestFixtures.runFrames(60, system: system, model: model,
                                             commandQueue: commandQueue)

        let finalJoint = SpringBoneTestFixtures.readBonePosition(model: model, boneIndex: 1)
        let finalDistance = simd_distance(finalJoint, sphereCenter)
        let requiredDistance = sphereRadius + hitRadius
        let tolerance: Float = 0.05 * requiredDistance

        XCTAssertGreaterThanOrEqual(finalDistance, requiredDistance - tolerance,
            "Joint distance to sphere center after settling must include " +
            "hitRadius. Got distance=\(finalDistance), expected ≥ " +
            "\(requiredDistance) - \(tolerance).")
    }

    // MARK: - Collision group mask: 0x0 vs 0xFFFFFFFF

    /// Same physical setup; only the spring's `colliderGroups` differ.
    /// The masked-off run must end measurably closer to the original
    /// (penetrating) position than the all-bits-on run — otherwise the
    /// mask is a silent no-op.
    func testMaskZeroProducesMeasurablyDifferentTrajectoryFromAllBits() throws {
        let sphereCenter = SIMD3<Float>(0.1, 0, 0)
        let sphereRadius: Float = 0.2

        let modelAllBits = try makeSingleJointModelWithSphere(
            sphereCenter: sphereCenter, sphereRadius: sphereRadius,
            hitRadius: 0.0, colliderGroupMask: 0xFFFFFFFF
        )
        let systemAllBits = try SpringBoneComputeSystem(device: device)
        try systemAllBits.populateSpringBoneData(model: modelAllBits)

        let modelMaskZero = try makeSingleJointModelWithSphere(
            sphereCenter: sphereCenter, sphereRadius: sphereRadius,
            hitRadius: 0.0, colliderGroupMask: 0x0
        )
        let systemMaskZero = try SpringBoneComputeSystem(device: device)
        try systemMaskZero.populateSpringBoneData(model: modelMaskZero)

        let initialJoint = SpringBoneTestFixtures.readBonePosition(
            model: modelMaskZero, boneIndex: 1)

        try SpringBoneTestFixtures.runFrames(60, system: systemAllBits,
                                             model: modelAllBits,
                                             commandQueue: commandQueue)
        try SpringBoneTestFixtures.runFrames(60, system: systemMaskZero,
                                             model: modelMaskZero,
                                             commandQueue: commandQueue)

        let jointAllBits = SpringBoneTestFixtures.readBonePosition(
            model: modelAllBits, boneIndex: 1)
        let jointMaskZero = SpringBoneTestFixtures.readBonePosition(
            model: modelMaskZero, boneIndex: 1)

        let separation = simd_distance(jointAllBits, jointMaskZero)
        // The all-bits run must move the joint at least halfway through the
        // initial penetration depth, and the masked run must NOT.
        let penetrationDepth = sphereRadius - simd_distance(initialJoint, sphereCenter)
        XCTAssertGreaterThan(separation, penetrationDepth * 0.5,
            "Mask 0x0 vs 0xFFFFFFFF must produce trajectories that differ " +
            "by at least half the initial penetration depth (\(penetrationDepth)). " +
            "AllBits joint=\(jointAllBits), MaskZero joint=\(jointMaskZero), " +
            "separation=\(separation). If they agree, the mask filter is a no-op.")

        // The mask-zero joint should stay close to its initial penetrating
        // position (no collision response was applied).
        let driftMaskZero = simd_distance(jointMaskZero, initialJoint)
        XCTAssertLessThan(driftMaskZero, penetrationDepth * 0.5,
            "Mask 0x0 joint drifted \(driftMaskZero) from its initial position " +
            "\(initialJoint); collision response appears to have leaked through " +
            "the mask filter.")
    }

    // MARK: - Plane collider: half-space inequality

    /// Place a joint below an upward-facing plane with gravity pulling
    /// further down. After settling, the joint must be at or above the
    /// plane (signed distance ≥ -epsilon).
    ///
    /// Setup: plane at `y=0` with normal `(0, 1, 0)`. Joint starts at
    /// `y=-0.05` (below the plane). Gravity pulls down at 9.8 m/s²; only
    /// the plane constraint can keep the joint on the upper half-space.
    func testJointBehindPlaneIsPushedToHalfSpace() throws {
        let planeY: Float = 0.0
        let planeNormal = SIMD3<Float>(0, 1, 0)
        let initialJointY: Float = -0.05

        let model = try makeSingleJointModelWithPlane(
            rootWorld: SIMD3<Float>(0, 5, 0),
            jointWorld: SIMD3<Float>(0, initialJointY, 0),
            planePoint: SIMD3<Float>(0, planeY, 0),
            planeNormal: planeNormal,
            gravityPower: 1.0,
            colliderGroupMask: 0xFFFFFFFF
        )

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        try SpringBoneTestFixtures.runFrames(120, system: system, model: model,
                                             commandQueue: commandQueue)

        let finalJoint = SpringBoneTestFixtures.readBonePosition(model: model, boneIndex: 1)
        let signedDistance = simd_dot(finalJoint - SIMD3<Float>(0, planeY, 0), planeNormal)
        let tolerance: Float = 0.01  // 1 cm

        XCTAssertGreaterThan(signedDistance, -tolerance,
            "After 120 frames the joint must lie on the positive-normal " +
            "side of the plane (signed distance > -\(tolerance)). " +
            "Got finalJoint=\(finalJoint), signedDistance=\(signedDistance). " +
            "If signedDistance is significantly negative, the plane collider " +
            "is not enforcing the half-space constraint.")

        SpringBoneTestFixtures.assertNoNaNPositions(model: model)
    }

    /// A joint already on the positive-normal side of a plane should be
    /// unaffected by it (the plane constraint is one-sided in the spec).
    /// Compares against a control model with no colliders — final positions
    /// must agree within numerical tolerance.
    func testPlaneColliderInactiveWhenJointIsAlreadyAbove() throws {
        let planeY: Float = 0.0
        let planeNormal = SIMD3<Float>(0, 1, 0)
        let initialJointY: Float = 1.0  // well above the plane

        let modelWithPlane = try makeSingleJointModelWithPlane(
            rootWorld: SIMD3<Float>(0, 5, 0),
            jointWorld: SIMD3<Float>(0, initialJointY, 0),
            planePoint: SIMD3<Float>(0, planeY, 0),
            planeNormal: planeNormal,
            gravityPower: 0.0,
            colliderGroupMask: 0xFFFFFFFF
        )
        let systemWithPlane = try SpringBoneComputeSystem(device: device)
        try systemWithPlane.populateSpringBoneData(model: modelWithPlane)

        let modelNoCollider = try makeSingleJointModelWithoutColliders(
            rootWorld: SIMD3<Float>(0, 5, 0),
            jointWorld: SIMD3<Float>(0, initialJointY, 0),
            gravityPower: 0.0
        )
        let systemNoCollider = try SpringBoneComputeSystem(device: device)
        try systemNoCollider.populateSpringBoneData(model: modelNoCollider)

        try SpringBoneTestFixtures.runFrames(30, system: systemWithPlane,
                                             model: modelWithPlane,
                                             commandQueue: commandQueue)
        try SpringBoneTestFixtures.runFrames(30, system: systemNoCollider,
                                             model: modelNoCollider,
                                             commandQueue: commandQueue)

        let withPlane = SpringBoneTestFixtures.readBonePosition(model: modelWithPlane, boneIndex: 1)
        let noCollider = SpringBoneTestFixtures.readBonePosition(model: modelNoCollider, boneIndex: 1)
        let separation = simd_distance(withPlane, noCollider)

        XCTAssertLessThan(separation, 0.005,
            "A plane collider must not affect a joint that's already on the " +
            "positive-normal side. WithPlane=\(withPlane), NoCollider=" +
            "\(noCollider), separation=\(separation). If separation > 5 mm, " +
            "the plane is exerting force on joints in its 'safe' half-space.")
    }

    // MARK: - Model builders

    /// Two-node chain (anchor + physics joint) with one sphere collider at
    /// the supplied world center. Designed so:
    ///   * Root is far from the sphere; its position is anchored by being
    ///     a "root" bone (driven by animation, not physics).
    ///   * The physics joint starts inside the sphere with rest length
    ///     to the root satisfied, so the only meaningful constraint is
    ///     the collision response.
    private func makeSingleJointModelWithSphere(
        sphereCenter: SIMD3<Float>,
        sphereRadius: Float,
        hitRadius: Float,
        colliderGroupMask: UInt32
    ) throws -> VRMModel {
        let rootWorld = SIMD3<Float>(0, 5, 0)
        // Place the joint near the sphere center but offset so the push
        // direction is well-defined.
        let jointWorld = SIMD3<Float>(0, 0, 0)
        return try makeAnchoredJointModelWithSphere(
            rootWorld: rootWorld, jointWorld: jointWorld,
            sphereCenter: sphereCenter, sphereRadius: sphereRadius,
            hitRadius: hitRadius, colliderGroupMask: colliderGroupMask
        )
    }

    private func makeAnchoredJointModelWithSphere(
        rootWorld: SIMD3<Float>,
        jointWorld: SIMD3<Float>,
        sphereCenter: SIMD3<Float>,
        sphereRadius: Float,
        hitRadius: Float,
        colliderGroupMask: UInt32
    ) throws -> VRMModel {
        let model = try SpringBoneTestFixtures.makeChainModel(
            device: device,
            names: ["root", "joint"],
            translations: [rootWorld, jointWorld - rootWorld]
        )

        // Sphere collider is in node 0's local space; since node 0 is at
        // rootWorld with identity rotation, the offset must be
        // (sphereCenter - rootWorld) to place it at sphereCenter in world.
        let collider = VRMCollider(
            node: 0,
            shape: .sphere(offset: sphereCenter - rootWorld, radius: sphereRadius)
        )
        let group = VRMColliderGroup(name: "SphereGroup", colliders: [0])

        // Joint at index 0 is the root anchor (driven by animation).
        // Joint at index 1 is physics-driven and the target of the test.
        // Disable gravity + stiffness so the only forces are the distance
        // constraint and the collision response.
        var rootJoint = SpringBoneTestFixtures.defaultJoint(node: 0)
        rootJoint.stiffness = 0.0
        rootJoint.gravityPower = 0.0
        rootJoint.hitRadius = hitRadius
        var physJoint = SpringBoneTestFixtures.defaultJoint(node: 1)
        physJoint.stiffness = 0.0
        physJoint.gravityPower = 0.0
        physJoint.dragForce = 0.9   // High drag → quick settling.
        physJoint.hitRadius = hitRadius

        var spring = VRMSpring(name: "TestSpring")
        spring.joints = [rootJoint, physJoint]
        spring.colliderGroups = (colliderGroupMask == 0) ? [] : [0]

        var sb = VRMSpringBone()
        sb.colliders = [collider]
        sb.colliderGroups = [group]
        sb.springs = [spring]
        model.springBone = sb

        // Manually clear the spring's `colliderGroups` so the spring's
        // computed mask is 0x0 (filter rejects everything). Empty
        // `colliderGroups` would default to 0xFFFFFFFF in the populator —
        // so for the masked-zero variant we pass `[0]` (group 0 only) and
        // configure the collider on a different group index. Simpler:
        // use a non-existent group index for the masked-off case.
        if colliderGroupMask == 0 {
            // Reference a collider group that doesn't intersect any actual
            // collider's bit (the only collider belongs to group 0; we ask
            // the spring to collide with group 1, which is unpopulated).
            spring.colliderGroups = [1]
            sb.springs = [spring]
            model.springBone = sb
        }

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 2, numSpheres: 1, numCapsules: 0)
        model.springBoneBuffers = buffers
        model.springBoneGlobalParams = SpringBoneTestFixtures.defaultGlobalParams(
            numBones: 2, numSpheres: 1
        )
        return model
    }

    /// Two-node chain with one plane collider. Plane is in node 0's local
    /// space; we offset by `planePoint - rootWorld` so it lands at
    /// `planePoint` in world.
    private func makeSingleJointModelWithPlane(
        rootWorld: SIMD3<Float>,
        jointWorld: SIMD3<Float>,
        planePoint: SIMD3<Float>,
        planeNormal: SIMD3<Float>,
        gravityPower: Float,
        colliderGroupMask: UInt32
    ) throws -> VRMModel {
        let model = try SpringBoneTestFixtures.makeChainModel(
            device: device,
            names: ["root", "joint"],
            translations: [rootWorld, jointWorld - rootWorld]
        )

        let collider = VRMCollider(
            node: 0,
            shape: .plane(offset: planePoint - rootWorld, normal: planeNormal)
        )
        let group = VRMColliderGroup(name: "PlaneGroup", colliders: [0])

        var rootJoint = SpringBoneTestFixtures.defaultJoint(node: 0)
        rootJoint.stiffness = 0.0
        rootJoint.gravityPower = 0.0
        var physJoint = SpringBoneTestFixtures.defaultJoint(node: 1)
        physJoint.stiffness = 0.0
        physJoint.gravityPower = gravityPower
        physJoint.dragForce = 0.6

        var spring = VRMSpring(name: "TestSpring")
        spring.joints = [rootJoint, physJoint]
        spring.colliderGroups = (colliderGroupMask == 0) ? [] : [0]

        var sb = VRMSpringBone()
        sb.colliders = [collider]
        sb.colliderGroups = [group]
        sb.springs = [spring]
        model.springBone = sb

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 2, numSpheres: 0, numCapsules: 0, numPlanes: 1)
        model.springBoneBuffers = buffers
        model.springBoneGlobalParams = SpringBoneTestFixtures.defaultGlobalParams(
            numBones: 2, numPlanes: 1
        )
        return model
    }

    /// Same chain as `makeSingleJointModelWithPlane` but with zero colliders.
    /// Used as a control to assert "no collider == no effect" when a joint
    /// already sits in the safe half-space.
    private func makeSingleJointModelWithoutColliders(
        rootWorld: SIMD3<Float>,
        jointWorld: SIMD3<Float>,
        gravityPower: Float
    ) throws -> VRMModel {
        let model = try SpringBoneTestFixtures.makeChainModel(
            device: device,
            names: ["root", "joint"],
            translations: [rootWorld, jointWorld - rootWorld]
        )

        var rootJoint = SpringBoneTestFixtures.defaultJoint(node: 0)
        rootJoint.stiffness = 0.0
        rootJoint.gravityPower = 0.0
        var physJoint = SpringBoneTestFixtures.defaultJoint(node: 1)
        physJoint.stiffness = 0.0
        physJoint.gravityPower = gravityPower
        physJoint.dragForce = 0.6

        var spring = VRMSpring(name: "TestSpring")
        spring.joints = [rootJoint, physJoint]

        var sb = VRMSpringBone()
        sb.springs = [spring]
        model.springBone = sb

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 2, numSpheres: 0, numCapsules: 0)
        model.springBoneBuffers = buffers
        model.springBoneGlobalParams = SpringBoneTestFixtures.defaultGlobalParams(numBones: 2)
        return model
    }
}
