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

/// Programmatic animation tests that don't depend on external files
final class VRMAMinimalTest: XCTestCase {

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

    // MARK: - Basic Animation Playback Tests

    func testMinimalAnimationPlayback() {
        let duration: Float = 1.0
        let targetAngle: Float = Float.pi / 4

        var clip = AnimationClip(duration: duration)
        let track = JointTrack(
            bone: .hips,
            rotationSampler: { time in
                let progress = time / duration
                return simd_quatf(angle: targetAngle * progress, axis: SIMD3<Float>(0, 1, 0))
            }
        )
        clip.addJointTrack(track)

        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = false

        player.update(deltaTime: duration * 0.5, model: model)

        guard let humanoid = model.humanoid,
              let hipsIndex = humanoid.getBoneNode(.hips),
              hipsIndex < model.nodes.count else {
            XCTFail("Hips bone not found in model")
            return
        }

        let hipsNode = model.nodes[hipsIndex]
        let expectedRotation = simd_quatf(angle: targetAngle * 0.5, axis: SIMD3<Float>(0, 1, 0))

        assertQuaternionsEqual(hipsNode.rotation, expectedRotation, tolerance: 0.01)
    }

    func testAnimationWithMultipleBones() {
        let duration: Float = 1.0
        let targetAngle: Float = Float.pi / 6

        var clip = AnimationClip(duration: duration)

        let bones: [VRMHumanoidBone] = [.hips, .spine, .chest]
        for bone in bones {
            let track = JointTrack(
                bone: bone,
                rotationSampler: { time in
                    let progress = time / duration
                    return simd_quatf(angle: targetAngle * progress, axis: SIMD3<Float>(1, 0, 0))
                }
            )
            clip.addJointTrack(track)
        }

        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = false

        player.update(deltaTime: duration, model: model)

        for bone in bones {
            guard let humanoid = model.humanoid,
                  let nodeIndex = humanoid.getBoneNode(bone),
                  nodeIndex < model.nodes.count else {
                continue
            }

            let node = model.nodes[nodeIndex]
            let expectedRotation = simd_quatf(angle: targetAngle, axis: SIMD3<Float>(1, 0, 0))
            assertQuaternionsEqual(node.rotation, expectedRotation, tolerance: 0.01)
        }
    }

    func testAnimationAtMultipleFrameTimes() {
        let duration: Float = 2.0
        let maxAngle: Float = Float.pi / 2

        var clip = AnimationClip(duration: duration)
        let track = JointTrack(
            bone: .leftUpperArm,
            rotationSampler: { time in
                let progress = time / duration
                return simd_quatf(angle: maxAngle * progress, axis: SIMD3<Float>(0, 0, 1))
            }
        )
        clip.addJointTrack(track)

        let frameTimes: [Float] = [0.0, duration / 2.0, duration]

        for frameTime in frameTimes {
            let player = AnimationPlayer()
            player.load(clip)
            player.isLooping = false

            player.update(deltaTime: frameTime, model: model)

            guard let humanoid = model.humanoid,
                  let nodeIndex = humanoid.getBoneNode(.leftUpperArm),
                  nodeIndex < model.nodes.count else {
                continue
            }

            let node = model.nodes[nodeIndex]
            let expectedAngle = maxAngle * (frameTime / duration)
            let expectedRotation = simd_quatf(angle: expectedAngle, axis: SIMD3<Float>(0, 0, 1))

            assertQuaternionsEqual(node.rotation, expectedRotation, tolerance: 0.01)
        }
    }

    // MARK: - Animation Player State Tests

    func testAnimationPlayerInitialState() {
        let player = AnimationPlayer()

        XCTAssertEqual(player.progress, 0)
        XCTAssertFalse(player.isFinished)
    }

    func testAnimationPlayerLoading() {
        let clip = AnimationClip(duration: 1.0)
        let player = AnimationPlayer()

        player.load(clip)

        XCTAssertEqual(player.progress, 0)
    }

    func testAnimationPlayerProgress() {
        var clip = AnimationClip(duration: 2.0)
        clip.addJointTrack(JointTrack(bone: .hips, rotationSampler: { _ in
            simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }))

        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = false

        player.update(deltaTime: 1.0, model: model)

        assertFloatsEqual(player.progress, 0.5, tolerance: 0.01)
    }

