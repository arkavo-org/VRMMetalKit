// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Tests documenting SpringBone settling failures.
///
/// These tests reproduce scenarios where hair/cloth physics fails to return
/// to rest position after disturbance due to drag/stiffness imbalance.
///
/// ## Root Cause Analysis
///
/// The physics has three competing forces:
/// 1. **Gravity** - pulls bones down
/// 2. **Drag** - resists velocity (damping)
/// 3. **Stiffness** - pulls toward bind pose
///
/// ### The Imbalance Problem
///
/// When drag is high (0.4-0.5) and stiffness is low (0.0-0.2):
/// - After a disturbance (jump/land), bones have velocity
/// - High drag quickly kills the velocity
/// - Low stiffness provides negligible return force
/// - Result: bones freeze in "disturbed" state
///
/// ### Expected vs Actual Behavior
///
/// **Expected**: After jump, hair trails behind, then smoothly returns to rest
/// **Actual**: Hair trails behind, then freezes at displaced position
///
/// ### The Math
///
/// Per-frame velocity update: `velocity *= (1 - drag)`
/// With drag=0.4: velocity drops to 0.6^N after N frames
/// - After 10 frames: 0.6^10 = 0.006 (99.4% velocity lost)
/// - After 20 frames: 0.6^20 = 0.00004 (effectively zero)
///
/// Stiffness correction per frame: `correction = (target - current) * stiffness`
/// With stiffness=0.1: only 10% of displacement corrected per frame
/// - But this creates velocity that drag immediately kills
/// - Net effect: ~1% actual movement toward target
///
final class SpringBoneSettlingFailureTests: XCTestCase {

    var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    // MARK: - Jump and Land Scenario

    /// **FAILURE CASE**: Hair freezes after jump disturbance
    ///
    /// This test simulates a character jumping and landing:
    /// 1. Character at rest (hair hanging naturally)
    /// 2. Jump UP (hair trails behind/down due to inertia)
    /// 3. Land (hair should swing back up, then settle)
    /// 4. Wait for settling (hair should return to rest position)
    ///
    /// **Expected**: Hair returns to within 10% of rest position after 120 frames
    /// **Actual (BUG)**: Hair remains frozen at displaced position
    func testJumpAndLand_HairShouldReturnToRest() throws {
        // Setup: 5-bone vertical hair chain with typical VRM parameters
        let model = try buildHairChain(
            boneCount: 5,
            stiffness: 0.1,      // Low stiffness (typical VRM)
            drag: 0.4,           // High drag (typical VRM)
            gravityPower: 1.0,
            settlingFrames: 0    // No settling period - we want to test post-disturbance behavior
        )
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        guard let rootNode = model.nodes.first else {
            XCTFail("No root node")
            return
        }

        // Phase 1: Let hair reach equilibrium (60 frames at rest)
        print("=== Phase 1: Initial Equilibrium ===")
        for _ in 0..<60 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }
        Thread.sleep(forTimeInterval: 0.1)
        system.writeBonesToNodes(model: model)

        let restPositions = readBonePositions(model: model)
        let restTipY = restPositions.last?.y ?? 0
        print("Rest position tip Y: \(restTipY)")

        // Phase 2: Jump UP (10 frames, 0.5m total displacement)
        print("\n=== Phase 2: Jump (Moving UP) ===")
        let jumpHeight: Float = 0.5
        let jumpFrames = 10
        for frame in 0..<jumpFrames {
            let progress = Float(frame + 1) / Float(jumpFrames)
            rootNode.translation = SIMD3<Float>(0, 1.0 + jumpHeight * progress, 0)
            rootNode.updateLocalMatrix()
            rootNode.updateWorldTransform()
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }
        Thread.sleep(forTimeInterval: 0.05)
        system.writeBonesToNodes(model: model)

        let jumpPeakPositions = readBonePositions(model: model)
        let peakTipY = jumpPeakPositions.last?.y ?? 0
        let tipLagAtPeak = (1.0 + jumpHeight) - peakTipY  // How much tip trails behind root
        print("Jump peak - Root Y: \(1.0 + jumpHeight), Tip Y: \(peakTipY), Tip lag: \(tipLagAtPeak)")

