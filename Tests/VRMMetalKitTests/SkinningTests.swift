//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import XCTest
import Metal
import simd
@testable import VRMMetalKit

// Helper to disambiguate simd_quatf initializer (VRMMetalKit has its own extension)
private func makeQuaternion(angle: Float, axis: SIMD3<Float>) -> simd_quatf {
    let halfAngle = angle * 0.5
    let sinHalf = sin(halfAngle)
    let cosHalf = cos(halfAngle)
    let normalizedAxis = simd_normalize(axis)
    return simd_quatf(
        ix: normalizedAxis.x * sinHalf,
        iy: normalizedAxis.y * sinHalf,
        iz: normalizedAxis.z * sinHalf,
        r: cosHalf
    )
}

/// Comprehensive tests for the VRMMetalKit skinning pipeline.
/// Tests validate:
/// - Inverse bind matrix loading and validity
/// - Skin matrix computation (worldMatrix * inverseBindMatrix)
/// - CPU-side skinning simulation
/// - Visual sanity checks (bounding boxes, symmetry)
final class SkinningTests: XCTestCase {

    var device: MTLDevice!

    override func setUp() async throws {
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else {
            throw XCTSkip("Metal device not available")
        }
    }

    // MARK: - Helper Properties

    /// Find project root for test files
    private var projectRoot: String {
        let fileManager = FileManager.default
        let candidates: [String?] = [
            ProcessInfo.processInfo.environment["PROJECT_ROOT"],
            ProcessInfo.processInfo.environment["SRCROOT"],
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path,
            fileManager.currentDirectoryPath
        ]

        for candidate in candidates.compactMap({ $0 }) {
            let packagePath = "\(candidate)/Package.swift"
            let vrmPath = "\(candidate)/AliciaSolid.vrm"
            if fileManager.fileExists(atPath: packagePath) &&
               fileManager.fileExists(atPath: vrmPath) {
                return candidate
            }
        }
        return fileManager.currentDirectoryPath
    }

    // MARK: - Helper Methods

    /// Load test VRM model
    private func loadTestModel() async throws -> VRMModel {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found at \(modelPath)")

        let modelURL = URL(fileURLWithPath: modelPath)
        return try await VRMModel.load(from: modelURL, device: device)
    }

    /// Compute skin matrix for a single joint
    private func computeSkinMatrix(worldMatrix: float4x4, inverseBindMatrix: float4x4) -> float4x4 {
        return worldMatrix * inverseBindMatrix
    }

    /// Apply skinning to a vertex (CPU simulation of GPU shader)
    private func skinVertex(
        position: SIMD3<Float>,
        joints: SIMD4<UInt16>,
        weights: SIMD4<Float>,
        skinMatrices: [float4x4]
    ) -> SIMD3<Float> {
        // Normalize weights
        let weightSum = max(weights.x + weights.y + weights.z + weights.w, 1e-6)
        let normalizedWeights = weights / weightSum

        // Blend skin matrices
        var skinMatrix = float4x4(0)
        if normalizedWeights.x > 0 && Int(joints.x) < skinMatrices.count {
            skinMatrix += skinMatrices[Int(joints.x)] * normalizedWeights.x
        }
        if normalizedWeights.y > 0 && Int(joints.y) < skinMatrices.count {
            skinMatrix += skinMatrices[Int(joints.y)] * normalizedWeights.y
        }
        if normalizedWeights.z > 0 && Int(joints.z) < skinMatrices.count {
            skinMatrix += skinMatrices[Int(joints.z)] * normalizedWeights.z
        }
        if normalizedWeights.w > 0 && Int(joints.w) < skinMatrices.count {
            skinMatrix += skinMatrices[Int(joints.w)] * normalizedWeights.w
        }

        // Transform position
        let pos4 = SIMD4<Float>(position.x, position.y, position.z, 1.0)
        let transformed = skinMatrix * pos4
        return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
    }

    /// Check if matrix contains NaN or Inf values
    private func matrixIsValid(_ m: float4x4) -> Bool {
        for col in 0..<4 {
            for row in 0..<4 {
                let val = m[col][row]
                if val.isNaN || val.isInfinite {
                    return false
                }
            }
        }
        return true
    }

    /// Compute matrix determinant (for invertibility check)
    private func determinant(_ m: float4x4) -> Float {
        // Use simd's built-in determinant
        return simd_determinant(m)
    }

