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

/// Phase 4: Finger Animation Tests
///
/// 🔴 RED Tests for hand and finger animation:
/// - Left hand finger bones
/// - Right hand finger bones
/// - Finger curl/extend animations
/// - Grip poses
final class FingerAnimationTests: XCTestCase {
    
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
    
    // MARK: - Finger Bone Enum Tests
    
    /// 🔴 RED: All finger bones exist in VRMHumanoidBone
    func testFingerBonesExist() {
        let leftFingers: [VRMHumanoidBone] = [
            .leftThumbMetacarpal, .leftThumbProximal, .leftThumbDistal,
            .leftIndexProximal, .leftIndexIntermediate, .leftIndexDistal,
            .leftMiddleProximal, .leftMiddleIntermediate, .leftMiddleDistal,
            .leftRingProximal, .leftRingIntermediate, .leftRingDistal,
            .leftLittleProximal, .leftLittleIntermediate, .leftLittleDistal,
        ]
        
        let rightFingers: [VRMHumanoidBone] = [
            .rightThumbMetacarpal, .rightThumbProximal, .rightThumbDistal,
            .rightIndexProximal, .rightIndexIntermediate, .rightIndexDistal,
            .rightMiddleProximal, .rightMiddleIntermediate, .rightMiddleDistal,
            .rightRingProximal, .rightRingIntermediate, .rightRingDistal,
            .rightLittleProximal, .rightLittleIntermediate, .rightLittleDistal,
        ]
        
        // All should be valid enum cases
        for bone in leftFingers + rightFingers {
            XCTAssertNotNil(bone, "Finger bone \(bone) should exist")
        }
    }
    
    /// 🔴 RED: Finger bone raw values
    func testFingerBoneRawValues() {
        let testCases: [(bone: VRMHumanoidBone, expectedRaw: String)] = [
            (.leftThumbProximal, "leftThumbProximal"),
            (.leftIndexProximal, "leftIndexProximal"),
            (.leftMiddleProximal, "leftMiddleProximal"),
            (.leftRingProximal, "leftRingProximal"),
            (.leftLittleProximal, "leftLittleProximal"),
            (.rightThumbProximal, "rightThumbProximal"),
            (.rightIndexProximal, "rightIndexProximal"),
            (.rightMiddleProximal, "rightMiddleProximal"),
            (.rightRingProximal, "rightRingProximal"),
            (.rightLittleProximal, "rightLittleProximal"),
        ]
        
        for (bone, expected) in testCases {
            XCTAssertEqual(bone.rawValue, expected,
                          "Bone raw value should match expected")
        }
    }
    
    // MARK: - Left Hand Finger Tests
    
    /// 🔴 RED: Left hand finger animation
    func testLeftHandFingerAnimation() throws {
        var clip = AnimationClip(duration: 1.0)
        
        // Curl all left fingers
        let leftFingers: [VRMHumanoidBone] = [
            .leftIndexProximal, .leftIndexIntermediate, .leftIndexDistal,
            .leftMiddleProximal, .leftMiddleIntermediate, .leftMiddleDistal,
            .leftRingProximal, .leftRingIntermediate, .leftRingDistal,
            .leftLittleProximal, .leftLittleIntermediate, .leftLittleDistal,
        ]
        
        for finger in leftFingers {
            clip.addEulerTrack(bone: finger, axis: .z) { time in
                // Curl inward (negative Z rotation)
                -time * Float.pi / 2
            }
        }
        
        // Thumb has different motion
        clip.addEulerTrack(bone: .leftThumbProximal, axis: .y) { time in
            time * Float.pi / 4
        }
        
        XCTAssertEqual(clip.jointTracks.count, 13)  // 12 fingers + thumb
    }
    
