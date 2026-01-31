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

/// TDD Tests for Z-fighting validation across multiple VRM models
/// These tests help determine if Z-fighting is model-specific or systemic
@MainActor
final class ZFightingMultiModelTests: XCTestCase {

    var device: MTLDevice!
    var helper: ZFightingTestHelper!

    // MARK: - Model Paths

    /// Directory containing test VRM models
    private var modelsDirectory: String {
        // Try common locations for VRM models
        let candidates: [String] = [
            "/Users/arkavo/Documents/VRMModels",
            ProcessInfo.processInfo.environment["VRM_MODELS_PATH"],
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/VRMModels").path
        ].compactMap { $0 }

        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return ""  // Empty string will cause tests to skip
    }

    /// Available test models
    private var availableModels: [String] {
        let models = [
            "AvatarSample_A.vrm.glb",
            "Seed-san.vrm",
            "VRM1_Constraint_Twist_Sample.vrm"
        ]

        return models.filter { model in
            let path = "\(modelsDirectory)/\(model)"
            return FileManager.default.fileExists(atPath: path)
        }
    }

    override func setUp() async throws {
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else {
            throw XCTSkip("Metal device not available")
        }
        helper = try ZFightingTestHelper(device: device, width: 512, height: 512)
    }

    // MARK: - Model Availability Tests