    /// Check if matrix is close to identity
    private func isCloseToIdentity(_ m: float4x4, tolerance: Float = 0.1) -> Bool {
        let identity = matrix_identity_float4x4
        for col in 0..<4 {
            for row in 0..<4 {
                if abs(m[col][row] - identity[col][row]) > tolerance {
                    return false
                }
            }
        }
        return true
    }

    /// Extract translation from matrix
    private func extractTranslation(_ m: float4x4) -> SIMD3<Float> {
        return SIMD3<Float>(m[3][0], m[3][1], m[3][2])
    }

    // MARK: - Phase 1: Inverse Bind Matrix Validation Tests

    /// Test 1.1: Verify inverse bind matrices are loaded and match joint count
    func testInverseBindMatricesLoaded() async throws {
        let model = try await loadTestModel()

        XCTAssertGreaterThan(model.skins.count, 0, "Model should have at least one skin")

        for (skinIndex, skin) in model.skins.enumerated() {
            // Joint count should match inverse bind matrix count
            XCTAssertEqual(skin.joints.count, skin.inverseBindMatrices.count,
                "Skin \(skinIndex) should have matching joint and inverse bind matrix counts")

            print("\n=== Skin \(skinIndex): \(skin.name ?? "unnamed") ===")
            print("Joints: \(skin.joints.count)")
            print("Inverse bind matrices: \(skin.inverseBindMatrices.count)")
        }
    }

    /// Test 1.2: Verify inverse bind matrices are valid (no NaN/Inf, invertible)
    func testInverseBindMatricesValid() async throws {
        let model = try await loadTestModel()

        for (skinIndex, skin) in model.skins.enumerated() {
            for (matrixIndex, matrix) in skin.inverseBindMatrices.enumerated() {
                // Check for NaN/Inf
                XCTAssertTrue(matrixIsValid(matrix),
                    "Skin \(skinIndex) inverse bind matrix \(matrixIndex) contains NaN/Inf")

                // Check determinant (should be non-zero for invertible matrix)
                let det = determinant(matrix)
                XCTAssertNotEqual(det, 0, accuracy: 1e-6,
                    "Skin \(skinIndex) inverse bind matrix \(matrixIndex) has zero determinant (not invertible)")
            }
        }
    }

    /// Test 1.3: Verify inverse bind matrices have reasonable values
    func testInverseBindMatricesReasonable() async throws {
        let model = try await loadTestModel()

        var identityCount = 0
        var totalMatrices = 0

        for (skinIndex, skin) in model.skins.enumerated() {
            for (matrixIndex, matrix) in skin.inverseBindMatrices.enumerated() {
                totalMatrices += 1

                // Check if matrix is identity (which would be suspicious for most bones)
                if isCloseToIdentity(matrix, tolerance: 0.001) {
                    identityCount += 1
                }

                // Check translation magnitude (bones shouldn't be too far from origin)
                let translation = extractTranslation(matrix)
                let translationMagnitude = simd_length(translation)

                // Most bones in a humanoid model should have translation < 10 units
                // But inverse bind matrices can have larger values
                if translationMagnitude > 100 {
                    print("⚠️ Skin \(skinIndex) matrix \(matrixIndex) has large translation: \(translationMagnitude)")
                }
            }
        }

        // Not all matrices should be identity (that would indicate loading failure)
        let identityRatio = Float(identityCount) / Float(totalMatrices)
        print("\nIdentity matrices: \(identityCount)/\(totalMatrices) (\(String(format: "%.1f", identityRatio * 100))%)")

        // If more than 50% are identity, something might be wrong
        XCTAssertLessThan(identityRatio, 0.5,
            "Too many inverse bind matrices are identity - possible loading issue")
    }

    // MARK: - Phase 2: Skin Matrix Computation Tests

    /// Test 2.1: In bind pose (no animation), skin matrices should be close to identity
    func testBindPoseSkinMatricesNearIdentity() async throws {
        let model = try await loadTestModel()

        // Ensure world transforms are updated
        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }

        print("\n=== Bind Pose Skin Matrix Analysis ===")

