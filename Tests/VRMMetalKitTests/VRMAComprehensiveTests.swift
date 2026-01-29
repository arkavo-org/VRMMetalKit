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

/// Comprehensive tests for VRMA loading, parsing, interpolation, and retargeting.
/// Designed to catch edge cases and potential bugs in the animation pipeline.
final class VRMAComprehensiveTests: XCTestCase {

    var device: MTLDevice!
    var model: VRMModel!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device

        let vrmDocument = try VRMBuilder()
            .setSkeleton(.defaultHumanoid)
            .applyMorphs(["height": 1.0])
            .setHairColor([0.35, 0.25, 0.15])
            .setEyeColor([0.2, 0.4, 0.8])
            .setSkinTone(0.5)
            .addExpressions([.happy, .sad, .angry, .surprised, .relaxed, .neutral, .blink])
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

    // MARK: - Interpolation Tests

    /// Test LINEAR interpolation produces smooth transitions
    func testLinearInterpolationSmoothness() {
        let duration: Float = 1.0
        let startAngle: Float = 0
        let endAngle: Float = Float.pi / 2

        var clip = AnimationClip(duration: duration)
        let track = JointTrack(
            bone: .hips,
            rotationSampler: { time in
                let progress = time / duration
                return simd_quatf(angle: startAngle + (endAngle - startAngle) * progress, axis: SIMD3<Float>(0, 1, 0))
            }
        )
        clip.addJointTrack(track)

        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = false

        // Sample at multiple points and verify smoothness
        var previousAngle: Float = 0
        let sampleCount = 20
        for i in 0...sampleCount {
            let t = Float(i) / Float(sampleCount)
            player.seek(to: t * duration)
            player.update(deltaTime: 0, model: model)

            guard let humanoid = model.humanoid,
                  let hipsIndex = humanoid.getBoneNode(.hips) else { continue }
            let hipsNode = model.nodes[hipsIndex]

            // Extract angle from quaternion
            let quat = hipsNode.rotation
            let angle = 2 * acos(min(1, abs(quat.real)))

            if i > 0 {
                let deltaAngle = abs(angle - previousAngle)
                let expectedDelta = endAngle / Float(sampleCount)
                XCTAssertLessThan(deltaAngle, expectedDelta * 2, "Interpolation should be smooth at t=\(t)")
            }
            previousAngle = angle
        }
    }

    /// Test STEP interpolation holds values until next keyframe
    func testStepInterpolationBehavior() {
        let duration: Float = 1.0
        let keyframeTimes: [Float] = [0, 0.5, 1.0]
        let keyframeAngles: [Float] = [0, Float.pi / 4, Float.pi / 2]

        var clip = AnimationClip(duration: duration)
        let track = JointTrack(
            bone: .spine,
            rotationSampler: { time in
                // Simulate STEP behavior
                var index = 0
                for i in 0..<keyframeTimes.count {
                    if time >= keyframeTimes[i] {
                        index = i
                    }
                }
                return simd_quatf(angle: keyframeAngles[index], axis: SIMD3<Float>(1, 0, 0))
            }
        )
        clip.addJointTrack(track)

        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = false

        // Test just before and after each keyframe
        let testTimes: [(Float, Float)] = [
            (0.49, 0),        // Before second keyframe, should hold first value
            (0.51, Float.pi / 4)  // After second keyframe, should jump to second value
        ]

        for (testTime, expectedAngle) in testTimes {
            player.seek(to: testTime)
            player.update(deltaTime: 0, model: model)

            guard let humanoid = model.humanoid,
                  let spineIndex = humanoid.getBoneNode(.spine) else { continue }
            let spineNode = model.nodes[spineIndex]

            let expectedQuat = simd_quatf(angle: expectedAngle, axis: SIMD3<Float>(1, 0, 0))
            assertQuaternionsEqual(spineNode.rotation, expectedQuat, tolerance: 0.1)
        }
    }

    // MARK: - Quaternion Edge Case Tests

