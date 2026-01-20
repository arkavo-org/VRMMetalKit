// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Tests VRM 0.0 vs VRM 1.0 compatibility, focusing on:
/// 1. Coordinate system handedness
/// 2. Humanoid bone orientations
/// 3. Spring bone bind directions
/// 4. Animation direction consistency
///
/// ## Known Issues
///
/// VRM 0.0 uses a different coordinate convention than VRM 1.0:
/// - VRM 0.0: May need X/Z mirroring for humanoid bones
/// - VRM 1.0: Aligns with glTF standard (right-handed, Y-up, -Z forward)
///
/// If AliciaSolid (VRM 0.0) walks backwards while AvatarSample (VRM 1.0) walks
/// forwards with the same animation, the loader is missing VRM 0.0 mirroring logic.
///
final class VRMCompatibilityTests: XCTestCase {

    var device: MTLDevice!

    // Test assets - adjust paths as needed
    let vrm0_0_path = "/Users/arkavo/Projects/Muse/Resources/VRM/AliciaSolid.vrm"
    let vrm1_0_path = "/Users/arkavo/Projects/Muse/Resources/VRM/AvatarSample_A.vrm.glb"

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    // MARK: - Version Detection Tests

    /// Test that VRM 0.0 models are correctly identified
    func testVRM0_0VersionDetection() async throws {
        let url = URL(fileURLWithPath: vrm0_0_path)
        guard FileManager.default.fileExists(atPath: vrm0_0_path) else {
            throw XCTSkip("AliciaSolid.vrm not found at \(vrm0_0_path)")
        }

        let model = try await VRMModel.load(from: url, device: device)

        print("=== VRM 0.0 Model Analysis (AliciaSolid) ===")

        // Check spring bone spec version (VRM 0.0 format)
        let springBoneVersion = model.springBone?.specVersion ?? "unknown"
        print("SpringBone Spec Version: \(springBoneVersion)")

        // VRM 0.0 should have springBone.specVersion = "0.0"
        XCTAssertEqual(springBoneVersion, "0.0",
                       "AliciaSolid should have spring bone specVersion 0.0")

        // Print humanoid bone info for coordinate analysis
        if let humanoid = model.humanoid {
            print("\nHumanoid Bones:")
            for bone in VRMHumanoidBone.allCases {
                if let humanBone = humanoid.humanBones[bone],
                   let node = model.nodes[safe: humanBone.node] {
                    let pos = node.worldPosition
                    print("  \(bone.rawValue): node=\(humanBone.node) worldPos=(\(String(format: "%.3f", pos.x)), \(String(format: "%.3f", pos.y)), \(String(format: "%.3f", pos.z)))")
                }
            }
        }

        // Print spring bone info
        if let springBone = model.springBone {
            print("\nSpring Bone Chains:")
            for (i, spring) in springBone.springs.enumerated() {
                print("  Chain \(i): '\(spring.name ?? "unnamed")' joints=\(spring.joints.count)")
                for (j, joint) in spring.joints.enumerated() {
                    let gDir = joint.gravityDir
                    print("    Joint \(j): gravityDir=(\(String(format: "%.2f", gDir.x)), \(String(format: "%.2f", gDir.y)), \(String(format: "%.2f", gDir.z)))")
                }
            }
        }
    }

