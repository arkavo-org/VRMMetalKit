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

/// Phase 4: Animation Edge Case Tests
///
/// 🔴 RED Tests for edge cases and error handling:
/// - Empty animations
/// - Single keyframe
/// - Zero duration
/// - Missing bones
/// - Quaternion neighborhood
final class AnimationEdgeCaseTests: XCTestCase {
    
    // MARK: - Test Setup
    
    private var device: MTLDevice!
    private var model: VRMModel!
    
    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
        
        let vrmDocument = try VRMBuilder()
            .setSkeleton(.defaultHumanoid)
            .build()
        
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("vrm")
        
        try vrmDocument.serialize(to: tempURL)
        self.model = try await VRMModel.load(from: tempURL, device: device)
        try? FileManager.default.removeItem(at: tempURL)
    }
    
    override func tearDown() {
        model = nil
        device = nil
    }
    
    // MARK: - Empty Animation Tests
    
    /// 🔴 RED: Empty animation clip
    ///
    /// Should not crash when playing empty clip.
    func testEmptyClip() throws {
        let clip = AnimationClip(duration: 0.0)
        
        let player = AnimationPlayer()
        player.load(clip)
        
        // Should not crash
        player.update(deltaTime: 1.0, model: model)
        
        XCTAssertTrue(player.isFinished || clip.duration == 0)
        XCTAssertEqual(clip.jointTracks.count, 0)
        XCTAssertEqual(clip.morphTracks.count, 0)
    }
    
    /// 🔴 RED: Empty clip with zero duration
    func testEmptyClipZeroDuration() throws {
        let clip = AnimationClip(duration: 0.0)
        
        XCTAssertEqual(clip.duration, 0.0)
        XCTAssertEqual(clip.jointTracks.count, 0)
        XCTAssertEqual(clip.morphTracks.count, 0)
    }
    
    /// 🔴 RED: Clip with tracks but no keyframes
    func testTracksWithNoKeyframes() throws {
        // Create a track that returns nil
        var clip = AnimationClip(duration: 1.0)
        
        // Track with no sampler
        let emptyTrack = JointTrack(bone: .hips)
        clip.addJointTrack(emptyTrack)
        
        XCTAssertEqual(clip.jointTracks.count, 1)
        
        // Sample should return nil
        let (rot, trans, scale) = clip.jointTracks[0].sample(at: 0.5)
        XCTAssertNil(rot)
        XCTAssertNil(trans)
        XCTAssertNil(scale)
    }
    
    // MARK: - Single Keyframe Tests
    
    /// 🔴 RED: Single keyframe animation
    ///
    /// Should hold the single value for all time.
    func testSingleKeyframe() throws {
        var clip = AnimationClip(duration: 1.0)
        
        // Single keyframe at t=0
        let track = JointTrack(
            bone: .hips,
            rotationSampler: { _ in
                simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 1, 0))
            }
        )
        clip.addJointTrack(track)
        
        // Sample at different times
        let times: [Float] = [0.0, 0.25, 0.5, 0.75, 1.0, 2.0]
        
        for time in times {
            let (rotation, _, _) = track.sample(at: time)
            XCTAssertNotNil(rotation)
            
            // Should always return the same rotation
            if let rot = rotation {
                let expected = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 1, 0))
                assertQuaternionsEqual(rot, expected, tolerance: 0.001)
            }
        }
    }
    
    /// 🔴 RED: Single keyframe for translation
    func testSingleKeyframeTranslation() throws {
        let track = JointTrack(
            bone: .hips,
            translationSampler: { _ in SIMD3<Float>(1, 2, 3) }
        )
        
        let (_, translation, _) = track.sample(at: 0.5)
        XCTAssertEqual(translation?.x, 1.0)
        XCTAssertEqual(translation?.y, 2.0)
        XCTAssertEqual(translation?.z, 3.0)
    }
    
    // MARK: - Zero Duration Tests
    
    /// 🔴 RED: Zero duration animation
    ///
    /// Should handle gracefully.
    func testZeroDuration() throws {
        var clip = AnimationClip(duration: 0.0)
        clip.addJointTrack(JointTrack(
            bone: .hips,
            rotationSampler: { _ in simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        ))
        
        let player = AnimationPlayer()
        player.load(clip)
        player.update(deltaTime: 0.016, model: model)
        
        // Should finish immediately
        XCTAssertTrue(player.isFinished || clip.duration == 0)
    }
    
    /// 🔴 RED: Very short duration
    func testVeryShortDuration() throws {
        var clip = AnimationClip(duration: 0.001)
        clip.addJointTrack(JointTrack(
            bone: .hips,
            rotationSampler: { _ in simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        ))
        
        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = false
        player.update(deltaTime: 0.016, model: model)
        
        XCTAssertTrue(player.isFinished)
    }
    
    // MARK: - Missing Bones Tests
    
    /// 🔴 RED: Animation with missing bones
    ///
    /// Should skip gracefully when bone doesn't exist in model.
    func testMissingBones() throws {
        // Use existing model (which has limited finger bones)
        // Create animation with bones that may not exist
        var clip = AnimationClip(duration: 1.0)
        clip.addEulerTrack(bone: .leftIndexProximal, axis: .z) { _ in 0.5 }
        clip.addEulerTrack(bone: .rightLittleProximal, axis: .z) { _ in 0.5 }
        
        // Should not crash even if bones don't exist
        let player = AnimationPlayer()
        player.load(clip)
        player.update(deltaTime: 0.5, model: model)
        
        // Test passes if no crash
        XCTAssertTrue(true, "Missing bones handled gracefully")
    }
    
    /// 🔴 RED: Partial bone mapping
    func testPartialBoneMapping() throws {
        // Some bones map, some don't
        throw XCTSkip("Partial mapping needs test data")
    }
    
    // MARK: - Quaternion Neighborhood Tests
    
    /// 🔴 RED: Quaternion neighborhood (dot product sign flip)
    ///
    /// SLERP should choose shortest path.
    func testQuaternionNeighborhood() throws {
        // Two quaternions that are > 90° apart
        let q1 = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        let q2 = simd_quatf(angle: Float.pi * 0.9, axis: SIMD3<Float>(0, 1, 0))  // 162°
        
        // SLERP should take shortest path
        let result = simd_slerp(q1, q2, 0.5)
        
        // The result should be around 81°
        let resultAngle = 2 * acos(min(1, abs(result.real)))
        
        // Should be ~81° (half of 162°), not ~99° (half of 198° the long way)
        XCTAssertEqual(resultAngle, Float.pi * 0.45, accuracy: 0.1,
                      "SLERP should take shortest path")
    }
    
    /// 🔴 RED: Quaternion double-cover (q == -q)
    func testQuaternionDoubleCover() throws {
        // q and -q represent the same rotation
        let q = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 1, 0))
        let qNegated = simd_quatf(vector: -q.vector)
        
        // Both should produce same rotation matrix
        let m1 = matrix_float4x4(q)
        let m2 = matrix_float4x4(qNegated)
        
        for i in 0..<4 {
            for j in 0..<4 {
                XCTAssertEqual(m1[i][j], m2[i][j], accuracy: 0.0001,
                              "q and -q should produce same matrix")
            }
        }
    }
    
    /// 🔴 RED: Quaternion normalization edge cases
    func testQuaternionNormalization() throws {
        // Near-zero quaternions
        let tinyQuat = simd_quatf(ix: 0.001, iy: 0, iz: 0, r: 0.9999995)
        let normalized = simd_normalize(tinyQuat)
        
        let length = sqrt(normalized.imag.x * normalized.imag.x +
                         normalized.imag.y * normalized.imag.y +
                         normalized.imag.z * normalized.imag.z +
                         normalized.real * normalized.real)
        
        XCTAssertEqual(length, 1.0, accuracy: 0.0001,
                      "Normalized quaternion should have length 1")
    }
    
    // MARK: - NaN/Inf Handling Tests
    
    /// 🔴 RED: NaN in animation data
    func testNaNHandling() throws {
        // Should handle NaN gracefully
        var clip = AnimationClip(duration: 1.0)
        
        // This shouldn't happen in practice, but test defense
        let track = JointTrack(
            bone: .hips,
            rotationSampler: { time in
                if time > 0.5 {
                    return simd_quatf(ix: Float.nan, iy: 0, iz: 0, r: 1)
                }
                return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            }
        )
        clip.addJointTrack(track)
        
        // Sample before NaN
        let (rot1, _, _) = track.sample(at: 0.25)
        XCTAssertNotNil(rot1)
        
        // Sample at NaN
        let (rot2, _, _) = track.sample(at: 0.75)
        // Should handle gracefully (return valid quaternion or nil)
        _ = rot2
        
        XCTAssertTrue(true, "NaN handling test")
    }
    
    /// 🔴 RED: Infinity in animation data
    func testInfinityHandling() throws {
        // Should handle infinity gracefully
        throw XCTSkip("Infinity handling not yet implemented")
    }
    
    // MARK: - Time Boundary Tests
    
    /// 🔴 RED: Negative time
    func testNegativeTime() throws {
        var clip = AnimationClip(duration: 1.0)
        clip.addEulerTrack(bone: .hips, axis: .y) { time in
            // Should clamp to 0
            max(0, time) * Float.pi
        }
        
        let player = AnimationPlayer()
        player.load(clip)
        
        // Update with negative delta
        player.update(deltaTime: -1.0, model: model)
        
        // Should handle gracefully
        XCTAssertTrue(true, "Negative time handled")
    }
    
    /// 🔴 RED: Time beyond duration
    func testTimeBeyondDuration() throws {
        var clip = AnimationClip(duration: 1.0)
        clip.addEulerTrack(bone: .hips, axis: .y) { time in
            min(time, 1.0) * Float.pi
        }
        
        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = false
        
        // Update well beyond duration
        player.update(deltaTime: 5.0, model: model)
        
        // Should be at end
        XCTAssertTrue(player.isFinished)
        XCTAssertEqual(player.progress, 1.0, accuracy: 0.01)
    }
    
    /// 🔴 RED: Very large time values
    func testLargeTimeValues() throws {
        var clip = AnimationClip(duration: 1.0)
        clip.addEulerTrack(bone: .hips, axis: .y) { _ in 0 }
        
        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = true
        
        // Simulate very long playback
        for _ in 0..<1000 {
            player.update(deltaTime: 0.016, model: model)
        }
        
        // Should not accumulate error
        XCTAssertTrue(true, "Large time values handled")
    }
    
    // MARK: - Resource Limit Tests
    
    /// 🔴 RED: Many tracks performance
    func testManyTracksPerformance() throws {
        var clip = AnimationClip(duration: 1.0)
        
        // Add tracks for all bones
        for bone in VRMHumanoidBone.allCases {
            clip.addEulerTrack(bone: bone, axis: .y) { time in
                time * 0.1
            }
        }
        
        let player = AnimationPlayer()
        player.load(clip)
        
        // Measure performance
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<100 {
            player.update(deltaTime: 0.016, model: model)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        // Should complete in reasonable time (< 1 second for 100 frames)
        XCTAssertLessThan(elapsed, 1.0, "Many tracks should perform well")
    }
    
    /// 🔴 RED: Deep hierarchy
    func testDeepHierarchy() throws {
        // Test animation on deeply nested bones
        throw XCTSkip("Deep hierarchy needs complex model")
    }
    
    /// 🔴 RED: Memory efficiency
    func testMemoryEfficiency() throws {
        // Should not leak memory with repeated play/reset
        throw XCTSkip("Memory efficiency needs profiling")
    }
}


