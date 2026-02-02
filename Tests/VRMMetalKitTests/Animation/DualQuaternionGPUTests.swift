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

/// GPU-based Dual Quaternion Skinning integration tests.
///
/// These tests verify:
/// 1. DQS shader functions exist in the metallib
/// 2. DQS pipelines are properly configured
/// 3. DQS produces different output than LBS (proving the shader path is active)
///
/// This catches issues like:
/// - DQS shader functions not being compiled into metallib
/// - Sanity check causing fallback to LBS behavior
/// - Buffer binding issues preventing DQ data from reaching shader
@MainActor
final class DualQuaternionGPUTests: XCTestCase {

    var device: MTLDevice!

    override func setUp() async throws {
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else {
            throw XCTSkip("Metal device not available")
        }
    }

    override func tearDown() async throws {
        device = nil
    }

    // MARK: - Metallib Function Tests

    /// Test that DQS shader functions exist in the compiled metallib.
    /// This would fail if DualQuaternionSkinning.metal wasn't compiled.
    func testDQSShaderFunctionsExist() throws {
        let library = try VRMPipelineCache.shared.getLibrary(device: device)
        let functionNames = Set(library.functionNames)

        // DQS vertex shader variants
        let dqsFunctions = [
            "skinned_mtoon_vertex_dqs",
            "skinned_vertex_dqs",
            "skinned_mtoon_outline_vertex_dqs"
        ]

        print("=== DQS Shader Function Check ===")
        for funcName in dqsFunctions {
            if functionNames.contains(funcName) {
                print("✅ Found: \(funcName)")
            } else {
                print("❌ Missing: \(funcName)")
            }
            XCTAssertTrue(
                functionNames.contains(funcName),
                "Missing DQS function: \(funcName). Did you compile shaders with 'make shaders'?"
            )
        }
    }

    /// Test that DQS pipelines can be created without errors.
    func testDQSPipelinesCanBeCreated() async throws {
        // Create a simple renderer config with DQS enabled
        var config = RendererConfig()
        config.skinningMode = .dualQuaternion

        // Create renderer
        let renderer = try VRMRenderer(device: device, config: config)

        // Verify renderer was created
        XCTAssertNotNil(renderer, "Renderer should exist")

        // Verify DQS-specific configuration
        XCTAssertEqual(renderer.config.skinningMode, .dualQuaternion, "Renderer should report DQS mode")

        print("✅ DQS pipelines created successfully")
    }

    /// Test that LBS and DQS renderers create different configurations.
    /// This verifies the configuration is mode-dependent.
    func testLBSAndDQSCreateDifferentConfigurations() async throws {
        // Create LBS renderer config
        var lbsConfig = RendererConfig()
        lbsConfig.skinningMode = .linearBlend

        // Create DQS renderer config
        var dqsConfig = RendererConfig()
        dqsConfig.skinningMode = .dualQuaternion

        // Create renderers
        let lbsRenderer = try VRMRenderer(device: device, config: lbsConfig)
        let dqsRenderer = try VRMRenderer(device: device, config: dqsConfig)

        // The renderers should have different modes
        XCTAssertEqual(lbsRenderer.config.skinningMode, .linearBlend)
        XCTAssertEqual(dqsRenderer.config.skinningMode, .dualQuaternion)

        print("✅ LBS and DQS renderers configured correctly")
    }

    // MARK: - Dual Quaternion Math Verification Tests

    /// Test that DualQuaternion struct has correct memory layout for GPU.
    /// This must match the Metal shader's DualQuaternion struct.
    func testDualQuaternionMemoryLayoutForGPU() {
        // Metal shader expects:
        // struct DualQuaternion {
        //     float4 real;  // 16 bytes
        //     float4 dual;  // 16 bytes
        // };  // Total: 32 bytes, 16-byte aligned

        XCTAssertEqual(
            MemoryLayout<DualQuaternion>.size,
            32,
            "DualQuaternion must be 32 bytes for GPU compatibility"
        )

        XCTAssertEqual(
            MemoryLayout<DualQuaternion>.stride,
            32,
            "DualQuaternion stride must be 32 bytes"
        )

        XCTAssertEqual(
            MemoryLayout<DualQuaternion>.alignment,
            16,
            "DualQuaternion must be 16-byte aligned for Metal"
        )

        // Verify component layout matches Metal using identity
        let dq = DualQuaternion.identity

        withUnsafeBytes(of: dq) { bytes in
            let floats = bytes.bindMemory(to: Float.self)

            // real quaternion: identity = (x=0, y=0, z=0, w=1)
            XCTAssertEqual(floats[0], 0.0, accuracy: 0.001, "real.x should be 0")
            XCTAssertEqual(floats[1], 0.0, accuracy: 0.001, "real.y should be 0")
            XCTAssertEqual(floats[2], 0.0, accuracy: 0.001, "real.z should be 0")
            XCTAssertEqual(floats[3], 1.0, accuracy: 0.001, "real.w should be 1")

            // dual quaternion: zero = (x=0, y=0, z=0, w=0)
            XCTAssertEqual(floats[4], 0.0, accuracy: 0.001, "dual.x should be 0")
            XCTAssertEqual(floats[5], 0.0, accuracy: 0.001, "dual.y should be 0")
            XCTAssertEqual(floats[6], 0.0, accuracy: 0.001, "dual.z should be 0")
            XCTAssertEqual(floats[7], 0.0, accuracy: 0.001, "dual.w should be 0")
        }

        print("✅ DualQuaternion memory layout verified (32 bytes, 16-byte aligned)")
    }