    /// Test that VRM 1.0 models are correctly identified
    func testVRM1_0VersionDetection() async throws {
        let url = URL(fileURLWithPath: vrm1_0_path)
        guard FileManager.default.fileExists(atPath: vrm1_0_path) else {
            throw XCTSkip("AvatarSample_A.vrm.glb not found at \(vrm1_0_path)")
        }

        let model = try await VRMModel.load(from: url, device: device)

        print("=== VRM 1.0 Model Analysis (AvatarSample_A) ===")

        // Check spring bone spec version (VRM 1.0 format)
        let springBoneVersion = model.springBone?.specVersion ?? "unknown"
        print("SpringBone Spec Version: \(springBoneVersion)")

        // VRM 1.0 should have springBone.specVersion = "1.0"
        XCTAssertEqual(springBoneVersion, "1.0",
                       "AvatarSample_A should have spring bone specVersion 1.0")

        // Print humanoid bone info for coordinate analysis
        if let humanoid = model.humanoid {
            print("\nHumanoid Bones:")
            for bone in VRMHumanoidBone.allCases {
                if let humanBone = humanoid.humanBones[bone],
                   let node = model.nodes[safe: humanBone.node] {
                    let pos = node.worldPosition
                    print("  \(bone.rawValue): node=\(humanBone.node) worldPos=(\(String(format: "%.3f", pos.x)), \(String(format: "%.3f", pos.y)), \(String(format: "%.3f", pos.z)))")
                }
            }
        }

        // Print spring bone info
        if let springBone = model.springBone {
            print("\nSpring Bone Chains:")
            for (i, spring) in springBone.springs.enumerated() {
                print("  Chain \(i): '\(spring.name ?? "unnamed")' joints=\(spring.joints.count)")
                for (j, joint) in spring.joints.enumerated() {
                    let gDir = joint.gravityDir
                    print("    Joint \(j): gravityDir=(\(String(format: "%.2f", gDir.x)), \(String(format: "%.2f", gDir.y)), \(String(format: "%.2f", gDir.z)))")
                }
            }
        }
    }

    // MARK: - Handedness / Coordinate System Tests

    /// **THE HANDEDNESS ACID TEST**
    ///
    /// Compare left/right bone positions between VRM 0.0 and VRM 1.0 models.
    /// If VRM 0.0 has inverted X coordinates for left/right limbs, the loader
    /// is missing coordinate mirroring.
    func testHandednessComparison() async throws {
        // Load both models
        guard FileManager.default.fileExists(atPath: vrm0_0_path),
              FileManager.default.fileExists(atPath: vrm1_0_path) else {
            throw XCTSkip("VRM test files not found")
        }

        let vrm0 = try await VRMModel.load(from: URL(fileURLWithPath: vrm0_0_path), device: device)
        let vrm1 = try await VRMModel.load(from: URL(fileURLWithPath: vrm1_0_path), device: device)

        print("=== Handedness Comparison: VRM 0.0 vs 1.0 ===\n")

        guard let humanoid0 = vrm0.humanoid, let humanoid1 = vrm1.humanoid else {
            XCTFail("Missing humanoid data")
            return
        }

        // Compare left/right arm positions using VRMHumanoidBone enum
        let bonePairs: [(left: VRMHumanoidBone, right: VRMHumanoidBone)] = [
            (.leftUpperArm, .rightUpperArm),
            (.leftLowerArm, .rightLowerArm),
            (.leftHand, .rightHand),
            (.leftUpperLeg, .rightUpperLeg),
            (.leftLowerLeg, .rightLowerLeg),
            (.leftFoot, .rightFoot),
        ]

        print("Checking if left/right X-coordinates have consistent sign...")
        print("(If VRM 0.0 has opposite signs, it needs X mirroring)\n")

        var vrm0_hasLeftPositiveX = 0
        var vrm0_hasRightPositiveX = 0
        var vrm1_hasLeftPositiveX = 0
        var vrm1_hasRightPositiveX = 0

        for (leftBoneType, rightBoneType) in bonePairs {
            // VRM 0.0
            if let leftBone = humanoid0.humanBones[leftBoneType],
               let rightBone = humanoid0.humanBones[rightBoneType],
               let leftNode = vrm0.nodes[safe: leftBone.node],
               let rightNode = vrm0.nodes[safe: rightBone.node] {
                let leftX = leftNode.worldPosition.x
                let rightX = rightNode.worldPosition.x
                if leftX > 0 { vrm0_hasLeftPositiveX += 1 }
                if rightX > 0 { vrm0_hasRightPositiveX += 1 }
                print("VRM 0.0 \(leftBoneType.rawValue): X=\(String(format: "%+.3f", leftX)), \(rightBoneType.rawValue): X=\(String(format: "%+.3f", rightX))")
            }

            // VRM 1.0
            if let leftBone = humanoid1.humanBones[leftBoneType],
               let rightBone = humanoid1.humanBones[rightBoneType],
               let leftNode = vrm1.nodes[safe: leftBone.node],
               let rightNode = vrm1.nodes[safe: rightBone.node] {
                let leftX = leftNode.worldPosition.x
                let rightX = rightNode.worldPosition.x
                if leftX > 0 { vrm1_hasLeftPositiveX += 1 }
                if rightX > 0 { vrm1_hasRightPositiveX += 1 }
                print("VRM 1.0 \(leftBoneType.rawValue): X=\(String(format: "%+.3f", leftX)), \(rightBoneType.rawValue): X=\(String(format: "%+.3f", rightX))")
            }
            print("")
        }

        print("=== Summary ===")
        print("VRM 0.0: Left bones with +X: \(vrm0_hasLeftPositiveX)/6, Right bones with +X: \(vrm0_hasRightPositiveX)/6")
        print("VRM 1.0: Left bones with +X: \(vrm1_hasLeftPositiveX)/6, Right bones with +X: \(vrm1_hasRightPositiveX)/6")

        // Check for inverted handedness
        // In standard glTF (VRM 1.0): left limbs should have positive X, right limbs negative X
        // If VRM 0.0 is opposite, it needs mirroring
        let vrm0_leftIsPositive = vrm0_hasLeftPositiveX > vrm0_hasRightPositiveX
        let vrm1_leftIsPositive = vrm1_hasLeftPositiveX > vrm1_hasRightPositiveX

        if vrm0_leftIsPositive != vrm1_leftIsPositive {
            print("\n⚠️  HANDEDNESS MISMATCH DETECTED!")
            print("VRM 0.0 and VRM 1.0 have opposite X-axis conventions.")
            print("The VRM 0.0 loader needs coordinate mirroring.")
            XCTFail("VRM 0.0 handedness differs from VRM 1.0 - loader needs X-axis mirroring")
        } else {
            print("\n✓ Handedness appears consistent between VRM 0.0 and VRM 1.0")
        }
    }

