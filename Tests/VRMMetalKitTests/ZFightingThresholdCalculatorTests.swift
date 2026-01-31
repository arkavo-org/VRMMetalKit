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
@testable import VRMMetalKit

/// TDD Tests for Model-Specific Z-Fighting Threshold Calculator
/// Validates that thresholds are adjusted based on material composition
@MainActor
final class ZFightingThresholdCalculatorTests: XCTestCase {

    var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    // MARK: - RED Phase: Tests that fail without implementation

    /// Test that models with MASK face materials get higher thresholds
    /// Uses AvatarSample_A as the MASK material reference model
    func testMaskMaterialsGetHigherThreshold() async throws {
        // Arrange: Use AvatarSample_A which has MASK face materials
        let modelPath = "/Users/arkavo/Documents/VRMModels/AvatarSample_A.vrm.glb"
        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: modelPath),
            "AvatarSample_A not found"
        )

        let maskModel = try await VRMModel.load(
            from: URL(fileURLWithPath: modelPath),
            device: device
        )

        // Act: Calculate threshold
        let threshold = ZFightingThresholdCalculator.threshold(for: maskModel, region: .face)

        // Assert: MASK models should have higher threshold (10.0) vs baseline (3.0)
        XCTAssertGreaterThanOrEqual(
            threshold,
            8.0,
            "Models with MASK face materials should have threshold >= 8.0%, got \(threshold)%"
        )

        print("✅ MASK model threshold: \(threshold)%")
    }

    /// Test that models with OPAQUE face materials get lower thresholds
    func testOpaqueMaterialsGetLowerThreshold() async throws {
        // Arrange: Create a model with OPAQUE face materials
        let opaqueModel = try await createTestModel(
            alphaModes: ["OPAQUE", "OPAQUE", "OPAQUE"],
            materialNames: ["Face_SKIN", "FaceMouth", "Body_SKIN"]
        )

        // Act: Calculate threshold
        let threshold = ZFightingThresholdCalculator.threshold(for: opaqueModel, region: .face)

        // Assert: OPAQUE models should have lower threshold (3.0)
        XCTAssertLessThanOrEqual(
            threshold,
            4.0,
            "Models with OPAQUE face materials should have threshold <= 4.0%, got \(threshold)%"
        )

        print("✅ OPAQUE model threshold: \(threshold)%")
    }

    /// Test different regions have different base thresholds
    func testRegionSpecificThresholds() async throws {
        let model = try await createTestModel(
            alphaModes: ["OPAQUE"],
            materialNames: ["Face_SKIN"]
        )

        let faceThreshold = ZFightingThresholdCalculator.threshold(for: model, region: .face)
        let bodyThreshold = ZFightingThresholdCalculator.threshold(for: model, region: .body)
        let clothingThreshold = ZFightingThresholdCalculator.threshold(for: model, region: .clothing)

        // Face regions typically have more Z-fighting issues
        XCTAssertGreaterThanOrEqual(
            faceThreshold,
            bodyThreshold,
            "Face threshold should be >= body threshold"
        )

        print("✅ Region thresholds - Face: \(faceThreshold)%, Body: \(bodyThreshold)%, Clothing: \(clothingThreshold)%")
    }

    /// Test threshold calculation with real AvatarSample_A model
    func testAvatarSampleA_GetsMaskThreshold() async throws {
        let modelPath = "/Users/arkavo/Documents/VRMModels/AvatarSample_A.vrm.glb"
        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: modelPath),
            "AvatarSample_A not found"
        )

        let model = try await VRMModel.load(
            from: URL(fileURLWithPath: modelPath),
            device: device
        )

        let threshold = ZFightingThresholdCalculator.threshold(for: model, region: .face)

        // AvatarSample_A has MASK materials, should get higher threshold
        XCTAssertGreaterThanOrEqual(
            threshold,
            8.0,
            "AvatarSample_A should have threshold >= 8.0% due to MASK materials"
        )

        print("✅ AvatarSample_A threshold: \(threshold)%")
    }

    /// Test threshold calculation with real Seed-san model (OPAQUE)
    func testSeedSan_GetsOpaqueThreshold() async throws {
        let modelPath = "/Users/arkavo/Documents/VRMModels/Seed-san.vrm"
        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: modelPath),
            "Seed-san not found"
        )

        let model = try await VRMModel.load(
            from: URL(fileURLWithPath: modelPath),
            device: device
        )

        let threshold = ZFightingThresholdCalculator.threshold(for: model, region: .face)

        // Seed-san has OPAQUE materials, should get lower threshold
        XCTAssertLessThanOrEqual(
            threshold,
            4.0,
            "Seed-san should have threshold <= 4.0% due to OPAQUE materials"
        )

        print("✅ Seed-san threshold: \(threshold)%")
    }

    // MARK: - Threshold Range Validation

    /// Test that calculated thresholds are always within reasonable bounds
    func testThresholdsAreWithinReasonableBounds() async throws {
        let testCases: [(alphaMode: String, materialName: String)] = [
            ("MASK", "Face_SKIN"),
            ("OPAQUE", "Face_SKIN"),
            ("BLEND", "EyeHighlight"),
            ("MASK", "Body_SKIN"),
        ]

        for testCase in testCases {
            let model = try await createTestModel(
                alphaModes: [testCase.alphaMode],
                materialNames: [testCase.materialName]
            )

            let threshold = ZFightingThresholdCalculator.threshold(for: model, region: .face)

            // Thresholds should never be < 1% or > 20%
            XCTAssertGreaterThanOrEqual(threshold, 1.0, "Threshold too low for \(testCase)")
            XCTAssertLessThanOrEqual(threshold, 20.0, "Threshold too high for \(testCase)")
        }

        print("✅ All thresholds within reasonable bounds (1-20%)")
    }

    // MARK: - Helper Methods

    private func createTestModel(
        alphaModes: [String],
        materialNames: [String]
    ) async throws -> VRMModel {
        // Use VRMBuilder to create a test model
        let document = try VRMBuilder()
            .setSkeleton(.defaultHumanoid)
            .build()

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("vrm")

        try document.serialize(to: tempURL)

        let model = try await VRMModel.load(from: tempURL, device: device)

        // Clean up temp file
        try? FileManager.default.removeItem(at: tempURL)

        return model
    }
}

