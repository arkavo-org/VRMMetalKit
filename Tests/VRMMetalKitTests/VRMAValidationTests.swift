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

/// Numerical validation tests comparing VRMMetalKit animation output
/// against official VRM tooling (UniVRM, VRM Blender Add-on)
///
/// These tests extract joint rotations at key frames and output them
/// in a format suitable for comparison with reference implementations.
final class VRMAValidationTests: XCTestCase {

    // MARK: - Configuration

    /// Find project root by checking known locations
    var projectRoot: String {
        let fileManager = FileManager.default

        // Known locations to check (in priority order)
        let candidates: [String?] = [
            // From environment variable (highest priority)
            ProcessInfo.processInfo.environment["PROJECT_ROOT"],
            // Relative to test file (#file)
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()  // VRMAValidationTests.swift
                .deletingLastPathComponent()  // VRMMetalKitTests
                .deletingLastPathComponent()  // Tests
                .path,
            // Current directory
            fileManager.currentDirectoryPath
        ]

        // Return first valid project root (has Package.swift and test files)
        for candidate in candidates.compactMap({ $0 }) {
            let packagePath = "\(candidate)/Package.swift"
            let vrmPath = "\(candidate)/AliciaSolid.vrm"
            if fileManager.fileExists(atPath: packagePath) &&
               fileManager.fileExists(atPath: vrmPath) {
                return candidate
            }
        }

        // Fallback: just use current directory (tests will skip if files not found)
        return fileManager.currentDirectoryPath
    }

    // Use project root for test files (can be overridden via environment)
    var vrmaBasePath: String {
        ProcessInfo.processInfo.environment["VRMA_TEST_PATH"] ?? projectRoot
    }

    var vrmModelPath: String {
        if let envPath = ProcessInfo.processInfo.environment["VRM_MODEL_PATH"] {
            return envPath
        }
        return "\(projectRoot)/AliciaSolid.vrm"
    }

    /// Bones to validate (critical for animation retargeting)
    let keyBones: [VRMHumanoidBone] = [
        .hips,
        .spine,
        .chest,
        .leftShoulder,
        .rightShoulder,
        .leftUpperArm,
        .rightUpperArm,
        .leftLowerArm,
        .rightLowerArm,
        .leftUpperLeg,
        .rightUpperLeg,
        .leftLowerLeg,
        .rightLowerLeg,
        .head
    ]

    // MARK: - Test Cases

    /// Extract and output joint rotations for VRMA_01.vrma
    /// This file was flagged as having z=-0.558 in upper arms (non-compliant per old heuristic)
    func testExtractJointRotations_VRMA01() async throws {
        try await extractAndPrintJointRotations(vrmaFile: "VRMA_01.vrma")
    }

    /// Extract and output joint rotations for VRMA_02.vrma
    /// This file was flagged as having z=-0.502 in upper arms
    func testExtractJointRotations_VRMA02() async throws {
        try await extractAndPrintJointRotations(vrmaFile: "VRMA_02.vrma")
    }

    /// Extract and output joint rotations for VRMA_07.vrma
    /// This file was flagged as having z=-0.366 in upper arms
    func testExtractJointRotations_VRMA07() async throws {
        try await extractAndPrintJointRotations(vrmaFile: "VRMA_07.vrma")
    }

    // MARK: - Helper Methods

    /// Load VRMA animation, apply it to VRM model, and extract joint rotations
    private func extractAndPrintJointRotations(vrmaFile: String) async throws {
        // Check if test files exist (they're in .gitignore, so only available locally)
        let modelPath = vrmModelPath
        let vrmaPath = "\(vrmaBasePath)/\(vrmaFile)"

        let modelExists = FileManager.default.fileExists(atPath: modelPath)
        let vrmaExists = FileManager.default.fileExists(atPath: vrmaPath)

        try XCTSkipIf(!modelExists, "VRM model not found at \(modelPath). These validation tests require local test files (not in repo).")
        try XCTSkipIf(!vrmaExists, "VRMA file not found at \(vrmaPath). These validation tests require local test files (not in repo).")

        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("Metal device not available")
            return
        }

        print("\n" + String(repeating: "=", count: 80))
        print("VRMA VALIDATION: \(vrmaFile)")
        print(String(repeating: "=", count: 80))

        // Load VRM model
        let modelURL = URL(fileURLWithPath: vrmModelPath)
        let model = try await VRMModel.load(from: modelURL, device: device)

        print("\n📦 Model: AliciaSolid.vrm")
        print("   Nodes: \(model.nodes.count)")
        print("   Humanoid bones: \(model.humanoid?.getBoneNode(.hips) != nil ? "✓" : "✗")")

        // Load VRMA animation
        let vrmaURL = URL(fileURLWithPath: "\(vrmaBasePath)/\(vrmaFile)")
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)

        print("\n🎬 Animation: \(vrmaFile)")
        print("   Duration: \(String(format: "%.2f", clip.duration))s")
        print("   Joint tracks: \(clip.jointTracks.count)")

        // Extract rotations at key frames
        let frameIndices = getKeyFrameIndices(duration: clip.duration)

        print("\n📊 Extracting rotations at frames: \(frameIndices.map { String(format: "%.2f", $0.time) }.joined(separator: ", "))")
        print("")

        for frameInfo in frameIndices {
            print("\n" + String(repeating: "-", count: 80))
            print("Frame \(frameInfo.index): t=\(String(format: "%.3f", frameInfo.time))s")
            print(String(repeating: "-", count: 80))

            // Apply animation at this specific time by using delta from start
            let player = AnimationPlayer()
            player.load(clip)
            player.isLooping = false

            // Advance to target time
            player.update(deltaTime: frameInfo.time, model: model)

            // Update world transforms
            for node in model.nodes where node.parent == nil {
                node.updateWorldTransform()
            }

            // Extract rotations for key bones
            for bone in keyBones {
                guard let humanoid = model.humanoid,
                      let nodeIndex = humanoid.getBoneNode(bone),
                      nodeIndex < model.nodes.count else {
                    continue
                }

                let node = model.nodes[nodeIndex]
                let rotation = node.rotation

                // Output in format: bone: quat(x, y, z, w)
                print(String(format: "  %-20s quat(% .6f, % .6f, % .6f, % .6f)",
                            "\(bone):",
                            rotation.imag.x,
                            rotation.imag.y,
                            rotation.imag.z,
                            rotation.real))
            }
        }

        print("\n" + String(repeating: "=", count: 80))
        print("Output format: Copy these quaternion values for comparison with UniVRM/Blender")
        print(String(repeating: "=", count: 80) + "\n")
    }

    /// Get key frame indices for validation
    /// Returns: first frame, middle frame, last frame
    private func getKeyFrameIndices(duration: Float) -> [(index: Int, time: Float)] {
        return [
            (0, 0.0),                    // First frame
            (1, duration / 2.0),         // Middle frame
            (2, max(0, duration - 0.001)) // Last frame (slightly before end to avoid boundary issues)
        ]
    }
}