    /// 🔴 RED: Left hand grip pose
    func testLeftHandGripPose() throws {
        var clip = AnimationClip(duration: 0.5)
        
        // Full grip - all fingers curled
        let curlAmount = Float.pi / 2  // 90°
        
        // Index
        clip.addEulerTrack(bone: .leftIndexProximal, axis: .z) { _ in -curlAmount }
        clip.addEulerTrack(bone: .leftIndexIntermediate, axis: .z) { _ in -curlAmount }
        clip.addEulerTrack(bone: .leftIndexDistal, axis: .z) { _ in -curlAmount * 0.5 }
        
        // Middle
        clip.addEulerTrack(bone: .leftMiddleProximal, axis: .z) { _ in -curlAmount }
        clip.addEulerTrack(bone: .leftMiddleIntermediate, axis: .z) { _ in -curlAmount }
        clip.addEulerTrack(bone: .leftMiddleDistal, axis: .z) { _ in -curlAmount * 0.5 }
        
        // Ring
        clip.addEulerTrack(bone: .leftRingProximal, axis: .z) { _ in -curlAmount }
        clip.addEulerTrack(bone: .leftRingIntermediate, axis: .z) { _ in -curlAmount }
        clip.addEulerTrack(bone: .leftRingDistal, axis: .z) { _ in -curlAmount * 0.5 }
        
        // Little
        clip.addEulerTrack(bone: .leftLittleProximal, axis: .z) { _ in -curlAmount }
        clip.addEulerTrack(bone: .leftLittleIntermediate, axis: .z) { _ in -curlAmount }
        clip.addEulerTrack(bone: .leftLittleDistal, axis: .z) { _ in -curlAmount * 0.5 }
        
        // Thumb opposes
        clip.addEulerTrack(bone: .leftThumbProximal, axis: .y) { _ in Float.pi / 4 }
        clip.addEulerTrack(bone: .leftThumbProximal, axis: .z) { _ in -Float.pi / 6 }
        
        XCTAssertGreaterThanOrEqual(clip.jointTracks.count, 10)
    }
    
    // MARK: - Right Hand Finger Tests
    
    /// 🔴 RED: Right hand finger animation
    func testRightHandFingerAnimation() throws {
        var clip = AnimationClip(duration: 1.0)
        
        // Waving motion for right hand
        let rightFingers: [VRMHumanoidBone] = [
            .rightIndexProximal, .rightMiddleProximal,
            .rightRingProximal, .rightLittleProximal,
        ]
        
        for finger in rightFingers {
            clip.addEulerTrack(bone: finger, axis: .z) { time in
                // Wave (oscillate)
                sin(time * Float.pi * 4) * 0.2
            }
        }
        
        XCTAssertGreaterThanOrEqual(clip.jointTracks.count, 4)
    }
    
    /// 🔴 RED: Right hand grip pose
    func testRightHandGripPose() throws {
        var clip = AnimationClip(duration: 0.5)
        
        // Full grip for right hand (mirror of left)
        let curlAmount = Float.pi / 2
        
        // All fingers except thumb
        let fingerBones: [VRMHumanoidBone] = [
            .rightIndexProximal, .rightIndexIntermediate, .rightIndexDistal,
            .rightMiddleProximal, .rightMiddleIntermediate, .rightMiddleDistal,
            .rightRingProximal, .rightRingIntermediate, .rightRingDistal,
            .rightLittleProximal, .rightLittleIntermediate, .rightLittleDistal,
        ]
        
        for bone in fingerBones {
            clip.addEulerTrack(bone: bone, axis: .z) { _ in curlAmount }
        }
        
        // Thumb (opposite direction from left hand)
        clip.addEulerTrack(bone: .rightThumbProximal, axis: .y) { _ in -Float.pi / 4 }
        
        XCTAssertGreaterThanOrEqual(clip.jointTracks.count, 10)
    }
    
    /// 🔴 RED: Right hand pointing gesture
    func testRightHandPointing() throws {
        var clip = AnimationClip(duration: 0.5)
        
        // Index extended, others curled
        // Index
        clip.addEulerTrack(bone: .rightIndexProximal, axis: .z) { _ in 0 }
        clip.addEulerTrack(bone: .rightIndexIntermediate, axis: .z) { _ in 0 }
        
        // Others curled
        let curlAmount = Float.pi / 2
        let otherFingers: [VRMHumanoidBone] = [
            .rightMiddleProximal, .rightMiddleIntermediate, .rightMiddleDistal,
            .rightRingProximal, .rightRingIntermediate, .rightRingDistal,
            .rightLittleProximal, .rightLittleIntermediate, .rightLittleDistal,
        ]
        
        for bone in otherFingers {
            clip.addEulerTrack(bone: bone, axis: .z) { _ in curlAmount }
        }
        
        XCTAssertEqual(clip.jointTracks.count, 11)
    }
    