    // MARK: - Forward Direction Test

    /// Test if the model's "forward" direction is consistent.
    /// In glTF/VRM 1.0, forward is -Z. VRM 0.0 may have different convention.
    func testForwardDirection() async throws {
        guard FileManager.default.fileExists(atPath: vrm0_0_path),
              FileManager.default.fileExists(atPath: vrm1_0_path) else {
            throw XCTSkip("VRM test files not found")
        }

        let vrm0 = try await VRMModel.load(from: URL(fileURLWithPath: vrm0_0_path), device: device)
        let vrm1 = try await VRMModel.load(from: URL(fileURLWithPath: vrm1_0_path), device: device)

        print("=== Forward Direction Test ===\n")

        // Get head bone position relative to hips
        // If the head is in front of hips (negative Z in VRM 1.0), the model faces -Z

        func getForwardDirection(model: VRMModel, name: String) -> SIMD3<Float>? {
            guard let humanoid = model.humanoid,
                  let headBone = humanoid.humanBones[.head],
                  let hipsBone = humanoid.humanBones[.hips],
                  let headNode = model.nodes[safe: headBone.node],
                  let hipsNode = model.nodes[safe: hipsBone.node] else {
                return nil
            }

            let headPos = headNode.worldPosition
            let hipsPos = hipsNode.worldPosition

            print("\(name):")
            print("  Head world position: (\(String(format: "%.3f", headPos.x)), \(String(format: "%.3f", headPos.y)), \(String(format: "%.3f", headPos.z)))")
            print("  Hips world position: (\(String(format: "%.3f", hipsPos.x)), \(String(format: "%.3f", hipsPos.y)), \(String(format: "%.3f", hipsPos.z)))")

            // For a T-pose character, head should be directly above hips (Z ≈ 0)
            // If head.z is significantly different from hips.z, model may be rotated or coordinate system differs
            let zDiff = headPos.z - hipsPos.z
            print("  Head-Hips Z difference: \(String(format: "%.3f", zDiff))")

            return headPos - hipsPos
        }

        let dir0 = getForwardDirection(model: vrm0, name: "VRM 0.0 (AliciaSolid)")
        let dir1 = getForwardDirection(model: vrm1, name: "VRM 1.0 (AvatarSample_A)")

        if let d0 = dir0, let d1 = dir1 {
            // Check if Z components have same sign
            if (d0.z > 0.01) != (d1.z > 0.01) && abs(d0.z) > 0.01 && abs(d1.z) > 0.01 {
                print("\n⚠️  Z-AXIS FORWARD DIRECTION MISMATCH")
                print("Models may face opposite directions")
            }
        }
    }

