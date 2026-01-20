// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Tests spring bone physics with actual VRM model files.
/// Verifies that hair/cloth responds correctly to character motion.
final class VRMRealModelPhysicsTest: XCTestCase {

    var device: MTLDevice!
    var modelPath: String {
        ProcessInfo.processInfo.environment["VRM_TEST_MODEL_PATH"] ?? ""
    }

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    /// Test that hair responds to character jumping motion
    func testHairRespondsToJump() async throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw XCTSkip("VRM model not found at \(modelPath)")
        }

        let model = try await VRMModel.load(from: URL(fileURLWithPath: modelPath), device: device)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        guard let hipsNode = model.humanoid?.humanBones[.hips].flatMap({ model.nodes[safe: $0.node] }) else {
            XCTFail("No hips bone found")
            return
        }

        print("=== Hair Response to Jump Test ===")
        print("Model: AvatarSample_A.vrm.glb")
        print("Spring bone chains: \(model.springBone?.springs.count ?? 0)")

        // Phase 1: Let physics settle (must exceed settling frames - model has 120)
        print("\n--- Phase 1: Settling (150 frames to exceed 120 settling period) ---")
        for _ in 0..<150 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        system.writeBonesToNodes(model: model)

        let restPositions = captureHairTipPositions(model: model)
        print("Rest positions captured for \(restPositions.count) hair chains")

        // Phase 2: Jump UP (move hips up 0.3m over 10 frames)
        print("\n--- Phase 2: Jump Up ---")
        let jumpHeight: Float = 0.3
        let originalHipsY = hipsNode.translation.y
        print("Original hips Y: \(originalHipsY)")

        for frame in 0..<10 {
            let progress = Float(frame + 1) / 10.0
            hipsNode.translation.y = originalHipsY + jumpHeight * progress
            hipsNode.updateLocalMatrix()
            updateAllTransforms(model: model)
            system.update(model: model, deltaTime: 1.0 / 60.0)

            if frame == 0 || frame == 4 || frame == 9 {
                try await Task.sleep(nanoseconds: 10_000_000)
                system.writeBonesToNodes(model: model)
                let pos = captureHairTipPositions(model: model)
                // Track Hair_5 (first hair chain) for consistent comparison
                if let hairPos = pos["Hair_5"] {
                    print("  Frame \(frame): hips Y=\(String(format: "%.3f", hipsNode.translation.y)), Hair_5 tip Y=\(String(format: "%.3f", hairPos.y))")
                }
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        system.writeBonesToNodes(model: model)

        let jumpPeakPositions = captureHairTipPositions(model: model)

        // Calculate hair lag (how much hair trails behind during jump)
        var totalLag: Float = 0
        var lagCount = 0
        for (chainName, restPos) in restPositions {
            if let peakPos = jumpPeakPositions[chainName] {
                // Hair should trail behind (be lower than expected)
                let expectedY = restPos.y + jumpHeight
                let actualY = peakPos.y
                let lag = expectedY - actualY
                totalLag += lag
                lagCount += 1
                print("  \(chainName): rest Y=\(String(format: "%.3f", restPos.y)), peak Y=\(String(format: "%.3f", actualY)), lag=\(String(format: "%.3f", lag))m")
            }
        }

        let avgLag = lagCount > 0 ? totalLag / Float(lagCount) : 0
        print("Average hair lag during jump: \(String(format: "%.3f", avgLag))m")

        // Phase 3: Land (return to original height)
        print("\n--- Phase 3: Land ---")
        for frame in 0..<10 {
            let progress = Float(frame + 1) / 10.0
            hipsNode.translation.y = originalHipsY + jumpHeight * (1.0 - progress)
            hipsNode.updateLocalMatrix()
            updateAllTransforms(model: model)
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        system.writeBonesToNodes(model: model)

        // Phase 4: Settle (120 frames for more complete settling)
        print("\n--- Phase 4: Settling After Land (120 frames) ---")
        for frame in 0..<120 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
            if frame == 30 || frame == 60 || frame == 90 || frame == 119 {
                try await Task.sleep(nanoseconds: 10_000_000)
                system.writeBonesToNodes(model: model)
                let pos = captureHairTipPositions(model: model)
                if let hairPos = pos["Hair_5"], let restPos = restPositions["Hair_5"] {
                    let delta = abs(hairPos.y - restPos.y)
                    print("  Frame \(frame): Hair_5 Y=\(String(format: "%.3f", hairPos.y)), rest Y=\(String(format: "%.3f", restPos.y)), delta=\(String(format: "%.4f", delta))m")
                }
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        system.writeBonesToNodes(model: model)

        let finalPositions = captureHairTipPositions(model: model)

        // Calculate final displacement from rest
        var maxDisplacement: Float = 0
        var totalDisplacement: Float = 0
        var displacementCount = 0

        print("\n--- Final Displacement Analysis ---")
        for (chainName, restPos) in restPositions {
            if let finalPos = finalPositions[chainName] {
                let displacement = simd_distance(restPos, finalPos)
                maxDisplacement = max(maxDisplacement, displacement)
                totalDisplacement += displacement
                displacementCount += 1
                print("  \(chainName): displacement=\(String(format: "%.4f", displacement))m")
            }
        }

        let avgDisplacement = displacementCount > 0 ? totalDisplacement / Float(displacementCount) : 0
        print("\nMax displacement: \(String(format: "%.4f", maxDisplacement))m")
        print("Avg displacement: \(String(format: "%.4f", avgDisplacement))m")

        // Assertions
        // 1. Physics should be responding - positions should change during jump
        let physicsResponding = avgLag != 0 || maxDisplacement > 0.001
        XCTAssertTrue(physicsResponding, "Physics should be responding to movement")

        // 2. Most chains should return close to rest
        // Some chains may have collision issues preventing perfect settling
        // Allow 15cm average (some chains with collision will be higher)
        XCTAssertLessThan(avgDisplacement, 0.15, "Average displacement should be within 15cm after settling")

        // 3. Check that at least some chains settle reasonably (< 8cm)
        let wellSettledCount = finalPositions.filter { chainName, pos in
            guard let restPos = restPositions[chainName] else { return false }
            return simd_distance(pos, restPos) < 0.08
        }.count
        print("Chains settled within 8cm: \(wellSettledCount)/\(finalPositions.count)")
        XCTAssertGreaterThan(wellSettledCount, 0, "At least some chains should settle to within 8cm")
    }

    /// Test that hair responds to character rotation
    func testHairRespondsToRotation() async throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw XCTSkip("VRM model not found at \(modelPath)")
        }

        let model = try await VRMModel.load(from: URL(fileURLWithPath: modelPath), device: device)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        guard let hipsNode = model.humanoid?.humanBones[.hips].flatMap({ model.nodes[safe: $0.node] }) else {
            XCTFail("No hips bone found")
            return
        }

        print("=== Hair Response to Rotation Test ===")

        // Settle (must exceed 120 settling frames)
        for _ in 0..<150 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        system.writeBonesToNodes(model: model)

        let restPositions = captureHairTipPositions(model: model)

        // Rotate 90 degrees over 15 frames
        print("\n--- Rotating 90 degrees ---")
        for frame in 0..<15 {
            let angle = (Float.pi / 2.0) * Float(frame + 1) / 15.0
            hipsNode.rotation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
            hipsNode.updateLocalMatrix()
            updateAllTransforms(model: model)
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        system.writeBonesToNodes(model: model)

        let rotatedPositions = captureHairTipPositions(model: model)

        // Check that hair positions changed during rotation
        var positionsChanged = false
        for (chainName, restPos) in restPositions {
            if let rotatedPos = rotatedPositions[chainName] {
                let delta = simd_distance(restPos, rotatedPos)
                if delta > 0.01 {
                    positionsChanged = true
                    print("  \(chainName): moved \(String(format: "%.3f", delta))m")
                }
            }
        }

        XCTAssertTrue(positionsChanged, "Hair should move during rotation (physics active)")

        // Check for NaN/explosion
        var hasNaN = false
        for (chainName, pos) in rotatedPositions {
            if pos.x.isNaN || pos.y.isNaN || pos.z.isNaN {
                hasNaN = true
                print("ERROR: \(chainName) has NaN position!")
            }
            if abs(pos.x) > 10 || abs(pos.y) > 10 || abs(pos.z) > 10 {
                print("WARNING: \(chainName) has extreme position: \(pos)")
            }
        }

        XCTAssertFalse(hasNaN, "No hair chains should have NaN positions")
    }

    // MARK: - Helper Methods

    private func captureHairTipPositions(model: VRMModel) -> [String: SIMD3<Float>] {
        var positions: [String: SIMD3<Float>] = [:]

        guard let springBone = model.springBone,
              let buffers = model.springBoneBuffers,
              let bonePosCurr = buffers.bonePosCurr else {
            return positions
        }

        let ptr = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)

        var boneIndex = 0
        for (springIndex, spring) in springBone.springs.enumerated() {
            // Use unique name including index to avoid dictionary key collisions
            let baseName = spring.name ?? "Chain"
            let chainName = "\(baseName)_\(springIndex)"

            // Get the last (tip) bone of the chain
            if spring.joints.count > 0 {
                let tipBoneIndex = boneIndex + spring.joints.count - 1
                if tipBoneIndex < buffers.numBones {
                    positions[chainName] = ptr[tipBoneIndex]
                }
            }
            boneIndex += spring.joints.count
        }

        return positions
    }

    private func propagateTransforms(from node: VRMNode) {
        node.updateWorldTransform()
        for child in node.children {
            propagateTransforms(from: child)
        }
    }

    /// Update all root nodes in the model to propagate transforms through entire skeleton
    private func updateAllTransforms(model: VRMModel) {
        for node in model.nodes where node.parent == nil {
            propagateTransforms(from: node)
        }
    }
}
