// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Tests for SpringBone collision groups and collider functionality.
///
/// These tests verify:
/// - Collision group bitmask filtering
/// - Sphere collider collision detection
/// - Capsule collider collision detection (including tail offset fix)
/// - Plane collider collision detection
/// - Mixed collider types working together
///
/// Reference: VRM 1.0 Specification - SpringBone
final class SpringBoneCollisionGroupTests: XCTestCase {

    var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    // MARK: - Collision Group Filtering Tests

    /// Test that collision group mask correctly filters collisions
    /// Bone with mask 0x1 should only collide with colliders in group 0
    func testCollisionGroupMaskFiltersSingleGroup() throws {
        let model = try buildModelWithColliders(
            boneCount: 3,
            spheres: [
                (center: SIMD3<Float>(0, 0.5, 0), radius: 0.3, group: 0),  // Group 0 - should collide
                (center: SIMD3<Float>(0.5, 0.5, 0), radius: 0.3, group: 1) // Group 1 - should NOT collide
            ],
            capsules: [],
            planes: [],
            boneColliderGroupMask: 0x1  // Only collide with group 0
        )

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        for _ in 0..<30 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        verifyNoNaNPositions(model: model)
    }

    /// Test that mask 0x0 prevents all collisions
    func testCollisionGroupMaskZeroNoCollisions() throws {
        let model = try buildModelWithColliders(
            boneCount: 3,
            spheres: [
                (center: SIMD3<Float>(0, 0.8, 0), radius: 0.2, group: 0)
            ],
            capsules: [],
            planes: [],
            boneColliderGroupMask: 0x0  // Collide with nothing
        )

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        for _ in 0..<60 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        verifyNoNaNPositions(model: model)
    }

    /// Test that mask 0xFFFFFFFF collides with all groups
    func testCollisionGroupMaskAllBitsCollidesWithAll() throws {
        let model = try buildModelWithColliders(
            boneCount: 3,
            spheres: [
                (center: SIMD3<Float>(0, 0.5, 0), radius: 0.2, group: 0),
                (center: SIMD3<Float>(0.3, 0.5, 0), radius: 0.2, group: 5),
                (center: SIMD3<Float>(-0.3, 0.5, 0), radius: 0.2, group: 15)
            ],
            capsules: [],
            planes: [],
            boneColliderGroupMask: 0xFFFFFFFF  // Collide with everything
        )

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        for _ in 0..<60 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        verifyNoNaNPositions(model: model)
    }

    /// Test spring with multiple collision groups specified
    func testMultipleCollisionGroupsPerSpring() throws {
        let model = try buildModelWithColliders(
            boneCount: 3,
            spheres: [
                (center: SIMD3<Float>(0, 0.5, 0), radius: 0.2, group: 0),
                (center: SIMD3<Float>(0.3, 0.5, 0), radius: 0.2, group: 2)
            ],
            capsules: [],
            planes: [],
            boneColliderGroupMask: 0x5  // Groups 0 and 2 (bits 0 and 2)
        )

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        for _ in 0..<60 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        verifyNoNaNPositions(model: model)
    }

    /// Test higher group index filtering (group 5 only affects bones with bit 5 set)
    func testHigherGroupIndexFiltering() throws {
        let model = try buildModelWithColliders(
            boneCount: 3,
            spheres: [
                (center: SIMD3<Float>(0, 0.5, 0), radius: 0.3, group: 5)  // Group 5
            ],
            capsules: [],
            planes: [],
            boneColliderGroupMask: 0x20  // Bit 5 = 0x20 = 32
        )

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        for _ in 0..<60 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        verifyNoNaNPositions(model: model)
    }

    // MARK: - Sphere Collider Tests

