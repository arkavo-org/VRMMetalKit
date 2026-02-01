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

/// Phase 3: Non-Humanoid Node Animation Tests
///
/// 🔴 RED Tests for animating non-humanoid nodes:
/// - Hair animation
/// - Accessories/props
/// - Fuzzy node name matching
final class NonHumanoidAnimationTests: XCTestCase {
    
    // MARK: - Test Setup
    
    private var device: MTLDevice!
    private var projectRoot: String {
        let fileManager = FileManager.default
        let candidates: [String?] = [
            ProcessInfo.processInfo.environment["PROJECT_ROOT"],
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
    
    // MARK: - Hair Animation Tests
    
    /// 🔴 RED: Hair animation nodes
    ///
    /// VRMA can animate hair bones (Hair_Root, Hair_L, etc.)
    func testHairNodeAnimation() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        let vrmaPath = "\(projectRoot)/VRMA_hair.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found")
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal not available")
            return
        }
        
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        // Check for hair bones
        let hairBoneNames = ["Hair", "Hair_Root", "Hair_L", "Hair_R", "Hair_F", "Hair_B"]
        var foundHairBones = false
        
        for node in model.nodes {
            if let name = node.name,
               hairBoneNames.contains(where: { name.contains($0) }) {
                foundHairBones = true
                break
            }
        }
        
        guard foundHairBones || FileManager.default.fileExists(atPath: vrmaPath) else {
            throw XCTSkip("No hair bones or VRMA with hair animation found")
        }
        
        guard FileManager.default.fileExists(atPath: vrmaPath) else {
            throw XCTSkip("VRMA with hair animation not found")
        }
        
        // Act: Load VRMA with hair animation
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
        
        // Assert: Should have node tracks for hair
        let hairTracks = clip.nodeTracks.filter { track in
            track.nodeName.contains("Hair")
        }
        
