// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// TDD-style tests for SpringBone bugs identified in issue #138 that PR #139
/// (the first RED batch) does not cover. This is the second RED batch and asserts
/// CORRECT behavior — these tests are expected to FAIL until the bugs are fixed.
///
/// Coverage:
///   - Bug #4: Kinematic kernel uses bonePosCurr as previous-position history.
///   - Bug #6: Inertia compensation block is commented out in SpringBonePredict.metal.
///   - Bug #7: Collider groupIndex >= 32 triggers bit-shift undefined behavior.
///
/// Bug #11 (externalVelocity never populated) is intentionally not in this batch:
/// its fix requires API design, not just a behavioral assertion. Once an API for
/// feeding character velocity into the spring system exists, a follow-up test
/// should assert it propagates into globalParams.externalVelocity.
///
/// GPU synchronization: tests pass a host-owned MTLCommandBuffer to
/// `SpringBoneComputeSystem.update(...)` so the system encodes work without
/// committing, and the test commits + `waitUntilCompleted()` for deterministic
/// readback — no `Thread.sleep`.
final class SpringBoneBugAuditTDDBatch2Tests: XCTestCase {

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

    // MARK: - Helpers

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

    /// Build a minimal model whose `nodes` are exactly the names/translations supplied.
    /// Each node `i` is parented to node `i-1` (single chain) and gets its world transform
    /// computed. Returns the model with `device` set.
    private func makeChainModel(names: [String], translations: [SIMD3<Float>]) throws -> VRMModel {
        precondition(names.count == translations.count, "names and translations must match")
        let model = try VRMBuilder().setSkeleton(.defaultHumanoid).build()
        model.nodes.removeAll()
        var previous: VRMNode?
        for (i, name) in names.enumerated() {
            let gltf = try createGLTFNode(name: name, translation: translations[i])
            let node = VRMNode(index: i, gltfNode: gltf)
            if let prev = previous {
                node.parent = prev
                prev.children.append(node)
            }
            model.nodes.append(node)
            previous = node
        }
        for n in model.nodes { n.updateWorldTransform() }
        model.device = device
        return model
    }

    private func readBonePosition(model: VRMModel, boneIndex: Int) -> SIMD3<Float> {
        guard let buffers = model.springBoneBuffers,
              boneIndex < buffers.numBones,
              let buf = buffers.bonePosCurr else { return .zero }
        let ptr = buf.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
        return ptr[boneIndex]
    }

    private func readBonePrevPosition(model: VRMModel, boneIndex: Int) -> SIMD3<Float> {
        guard let buffers = model.springBoneBuffers,
              boneIndex < buffers.numBones,
              let buf = buffers.bonePosPrev else { return .zero }
        let ptr = buf.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
        return ptr[boneIndex]
    }

    /// Note: `substeps` and `numSpheres` here populate `SpringBoneGlobalParams` for the
    /// shaders, but the runtime substep count actually comes from `update(deltaTime:)`
    /// against `quality.substepRateHz`. With `deltaTime = 1/60` and the default 120Hz
    /// rate, each `update()` runs ~2 substeps — enough to expose Bug #4's stomping.
    private func makeGlobalParams(numBones: Int, numSpheres: UInt32 = 0) -> SpringBoneGlobalParams {
        SpringBoneGlobalParams(
            gravity: SIMD3<Float>(0, -9.8, 0),
            dtSub: Float(1.0 / 120.0),
            windAmplitude: 0.0,
            windFrequency: 0.0,
            windPhase: 0.0,
            windDirection: SIMD3<Float>(1, 0, 0),
            substeps: 1,
            numBones: UInt32(numBones),
            numSpheres: numSpheres,
            numCapsules: 0,
            numPlanes: 0,
            settlingFrames: 0
        )
    }

    /// Drive the compute system through one frame using a host-owned command buffer
    /// and block until the GPU has finished. Replaces `Thread.sleep` with deterministic
    /// synchronization.
    private func runFrame(system: SpringBoneComputeSystem, model: VRMModel,
                          deltaTime: TimeInterval = 1.0 / 60.0) throws {
        guard let cb = commandQueue.makeCommandBuffer() else {
            throw XCTSkip("Could not create command buffer")
        }
        system.update(model: model, deltaTime: deltaTime, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
    }

    // MARK: - Bug #4: Kinematic kernel uses bonePosCurr as previous-position history

    /// `SpringBoneKinematic.metal` reads `previousPos = bonePosCurr[boneIndex]` and
    /// writes that into `bonePosPrev[boneIndex]`. Because the kernel runs once per
    /// substep and writes `bonePosCurr = animatedPos`, every substep after the first
    /// stomps `bonePosPrev` with the *current* animated position, destroying the
    /// previous-frame velocity history.
    ///
    /// Correct behavior: `bonePosPrev[root]` must reflect the **previous frame's**
    /// animated position so velocity = curr - prev is meaningful for downstream
    /// inertia compensation (Bug #6) and any future child-bone effects that read
    /// root velocity.
    ///
    /// Architecturally, this requires a separate animated-position history buffer
    /// (per the issue #138 fix recommendation), not just relying on Bug #3 to keep
    /// `bonePosCurr[root]` clean.
    func testRootBonePrevPositionTracksPreviousAnimatedFrameNotCurrentSubstep() throws {
        let model = try makeChainModel(
            names: ["A", "B"],
            translations: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, -1, 0)]
        )

