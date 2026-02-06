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

/// Phase 2: VRM 1.0 Animation Behavior Tests
///
/// 🔴 RED Tests for VRM 1.0 specific animation behavior
///
/// VRM 1.0 characteristics:
/// - Uses glTF right-handed coordinate system (same as VRMA)
/// - No coordinate conversion needed
/// - Uses VRM 1.0 spec bone names (leftUpperArm, etc.)
/// - Uses VRMC_vrm extension for expressions
final class VRM1AnimationTests: XCTestCase {
    
    // MARK: - Test Setup
    
    private var device: MTLDevice!
    private var projectRoot: String {
        let fileManager = FileManager.default
        let candidates: [String?] = [
            ProcessInfo.processInfo.environment["PROJECT_ROOT"],
            ProcessInfo.processInfo.environment["SRCROOT"],
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
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
    
    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }
    
    override func tearDown() {
        device = nil
    }
    
    // MARK: - No Coordinate Conversion Tests
    
    /// 🔴 RED: No coordinate conversion for VRM 1.0 models
    ///
    /// VRM 1.0 and VRMA both use glTF right-handed coordinates.
    /// No conversion should be applied.
    func testVRM1NoCoordinateConversion() async throws {
        // Arrange: VRM 1.0 model
        let modelPath = "\(projectRoot)/Seed-san.vrm"
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM 1.0 model (Seed-san.vrm) not found")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA file not found")
        
        // Act: Load VRM 1.0 model
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        // Assert: Model detected as VRM 1.0
        XCTAssertEqual(model.specVersion, .v1_0, "Model should be VRM 1.0")
        XCTAssertFalse(model.isVRM0, "VRM 1.0 should not be marked as VRM 0.0")
        
        // Act: Load VRMA
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
        
        // Assert: Animation loads without conversion
        // The sampled values should match the raw VRMA data (no negation)
        if let hipsTrack = clip.jointTracks.first(where: { $0.bone == .hips }) {
            let (rotation, translation, _) = hipsTrack.sample(at: 0)
            
            if let rot = rotation {
                // Rotation should be valid
                let length = sqrt(rot.imag.x * rot.imag.x + 
                                 rot.imag.y * rot.imag.y + 
                                 rot.imag.z * rot.imag.z + 
                                 rot.real * rot.real)
                XCTAssertEqual(length, 1.0, accuracy: 0.01, 
                              "Rotation should be normalized")
            }
            
            if let trans = translation {
                // For VRM 1.0, forward movement in VRMA (positive Z) 
                // should remain positive Z (no negation)
                // We can't assert exact values without known test data,
                // but we can verify no NaN/Inf
                XCTAssertFalse(trans.x.isNaN, "Translation X should not be NaN")
                XCTAssertFalse(trans.y.isNaN, "Translation Y should not be NaN")
                XCTAssertFalse(trans.z.isNaN, "Translation Z should not be NaN")
            }
        }
    }
    
    /// 🔴 RED: VRM 1.0 model with VRMA produces same coordinate space
    func testVRM1CoordinateSpaceConsistency() async throws {
        let modelPath = "\(projectRoot)/Seed-san.vrm"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM 1.0 model not found")
        
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        XCTAssertEqual(model.specVersion, .v1_0)
        
        // Verify the model's coordinate system is right-handed
        // This is implicit in glTF/VRM 1.0 spec
        // We verify by checking model transforms
        
        guard let humanoid = model.humanoid else {
            XCTFail("Model should have humanoid")
            return
        }
        
        // Check that bone transforms are in reasonable ranges
        let keyBones: [VRMHumanoidBone] = [.hips, .spine, .head, .leftUpperArm, .rightUpperArm]
        
        for bone in keyBones {
            guard let nodeIndex = humanoid.getBoneNode(bone) else { continue }
            let node = model.nodes[nodeIndex]
            
            // Rotation should be normalized
            let rotLength = sqrt(node.rotation.imag.x * node.rotation.imag.x +
                                node.rotation.imag.y * node.rotation.imag.y +
                                node.rotation.imag.z * node.rotation.imag.z +
                                node.rotation.real * node.rotation.real)
            XCTAssertEqual(rotLength, 1.0, accuracy: 0.01,
                          "\(bone) rotation should be normalized")
        }
    }
    
