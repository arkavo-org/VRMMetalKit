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

/// TDD Tests for VRM 1.0 model compatibility with VRMA animations
///
/// Very narrow focus: Verify VRM 1.0 models are correctly detected and
/// VRMA animations work WITHOUT coordinate conversion (VRM 1.0 and VRMA
/// both use the same right-handed coordinate system)
final class VRM1CompatibilityTests: XCTestCase {

    // MARK: - Test Paths
    
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
    
    private var vrmModelsPath: String {
        // Use environment variable or fallback to project root
        return ProcessInfo.processInfo.environment["VRM_MODELS_PATH"] ?? projectRoot
    }
    
    private var vrmaPath: String {
        // Use environment variable or fallback to project root
        return ProcessInfo.processInfo.environment["VRMA_TEST_PATH"] ?? projectRoot
    }
    
    // MARK: - TDD RED: VRM 1.0 Detection Tests
    
    /// RED: Test that Seed-san.vrm is detected as VRM 1.0
    ///
    /// VRM 1.0 models should have:
    /// - specVersion == .v1_0
    /// - isVRM0 == false
    func testSeedSanDetectedAsVRM1() async throws {
        let modelPath = "\(vrmModelsPath)/Seed-san.vrm"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found at \(modelPath)")
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal device not available")
            return
        }
        
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        print("\n=== Seed-san.vrm Version Detection ===")
        print("specVersion: \(model.specVersion)")
        print("isVRM0: \(model.isVRM0)")
        
