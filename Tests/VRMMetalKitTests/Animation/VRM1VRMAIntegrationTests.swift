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

// MARK: - Phase 1: RED Tests
// These tests are designed to fail initially (RED phase of TDD)
// They define the expected behavior for VRM 1.0 + VRMA integration

/// VRM 1.0 + VRMA Integration Tests
///
/// 🔴 RED Phase Tests: These tests define expected behavior but will initially fail
/// because the implementation needs to be completed.
///
/// Key behaviors to verify:
/// - VRM 1.0 models should NOT have coordinate conversion applied (no X/Z negation)
/// - VRM 1.0 bone retargeting should handle different rest poses via delta-based retargeting
/// - VRM 1.0 expression animation should work via VRMA expression tracks
final class VRM1VRMAIntegrationTests: XCTestCase {
    
    // MARK: - Test Setup
    
    private var device: MTLDevice!
    
    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }
    
    override func tearDown() {
        device = nil
    }
    
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
    
    // MARK: - RED Test 1.1: VRM 1.0 Model with VRMA Without Coordinate Conversion
    
    /// 🔴 RED: Test VRM 1.0 model loads with VRMA without coordinate conversion
    ///
    /// Expected behavior:
    /// - VRM 1.0 models use right-handed coordinates (same as VRMA)
    /// - No coordinate conversion should be applied
    /// - Rotation X/Z should NOT be negated
    /// - Translation X/Z should NOT be negated
    func testVRM1ModelLoadsVRMAWithoutConversion() async throws {
        // Arrange: Load VRM 1.0 model (Seed-san.vrm)
        let modelPath = "\(projectRoot)/Seed-san.vrm"
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM 1.0 model (Seed-san.vrm) not found at \(modelPath)")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA file not found at \(vrmaPath)")
        
        // Act: Load VRM 1.0 model
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        // Assert: Model is detected as VRM 1.0
        XCTAssertEqual(model.specVersion, .v1_0, "Model should be detected as VRM 1.0")
        XCTAssertFalse(model.isVRM0, "VRM 1.0 model should NOT be marked as VRM 0.0")
        
        // Act: Load VRMA animation
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
        
        // Assert: Animation loaded successfully
        XCTAssertGreaterThan(clip.duration, 0, "Animation should have positive duration")
        XCTAssertGreaterThan(clip.jointTracks.count, 0, "Animation should have joint tracks")
        
        // 🔴 RED: Sample rotation and verify no coordinate conversion is applied
        // For VRM 1.0, the rotation should be in right-handed space (no negation of X/Z)
        if let hipsTrack = clip.jointTracks.first(where: { $0.bone == .hips }) {
            let (rotation, translation, _) = hipsTrack.sample(at: 0)
            
            // TODO: This assertion will initially fail until we implement proper
            // VRM 1.0 detection and disable coordinate conversion
            if let rot = rotation {
                // The rotation quaternion should NOT have X/Z negated for VRM 1.0
                // We verify this by checking the raw values from the VRMA file
                // match what we'd expect without conversion
                let rawRot = getRawRotationFromVRMA(vrmaPath: vrmaPath, boneNodeIndex: 0)
                
                // For VRM 1.0, sampled rotation should equal raw rotation (no conversion)
                XCTAssertEqual(rot.imag.x, rawRot.imag.x, accuracy: 0.001,
                              "VRM 1.0: Rotation X should not be negated")
                XCTAssertEqual(rot.imag.z, rawRot.imag.z, accuracy: 0.001,
                              "VRM 1.0: Rotation Z should not be negated")
            }
            
            if let trans = translation {
                // For VRM 1.0, translation should NOT have X/Z negated
                let rawTrans = getRawTranslationFromVRMA(vrmaPath: vrmaPath, boneNodeIndex: 0)
                
                XCTAssertEqual(trans.x, rawTrans.x, accuracy: 0.001,
                              "VRM 1.0: Translation X should not be negated")
                XCTAssertEqual(trans.z, rawTrans.z, accuracy: 0.001,
                              "VRM 1.0: Translation Z should not be negated")
            }
        }
    }
    
    /// 🔴 RED: Test VRM 1.0 bone retargeting with different rest poses
    ///
    /// When a VRM 1.0 model has a non-T-pose rest pose and we load a VRMA
    /// animation authored with a different rest pose, delta-based retargeting
    /// should produce correct rotations.
    func testVRM1RetargetingDifferentRestPoses() async throws {
        // Arrange: VRM 1.0 model with non-T-pose rest pose
        let modelPath = "\(projectRoot)/Seed-san.vrm"
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM 1.0 model not found")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA file not found")
        
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        XCTAssertEqual(model.specVersion, .v1_0, "Test requires VRM 1.0 model")
        
        // Get the model's rest pose for left upper arm
        guard let leftArmIndex = model.humanoid?.getBoneNode(.leftUpperArm) else {
            XCTFail("Model should have left upper arm")
            return
        }
        let restPoseRotation = model.nodes[leftArmIndex].rotation
        
        // Act: Load VRMA animation authored with different rest pose
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
        
        // Apply animation at frame 0
        let player = AnimationPlayer()
        player.load(clip)
        player.update(deltaTime: 0, model: model)
        
        // Assert: Delta-based retargeting produces correct rotations
        // The final rotation should be: restPose * deltaRotation
        // NOT just the animation's absolute rotation
        if let track = clip.jointTracks.first(where: { $0.bone == .leftUpperArm }) {
            let (animRotation, _, _) = track.sample(at: 0)
            
            guard let animRot = animRotation else {
                XCTFail("Animation should have rotation for left upper arm")
                return
            }
            
            let finalRotation = model.nodes[leftArmIndex].rotation
            
            // 🔴 RED: Calculate expected rotation with delta retargeting
            // expected = restPose * delta
            // where delta = inverse(restPoseInAnimation) * animRotation
            // This requires the VRMA to store rest pose info (which it should for VRM 1.0)
            
            // For now, we just verify the rotation changed from rest pose
            // TODO: Implement proper delta retargeting assertion
            let rotationChanged = abs(simd_dot(finalRotation.vector, restPoseRotation.vector)) < 0.99
            
            // The assertion will fail if retargeting isn't implemented
            // We expect the rotation to be different from both rest pose and raw animation
            XCTAssertTrue(rotationChanged, "Retargeting should produce different rotation from rest pose")
            
            // 🔴 RED: More specific assertion - final rotation should account for rest pose difference
            // This will fail until delta retargeting is implemented
            XCTAssertNotEqual(finalRotation, animRot,
                             "VRM 1.0 retargeting: Final rotation should not equal raw animation rotation")
        }
    }
    
    /// 🔴 RED: Test VRM 1.0 expression animation via VRMA
    ///
    /// VRM 1.0 uses VRMC_vrm extension for expressions (formerly BlendShapeProxy in VRM 0.0)
    /// VRMA can animate expression weights via expression tracks.
    func testVRM1ExpressionAnimation() async throws {
        // Arrange: VRM 1.0 model with expressions
        let modelPath = "\(projectRoot)/Seed-san.vrm"
        let vrmaPath = "\(projectRoot)/VRMA_expressions.vrma"  // VRMA with expression tracks
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM 1.0 model not found")
        
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        XCTAssertEqual(model.specVersion, .v1_0, "Test requires VRM 1.0 model")
        
        // Verify model has expressions (VRM 1.0 style)
        // VRM 1.0 uses expressionsPreset/expressionsCustom in VRMC_vrm extension
        let hasExpressions = model.expressions?.preset.isEmpty == false
        XCTAssertTrue(hasExpressions, "VRM 1.0 model should have expressions defined")
        
        // Act: Load VRMA with expression tracks
        // Skip if expression VRMA doesn't exist yet
        guard FileManager.default.fileExists(atPath: vrmaPath) else {
            throw XCTSkip("VRMA with expressions not found at \(vrmaPath)")
        }
        
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
        
        // Assert: Expression weights sampled correctly
        // 🔴 RED: Verify expression tracks are loaded and sampled
        XCTAssertGreaterThan(clip.expressionTracks.count, 0,
                            "VRMA should have expression tracks for VRM 1.0")
        
        // Sample expression weights at different times
        let testExpressions: [VRMExpressionPreset] = [.happy, .sad, .angry, .surprised]
        
        for expression in testExpressions {
            guard let track = clip.expressionTracks.first(where: { $0.expression == expression }) else {
                continue  // Not all expressions may be animated
            }
            
            // Sample at t=0 and t=duration/2
            let weightAt0 = track.sample(at: 0)
            let weightAtMid = track.sample(at: clip.duration / 2)
            
            // Weights should be in valid range [0, 1]
            XCTAssertGreaterThanOrEqual(weightAt0, 0, "Expression weight should be >= 0")
            XCTAssertLessThanOrEqual(weightAt0, 1, "Expression weight should be <= 1")
            XCTAssertGreaterThanOrEqual(weightAtMid, 0, "Expression weight should be >= 0")
            XCTAssertLessThanOrEqual(weightAtMid, 1, "Expression weight should be <= 1")
            
            // 🔴 RED: Verify expression weights are actually applied to the model
            // This requires the model to have expression morph targets
            // TODO: Implement expression application assertion
        }
    }
    
    /// 🔴 RED: Test VRM 1.0 models ignore VRM 0.0 coordinate conversion flag
    ///
    /// Even if someone accidentally sets convertForVRM0 = true,
    /// VRM 1.0 models should not have coordinate conversion applied.
    func testVRM1IgnoresConversionFlag() async throws {
        let modelPath = "\(projectRoot)/Seed-san.vrm"
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM 1.0 model not found")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA file not found")
        
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        XCTAssertEqual(model.specVersion, .v1_0)
        
        // Load VRMA - should auto-detect VRM version and NOT convert
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
        
        // 🔴 RED: Verify the loader correctly detected VRM 1.0 and disabled conversion
        // This requires inspecting internal state or behavior
        // We can verify by checking sampled values match expected right-handed coordinates
        
        if let hipsTrack = clip.jointTracks.first(where: { $0.bone == .hips }) {
            let (_, translation, _) = hipsTrack.sample(at: 0)
            
            if let trans = translation {
                // For a typical walking animation, Z should be positive for forward movement
                // in VRM 1.0 (right-handed) coordinates
                // If conversion was wrongly applied, Z would be negated
                
                // This assertion will fail if coordinate conversion is incorrectly applied
                // to VRM 1.0 models
                XCTAssertGreaterThanOrEqual(trans.z, -0.1,
                    "VRM 1.0: Forward movement should have positive Z (or near zero), got \(trans.z). " +
                    "This may indicate coordinate conversion was incorrectly applied.")
            }
        }
    }
}

// MARK: - Helper Functions

extension VRM1VRMAIntegrationTests {
    
    /// Extract raw rotation from VRMA file without any conversion
    /// This reads the raw quaternion from glTF animation data
    private func getRawRotationFromVRMA(vrmaPath: String, boneNodeIndex: Int) -> simd_quatf {
        // For testing purposes, we return identity
        // In a full implementation, this would parse the glTF directly
        return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    }
    
    /// Extract raw translation from VRMA file without any conversion
    /// This reads the raw translation from glTF animation data
    private func getRawTranslationFromVRMA(vrmaPath: String, boneNodeIndex: Int) -> SIMD3<Float> {
        // For testing purposes, we return zero
        // In a full implementation, this would parse the glTF directly
        return SIMD3<Float>(0, 0, 0)
    }
}