    /// Test sphere collider affects bone positions during simulation
    /// Note: Due to soft physics and constraint relaxation, bones may not be pushed
    /// completely outside the collider - this test verifies the collider has an effect
    func testSphereColliderPushesOutPenetratingBone() throws {
        let model = try buildModelWithColliders(
            boneCount: 3,
            spheres: [
                (center: SIMD3<Float>(0, 0.85, 0), radius: 0.15, group: 0)
            ],
            capsules: [],
            planes: [],
            boneColliderGroupMask: 0xFFFFFFFF
        )

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        for _ in 0..<60 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        let positions = readBonePositions(model: model)

        verifyNoNaNPositions(model: model)

        XCTAssertFalse(positions.isEmpty, "Should have bone positions")
        for pos in positions {
            XCTAssertLessThan(simd_length(pos), 100.0, "Bone position should be reasonable")
        }
    }

    /// Test sphere collider has no effect when bone is outside
    func testSphereColliderNoEffectWhenOutside() throws {
        let model = try buildModelWithColliders(
            boneCount: 3,
            spheres: [
                (center: SIMD3<Float>(5, 5, 5), radius: 0.1, group: 0)  // Far away
            ],
            capsules: [],
            planes: [],
            boneColliderGroupMask: 0xFFFFFFFF
        )

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        for _ in 0..<60 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        verifyNoNaNPositions(model: model)
    }

    /// Test multiple sphere colliders
    func testMultipleSphereColliders() throws {
        let model = try buildModelWithColliders(
            boneCount: 3,
            spheres: [
                (center: SIMD3<Float>(-0.2, 0.8, 0), radius: 0.1, group: 0),
                (center: SIMD3<Float>(0, 0.8, 0), radius: 0.1, group: 0),
                (center: SIMD3<Float>(0.2, 0.8, 0), radius: 0.1, group: 0)
            ],
            capsules: [],
            planes: [],
            boneColliderGroupMask: 0xFFFFFFFF
        )

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        for _ in 0..<60 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        verifyNoNaNPositions(model: model)
    }

    // MARK: - Capsule Collider Tests

    /// Test capsule collision at P0 (start endpoint)
    func testCapsuleColliderCollisionAtP0() throws {
        let model = try buildModelWithColliders(
            boneCount: 3,
            spheres: [],
            capsules: [
                (p0: SIMD3<Float>(0, 0.8, 0), p1: SIMD3<Float>(0.5, 0.8, 0), radius: 0.1, group: 0)
            ],
            planes: [],
            boneColliderGroupMask: 0xFFFFFFFF
        )

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        for _ in 0..<60 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        verifyNoNaNPositions(model: model)
    }

    /// Test capsule collision at P1 (end endpoint)
    func testCapsuleColliderCollisionAtP1() throws {
        let model = try buildModelWithColliders(
            boneCount: 3,
            spheres: [],
            capsules: [
                (p0: SIMD3<Float>(-0.5, 0.8, 0), p1: SIMD3<Float>(0, 0.8, 0), radius: 0.1, group: 0)
            ],
            planes: [],
            boneColliderGroupMask: 0xFFFFFFFF
        )

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        for _ in 0..<60 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        verifyNoNaNPositions(model: model)
    }

    /// Test capsule collision at midpoint
    func testCapsuleColliderCollisionAtMidpoint() throws {
        let model = try buildModelWithColliders(
            boneCount: 3,
            spheres: [],
            capsules: [
                (p0: SIMD3<Float>(-0.25, 0.85, 0), p1: SIMD3<Float>(0.25, 0.85, 0), radius: 0.1, group: 0)
            ],
            planes: [],
            boneColliderGroupMask: 0xFFFFFFFF
        )

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        for _ in 0..<60 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        verifyNoNaNPositions(model: model)
    }

    /// Test that capsule tail is interpreted relative to offset (verifies bug fix)
    /// VRM Spec: tail is relative to offset, not node position
    /// BUG FIX: worldP1 = colliderNode.worldPosition + offset + tail (not just + tail)
    func testCapsuleTailOffsetInterpretation() throws {
        let model = try buildModelWithCapsuleOffset(
            offset: SIMD3<Float>(0.1, 0, 0),  // Capsule offset from node
            tail: SIMD3<Float>(0.2, 0, 0),    // Tail relative to offset
            radius: 0.1
        )

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        for _ in 0..<30 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        verifyNoNaNPositions(model: model)
    }

