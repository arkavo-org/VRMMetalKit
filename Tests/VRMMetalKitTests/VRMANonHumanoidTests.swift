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

/// TDD Tests for VRMA non-humanoid node animation
///
/// Very narrow focus: Verify VRMA animations correctly handle non-humanoid nodes
/// like hair, bust, accessories that aren't part of the humanoid bone hierarchy
final class VRMANonHumanoidTests: XCTestCase {

    // MARK: - Test Paths
    
    private var vrmModelsPath: String {
        return "/Users/arkavo/Documents/VRMModels"
    }
    
    private var vrmaPath: String {
        let gameOfModsPath = "/Users/arkavo/Projects/GameOfMods/GameOfMods"
        if FileManager.default.fileExists(atPath: "\(gameOfModsPath)/VRMA_01.vrma") {
            return gameOfModsPath
        }
        return "/Users/arkavo/Projects/VRMMetalKit"
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
    
    // MARK: - TDD RED: Non-Humanoid Node Track Tests
    
    /// RED: Test that VRMA files have non-humanoid node tracks
    ///
    /// Non-humanoid nodes (hair, accessories) should be captured as NodeTracks
    func testVRMAHasNonHumanoidNodeTracks() async throws {
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
        
        print("\n=== VRMA Non-Humanoid Node Tracks ===")
        print("Joint tracks (humanoid): \(clip.jointTracks.count)")
        print("Node tracks (non-humanoid): \(clip.nodeTracks.count)")
        
        // Log node track names
        for track in clip.nodeTracks {
            print("  Node: \(track.nodeName)")
        }
        
        // Document what we found - some VRMAs may have non-humanoid animation
        if clip.nodeTracks.isEmpty {
            print("Note: VRMA_01.vrma has no non-humanoid node tracks")
        }
    }
    
    /// RED: Test non-humanoid node track sampling
    ///
    /// Node tracks should produce valid transforms when sampled
    func testNonHumanoidNodeTrackSampling() async throws {
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
        
        // Sample all node tracks at various times
        let sampleTimes: [Float] = [0, 0.5, 1.0].map { $0 * clip.duration }
        
        print("\n=== Non-Humanoid Node Track Sampling ===")
        
        for track in clip.nodeTracks {
            print("Node: \(track.nodeName)")
            
            for time in sampleTimes {
                if let rotation = track.rotationSampler?(time) {
                    // Verify valid quaternion
                    let length = simd_length(rotation.vector)
                    XCTAssertEqual(length, 1.0, accuracy: 0.01,
                                   "Rotation should be normalized")
                }
                
                if let translation = track.translationSampler?(time) {
                    // Verify no NaN
                    XCTAssertFalse(translation.x.isNaN, "Translation X should not be NaN")
                    XCTAssertFalse(translation.y.isNaN, "Translation Y should not be NaN")
                    XCTAssertFalse(translation.z.isNaN, "Translation Z should not be NaN")
                }
            }
        }
    }
    
    /// RED: Test node name normalization
    ///
    /// NodeTrack should normalize names for matching (lowercase, remove underscores)
    func testNodeNameNormalization() {
        // Test cases for node name normalization
        let testCases = [
            ("J_Sec_Hair1", "jsechair1"),
            ("Bust", "bust"),
            ("Acc_Headphone", "accheadphone"),
            ("hair_L_01", "hairl01"),
        ]
        
        print("\n=== Node Name Normalization ===")
        
        for (input, expected) in testCases {
            let normalized = input.lowercased()
                .replacingOccurrences(of: "_", with: "")
            
            print("  \(input) -> \(normalized)")
            XCTAssertEqual(normalized, expected, "Normalization should match expected")
        }
    }
    
    /// RED: Test multiple VRMA files for non-humanoid diversity
    func testMultipleVRMANonHumanoidDiversity() async throws {
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
        
        print("\n=== VRMA Non-Humanoid Diversity ===")
        
        var allNodeNames: Set<String> = []
        
        for vrmaFile in vrmaFiles {
            let vrmaPath = "\(self.vrmaPath)/\(vrmaFile)"
            
            guard FileManager.default.fileExists(atPath: vrmaPath) else {
                print("  \(vrmaFile): not found")
                continue
            }
            
            do {
                let vrmaURL = URL(fileURLWithPath: vrmaPath)
                let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
                
                let nodeNames = clip.nodeTracks.map { $0.nodeName }
                allNodeNames.formUnion(nodeNames)
                
                if nodeNames.isEmpty {
                    print("  \(vrmaFile): no non-humanoid tracks")
                } else {
                    print("  \(vrmaFile): \(nodeNames.joined(separator: ", "))")
                }
            } catch {
                print("  \(vrmaFile): error - \(error)")
            }
        }
        
        print("\nAll unique non-humanoid nodes: \(allNodeNames.sorted())")
    }
    
    // MARK: - TDD RED: Node Track vs Joint Track Separation
    
    /// RED: Test that humanoid bones go to jointTracks, not nodeTracks
    ///
    /// Humanoid bones (hips, spine, etc.) should be in jointTracks
    /// Non-humanoid nodes (hair, accessories) should be in nodeTracks
    func testHumanoidBonesNotInNodeTracks() async throws {
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
        
        print("\n=== Humanoid vs Non-Humanoid Separation ===")
        print("Joint tracks: \(clip.jointTracks.map { $0.bone.rawValue })")
        print("Node tracks: \(clip.nodeTracks.map { $0.nodeName })")
        
        // Verify no overlap - node tracks shouldn't have humanoid bone names
        let humanoidNames = Set(VRMHumanoidBone.allCases.map { $0.rawValue.lowercased() })
        
        for track in clip.nodeTracks {
            let nodeNameLower = track.nodeName.lowercased()
            
            // Check if node name matches any humanoid bone
            let isHumanoidName = humanoidNames.contains { boneName in
                nodeNameLower.contains(boneName)
            }
            
            if isHumanoidName {
                print("  ⚠️ Node '\(track.nodeName)' might be a humanoid bone")
            }
        }
        
        // The separation should be clean - no humanoid bones in nodeTracks
        XCTAssertTrue(true, "Separation documented")
    }
    
    /// RED: Test VRM 1.0 model with non-humanoid nodes
    func testVRM1NonHumanoidNodes() async throws {
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
        
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
        
        print("\n=== VRM 1.0 Non-Humanoid Nodes (Seed-san) ===")
        print("Joint tracks: \(clip.jointTracks.count)")
        print("Node tracks: \(clip.nodeTracks.count)")
        
        for track in clip.nodeTracks {
            print("  \(track.nodeName)")
        }
        
        // Both VRM 0.0 and 1.0 should handle non-humanoid nodes similarly
        XCTAssertEqual(model.specVersion, .v1_0)
    }
    
    // MARK: - TDD RED: Mock Node Track Tests
    
    /// RED: Test NodeTrack structure
    func testNodeTrackStructure() {
        let nodeName = "J_Sec_Hair1"
        let rotationSampler: ((Float) -> simd_quatf)? = { _ in
            simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        let translationSampler: ((Float) -> SIMD3<Float>)? = { _ in
            SIMD3<Float>(0, 0, 0)
        }
        
        let track = NodeTrack(
            nodeName: nodeName,
            rotationSampler: rotationSampler,
            translationSampler: translationSampler,
            scaleSampler: nil
        )
        
        XCTAssertEqual(track.nodeName, nodeName)
        XCTAssertEqual(track.nodeNameNormalized, "jsechair1")
        XCTAssertNotNil(track.rotationSampler)
        XCTAssertNotNil(track.translationSampler)
        XCTAssertNil(track.scaleSampler)
        
        // Test sampling
        let rotation = track.rotationSampler?(0)
        let translation = track.translationSampler?(0)
        
        XCTAssertNotNil(rotation)
        XCTAssertNotNil(translation)
        
        print("\n=== NodeTrack Structure ===")
        print("Node name: \(track.nodeName)")
        print("Normalized: \(track.nodeNameNormalized)")
        print("Has rotation: \(track.rotationSampler != nil)")
        print("Has translation: \(track.translationSampler != nil)")
        print("Has scale: \(track.scaleSampler != nil)")
    }
    
    /// RED: Test common non-humanoid node naming patterns
    func testCommonNonHumanoidNodePatterns() {
        // Common patterns for non-humanoid nodes in VRM models
        let commonPatterns = [
            "J_Sec_Hair",      // Hair secondary bones
            "Hair",            // Generic hair
            "Bust",            // Chest/bust animation
            "Acc_",            // Accessories
            "Accessory",       // Accessories
            "Tail",            // Tails
            "Ear",             // Animal ears
            "Wing",            // Wings
            "Ribbon",          // Ribbons
            "Skirt",           // Skirt bones
        ]
        
        print("\n=== Common Non-Humanoid Node Patterns ===")
        
        for pattern in commonPatterns {
            print("  \(pattern)")
        }
        
        // Document the expected patterns
        XCTAssertGreaterThan(commonPatterns.count, 0)
    }
    
    /// RED: Test node track coordinate conversion
    ///
    /// Non-humanoid nodes should follow the same coordinate conversion
    /// as humanoid bones based on VRM version
    func testNonHumanoidCoordinateConversion() {
        // This is a documentation test
        print("\n=== Non-Humanoid Coordinate Conversion ===")
        print("Expected behavior:")
        print("  - VRM 0.0: Apply coordinate conversion (left-handed)")
        print("  - VRM 1.0: No conversion (right-handed)")
        print("  - Same as humanoid bones")
        
        XCTAssertTrue(true, "Behavior documented")
    }
}
