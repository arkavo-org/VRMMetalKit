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

// MARK: - Phase 1: RED Tests - VRMA Path Coverage
// These tests verify that all animation paths defined in the VRMA spec
// are correctly sampled and produce valid values.

/// VRMA Path Coverage Tests
///
/// 🔴 RED Phase Tests: Comprehensive coverage of all VRMA animation paths
///
/// VRMA Specification Paths:
/// - "rotation" - Joint rotation (quaternion)
/// - "translation" - Joint translation (vector3) - Hips = root motion
/// - "scale" - Joint scale (vector3)
/// - "weights" - Morph target weights
final class VRMAPathCoverageTests: XCTestCase {
    
    // MARK: - Test Setup
    
    private var device: MTLDevice!
    private var vrm0Model: VRMModel!
    
    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
        
        // Build a VRM 0.0 test model using VRMBuilder
        let vrmDocument = try VRMBuilder()
            .setSkeleton(.defaultHumanoid)
            .applyMorphs(["happy": 1.0, "sad": 1.0, "angry": 1.0])
            .addExpressions([.happy, .sad, .angry])
            .build()
        
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("vrm")
        
        try vrmDocument.serialize(to: tempURL)
        self.vrm0Model = try await VRMModel.load(from: tempURL, device: device)
        try? FileManager.default.removeItem(at: tempURL)
    }
    
    override func tearDown() {
        vrm0Model = nil
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
    
    // MARK: - RED Test: Rotation Path Sampling
    
    /// 🔴 RED: Test "rotation" path produces valid quaternions
    ///
    /// The rotation path should:
    /// - Produce normalized quaternions (length = 1.0)
    /// - Handle quaternion double-cover (q == -q)
    /// - Support all interpolation types (LINEAR, STEP, CUBICSPLINE)
    func testRotationPathSampling() async throws {
        // Arrange: Load real VRMA file with rotation data
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA file not found")
        
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: vrm0Model)
        
        // Act & Assert: Sample rotation at multiple time points
        let sampleTimes: [Float] = [0, 0.25, 0.5, 0.75, 1.0].map { $0 * clip.duration }
        
        for track in clip.jointTracks {
            for time in sampleTimes {
                let (rotation, _, _) = track.sample(at: time)
                
                // Assert: Rotation should be valid quaternion
                XCTAssertNotNil(rotation, "Rotation should be sampled at t=\(time)")
                
                guard let rot = rotation else { continue }
                
                // Assert: Quaternion should be normalized
                let length = sqrt(rot.imag.x * rot.imag.x +
                                 rot.imag.y * rot.imag.y +
                                 rot.imag.z * rot.imag.z +
                                 rot.real * rot.real)
                
                XCTAssertEqual(length, 1.0, accuracy: 0.01,
                    "Quaternion for \(track.bone) at t=\(time) should be normalized")
                
                // Assert: No NaN or Inf values
                XCTAssertFalse(rot.imag.x.isNaN, "Rotation X should not be NaN")
                XCTAssertFalse(rot.imag.y.isNaN, "Rotation Y should not be NaN")
                XCTAssertFalse(rot.imag.z.isNaN, "Rotation Z should not be NaN")
                XCTAssertFalse(rot.real.isNaN, "Rotation W should not be NaN")
                XCTAssertFalse(rot.imag.x.isInfinite, "Rotation X should not be infinite")
                XCTAssertFalse(rot.imag.y.isInfinite, "Rotation Y should not be infinite")
                XCTAssertFalse(rot.imag.z.isInfinite, "Rotation Z should not be infinite")
                XCTAssertFalse(rot.real.isInfinite, "Rotation W should not be infinite")
            }
        }
    }
    
    /// 🔴 RED: Test rotation interpolation between keyframes
    ///
    /// For LINEAR interpolation, rotation should smoothly transition between keyframes.
    /// The shortest path should be chosen (quaternion neighborhood).
    func testRotationPathInterpolation() async throws {
        // Arrange: Create animation with known keyframes
        var clip = AnimationClip(duration: 1.0)
        
        // Add rotation track with 0° at t=0 and 180° at t=1
        let track = JointTrack(
            bone: .hips,
            rotationSampler: { time in
                let angle = time * Float.pi  // 0 to 180 degrees
                return simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
            }
        )
        clip.addJointTrack(track)
        
        // Act & Assert: Sample at midpoint
        let (midRotation, _, _) = track.sample(at: 0.5)
        
        XCTAssertNotNil(midRotation)
        guard let midRot = midRotation else { return }
        
        // At t=0.5, should be approximately 90 degrees around Y
        let midAngle = 2 * acos(min(1, abs(midRot.real)))
        XCTAssertEqual(midAngle, Float.pi / 2, accuracy: 0.01,
                      "Midpoint rotation should be 90°")
        
        // Rotation axis should be Y
        let sinHalfAngle = sin(midAngle / 2)
        if abs(sinHalfAngle) > 0.001 {
            let axis = midRot.imag / sinHalfAngle
            XCTAssertEqual(axis.x, 0, accuracy: 0.01, "Rotation axis should be Y")
            XCTAssertEqual(axis.y, 1, accuracy: 0.01, "Rotation axis should be Y")
            XCTAssertEqual(axis.z, 0, accuracy: 0.01, "Rotation axis should be Y")
        }
    }
    
    // MARK: - RED Test: Translation Path Sampling
    
    /// 🔴 RED: Test "translation" path produces valid vectors
    ///
    /// Translation path specifics:
    /// - Hips translation = root motion (character movement)
    /// - Other bones = local translation (rarely used)
    /// - Values are in model space units (usually meters)
    func testTranslationPathSampling() async throws {
        // Arrange: Load VRMA with translation data
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA file not found")
        
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: vrm0Model)
        
        // Find hips track (most likely to have translation for root motion)
        guard let hipsTrack = clip.jointTracks.first(where: { $0.bone == .hips }) else {
            throw XCTSkip("VRMA doesn't have hips track with translation")
        }
        
        // Act: Sample translation at multiple times
        let sampleTimes: [Float] = [0, 0.25, 0.5, 0.75, 1.0].map { $0 * clip.duration }
        var translations: [SIMD3<Float>] = []
        
        for time in sampleTimes {
            let (_, translation, _) = hipsTrack.sample(at: time)
            XCTAssertNotNil(translation, "Translation should be sampled at t=\(time)")
            if let trans = translation {
                translations.append(trans)
                
                // Assert: No NaN or Inf
                XCTAssertFalse(trans.x.isNaN, "Translation X should not be NaN")
                XCTAssertFalse(trans.y.isNaN, "Translation Y should not be NaN")
                XCTAssertFalse(trans.z.isNaN, "Translation Z should not be NaN")
                XCTAssertFalse(trans.x.isInfinite, "Translation X should not be infinite")
                XCTAssertFalse(trans.y.isInfinite, "Translation Y should not be infinite")
                XCTAssertFalse(trans.z.isInfinite, "Translation Z should not be infinite")
            }
        }
        
        // Assert: Translation values are in reasonable range for character animation
        // Typical human movement is within ±10 meters
        for trans in translations {
            XCTAssertLessThan(abs(trans.x), 100, "Translation X seems unreasonably large")
            XCTAssertLessThan(abs(trans.y), 100, "Translation Y seems unreasonably large")
            XCTAssertLessThan(abs(trans.z), 100, "Translation Z seems unreasonably large")
        }
    }
    
    /// 🔴 RED: Test hips translation = root motion
    ///
    /// Hips translation in VRMA represents the character's movement in space.
    /// This is called "root motion" and should be applied to the character's transform.
    func testHipsTranslationIsRootMotion() async throws {
        // Arrange
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA file not found")
        
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: vrm0Model)
        
        guard let hipsTrack = clip.jointTracks.first(where: { $0.bone == .hips }) else {
            throw XCTSkip("VRMA doesn't have hips track")
        }
        
        // Act: Apply animation with root motion enabled
        let player = AnimationPlayer()
        player.load(clip)
        player.applyRootMotion = true
        player.update(deltaTime: 0, model: vrm0Model)
        
        // Get initial hips world position
        guard let hipsIndex = vrm0Model.humanoid?.getBoneNode(.hips) else {
            XCTFail("Model should have hips bone")
            return
        }
        
        let hipsNode = vrm0Model.nodes[hipsIndex]
        let initialPosition = SIMD3<Float>(hipsNode.worldMatrix[3][0],
                                           hipsNode.worldMatrix[3][1],
                                           hipsNode.worldMatrix[3][2])
        
        // Advance to end of animation
        player.update(deltaTime: clip.duration, model: vrm0Model)
        
        // Update world transforms
        for node in vrm0Model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }
        
        let finalPosition = SIMD3<Float>(hipsNode.worldMatrix[3][0],
                                         hipsNode.worldMatrix[3][1],
                                         hipsNode.worldMatrix[3][2])
        
        // Assert: Position changed due to root motion
        let movement = finalPosition - initialPosition
        let distance = simd_length(movement)
        
        // Sample translation from track to verify it matches
        let (_, translationAtEnd, _) = hipsTrack.sample(at: clip.duration)
        
        if let trans = translationAtEnd {
            // Root motion distance should approximately match translation magnitude
            // (accounting for coordinate conversion for VRM 0.0)
            let expectedDistance = simd_length(trans)
            
            // 🔴 RED: This will fail if root motion extraction isn't properly implemented
            XCTAssertEqual(distance, expectedDistance, accuracy: 0.1,
                "Root motion distance (\(distance)) should match translation magnitude (\(expectedDistance))")
        }
    }
    
    // MARK: - RED Test: Scale Path Sampling
    
    /// 🔴 RED: Test "scale" path produces valid vectors
    ///
    /// Scale path is less common but used for:
    /// - Cartoon-style squash and stretch
    /// - Breathing animations (chest scale)
    /// - Proportional adjustments
    func testScalePathSampling() async throws {
        // Arrange: Create animation with scale track
        var clip = AnimationClip(duration: 1.0)
        
        let track = JointTrack(
            bone: .chest,
            scaleSampler: { time in
                // Breathing animation: scale Y from 1.0 to 1.1
                let scaleY = 1.0 + 0.1 * sin(time * Float.pi * 2)
                return SIMD3<Float>(1.0, scaleY, 1.0)
            }
        )
        clip.addJointTrack(track)
        
        // Act & Assert: Sample at multiple times
        let sampleTimes: [Float] = [0, 0.25, 0.5, 0.75, 1.0]
        
        for time in sampleTimes {
            let (_, _, scale) = track.sample(at: time * clip.duration)
            
            XCTAssertNotNil(scale, "Scale should be sampled at t=\(time)")
            guard let s = scale else { continue }
            
            // Assert: Scale values should be positive
            XCTAssertGreaterThan(s.x, 0, "Scale X should be positive")
            XCTAssertGreaterThan(s.y, 0, "Scale Y should be positive")
            XCTAssertGreaterThan(s.z, 0, "Scale Z should be positive")
            
            // Assert: No NaN or Inf
            XCTAssertFalse(s.x.isNaN, "Scale X should not be NaN")
            XCTAssertFalse(s.y.isNaN, "Scale Y should not be NaN")
            XCTAssertFalse(s.z.isNaN, "Scale Z should not be NaN")
            
            // Assert: Scale should be in reasonable range
            XCTAssertLessThan(s.x, 10, "Scale X seems unreasonably large")
            XCTAssertLessThan(s.y, 10, "Scale Y seems unreasonably large")
            XCTAssertLessThan(s.z, 10, "Scale Z seems unreasonably large")
        }
    }
    
    /// 🔴 RED: Test scale path from VRMA file
    func testScalePathFromVRMA() async throws {
        // Try to load a VRMA that might have scale animations
        // Most VRMA files don't use scale, so this test may be skipped
        let vrmaPath = "\(projectRoot)/VRMA_scale.vrma"
        
        guard FileManager.default.fileExists(atPath: vrmaPath) else {
            throw XCTSkip("VRMA with scale animation not found")
        }
        
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: vrm0Model)
        
        // Assert: At least one track should have scale data
        var hasScaleTrack = false
        for track in clip.jointTracks {
            let (_, _, scale) = track.sample(at: 0)
            if scale != nil {
                hasScaleTrack = true
                break
            }
        }
        
        // 🔴 RED: This will fail if scale path parsing isn't implemented
        XCTAssertTrue(hasScaleTrack, "VRMA should have at least one scale track")
    }
    
    // MARK: - RED Test: Morph Weight Path Sampling
    
    /// 🔴 RED: Test morph target weight animation
    ///
    /// Morph weights (formerly blend shapes) animate facial expressions,
    /// body morphs, and other vertex-based deformations.
    func testMorphWeightPathSampling() async throws {
        // Arrange: Create animation with morph tracks
        var clip = AnimationClip(duration: 2.0)
        
        // Add morph tracks for expressions
        clip.addMorphTrack(key: "happy", sample: { time in
            // Happy expression: fade in then out
            return sin(time * Float.pi / 2)  // 0 -> 1 -> 0
        })
        
        clip.addMorphTrack(key: "blink", sample: { time in
            // Blink: quick on/off
            if time > 0.4 && time < 0.5 {
                return 1.0
            }
            return 0.0
        })
        
        // Act & Assert: Sample morph weights
        let testCases: [(time: Float, morph: String, expectedRange: ClosedRange<Float>)] = [
            (0.0, "happy", 0.0...0.1),
            (1.0, "happy", 0.9...1.0),
            (2.0, "happy", 0.0...0.1),
            (0.45, "blink", 0.9...1.0),
            (0.0, "blink", 0.0...0.1),
        ]
        
        for (time, morphKey, expectedRange) in testCases {
            guard let track = clip.morphTracks.first(where: { $0.key == morphKey }) else {
                XCTFail("Morph track '\(morphKey)' not found")
                continue
            }
            
            let weight = track.sample(at: time)
            
            // Assert: Weight should be in valid range [0, 1]
            XCTAssertGreaterThanOrEqual(weight, 0, "Morph weight should be >= 0")
            XCTAssertLessThanOrEqual(weight, 1, "Morph weight should be <= 1")
            
            // Assert: Weight should match expected range for this test case
            XCTAssertTrue(expectedRange.contains(weight),
                "Morph '\(morphKey)' at t=\(time) should be in range \(expectedRange), got \(weight)")
        }
    }
    
    /// 🔴 RED: Test morph weight interpolation
    ///
    /// Morph weights should smoothly interpolate between keyframes (LINEAR by default).
    func testMorphWeightInterpolation() {
        var clip = AnimationClip(duration: 1.0)
        
        // Create morph track with explicit keyframes
        clip.addMorphTrack(key: "test", sample: { time in
            // Linear interpolation from 0 to 1
            return time
        })
        
        guard let track = clip.morphTracks.first else {
            XCTFail("Morph track should exist")
            return
        }
        
        // Test interpolation at multiple points
        let testPoints: [(time: Float, expected: Float)] = [
            (0.0, 0.0),
            (0.25, 0.25),
            (0.5, 0.5),
            (0.75, 0.75),
            (1.0, 1.0),
        ]
        
        for (time, expected) in testPoints {
            let weight = track.sample(at: time)
            XCTAssertEqual(weight, expected, accuracy: 0.001,
                "Morph weight at t=\(time) should be \(expected), got \(weight)")
        }
    }
    
    /// 🔴 RED: Test morph weights from VRMA file
    func testMorphWeightsFromVRMA() async throws {
        let vrmaPath = "\(projectRoot)/VRMA_expressions.vrma"
        
        guard FileManager.default.fileExists(atPath: vrmaPath) else {
            throw XCTSkip("VRMA with expressions not found")
        }
        
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: vrm0Model)
        
        // Assert: VRMA should have expression tracks
        // 🔴 RED: This will fail if expression track parsing isn't implemented
        XCTAssertGreaterThan(clip.morphTracks.count, 0,
                            "VRMA with expressions should have morph tracks")
        
        // Verify each morph weight is valid
        for track in clip.morphTracks {
            for t in stride(from: Float(0), through: clip.duration, by: 0.1) {
                let weight = track.sample(at: t)
                
                XCTAssertGreaterThanOrEqual(weight, 0,
                    "Morph '\(track.key)' weight at t=\(t) should be >= 0")
                XCTAssertLessThanOrEqual(weight, 1,
                    "Morph '\(track.key)' weight at t=\(t) should be <= 1")
            }
        }
    }
    
    // MARK: - RED Test: Combined Path Sampling
    
    /// 🔴 RED: Test all paths sampled together (rotation + translation + scale)
    ///
    /// Real VRMA files often have multiple paths for the same joint.
    /// This test verifies they all work together correctly.
    func testCombinedPathSampling() {
        // Arrange: Create animation with all three transform paths
        var clip = AnimationClip(duration: 1.0)
        
        let track = JointTrack(
            bone: .hips,
            rotationSampler: { time in
                let angle = time * Float.pi / 4
                return simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
            },
            translationSampler: { time in
                return SIMD3<Float>(time, 0, time * 0.5)
            },
            scaleSampler: { time in
                let s = 1.0 + 0.1 * sin(time * Float.pi)
                return SIMD3<Float>(s, s, s)
            }
        )
        clip.addJointTrack(track)
        
        // Act: Sample all paths at midpoint
        let (rotation, translation, scale) = track.sample(at: 0.5)
        
        // Assert: All paths return valid values
        XCTAssertNotNil(rotation, "Rotation should be sampled")
        XCTAssertNotNil(translation, "Translation should be sampled")
        XCTAssertNotNil(scale, "Scale should be sampled")
        
        // Assert: Values are as expected
        if let rot = rotation {
            let angle = 2 * acos(min(1, abs(rot.real)))
            XCTAssertEqual(angle, Float.pi / 8, accuracy: 0.01,
                          "Rotation at t=0.5 should be ~22.5°")
        }
        
        if let trans = translation {
            XCTAssertEqual(trans.x, 0.5, accuracy: 0.001, "Translation X should be 0.5")
            XCTAssertEqual(trans.y, 0.0, accuracy: 0.001, "Translation Y should be 0.0")
            XCTAssertEqual(trans.z, 0.25, accuracy: 0.001, "Translation Z should be 0.25")
        }
        
        if let s = scale {
            let expectedScale = 1.0 + 0.1 * sin(0.5 * Float.pi)
            XCTAssertEqual(s.x, expectedScale, accuracy: 0.001, "Scale should match expected")
            XCTAssertEqual(s.y, expectedScale, accuracy: 0.001, "Scale should match expected")
            XCTAssertEqual(s.z, expectedScale, accuracy: 0.001, "Scale should match expected")
        }
    }
    
    // MARK: - RED Test: Path Type Validation
    
    /// 🔴 RED: Test that incorrect path types are rejected or handled gracefully
    ///
    /// The VRMA spec defines specific types for each path:
    /// - rotation: VEC4 (quaternion)
    /// - translation: VEC3
    /// - scale: VEC3
    /// - weights: SCALAR (or array of scalars)
    func testPathTypeValidation() {
        // This test verifies that the loader validates path types
        // and produces meaningful errors for invalid data
        
        // For now, we just verify that valid paths work correctly
        // Invalid path handling would be tested with corrupted/malformed data
        
        var clip = AnimationClip(duration: 1.0)
        
        // Valid: rotation as quaternion
        let validRotationTrack = JointTrack(
            bone: .head,
            rotationSampler: { _ in simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)) }
        )
        clip.addJointTrack(validRotationTrack)
        
        let (rot, _, _) = validRotationTrack.sample(at: 0)
        XCTAssertNotNil(rot, "Valid rotation track should sample successfully")
        
        // TODO: Add tests for invalid path types once error handling is implemented
    }
}