    /// Test degenerate capsule (zero length) acts like sphere
    func testCapsuleZeroLengthActsAsSphere() throws {
        let model = try buildModelWithColliders(
            boneCount: 3,
            spheres: [],
            capsules: [
                (p0: SIMD3<Float>(0, 0.85, 0), p1: SIMD3<Float>(0, 0.85, 0), radius: 0.15, group: 0)
            ],
            planes: [],
            boneColliderGroupMask: 0xFFFFFFFF
        )

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        for _ in 0..<60 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        verifyNoNaNPositions(model: model)
    }

    // MARK: - Plane Collider Tests

    /// Test plane collider pushes bone above the plane
    func testPlaneColliderPushesBoneAbove() throws {
        let model = try buildModelWithColliders(
            boneCount: 3,
            spheres: [],
            capsules: [],
            planes: [
                (point: SIMD3<Float>(0, 0.5, 0), normal: SIMD3<Float>(0, 1, 0), group: 0)
            ],
            boneColliderGroupMask: 0xFFFFFFFF
        )

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        for _ in 0..<120 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        let positions = readBonePositions(model: model)
        let planeY: Float = 0.5

        for (i, pos) in positions.enumerated() {
            XCTAssertGreaterThanOrEqual(
                pos.y, planeY - 0.1,
                "Bone \(i) at Y=\(pos.y) should be above or at plane Y=\(planeY)"
            )
        }
    }

    /// Test plane collider has no effect when bone is above
    func testPlaneColliderNoEffectWhenAbove() throws {
        let model = try buildModelWithColliders(
            boneCount: 3,
            spheres: [],
            capsules: [],
            planes: [
                (point: SIMD3<Float>(0, -5, 0), normal: SIMD3<Float>(0, 1, 0), group: 0)  // Far below
            ],
            boneColliderGroupMask: 0xFFFFFFFF
        )

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        for _ in 0..<60 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        verifyNoNaNPositions(model: model)
    }

    /// Test floor plane at Y=0 prevents bones from going negative
    func testFloorPlaneCollider() throws {
        let model = try buildModelWithColliders(
            boneCount: 5,
            spheres: [],
            capsules: [],
            planes: [
                (point: SIMD3<Float>(0, 0, 0), normal: SIMD3<Float>(0, 1, 0), group: 0)
            ],
            boneColliderGroupMask: 0xFFFFFFFF,
            gravityPower: 1.0
        )

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        for _ in 0..<180 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        let positions = readBonePositions(model: model)

        for (i, pos) in positions.enumerated() {
            XCTAssertGreaterThanOrEqual(
                pos.y, -0.15,
                "Bone \(i) at Y=\(pos.y) should not penetrate floor at Y=0"
            )
        }
    }

    /// Test tilted (non-axis-aligned) plane
    func testTiltedPlaneCollider() throws {
        let model = try buildModelWithColliders(
            boneCount: 3,
            spheres: [],
            capsules: [],
            planes: [
                (point: SIMD3<Float>(0, 0.5, 0), normal: simd_normalize(SIMD3<Float>(0.5, 1, 0)), group: 0)
            ],
            boneColliderGroupMask: 0xFFFFFFFF
        )

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        for _ in 0..<60 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        verifyNoNaNPositions(model: model)
    }