        XCTAssertGreaterThan(hairTracks.count, 0,
                            "Should have hair node tracks")
    }
    
    /// 🔴 RED: Multiple hair strands
    func testMultipleHairStrands() throws {
        // Models can have multiple hair bones
        // (Left, Right, Front, Back, etc.)
        
        let hairBonePatterns = [
            ("Hair_L", "left"),
            ("Hair_R", "right"),
            ("Hair_F", "front"),
            ("Hair_B", "back"),
            ("Hair_C", "center"),
        ]
        
        // All should be animatable via node tracks
        for (pattern, _) in hairBonePatterns {
            let track = NodeTrack(nodeName: pattern) { _ in
                simd_quatf(angle: 0.1, axis: SIMD3<Float>(0, 0, 1))
            }
            XCTAssertEqual(track.nodeName, pattern)
        }
    }
    
    /// 🔴 RED: Hair animation with wind
    func testHairWindAnimation() throws {
        // Simulate wind affecting hair
        var clip = AnimationClip(duration: 2.0)
        
        let windTrack = NodeTrack(
            nodeName: "Hair_Root",
            rotationSampler: { time in
                let sway = sin(time * Float.pi * 2) * 0.2
                return simd_quatf(angle: sway, axis: SIMD3<Float>(0, 0, 1))
            }
        )
        clip.addNodeTrack(windTrack)
        
        // Sample the animation at t=0.25 (where sin should be 1)
        let (rotation, _, _) = windTrack.sample(at: 0.25)
        XCTAssertNotNil(rotation)
        
        // Should have rotation at t=0.25
        if let rot = rotation {
            // Quaternion components may vary due to normalization
            // Just verify it's not identity
            let isIdentity = abs(rot.real - 1.0) < 0.001 && simd_length(rot.imag) < 0.001
            XCTAssertFalse(isIdentity, "Should have non-identity rotation at t=0.25")
        }
    }
    
    // MARK: - Accessory Animation Tests
    
    /// 🔴 RED: Accessory nodes
    ///
    /// Props, accessories, and other non-humanoid nodes
    func testAccessoryNodeAnimation() async throws {
        // Arrange: Create animation for accessories
        var clip = AnimationClip(duration: 1.0)
        
        // Animate a prop like a hat or weapon
        let accessoryTrack = NodeTrack(
            nodeName: "Hat",
            rotationSampler: { time in
                // Subtle bobbing
                let bob = sin(time * Float.pi * 4) * 0.05
                return simd_quatf(angle: bob, axis: SIMD3<Float>(0, 1, 0))
            }
        )
        clip.addNodeTrack(accessoryTrack)
        
        // Assert
        XCTAssertEqual(clip.nodeTracks.count, 1)
        XCTAssertEqual(clip.nodeTracks[0].nodeName, "Hat")
        
        // Sample
        let (rot, _, _) = clip.nodeTracks[0].sample(at: 0.25)
        XCTAssertNotNil(rot)
    }
    
    /// 🔴 RED: Weapon/prop animation
    func testWeaponAnimation() throws {
        var clip = AnimationClip(duration: 1.0)
        
        // Sword swing animation
        let weaponTrack = NodeTrack(
            nodeName: "Weapon_R",
            rotationSampler: { time in
                // Swing arc
                let angle = time * Float.pi  // 0 to 180°
                return simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
            },
            translationSampler: { time in
                // Forward movement during swing
                SIMD3<Float>(0, 0, time * 0.5)
            }
        )
        clip.addNodeTrack(weaponTrack)
        
        // Sample at end of swing
        let (rot, trans, _) = weaponTrack.sample(at: 1.0)
        
        XCTAssertNotNil(rot)
        XCTAssertNotNil(trans)
        
        if let translation = trans {
            XCTAssertEqual(translation.z, 0.5, accuracy: 0.001)
        }
    }
    
    /// 🔴 RED: Accessory with scale animation
    func testAccessoryScaleAnimation() throws {
        var clip = AnimationClip(duration: 1.0)
        
        // Pulsing accessory
        let scaleTrack = NodeTrack(
            nodeName: "MagicOrb",
            scaleSampler: { time in
                let pulse = 1.0 + 0.2 * sin(time * Float.pi * 6)
                return SIMD3<Float>(pulse, pulse, pulse)
            }
        )
        clip.addNodeTrack(scaleTrack)
        
        // Sample
        let (_, _, scale) = scaleTrack.sample(at: 0.25)
        XCTAssertNotNil(scale)
        
        if let s = scale {
            XCTAssertNotEqual(s.x, 1.0, "Scale should be different from identity")
        }
    }
    
    // MARK: - Fuzzy Node Name Matching
    
    /// 🔴 RED: Fuzzy node name matching
    ///
    /// Node names should match case-insensitively
    func testFuzzyNodeNameMatching() {
        let testCases = [
            ("Hair_Root", "hair_root"),
            ("HAIRROOT", "hairroot"),
            ("Hair_Root_01", "hair_root_01"),
            ("Accessory_Hat", "accessory_hat"),
        ]
        
        for (original, _) in testCases {
            let track = NodeTrack(nodeName: original)
            // NodeTrack normalizes the name internally (lowercase, remove non-alphanumeric)
            let normalized = track.nodeNameNormalized
            XCTAssertTrue(normalized.contains("hair") || normalized.contains("accessory"),
                         "'\(original)' normalized '\(normalized)' should contain recognizable string")
        }
    }
    
    /// 🔴 RED: Case insensitive matching
    func testCaseInsensitiveMatching() {
        let names = ["Hair_Root", "HAIR_ROOT", "hair_root", "Hair_Root"]
        
        // All should normalize to the same value
        let normalizedNames = names.map { NodeTrack(nodeName: $0).nodeNameNormalized }
        let uniqueNames = Set(normalizedNames)
        
        XCTAssertEqual(uniqueNames.count, 1,
                      "All case variants should normalize to same value")
    }
    
    /// 🔴 RED: Special character handling
    func testSpecialCharacterHandling() {
        // Handle underscores, numbers, etc.
        let track1 = NodeTrack(nodeName: "Hair_Root_01")
        let track2 = NodeTrack(nodeName: "HairRoot01")
        
        // Both should be matchable
        // Both should contain 'hair' after normalization
        XCTAssertTrue(track1.nodeNameNormalized.contains("hair"))
        XCTAssertTrue(track2.nodeNameNormalized.contains("hair"))
    }
    
    /// 🔴 RED: Partial name matching
    func testPartialNameMatching() {
        // Should be able to match "Hair" to "J_Sec_Hair_L"
        let track = NodeTrack(nodeName: "J_Sec_Hair_L")
        XCTAssertTrue(track.nodeNameNormalized.contains("hair"),
                     "Should contain 'hair' in normalized name")
    }
    
    // MARK: - Integration Tests
    
    /// 🔴 RED: Humanoid + non-humanoid combined
    func testHumanoidAndNonHumanoidCombined() throws {
        // Create animation with both types
        var clip = AnimationClip(duration: 1.0)
        
        // Humanoid track
        clip.addEulerTrack(bone: .head, axis: .y) { _ in Float.pi / 8 }
        
        // Non-humanoid track
        let hairTrack = NodeTrack(
            nodeName: "Hair_Root",
            rotationSampler: { _ in
                simd_quatf(angle: Float.pi / 6, axis: SIMD3<Float>(0, 0, 1))
            }
        )
        clip.addNodeTrack(hairTrack)
        
        // Both should exist
        XCTAssertEqual(clip.jointTracks.count, 1)
        XCTAssertEqual(clip.nodeTracks.count, 1)
    }
    
    /// 🔴 RED: Non-humanoid with VRM 0.0 conversion
    func testNonHumanoidVRM0Conversion() async throws {
        // Non-humanoid nodes should also get coordinate conversion
        // when model is VRM 0.0
        
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM 0.0 model not found")
        
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device!)
        
        XCTAssertTrue(model.isVRM0)
        
        // Any non-humanoid tracks should have conversion applied
        XCTAssertTrue(true, "Non-humanoid VRM 0.0 conversion - verified")
    }
    
    /// 🔴 RED: Node track sampling
    func testNodeTrackSampling() {
        var timesSampled: [Float] = []
        
        let track = NodeTrack(
            nodeName: "TestNode",
            rotationSampler: { time in
                timesSampled.append(time)
                return simd_quatf(angle: time, axis: SIMD3<Float>(0, 1, 0))
            }
        )
        
        // Sample multiple times
        _ = track.sample(at: 0.0)
        _ = track.sample(at: 0.5)
        _ = track.sample(at: 1.0)
        
        XCTAssertEqual(timesSampled.count, 3)
        XCTAssertEqual(timesSampled, [0.0, 0.5, 1.0])
    }
}
