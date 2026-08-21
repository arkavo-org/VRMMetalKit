// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Diagnostic for issue #415 — "a collider in two referenced groups must be
/// applied once per group, not once total".
///
/// The conformance oracles (UniVRM v0.131.0, `@pixiv/three-vrm` 3.5.0) both
/// flatten `spring.colliderGroups → group.colliders` with no dedup, so such a
/// collider appears twice in their per-joint collider list. In those solvers the
/// second application is NOT a no-op, because each hit is followed *inside the
/// collider loop* by a re-projection of the tail onto the bone-length sphere,
/// which generally pushes the joint back into the collider:
///
///   UniVRM  `SpringBoneCollision.cs:50-53`  — push out, then
///           `newNextTail = head + normalize(posFromCollider - head) * logic.length`
///   UniVRM  `FastSpringBoneBufferFactory.cs:47-48` — `.SelectMany(group => group.Colliders)`, no `.Distinct()`
///   three-vrm `VRMSpringBoneJoint.ts:284-299` — same nested loop, same in-loop
///           "normalize bone length" after each hit
///
/// VMK's solver is structurally different: collision is a pure positional
/// projection to the collider surface (`responseScale == 1`), and the distance
/// constraint is a **separate kernel dispatched before** collision, never
/// between two colliders. So pushing a joint out of the same sphere twice in one
/// pass lands it in exactly the same place as pushing it out once.
///
/// These tests MEASURE that, rather than asserting it from code reading. Variant
/// B is hand-built to be byte-for-byte what the issue's proposed fix would
/// upload (one buffer entry per (group, collider) membership, each carrying a
/// single group bit) — without changing production code. If A and B agree, the
/// proposed fix cannot move rendered output, and the discriminator asset is
/// measuring the solver's collision-integration scheme rather than group
/// semantics.
final class SpringBoneMultiGroupColliderTests: XCTestCase {

    var device: (any MTLDevice)!
    var commandQueue: (any MTLCommandQueue)!

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

    // MARK: - Rig

    /// How the collider reachable from the spring is registered.
    private enum ColliderLayout {
        /// No colliders at all. Buffers are allocated with `numSpheres: 0` so
        /// `update()` computes `params.numSpheres == 0` and skips the collide
        /// dispatch entirely — the control must be collider-free by
        /// construction, not by the sphere slot happening to read as zeroed.
        case none
        /// One collider, member of both groups — today's upload, one entry
        /// masked `0b11`.
        case shared
        /// Two identical colliders, one per group — the per-group upload #415
        /// asks for, two entries masked `0b01` and `0b10`.
        case perGroup
    }

    /// One sphere collider sitting against a 4-joint hanging chain, reachable
    /// through two collider groups that the spring references.
    private func buildChain(_ layout: ColliderLayout) throws -> VRMModel {
        let builder = VRMBuilder()
        let model = try builder.setSkeleton(.defaultHumanoid).build()

        let boneCount = 4
        let boneLength: Float = 0.1
        model.nodes.removeAll()

        var previousNode: VRMNode? = nil
        for i in 0..<boneCount {
            let localY: Float = (i == 0) ? 1.0 : -boneLength
            let gltfNode = try makeGLTFNode(name: "joint_\(i)", translation: SIMD3<Float>(0, localY, 0))
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

        // Offsets are relative to node 0 (world (0, 1, 0)); this places the
        // sphere so joints 2 and 3 rest inside it and stay in contact.
        let shape = VRMColliderShape.sphere(offset: SIMD3<Float>(0.02, -0.25, 0), radius: 0.08)

        var springBone = VRMSpringBone()
        switch layout {
        case .none:
            springBone.colliders = []
            springBone.colliderGroups = []
        case .shared:
            springBone.colliders = [VRMCollider(node: 0, shape: shape)]
            springBone.colliderGroups = [
                VRMColliderGroup(name: "G0", colliders: [0]),
                VRMColliderGroup(name: "G1", colliders: [0]),
            ]
        case .perGroup:
            springBone.colliders = [
                VRMCollider(node: 0, shape: shape),
                VRMCollider(node: 0, shape: shape),
            ]
            springBone.colliderGroups = [
                VRMColliderGroup(name: "G0", colliders: [0]),
                VRMColliderGroup(name: "G1", colliders: [1]),
            ]
        }

        var joints: [VRMSpringJoint] = []
        for i in 0..<boneCount {
            var joint = VRMSpringJoint(node: i)
            joint.hitRadius = 0.02
            joint.stiffness = 0.5
            joint.gravityPower = 0.5
            joint.gravityDir = SIMD3<Float>(0, -1, 0)
            joint.dragForce = 0.4
            joints.append(joint)
        }
        var spring = VRMSpring(name: "TestSpring")
        spring.joints = joints
        // References BOTH groups (none exist in the `.none` control, which
        // leaves the mask at the collide-with-everything default — so nothing
        // but the absent dispatch suppresses collision there).
        spring.colliderGroups = layout == .none ? [] : [0, 1]
        springBone.springs = [spring]
        model.springBone = springBone
        model.device = device

        let sphereCount = springBone.colliders.count
        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: boneCount, numSpheres: sphereCount,
                                numCapsules: 0, numPlanes: 0)
        model.springBoneBuffers = buffers

        model.springBoneGlobalParams = SpringBoneGlobalParams(
            gravity: SIMD3<Float>(0, -9.8, 0),
            dtSub: Float(1.0 / 120.0),
            windAmplitude: 0.0,
            windFrequency: 0.0,
            windPhase: 0.0,
            windDirection: SIMD3<Float>(1, 0, 0),
            substeps: 1,
            numBones: UInt32(boneCount),
            numSpheres: UInt32(sphereCount),
            numCapsules: 0,
            numPlanes: 0
        )
        return model
    }