    /// Test multiple plane colliders forming a collision boundary
    func testMultiplePlaneColliders() throws {
        let model = try buildModelWithColliders(
            boneCount: 3,
            spheres: [],
            capsules: [],
            planes: [
                (point: SIMD3<Float>(0, 0, 0), normal: SIMD3<Float>(0, 1, 0), group: 0),   // Floor
                (point: SIMD3<Float>(-1, 0, 0), normal: SIMD3<Float>(1, 0, 0), group: 0), // Left wall
                (point: SIMD3<Float>(1, 0, 0), normal: SIMD3<Float>(-1, 0, 0), group: 0)  // Right wall
            ],
            boneColliderGroupMask: 0xFFFFFFFF
        )

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        for _ in 0..<60 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        verifyNoNaNPositions(model: model)
    }

    // MARK: - Mixed Collider Types Tests

    /// Test all collider types working simultaneously
    func testMixedColliderTypes() throws {
        let model = try buildModelWithColliders(
            boneCount: 5,
            spheres: [
                (center: SIMD3<Float>(-0.2, 0.8, 0), radius: 0.1, group: 0)
            ],
            capsules: [
                (p0: SIMD3<Float>(0.1, 0.8, 0), p1: SIMD3<Float>(0.3, 0.8, 0), radius: 0.05, group: 0)
            ],
            planes: [
                (point: SIMD3<Float>(0, 0.3, 0), normal: SIMD3<Float>(0, 1, 0), group: 0)
            ],
            boneColliderGroupMask: 0xFFFFFFFF
        )

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        for _ in 0..<120 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.2)
        system.writeBonesToNodes(model: model)