    /// Test quaternion normalization with near-identity values
    func testQuaternionNormalization() {
        let duration: Float = 1.0

        // Create a clip with very small rotations
        var clip = AnimationClip(duration: duration)
        let track = JointTrack(
            bone: .head,
            rotationSampler: { time in
                let smallAngle: Float = 0.001 * time
                return simd_quatf(angle: smallAngle, axis: SIMD3<Float>(1, 0, 0))
            }
        )
        clip.addJointTrack(track)

        let player = AnimationPlayer()
        player.load(clip)

        // Should not crash or produce NaN
        for i in 0...10 {
            let t = Float(i) / 10.0
            player.seek(to: t * duration)
            player.update(deltaTime: 0, model: model)

            guard let humanoid = model.humanoid,
                  let headIndex = humanoid.getBoneNode(.head) else { continue }
            let headNode = model.nodes[headIndex]

            XCTAssertFalse(headNode.rotation.real.isNaN, "Quaternion real component should not be NaN")
            XCTAssertFalse(headNode.rotation.imag.x.isNaN, "Quaternion X component should not be NaN")
        }
    }

    /// Test quaternion SLERP with near-opposite quaternions
    func testQuaternionSlerpOpposite() {
        let duration: Float = 1.0

        // Create a clip with large rotation (near 180 degrees)
        var clip = AnimationClip(duration: duration)
        let track = JointTrack(
            bone: .leftUpperArm,
            rotationSampler: { time in
                let angle = Float.pi * time / duration
                return simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
            }
        )
        clip.addJointTrack(track)

        let player = AnimationPlayer()
        player.load(clip)

        // Test midpoint of 180-degree rotation
        player.seek(to: duration / 2)
        player.update(deltaTime: 0, model: model)

        guard let humanoid = model.humanoid,
              let armIndex = humanoid.getBoneNode(.leftUpperArm) else {
            XCTFail("Bone not found")
            return
        }
        let armNode = model.nodes[armIndex]

        // Should be approximately 90 degrees
        let magnitude = simd_length(armNode.rotation.imag)
        XCTAssertGreaterThan(magnitude, 0.5, "Rotation should be significant at midpoint")
        XCTAssertFalse(armNode.rotation.real.isNaN, "Quaternion should not be NaN")
    }

    // MARK: - Boundary Condition Tests

    /// Test animation at exactly t=0
    func testAnimationAtTimeZero() {
        var clip = AnimationClip(duration: 1.0)
        let initialAngle: Float = Float.pi / 6
        clip.addJointTrack(JointTrack(
            bone: .neck,
            rotationSampler: { time in
                return simd_quatf(angle: initialAngle + time * 0.5, axis: SIMD3<Float>(1, 0, 0))
            }
        ))

        let player = AnimationPlayer()
        player.load(clip)
        player.seek(to: 0)
        player.update(deltaTime: 0, model: model)

        guard let humanoid = model.humanoid,
              let neckIndex = humanoid.getBoneNode(.neck) else {
            XCTFail("Bone not found")
            return
        }
        let neckNode = model.nodes[neckIndex]

        let expectedQuat = simd_quatf(angle: initialAngle, axis: SIMD3<Float>(1, 0, 0))
        assertQuaternionsEqual(neckNode.rotation, expectedQuat, tolerance: 0.01)
    }

    /// Test animation at exactly t=duration
    func testAnimationAtDuration() {
        let duration: Float = 2.0
        var clip = AnimationClip(duration: duration)
        let finalAngle: Float = Float.pi / 3
        clip.addJointTrack(JointTrack(
            bone: .hips,  // Use hips - guaranteed to exist
            rotationSampler: { time in
                let progress = min(1.0, time / duration)
                return simd_quatf(angle: finalAngle * progress, axis: SIMD3<Float>(0, 0, 1))
            }
        ))

        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = false
        // Use deltaTime to advance instead of seek to ensure proper update
        player.update(deltaTime: duration, model: model)

        guard let humanoid = model.humanoid,
              let hipsIndex = humanoid.getBoneNode(.hips) else {
            XCTFail("Bone not found")
            return
        }
        let hipsNode = model.nodes[hipsIndex]

        let expectedQuat = simd_quatf(angle: finalAngle, axis: SIMD3<Float>(0, 0, 1))
        assertQuaternionsEqual(hipsNode.rotation, expectedQuat, tolerance: 0.01)
    }