        for (skinIndex, skin) in model.skins.enumerated() {
            var nearIdentityCount = 0

            for (jointIndex, joint) in skin.joints.enumerated() {
                let worldMatrix = joint.worldMatrix
                let inverseBindMatrix = skin.inverseBindMatrices[jointIndex]
                let skinMatrix = computeSkinMatrix(worldMatrix: worldMatrix, inverseBindMatrix: inverseBindMatrix)

                // In bind pose, skinMatrix should be close to identity
                // (worldMatrix * inverseBindMatrix ≈ I when world == bind)
                if isCloseToIdentity(skinMatrix, tolerance: 0.5) {
                    nearIdentityCount += 1
                } else if jointIndex < 10 {
                    // Print first few non-identity matrices for debugging
                    let translation = extractTranslation(skinMatrix)
                    print("Joint \(jointIndex) '\(joint.name ?? "?")': skinMatrix translation = \(translation)")
                }
            }

            let ratio = Float(nearIdentityCount) / Float(skin.joints.count)
            print("Skin \(skinIndex): \(nearIdentityCount)/\(skin.joints.count) matrices near identity (\(String(format: "%.1f", ratio * 100))%)")

            // At least some matrices should be near identity in bind pose
            XCTAssertGreaterThan(nearIdentityCount, 0,
                "Skin \(skinIndex) has no matrices near identity in bind pose - possible issue")
        }
    }

    /// Test 2.2: Rotation applied to joint propagates to skin matrix
    func testRotationPropagatestoSkinMatrix() async throws {
        let model = try await loadTestModel()

        guard let humanoid = model.humanoid,
              let hipsIndex = humanoid.getBoneNode(.hips),
              hipsIndex < model.nodes.count else {
            throw XCTSkip("Model doesn't have humanoid hips bone")
        }

        let hipsNode = model.nodes[hipsIndex]

        // Record initial skin matrix for hips
        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }

        // Find skin containing hips
        var hipsSkin: VRMSkin?
        var hipsJointIndex: Int?
        for skin in model.skins {
            if let idx = skin.joints.firstIndex(where: { $0 === hipsNode }) {
                hipsSkin = skin
                hipsJointIndex = idx
                break
            }
        }

        guard let skin = hipsSkin, let jointIdx = hipsJointIndex else {
            throw XCTSkip("Hips node not found in any skin")
        }

        let initialSkinMatrix = computeSkinMatrix(
            worldMatrix: hipsNode.worldMatrix,
            inverseBindMatrix: skin.inverseBindMatrices[jointIdx]
        )

        // Apply 45° rotation around Y axis
        let angle: Float = .pi / 4
        hipsNode.rotation = makeQuaternion(angle: angle, axis: SIMD3<Float>(0, 1, 0))
        hipsNode.updateLocalMatrix()

        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }

        let rotatedSkinMatrix = computeSkinMatrix(
            worldMatrix: hipsNode.worldMatrix,
            inverseBindMatrix: skin.inverseBindMatrices[jointIdx]
        )

        // Skin matrices should be different after rotation
        var matricesDiffer = false
        for col in 0..<4 {
            for row in 0..<4 {
                if abs(initialSkinMatrix[col][row] - rotatedSkinMatrix[col][row]) > 0.001 {
                    matricesDiffer = true
                    break
                }
            }
        }

        XCTAssertTrue(matricesDiffer, "Skin matrix should change when joint is rotated")

        print("\n=== Rotation Propagation Test ===")
        print("Applied 45° Y rotation to hips")
        print("Initial translation: \(extractTranslation(initialSkinMatrix))")
        print("Rotated translation: \(extractTranslation(rotatedSkinMatrix))")
    }

    // MARK: - Phase 3: Vertex Skinning Tests

    /// Test 3.1: CPU skinning simulation produces reasonable results
    func testCPUSkinningProducesReasonableResults() async throws {
        let model = try await loadTestModel()

        // Ensure world transforms are updated
        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }

        guard model.skins.count > 0 else {
            throw XCTSkip("Model has no skins")
        }

        let skin = model.skins[0]

        // Compute all skin matrices
        var skinMatrices: [float4x4] = []
        for (idx, joint) in skin.joints.enumerated() {
            let skinMatrix = computeSkinMatrix(
                worldMatrix: joint.worldMatrix,
                inverseBindMatrix: skin.inverseBindMatrices[idx]
            )
            skinMatrices.append(skinMatrix)
        }

        // Test skinning a vertex at origin with single joint influence
        let testPosition = SIMD3<Float>(0, 1, 0)  // 1 unit up
        let testJoints = SIMD4<UInt16>(0, 0, 0, 0)  // All weight on joint 0
        let testWeights = SIMD4<Float>(1, 0, 0, 0)

        let skinnedPosition = skinVertex(
            position: testPosition,
            joints: testJoints,
            weights: testWeights,
            skinMatrices: skinMatrices
        )

        // Result should be finite
        XCTAssertFalse(skinnedPosition.x.isNaN || skinnedPosition.x.isInfinite)
        XCTAssertFalse(skinnedPosition.y.isNaN || skinnedPosition.y.isInfinite)
        XCTAssertFalse(skinnedPosition.z.isNaN || skinnedPosition.z.isInfinite)

        // In bind pose, position shouldn't move dramatically
        let displacement = simd_length(skinnedPosition - testPosition)
        print("\n=== CPU Skinning Test ===")
        print("Original position: \(testPosition)")
        print("Skinned position: \(skinnedPosition)")
        print("Displacement: \(displacement)")

        // Displacement should be reasonable (< 10 units for bind pose)
        XCTAssertLessThan(displacement, 10.0,
            "Skinned vertex moved too far from original position in bind pose")
    }

    /// Test 3.2: Multi-joint weighted skinning produces smooth blend
    func testMultiJointSkinningBlend() async throws {
        let model = try await loadTestModel()

        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }

        guard model.skins.count > 0, model.skins[0].joints.count >= 2 else {
            throw XCTSkip("Model needs at least 2 joints in first skin")
        }

        let skin = model.skins[0]

        var skinMatrices: [float4x4] = []
        for (idx, joint) in skin.joints.enumerated() {
            skinMatrices.append(computeSkinMatrix(
                worldMatrix: joint.worldMatrix,
                inverseBindMatrix: skin.inverseBindMatrices[idx]
            ))
        }

        let testPosition = SIMD3<Float>(0, 1, 0)

        // Test 100% joint 0
        let pos0 = skinVertex(
            position: testPosition,
            joints: SIMD4<UInt16>(0, 1, 0, 0),
            weights: SIMD4<Float>(1, 0, 0, 0),
            skinMatrices: skinMatrices
        )

        // Test 100% joint 1
        let pos1 = skinVertex(
            position: testPosition,
            joints: SIMD4<UInt16>(0, 1, 0, 0),
            weights: SIMD4<Float>(0, 1, 0, 0),
            skinMatrices: skinMatrices
        )

        // Test 50/50 blend
        let posBlend = skinVertex(
            position: testPosition,
            joints: SIMD4<UInt16>(0, 1, 0, 0),
            weights: SIMD4<Float>(0.5, 0.5, 0, 0),
            skinMatrices: skinMatrices
        )

        // Blended position should be between the two extremes
        let expected = (pos0 + pos1) / 2.0
        let blendError = simd_length(posBlend - expected)

        print("\n=== Multi-Joint Blend Test ===")
        print("100% Joint 0: \(pos0)")
        print("100% Joint 1: \(pos1)")
        print("50/50 Blend: \(posBlend)")
        print("Expected: \(expected)")
        print("Blend error: \(blendError)")

        XCTAssertLessThan(blendError, 0.001,
            "50/50 blend should produce average of two positions")
    }

    // MARK: - Phase 4: Visual Validation Tests

    /// Test 4.1: Model bounding box is reasonable in bind pose
    func testBindPoseBoundingBoxReasonable() async throws {
        let model = try await loadTestModel()

        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }

        // Compute bounding box from all mesh vertices
        var minBound = SIMD3<Float>(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var maxBound = SIMD3<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
        var vertexCount = 0

        for mesh in model.meshes {
            for primitive in mesh.primitives {
                // Access vertex buffer if available
                if let vertexBuffer = primitive.vertexBuffer {
                    let vertexStride = MemoryLayout<VRMVertex>.stride
                    let count = vertexBuffer.length / vertexStride
                    let vertices = vertexBuffer.contents().bindMemory(to: VRMVertex.self, capacity: count)

                    for i in 0..<count {
                        let pos = vertices[i].position
                        minBound = simd_min(minBound, pos)
                        maxBound = simd_max(maxBound, pos)
                        vertexCount += 1
                    }
                }
            }
        }

        guard vertexCount > 0 else {
            throw XCTSkip("No vertices found in model")
        }

        let size = maxBound - minBound
        let center = (minBound + maxBound) / 2.0

        print("\n=== Bounding Box Analysis ===")
        print("Vertices: \(vertexCount)")
        print("Min: \(minBound)")
        print("Max: \(maxBound)")
        print("Size: \(size)")
        print("Center: \(center)")

        // Humanoid model should have reasonable dimensions
        // Typical VRM is ~1.5-2m tall (Y), ~0.5m wide (X), ~0.3m deep (Z)
        XCTAssertGreaterThan(size.y, 0.1, "Model should have positive height")
        XCTAssertLessThan(size.y, 10.0, "Model height should be reasonable (< 10 units)")
        XCTAssertLessThan(size.x, 10.0, "Model width should be reasonable")
        XCTAssertLessThan(size.z, 10.0, "Model depth should be reasonable")
    }

    /// Test 4.2: Left and right arms should be roughly symmetric in bind pose
    func testSymmetricArmPositions() async throws {
        let model = try await loadTestModel()

        guard let humanoid = model.humanoid else {
            throw XCTSkip("Model doesn't have humanoid data")
        }

        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }

        // Get left and right upper arm positions
        guard let leftArmIndex = humanoid.getBoneNode(.leftUpperArm),
              let rightArmIndex = humanoid.getBoneNode(.rightUpperArm) else {
            throw XCTSkip("Model missing arm bones")
        }

        let leftArmPos = extractTranslation(model.nodes[leftArmIndex].worldMatrix)
        let rightArmPos = extractTranslation(model.nodes[rightArmIndex].worldMatrix)

        print("\n=== Arm Symmetry Test ===")
        print("Left arm world position: \(leftArmPos)")
        print("Right arm world position: \(rightArmPos)")

        // X coordinates should be roughly mirrored (opposite signs)
        let xSymmetry = abs(leftArmPos.x + rightArmPos.x)
        print("X symmetry error: \(xSymmetry)")

        // Y coordinates should be similar
        let yDiff = abs(leftArmPos.y - rightArmPos.y)
        print("Y difference: \(yDiff)")

        // Z coordinates should be similar
        let zDiff = abs(leftArmPos.z - rightArmPos.z)
        print("Z difference: \(zDiff)")

        // Arms should be roughly symmetric
        XCTAssertLessThan(xSymmetry, 0.1, "Arms should be X-symmetric (mirrored)")
        XCTAssertLessThan(yDiff, 0.1, "Arms should be at same height")
        XCTAssertLessThan(zDiff, 0.1, "Arms should be at same depth")
    }

    /// Test 4.3: Animated pose doesn't cause vertex explosion
    func testAnimatedPoseNoVertexExplosion() async throws {
        let model = try await loadTestModel()
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"

        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA file not found")

        // Load and apply animation
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)

        let player = AnimationPlayer()
        player.load(clip)
        player.update(deltaTime: clip.duration / 2, model: model)  // Mid-animation

        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }

        // Compute skin matrices
        guard model.skins.count > 0 else {
            throw XCTSkip("Model has no skins")
        }

        let skin = model.skins[0]
        var skinMatrices: [float4x4] = []
        for (idx, joint) in skin.joints.enumerated() {
            skinMatrices.append(computeSkinMatrix(
                worldMatrix: joint.worldMatrix,
                inverseBindMatrix: skin.inverseBindMatrices[idx]
            ))
        }

        // Check that skin matrices don't have extreme values
        var maxTranslation: Float = 0
        for (idx, matrix) in skinMatrices.enumerated() {
            let translation = extractTranslation(matrix)
            let magnitude = simd_length(translation)

            if magnitude > maxTranslation {
                maxTranslation = magnitude
            }

            // No matrix should have translation > 100 units
            if magnitude > 100 {
                print("⚠️ Joint \(idx) skin matrix has large translation: \(magnitude)")
            }

            XCTAssertLessThan(magnitude, 100,
                "Joint \(idx) skin matrix has extreme translation (\(magnitude))")
        }

        print("\n=== Animated Pose Validation ===")
        print("Max skin matrix translation: \(maxTranslation)")
    }
}