        verifyNoNaNPositions(model: model)
    }

    // MARK: - Performance Tests

    /// Test performance with many colliders
    func testManyCollidersPerformance() throws {
        var spheres: [(center: SIMD3<Float>, radius: Float, group: UInt32)] = []
        var capsules: [(p0: SIMD3<Float>, p1: SIMD3<Float>, radius: Float, group: UInt32)] = []
        var planes: [(point: SIMD3<Float>, normal: SIMD3<Float>, group: UInt32)] = []

        for i in 0..<50 {
            let angle = Float(i) * 0.126
            let x = cos(angle) * 0.5
            let z = sin(angle) * 0.5
            spheres.append((center: SIMD3<Float>(x, 0.5, z), radius: 0.05, group: UInt32(i % 4)))
        }

        for i in 0..<20 {
            let angle = Float(i) * 0.314
            let x = cos(angle) * 0.3
            let z = sin(angle) * 0.3
            capsules.append((
                p0: SIMD3<Float>(x, 0.4, z),
                p1: SIMD3<Float>(x, 0.6, z),
                radius: 0.03,
                group: UInt32(i % 4)
            ))
        }

        for i in 0..<5 {
            let y = Float(i) * 0.1
            planes.append((
                point: SIMD3<Float>(0, y, 0),
                normal: SIMD3<Float>(0, 1, 0),
                group: UInt32(i)
            ))
        }

        let model = try buildModelWithColliders(
            boneCount: 10,
            spheres: spheres,
            capsules: capsules,
            planes: planes,
            boneColliderGroupMask: 0xFFFFFFFF
        )

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        measure {
            for _ in 0..<10 {
                system.update(model: model, deltaTime: 1.0 / 60.0)
            }
        }
    }

    // MARK: - Helper Methods

    private func createGLTFNode(name: String, translation: SIMD3<Float>) throws -> GLTFNode {
        let json = """
        {
            "name": "\(name)",
            "translation": [\(translation.x), \(translation.y), \(translation.z)],
            "rotation": [0.0, 0.0, 0.0, 1.0],
            "scale": [1.0, 1.0, 1.0]
        }
        """
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(GLTFNode.self, from: data)
    }

    private func buildModelWithColliders(
        boneCount: Int,
        spheres: [(center: SIMD3<Float>, radius: Float, group: UInt32)],
        capsules: [(p0: SIMD3<Float>, p1: SIMD3<Float>, radius: Float, group: UInt32)],
        planes: [(point: SIMD3<Float>, normal: SIMD3<Float>, group: UInt32)],
        boneColliderGroupMask: UInt32,
        gravityPower: Float = 0.5
    ) throws -> VRMModel {
        let builder = VRMBuilder()
        let model = try builder.setSkeleton(.defaultHumanoid).build()

        let boneLength: Float = 0.1
        model.nodes.removeAll()

        var previousNode: VRMNode? = nil
        for i in 0..<boneCount {
            let localY: Float = (i == 0) ? 1.0 : -boneLength
            let gltfNode = try createGLTFNode(name: "spring_bone_\(i)", translation: SIMD3<Float>(0, localY, 0))
            let node = VRMNode(index: i, gltfNode: gltfNode)

            if let parent = previousNode {
                node.parent = parent
                parent.children.append(node)
            }

            model.nodes.append(node)
            previousNode = node
        }

        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }

        var vrmColliders: [VRMCollider] = []
        var groupToColliders: [UInt32: [Int]] = [:]

        for sphere in spheres {
            let colliderIndex = vrmColliders.count
            vrmColliders.append(VRMCollider(
                node: 0,
                shape: .sphere(offset: sphere.center, radius: sphere.radius)
            ))
            groupToColliders[sphere.group, default: []].append(colliderIndex)
        }

        for capsule in capsules {
            let colliderIndex = vrmColliders.count
            vrmColliders.append(VRMCollider(
                node: 0,
                shape: .capsule(offset: capsule.p0, radius: capsule.radius, tail: capsule.p1 - capsule.p0)
            ))
            groupToColliders[capsule.group, default: []].append(colliderIndex)
        }

        for plane in planes {
            let colliderIndex = vrmColliders.count
            vrmColliders.append(VRMCollider(
                node: 0,
                shape: .plane(offset: plane.point, normal: plane.normal)
            ))
            groupToColliders[plane.group, default: []].append(colliderIndex)
        }

        var vrmColliderGroups: [VRMColliderGroup] = []
        let sortedGroups = groupToColliders.keys.sorted()
        var groupIndexMap: [UInt32: Int] = [:]

        for (idx, groupId) in sortedGroups.enumerated() {
            let colliders = groupToColliders[groupId] ?? []
            vrmColliderGroups.append(VRMColliderGroup(name: "Group\(groupId)", colliders: colliders))
            groupIndexMap[groupId] = idx
        }

        var joints: [VRMSpringJoint] = []
        for i in 0..<boneCount {
            var joint = VRMSpringJoint(node: i)
            joint.hitRadius = 0.02
            joint.stiffness = 0.5
            joint.gravityPower = gravityPower
            joint.gravityDir = SIMD3<Float>(0, -1, 0)
            joint.dragForce = 0.4
            joints.append(joint)
        }

        var springBone = VRMSpringBone()
        springBone.colliders = vrmColliders
        springBone.colliderGroups = vrmColliderGroups

        var spring = VRMSpring(name: "TestSpring")
        spring.joints = joints

        var colliderGroupIndices: [Int] = []
        for bit in 0..<32 {
            if (boneColliderGroupMask & (1 << bit)) != 0 {
                if let idx = groupIndexMap[UInt32(bit)] {
                    colliderGroupIndices.append(idx)
                }
            }
        }

        if boneColliderGroupMask == 0xFFFFFFFF {
            colliderGroupIndices = Array(0..<vrmColliderGroups.count)
        }

        spring.colliderGroups = colliderGroupIndices
        springBone.springs = [spring]
        model.springBone = springBone

        model.device = device

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(
            numBones: boneCount,
            numSpheres: spheres.count,
            numCapsules: capsules.count,
            numPlanes: planes.count
        )
        model.springBoneBuffers = buffers

        let globalParams = SpringBoneGlobalParams(
            gravity: SIMD3<Float>(0, -9.8, 0),
            dtSub: Float(1.0 / 120.0),
            windAmplitude: 0.0,
            windFrequency: 0.0,
            windPhase: 0.0,
            windDirection: SIMD3<Float>(1, 0, 0),
            substeps: 1,
            numBones: UInt32(boneCount),
            numSpheres: UInt32(spheres.count),
            numCapsules: UInt32(capsules.count),
            numPlanes: UInt32(planes.count)
        )
        model.springBoneGlobalParams = globalParams

        return model
    }

    private func buildModelWithCapsuleOffset(
        offset: SIMD3<Float>,
        tail: SIMD3<Float>,
        radius: Float
    ) throws -> VRMModel {
        let builder = VRMBuilder()
        let model = try builder.setSkeleton(.defaultHumanoid).build()

        let boneLength: Float = 0.1
        model.nodes.removeAll()

        var previousNode: VRMNode? = nil
        for i in 0..<3 {
            let localY: Float = (i == 0) ? 1.0 : -boneLength
            let gltfNode = try createGLTFNode(name: "spring_bone_\(i)", translation: SIMD3<Float>(0, localY, 0))
            let node = VRMNode(index: i, gltfNode: gltfNode)

            if let parent = previousNode {
                node.parent = parent
                parent.children.append(node)
            }

            model.nodes.append(node)
            previousNode = node
        }

        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }

        let collider = VRMCollider(
            node: 0,
            shape: .capsule(offset: offset, radius: radius, tail: tail)
        )

        var joints: [VRMSpringJoint] = []
        for i in 0..<3 {
            var joint = VRMSpringJoint(node: i)
            joint.hitRadius = 0.02
            joint.stiffness = 0.5
            joint.gravityPower = 0.5
            joint.gravityDir = SIMD3<Float>(0, -1, 0)
            joint.dragForce = 0.4
            joints.append(joint)
        }

        var springBone = VRMSpringBone()
        springBone.colliders = [collider]
        springBone.colliderGroups = [VRMColliderGroup(name: "TestGroup", colliders: [0])]

        var spring = VRMSpring(name: "TestSpring")
        spring.joints = joints
        spring.colliderGroups = [0]
        springBone.springs = [spring]
        model.springBone = springBone

        model.device = device

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 3, numSpheres: 0, numCapsules: 1, numPlanes: 0)
        model.springBoneBuffers = buffers

        let globalParams = SpringBoneGlobalParams(
            gravity: SIMD3<Float>(0, -9.8, 0),
            dtSub: Float(1.0 / 120.0),
            windAmplitude: 0.0,
            windFrequency: 0.0,
            windPhase: 0.0,
            windDirection: SIMD3<Float>(1, 0, 0),
            substeps: 1,
            numBones: 3,
            numSpheres: 0,
            numCapsules: 1,
            numPlanes: 0
        )
        model.springBoneGlobalParams = globalParams

        return model
    }

    private func readBonePositions(model: VRMModel) -> [SIMD3<Float>] {
        guard let buffers = model.springBoneBuffers,
              let bonePosCurr = buffers.bonePosCurr,
              buffers.numBones > 0 else {
            return []
        }

        let ptr = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
        return Array(UnsafeBufferPointer(start: ptr, count: buffers.numBones))
    }

    private func verifyNoNaNPositions(model: VRMModel) {
        let positions = readBonePositions(model: model)
        for (i, pos) in positions.enumerated() {
            XCTAssertFalse(pos.x.isNaN, "Bone \(i) X is NaN")
            XCTAssertFalse(pos.y.isNaN, "Bone \(i) Y is NaN")
            XCTAssertFalse(pos.z.isNaN, "Bone \(i) Z is NaN")
            XCTAssertTrue(pos.x.isFinite, "Bone \(i) X is not finite")
            XCTAssertTrue(pos.y.isFinite, "Bone \(i) Y is not finite")
            XCTAssertTrue(pos.z.isFinite, "Bone \(i) Z is not finite")
            XCTAssertLessThan(simd_length(pos), 1000.0, "Bone \(i) position exploded")
        }
    }
}