    private func makeGLTFNode(name: String, translation: SIMD3<Float>) throws -> GLTFNode {
        let json = """
        {
            "name": "\(name)",
            "translation": [\(translation.x), \(translation.y), \(translation.z)],
            "rotation": [0.0, 0.0, 0.0, 1.0],
            "scale": [1.0, 1.0, 1.0]
        }
        """
        return try JSONDecoder().decode(GLTFNode.self, from: json.data(using: .utf8)!)
    }

    private func simulate(_ model: VRMModel, frames: Int) throws -> [SIMD3<Float>] {
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)
        for _ in 0..<frames {
            guard let cb = commandQueue.makeCommandBuffer() else {
                throw XCTSkip("Could not create command buffer")
            }
            system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: cb)
            cb.commit()
            cb.waitUntilCompleted()
        }
        guard let buffers = model.springBoneBuffers, let pos = buffers.bonePosCurr else { return [] }
        let ptr = pos.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
        return Array(UnsafeBufferPointer(start: ptr, count: buffers.numBones))
    }

    private func uploadedSpheres(_ model: VRMModel) throws -> [SphereCollider] {
        let buffers = try XCTUnwrap(model.springBoneBuffers)
        let buffer = try XCTUnwrap(buffers.sphereColliders)
        let ptr = buffer.contents().bindMemory(to: SphereCollider.self, capacity: buffers.numSpheres)
        return Array(UnsafeBufferPointer(start: ptr, count: buffers.numSpheres))
    }

    // MARK: - Control: the two variants really do upload different buffers

    /// Guards the measurement below against passing trivially. If both variants
    /// uploaded the same buffer, equal bone positions would prove nothing.
    func testVariantsUploadStructurallyDifferentColliderBuffers() throws {
        let deduped = try buildChain(.shared)
        let perGroup = try buildChain(.perGroup)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: deduped)
        let system2 = try SpringBoneComputeSystem(device: device)
        try system2.populateSpringBoneData(model: perGroup)

        let a = try uploadedSpheres(deduped)
        let b = try uploadedSpheres(perGroup)

        XCTAssertEqual(a.count, 1, "today's upload: one entry for the shared collider")
        XCTAssertEqual(a[0].groupMask, 0b11,
                       "today's entry carries the OR of both memberships")

        XCTAssertEqual(b.count, 2, "per-group upload: one entry per (group, collider) membership")
        XCTAssertEqual(b[0].groupMask, 0b01, "first entry carries only group 0's bit")
        XCTAssertEqual(b[1].groupMask, 0b10, "second entry carries only group 1's bit")

        // Same geometry in both — only the count and the masks differ.
        XCTAssertEqual(a[0].center, b[0].center)
        XCTAssertEqual(a[0].radius, b[0].radius)
        XCTAssertEqual(b[0].center, b[1].center)
    }

    /// The bone must actually be in contact, or "no difference" would just mean
    /// "no collision happened".
    ///
    /// The control allocates zero sphere slots rather than muting a collider,
    /// so the collide kernel is never dispatched. Muting via
    /// `springBoneGlobalParams.numSpheres` would not work — `update()`
    /// recomputes that field from `buffers.numSpheres` every substep — and
    /// clearing `springBone.colliders` alone leaves an allocated, never-written
    /// sphere slot that the kernel still reads.
    func testColliderIsEngaged() throws {
        let withCollider = try simulate(try buildChain(.shared), frames: 60)
        let without = try simulate(try buildChain(.none), frames: 60)

        XCTAssertEqual(withCollider.count, without.count)
        let moved = zip(withCollider, without).map { simd_distance($0, $1) }.max() ?? 0
        XCTAssertGreaterThan(moved, 1e-4,
            "the collider must visibly move at least one joint, otherwise the "
            + "dedup measurement below is vacuous (max delta \(moved))")
    }

    // MARK: - The measurement

    /// Applying the same collider once per referenced group lands the joint in
    /// exactly the same place as applying it once, because VMK's push-out is an
    /// idempotent projection onto the collider surface and no length constraint
    /// runs between two colliders in a pass.
    ///
    /// If this test ever FAILS, the solver has gained a per-collider constraint
    /// that makes repeated application meaningful — at which point #415's fix
    /// becomes both implementable and observable, and this test should be
    /// inverted into the acceptance test the issue specifies.
    func testPerGroupDuplicationDoesNotChangeSimulationResult() throws {
        let deduped = try simulate(try buildChain(.shared), frames: 60)
        let perGroup = try simulate(try buildChain(.perGroup), frames: 60)

        XCTAssertEqual(deduped.count, perGroup.count)
        XCTAssertFalse(deduped.isEmpty, "simulation produced no bone positions")

        var maxDelta: Float = 0
        for (i, (a, b)) in zip(deduped, perGroup).enumerated() {
            let delta = simd_distance(a, b)
            maxDelta = max(maxDelta, delta)
            XCTAssertLessThan(delta, 1e-6,
                "joint \(i): duplicating the collider per group moved it by \(delta) m — "
                + "if this is a real change, #415's premise holds for VMK after all")
        }
        print("[#415] max joint delta, dedup vs per-group upload: \(maxDelta) m")
    }

    /// The conformance runner excites the chain (swing) rather than measuring it
    /// at rest, so the resting-contact measurement above is not on its own
    /// enough. This drives the chain root laterally each frame — joints sweep
    /// through the collider at speed — and measures the same two uploads.
    ///
    /// Still no difference: VMK's push-out is a projection onto the collider
    /// surface regardless of incoming velocity, and the swept (CCD) branch is
    /// scoped to the synthetic group, which this rig (like the conformance
    /// asset, `augment_colliders: false`) does not have.
    func testPerGroupDuplicationIsInertUnderSwingExcitation() throws {
        func swing(_ model: VRMModel, frames: Int) throws -> [SIMD3<Float>] {
            let system = try SpringBoneComputeSystem(device: device)
            try system.populateSpringBoneData(model: model)
            for f in 0..<frames {
                // Drive the kinematic root through a lateral sweep.
                let t = Float(f) / 60.0
                let root = model.nodes[0]
                root.translation = SIMD3<Float>(0.12 * sin(t * 8.0), 1.0, 0)
                root.updateWorldTransform()
                guard let cb = commandQueue.makeCommandBuffer() else {
                    throw XCTSkip("Could not create command buffer")
                }
                system.update(model: model, deltaTime: 1.0 / 60.0, commandBuffer: cb)
                cb.commit()
                cb.waitUntilCompleted()
            }
            guard let buffers = model.springBoneBuffers, let pos = buffers.bonePosCurr else { return [] }
            let ptr = pos.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
            return Array(UnsafeBufferPointer(start: ptr, count: buffers.numBones))
        }

        let deduped = try swing(try buildChain(.shared), frames: 90)
        let perGroup = try swing(try buildChain(.perGroup), frames: 90)

        XCTAssertFalse(deduped.isEmpty, "simulation produced no bone positions")
        var maxDelta: Float = 0
        for (i, (a, b)) in zip(deduped, perGroup).enumerated() {
            let delta = simd_distance(a, b)
            maxDelta = max(maxDelta, delta)
            XCTAssertLessThan(delta, 1e-6,
                "joint \(i): under swing excitation, per-group duplication moved it by \(delta) m")
        }
        print("[#415] max joint delta under swing, dedup vs per-group upload: \(maxDelta) m")
    }

    // MARK: - Where per-group application WOULD bite: ordering, not repetition

    /// Two overlapping colliders, `X` in both referenced groups and `Y` in the
    /// first only. Three uploads of the same scene:
    ///
    ///   A  dedup (today)              [X(0b11), Y(0b01)]
    ///   B  per-group, collider-major  [X(0b01), X(0b10), Y(0b01)]
    ///   C  per-group, group-major     [X(0b01), Y(0b01), X(0b10)]   <- UniVRM's order
    ///
    /// B keeps the repeats adjacent, so the second `X` still resolves a joint
    /// that nothing has moved since — inert, exactly as in the single-collider
    /// case. C is the order UniVRM's `.SelectMany(group => group.Colliders)`
    /// produces: `Y` pushes the joint back into `X` before `X` is applied again,
    /// so the trailing entry does real work.
    ///
    /// This is what actually separates the reference behaviour from VMK's on a
    /// real avatar — collider *ordering*, not the repetition itself.
    func testGroupMajorOrderingIsWhatMakesRepetitionObservable() throws {
        func buildOverlapping(colliders: [(offsetX: Float, group: Int)],
                              groupCount: Int) throws -> VRMModel {
            let builder = VRMBuilder()
            let model = try builder.setSkeleton(.defaultHumanoid).build()
            model.nodes.removeAll()
            var previousNode: VRMNode? = nil
            for i in 0..<4 {
                let localY: Float = (i == 0) ? 1.0 : -0.1
                let gltfNode = try makeGLTFNode(name: "joint_\(i)", translation: SIMD3<Float>(0, localY, 0))
                let node = VRMNode(index: i, gltfNode: gltfNode)
                if let parent = previousNode { node.parent = parent; parent.children.append(node) }
                model.nodes.append(node)
                previousNode = node
            }
            for node in model.nodes where node.parent == nil { node.updateWorldTransform() }

            var springBone = VRMSpringBone()
            var groups: [[Int]] = Array(repeating: [], count: groupCount)
            for (i, c) in colliders.enumerated() {
                springBone.colliders.append(VRMCollider(
                    node: 0,
                    shape: .sphere(offset: SIMD3<Float>(c.offsetX, -0.2, 0), radius: 0.06)))
                groups[c.group].append(i)
            }
            springBone.colliderGroups = groups.enumerated().map {
                VRMColliderGroup(name: "G\($0.offset)", colliders: $0.element)
            }

            var joints: [VRMSpringJoint] = []
            for i in 0..<4 {
                var joint = VRMSpringJoint(node: i)
                joint.hitRadius = 0.02
                joint.stiffness = 0.5
                joint.gravityPower = 0.5
                joint.gravityDir = SIMD3<Float>(0, -1, 0)
                joint.dragForce = 0.4
                joints.append(joint)
            }
            var spring = VRMSpring(name: "TestSpring")
            spring.joints = joints
            spring.colliderGroups = Array(0..<groupCount)
            springBone.springs = [spring]
            model.springBone = springBone
            model.device = device

            let n = colliders.count
            let buffers = SpringBoneBuffers(device: device)
            buffers.allocateBuffers(numBones: 4, numSpheres: n, numCapsules: 0, numPlanes: 0)
            model.springBoneBuffers = buffers
            model.springBoneGlobalParams = SpringBoneGlobalParams(
                gravity: SIMD3<Float>(0, -9.8, 0), dtSub: Float(1.0 / 120.0),
                windAmplitude: 0, windFrequency: 0, windPhase: 0,
                windDirection: SIMD3<Float>(1, 0, 0), substeps: 1,
                numBones: 4, numSpheres: UInt32(n), numCapsules: 0, numPlanes: 0)
            return model
        }

        // X at +0.05, Y at -0.05 — overlapping, so push-out from one re-enters the other.
        let a = try buildOverlapping(colliders: [(0.05, 0), (-0.05, 0)], groupCount: 2)
        a.springBone?.colliderGroups[1] = VRMColliderGroup(name: "G1", colliders: [0])  // X also in group 1
        let b = try buildOverlapping(colliders: [(0.05, 0), (0.05, 1), (-0.05, 0)], groupCount: 2)
        let c = try buildOverlapping(colliders: [(0.05, 0), (-0.05, 0), (0.05, 1)], groupCount: 2)

        let posA = try simulate(a, frames: 90)
        let posB = try simulate(b, frames: 90)
        let posC = try simulate(c, frames: 90)

        let deltaAB = zip(posA, posB).map { simd_distance($0, $1) }.max() ?? 0
        let deltaAC = zip(posA, posC).map { simd_distance($0, $1) }.max() ?? 0
        print("[#415] overlapping colliders — dedup vs collider-major: \(deltaAB) m, dedup vs group-major: \(deltaAC) m")

        XCTAssertLessThan(deltaAB, 1e-6,
            "collider-major duplication keeps the repeats adjacent, so it stays inert")
        XCTAssertGreaterThan(deltaAC, 1e-5,
            "group-major duplication (UniVRM's order) interleaves the repeat after another "
            + "collider has moved the joint, so it must do real work — if this is inert too, "
            + "the ordering analysis in #415's response is wrong")
    }
}