    // MARK: - Finger Animation from VRMA
    
    /// 🔴 RED: Finger animation from VRMA file
    func testFingerAnimationFromVRMA() async throws {
        let modelPath = "\(projectRoot)/AliciaSolid.vrm"
        let vrmaPath = "\(projectRoot)/VRMA_fingers.vrma"
        
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "VRM model not found")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA with finger animation not found")
        
        let modelURL = URL(fileURLWithPath: modelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)
        
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
        
        // Should have finger tracks
        let fingerBones: [VRMHumanoidBone] = [
            .leftThumbProximal, .leftIndexProximal, .leftMiddleProximal,
            .rightThumbProximal, .rightIndexProximal, .rightMiddleProximal,
        ]
        
        var fingerTrackCount = 0
        for bone in fingerBones {
            if clip.jointTracks.contains(where: { $0.bone == bone }) {
                fingerTrackCount += 1
            }
        }
        
        XCTAssertGreaterThan(fingerTrackCount, 0,
                            "Should have at least some finger tracks")
    }
    
    /// 🔴 RED: All fingers animated
    func testAllFingersAnimated() async throws {
        let vrmaPath = "\(projectRoot)/VRMA_fingers.vrma"
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA with finger animation not found")
        
        // Load and verify all finger bones are animated
        throw XCTSkip("All fingers - needs test data")
    }
    
    // MARK: - Finger Coordination Tests
    
    /// 🔴 RED: Finger coordination (piano playing)
    func testFingerCoordination() throws {
        // Sequential finger animation (like playing piano)
        var clip = AnimationClip(duration: 2.0)
        
        let fingers: [(bone: VRMHumanoidBone, delay: Float)] = [
            (.rightLittleProximal, 0.0),
            (.rightRingProximal, 0.2),
            (.rightMiddleProximal, 0.4),
            (.rightIndexProximal, 0.6),
            (.rightThumbProximal, 0.8),
        ]
        
        for (bone, delay) in fingers {
            clip.addEulerTrack(bone: bone, axis: .z) { time in
                // Press down at specific time
                let pressTime = 0.1
                if time >= delay && time <= delay + Float(pressTime) {
                    return Float.pi / 4  // Press
                }
                return 0  // Release
            }
        }
        
        XCTAssertEqual(clip.jointTracks.count, 5)
    }
    
    /// 🔴 RED: Symmetric finger animation
    func testSymmetricFingerAnimation() throws {
        // Both hands doing same gesture
        var clip = AnimationClip(duration: 1.0)
        
        let leftFingers: [VRMHumanoidBone] = [
            .leftIndexProximal, .leftMiddleProximal,
        ]
        let rightFingers: [VRMHumanoidBone] = [
            .rightIndexProximal, .rightMiddleProximal,
        ]
        
        // Mirror motion
        for (leftBone, rightBone) in zip(leftFingers, rightFingers) {
            clip.addEulerTrack(bone: leftBone, axis: .z) { time in
                -sin(time * Float.pi * 2) * 0.3
            }
            clip.addEulerTrack(bone: rightBone, axis: .z) { time in
                sin(time * Float.pi * 2) * 0.3
            }
        }
        
        XCTAssertEqual(clip.jointTracks.count, 4)
    }
    
    // MARK: - Finger Bone Hierarchy
    
    /// 🔴 RED: Finger bone hierarchy preserved
    func testFingerBoneHierarchy() async throws {
        // Distal should follow intermediate, which follows proximal
        let vrmDocument = try VRMBuilder()
            .setSkeleton(.defaultHumanoid)
            .build()
        
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("vrm")
        
        try vrmDocument.serialize(to: tempURL)
        let model = try await VRMModel.load(from: tempURL, device: device)
        try? FileManager.default.removeItem(at: tempURL)
        
        // Check finger bone hierarchy
        guard let humanoid = model.humanoid else {
            XCTFail("Model should have humanoid")
            return
        }
        
        // If finger bones exist, verify hierarchy
        if let indexProximal = humanoid.getBoneNode(.leftIndexProximal),
           let indexIntermediate = humanoid.getBoneNode(.leftIndexIntermediate) {
            _ = model.nodes[indexProximal]
            let intermediateNode = model.nodes[indexIntermediate]
            
            XCTAssertEqual(intermediateNode.parent?.index, indexProximal,
                          "Intermediate should be child of proximal")
        }
    }
    
    /// 🔴 RED: Finger curl propagation
    func testFingerCurlPropagation() throws {
        // When proximal curls, distal should follow
        var clip = AnimationClip(duration: 1.0)
        
        // Curl chain
        clip.addEulerTrack(bone: .leftIndexProximal, axis: .z) { time in
            -time * Float.pi / 3
        }
        clip.addEulerTrack(bone: .leftIndexIntermediate, axis: .z) { time in
            -time * Float.pi / 2
        }
        clip.addEulerTrack(bone: .leftIndexDistal, axis: .z) { time in
            -time * Float.pi / 4
        }
        
        XCTAssertEqual(clip.jointTracks.count, 3)
    }
    
    // MARK: - Integration Tests
    
    /// 🔴 RED: Finger + hand animation combined
    func testFingerAndHandCombined() throws {
        // Hand position + finger pose
        var clip = AnimationClip(duration: 1.0)
        
        // Hand wave
        clip.addEulerTrack(bone: .rightHand, axis: .z) { time in
            sin(time * Float.pi * 4) * 0.5
        }
        
        // Finger curl
        clip.addEulerTrack(bone: .rightIndexProximal, axis: .z) { _ in Float.pi / 4 }
        clip.addEulerTrack(bone: .rightMiddleProximal, axis: .z) { _ in Float.pi / 4 }
        
        XCTAssertEqual(clip.jointTracks.count, 3)
    }
    
    /// 🔴 RED: Finger animation performance
    func testFingerAnimationPerformance() async throws {
        // Many finger tracks should perform well
        var clip = AnimationClip(duration: 1.0)
        
        // Add all finger bones
        let allFingers: [VRMHumanoidBone] = [
            .leftThumbProximal, .leftThumbDistal,
            .leftIndexProximal, .leftIndexIntermediate, .leftIndexDistal,
            .leftMiddleProximal, .leftMiddleIntermediate, .leftMiddleDistal,
            .leftRingProximal, .leftRingIntermediate, .leftRingDistal,
            .leftLittleProximal, .leftLittleIntermediate, .leftLittleDistal,
            .rightThumbProximal, .rightThumbDistal,
            .rightIndexProximal, .rightIndexIntermediate, .rightIndexDistal,
            .rightMiddleProximal, .rightMiddleIntermediate, .rightMiddleDistal,
            .rightRingProximal, .rightRingIntermediate, .rightRingDistal,
            .rightLittleProximal, .rightLittleIntermediate, .rightLittleDistal,
        ]
        
        for finger in allFingers {
            clip.addEulerTrack(bone: finger, axis: .z) { time in
                sin(time * Float.pi * 2 + Float(allFingers.firstIndex(of: finger) ?? 0)) * 0.2
            }
        }
        
        // Create test model
        let vrmDocument = try VRMBuilder()
            .setSkeleton(.defaultHumanoid)
            .build()
        
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("vrm")
        
        try vrmDocument.serialize(to: tempURL)
        let testModel = try await VRMModel.load(from: tempURL, device: device!)
        try? FileManager.default.removeItem(at: tempURL)
        
        let player = AnimationPlayer()
        player.load(clip)
        
        // Measure performance
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<60 {  // 60 frames
            player.update(deltaTime: Float(1.0/60.0), model: testModel)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        // Should run at 60fps (< 1 second for 60 frames)
        XCTAssertLessThan(elapsed, 1.0, "Finger animation should perform well")
    }
}