        // Phase 3: Land (10 frames, return to original height)
        print("\n=== Phase 3: Land (Moving DOWN) ===")
        for frame in 0..<jumpFrames {
            let progress = Float(frame + 1) / Float(jumpFrames)
            rootNode.translation = SIMD3<Float>(0, 1.0 + jumpHeight * (1.0 - progress), 0)
            rootNode.updateLocalMatrix()
            rootNode.updateWorldTransform()
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }
        Thread.sleep(forTimeInterval: 0.05)
        system.writeBonesToNodes(model: model)

        let landPositions = readBonePositions(model: model)
        let landTipY = landPositions.last?.y ?? 0
        print("Land - Root Y: 1.0, Tip Y: \(landTipY)")

        // Phase 4: Wait for settling (120 frames at rest)
        print("\n=== Phase 4: Settling (Should Return to Rest) ===")
        var settlingHistory: [(frame: Int, tipY: Float, deltaFromRest: Float)] = []

        for frame in 0..<120 {
            system.update(model: model, deltaTime: 1.0 / 60.0)

            if frame % 20 == 0 || frame == 119 {
                Thread.sleep(forTimeInterval: 0.02)
                system.writeBonesToNodes(model: model)
                let positions = readBonePositions(model: model)
                let tipY = positions.last?.y ?? 0
                let deltaFromRest = tipY - restTipY
                settlingHistory.append((frame, tipY, deltaFromRest))
                print("  Frame \(frame): Tip Y = \(String(format: "%.4f", tipY)), " +
                      "Delta from rest = \(String(format: "%.4f", deltaFromRest))")
            }
        }

        // Final assessment
        let finalTipY = settlingHistory.last?.tipY ?? 0
        let finalDeltaFromRest = abs(finalTipY - restTipY)
        let restLength = abs(restPositions[0].y - restTipY)  // Total chain length
        let percentDisplacement = (finalDeltaFromRest / max(restLength, 0.01)) * 100

        print("\n=== Results ===")
        print("Rest tip Y: \(restTipY)")
        print("Final tip Y: \(finalTipY)")
        print("Final delta from rest: \(finalDeltaFromRest)")
        print("Chain length: \(restLength)")
        print("Displacement: \(String(format: "%.1f", percentDisplacement))% of chain length")

