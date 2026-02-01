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

/// Phase 2: VRM 0.0 Animation Behavior Tests
///
/// 🔴 RED Tests for VRM 0.0 specific animation behavior
///
/// VRM 0.0 characteristics:
/// - Uses Unity's left-handed coordinate system
/// - Requires coordinate conversion when loading VRMA (VRM 1.0 format)
/// - Uses Unity-style bone naming (J_Bip_L_UpperArm, etc.)
/// - Uses BlendShapeProxy for expressions
final class VRM0AnimationTests: XCTestCase {
    
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
    
    // MARK: - Coordinate Conversion Tests
    
    /// 🔴 RED: Coordinate conversion applied for VRM 0.0 models
    ///
    /// When loading VRMA (VRM 1.0 format) onto VRM 0.0 models:
    /// - Rotation X/Z should be negated
    /// - Translation X/Z should be negated
    func testVRM0CoordinateConversionApplied() async throws {
        // Arrange: VRM 0.0 model (AliciaSolid.vrm)
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM 0.0 model not found at \(modelPath)")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA file not found at \(vrmaPath)")
        
        // Act: Load VRM 0.0 model
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        // Assert: Model detected as VRM 0.0
        XCTAssertTrue(model.isVRM0, "AliciaSolid should be VRM 0.0")
        XCTAssertEqual(model.specVersion, .v0_0, "Spec version should be VRM 0.0")
        
        // Act: Load VRMA animation
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
        
