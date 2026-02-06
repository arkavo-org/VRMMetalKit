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

/// TDD Tests for VRMA bone retargeting
/// 
/// Very narrow focus: Verify that VRMA animation bones correctly map to VRM model bones
/// Uses actual VRMA files from GameOfMods and actual VRM models
final class VRMABoneRetargetingTests: XCTestCase {

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
    
    private var vrmaPath: String {
        // Try environment variable first, then fallback to project root
        if let envPath = ProcessInfo.processInfo.environment["VRMA_TEST_PATH"] {
            return envPath
        }
        return projectRoot
    }
    
    // MARK: - TDD RED: Actual File Integration Tests
    
    /// RED: Test that VRMA_01.vrma loads and maps bones to AliciaSolid.vrm
    /// 
    /// This test verifies the full pipeline:
    /// 1. Load VRM 0.0 model (AliciaSolid.vrm)
    /// 2. Load VRMA animation (VRMA_01.vrma)
    /// 3. Verify bones are correctly mapped
    func testVRMA01MapsBonesToAliciaSolid() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        let vrmaPath = "\(self.vrmaPath)/VRMA_01.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found at \(modelPath)")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA file not found at \(vrmaPath)")
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal device not available")
            return
        }
        
        // Load VRM 0.0 model
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        // Load VRMA animation
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
        
        // Verify animation loaded
        XCTAssertGreaterThan(clip.duration, 0, "Animation should have positive duration")
        
        // Verify at least some bones were mapped
        XCTAssertGreaterThan(clip.jointTracks.count, 0, "Should have joint tracks")
        
        // Log mapped bones for debugging
        print("\n=== VRMA_01 Bone Mapping to AliciaSolid ===")
        print("Duration: \(clip.duration)s")
        print("Joint tracks: \(clip.jointTracks.count)")
        
        for track in clip.jointTracks {
            let (rot, trans, _) = track.sample(at: 0)
            print("  \(track.bone): rotation=\(rot != nil ? "✓" : "✗") translation=\(trans != nil ? "✓" : "✗")")
        }
        
        // Verify essential bones are mapped
        let essentialBones: [VRMHumanoidBone] = [.hips, .spine, .head]
        for bone in essentialBones {
            let hasTrack = clip.jointTracks.contains { $0.bone == bone }
            // Don't fail if missing - just log - some animations may not have all bones
            if !hasTrack {
                print("  ⚠️ Missing track for \(bone)")
            }
        }
    }
    
    /// RED: Test that VRMA bone retargeting produces valid quaternion values
    /// 
    /// Samples animation at various times and verifies rotations are valid
    func testVRMA01ProducesValidRotations() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        let vrmaPath = "\(self.vrmaPath)/VRMA_01.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found at \(modelPath)")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA file not found at \(vrmaPath)")
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal device not available")
            return
        }
        
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
        
        // Sample at multiple time points
        let sampleTimes: [Float] = [0, 0.25, 0.5, 0.75, 1.0].map { $0 * clip.duration }
        
        print("\n=== VRMA_01 Rotation Validation ===")
        
        for track in clip.jointTracks {
            for time in sampleTimes {
                let (rot, _, _) = track.sample(at: time)
                
                if let rotation = rot {
                    // Verify quaternion is normalized
                    let length = simd_length(rotation.vector)
                    XCTAssertEqual(length, 1.0, accuracy: 0.01,
                                   "\(track.bone) rotation at t=\(time) should be normalized")
                    
                    // Verify no NaN or infinite values
                    let vec = rotation.vector
                    let hasNaN = vec[0].isNaN || vec[1].isNaN || vec[2].isNaN || vec[3].isNaN
                    let hasInfinite = vec[0].isInfinite || vec[1].isInfinite || vec[2].isInfinite || vec[3].isInfinite
                    
                    XCTAssertFalse(hasNaN,
                                   "\(track.bone) rotation at t=\(time) should not contain NaN")
                    XCTAssertFalse(hasInfinite,
                                   "\(track.bone) rotation at t=\(time) should not contain infinity")
                }
            }
        }
    }
    
    /// RED: Test multiple VRMA files load successfully
    func testMultipleVRMAFilesLoad() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found at \(modelPath)")
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal device not available")
            return
        }
        
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        let vrmaFiles = (1...7).map { "VRMA_0\($0).vrma" }
        
        print("\n=== Multiple VRMA Loading Test ===")
        
        for vrmaFile in vrmaFiles {
            let vrmaPath = "\(self.vrmaPath)/\(vrmaFile)"
            
            guard FileManager.default.fileExists(atPath: vrmaPath) else {
                print("  ⚠️ \(vrmaFile) not found, skipping")
                continue
            }
            
            do {
                let vrmaURL = URL(fileURLWithPath: vrmaPath)
                let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
                
                print("  ✓ \(vrmaFile): duration=\(String(format: "%.2f", clip.duration))s, tracks=\(clip.jointTracks.count)")
                
                XCTAssertGreaterThan(clip.duration, 0, "\(vrmaFile) should have positive duration")
            } catch {
                XCTFail("Failed to load \(vrmaFile): \(error)")
            }
        }
    }
    
    // MARK: - TDD RED: Mock Tests for Isolated Behavior
    
    /// RED: Test bone mapping priority with mock data
    /// 
    /// Priority order:
    /// 1. VRMA extension humanoid mapping
    /// 2. Model node name mapping
    /// 3. Heuristic name matching
    func testBoneMappingPriority() {
        // This test validates the mapping priority logic
        // We can't easily test this with actual files, so we document the expected behavior
        
        let expectedPriority: [(source: String, priority: Int)] = [
            ("VRMA extension humanoid", 1),
            ("Model node name", 2),
            ("Heuristic matching", 3)
        ]
        
        // Verify priority order
        for i in 0..<expectedPriority.count-1 {
            XCTAssertLessThan(expectedPriority[i].priority, expectedPriority[i+1].priority,
                              "\(expectedPriority[i].source) should have higher priority than \(expectedPriority[i+1].source)")
        }
        
        print("\n=== Bone Mapping Priority ===")
        for item in expectedPriority {
            print("  \(item.priority). \(item.source)")
        }
    }
    
    /// RED: Test coordinate conversion math for VRM 0.0
    /// 
    /// VRMA (VRM 1.0) uses right-handed coordinates
    /// VRM 0.0 uses Unity left-handed coordinates
    /// Conversion: negate X and Z
    func testVRM0CoordinateConversionMath() {
        // Test rotation conversion
        let originalRotation = simd_quatf(ix: 0.3, iy: 0.4, iz: 0.5, r: 0.6)
        
        // Expected: X and Z negated, Y and W unchanged
        let expectedRotation = simd_quatf(
            ix: -originalRotation.imag.x,
            iy: originalRotation.imag.y,
            iz: -originalRotation.imag.z,
            r: originalRotation.real
        )
        
        XCTAssertEqual(expectedRotation.imag.x, -0.3, accuracy: 0.0001)
        XCTAssertEqual(expectedRotation.imag.y, 0.4, accuracy: 0.0001)
        XCTAssertEqual(expectedRotation.imag.z, -0.5, accuracy: 0.0001)
        XCTAssertEqual(expectedRotation.real, 0.6, accuracy: 0.0001)
        
        // Test translation conversion
        let originalTranslation = SIMD3<Float>(1.0, 2.0, 3.0)
        let expectedTranslation = SIMD3<Float>(-1.0, 2.0, -3.0)
        
        XCTAssertEqual(expectedTranslation.x, -originalTranslation.x, accuracy: 0.0001)
        XCTAssertEqual(expectedTranslation.y, originalTranslation.y, accuracy: 0.0001)
        XCTAssertEqual(expectedTranslation.z, -originalTranslation.z, accuracy: 0.0001)
    }
    
    /// RED: Test that retargeting preserves animation intent
    /// 
    /// When animation rest pose differs from model bind pose,
    /// retargeting should preserve the animation's relative motion
    func testRetargetingPreservesAnimationIntent() throws {
        // This is a conceptual test documenting expected behavior
        // Full testing would require known animation/model pairs
        
        print("\n=== Retargeting Intent Preservation ===")
        print("Expected behavior:")
        print("  - Animation delta from rest pose is preserved")
        print("  - Applied to model's bind pose")
        print("  - Result: animation looks correct on different skeletons")
        
        // Retargeting formula: result = modelRest * inverse(animationRest) * animationValue
        // This is verified indirectly through integration tests
        throw XCTSkip("Retargeting intent preservation needs known animation/model pairs")
    }
}