        // The test: hair should return to within 10% of rest position
        // With current bug, it typically remains 30-50% displaced
        XCTAssertLessThan(
            percentDisplacement, 10.0,
            """
            SETTLING FAILURE: Hair did not return to rest position after jump!

            Expected: < 10% displacement from rest
            Actual: \(String(format: "%.1f", percentDisplacement))% displacement

            This indicates drag is overwhelming stiffness - velocity dies before
            stiffness force can return hair to rest position.

            Possible fixes:
            1. Use proper PBD stiffness: correction = (target - current) * stiffness
            2. Reduce drag or make it dt-scaled: velocity *= (1 - drag * dt)
            3. Apply stiffness as position correction, not velocity impulse
            """
        )
    }

    /// **DIAGNOSTIC**: Measure velocity decay rate
    ///
    /// This test quantifies how quickly drag kills velocity,
    /// demonstrating why stiffness can't overcome it.
    func testVelocityDecayRate() throws {
        let model = try buildHairChain(
            boneCount: 3,
            stiffness: 0.0,      // No stiffness - isolate drag effect
            drag: 0.4,
            gravityPower: 0.0,   // No gravity - isolate drag effect
            settlingFrames: 0
        )
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        guard let buffers = model.springBoneBuffers,
              let bonePosPrev = buffers.bonePosPrev,
              let bonePosCurr = buffers.bonePosCurr else {
            XCTFail("No buffers")
            return
        }

        // Give tip bone initial velocity by displacing it
        let currPtr = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
        let prevPtr = bonePosPrev.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)

        // Set initial velocity of 0.1 m/frame for bone 2 (tip)
        let tipIndex = 2
        let initialVelocity: Float = 0.1
        prevPtr[tipIndex] = currPtr[tipIndex] - SIMD3<Float>(0, initialVelocity, 0)

        print("=== Velocity Decay Test (drag=0.4, no gravity, no stiffness) ===")
        print("Initial velocity: \(initialVelocity) m/frame")
        print("Expected decay: velocity *= (1 - drag) = 0.6 per frame")
        print("")

        var velocities: [Float] = []
        for frame in 0..<20 {
            system.update(model: model, deltaTime: 1.0 / 60.0)

            let velocity = currPtr[tipIndex] - prevPtr[tipIndex]
            let speed = length(velocity)
            velocities.append(speed)

            let theoreticalSpeed = initialVelocity * pow(0.6, Float(frame + 1))
            print("Frame \(String(format: "%2d", frame)): " +
                  "actual=\(String(format: "%.6f", speed)), " +
                  "theoretical=\(String(format: "%.6f", theoreticalSpeed)), " +
                  "ratio=\(String(format: "%.2f", speed / max(theoreticalSpeed, 0.0001)))")
        }

        // After 10 frames, velocity should be ~0.6% of initial
        let frame10Velocity = velocities[9]
        let expectedFrame10 = initialVelocity * pow(0.6, 10)  // ~0.0006
        print("\nAfter 10 frames: \(String(format: "%.6f", frame10Velocity)) " +
              "(expected ~\(String(format: "%.6f", expectedFrame10)))")
        print("Velocity remaining: \(String(format: "%.2f", (frame10Velocity / initialVelocity) * 100))%")
    }

    /// **DIAGNOSTIC**: Measure stiffness correction effectiveness
    ///
    /// This test shows how much position correction stiffness provides
    /// when fighting against drag.
    func testStiffnessVsDragBalance() throws {
        // Test different stiffness values with constant drag
        let dragValue: Float = 0.4
        let stiffnessValues: [Float] = [0.0, 0.1, 0.2, 0.5, 0.8, 1.0]

        print("=== Stiffness vs Drag Balance Test ===")
        print("Drag: \(dragValue)")
        print("Initial displacement: 0.2m from rest position")
        print("Frames to simulate: 60")
        print("")

        for stiffness in stiffnessValues {
            let model = try buildHairChain(
                boneCount: 3,
                stiffness: stiffness,
                drag: dragValue,
                gravityPower: 0.0,  // No gravity - test only stiffness vs drag
                settlingFrames: 0
            )
            let system = try SpringBoneComputeSystem(device: device)
            try system.populateSpringBoneData(model: model)

            // Displace tip bone from rest position
            guard let buffers = model.springBoneBuffers,
                  let bonePosCurr = buffers.bonePosCurr else { continue }

            let currPtr = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
            let restY = currPtr[2].y
            let displacement: Float = 0.2
            currPtr[2].y = restY + displacement  // Displace upward

            // Run 60 frames
            for _ in 0..<60 {
                system.update(model: model, deltaTime: 1.0 / 60.0)
            }

            // Measure final displacement
            let finalY = currPtr[2].y
            let finalDisplacement = finalY - restY
            let percentReturned = ((displacement - abs(finalDisplacement)) / displacement) * 100

            print("Stiffness \(String(format: "%.1f", stiffness)): " +
                  "final displacement = \(String(format: "%.4f", finalDisplacement))m, " +
                  "returned \(String(format: "%.1f", percentReturned))% to rest")
        }
    }

    /// **DIAGNOSTIC**: Compare different drag values
    func testDragImpactOnSettling() throws {
        let stiffness: Float = 0.2
        let dragValues: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.8]

        print("=== Drag Impact on Settling Test ===")
        print("Stiffness: \(stiffness)")
        print("Initial displacement: 0.2m")
        print("Frames: 60")
        print("")

        for drag in dragValues {
            let model = try buildHairChain(
                boneCount: 3,
                stiffness: stiffness,
                drag: drag,
                gravityPower: 0.0,
                settlingFrames: 0
            )
            let system = try SpringBoneComputeSystem(device: device)
            try system.populateSpringBoneData(model: model)

            guard let buffers = model.springBoneBuffers,
                  let bonePosCurr = buffers.bonePosCurr else { continue }

            let currPtr = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
            let restY = currPtr[2].y
            let displacement: Float = 0.2
            currPtr[2].y = restY + displacement

            for _ in 0..<60 {
                system.update(model: model, deltaTime: 1.0 / 60.0)
            }

            let finalY = currPtr[2].y
            let finalDisplacement = finalY - restY
            let percentReturned = ((displacement - abs(finalDisplacement)) / displacement) * 100

            print("Drag \(String(format: "%.1f", drag)): " +
                  "final displacement = \(String(format: "%.4f", finalDisplacement))m, " +
                  "returned \(String(format: "%.1f", percentReturned))% to rest")
        }
    }

    /// **REGRESSION TEST**: Rapid rotation should not explode
    ///
    /// Tests that rapid character rotation doesn't cause physics explosion
    /// (validates the interpolation fix for rotational snapping)
    func testRapidRotation_ShouldNotExplode() throws {
        let model = try buildHairChain(
            boneCount: 5,
            stiffness: 0.5,
            drag: 0.3,
            gravityPower: 1.0,
            settlingFrames: 0
        )
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        guard let rootNode = model.nodes.first else {
            XCTFail("No root node")
            return
        }

        // Equilibrium
        for _ in 0..<30 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        // Rapid 180-degree rotation in 5 frames (simulates quick turn)
        print("=== Rapid Rotation Test (180° in 5 frames) ===")
        for frame in 0..<5 {
            let angle = Float.pi * Float(frame + 1) / 5.0  // 0 to π
            rootNode.rotation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
            rootNode.updateLocalMatrix()
            rootNode.updateWorldTransform()
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }

        Thread.sleep(forTimeInterval: 0.05)
        system.writeBonesToNodes(model: model)
        let postRotationPositions = readBonePositions(model: model)

        // Check for NaN/Inf (explosion)
        var hasNaN = false
        var maxPosition: Float = 0
        for (i, pos) in postRotationPositions.enumerated() {
            if pos.x.isNaN || pos.y.isNaN || pos.z.isNaN ||
               pos.x.isInfinite || pos.y.isInfinite || pos.z.isInfinite {
                hasNaN = true
                print("Bone \(i): NaN/Inf detected!")
            }
            maxPosition = max(maxPosition, abs(pos.x), abs(pos.y), abs(pos.z))
        }

        print("Max position magnitude: \(maxPosition)")

        XCTAssertFalse(hasNaN, "Physics exploded to NaN/Inf during rapid rotation!")
        XCTAssertLessThan(maxPosition, 10.0, "Physics exploded during rapid rotation (positions > 10m)!")
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

    /// Build a vertical hair chain (bones extend downward from root at Y=1)
    private func buildHairChain(
        boneCount: Int,
        stiffness: Float,
        drag: Float,
        gravityPower: Float,
        settlingFrames: UInt32
    ) throws -> VRMModel {
        let builder = VRMBuilder()
        let model = try builder.setSkeleton(.defaultHumanoid).build()

        let boneLength: Float = 0.1
        model.nodes.removeAll()

        var previousNode: VRMNode? = nil
        for i in 0..<boneCount {
            // Vertical chain: root at (0, 1, 0), children extend downward
            let localY: Float = (i == 0) ? 1.0 : -boneLength
            let gltfNode = try createGLTFNode(
                name: "hair_bone_\(i)",
                translation: SIMD3<Float>(0, localY, 0)
            )
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

        var joints: [VRMSpringJoint] = []
        for i in 0..<boneCount {
            var joint = VRMSpringJoint(node: i)
            joint.hitRadius = 0.02
            joint.stiffness = stiffness
            joint.gravityPower = gravityPower
            joint.gravityDir = SIMD3<Float>(0, -1, 0)
            joint.dragForce = drag
            joints.append(joint)
        }

        var springBone = VRMSpringBone()
        var spring = VRMSpring(name: "HairChain")
        spring.joints = joints
        springBone.springs = [spring]
        model.springBone = springBone

        model.device = device

        let buffers = SpringBoneBuffers(device: device)
        buffers.allocateBuffers(numBones: boneCount, numSpheres: 0, numCapsules: 0)
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
            numSpheres: 0,
            numCapsules: 0,
            numPlanes: 0,
            settlingFrames: settlingFrames
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
}