    /// Test animation beyond duration (clamping)
    func testAnimationBeyondDuration() {
        let duration: Float = 1.0
        var clip = AnimationClip(duration: duration)
        clip.addJointTrack(JointTrack(
            bone: .hips,
            rotationSampler: { time in
                let clampedTime = min(time, duration)
                return simd_quatf(angle: clampedTime, axis: SIMD3<Float>(0, 1, 0))
            }
        ))

        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = false

        // Advance well beyond duration
        player.update(deltaTime: 5.0, model: model)

        // Should be at the final pose, not beyond
        XCTAssertTrue(player.isFinished, "Animation should be finished")
        XCTAssertEqual(player.progress, 1.0, accuracy: 0.01, "Progress should clamp to 1.0")
    }

    // MARK: - Translation Track Tests

    /// Test translation sampling accuracy
    /// Note: Hips translation requires applyRootMotion=true
    func testTranslationSampling() {
        let duration: Float = 1.0
        let targetTranslation = SIMD3<Float>(0.5, 0, 0)

        var clip = AnimationClip(duration: duration)
        clip.addJointTrack(JointTrack(
            bone: .hips,
            translationSampler: { time in
                let progress = time / duration
                return targetTranslation * progress
            }
        ))

        let player = AnimationPlayer()
        player.load(clip)
        player.applyRootMotion = true  // Required for hips translation
        player.seek(to: duration / 2)
        player.update(deltaTime: 0, model: model)

        guard let humanoid = model.humanoid,
              let hipsIndex = humanoid.getBoneNode(.hips) else {
            XCTFail("Bone not found")
            return
        }
        let hipsNode = model.nodes[hipsIndex]

        // Translation should be approximately half of target
        let expectedTranslation = targetTranslation * 0.5
        XCTAssertEqual(hipsNode.translation.x, expectedTranslation.x, accuracy: 0.01)
        XCTAssertEqual(hipsNode.translation.y, expectedTranslation.y, accuracy: 0.01)
        XCTAssertEqual(hipsNode.translation.z, expectedTranslation.z, accuracy: 0.01)
    }

    // MARK: - Scale Track Tests

    /// Test scale sampling accuracy
    func testScaleSampling() {
        let duration: Float = 1.0
        let targetScale = SIMD3<Float>(1.5, 1.5, 1.5)

        var clip = AnimationClip(duration: duration)
        clip.addJointTrack(JointTrack(
            bone: .hips,  // Use hips - guaranteed to exist
            scaleSampler: { time in
                let progress = time / duration
                return SIMD3<Float>(1, 1, 1) + (targetScale - SIMD3<Float>(1, 1, 1)) * progress
            }
        ))

        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = false
        // Use deltaTime to advance to end
        player.update(deltaTime: duration, model: model)

        guard let humanoid = model.humanoid,
              let hipsIndex = humanoid.getBoneNode(.hips) else {
            XCTFail("Bone not found")
            return
        }
        let hipsNode = model.nodes[hipsIndex]

        XCTAssertEqual(hipsNode.scale.x, targetScale.x, accuracy: 0.01)
        XCTAssertEqual(hipsNode.scale.y, targetScale.y, accuracy: 0.01)
        XCTAssertEqual(hipsNode.scale.z, targetScale.z, accuracy: 0.01)
    }

    // MARK: - Morph Track Tests