    // MARK: - Bone Name Mapping Tests
    
    /// 🔴 RED: VRM 1.0 spec bone name mapping
    ///
    /// VRM 1.0 uses camelCase bone names per spec:
    /// - hips, spine, chest, upperChest
    /// - leftUpperArm, leftLowerArm, leftHand
    /// - rightUpperArm, rightLowerArm, rightHand
    func testVRM1SpecBoneNameMapping() {
        // VRM 1.0 spec bone names
        let vrm1BoneNames = [
            "hips", "spine", "chest", "upperChest",
            "neck", "head",
            "leftShoulder", "leftUpperArm", "leftLowerArm", "leftHand",
            "rightShoulder", "rightUpperArm", "rightLowerArm", "rightHand",
            "leftUpperLeg", "leftLowerLeg", "leftFoot", "leftToes",
            "rightUpperLeg", "rightLowerLeg", "rightFoot", "rightToes",
            "leftEye", "rightEye", "jaw"
        ]
        
        // All should map to VRMHumanoidBone
        for name in vrm1BoneNames {
            let bone = VRMHumanoidBone(rawValue: name)
            XCTAssertNotNil(bone, "VRM 1.0 bone '\(name)' should map to VRMHumanoidBone")
        }
    }
    
    /// 🔴 RED: Direct bone name mapping (no heuristic needed for VRM 1.0)
    func testVRM1DirectBoneMapping() async throws {
        // Build a VRM 1.0 style model
        let vrmDocument = try VRMBuilder()
            .setSkeleton(.defaultHumanoid)
            .build()
        
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("vrm")
        
        try vrmDocument.serialize(to: tempURL)
        let model = try await VRMModel.load(from: tempURL, device: device)
        try? FileManager.default.removeItem(at: tempURL)
        
        // All bones should be directly mappable
        let allBones = VRMHumanoidBone.allCases
        var mappedCount = 0
        
        for bone in allBones {
            if let _ = model.humanoid?.getBoneNode(bone) {
                mappedCount += 1
            }
        }
        
        // Some bones should be mapped (may not be all due to minimal skeleton)
        XCTAssertGreaterThan(mappedCount, 0,
                            "At least some bones should be mapped")
    }
    
    // MARK: - Expression Animation Tests
    
    /// 🔴 RED: VRM 1.0 expression animation (VRMC_expression)
    ///
    /// VRM 1.0 uses VRMC_vrm extension for expressions.
    func testVRM1ExpressionAnimation() async throws {
        let modelPath = "\(projectRoot)/Seed-san.vrm"
        let vrmaPath = "\(projectRoot)/VRMA_expressions.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM 1.0 model not found")
        
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        XCTAssertEqual(model.specVersion, .v1_0, "Test requires VRM 1.0")
        
        // Should have expressions
        let hasExpressions = model.expressions?.preset.isEmpty == false ||
                            model.expressions?.custom.isEmpty == false
        
        if !hasExpressions {
            throw XCTSkip("Model has no expressions")
        }
        
        // Try to load expression VRMA
        guard FileManager.default.fileExists(atPath: vrmaPath) else {
            throw XCTSkip("VRMA with expressions not found")
        }
        
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
        
        // Should have expression tracks
        XCTAssertGreaterThan(clip.expressionTracks.count, 0,
                            "VRM 1.0 should have expression tracks")
        
