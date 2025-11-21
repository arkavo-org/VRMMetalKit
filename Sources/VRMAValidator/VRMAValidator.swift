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

import Foundation
import Metal
import simd
import VRMMetalKit

/// Command-line tool to extract joint rotations from VRMA files for validation
/// Usage: VRMAValidator <vrma-file> <vrm-model>

@main
struct VRMAValidatorMain {
    // Key bones for validation
    static let keyBones: [VRMHumanoidBone] = [
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

    static func extractJointRotations(vrmaPath: String, vrmPath: String) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("❌ Metal device not available")
            exit(1)
        }

        print("\n" + String(repeating: "=", count: 80))
        print("VRMA VALIDATION OUTPUT")
        print(String(repeating: "=", count: 80))

        // Load VRM model
        let modelURL = URL(fileURLWithPath: vrmPath)
        let model = try await VRMModel.load(from: modelURL, device: device)

        print("\n📦 Model: \(vrmPath)")
        print("   Nodes: \(model.nodes.count)")
        print("   Humanoid: \(model.humanoid != nil ? "✓" : "✗")")

        // Load VRMA animation
        let vrmaURL = URL(fileURLWithPath: vrmaPath)
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)

        print("\n🎬 Animation: \(vrmaPath)")
        print("   Duration: \(String(format: "%.3f", clip.duration))s")
        print("   Joint tracks: \(clip.jointTracks.count)")

        // Extract at key frames: 0, middle, last
        let frameTimes: [Float] = [
            0.0,
            clip.duration / 2.0,
            max(0, clip.duration - 0.001)
        ]

        print("\n📊 Frame times: \(frameTimes.map { String(format: "%.3f", $0) }.joined(separator: "s, "))s")
        print("")

        for (index, time) in frameTimes.enumerated() {
            print("\n" + String(repeating: "-", count: 80))
            print("FRAME \(index): t=\(String(format: "%.3f", time))s")
            print(String(repeating: "-", count: 80))

            // Apply animation by seeking to specific time
            let player = AnimationPlayer()
            player.load(clip)
            player.isLooping = false
            player.play()

            // Seek to the desired time point
            player.seek(to: time)

            // Sample animation at this time point (deltaTime=0 to prevent further time advancement)
            player.update(deltaTime: 0, model: model)

            // Update world transforms
            for node in model.nodes where node.parent == nil {
                node.updateWorldTransform()
            }

            // Extract rotations
            for bone in keyBones {
                guard let humanoid = model.humanoid,
                      let nodeIndex = humanoid.getBoneNode(bone),
                      nodeIndex < model.nodes.count else {
                    continue
                }

                let node = model.nodes[nodeIndex]
                let q = node.rotation

                // Format output using NSString to avoid C-style formatting issues
                let boneName = "\(bone):".padding(toLength: 20, withPad: " ", startingAt: 0)
                let formatted = String(format: "%@ quat(% .6f, % .6f, % .6f, % .6f)",
                                      boneName as NSString,
                                      q.imag.x, q.imag.y, q.imag.z, q.real)
                print(formatted)
            }
        }

        print("\n" + String(repeating: "=", count: 80))
        print("END OUTPUT")
        print(String(repeating: "=", count: 80) + "\n")
    }

    static func main() async {
        guard CommandLine.arguments.count >= 3 else {
            print("Usage: VRMAValidator <vrma-file> <vrm-model>")
            print("")
            print("Example:")
            print("  VRMAValidator VRMA_01.vrma AliciaSolid.vrm")
            Foundation.exit(1)
        }

        let vrmaPath = CommandLine.arguments[1]
        let vrmPath = CommandLine.arguments[2]

        do {
            try await extractJointRotations(vrmaPath: vrmaPath, vrmPath: vrmPath)
            Foundation.exit(0)
        } catch {
            print("❌ Error: \(error)")
            Foundation.exit(1)
        }
    }
}
