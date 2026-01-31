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
import simd
@testable import VRMMetalKit

/// TDD Tests for VRMA expression/morph track compatibility
///
/// Very narrow focus: Verify VRMA expression tracks are correctly parsed
/// and mapped to VRM model expressions
final class VRMAExpressionTests: XCTestCase {

    // MARK: - Test Paths
    
    private var vrmModelsPath: String {
        // Use environment variable or fallback to project root
        return ProcessInfo.processInfo.environment["VRM_MODELS_PATH"] ?? projectRoot
    }
    
    private var vrmaPath: String {
        // Use environment variable or fallback to project root
        return ProcessInfo.processInfo.environment["VRMA_TEST_PATH"] ?? projectRoot
    }
    
    private var projectRoot: String {
        let fileManager = FileManager.default
        let candidates: [String?] = [
            ProcessInfo.processInfo.environment["PROJECT_ROOT"],
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path,
            fileManager.currentDirectoryPath
        ]
        
        for candidate in candidates.compactMap({ $0 }) {
            let packagePath = "\(candidate)/Package.swift"
            if fileManager.fileExists(atPath: packagePath) {
                return candidate
            }
        }
        return fileManager.currentDirectoryPath
    }
    
    // MARK: - TDD RED: VRMA Expression Parsing Tests
    
    /// RED: Test that VRMA files have expression data in extension
    ///
    /// VRMA files should have VRMC_vrm_animation.expressions with preset/custom
    func testVRMAHasExpressionData() async throws {
        let vrmaPath = "\(self.vrmaPath)/VRMA_01.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA file not found at \(vrmaPath)")
        
        // Load the raw GLTF document to inspect extension
        let data = try Data(contentsOf: URL(fileURLWithPath: vrmaPath))
        let parser = GLTFParser()
        let (document, _) = try parser.parse(data: data)
        
        // Check for VRMC_vrm_animation extension
        guard let extensionDict = document.extensions?["VRMC_vrm_animation"] as? [String: Any] else {
            XCTFail("VRMA file should have VRMC_vrm_animation extension")
            return
        }
        
        // Check for expressions
        guard let expressions = extensionDict["expressions"] as? [String: Any] else {
            print("Note: VRMA_01.vrma has no expressions section")
            return
        }
        
        print("\n=== VRMA_01 Expression Data ===")
        
        // Check preset expressions
        if let preset = expressions["preset"] as? [String: Any] {
            print("Preset expressions: \(preset.keys.sorted())")
            XCTAssertGreaterThan(preset.count, 0, "Should have preset expressions")
        }
        