        var joints: [VRMSpringJoint] = []
        for i in 0..<2 {
            var j = VRMSpringJoint(node: i)
            j.hitRadius = 0.02
            j.stiffness = 0.0
            j.gravityPower = 0.0
            j.dragForce = 0.0
            joints.append(j)
        }
        var spring = VRMSpring(name: "Test")
        spring.joints = joints
        var sb = VRMSpringBone()
        sb.springs = [spring]
        model.springBone = sb

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 2, numSpheres: 0, numCapsules: 0)
        model.springBoneBuffers = buffers
        model.springBoneGlobalParams = makeGlobalParams(numBones: 2)

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        // Establish a clean baseline before frame 1 so the test isn't sensitive to
        // whatever populateSpringBoneData left in bonePosCurr/bonePosPrev.
        if let curr = buffers.bonePosCurr, let prev = buffers.bonePosPrev,
           let rest = buffers.restLengths {
            let c = curr.contents().bindMemory(to: SIMD3<Float>.self, capacity: 2)
            let p = prev.contents().bindMemory(to: SIMD3<Float>.self, capacity: 2)
            let r = rest.contents().bindMemory(to: Float.self, capacity: 2)
            c[0] = SIMD3<Float>(0, 0, 0); p[0] = c[0]
            c[1] = SIMD3<Float>(0, -1, 0); p[1] = c[1]
            r[1] = 1.0
        }

        let nodeA = model.nodes[0]

        // Frame 1: root at (0, 0, 0). Settle history.
        nodeA.translation = SIMD3<Float>(0, 0, 0)
        nodeA.updateLocalMatrix()
        nodeA.updateWorldTransform()
        try runFrame(system: system, model: model)

        // Frame 2: root jumps to (1, 0, 0). Animated delta = (1, 0, 0).
        nodeA.translation = SIMD3<Float>(1, 0, 0)
        nodeA.updateLocalMatrix()
        nodeA.updateWorldTransform()
        try runFrame(system: system, model: model)

        let curr = readBonePosition(model: model, boneIndex: 0)
        let prev = readBonePrevPosition(model: model, boneIndex: 0)
        let velocity = curr - prev

        // Correct: prev[0] = previous frame's animated (0,0,0) → velocity ≈ (1,0,0).
        // Buggy: prev[0] stomped to current animated (1,0,0) → velocity ≈ 0.
        XCTAssertGreaterThan(simd_length(velocity), 0.5,
            "Root bone velocity (curr - prev) should be ~1 m/frame after the root " +
            "moves from (0,0,0) to (1,0,0) between two frames. " +
            "Got curr=\(curr), prev=\(prev), velocity=\(velocity). " +
            "Bug #4: SpringBoneKinematic.metal reads previousPos from bonePosCurr, " +
            "which it then overwrites — and because the kernel runs every substep, " +
            "after substep 2+ bonePosPrev is stomped with the *current* animated " +
            "position. Fix: maintain a separate animated-position history buffer " +
            "for root bones so bonePosPrev[root] tracks the previous frame.")
    }

    // MARK: - Bug #6: Inertia compensation block is commented out

    /// `SpringBonePredict.metal` lines 121–141 contain a block of inertia-compensation
    /// logic wrapped in `/* ... */` behind a "INERTIA COMPENSATION DISABLED FOR DEBUGGING"
    /// marker. Without it, child bones rigidly follow the parent during fast motion
    /// (e.g. head turns, jumps) instead of trailing naturally.
    ///
    /// The spec is unambiguous: re-enable the block. A behavioral test of trailing is
    /// hard to write robustly because hard distance constraints partially mask the
    /// effect; the source-level invariant — "the disabled marker must be gone" — is
    /// the cleanest guarantee that the fix actually shipped.
    func testInertiaCompensationBlockIsLiveCodeNotCommentedOut() throws {
        let shaderURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // VRMMetalKitTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/VRMMetalKit/Shaders/SpringBonePredict.metal")

        let source = try String(contentsOf: shaderURL, encoding: .utf8)

        XCTAssertFalse(source.contains("INERTIA COMPENSATION DISABLED FOR DEBUGGING"),
            "Bug #6: SpringBonePredict.metal still contains the 'INERTIA COMPENSATION " +
            "DISABLED FOR DEBUGGING' marker. The block at lines ~121-141 (currently " +
            "wrapped in /* */) must be re-enabled so long bone chains trail behind " +
            "fast parent movement instead of rigidly following. The original disable " +
            "was reportedly to debug flutter — re-evaluate after Bugs #3/#4 are fixed " +
            "(per issue #138, those may have been the underlying cause of the flutter).")
    }

    // MARK: - Bug #7: Collider groupIndex >= 32 triggers bit-shift undefined behavior

    /// `SpringBoneCollision.metal` does `1u << sphere.groupIndex` to build a per-collider
    /// group bitmask. Per Metal C++ (and the underlying SPIR-V/MSL semantics), shifting
    /// a 32-bit value by 32 or more is undefined behavior. The collider's `groupIndex`
    /// is plumbed through unclamped from Swift, so a model with 33 or more collider
    /// groups silently corrupts collision filtering.
    ///
    /// Both candidate fixes (Swift-side clamp to `0...31`, or shader-side
    /// `if (groupIndex >= 32) continue;`) leave a bone in group 0 unaffected by an
    /// out-of-range collider whose group bit cannot fit in the bone's mask. This test
    /// asserts that observable invariant.
    func testBoneInGroup0NotAffectedByColliderWithGroupIndexAbove31() throws {
        let model = try makeChainModel(
            names: ["A", "B"],
            translations: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 1, 0)]
        )

        // 33 colliders. Indices 0..31 are placed far away (irrelevant). Index 32 is
        // placed overlapping bone B — this is the out-of-range one whose `1u << 32`
        // shift is UB. The sphere is offset along +X from the bone so the collision
        // normal has a defined direction (a sphere centered exactly on the bone yields
        // zero push because `toCenter / |toCenter|` is undefined at the center).
        let groupCount = 33
        var colliders: [VRMCollider] = []
        for i in 0..<groupCount {
            let offset: SIMD3<Float> = (i == 32)
                ? SIMD3<Float>(0.1, 1, 0)            // overlap B with defined normal
                : SIMD3<Float>(100, 100, 100)         // far away
            colliders.append(VRMCollider(node: 0, shape: .sphere(offset: offset, radius: 0.3)))
        }
        let groups: [VRMColliderGroup] = (0..<groupCount).map { i in
            VRMColliderGroup(name: "Group_\(i)", colliders: [i])
        }

        var joints: [VRMSpringJoint] = []
        for i in 0..<2 {
            var j = VRMSpringJoint(node: i)
            j.hitRadius = 0.1
            j.stiffness = 0.0
            j.gravityPower = 0.0
            j.dragForce = 0.0
            joints.append(j)
        }
        var spring = VRMSpring(name: "Test")
        spring.joints = joints
        // Bone collides ONLY with group index 0 of the spring's known groups, so its
        // bone-mask bit is `1 << 0 = 1` and an in-bounds collider in any other group
        // would not touch it. The bug is that `1u << 32` is UB, so the sphere in
        // group 32 may slip through anyway.
        spring.colliderGroups = [0]

        var sb = VRMSpringBone()
        sb.springs = [spring]
        sb.colliders = colliders
        sb.colliderGroups = groups
        model.springBone = sb

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: 2, numSpheres: groupCount, numCapsules: 0)
        model.springBoneBuffers = buffers
        model.springBoneGlobalParams = makeGlobalParams(numBones: 2, numSpheres: UInt32(groupCount))

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        if let rest = buffers.restLengths {
            let r = rest.contents().bindMemory(to: Float.self, capacity: 2)
            r[1] = 1.0
        }

        let initialB = readBonePosition(model: model, boneIndex: 1)
        try runFrame(system: system, model: model)
        let finalB = readBonePosition(model: model, boneIndex: 1)
        let displacement = simd_length(finalB - initialB)

        XCTAssertLessThan(displacement, 0.05,
            "Bone whose collider mask contains only group 0 must not be displaced " +
            "by an overlapping collider in group 32. " +
            "Initial: \(initialB), final: \(finalB), displacement: \(displacement). " +
            "Bug #7: `1u << 32` is undefined behavior in Metal C++; on Apple GPUs " +
            "the LSL instruction takes the low 5 bits of the shift amount, so the " +
            "out-of-range bit collides with the bone's group-0 bit and the sphere " +
            "leaks through the filter. Fix: clamp groupIndex to 0...31 in Swift " +
            "before populating colliders, OR add `if (groupIndex >= 32) continue;` " +
            "at the top of each collide* helper in SpringBoneCollision.metal before " +
            "the shift.")
    }
}