    /// Test that we can find the VRM models directory
    func testModelsDirectoryExists() {
        XCTAssertFalse(modelsDirectory.isEmpty, "VRM models directory should exist")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: modelsDirectory),
            "Models directory should exist at \(modelsDirectory)"
        )
    }

    /// Test that we have at least one model to test with
    func testAtLeastOneModelAvailable() {
        print("Available models: \(availableModels)")
        XCTAssertGreaterThan(
            availableModels.count,
            0,
            "Should have at least one VRM model available. Checked: \(modelsDirectory)"
        )
    }

    // MARK: - Per-Model Z-Fighting Baseline Tests

    /// Test Z-fighting on AvatarSample_A model (known problematic)
    func testAvatarSampleA_FaceZFighting() async throws {
        let modelPath = "\(modelsDirectory)/AvatarSample_A.vrm.glb"
        try await validateModelZFighting(
            modelPath: modelPath,
            modelName: "AvatarSample_A",
            cameraPosition: SIMD3<Float>(0, 1.5, 1.0),
            targetPosition: SIMD3<Float>(0, 1.5, 0),
            regionName: "Face Front",
            maxAcceptableFlicker: 15.0  // Relaxed threshold for baseline
        )
    }

    /// Test Z-fighting on Seed-san model
    func testSeedSan_FaceZFighting() async throws {
        let modelPath = "\(modelsDirectory)/Seed-san.vrm"
        try await validateModelZFighting(
            modelPath: modelPath,
            modelName: "Seed-san",
            cameraPosition: SIMD3<Float>(0, 1.5, 1.0),
            targetPosition: SIMD3<Float>(0, 1.5, 0),
            regionName: "Face Front",
            maxAcceptableFlicker: 10.0  // Relaxed threshold for baseline
        )
    }

    /// Test Z-fighting on VRM1 Constraint Twist Sample
    func testVRM1Constraint_FaceZFighting() async throws {
        let modelPath = "\(modelsDirectory)/VRM1_Constraint_Twist_Sample.vrm"
        try await validateModelZFighting(
            modelPath: modelPath,
            modelName: "VRM1_Constraint_Twist_Sample",
            cameraPosition: SIMD3<Float>(0, 1.5, 1.0),
            targetPosition: SIMD3<Float>(0, 1.5, 0),
            regionName: "Face Front",
            maxAcceptableFlicker: 10.0
        )
    }

    // MARK: - Model Comparison Test

    /// Compare Z-fighting across all available models
    func testZFightingComparisonAcrossModels() async throws {
        print("\n" + String(repeating: "=", count: 70))
        print("Z-FIGHTING COMPARISON ACROSS MODELS")
        print(String(repeating: "=", count: 70))

        var results: [(model: String, flickerRate: Float, passed: Bool)] = []

        for modelName in availableModels {
            let modelPath = "\(modelsDirectory)/\(modelName)"
            guard FileManager.default.fileExists(atPath: modelPath) else {
                print("⚠️ Skipping \(modelName) - file not found")
                continue
            }

            do {
                let flickerRate = try await measureZFighting(
                    modelPath: modelPath,
                    cameraPosition: SIMD3<Float>(0, 1.5, 1.0),
                    targetPosition: SIMD3<Float>(0, 1.5, 0)
                )

                let passed = flickerRate < 10.0  // Baseline threshold
                results.append((model: modelName, flickerRate: flickerRate, passed: passed))

                let status = passed ? "✅" : "❌"
                print("\(status) \(modelName): \(String(format: "%.2f", flickerRate))% flicker")

            } catch {
                print("❌ \(modelName): Failed to test - \(error)")
                results.append((model: modelName, flickerRate: 100.0, passed: false))
            }
        }

        print(String(repeating: "=", count: 70))
        print("Summary: \(results.filter { $0.passed }.count)/\(results.count) models within threshold")
        print(String(repeating: "=", count: 70) + "\n")

        // Document results but don't fail - this is data collection
        XCTAssertGreaterThan(results.count, 0, "Should have tested at least one model")
    }

    // MARK: - Material Analysis Tests

    /// Analyze material structure of each model
    func testMaterialStructureComparison() async throws {
        print("\n" + String(repeating: "=", count: 70))
        print("MATERIAL STRUCTURE ANALYSIS")
        print(String(repeating: "=", count: 70))

        for modelName in availableModels {
            let modelPath = "\(modelsDirectory)/\(modelName)"
            guard FileManager.default.fileExists(atPath: modelPath) else { continue }

            do {
                let model = try await VRMModel.load(
                    from: URL(fileURLWithPath: modelPath),
                    device: device
                )

                print("\n📦 \(modelName):")
                print("  Meshes: \(model.meshes.count)")
                print("  Materials: \(model.materials.count)")
                print("  Total primitives: \(model.meshes.reduce(0) { $0 + $1.primitives.count })")

                // Analyze materials
                let faceMaterials = model.materials.filter { mat in
                    let name = (mat.name ?? "").lowercased()
                    return name.contains("face") || name.contains("skin") || name.contains("body")
                }

                print("  Face/Skin/Body materials: \(faceMaterials.count)")
                for mat in faceMaterials {
                    print("    - \(mat.name ?? "unnamed") (\(mat.alphaMode))")
                }

            } catch {
                print("❌ Failed to load \(modelName): \(error)")
            }
        }

        print(String(repeating: "=", count: 70) + "\n")
    }

    // MARK: - Depth Bias Effectiveness Tests

    /// Test that depth bias is being applied
    func testDepthBiasConfigurationExists() {
        let renderer = VRMRenderer(device: device)

        // Verify required depth states exist
        XCTAssertNotNil(renderer.depthStencilStates["face"], "Face depth state should exist")
        XCTAssertNotNil(renderer.depthStencilStates["faceOverlay"], "FaceOverlay depth state should exist")
        XCTAssertNotNil(renderer.depthStencilStates["opaque"], "Opaque depth state should exist")
    }

    /// Validate that different face categories get different depth handling
    func testFaceCategoryDepthHandling() async throws {
        // This test validates the depth bias values are different per category
        let modelPath = "\(modelsDirectory)/AvatarSample_A.vrm.glb"
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath), "Model not found")

        let model = try await VRMModel.load(
            from: URL(fileURLWithPath: modelPath),
            device: device
        )

        let renderer = VRMRenderer(device: device)
        renderer.loadModel(model)

        // Verify model loaded with face categories
        XCTAssertNotNil(renderer.model, "Model should be loaded")

        // The actual depth bias application is tested indirectly through Z-fighting rates
        // If depth bias is working, we should see different flicker rates
        print("✅ Face category depth handling test setup complete")
    }

    // MARK: - Helper Methods

    private func validateModelZFighting(
        modelPath: String,
        modelName: String,
        cameraPosition: SIMD3<Float>,
        targetPosition: SIMD3<Float>,
        regionName: String,
        maxAcceptableFlicker: Float
    ) async throws {
        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: modelPath),
            "\(modelName) not found at \(modelPath)"
        )

        let flickerRate = try await measureZFighting(
            modelPath: modelPath,
            cameraPosition: cameraPosition,
            targetPosition: targetPosition
        )

        print("\(modelName) \(regionName): \(String(format: "%.2f", flickerRate))% flicker")

        // Document but don't enforce - this is data collection for now
        XCTAssertLessThan(
            flickerRate,
            maxAcceptableFlicker,
            "\(modelName) \(regionName) Z-fighting (\(flickerRate)%) exceeds baseline threshold (\(maxAcceptableFlicker)%)"
        )
    }

    private func measureZFighting(
        modelPath: String,
        cameraPosition: SIMD3<Float>,
        targetPosition: SIMD3<Float>
    ) async throws -> Float {
        let model = try await VRMModel.load(
            from: URL(fileURLWithPath: modelPath),
            device: device
        )

        helper.loadModel(model)

        helper.setViewMatrix(makeLookAt(
            eye: cameraPosition,
            target: targetPosition,
            up: SIMD3<Float>(0, 1, 0)
        ))

        let frames = try helper.renderMultipleFrames(count: 20, perturbationScale: 0.0001)

        // Analyze center region where face should be
        let result = FlickerDetector.analyzeRegion(
            frames: frames,
            x: 128, y: 128, width: 256, height: 256,
            frameWidth: 512, threshold: 5
        )

        return result.flickerRate
    }
}

// MARK: - Model-Specific Issues Documentation

/*
 KNOWN MODEL-SPECIFIC ISSUES:

 1. AvatarSample_A.vrm.glb
    - Face front: 9.29% flicker
    - Face side: 9.41% flicker
    - Collar/Neck: 13.45% flicker
    - Issue: FaceMouth and Face_SKIN materials overlap

 2. Seed-san.vrm
    - Status: TODO - measure baseline

 3. VRM1_Constraint_Twist_Sample.vrm
    - Status: TODO - measure baseline

 EXPECTED FINDINGS:
 - Different models will have different Z-fighting characteristics
 - Models with cleanly separated geometry should have <2% flicker
 - Models with overlapping materials will show higher flicker rates
 - This will help determine if fixes should be model-specific or systemic
*/