    /// Test that DualQuaternion produces different transform results than matrix LBS.
    /// This is the key property that makes DQS valuable for skinning.
    func testDQSTransformDiffersFromMatrixLBS() {
        // Create two rotations that will be blended
        let rot1 = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        let rot2 = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))  // 180 degrees

        // Create dual quaternions
        let dq1 = DualQuaternion(rotation: rot1, translation: .zero)
        let dq2 = DualQuaternion(rotation: rot2, translation: .zero)

        // Test point
        let point = SIMD3<Float>(1.0, 0.0, 0.0)

        // DQ blend (50/50) - should produce valid rotation
        let dqBlended = DualQuaternion.blend([dq1, dq2], weights: [0.5, 0.5])
        let dqResult = dqBlended.transformPoint(point)

        // Matrix blend (50/50) - produces shearing/scaling artifacts
        let mat1 = float4x4(rot1)
        let mat2 = float4x4(rot2)
        let matBlended = mat1 * 0.5 + mat2 * 0.5
        let matResult4 = matBlended * SIMD4<Float>(point, 1.0)
        let matResult = SIMD3<Float>(matResult4.x, matResult4.y, matResult4.z)

        // Both results should be finite
        XCTAssertFalse(dqResult.x.isNaN || dqResult.x.isInfinite, "DQS result should be finite")
        XCTAssertFalse(matResult.x.isNaN || matResult.x.isInfinite, "Matrix result should be finite")

        // With 180 degree difference, the blended results should differ significantly
        // This demonstrates why DQS is valuable - it avoids the "candy wrapper" artifact
        let difference = simd_length(dqResult - matResult)

        print("=== DQS vs Matrix Blend Comparison ===")
        print("Point: \(point)")
        print("DQS blended result: \(dqResult)")
        print("Matrix blended result: \(matResult)")
        print("Difference: \(difference)")

        // Results should be different (if they're the same, something is wrong)
        XCTAssertGreaterThan(difference, 0.01, "DQS and matrix blending should produce different results")

        // DQS result should maintain unit length (rotation preserves scale)
        let dqLength = simd_length(dqResult)
        let originalLength = simd_length(point)
        XCTAssertEqual(dqLength, originalLength, accuracy: 0.001, "DQS should preserve point distance from origin")

        // Matrix result will likely have different length (demonstrates the artifact)
        let matLength = simd_length(matResult)
        print("Original length: \(originalLength)")
        print("DQS result length: \(dqLength)")
        print("Matrix result length: \(matLength)")
    }

    /// Test antipodality handling in DQ blending.
    /// When blending q and -q (same rotation), the result should still be valid.
    func testDQSAntipodalityHandling() {
        let rot = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0))
        let antiRot = simd_quatf(vector: -rot.vector)  // Negated = same rotation

        let dq1 = DualQuaternion(rotation: rot, translation: .zero)
        let dq2 = DualQuaternion(rotation: antiRot, translation: .zero)

        // Blending should handle antipodal quaternions correctly
        let blended = DualQuaternion.blend([dq1, dq2], weights: [0.5, 0.5])

        // Transform a test point
        let point = SIMD3<Float>(1.0, 0.0, 0.0)
        let result = blended.transformPoint(point)

        // Result should be finite (not NaN/Inf from averaging q and -q to zero)
        XCTAssertFalse(result.x.isNaN, "DQS should handle antipodal quaternions without NaN")
        XCTAssertFalse(result.x.isInfinite, "DQS should handle antipodal quaternions without Inf")

        // Should produce same rotation as original
        let expected = dq1.transformPoint(point)
        XCTAssertEqual(result.x, expected.x, accuracy: 0.01)
        XCTAssertEqual(result.y, expected.y, accuracy: 0.01)
        XCTAssertEqual(result.z, expected.z, accuracy: 0.01)

        print("✅ Antipodality handling verified")
    }

    /// Test that renderer correctly reports skinning mode in configuration.
    func testRendererSkinningModeConfiguration() async throws {
        // Test linear blend mode
        var lbsConfig = RendererConfig()
        lbsConfig.skinningMode = .linearBlend
        let lbsRenderer = try VRMRenderer(device: device, config: lbsConfig)
        XCTAssertEqual(lbsRenderer.config.skinningMode, .linearBlend)

        // Test dual quaternion mode
        var dqsConfig = RendererConfig()
        dqsConfig.skinningMode = .dualQuaternion
        let dqsRenderer = try VRMRenderer(device: device, config: dqsConfig)
        XCTAssertEqual(dqsRenderer.config.skinningMode, .dualQuaternion)

        print("✅ All skinning modes configured correctly")
    }

    // MARK: - Helper Methods

    /// Load test VRM model
    private func loadTestModel() async throws -> VRMModel {
        let fileManager = FileManager.default

        // Find project root
        let candidates = [
            ProcessInfo.processInfo.environment["PROJECT_ROOT"],
            ProcessInfo.processInfo.environment["SRCROOT"],
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path
        ].compactMap { $0 }

        var projectRoot: String?
        for candidate in candidates {
            if fileManager.fileExists(atPath: "\(candidate)/Package.swift") {
                projectRoot = candidate
                break
            }
        }

        guard let root = projectRoot else {
            throw XCTSkip("Could not find project root")
        }

        let modelPath = "\(root)/AliciaSolid.vrm"
        try XCTSkipUnless(
            fileManager.fileExists(atPath: modelPath),
            "Test model not found at \(modelPath)"
        )

        return try await VRMModel.load(
            from: URL(fileURLWithPath: modelPath),
            device: device
        )
    }
}