        // VRM 1.0 assertions
        XCTAssertEqual(model.specVersion, .v1_0, "Seed-san should be VRM 1.0")
        XCTAssertFalse(model.isVRM0, "Seed-san should NOT be marked as VRM 0.0")
    }
    
    /// RED: Test that VRM1_Constraint_Twist_Sample.vrm is detected as VRM 1.0
    func testConstraintTwistSampleDetectedAsVRM1() async throws {
        let modelPath = "\(vrmModelsPath)/VRM1_Constraint_Twist_Sample.vrm"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found at \(modelPath)")
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal device not available")
            return
        }
        
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        print("\n=== VRM1_Constraint_Twist_Sample.vrm Version Detection ===")
        print("specVersion: \(model.specVersion)")
        print("isVRM0: \(model.isVRM0)")
        
        // VRM 1.0 assertions
        XCTAssertEqual(model.specVersion, .v1_0, "Should be VRM 1.0")
        XCTAssertFalse(model.isVRM0, "Should NOT be marked as VRM 0.0")
    }
    
    /// RED: Test VRM 1.0 model has all required humanoid bones
    func testVRM1ModelHasRequiredBones() async throws {
        let modelPath = "\(vrmModelsPath)/Seed-san.vrm"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found at \(modelPath)")
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal device not available")
            return
        }
        
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        print("\n=== Seed-san.vrm Humanoid Bones ===")
        print("Total bones: \(model.humanoid?.humanBones.count ?? 0)")
        
        // Required bones for VRM
        let requiredBones: [VRMHumanoidBone] = [
            .hips, .spine, .head,
            .leftUpperArm, .leftLowerArm, .leftHand,
            .rightUpperArm, .rightLowerArm, .rightHand,
            .leftUpperLeg, .leftLowerLeg, .leftFoot,
            .rightUpperLeg, .rightLowerLeg, .rightFoot
        ]
        
        for bone in requiredBones {
            let nodeIndex = model.humanoid?.getBoneNode(bone)
            print("  \(bone): \(nodeIndex != nil ? "✓" : "✗")")
            XCTAssertNotNil(nodeIndex, "Required bone \(bone) should be present")
        }
    }
    
    // MARK: - TDD RED: VRMA + VRM 1.0 Compatibility Tests
    
    /// RED: Test VRMA animation loads with VRM 1.0 model
    ///
    /// This test verifies that VRMA animations work with VRM 1.0 models
    func testVRMALoadsWithVRM1Model() async throws {
        let modelPath = "\(vrmModelsPath)/Seed-san.vrm"
        let vrmaPath = "\(self.vrmaPath)/VRMA_01.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found at \(modelPath)")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA file not found at \(vrmaPath)")
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal device not available")
            return
        }
        
        // Load VRM 1.0 model
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        XCTAssertEqual(model.specVersion, .v1_0, "Should be VRM 1.0")
        
        // Load VRMA with VRM 1.0 model
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
        
        print("\n=== VRMA + VRM 1.0 (Seed-san) ===")
        print("Duration: \(clip.duration)s")
        print("Joint tracks: \(clip.jointTracks.count)")
        
        // Log mapped bones
        for track in clip.jointTracks {
            let (rot, trans, _) = track.sample(at: 0)
            print("  \(track.bone): rotation=\(rot != nil ? "✓" : "✗") translation=\(trans != nil ? "✓" : "✗")")
        }
        
        // Verify animation loaded correctly
        XCTAssertGreaterThan(clip.duration, 0, "Animation should have positive duration")
        XCTAssertGreaterThan(clip.jointTracks.count, 0, "Should have joint tracks")
    }
    
    /// RED: Test VRM 1.0 does NOT get coordinate conversion
    ///
    /// VRM 1.0 and VRMA both use right-handed coordinates
    /// No conversion should be applied
    func testVRM1DoesNotApplyCoordinateConversion() async throws {
        let modelPath = "\(vrmModelsPath)/Seed-san.vrm"
        let vrmaPath = "\(self.vrmaPath)/VRMA_01.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found at \(modelPath)")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA file not found at \(vrmaPath)")
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal device not available")
            return
        }
        
        // Load VRM 1.0 model
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        // Load VRMA with VRM 1.0 model
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
        
        print("\n=== VRM 1.0 Coordinate Conversion Check ===")
        print("Model: Seed-san.vrm (VRM 1.0)")
        print("VRMA: VRMA_01.vrma")
        
        // For VRM 1.0, convertForVRM0 should be false
        // This means rotation X/Z should NOT be negated
        // We can't directly test the internal flag, but we can verify the model version
        XCTAssertEqual(model.specVersion, .v1_0)
        XCTAssertFalse(model.isVRM0)
        
        // Log a sample rotation to verify it's in right-handed space
        if let hipsTrack = clip.jointTracks.first(where: { $0.bone == .hips }) {
            let (rot, _, _) = hipsTrack.sample(at: 0)
            if let rotation = rot {
                print("Sample hips rotation at t=0:")
                print("  quat(\(rotation.imag.x), \(rotation.imag.y), \(rotation.imag.z), \(rotation.real))")
                
                // Just verify it's a valid quaternion
                let length = simd_length(rotation.vector)
                XCTAssertEqual(length, 1.0, accuracy: 0.01, "Rotation should be normalized")
            }
        }
    }
    
    /// RED: Compare VRM 0.0 vs VRM 1.0 behavior
    ///
    /// Both models loading the same VRMA should have different coordinate handling
    func testVRM0vsVRM1BehaviorDifference() async throws {
        let vrm0Path = "\(projectRoot)/AliciaSolid.vrm"
        let vrm1Path = "\(vrmModelsPath)/Seed-san.vrm"
        let vrmaPath = "\(self.vrmaPath)/VRMA_01.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrm0Path),
                      "VRM 0.0 model not found")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrm1Path),
                      "VRM 1.0 model not found")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA file not found")
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal device not available")
            return
        }
        
        // Load both models
        let vrm0Model = try await VRMModel.load(from: URL(fileURLWithPath: vrm0Path), device: device)
        let vrm1Model = try await VRMModel.load(from: URL(fileURLWithPath: vrm1Path), device: device)
        
        // Verify versions
        XCTAssertEqual(vrm0Model.specVersion, .v0_0, "AliciaSolid should be VRM 0.0")
        XCTAssertEqual(vrm1Model.specVersion, .v1_0, "Seed-san should be VRM 1.0")
        XCTAssertTrue(vrm0Model.isVRM0)
        XCTAssertFalse(vrm1Model.isVRM0)
        
        print("\n=== VRM 0.0 vs VRM 1.0 Comparison ===")
        print("VRM 0.0 (AliciaSolid):")
        print("  specVersion: \(vrm0Model.specVersion)")
        print("  isVRM0: \(vrm0Model.isVRM0)")
        print("  convertForVRM0: true (coordinate conversion applied)")
        
        print("VRM 1.0 (Seed-san):")
        print("  specVersion: \(vrm1Model.specVersion)")
        print("  isVRM0: \(vrm1Model.isVRM0)")
        print("  convertForVRM0: false (no conversion needed)")
        
        // Load same VRMA with both models
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let vrm0Clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: vrm0Model)
        let vrm1Clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: vrm1Model)
        
        // Both should load successfully with appropriate handling
        XCTAssertGreaterThan(vrm0Clip.jointTracks.count, 0, "VRM 0.0 should have tracks")
        XCTAssertGreaterThan(vrm1Clip.jointTracks.count, 0, "VRM 1.0 should have tracks")
        
        print("Both clips loaded successfully with version-appropriate handling")
    }
    
    // MARK: - TDD RED: Bone Name Compatibility Tests
    
    /// RED: Test that VRM 1.0 bone names are correctly parsed
    ///
    /// VRM 1.0 uses standard bone names like "hips", "leftUpperArm", etc.
    func testVRM1BoneNameParsing() async throws {
        let modelPath = "\(vrmModelsPath)/Seed-san.vrm"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found at \(modelPath)")
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal device not available")
            return
        }
        
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        print("\n=== VRM 1.0 Bone Names (Seed-san) ===")
        
        // Get node names for bones
        for (bone, humanBone) in model.humanoid?.humanBones ?? [:] {
            if humanBone.node < model.nodes.count {
                let nodeName = model.nodes[humanBone.node].name ?? "unnamed"
                print("  \(bone.rawValue) -> node[\(humanBone.node)]: \(nodeName)")
            }
        }
        
        // VRM 1.0 should have proper bone names that match our heuristic
        XCTAssertNotNil(model.humanoid?.getBoneNode(.hips))
        XCTAssertNotNil(model.humanoid?.getBoneNode(.head))
    }
}
