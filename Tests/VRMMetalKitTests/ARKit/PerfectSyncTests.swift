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
@testable import VRMMetalKit

/// Tests for Perfect Sync capability detection and mapping.
///
/// Perfect Sync enables 1:1 mapping of ARKit's 52 facial blend shapes to VRM
/// avatar expressions for higher fidelity facial animation.
final class PerfectSyncTests: XCTestCase {

    // MARK: - Capability Detection Tests

    func testCapabilityDetection_None_NoExpressions() {
        let model = createMockModel(customExpressionNames: [])
        let result = PerfectSyncCapability.detect(from: model)

        XCTAssertEqual(result.capability, .none)
        XCTAssertEqual(result.capability.description, "none (standard composite mapping)")
        XCTAssertEqual(result.capability.directMappingCount, 0)
        XCTAssertTrue(result.nameMapping.isEmpty)
    }

    func testCapabilityDetection_None_NonARKitExpressions() {
        let model = createMockModel(customExpressionNames: [
            "customSmile", "customFrown", "customWink", "myExpression1", "myExpression2"
        ])
        let result = PerfectSyncCapability.detect(from: model)

        XCTAssertEqual(result.capability, .none)
    }

    func testCapabilityDetection_None_BelowThreshold() {
        // 20 ARKit names is below the threshold of 30
        let arkitNames = Array(ARKitFaceBlendShapes.allKeys.prefix(20))
        let model = createMockModel(customExpressionNames: arkitNames)
        let result = PerfectSyncCapability.detect(from: model)

        XCTAssertEqual(result.capability, .none)
    }

    func testCapabilityDetection_Partial() {
        // 35 ARKit names should be partial (threshold is 30)
        let arkitNames = Array(ARKitFaceBlendShapes.allKeys.prefix(35))
        let model = createMockModel(customExpressionNames: arkitNames)
        let result = PerfectSyncCapability.detect(from: model)

        if case .partial(let matched, let missing) = result.capability {
            XCTAssertEqual(matched.count, 35)
            XCTAssertEqual(missing.count, 52 - 35)
            XCTAssertTrue(result.capability.description.contains("partial"))
        } else {
            XCTFail("Expected .partial capability")
        }
    }

    func testCapabilityDetection_Full() {
        // All 52 ARKit names
        let model = createMockModel(customExpressionNames: ARKitFaceBlendShapes.allKeys)
        let result = PerfectSyncCapability.detect(from: model)

        XCTAssertEqual(result.capability, .full)
        XCTAssertEqual(result.capability.description, "full (52 direct mappings)")
        XCTAssertEqual(result.capability.directMappingCount, 52)
    }

    func testCapabilityDetection_Full_WithExtraExpressions() {
        // All 52 ARKit names plus some extra custom expressions
        var names = ARKitFaceBlendShapes.allKeys
        names.append(contentsOf: ["extraExpression1", "extraExpression2", "customSmile"])
        let model = createMockModel(customExpressionNames: names)
        let result = PerfectSyncCapability.detect(from: model)

        XCTAssertEqual(result.capability, .full)
    }