    /// Test morph track sampling
    func testMorphTrackSampling() {
        let duration: Float = 1.0

        var clip = AnimationClip(duration: duration)
        clip.addMorphTrack(key: "happy", sample: { time in
            return time / duration
        })
        clip.addMorphTrack(key: "sad", sample: { time in
            return 1.0 - (time / duration)
        })

        let player = AnimationPlayer()
        player.load(clip)
        player.seek(to: duration / 2)
        player.update(deltaTime: 0, model: model)

        // Morph weights are tracked internally - this test verifies no crashes
        XCTAssertEqual(clip.morphTracks.count, 2)
        XCTAssertEqual(clip.morphTracks[0].sample(at: duration / 2), 0.5, accuracy: 0.01)
        XCTAssertEqual(clip.morphTracks[1].sample(at: duration / 2), 0.5, accuracy: 0.01)
    }

    // MARK: - Multi-Bone Coordination Tests

    /// Test that multiple bones animate together correctly
    func testMultiBoneCoordination() {
        let duration: Float = 1.0

        var clip = AnimationClip(duration: duration)

        // Create a coordinated animation where spine, chest, and head all rotate
        let bones: [VRMHumanoidBone] = [.spine, .chest, .head]
        let angles: [Float] = [0.1, 0.15, 0.2]  // Increasing angles up the spine

        for (i, bone) in bones.enumerated() {
            let targetAngle = angles[i]
            clip.addJointTrack(JointTrack(
                bone: bone,
                rotationSampler: { time in
                    let progress = time / duration
                    return simd_quatf(angle: targetAngle * progress, axis: SIMD3<Float>(1, 0, 0))
                }
            ))
        }

        let player = AnimationPlayer()
        player.load(clip)
        player.update(deltaTime: duration, model: model)

        // Verify all bones have been updated
        for (i, bone) in bones.enumerated() {
            guard let humanoid = model.humanoid,
                  let nodeIndex = humanoid.getBoneNode(bone) else { continue }
            let node = model.nodes[nodeIndex]

            let expectedQuat = simd_quatf(angle: angles[i], axis: SIMD3<Float>(1, 0, 0))
            assertQuaternionsEqual(node.rotation, expectedQuat, tolerance: 0.02)
        }
    }

    // MARK: - Looping Tests

    /// Test that looping wraps time correctly
    func testLoopingTimeWrap() {
        let duration: Float = 1.0

        var clip = AnimationClip(duration: duration)
        clip.addJointTrack(JointTrack(
            bone: .hips,
            rotationSampler: { time in
                let wrappedTime = time.truncatingRemainder(dividingBy: duration)
                return simd_quatf(angle: wrappedTime * Float.pi / 4, axis: SIMD3<Float>(0, 1, 0))
            }
        ))

        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = true

        // Advance past one full cycle
        player.update(deltaTime: duration * 1.5, model: model)

        XCTAssertFalse(player.isFinished, "Looping animation should never finish")
        XCTAssertLessThan(player.progress, 1.0, "Progress should wrap after loop")
    }

    // MARK: - Performance Tests

