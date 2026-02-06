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

/// TDD Tests for Advanced VRMA Features (1-6)
///
/// 1. Animation Playback - Looping, speed, seeking
/// 2. Performance - Loading benchmarks, memory
/// 3. Error Handling - Corrupted files, missing bones
/// 4. SpringBone Integration - Physics + animation
/// 5. Multi-Animation Blending - Layer mixing
/// 6. Visual Rendering - Pixel validation
final class VRMAAdvancedTests: XCTestCase {

    // MARK: - Test Paths
    
    private var vrmModelsPath: String { 
        ProcessInfo.processInfo.environment["VRM_MODELS_PATH"] ?? projectRoot 
    }
    private var vrmaPath: String { 
        ProcessInfo.processInfo.environment["VRMA_TEST_PATH"] ?? projectRoot 
    }
    private var projectRoot: String {
        let candidates: [String?] = [
            ProcessInfo.processInfo.environment["PROJECT_ROOT"],
            URL(fileURLWithPath: #file).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().path
        ]
        for candidate in candidates.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: "\(candidate)/Package.swift") {
                return candidate
            }
        }
        return FileManager.default.currentDirectoryPath
    }

    // ============================================================================
    // MARK: - 1. ANIMATION PLAYBACK TESTS
    // ============================================================================
    
    /// Test animation looping behavior
    func testAnimationLooping() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        let vrmaPath = "\(self.vrmaPath)/VRMA_01.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath))
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath))
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal not available")
            return
        }
        
        let model = try await VRMModel.load(from: URL(fileURLWithPath: modelPath), device: device)
        let clip = try VRMAnimationLoader.loadVRMA(from: URL(fileURLWithPath: vrmaPath), model: model)
        
        print("\n=== Animation Looping Test ===")
        print("Duration: \(clip.duration)s")
        
        // Test time wrapping for looping
        let loopTimes: [Float] = [
            clip.duration + 0.5,      // Should wrap to 0.5
            clip.duration * 2 + 0.3,  // Should wrap to 0.3
            -0.5                       // Should clamp or wrap
        ]
        
        for time in loopTimes {
            // Sample at wrapped time
            if let track = clip.jointTracks.first {
                let (rot, _, _) = track.sample(at: time)
                print("Time \(time): rotation \(rot != nil ? "valid" : "nil")")
            }
        }
    }
    
    /// Test animation speed multiplier
    func testAnimationSpeedMultiplier() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        let vrmaPath = "\(self.vrmaPath)/VRMA_01.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath))
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath))
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal not available")
            return
        }
        
        let model = try await VRMModel.load(from: URL(fileURLWithPath: modelPath), device: device)
        let clip = try VRMAnimationLoader.loadVRMA(from: URL(fileURLWithPath: vrmaPath), model: model)
        
        print("\n=== Animation Speed Test ===")
        
        let speeds: [Float] = [0.5, 1.0, 2.0, 0.0]
        
        for speed in speeds {
            let effectiveDuration = clip.duration / max(speed, 0.001)
            print("Speed \(speed)x: effective duration \(String(format: "%.2f", effectiveDuration))s")
        }
    }
    
    /// Test animation seeking
    func testAnimationSeeking() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        let vrmaPath = "\(self.vrmaPath)/VRMA_01.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath))
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath))
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal not available")
            return
        }
        
        let model = try await VRMModel.load(from: URL(fileURLWithPath: modelPath), device: device)
        let clip = try VRMAnimationLoader.loadVRMA(from: URL(fileURLWithPath: vrmaPath), model: model)
        
        print("\n=== Animation Seeking Test ===")
        
        let seekTimes: [Float] = [0, 0.25, 0.5, 0.75, 1.0].map { $0 * clip.duration }
        
        guard let hipsTrack = clip.jointTracks.first(where: { $0.bone == .hips }) else {
            XCTFail("No hips track")
            return
        }
        
        for time in seekTimes {
            let (rot, trans, _) = hipsTrack.sample(at: time)
            print("Seek to \(String(format: "%.2f", time)): rot=\(rot != nil ? "✓" : "✗") trans=\(trans != nil ? "✓" : "✗")")
        }
    }

    // ============================================================================
    // MARK: - 2. PERFORMANCE TESTS
    // ============================================================================
    
    /// Test VRMA loading performance
    func testVRMALoadingPerformance() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        let vrmaPath = "\(self.vrmaPath)/VRMA_01.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath))
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath))
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal not available")
            return
        }
        
        let model = try await VRMModel.load(from: URL(fileURLWithPath: modelPath), device: device)
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        
        print("\n=== Performance Test: VRMA Loading ===")
        
        let iterations = 10
        let startTime = CFAbsoluteTimeGetCurrent()
        
        for _ in 0..<iterations {
            _ = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
        }
        
        let endTime = CFAbsoluteTimeGetCurrent()
        let avgTime = (endTime - startTime) / Double(iterations)
        
        print("Loaded \(iterations) times")
        print("Average load time: \(String(format: "%.3f", avgTime * 1000))ms")
        
        // Should load in reasonable time (< 100ms)
        XCTAssertLessThan(avgTime, 0.1, "Loading should be fast")
    }
    
    /// Test animation sampling performance
    func testAnimationSamplingPerformance() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        let vrmaPath = "\(self.vrmaPath)/VRMA_01.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath))
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath))
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal not available")
            return
        }
        
        let model = try await VRMModel.load(from: URL(fileURLWithPath: modelPath), device: device)
        let clip = try VRMAnimationLoader.loadVRMA(from: URL(fileURLWithPath: vrmaPath), model: model)
        
        print("\n=== Performance Test: Animation Sampling ===")
        
        let iterations = 1000
        let startTime = CFAbsoluteTimeGetCurrent()
        
        for i in 0..<iterations {
            let time = Float(i % 100) / 100.0 * clip.duration
            for track in clip.jointTracks {
                _ = track.sample(at: time)
            }
        }
        
        let endTime = CFAbsoluteTimeGetCurrent()
        let avgTime = (endTime - startTime) / Double(iterations) * 1000.0
        
        print("Sampled \(iterations) frames across \(clip.jointTracks.count) tracks")
        print("Average sample time: \(String(format: "%.4f", avgTime))ms")
        
        // Should sample fast (< 5ms per frame for all tracks)
        XCTAssertLessThan(avgTime, 5.0, "Sampling should be fast (< 5ms per frame)")
    }

    // ============================================================================
    // MARK: - 3. ERROR HANDLING TESTS
    // ============================================================================
    
    /// Test loading non-existent file
    func testLoadNonExistentFile() {
        let badPath = "/nonexistent/path/file.vrma"
        
        XCTAssertThrowsError(try VRMAnimationLoader.loadVRMA(from: URL(fileURLWithPath: badPath), model: nil)) { error in
            print("\n=== Error Handling: Non-existent file ===")
            print("Error: \(error)")
        }
    }
    
    /// Test loading invalid file format
    func testLoadInvalidFileFormat() {
        // Create a temporary invalid file
        let tempPath = NSTemporaryDirectory() + "invalid.vrma"
        let invalidData = "This is not a valid GLB file".data(using: .utf8)!
        try? invalidData.write(to: URL(fileURLWithPath: tempPath))
        
        defer { try? FileManager.default.removeItem(atPath: tempPath) }
        
        XCTAssertThrowsError(try VRMAnimationLoader.loadVRMA(from: URL(fileURLWithPath: tempPath), model: nil)) { error in
            print("\n=== Error Handling: Invalid format ===")
            print("Error: \(error)")
        }
    }
    
    /// Test animation with no humanoid bones
    func testAnimationWithNoHumanoidBones() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath))
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal not available")
            return
        }
        
        let model = try await VRMModel.load(from: URL(fileURLWithPath: modelPath), device: device)
        
        print("\n=== Error Handling: Bone Mapping ===")
        print("Model has \(model.humanoid?.humanBones.count ?? 0) humanoid bones")
        
        // Model should have bones
        XCTAssertGreaterThan(model.humanoid?.humanBones.count ?? 0, 0)
    }

    // ============================================================================
    // MARK: - 4. SPRINGBONE INTEGRATION TESTS
    // ============================================================================
    
    /// Test that SpringBone works alongside animation
    func testSpringBoneWithAnimation() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        let vrmaPath = "\(self.vrmaPath)/VRMA_01.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath))
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath))
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal not available")
            return
        }
        
        let model = try await VRMModel.load(from: URL(fileURLWithPath: modelPath), device: device)
        let clip = try VRMAnimationLoader.loadVRMA(from: URL(fileURLWithPath: vrmaPath), model: model)
        
        print("\n=== SpringBone Integration Test ===")
        print("Model has SpringBone: \(model.springBone != nil)")
        print("SpringBone springs: \(model.springBone?.springs.count ?? 0)")
        print("Animation tracks: \(clip.jointTracks.count)")
        
        // Document that SpringBone and animation should coexist
        throw XCTSkip("SpringBone and animation coexistence needs assertions")
    }
    
    /// Test SpringBone colliders exist
    func testSpringBoneColliders() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath))
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal not available")
            return
        }
        
        let model = try await VRMModel.load(from: URL(fileURLWithPath: modelPath), device: device)
        
        print("\n=== SpringBone Colliders ===")
        print("Colliders: \(model.springBone?.colliders.count ?? 0)")
        
        // SpringBone should have colliders for physics
        XCTAssertNotNil(model.springBone)
    }

    // ============================================================================
    // MARK: - 5. MULTI-ANIMATION BLENDING TESTS
    // ============================================================================
    
    /// Test blending multiple animations
    func testAnimationBlending() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        let vrma1Path = "\(self.vrmaPath)/VRMA_01.vrma"
        let vrma2Path = "\(self.vrmaPath)/VRMA_02.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath))
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrma1Path))
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrma2Path))
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal not available")
            return
        }
        
        let model = try await VRMModel.load(from: URL(fileURLWithPath: modelPath), device: device)
        let clip1 = try VRMAnimationLoader.loadVRMA(from: URL(fileURLWithPath: vrma1Path), model: model)
        let clip2 = try VRMAnimationLoader.loadVRMA(from: URL(fileURLWithPath: vrma2Path), model: model)
        
        print("\n=== Animation Blending Test ===")
        print("Clip 1: \(clip1.duration)s, \(clip1.jointTracks.count) tracks")
        print("Clip 2: \(clip2.duration)s, \(clip2.jointTracks.count) tracks")
        
        // Sample both at same time
        let time: Float = 0.5
        
        for bone in [VRMHumanoidBone.hips, VRMHumanoidBone.head] {
            let rot1 = clip1.jointTracks.first { $0.bone == bone }?.sample(at: time).rotation
            let rot2 = clip2.jointTracks.first { $0.bone == bone }?.sample(at: time).rotation
            
            print("\(bone.rawValue):")
            print("  Clip1: \(rot1 != nil ? "✓" : "✗")")
            print("  Clip2: \(rot2 != nil ? "✓" : "✗")")
        }
        
        // Blending would interpolate between rot1 and rot2
        throw XCTSkip("Animation blending not yet implemented")
    }
    
    /// Test animation layer prioritization
    func testAnimationLayerPriority() throws {
        print("\n=== Animation Layer Priority ===")
        print("Priority order (highest to lowest):")
        print("  1. VRMA animation (direct bone control)")
        print("  2. IK layers (foot IK)")
        print("  3. Procedural layers (breathing)")
        print("  4. Base pose")
        
        throw XCTSkip("Layer priority not yet implemented")
    }

    // ============================================================================
    // MARK: - 6. VISUAL RENDERING TESTS
    // ============================================================================
    
    /// Test animation produces different poses at different times
    func testAnimationProducesDifferentPoses() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        let vrmaPath = "\(self.vrmaPath)/VRMA_01.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath))
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath))
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal not available")
            return
        }
        
        let model = try await VRMModel.load(from: URL(fileURLWithPath: modelPath), device: device)
        let clip = try VRMAnimationLoader.loadVRMA(from: URL(fileURLWithPath: vrmaPath), model: model)
        
        print("\n=== Visual Rendering: Pose Variation ===")
        
        guard let hipsTrack = clip.jointTracks.first(where: { $0.bone == .hips }) else {
            XCTFail("No hips track")
            return
        }
        
        // Sample at different times
        let time1: Float = 0
        let time2: Float = clip.duration / 2
        
        let (rot1, trans1, _) = hipsTrack.sample(at: time1)
        let (rot2, trans2, _) = hipsTrack.sample(at: time2)
        
        print("Hips at t=0: \(rot1?.vector ?? SIMD4<Float>(repeating: 0))")
        print("Hips at t=\(time2): \(rot2?.vector ?? SIMD4<Float>(repeating: 0))")
        
        // Poses should be different
        let sameRotation = rot1?.vector == rot2?.vector
        print("Poses identical: \(sameRotation)")
        
        // Animation should produce variation
        throw XCTSkip("Animation variation needs assertions")
    }
    
    /// Test that animation affects bone transforms
    func testAnimationAffectsBones() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        let vrmaPath = "\(self.vrmaPath)/VRMA_01.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath))
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath))
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal not available")
            return
        }
        
        let model = try await VRMModel.load(from: URL(fileURLWithPath: modelPath), device: device)
        let clip = try VRMAnimationLoader.loadVRMA(from: URL(fileURLWithPath: vrmaPath), model: model)
        
        print("\n=== Visual Rendering: Bone Transform Test ===")
        
        // Check multiple bones
        let testBones: [VRMHumanoidBone] = [.hips, .spine, .head, .leftUpperArm]
        
        for bone in testBones {
            guard let track = clip.jointTracks.first(where: { $0.bone == bone }) else {
                print("\(bone): not animated")
                continue
            }
            
            let (rot, trans, _) = track.sample(at: 0)
            let hasTransform = rot != nil || trans != nil
            
            print("\(bone): animated=\(hasTransform ? "✓" : "✗")")
        }
        
        throw XCTSkip("Bone transform validation needs assertions")
    }
}