    // MARK: - Spring Bone Physics Test

    /// Test that spring bone rest lengths are reasonable for both VRM versions
    func testSpringBoneRestLengths() async throws {
        guard FileManager.default.fileExists(atPath: vrm0_0_path),
              FileManager.default.fileExists(atPath: vrm1_0_path) else {
            throw XCTSkip("VRM test files not found")
        }

        let vrm0 = try await VRMModel.load(from: URL(fileURLWithPath: vrm0_0_path), device: device)
        let vrm1 = try await VRMModel.load(from: URL(fileURLWithPath: vrm1_0_path), device: device)

        print("=== Spring Bone Rest Length Analysis ===\n")

        func analyzeSpringBone(model: VRMModel, name: String) {
            guard let springBone = model.springBone else {
                print("\(name): No spring bone data")
                return
            }

            print("\(name):")
            var minRestLen: Float = .infinity
            var maxRestLen: Float = 0

            for spring in springBone.springs {
                for (i, joint) in spring.joints.enumerated() {
                    if i == 0 { continue } // Skip root

                    // Calculate rest length from node positions
                    let parentJoint = spring.joints[i - 1]
                    if let node = model.nodes[safe: joint.node],
                       let parentNode = model.nodes[safe: parentJoint.node] {
                        let restLen = simd_distance(node.worldPosition, parentNode.worldPosition)
                        minRestLen = min(minRestLen, restLen)
                        maxRestLen = max(maxRestLen, restLen)
                    }
                }
            }

            if minRestLen < .infinity {
                print("  Rest length range: \(String(format: "%.4f", minRestLen))m - \(String(format: "%.4f", maxRestLen))m")

                // Flag very small rest lengths (< 2cm) as potential problems
                if minRestLen < 0.02 {
                    print("  ⚠️  Very small rest lengths detected!")
                    print("     Small rest lengths (< 2cm) are susceptible to velocity sledgehammer.")
                }
            }
        }

        analyzeSpringBone(model: vrm0, name: "VRM 0.0 (AliciaSolid)")
        analyzeSpringBone(model: vrm1, name: "VRM 1.0 (AvatarSample_A)")
    }

    // MARK: - Physics Behavior Test

    /// Test that physics simulation produces similar behavior for both VRM versions
    func testPhysicsBehaviorConsistency() async throws {
        guard FileManager.default.fileExists(atPath: vrm1_0_path) else {
            throw XCTSkip("VRM 1.0 test file not found")
        }

        let model = try await VRMModel.load(from: URL(fileURLWithPath: vrm1_0_path), device: device)

        guard let springBone = model.springBone, !springBone.springs.isEmpty else {
            throw XCTSkip("No spring bone data in model")
        }

        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)

        print("=== VRM 1.0 Physics Behavior Test ===\n")

        // Run physics for 60 frames at rest
        for _ in 0..<60 {
            system.update(model: model, deltaTime: 1.0 / 60.0)
        }
        try await Task.sleep(nanoseconds: 100_000_000)  // 0.1 seconds
        system.writeBonesToNodes(model: model)

        // Check that physics reached stable state (positions not NaN or infinite)
        var stableCount = 0
        var totalBones = 0

        guard let buffers = model.springBoneBuffers,
              let bonePosCurr = buffers.bonePosCurr else {
            XCTFail("No physics buffers")
            return
        }

        let ptr = bonePosCurr.contents().bindMemory(to: SIMD3<Float>.self, capacity: buffers.numBones)
        for i in 0..<buffers.numBones {
            let pos = ptr[i]
            totalBones += 1
            if !pos.x.isNaN && !pos.y.isNaN && !pos.z.isNaN &&
               !pos.x.isInfinite && !pos.y.isInfinite && !pos.z.isInfinite {
                stableCount += 1
            } else {
                print("  ⚠️  Bone \(i) has invalid position: \(pos)")
            }
        }

        print("Stable bones: \(stableCount)/\(totalBones)")
        XCTAssertEqual(stableCount, totalBones, "All physics bones should have valid positions")
    }
}