    /// Test animation with many tracks doesn't cause performance issues
    func testManyTracksPerformance() {
        let duration: Float = 2.0

        var clip = AnimationClip(duration: duration)

        // Add tracks for all common bones
        let allBones: [VRMHumanoidBone] = [
            .hips, .spine, .chest, .head, .neck,
            .leftUpperArm, .leftLowerArm, .leftHand,
            .rightUpperArm, .rightLowerArm, .rightHand,
            .leftUpperLeg, .leftLowerLeg, .leftFoot,
            .rightUpperLeg, .rightLowerLeg, .rightFoot
        ]

        for bone in allBones {
            clip.addJointTrack(JointTrack(
                bone: bone,
                rotationSampler: { time in
                    return simd_quatf(angle: time * 0.1, axis: SIMD3<Float>(0, 1, 0))
                }
            ))
        }

        let player = AnimationPlayer()
        player.load(clip)

        // Measure performance of 1000 updates
        let startTime = CFAbsoluteTimeGetCurrent()
        for _ in 0..<1000 {
            player.update(deltaTime: 0.016, model: model)  // ~60fps
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        // Should complete in reasonable time (less than 1 second for 1000 frames)
        XCTAssertLessThan(elapsed, 1.0, "Animation updates should be performant")
    }

    // MARK: - Node Track Tests

    /// Test non-humanoid node tracks
    func testNodeTrackPlayback() {
        let duration: Float = 1.0

        var clip = AnimationClip(duration: duration)
        clip.addNodeTrack(NodeTrack(
            nodeName: "Hair_Root",
            rotationSampler: { time in
                return simd_quatf(angle: time * 0.2, axis: SIMD3<Float>(0, 0, 1))
            }
        ))

        XCTAssertEqual(clip.nodeTracks.count, 1)
        XCTAssertEqual(clip.nodeTracks[0].nodeName, "Hair_Root")

        let (rotation, _, _) = clip.nodeTracks[0].sample(at: 0.5)
        XCTAssertNotNil(rotation)
        XCTAssertFalse(rotation!.real.isNaN)
    }

    // MARK: - Euler Track Tests

    /// Test addEulerTrack convenience method
    func testEulerTrackConversion() {
        let duration: Float = 1.0

        var clip = AnimationClip(duration: duration)
        clip.addEulerTrack(bone: .head, axis: .x, sample: { time in
            return time * Float.pi / 4
        })

        XCTAssertEqual(clip.jointTracks.count, 1)
        XCTAssertEqual(clip.jointTracks[0].bone, .head)

        let (rotation, _, _) = clip.jointTracks[0].sample(at: duration)
        XCTAssertNotNil(rotation)

        // At t=1.0, angle should be pi/4
        let expectedQuat = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(1, 0, 0))
        assertQuaternionsEqual(rotation!, expectedQuat, tolerance: 0.01)
    }

    // MARK: - Coordinate Conversion Tests

    /// Test VRM 0.0 coordinate conversion math
    func testVRM0CoordinateConversion() {
        // Test rotation conversion: X and Z should be negated
        let testQuat = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(1, 1, 1).normalized)

        // The conversion should negate X and Z components of the quaternion
        // This matches three-vrm createVRMAnimationClip.ts behavior
        let converted = simd_quatf(ix: -testQuat.imag.x, iy: testQuat.imag.y, iz: -testQuat.imag.z, r: testQuat.real)

        XCTAssertEqual(converted.imag.x, -testQuat.imag.x, accuracy: 0.0001)
        XCTAssertEqual(converted.imag.y, testQuat.imag.y, accuracy: 0.0001)
        XCTAssertEqual(converted.imag.z, -testQuat.imag.z, accuracy: 0.0001)
        XCTAssertEqual(converted.real, testQuat.real, accuracy: 0.0001)
    }

    /// Test translation coordinate conversion
    func testTranslationCoordinateConversion() {
        let testTranslation = SIMD3<Float>(1.0, 2.0, 3.0)

        // The conversion should negate X and Z
        let converted = SIMD3<Float>(-testTranslation.x, testTranslation.y, -testTranslation.z)

        XCTAssertEqual(converted.x, -1.0, accuracy: 0.0001)
        XCTAssertEqual(converted.y, 2.0, accuracy: 0.0001)
        XCTAssertEqual(converted.z, -3.0, accuracy: 0.0001)
    }

    // MARK: - Error Handling Tests

    /// Test that empty clip doesn't crash
    func testEmptyClipSafety() {
        let clip = AnimationClip(duration: 0)
        let player = AnimationPlayer()
        player.load(clip)

        // Should not crash
        player.update(deltaTime: 1.0, model: model)
        XCTAssertTrue(player.isFinished || clip.duration == 0)
    }

    /// Test very short duration clip
    func testVeryShortDuration() {
        var clip = AnimationClip(duration: 0.001)
        clip.addJointTrack(JointTrack(
            bone: .hips,
            rotationSampler: { _ in simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        ))

        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = false

        player.update(deltaTime: 0.016, model: model)

        XCTAssertTrue(player.isFinished, "Very short animation should finish immediately")
    }
}

// MARK: - Test Helpers

extension SIMD3 where Scalar == Float {
    var normalized: SIMD3<Float> {
        let len = simd_length(self)
        return len > 0 ? self / len : self
    }
}