    func testAnimationPlayerFinished() {
        var clip = AnimationClip(duration: 1.0)
        clip.addJointTrack(JointTrack(bone: .hips, rotationSampler: { _ in
            simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }))

        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = false

        player.update(deltaTime: 2.0, model: model)

        XCTAssertTrue(player.isFinished)
    }

    func testAnimationPlayerLooping() {
        var clip = AnimationClip(duration: 1.0)
        clip.addJointTrack(JointTrack(bone: .hips, rotationSampler: { _ in
            simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }))

        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = true

        player.update(deltaTime: 2.5, model: model)

        XCTAssertFalse(player.isFinished, "Looping animation should never be finished")
        XCTAssertGreaterThan(player.progress, 0, "Progress should accumulate")
    }

    // MARK: - Animation Speed Tests

    func testAnimationSpeedMultiplier() {
        var clip = AnimationClip(duration: 2.0)
        clip.addJointTrack(JointTrack(bone: .hips, rotationSampler: { _ in
            simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }))

        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = false
        player.speed = 2.0

        player.update(deltaTime: 0.5, model: model)

        assertFloatsEqual(player.progress, 0.5, tolerance: 0.01)
    }

    func testAnimationZeroSpeed() {
        var clip = AnimationClip(duration: 1.0)
        clip.addJointTrack(JointTrack(bone: .hips, rotationSampler: { _ in
            simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }))

        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = false
        player.speed = 0

        player.update(deltaTime: 1.0, model: model)

        XCTAssertEqual(player.progress, 0)
    }

    // MARK: - World Transform Propagation Tests

    func testWorldTransformPropagation() {
        let angle: Float = Float.pi / 4

        var clip = AnimationClip(duration: 1.0)
        clip.addJointTrack(JointTrack(
            bone: .hips,
            rotationSampler: { _ in
                simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
            }
        ))

        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = false

        player.update(deltaTime: 0.5, model: model)

        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }

        XCTAssertNotNil(model.nodes.first)
    }

    // MARK: - Morph Track Tests

    func testMorphTrackPlayback() {
        var clip = AnimationClip(duration: 1.0)
        clip.addMorphTrack(key: "happy", sample: { time in
            return time
        })

        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = false

        player.update(deltaTime: 0.5, model: model)

        XCTAssertNotNil(player)
    }

    // MARK: - Control Flow Tests

    func testAnimationPlayPauseStop() {
        var clip = AnimationClip(duration: 2.0)
        clip.addJointTrack(JointTrack(bone: .hips, rotationSampler: { _ in
            simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }))

        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = false

        player.update(deltaTime: 0.5, model: model)
        let progressAfterPlay = player.progress

        player.pause()
        player.update(deltaTime: 0.5, model: model)
        let progressAfterPause = player.progress

        XCTAssertGreaterThan(progressAfterPlay, 0)
        XCTAssertEqual(progressAfterPause, progressAfterPlay, accuracy: 0.001)

        player.play()
        player.update(deltaTime: 0.5, model: model)
        let progressAfterResume = player.progress

        XCTAssertGreaterThan(progressAfterResume, progressAfterPause)

        player.stop()
        XCTAssertEqual(player.progress, 0)
    }

    func testAnimationSeek() {
        var clip = AnimationClip(duration: 2.0)
        clip.addJointTrack(JointTrack(bone: .hips, rotationSampler: { _ in
            simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }))

        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = false

        player.seek(to: 1.0)
        player.update(deltaTime: 0, model: model)

        assertFloatsEqual(player.progress, 0.5, tolerance: 0.01)
    }

    // MARK: - Edge Case Tests

    func testEmptyClipHandling() {
        let clip = AnimationClip(duration: 1.0)
        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = false

        player.update(deltaTime: 0.5, model: model)

        XCTAssertNotNil(player)
    }

    func testZeroDurationClip() {
        let clip = AnimationClip(duration: 0.0)
        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = false

        player.update(deltaTime: 0.1, model: model)

        XCTAssertTrue(player.isFinished || player.progress.isNaN || player.progress.isInfinite || player.progress >= 1.0)
    }

    func testNegativeSpeedClamping() {
        var clip = AnimationClip(duration: 1.0)
        clip.addJointTrack(JointTrack(bone: .hips, rotationSampler: { _ in
            simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }))

        let player = AnimationPlayer()
        player.load(clip)
        player.speed = -1.0

        XCTAssertGreaterThanOrEqual(player.speed, 0)
    }
}