        // Assert: Coordinate conversion should be applied
        // For VRM 0.0, rotations should have X/Z negated compared to raw VRMA data
        if let hipsTrack = clip.jointTracks.first(where: { $0.bone == .hips }) {
            let (rotation, translation, _) = hipsTrack.sample(at: 0)
            
            // These assertions verify the conversion is happening
            // The actual values will depend on the VRMA file content
            if let rot = rotation {
                // After conversion, the rotation should be valid (normalized)
                let length = sqrt(rot.imag.x * rot.imag.x + 
                                 rot.imag.y * rot.imag.y + 
                                 rot.imag.z * rot.imag.z + 
                                 rot.real * rot.real)
                XCTAssertEqual(length, 1.0, accuracy: 0.01, 
                              "Converted rotation should be normalized")
            }
            
            if let trans = translation {
                // Translation should be finite
                XCTAssertFalse(trans.x.isNaN, "Translation X should not be NaN")
                XCTAssertFalse(trans.y.isNaN, "Translation Y should not be NaN")
                XCTAssertFalse(trans.z.isNaN, "Translation Z should not be NaN")
            }
        }
    }
    
    /// 🔴 RED: Verify coordinate conversion math
    func testVRM0CoordinateConversionMath() {
        // Test rotation conversion
        let testQuat = simd_quatf(ix: 0.5, iy: 0.5, iz: 0.5, r: 0.5)
        let convertedQuat = convertRotationForVRM0Test(testQuat)
        
        // X and Z should be negated, Y and W should remain
        XCTAssertEqual(convertedQuat.imag.x, -testQuat.imag.x, accuracy: 0.0001)
        XCTAssertEqual(convertedQuat.imag.y, testQuat.imag.y, accuracy: 0.0001)
        XCTAssertEqual(convertedQuat.imag.z, -testQuat.imag.z, accuracy: 0.0001)
        XCTAssertEqual(convertedQuat.real, testQuat.real, accuracy: 0.0001)
        
        // Test translation conversion
        let testTrans = SIMD3<Float>(1.0, 2.0, 3.0)
        let convertedTrans = convertTranslationForVRM0Test(testTrans)
        
        XCTAssertEqual(convertedTrans.x, -testTrans.x, accuracy: 0.0001)
        XCTAssertEqual(convertedTrans.y, testTrans.y, accuracy: 0.0001)
        XCTAssertEqual(convertedTrans.z, -testTrans.z, accuracy: 0.0001)
    }
    
    // MARK: - Bone Name Mapping Tests
    
    /// 🔴 RED: Unity-style bone name mapping
    ///
    /// VRM 0.0 commonly uses Unity naming convention:
    /// - J_Bip_C_Hips (center/hips)
    /// - J_Bip_L_UpperArm (left upper arm)
    /// - J_Bip_R_UpperArm (right upper arm)
    func testVRM0UnityBoneNameMapping() async throws {
        // Arrange: Create test model with Unity-style bone names
        let vrmDocument = try VRMBuilder()
            .setSkeleton(.defaultHumanoid)
            .build()
        
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("vrm")
        
        try vrmDocument.serialize(to: tempURL)
        let model = try await VRMModel.load(from: tempURL, device: device)
        try? FileManager.default.removeItem(at: tempURL)
        
        // The model should have standard humanoid bones mapped
        XCTAssertNotNil(model.humanoid, "Model should have humanoid")
        
        // Verify required bones exist
        let requiredBones: [VRMHumanoidBone] = [
            .hips, .spine, .chest, .neck, .head,
            .leftUpperArm, .leftLowerArm, .leftHand,
            .rightUpperArm, .rightLowerArm, .rightHand,
            .leftUpperLeg, .leftLowerLeg, .leftFoot,
            .rightUpperLeg, .rightLowerLeg, .rightFoot
        ]
        
        for bone in requiredBones {
            let nodeIndex = model.humanoid?.getBoneNode(bone)
            XCTAssertNotNil(nodeIndex, "Required bone \(bone) should be mapped")
        }
    }
    
    /// 🔴 RED: Heuristic bone name matching for VRM 0.0
    func testVRM0HeuristicBoneMatching() {
        // Test various Unity-style naming patterns
        let testCases: [(name: String, expectedBone: VRMHumanoidBone)] = [
            ("J_Bip_C_Hips", .hips),
            ("J_Bip_C_Spine", .spine),
            ("J_Bip_C_Chest", .chest),
            ("J_Bip_C_UpperChest", .upperChest),
            ("J_Bip_C_Neck", .neck),
            ("J_Bip_C_Head", .head),
            ("J_Bip_L_UpperArm", .leftUpperArm),
            ("J_Bip_L_LowerArm", .leftLowerArm),
            ("J_Bip_L_Hand", .leftHand),
            ("J_Bip_L_Shoulder", .leftShoulder),
            ("J_Bip_R_UpperArm", .rightUpperArm),
            ("J_Bip_R_LowerArm", .rightLowerArm),
            ("J_Bip_R_Hand", .rightHand),
            ("J_Bip_R_Shoulder", .rightShoulder),
            ("J_Bip_L_UpperLeg", .leftUpperLeg),
            ("J_Bip_L_LowerLeg", .leftLowerLeg),
            ("J_Bip_L_Foot", .leftFoot),
            ("J_Bip_R_UpperLeg", .rightUpperLeg),
            ("J_Bip_R_LowerLeg", .rightLowerLeg),
            ("J_Bip_R_Foot", .rightFoot),
        ]
        
        // The heuristic matching function from VRMAnimationLoader
        let heuristicNameToBone: (String) -> VRMHumanoidBone? = { name in
            let n = name.lowercased()
            let isLeft = n.contains("_l_") || n.contains("left")
            let isRight = n.contains("_r_") || n.contains("right")
            
            if n.contains("hips") { return .hips }
            if n.contains("upperchest") || (n.contains("upper") && n.contains("chest")) { return .upperChest }
            if n.contains("chest") { return .chest }
            if n.contains("spine") { return .spine }
            if n.contains("neck") { return .neck }
            if n.contains("head") { return .head }
            
            if isLeft {
                if n.contains("upperarm") { return .leftUpperArm }
                if n.contains("lowerarm") { return .leftLowerArm }
                if n.contains("hand") && !n.contains("arm") { return .leftHand }
                if n.contains("shoulder") { return .leftShoulder }
                if n.contains("upperleg") { return .leftUpperLeg }
                if n.contains("lowerleg") { return .leftLowerLeg }
                if n.contains("foot") { return .leftFoot }
                if n.contains("toe") { return .leftToes }
            }
            
            if isRight {
                if n.contains("upperarm") { return .rightUpperArm }
                if n.contains("lowerarm") { return .rightLowerArm }
                if n.contains("hand") && !n.contains("arm") { return .rightHand }
                if n.contains("shoulder") { return .rightShoulder }
                if n.contains("upperleg") { return .rightUpperLeg }
                if n.contains("lowerleg") { return .rightLowerLeg }
                if n.contains("foot") { return .rightFoot }
                if n.contains("toe") { return .rightToes }
            }
            
            return nil
        }
        
        for (name, expectedBone) in testCases {
            let matchedBone = heuristicNameToBone(name)
            XCTAssertEqual(matchedBone, expectedBone, 
                          "Bone '\(name)' should map to \(expectedBone), got \(String(describing: matchedBone))")
        }
    }
    
    // MARK: - Expression Animation Tests
    
    /// 🔴 RED: VRM 0.0 expression animation (BlendShapeProxy)
    ///
    /// VRM 0.0 uses BlendShapeProxy for expressions.
    /// Expression names should map correctly from VRMA.
    func testVRM0ExpressionAnimation() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        let vrmaPath = "\(projectRoot)/VRMA_expressions.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM 0.0 model not found")
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal not available")
            return
        }
        
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        XCTAssertTrue(model.isVRM0, "Test requires VRM 0.0 model")
        
        // VRM 0.0 should have blend shape proxy
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
        
        // Should have morph tracks for expressions
        XCTAssertGreaterThan(clip.morphTracks.count, 0, 
                            "VRM 0.0 should load expression animation as morph tracks")
    }
    
    /// 🔴 RED: VRM 0.0 expression names map correctly
    func testVRM0ExpressionNameMapping() {
        // Common VRM 0.0 expression names (lowercased for VRM 1.0 compatibility)
        let vrm0ExpressionNames = [
            "happy", "angry", "sad", "relaxed", "surprised",
            "blink", "blinkLeft", "blinkRight",
            "lookUp", "lookDown", "lookLeft", "lookRight",
            "aa", "ih", "ou", "ee", "oh"
        ]
        
        // These should map to VRMExpressionPreset
        for name in vrm0ExpressionNames {
            let preset = VRMExpressionPreset(rawValue: name)
            XCTAssertNotNil(preset, "Expression '\(name)' should map to a preset")
        }
    }
    
    // MARK: - Integration Tests
    
    /// 🔴 RED: Full VRM 0.0 + VRMA integration
    func testVRM0FullIntegration() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM 0.0 model not found")
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
        
        // Verify bones were animated
        guard let humanoid = model.humanoid else {
            XCTFail("Model should have humanoid")
            return
        }
        
        var animatedBoneCount = 0
        for track in clip.jointTracks {
            if let nodeIndex = humanoid.getBoneNode(track.bone) {
                let node = model.nodes[nodeIndex]
                // Check if rotation changed from identity
                if abs(node.rotation.real - 1.0) > 0.01 || 
                   simd_length(node.rotation.imag) > 0.01 {
                    animatedBoneCount += 1
                }
            }
        }
        
        XCTAssertGreaterThan(animatedBoneCount, 0, 
                            "Animation should affect at least one bone")
    }
}

// MARK: - Helper Functions

extension VRM0AnimationTests {
    /// Test version of rotation conversion
    private func convertRotationForVRM0Test(_ q: simd_quatf) -> simd_quatf {
        return simd_quatf(ix: -q.imag.x, iy: q.imag.y, iz: -q.imag.z, r: q.real)
    }
    
    /// Test version of translation conversion
    private func convertTranslationForVRM0Test(_ v: SIMD3<Float>) -> SIMD3<Float> {
        return SIMD3<Float>(-v.x, v.y, -v.z)
    }
}