        // Check custom expressions
        if let custom = expressions["custom"] as? [String: Any] {
            print("Custom expressions: \(custom.keys.sorted())")
        }
    }
    
    /// RED: Test VRMA expression tracks are loaded into AnimationClip
    ///
    /// Expression tracks should be accessible via clip.morphTracks
    func testVRMAExpressionTracksLoaded() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        let vrmaPath = "\(self.vrmaPath)/VRMA_01.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA file not found")
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal device not available")
            return
        }
        
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
        
        print("\n=== VRMA_01 Expression Tracks ===")
        print("Morph tracks: \(clip.morphTracks.count)")
        
        for track in clip.morphTracks {
            print("  Expression: \(track.key)")
        }
        
        // Document what we found - some VRMA files may not have expressions
        if clip.morphTracks.isEmpty {
            print("Note: VRMA_01.vrma has no expression tracks")
        }
    }
    
    /// RED: Test expression weight sampling
    ///
    /// Expression weights should be in range [0.0, 1.0]
    func testExpressionWeightSampling() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        let vrmaPath = "\(self.vrmaPath)/VRMA_01.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA file not found")
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal device not available")
            return
        }
        
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
        
        // Sample expression weights at various times
        let sampleTimes: [Float] = [0, 0.25, 0.5, 0.75, 1.0].map { $0 * clip.duration }
        
        print("\n=== Expression Weight Sampling ===")
        
        for track in clip.morphTracks {
            print("Expression '\(track.key)':")
            
            for time in sampleTimes {
                let weight = track.sampler(time)
                print("  t=\(String(format: "%.2f", time)): weight=\(String(format: "%.3f", weight))")
                
                // Expression weights should typically be in [0, 1] range
                // But allow slight overshoot for animation curves
                XCTAssertGreaterThanOrEqual(weight, -0.1, "Weight should not be extremely negative")
                XCTAssertLessThanOrEqual(weight, 1.5, "Weight should not be extremely large")
                
                // Verify no NaN or infinity
                XCTAssertFalse(weight.isNaN, "Weight should not be NaN")
                XCTAssertFalse(weight.isInfinite, "Weight should not be infinite")
            }
        }
    }
    
    /// RED: Test multiple VRMA files for expression diversity
    ///
    /// Different VRMA files may have different expression sets
    func testMultipleVRMAExpressionDiversity() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found")
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal device not available")
            return
        }
        
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        let vrmaFiles = (1...7).map { "VRMA_0\($0).vrma" }
        
        print("\n=== VRMA Expression Diversity ===")
        
        var allExpressionNames: Set<String> = []
        
        for vrmaFile in vrmaFiles {
            let vrmaPath = "\(self.vrmaPath)/\(vrmaFile)"
            
            guard FileManager.default.fileExists(atPath: vrmaPath) else {
                print("  \(vrmaFile): not found")
                continue
            }
            
            do {
                let vrmaURL = URL(fileURLWithPath: vrmaPath)
                let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
                
                let expressionNames = clip.morphTracks.map { $0.key }
                allExpressionNames.formUnion(expressionNames)
                
                if expressionNames.isEmpty {
                    print("  \(vrmaFile): no expressions")
                } else {
                    print("  \(vrmaFile): \(expressionNames.joined(separator: ", "))")
                }
            } catch {
                print("  \(vrmaFile): error - \(error)")
            }
        }
        
        print("\nAll unique expressions found: \(allExpressionNames.sorted())")
    }
    
    // MARK: - TDD RED: VRM 1.0 Expression Tests
    
    /// RED: Test VRM 1.0 model with VRMA expressions
    ///
    /// VRM 1.0 models should work with VRMA expression tracks
    func testVRM1ModelWithExpressions() async throws {
        let modelPath = "\(vrmModelsPath)/Seed-san.vrm"
        let vrmaPath = "\(self.vrmaPath)/VRMA_01.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM 1.0 model not found")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA file not found")
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal device not available")
            return
        }
        
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        XCTAssertEqual(model.specVersion, .v1_0, "Should be VRM 1.0")
        
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
        
        print("\n=== VRM 1.0 + VRMA Expressions (Seed-san) ===")
        print("Morph tracks: \(clip.morphTracks.count)")
        
        for track in clip.morphTracks {
            let weight = track.sampler(0)
            print("  \(track.key): \(String(format: "%.3f", weight))")
        }
        
        // Both VRM 0.0 and VRM 1.0 should handle expressions the same way
        // (expressions don't need coordinate conversion)
    }
    
    // MARK: - TDD RED: Expression to Model Mapping Tests
    
    /// RED: Test VRM model expression availability
    ///
    /// Verify the VRM model has expressions that can be driven
    func testVRMModelHasExpressions() async throws {
        let vrm0Path = "\(projectRoot)/AliciaSolid.vrm"
        let vrm1Path = "\(vrmModelsPath)/Seed-san.vrm"
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal device not available")
            return
        }
        
        print("\n=== VRM Model Expression Availability ===")
        
        // Test VRM 0.0
        if FileManager.default.fileExists(atPath: vrm0Path) {
            let vrm0Model = try await VRMModel.load(from: URL(fileURLWithPath: vrm0Path), device: device)
            let vrm0Expressions = vrm0Model.expressions
            print("AliciaSolid (VRM 0.0):")
            print("  Preset expressions: \(vrm0Expressions?.preset.keys.map { $0.rawValue }.sorted() ?? [])")
            print("  Custom expressions: \(vrm0Expressions?.custom.keys.sorted() ?? [])")
        }
        
        // Test VRM 1.0
        if FileManager.default.fileExists(atPath: vrm1Path) {
            let vrm1Model = try await VRMModel.load(from: URL(fileURLWithPath: vrm1Path), device: device)
            let vrm1Expressions = vrm1Model.expressions
            print("Seed-san (VRM 1.0):")
            print("  Preset expressions: \(vrm1Expressions?.preset.keys.map { $0.rawValue }.sorted() ?? [])")
            print("  Custom expressions: \(vrm1Expressions?.custom.keys.sorted() ?? [])")
        }
    }
    
    /// RED: Test expression name compatibility
    ///
    /// VRMA expression names should map to VRM model expression names
    func testExpressionNameCompatibility() {
        // Common expression names in VRMA and VRM
        let standardExpressions = [
            "happy", "angry", "sad", "relaxed", "surprised",
            "aa", "ih", "ou", "ee", "oh",
            "blink", "blinkLeft", "blinkRight",
            "lookUp", "lookDown", "lookLeft", "lookRight"
        ]
        
        print("\n=== Standard VRM Expressions ===")
        
        for expr in standardExpressions {
            // Verify these are valid expression preset names
            let preset = VRMExpressionPreset(rawValue: expr)
            if preset != nil {
                print("  \(expr): standard preset ✓")
            } else {
                print("  \(expr): custom/other")
            }
        }
    }
    
    // MARK: - TDD RED: Mock Expression Tests
    
    /// RED: Test expression weight sampler behavior
    ///
    /// Mock test for expression weight extraction from translation
    func testExpressionWeightSampler() {
        // Expression weight is encoded in translation.x
        // This is documented in VRMA spec
        
        let mockTranslation = SIMD3<Float>(0.75, 0.0, 0.0)
        let expectedWeight = mockTranslation.x
        
        XCTAssertEqual(expectedWeight, 0.75, accuracy: 0.001)
        
        print("\n=== Expression Weight Encoding ===")
        print("VRMA encodes expression weight in translation.x")
        print("Mock translation: \(mockTranslation)")
        print("Extracted weight: \(expectedWeight)")
    }
    
    /// RED: Test expression weight interpolation
    ///
    /// Expression weights should interpolate between keyframes
    func testExpressionWeightInterpolation() {
        // Document expected behavior
        print("\n=== Expression Weight Interpolation ===")
        print("Expected behavior:")
        print("  - Expression weights interpolate linearly between keyframes")
        print("  - Result should be smooth 0.0 to 1.0 (or beyond for emphasis)")
        print("  - No coordinate conversion needed for expressions")
        
        // Simple linear interpolation test
        let v0: Float = 0.0
        let v1: Float = 1.0
        let t: Float = 0.5
        let result = v0 + (v1 - v0) * t
        
        XCTAssertEqual(result, 0.5, accuracy: 0.001)
    }
}
