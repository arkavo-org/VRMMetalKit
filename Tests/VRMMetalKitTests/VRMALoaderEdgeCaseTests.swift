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

/// Tests for VRMAnimationLoader edge cases and error handling
final class VRMALoaderEdgeCaseTests: XCTestCase {

    var device: MTLDevice!
    var model: VRMModel!

    private var projectRoot: String {
        let fileManager = FileManager.default
        let candidates: [String?] = [
            ProcessInfo.processInfo.environment["PROJECT_ROOT"],
            ProcessInfo.processInfo.environment["SRCROOT"],
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

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device

        let vrmDocument = try VRMBuilder()
            .setSkeleton(.defaultHumanoid)
            .applyMorphs(["height": 1.0])
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

    // MARK: - Real File Loading Tests

    /// Test loading VRMA_01 and verify all expected tracks are present
    func testVRMA01LoadsAllBones() async throws {
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"

        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA_01 not found at \(vrmaPath)")

        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)

        XCTAssertGreaterThan(clip.duration, 0, "Duration should be positive")
        XCTAssertGreaterThan(clip.jointTracks.count, 0, "Should have joint tracks")

        // Check for essential bones
        let essentialBones: [VRMHumanoidBone] = [.hips, .spine]
        for bone in essentialBones {
            let hasTrack = clip.jointTracks.contains { $0.bone == bone }
            XCTAssertTrue(hasTrack, "Should have track for \(bone)")
        }

        print("[VRMA01] Duration: \(clip.duration)s")
        print("[VRMA01] Joint tracks: \(clip.jointTracks.count)")
        print("[VRMA01] Morph tracks: \(clip.morphTracks.count)")
        print("[VRMA01] Node tracks: \(clip.nodeTracks.count)")
    }

    /// Test all VRMA files load without crashing
    func testAllVRMAFilesLoad() async throws {
        let vrmaFiles = (1...7).compactMap { num -> URL? in
            let path = "\(projectRoot)/VRMA_0\(num).vrma"
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            return nil
        }

        try XCTSkipIf(vrmaFiles.isEmpty, "No VRMA files found")

        for vrmaURL in vrmaFiles {
            do {
                let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
                XCTAssertGreaterThan(clip.duration, 0, "\(vrmaURL.lastPathComponent) should have positive duration")
                print("[OK] \(vrmaURL.lastPathComponent): \(clip.jointTracks.count) tracks, \(String(format: "%.2f", clip.duration))s")
            } catch {
                XCTFail("Failed to load \(vrmaURL.lastPathComponent): \(error)")
            }
        }
    }

    /// Test loading without model (no retargeting)
    func testLoadWithoutModel() throws {
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"

        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA_01 not found")

        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: nil)

        XCTAssertGreaterThan(clip.duration, 0)
        XCTAssertGreaterThan(clip.jointTracks.count, 0)

        // Sample a track to ensure it works
        if let hipsTrack = clip.jointTracks.first(where: { $0.bone == .hips }) {
            let (rotation, _, _) = hipsTrack.sample(at: 0)
            XCTAssertNotNil(rotation)
            XCTAssertFalse(rotation!.real.isNaN)
        }
    }

    // MARK: - Retargeting Tests

    /// Test that retargeting produces valid quaternions
    func testRetargetingProducesValidQuaternions() throws {
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"

        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA_01 not found")

        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)

        // Sample every track at multiple times
        let sampleTimes: [Float] = [0, clip.duration * 0.25, clip.duration * 0.5, clip.duration * 0.75, clip.duration]