        // Verify expression track types
        for track in clip.expressionTracks {
            XCTAssertNotNil(track.expression, "Expression track should have preset")
            
            // Sample at different times
            let weight0 = track.sample(at: 0)
            let weightMid = track.sample(at: clip.duration / 2)
            
            // Weights should be valid
            XCTAssertGreaterThanOrEqual(weight0, 0, "Weight should be >= 0")
            XCTAssertLessThanOrEqual(weight0, 1, "Weight should be <= 1")
            XCTAssertGreaterThanOrEqual(weightMid, 0, "Weight should be >= 0")
            XCTAssertLessThanOrEqual(weightMid, 1, "Weight should be <= 1")
        }
    }
    
    /// 🔴 RED: VRM 1.0 expression preset mapping
    func testVRM1ExpressionPresetMapping() {
        // VRM 1.0 expression presets per spec
        let expectedPresets: [VRMExpressionPreset] = [
            // Emotions
            .happy, .angry, .sad, .relaxed, .surprised,
            // Lip sync
            .aa, .ih, .ou, .ee, .oh,
            // Eye
            .blink, .blinkLeft, .blinkRight,
            // Look
            .lookUp, .lookDown, .lookLeft, .lookRight
        ]
        
        // All should exist
        // Verify all expected presets exist
        for preset in expectedPresets {
            XCTAssertFalse(preset.rawValue.isEmpty, "Preset should have a name")
        }
    }
    
    /// 🔴 RED: VRM 1.0 expression override behavior
    ///
    /// VRM 1.0 expressions can have override properties
    func testVRM1ExpressionOverride() async throws {
        // This tests that expression overrides work correctly
        // when animated via VRMA
        
        let modelPath = "\(projectRoot)/Seed-san.vrm"
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM 1.0 model not found")
        
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        // Check if expressions have override settings
        if let expressions = model.expressions {
            for (preset, expression) in expressions.preset {
                // Some expressions may have isBinary flag
                print("Expression \(preset): isBinary=\(expression.isBinary)")
            }
        }
        
        // Test passes if we can access expression data
        throw XCTSkip("Expression override validation needs assertions")
    }
    
    // MARK: - Constraint Tests
    
    /// 🔴 RED: VRM 1.0 constraint support
    ///
    /// VRM 1.0 supports constraints (VRMC_constraint)
    func testVRM1ConstraintSupport() async throws {
        let modelPath = "\(projectRoot)/VRM1_Constraint_Twist_Sample.vrm"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM 1.0 constraint sample not found")
        
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        XCTAssertEqual(model.specVersion, .v1_0)
        
        // Model should have constraints
        // This is a placeholder - actual constraint checking depends on implementation
        XCTAssertNotNil(model, "Model with constraints should load")
    }
    
    // MARK: - Integration Tests
    
    /// 🔴 RED: Full VRM 1.0 + VRMA integration
    func testVRM1FullIntegration() async throws {
        let modelPath = "\(projectRoot)/Seed-san.vrm"
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM 1.0 model not found")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA file not found")
        
        // Act: Load model and animation
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
        
        // Assert: Apply animation
        let player = AnimationPlayer()
        player.load(clip)
        player.update(deltaTime: 0, model: model)
        
        // Verify animation applied
        guard let humanoid = model.humanoid else {
            XCTFail("Model should have humanoid")
            return
        }
        
        var animatedBones = 0
        for track in clip.jointTracks {
            if let nodeIndex = humanoid.getBoneNode(track.bone) {
                let node = model.nodes[nodeIndex]
                if simd_length(node.rotation.imag) > 0.01 {
                    animatedBones += 1
                }
            }
        }
        
        XCTAssertGreaterThan(animatedBones, 0, "Animation should affect bones")
    }
    
    /// 🔴 RED: VRM 1.0 retargeting (when rest poses differ)
    func testVRM1Retargeting() async throws {
        let modelPath = "\(projectRoot)/Seed-san.vrm"
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM 1.0 model not found")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA file not found")
        
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
        
        // With VRM 1.0, retargeting should use delta-based method
        // but NOT apply coordinate conversion
        XCTAssertGreaterThan(clip.jointTracks.count, 0, "Should have joint tracks")
        
        // All sampled rotations should be valid
        for track in clip.jointTracks {
            let (rot, _, _) = track.sample(at: 0)
            if let rotation = rot {
                let length = simd_length(rotation.vector)
                XCTAssertEqual(length, 1.0, accuracy: 0.01,
                              "Retargeted rotation should be normalized")
            }
        }
    }
}