    func testCapabilityDetection_PascalCase() {
        // ARKit names in PascalCase (VRoid/HANA_Tool style) should match
        let pascalCaseNames = ARKitFaceBlendShapes.allKeys.map { name -> String in
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        let model = createMockModel(customExpressionNames: pascalCaseNames)
        let result = PerfectSyncCapability.detect(from: model)

        XCTAssertEqual(result.capability, .full)
        XCTAssertEqual(result.nameMapping.count, 52)
        // Verify mapping translates ARKit -> PascalCase
        XCTAssertEqual(result.nameMapping["eyeBlinkLeft"], "EyeBlinkLeft")
    }

    func testCapabilityDetection_SnakeCase() {
        // ARKit names in snake_case should match
        let snakeCaseNames = ARKitFaceBlendShapes.allKeys.map { name -> String in
            // Convert camelCase to snake_case
            var result = ""
            for char in name {
                if char.isUppercase {
                    result += "_" + char.lowercased()
                } else {
                    result += String(char)
                }
            }
            return result
        }
        let model = createMockModel(customExpressionNames: snakeCaseNames)
        let result = PerfectSyncCapability.detect(from: model)

        XCTAssertEqual(result.capability, .full)
        XCTAssertEqual(result.nameMapping.count, 52)
        // Verify mapping translates ARKit -> snake_case
        XCTAssertEqual(result.nameMapping["eyeBlinkLeft"], "eye_blink_left")
    }

    // MARK: - Direct Mapping Tests

    func testUsesDirectMapping_None() {
        let capability = PerfectSyncCapability.none

        XCTAssertFalse(capability.usesDirectMapping(for: "eyeBlinkLeft"))
        XCTAssertFalse(capability.usesDirectMapping(for: "mouthSmileRight"))
    }

    func testUsesDirectMapping_Full() {
        let capability = PerfectSyncCapability.full

        XCTAssertTrue(capability.usesDirectMapping(for: "eyeBlinkLeft"))
        XCTAssertTrue(capability.usesDirectMapping(for: "mouthSmileRight"))
        XCTAssertTrue(capability.usesDirectMapping(for: "browInnerUp"))
    }

    func testUsesDirectMapping_Partial() {
        let matched: Set<String> = ["eyeBlinkLeft", "eyeBlinkRight", "mouthSmileLeft"]
        let missing: Set<String> = ["jawOpen", "tongueOut"]
        let capability = PerfectSyncCapability.partial(matched: matched, missing: missing)

        XCTAssertTrue(capability.usesDirectMapping(for: "eyeBlinkLeft"))
        XCTAssertTrue(capability.usesDirectMapping(for: "mouthSmileLeft"))
        XCTAssertFalse(capability.usesDirectMapping(for: "jawOpen"))
        XCTAssertFalse(capability.usesDirectMapping(for: "tongueOut"))
    }

    // MARK: - Mapper Tests

    func testMapper_Full_DirectPassthrough() {
        let capability = PerfectSyncCapability.full
        let mapper = PerfectSyncMapper(capability: capability)

        let blendShapes = createMockBlendShapes([
            "eyeBlinkLeft": 0.8,
            "eyeBlinkRight": 0.7,
            "mouthSmileLeft": 0.5,
            "jawOpen": 0.3
        ])

        let (custom, preset) = mapper.evaluate(blendShapes)

        // Full mode: all 52 shapes go to custom, none to preset
        XCTAssertEqual(custom.count, 52)
        XCTAssertEqual(preset.count, 0)
        XCTAssertEqual(custom["eyeBlinkLeft"], 0.8)
        XCTAssertEqual(custom["eyeBlinkRight"], 0.7)
        XCTAssertEqual(custom["mouthSmileLeft"], 0.5)
        XCTAssertEqual(custom["jawOpen"], 0.3)
    }

    func testMapper_None_CompositeOnly() {
        let capability = PerfectSyncCapability.none
        let mapper = PerfectSyncMapper(capability: capability)

        let blendShapes = createMockBlendShapes([
            "eyeBlinkLeft": 0.8,
            "eyeBlinkRight": 0.8
        ])

        let (custom, preset) = mapper.evaluate(blendShapes)

        // None mode: no custom, all go through composite mapper
        XCTAssertEqual(custom.count, 0)
        XCTAssertGreaterThan(preset.count, 0)
        // Default mapper should produce blink weight
        XCTAssertNotNil(preset["blink"])
    }

    func testMapper_Partial_HybridMapping() {
        let matched: Set<String> = Set(ARKitFaceBlendShapes.allKeys.prefix(35))
        let missing: Set<String> = Set(ARKitFaceBlendShapes.allKeys.suffix(17))
        let capability = PerfectSyncCapability.partial(matched: matched, missing: missing)
        let mapper = PerfectSyncMapper(capability: capability)

        let blendShapes = createMockBlendShapes([
            "eyeBlinkLeft": 0.9,
            "eyeBlinkRight": 0.9
        ])

        let (custom, preset) = mapper.evaluate(blendShapes)

        // Partial mode: matched shapes go to custom, composite mapping also produced
        XCTAssertEqual(custom.count, 35)
        XCTAssertGreaterThan(preset.count, 0)
    }

    func testMapper_HasMappings() {
        let fullMapper = PerfectSyncMapper(capability: .full)
        XCTAssertTrue(fullMapper.hasCustomMappings)
        XCTAssertFalse(fullMapper.hasPresetMappings)

        let noneMapper = PerfectSyncMapper(capability: .none)
        XCTAssertFalse(noneMapper.hasCustomMappings)
        XCTAssertTrue(noneMapper.hasPresetMappings)

        let matched: Set<String> = ["eyeBlinkLeft"]
        let missing: Set<String> = ["jawOpen"]
        let partialMapper = PerfectSyncMapper(capability: .partial(matched: matched, missing: missing))
        XCTAssertTrue(partialMapper.hasCustomMappings)
        XCTAssertTrue(partialMapper.hasPresetMappings)
    }

    func testMapper_EvaluateCustomOnly() {
        let capability = PerfectSyncCapability.full
        let mapper = PerfectSyncMapper(capability: capability)

        let blendShapes = createMockBlendShapes([
            "eyeBlinkLeft": 0.5,
            "jawOpen": 0.3
        ])

        let custom = mapper.evaluateCustomOnly(blendShapes)

        XCTAssertEqual(custom.count, 52)
        XCTAssertEqual(custom["eyeBlinkLeft"], 0.5)
        XCTAssertEqual(custom["jawOpen"], 0.3)
    }

    func testMapper_EvaluatePresetOnly() {
        let capability = PerfectSyncCapability.none
        let mapper = PerfectSyncMapper(capability: capability)

        let blendShapes = createMockBlendShapes([
            "eyeBlinkLeft": 0.8,
            "eyeBlinkRight": 0.8
        ])

        let preset = mapper.evaluatePresetOnly(blendShapes)

        XCTAssertGreaterThan(preset.count, 0)
        XCTAssertNotNil(preset["blink"])
    }

    // MARK: - ARKitFaceDriver Integration Tests

    func testDriverPerfectSyncInitialization_None() {
        let model = createMockModel(customExpressionNames: [])
        let driver = ARKitFaceDriver.configured(for: model)

        XCTAssertEqual(driver.perfectSyncCapability, .none)
    }

    func testDriverPerfectSyncInitialization_Full() {
        let model = createMockModel(customExpressionNames: ARKitFaceBlendShapes.allKeys)
        let driver = ARKitFaceDriver.configured(for: model)

        XCTAssertEqual(driver.perfectSyncCapability, .full)
    }

    func testDriverPerfectSyncInitialization_Partial() {
        let arkitNames = Array(ARKitFaceBlendShapes.allKeys.prefix(40))
        let model = createMockModel(customExpressionNames: arkitNames)
        let driver = ARKitFaceDriver.configured(for: model)

        if case .partial(let matched, _) = driver.perfectSyncCapability {
            XCTAssertEqual(matched.count, 40)
        } else {
            XCTFail("Expected .partial capability")
        }
    }

    func testDriverManualInitialization() {
        let driver = ARKitFaceDriver(mapper: .default, smoothing: .none)
        XCTAssertEqual(driver.perfectSyncCapability, .none)

        let model = createMockModel(customExpressionNames: ARKitFaceBlendShapes.allKeys)
        driver.initializeForModel(model)

        XCTAssertEqual(driver.perfectSyncCapability, .full)
    }

    // MARK: - Capability Equality Tests

    func testCapabilityEquality_None() {
        XCTAssertEqual(PerfectSyncCapability.none, PerfectSyncCapability.none)
    }

    func testCapabilityEquality_Full() {
        XCTAssertEqual(PerfectSyncCapability.full, PerfectSyncCapability.full)
    }

    func testCapabilityEquality_Partial() {
        let matched1: Set<String> = ["a", "b"]
        let missing1: Set<String> = ["c"]
        let matched2: Set<String> = ["a", "b"]
        let missing2: Set<String> = ["c"]

        XCTAssertEqual(
            PerfectSyncCapability.partial(matched: matched1, missing: missing1),
            PerfectSyncCapability.partial(matched: matched2, missing: missing2)
        )
    }

    func testCapabilityInequality() {
        XCTAssertNotEqual(PerfectSyncCapability.none, PerfectSyncCapability.full)

        let matched: Set<String> = ["a"]
        let missing: Set<String> = ["b"]
        XCTAssertNotEqual(
            PerfectSyncCapability.none,
            PerfectSyncCapability.partial(matched: matched, missing: missing)
        )
    }

    // MARK: - Real VRM Model Integration Tests

    /// Test Perfect Sync detection with a real VRM model from hinzka/52blendshapes-for-VRoid-face
    func testRealPerfectSyncModel() async throws {
        // Skip if Metal device unavailable (CI environment)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }

        // Get the path to the test resource - try multiple locations
        // This test gracefully skips if the model is not present (e.g., in CI)
        var resourcePath: URL?

        // Try /tmp first (local development)
        let tmpPath = URL(fileURLWithPath: "/tmp/VRoid_PerfectSync_Female.vrm")
        if FileManager.default.fileExists(atPath: tmpPath.path) {
            resourcePath = tmpPath
        }

        // Try bundle (if added as test resource)
        if resourcePath == nil {
            let testBundle = Bundle(for: type(of: self))
            if let bundleURL = testBundle.url(forResource: "VRoid_PerfectSync_Female", withExtension: "vrm") {
                resourcePath = bundleURL
            }
        }

        guard let vrmURL = resourcePath else {
            throw XCTSkip("Perfect Sync VRM model not found. For local testing, download to /tmp: curl -L -o /tmp/VRoid_PerfectSync_Female.vrm 'https://github.com/hinzka/52blendshapes-for-VRoid-face/raw/main/VRoid_V110_Female_v1.1.3.vrm'")
        }

        // Load the model
        let model = try await VRMModel.load(from: vrmURL, device: device)

        // Verify Perfect Sync detection
        let result = PerfectSyncCapability.detect(from: model)

        // This model should have full or partial Perfect Sync support
        switch result.capability {
        case .full:
            XCTAssertEqual(result.capability.directMappingCount, 52)
            print("✅ Real VRM model detected as FULL Perfect Sync (52 direct mappings)")
            print("📋 Name mapping sample: eyeBlinkLeft -> \(result.nameMapping["eyeBlinkLeft"] ?? "N/A")")
        case .partial(let matched, let missing):
            XCTAssertGreaterThanOrEqual(matched.count, 30)
            print("✅ Real VRM model detected as PARTIAL Perfect Sync (\(matched.count) direct, \(missing.count) composite)")
        case .none:
            XCTFail("Expected Perfect Sync model but detected .none capability")
        }

        // Test driver initialization
        let driver = ARKitFaceDriver.configured(for: model)
        XCTAssertNotEqual(driver.perfectSyncCapability, .none, "Driver should detect Perfect Sync capability")

        // List custom expressions found (via name mapping)
        print("📊 Found \(result.nameMapping.count) ARKit-matching custom expressions")
        if result.nameMapping.count < 52 {
            let matchedNames = Set(result.nameMapping.keys)
            let missingShapes = Set(ARKitFaceBlendShapes.allKeys).subtracting(matchedNames)
            print("   Missing: \(missingShapes.sorted().prefix(10).joined(separator: ", "))...")
        }
    }

    // MARK: - Performance Tests

    func testCapabilityDetectionPerformance() {
        let model = createMockModel(customExpressionNames: ARKitFaceBlendShapes.allKeys)

        measure {
            for _ in 0..<1000 {
                let result = PerfectSyncCapability.detect(from: model)
                _ = result.capability
            }
        }
    }

    func testMapperEvaluationPerformance_Full() {
        let mapper = PerfectSyncMapper(capability: .full)
        let blendShapes = createMockBlendShapes(allShapesWithValue: 0.5)

        measure {
            for _ in 0..<1000 {
                _ = mapper.evaluate(blendShapes)
            }
        }
    }

    // MARK: - Helper Methods

    private func createMockModel(customExpressionNames: [String]) -> VRMModel {
        // Create a minimal GLTFDocument from JSON
        let minimalGLTF = """
        {
            "asset": {
                "version": "2.0",
                "generator": "TestMock"
            }
        }
        """
        let gltf = try! JSONDecoder().decode(GLTFDocument.self, from: minimalGLTF.data(using: .utf8)!)

        // Create VRMMeta with required licenseUrl
        let meta = VRMMeta(licenseUrl: "https://example.com/license")

        // Create VRMModel with correct spec version enum
        let model = VRMModel(specVersion: .v1_0, meta: meta, humanoid: nil, gltf: gltf)

        // Add custom expressions
        let expressions = VRMExpressions()
        for name in customExpressionNames {
            expressions.custom[name] = VRMExpression(name: name)
        }
        model.expressions = expressions

        return model
    }

    private func createMockBlendShapes(_ shapes: [String: Float]) -> ARKitFaceBlendShapes {
        return ARKitFaceBlendShapes(
            timestamp: Date().timeIntervalSinceReferenceDate,
            shapes: shapes
        )
    }

    private func createMockBlendShapes(allShapesWithValue value: Float) -> ARKitFaceBlendShapes {
        var shapes: [String: Float] = [:]
        for key in ARKitFaceBlendShapes.allKeys {
            shapes[key] = value
        }
        return ARKitFaceBlendShapes(
            timestamp: Date().timeIntervalSinceReferenceDate,
            shapes: shapes
        )
    }
}