        for track in clip.jointTracks {
            for time in sampleTimes {
                let (rotation, _, _) = track.sample(at: time)

                if let rot = rotation {
                    // Check for NaN
                    XCTAssertFalse(rot.real.isNaN, "Rotation real should not be NaN for \(track.bone) at t=\(time)")
                    XCTAssertFalse(rot.imag.x.isNaN, "Rotation X should not be NaN for \(track.bone) at t=\(time)")
                    XCTAssertFalse(rot.imag.y.isNaN, "Rotation Y should not be NaN for \(track.bone) at t=\(time)")
                    XCTAssertFalse(rot.imag.z.isNaN, "Rotation Z should not be NaN for \(track.bone) at t=\(time)")

                    // Check for Inf
                    XCTAssertFalse(rot.real.isInfinite, "Rotation should not be infinite for \(track.bone)")

                    // Check normalization (quaternion length should be ~1)
                    let length = simd_length(rot.vector)
                    XCTAssertEqual(length, 1.0, accuracy: 0.01, "Quaternion should be normalized for \(track.bone)")
                }
            }
        }
    }

    /// Test retargeting with different rest poses
    func testRetargetingWithDifferentRestPose() throws {
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"

        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA_01 not found")

        let vrmaURL = URL(fileURLWithPath: vrmaPath)

        // Load with and without model
        let clipWithModel = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
        let clipWithoutModel = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: nil)

        // Both should have tracks
        XCTAssertGreaterThan(clipWithModel.jointTracks.count, 0)
        XCTAssertGreaterThan(clipWithoutModel.jointTracks.count, 0)

        // Compare hips rotation at t=0
        if let trackWith = clipWithModel.jointTracks.first(where: { $0.bone == .hips }),
           let trackWithout = clipWithoutModel.jointTracks.first(where: { $0.bone == .hips }) {
            let (rotWith, _, _) = trackWith.sample(at: 0)
            let (rotWithout, _, _) = trackWithout.sample(at: 0)

            // They should both exist
            XCTAssertNotNil(rotWith)
            XCTAssertNotNil(rotWithout)

            // Log the difference for debugging
            if let rw = rotWith, let rwo = rotWithout {
                let dot = simd_dot(rw.vector, rwo.vector)
                print("[Retargeting] Hips rotation dot product (with vs without model): \(dot)")
            }
        }
    }

    // MARK: - Sampling Edge Cases

    /// Test sampling at negative time
    func testSamplingAtNegativeTime() throws {
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"

        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA_01 not found")

        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)

        guard let hipsTrack = clip.jointTracks.first(where: { $0.bone == .hips }) else {
            XCTFail("No hips track")
            return
        }

        // Sample at negative time - should clamp to 0
        let (rotation, _, _) = hipsTrack.sample(at: -1.0)
        let (rotationAtZero, _, _) = hipsTrack.sample(at: 0)

        XCTAssertNotNil(rotation)
        XCTAssertNotNil(rotationAtZero)

        // Should be equal to t=0 (clamped)
        if let r1 = rotation, let r2 = rotationAtZero {
            assertQuaternionsEqual(r1, r2, tolerance: 0.0001)
        }
    }

    /// Test sampling at very large time
    func testSamplingAtLargeTime() throws {
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"

        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA_01 not found")

        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)

        guard let hipsTrack = clip.jointTracks.first(where: { $0.bone == .hips }) else {
            XCTFail("No hips track")
            return
        }

        // Sample at very large time - should clamp to duration
        let (rotation, _, _) = hipsTrack.sample(at: 1000000.0)
        let (rotationAtEnd, _, _) = hipsTrack.sample(at: clip.duration)

        XCTAssertNotNil(rotation)
        XCTAssertNotNil(rotationAtEnd)

        // Should be equal to t=duration (clamped)
        if let r1 = rotation, let r2 = rotationAtEnd {
            assertQuaternionsEqual(r1, r2, tolerance: 0.0001)
        }
    }

    // MARK: - Animation Player Integration Tests

    /// Test AnimationPlayer with VRMA clip
    func testAnimationPlayerWithVRMA() throws {
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"

        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA_01 not found")

        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)

        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = false

        // Update through the full animation
        var frameCount = 0
        while !player.isFinished && frameCount < 1000 {
            player.update(deltaTime: 1.0 / 60.0, model: model)
            frameCount += 1
        }

        XCTAssertTrue(player.isFinished, "Animation should finish")
        print("[Player] Completed in \(frameCount) frames")
    }

    /// Test AnimationPlayer looping with VRMA
    func testAnimationPlayerLoopingWithVRMA() throws {
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"

        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA_01 not found")

        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)

        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = true

        // Update past duration
        player.update(deltaTime: clip.duration * 1.5, model: model)

        XCTAssertFalse(player.isFinished, "Looping animation should not finish")
        XCTAssertLessThan(player.progress, 1.0, "Progress should wrap on loop")
    }

    // MARK: - Expression Track Tests

    /// Test expression tracks are loaded
    func testExpressionTracksLoaded() throws {
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"

        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA_01 not found")

        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)

        // Check if any morph tracks exist
        print("[Expressions] Found \(clip.morphTracks.count) morph tracks")
        for track in clip.morphTracks {
            print("  - \(track.key)")

            // Sample at various times
            for t in [Float(0), clip.duration / 2, clip.duration] {
                let weight = track.sample(at: t)
                XCTAssertFalse(weight.isNaN, "Weight should not be NaN for \(track.key)")
                XCTAssertGreaterThanOrEqual(weight, 0, "Weight should be >= 0 for \(track.key)")
                XCTAssertLessThanOrEqual(weight, 1.5, "Weight should be reasonable for \(track.key)")
            }
        }
    }

    // MARK: - Non-Humanoid Node Track Tests

    /// Test non-humanoid node tracks are loaded
    func testNonHumanoidNodeTracksLoaded() throws {
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"

        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "VRMA_01 not found")

        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)

        print("[NodeTracks] Found \(clip.nodeTracks.count) non-humanoid node tracks")
        for track in clip.nodeTracks {
            print("  - \(track.nodeName)")

            // Sample rotation
            let (rotation, translation, scale) = track.sample(at: clip.duration / 2)

            if let rot = rotation {
                XCTAssertFalse(rot.real.isNaN, "Node rotation should not be NaN for \(track.nodeName)")
            }
            if let trans = translation {
                XCTAssertFalse(trans.x.isNaN, "Node translation should not be NaN for \(track.nodeName)")
            }
            if let scl = scale {
                XCTAssertFalse(scl.x.isNaN, "Node scale should not be NaN for \(track.nodeName)")
            }
        }
    }

    // MARK: - Error Handling Tests

    /// Test loading non-existent file throws appropriate error
    func testLoadNonExistentFile() {
        let fakeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString)")
            .appendingPathExtension("vrma")

        XCTAssertThrowsError(try VRMAnimationLoader.loadVRMA(from: fakeURL, model: model)) { error in
            // Should throw file not found error
            print("[Error] Expected error: \(error)")
        }
    }

    /// Test loading invalid file throws appropriate error
    func testLoadInvalidFile() throws {
        // Create a temporary file with invalid data
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("vrma")

        try "this is not a valid GLB file".write(to: tempURL, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        XCTAssertThrowsError(try VRMAnimationLoader.loadVRMA(from: tempURL, model: model)) { error in
            print("[Error] Expected error for invalid file: \(error)")
        }
    }
}
