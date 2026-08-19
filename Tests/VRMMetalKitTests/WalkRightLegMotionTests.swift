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

/// Walk.vrma on AvatarSample_U must articulate both knees. A frozen right
/// shin/foot (knee locked, foot locked to shin) is a mapping/retarget/apply
/// bug — the clip itself authors ~50° of rightLowerLeg motion.
final class WalkRightLegMotionTests: XCTestCase {

    private var projectRoot: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }

    private func loadAvatarU() async throws -> VRMModel {
        let modelPath = "\(projectRoot)/AvatarSample_U_1.0.vrm.glb"
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "AvatarSample_U_1.0.vrm.glb not at repo root")
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        return try await VRMModel.load(
            from: URL(fileURLWithPath: modelPath),
            device: device,
            options: VRMLoadingOptions(augmentSpringBoneColliders: false)
        )
    }

    private func loadWalk(on model: VRMModel) throws -> AnimationClip {
        let vrmaPath = "\(projectRoot)/VRMA_Locomotion_Pack/Walk.vrma"
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath),
                      "Walk.vrma not at \(vrmaPath)")
        return try VRMAnimationLoader.loadVRMA(
            from: URL(fileURLWithPath: vrmaPath), model: model)
    }

    private func worldPos(_ model: VRMModel, _ bone: VRMHumanoidBone) -> SIMD3<Float>? {
        guard let idx = model.humanoid?.getBoneNode(bone), idx < model.nodes.count else {
            return nil
        }
        return model.nodes[idx].worldPosition
    }

    private func kneeAngle(_ model: VRMModel, upper: VRMHumanoidBone,
                           lower: VRMHumanoidBone, foot: VRMHumanoidBone) -> Float? {
        guard let hip = worldPos(model, upper),
              let knee = worldPos(model, lower),
              let ankle = worldPos(model, foot) else { return nil }
        let a = simd_normalize(hip - knee)
        let b = simd_normalize(ankle - knee)
        return acos(simd_clamp(simd_dot(a, b), -1, 1))
    }

    private func quatAngleFrom(_ q: simd_quatf, _ rest: simd_quatf) -> Float {
        let d = abs(simd_dot(simd_normalize(q).vector, simd_normalize(rest).vector))
        return 2 * acos(min(1, d))
    }

    func testWalkClipHasRightLegTracksAndBothKneesArticulate() async throws {
        let model = try await loadAvatarU()
        let humanoid = try XCTUnwrap(model.humanoid)
        let clip = try loadWalk(on: model)

        var counts: [VRMHumanoidBone: Int] = [:]
        for track in clip.jointTracks {
            counts[track.bone, default: 0] += 1
        }

        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = true

        var leftAngles: [Float] = []
        var rightAngles: [Float] = []
        var leftLowerDeltas: [Float] = []
        var rightLowerDeltas: [Float] = []
        let leftLowerRest = model.nodes[try XCTUnwrap(humanoid.getBoneNode(.leftLowerLeg))].initialRotation
        let rightLowerRest = model.nodes[try XCTUnwrap(humanoid.getBoneNode(.rightLowerLeg))].initialRotation
        let lIdx = try XCTUnwrap(humanoid.getBoneNode(.leftLowerLeg))
        let rIdx = try XCTUnwrap(humanoid.getBoneNode(.rightLowerLeg))

        for i in 0...16 {
            player.seek(to: clip.duration * Float(i) / 16)
            player.update(deltaTime: 0, model: model)
            leftAngles.append(try XCTUnwrap(
                kneeAngle(model, upper: .leftUpperLeg, lower: .leftLowerLeg, foot: .leftFoot)))
            rightAngles.append(try XCTUnwrap(
                kneeAngle(model, upper: .rightUpperLeg, lower: .rightLowerLeg, foot: .rightFoot)))
            leftLowerDeltas.append(quatAngleFrom(model.nodes[lIdx].rotation, leftLowerRest))
            rightLowerDeltas.append(quatAngleFrom(model.nodes[rIdx].rotation, rightLowerRest))
        }

        let leftRange = (leftAngles.max() ?? 0) - (leftAngles.min() ?? 0)
        let rightRange = (rightAngles.max() ?? 0) - (rightAngles.min() ?? 0)
        let leftLowerRange = (leftLowerDeltas.max() ?? 0) - (leftLowerDeltas.min() ?? 0)
        let rightLowerRange = (rightLowerDeltas.max() ?? 0) - (rightLowerDeltas.min() ?? 0)

        XCTAssertEqual(counts[.rightLowerLeg], 1, "rightLowerLeg must have exactly one joint track")
        XCTAssertEqual(counts[.rightFoot], 1, "rightFoot must have exactly one joint track")
        XCTAssertGreaterThan(leftLowerRange, 10 * .pi / 180,
                             "left lower-leg must articulate on Walk.vrma")
        XCTAssertGreaterThan(rightLowerRange, 10 * .pi / 180,
                             "right lower-leg must articulate on Walk.vrma (frozen shin)")
        XCTAssertGreaterThan(rightRange, 10 * .pi / 180,
                             "right knee angle must change over the walk (frozen knee)")
        XCTAssertGreaterThan(rightRange, leftRange * 0.4,
                             "right knee range should be comparable to left, not a locked strut")
    }

    /// Avatar U authors 276 skin joints (skirt chains occupy mid-palette
    /// slots). `rightLowerLeg` / `rightFoot` / `rightToes` sit at palette
    /// 257 / 265 / 266. Clamping JOINTS_0 to 255 at load remaps those
    /// vertices onto joint 0, so the mesh from the right knee down stays
    /// planted in bind pose while the skeleton walks — the frozen-foot
    /// artifact in U_walk.mov. This is not an IK failure.
    func testAvatarUBodyKeepsRightLegJointIndicesAbove255() async throws {
        let model = try await loadAvatarU()
        let humanoid = try XCTUnwrap(model.humanoid)
        let rightLower = try XCTUnwrap(humanoid.getBoneNode(.rightLowerLeg))
        let rightFoot = try XCTUnwrap(humanoid.getBoneNode(.rightFoot))
        let rightToes = try XCTUnwrap(humanoid.getBoneNode(.rightToes))
        XCTAssertGreaterThan(rightLower, 255, "fixture: rightLowerLeg palette must exceed the old 8-bit cap")
        XCTAssertGreaterThan(rightFoot, 255)
        XCTAssertGreaterThan(rightToes, 255)

        var seen: Set<UInt32> = []
        var maxRequired = 0
        for mesh in model.meshes {
            let name = mesh.name ?? ""
            guard name.localizedCaseInsensitiveContains("body") else { continue }
            for primitive in mesh.primitives {
                maxRequired = max(maxRequired, primitive.requiredPaletteSize)
                let verts = primitive.interleavedVertices()
                guard !verts.isEmpty else { continue }
                for v in verts {
                    let j = v.joints
                    let w = v.weights
                    if w.x > 0 { seen.insert(j.x) }
                    if w.y > 0 { seen.insert(j.y) }
                    if w.z > 0 { seen.insert(j.z) }
                    if w.w > 0 { seen.insert(j.w) }
                }
            }
        }

        XCTAssertGreaterThan(maxRequired, 256,
                             "Body requiredPaletteSize must include joints above 255, got \(maxRequired)")
        XCTAssertTrue(seen.contains(UInt32(rightLower)),
                      "Body vertices must keep rightLowerLeg palette \(rightLower); sanitized-to-0 freezes the shin")
        XCTAssertTrue(seen.contains(UInt32(rightFoot)),
                      "Body vertices must keep rightFoot palette \(rightFoot)")
        XCTAssertTrue(seen.contains(UInt32(rightToes)),
                      "Body vertices must keep rightToes palette \(rightToes)")
    }
}