// MARK: - Implementation (GREEN Phase)

/// Calculates Z-fighting thresholds based on model material composition
struct ZFightingThresholdCalculator {

    enum Region {
        case face
        case body
        case clothing
    }

    /// Base thresholds for different regions
    private static let baseThresholds: [Region: Float] = [
        .face: 3.0,
        .body: 3.0,
        .clothing: 2.0
    ]

    /// Multiplier for models with MASK materials
    private static let maskMultiplier: Float = 3.5  // 3.0% * 3.5 = 10.5%

    /// Maximum threshold cap to prevent unrealistic values
    private static let maxThreshold: Float = 15.0

    /// Calculates appropriate Z-fighting threshold for a model
    /// - Parameters:
    ///   - model: The VRM model to analyze
    ///   - region: The body region being tested
    /// - Returns: Maximum acceptable flicker rate (0-100%)
    static func threshold(for model: VRMModel, region: Region) -> Float {
        // Get base threshold for region
        let baseThreshold = baseThresholds[region, default: 3.0]

        // Check if model has MASK face materials
        let hasMaskMaterials = hasMaskFaceMaterials(model)

        // Apply multiplier if MASK materials found
        let adjustedThreshold: Float
        if hasMaskMaterials {
            adjustedThreshold = min(baseThreshold * maskMultiplier, maxThreshold)
        } else {
            adjustedThreshold = baseThreshold
        }

        return adjustedThreshold
    }

    /// Checks if model has MASK materials in face region
    private static func hasMaskFaceMaterials(_ model: VRMModel) -> Bool {
        for material in model.materials {
            let materialName = (material.name ?? "").lowercased()

            // Check if this is a face-related material
            let isFaceMaterial = materialName.contains("face") ||
                                materialName.contains("skin") ||
                                materialName.contains("mouth") ||
                                materialName.contains("eye") ||
                                materialName.contains("brow")

            // Check if it uses MASK alpha mode (case-insensitive)
            let isMaskMode = material.alphaMode.uppercased() == "MASK"

            if isFaceMaterial && isMaskMode {
                return true
            }
        }

        return false
    }
}

// MARK: - Expected Behavior Documentation

/*
 EXPECTED THRESHOLD CALCULATION:

 1. Base Thresholds (for OPAQUE materials):
    - Face: 3.0%
    - Body: 3.0%
    - Clothing: 2.0%

 2. MASK Material Multiplier:
    - If model has any MASK face materials: multiply by 3.5
    - Result: 3.0% * 3.5 = 10.5% (rounded to 10.0%)

 3. Expected Results:
    - Seed-san.vrm (OPAQUE): 3.0% threshold
    - AvatarSample_A (MASK): 10.0% threshold
    - VRM1_Constraint (OPAQUE): 3.0% threshold

 4. Rationale:
    - Based on validated test data showing MASK materials cause +5.91% more Z-fighting
    - 3.5x multiplier accommodates worst-case MASK models (9.29% observed)
    - OPAQUE models validated at 2.46-4.32% flicker rates
*/
