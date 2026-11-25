//
// Copyright 2026 Arkavo
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

/// Regression tests for issue #135: bone-name fallback heuristics supporting
/// Mixamo, Blender, namespace prefixes, and synonyms alongside VRM 1.0 and Unity,
/// plus deterministic single-track-per-bone resolution without leaf/finger clobbering.
final class VRMABoneHeuristicTests: XCTestCase {

    func testMixamoBoneNames() {
        let cases: [(String, VRMHumanoidBone)] = [
            ("mixamorig:Hips", .hips),
            ("mixamorig:Spine", .spine),
            ("mixamorig:Spine1", .chest),
            ("mixamorig:Spine2", .upperChest),
            ("mixamorig:Chest", .chest),
            ("mixamorig:UpperChest", .upperChest),
            ("mixamorig:Neck", .neck),
            ("mixamorig:Head", .head),
            ("mixamorig:LeftShoulder", .leftShoulder),
            ("mixamorig:LeftArm", .leftUpperArm),
            ("mixamorig:LeftUpperArm", .leftUpperArm),
            ("mixamorig:LeftForeArm", .leftLowerArm),
            ("mixamorig:LeftHand", .leftHand),
            ("mixamorig:RightShoulder", .rightShoulder),
            ("mixamorig:RightArm", .rightUpperArm),
            ("mixamorig:RightForeArm", .rightLowerArm),
            ("mixamorig:RightHand", .rightHand),
            ("mixamorig:LeftUpLeg", .leftUpperLeg),
            ("mixamorig:LeftLeg", .leftLowerLeg),
            ("mixamorig:LeftFoot", .leftFoot),
            ("mixamorig:LeftToeBase", .leftToes),
            ("mixamorig:RightUpLeg", .rightUpperLeg),
            ("mixamorig:RightLeg", .rightLowerLeg),
            ("mixamorig:RightFoot", .rightFoot),
            ("mixamorig:RightToeBase", .rightToes),
            ("mixamorig1:LeftArm", .leftUpperArm),
        ]
        for (name, expected) in cases {
            XCTAssertEqual(VRMAnimationLoader.heuristicBone(forNodeName: name), expected,
                "Expected '\(name)' to map to \(expected)")
        }
    }

    func testBlenderAndSuffixBoneNames() {
        let cases: [(String, VRMHumanoidBone)] = [
            ("Armature|Hips", .hips),
            ("Armature|Pelvis", .hips),
            ("Armature|Spine", .spine),
            ("Armature|Head", .head),
            ("arm.L", .leftUpperArm),
            ("arm.R", .rightUpperArm),
            ("upper_arm.L", .leftUpperArm),
            ("lower_arm.R", .rightLowerArm),
            ("forearm.L", .leftLowerArm),
            ("forearm.R", .rightLowerArm),
            ("hand.L", .leftHand),
            ("hand_r", .rightHand),
            ("shoulder.L", .leftShoulder),
            ("clavicle.R", .rightShoulder),
            ("thigh.L", .leftUpperLeg),
            ("thigh.R", .rightUpperLeg),
            ("shin.L", .leftLowerLeg),
            ("calf.R", .rightLowerLeg),
            ("foot.L", .leftFoot),
            ("foot_r", .rightFoot),
            ("toe.L", .leftToes),
            ("toes_r", .rightToes),
            ("Rig:Armature|thigh.R", .rightUpperLeg),
        ]
        for (name, expected) in cases {
            XCTAssertEqual(VRMAnimationLoader.heuristicBone(forNodeName: name), expected,
                "Expected '\(name)' to map to \(expected)")
        }
    }

    func testVRM1AndUnityBoneNamesPreserved() {
        let cases: [(String, VRMHumanoidBone)] = [
            ("hips", .hips),
            ("spine", .spine),
            ("chest", .chest),
            ("upperChest", .upperChest),
            ("neck", .neck),
            ("head", .head),
            ("leftUpperArm", .leftUpperArm),
            ("leftLowerArm", .leftLowerArm),
            ("leftHand", .leftHand),
            ("rightUpperLeg", .rightUpperLeg),
            ("rightLowerLeg", .rightLowerLeg),
            ("rightFoot", .rightFoot),
            ("rightToes", .rightToes),
            ("J_Bip_C_Hips", .hips),
            ("J_Bip_C_UpperChest", .upperChest),
            ("J_Bip_L_UpperArm", .leftUpperArm),
            ("J_Bip_R_LowerArm", .rightLowerArm),
            ("J_Bip_L_Hand", .leftHand),
            ("J_Bip_R_UpperLeg", .rightUpperLeg),
            ("J_Bip_L_LowerLeg", .leftLowerLeg),
            ("J_Bip_R_Foot", .rightFoot),
            ("J_Bip_L_ToeBase", .leftToes),
        ]
        for (name, expected) in cases {
            XCTAssertEqual(VRMAnimationLoader.heuristicBone(forNodeName: name), expected,
                "Expected '\(name)' to map to \(expected)")
        }
    }

    func testNonHumanoidHelperAndLeafEndBonesReturnNil() {
        let ignored = [
            "",
            "mixamorig:",
            "Armature|",
            "mixamorig:HeadTop_End",
            "mixamorig:LeftToe_End",
            "mixamorig:LeftHandThumb1",
            "mixamorig:RightHandIndex2",
            "toe_end.L",
            "Bip01 HeadNub",
            "upperarm_twist_01_l",
            "calf_twist_01_l",
            "DEF-upper_arm.L.001",
            "hand_ik.L",
            "ik_foot_r",
            "LeftEye",
            "RightEye",
            "Hair_Front_L",
            "J_Sec_L_Bust1",
            "armor.L",
            "leggings.R",
            "Armature",
        ]
        for name in ignored {
            XCTAssertNil(VRMAnimationLoader.heuristicBone(forNodeName: name),
                "Non-humanoid, helper, or leaf bone '\(name)' must not map to a humanoid bone")
        }
    }

    /// End-to-end test loading a full real Mixamo skeleton (`Spine`/`Spine1`/`Spine2`,
    /// `HeadTop_End`, finger sub-bones, helper bones, empty-after-strip prefixes) with
    /// distinct per-node rotations against a VRM 1.0 builder model.
    func testLoadVRMARetargetsFullMixamoRigDeterministicallyOnVRM1Model() async throws {
        let modelData = try VRMBuilder().setSkeleton(.defaultHumanoid).build().serialize()
        let model = try await VRMModel.load(from: modelData, device: nil)

        try assertFullMixamoClipRetargeting(on: model)
    }

    /// Same end-to-end Mixamo rig test against a Unity `J_Bip_*`-named VRM model,
    /// also verifying `mixamorig:Chest` never ambiguously binds to `.upperChest`.
    func testLoadVRMARetargetsMixamoRigDeterministicallyOnUnityNamedModel() async throws {
        let model = try await makeUnityNamedVRM1Model()
        try assertFullMixamoClipRetargeting(on: model)

        let chestAngle: Float = 0.42
        let glb = try makePlainAnimationGLB(nodes: [
            ("mixamorig:Chest", chestAngle),
            ("mixamorig:", 0.99),
            ("e", 0.77),
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixamo-chest-\(UUID().uuidString).vrma")
        try glb.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = try VRMAnimationLoader.loadVRMA(from: url, model: model)
        XCTAssertEqual(clip.jointTracks.count, 1,
            "Only mixamorig:Chest should map to a humanoid track; empty prefix and 1-char names must not")
        XCTAssertEqual(clip.jointTracks.first?.bone, .chest,
            "mixamorig:Chest must deterministically map to .chest (not .upperChest)")
    }

    /// End-to-end test loading an animation GLB without `VRMC_vrm_animation`
    /// containing Blender `.L`/`.R` and `Armature|` bones against a VRM 1.0 model,
    /// asserting exact track count and sampled rotations.
    func testLoadVRMARetargetsBlenderNamedAnimationOnVRM1Model() async throws {
        let modelData = try VRMBuilder().setSkeleton(.defaultHumanoid).build().serialize()
        let model = try await VRMModel.load(from: modelData, device: nil)

        let expectedAngles: [(name: String, bone: VRMHumanoidBone, angle: Float)] = [
            ("Armature|Hips", .hips, 0.15),
            ("arm.L", .leftUpperArm, 0.30),
            ("forearm.R", .rightLowerArm, 0.45),
            ("thigh.R", .rightUpperLeg, 0.60),
            ("shin.L", .leftLowerLeg, 0.75),
            ("hand.L", .leftHand, 0.90),
        ]
        let extraNodes: [(String, Float)] = [
            ("DEF-upper_arm.L.001", 1.20),
            ("hand_ik.L", 1.35),
            ("toe_end.L", 1.50),
            ("Armature|", 1.65),
        ]
        let glb = try makePlainAnimationGLB(
            nodes: expectedAngles.map { ($0.name, $0.angle) } + extraNodes)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blender-\(UUID().uuidString).vrma")
        try glb.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = try VRMAnimationLoader.loadVRMA(from: url, model: model)
        XCTAssertEqual(clip.jointTracks.count, expectedAngles.count,
            "Expected exactly \(expectedAngles.count) humanoid tracks without helper/end duplicates")
        XCTAssertEqual(clip.nodeTracks.count, extraNodes.count,
            "Helper, duplicate, end, and prefix-only nodes must route to non-humanoid tracks")

        let trackByBone = Dictionary(uniqueKeysWithValues: clip.jointTracks.map { ($0.bone, $0) })
        for entry in expectedAngles {
            let track = try XCTUnwrap(trackByBone[entry.bone], "Missing track for \(entry.bone)")
            let sampled = try XCTUnwrap(track.rotationSampler?(1.0))
            let expectedQuat = simd_quatf(angle: entry.angle, axis: SIMD3<Float>(0, 0, 1))
            XCTAssertEqual(abs(simd_dot(sampled.vector, expectedQuat.vector)), 1.0, accuracy: 1e-4,
                "Bone \(entry.bone) sampled wrong rotation (expected angle \(entry.angle))")
        }
    }

    /// Duplicate humanoid candidates for the same bone must be dropped rather
    /// than routed to `nodeTracks`, preventing raw node-name playback from
    /// overwriting the winning retargeted humanoid track.
    func testDuplicateHumanoidCandidatesDoNotOverwriteWinningBoneTrack() async throws {
        let modelData = try VRMBuilder().setSkeleton(.defaultHumanoid).build().serialize()
        let model = try await VRMModel.load(from: modelData, device: nil)

        let headIndex = try XCTUnwrap(model.humanoid?.getBoneNode(.head))
        let headNodeName = try XCTUnwrap(model.nodes[headIndex].name)

        let winnerAngle: Float = 0.35
        let duplicateAngle: Float = 1.40
        // Node 0 maps explicitly to .head via VRMC_vrm_animation (priority 0).
        // Node 1 shares the model's exact head node name (priority 1) and would
        // overwrite the retargeted bone if emitted as a raw NodeTrack.
        let glb = try makePlainAnimationGLB(
            nodes: [
                ("Armature|Head", winnerAngle),
                (headNodeName, duplicateAngle),
            ],
            vrmaHumanBones: ["head": 0]
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-humanoid-\(UUID().uuidString).vrma")
        try glb.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = try VRMAnimationLoader.loadVRMA(from: url, model: model)
        XCTAssertEqual(clip.jointTracks.count, 1)
        XCTAssertTrue(clip.nodeTracks.isEmpty,
            "Losing duplicate humanoid candidate must not be emitted as a raw NodeTrack")

        let player = AnimationPlayer()
        player.load(clip)
        player.isLooping = false
        player.play()
        player.update(deltaTime: 1.0, model: model)

        let expectedQuat = simd_quatf(angle: winnerAngle, axis: SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(abs(simd_dot(model.nodes[headIndex].rotation.vector, expectedQuat.vector)), 1.0, accuracy: 1e-4,
            "Head bone rotation must come from the winning humanoid track, not a raw duplicate NodeTrack")
    }

    // MARK: - Helpers

    private func assertFullMixamoClipRetargeting(on model: VRMModel) throws {
        let expected: [(name: String, bone: VRMHumanoidBone, angle: Float)] = [
            ("mixamorig:Hips", .hips, 0.10),
            ("mixamorig:Spine", .spine, 0.20),
            ("mixamorig:Spine1", .chest, 0.30),
            ("mixamorig:Spine2", .upperChest, 0.40),
            ("mixamorig:Neck", .neck, 0.50),
            ("mixamorig:Head", .head, 0.60),
            ("mixamorig:LeftShoulder", .leftShoulder, 0.70),
            ("mixamorig:LeftArm", .leftUpperArm, 0.80),
            ("mixamorig:LeftForeArm", .leftLowerArm, 0.90),
            ("mixamorig:LeftHand", .leftHand, 1.00),
            ("mixamorig:RightUpLeg", .rightUpperLeg, 1.10),
            ("mixamorig:RightLeg", .rightLowerLeg, 1.20),
            ("mixamorig:RightFoot", .rightFoot, 1.30),
            ("mixamorig:RightToeBase", .rightToes, 1.40),
        ]
        // Leaf, finger, and helper nodes that must NOT clobber head/hand/toes/arm
        let nonHumanoid: [(String, Float)] = [
            ("mixamorig:HeadTop_End", 2.00),
            ("mixamorig:LeftHandThumb1", 2.10),
            ("mixamorig:LeftHandIndex1", 2.20),
            ("mixamorig:RightToe_End", 2.30),
            ("upperarm_twist_01_l", 2.40),
            ("Bip01 HeadNub", 2.50),
        ]

        let glb = try makePlainAnimationGLB(
            nodes: expected.map { ($0.name, $0.angle) } + nonHumanoid)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixamo-full-\(UUID().uuidString).vrma")
        try glb.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = try VRMAnimationLoader.loadVRMA(from: url, model: model)
        XCTAssertEqual(clip.jointTracks.count, expected.count,
            "Expected exactly one track per humanoid bone (\(expected.count)), got \(clip.jointTracks.count)")
        XCTAssertEqual(clip.nodeTracks.count, nonHumanoid.count,
            "Leaf/finger/helper nodes must be routed to nodeTracks, not humanoid tracks")

        let trackByBone = Dictionary(uniqueKeysWithValues: clip.jointTracks.map { ($0.bone, $0) })
        for entry in expected {
            let track = try XCTUnwrap(trackByBone[entry.bone], "Missing track for \(entry.bone)")
            let sampled = try XCTUnwrap(track.rotationSampler?(1.0))
            let expectedQuat = simd_quatf(angle: entry.angle, axis: SIMD3<Float>(0, 0, 1))
            XCTAssertEqual(abs(simd_dot(sampled.vector, expectedQuat.vector)), 1.0, accuracy: 1e-4,
                "Bone \(entry.bone) sampled wrong rotation (expected \(entry.name) angle \(entry.angle))")
        }
    }

    private func makeUnityNamedVRM1Model() async throws -> VRMModel {
        let unityNames: [(VRMHumanoidBone, String)] = [
            (.hips, "J_Bip_C_Hips"),
            (.spine, "J_Bip_C_Spine"),
            (.chest, "J_Bip_C_Chest"),
            (.upperChest, "J_Bip_C_UpperChest"),
            (.neck, "J_Bip_C_Neck"),
            (.head, "J_Bip_C_Head"),
            (.leftShoulder, "J_Bip_L_Shoulder"),
            (.leftUpperArm, "J_Bip_L_UpperArm"),
            (.leftLowerArm, "J_Bip_L_LowerArm"),
            (.leftHand, "J_Bip_L_Hand"),
            (.rightShoulder, "J_Bip_R_Shoulder"),
            (.rightUpperArm, "J_Bip_R_UpperArm"),
            (.rightLowerArm, "J_Bip_R_LowerArm"),
            (.rightHand, "J_Bip_R_Hand"),
            (.leftUpperLeg, "J_Bip_L_UpperLeg"),
            (.leftLowerLeg, "J_Bip_L_LowerLeg"),
            (.leftFoot, "J_Bip_L_Foot"),
            (.leftToes, "J_Bip_L_ToeBase"),
            (.rightUpperLeg, "J_Bip_R_UpperLeg"),
            (.rightLowerLeg, "J_Bip_R_LowerLeg"),
            (.rightFoot, "J_Bip_R_Foot"),
            (.rightToes, "J_Bip_R_ToeBase"),
        ]
        var nodes: [[String: Any]] = []
        var humanBones: [String: Any] = [:]
        for (idx, pair) in unityNames.enumerated() {
            nodes.append(["name": pair.1])
            humanBones[pair.0.rawValue] = ["node": idx]
        }
        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "scene": 0,
            "scenes": [["nodes": Array(0..<nodes.count)]],
            "nodes": nodes,
            "extensionsUsed": ["VRMC_vrm"],
            "extensions": [
                "VRMC_vrm": [
                    "specVersion": "1.0",
                    "meta": [
                        "name": "UnityBoneTest",
                        "authors": ["Test"],
                        "licenseUrl": "https://vrm.dev/licenses/1.0/",
                    ],
                    "humanoid": ["humanBones": humanBones],
                ]
            ],
        ]
        var jsonData = try JSONSerialization.data(withJSONObject: json)
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }

        var glb = Data()
        func appendU32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { glb.append(contentsOf: $0) }
        }
        appendU32(0x46546C67)
        appendU32(2)
        appendU32(UInt32(12 + 8 + jsonData.count))
        appendU32(UInt32(jsonData.count))
        appendU32(0x4E4F534A)
        glb.append(jsonData)
        return try await VRMModel.load(from: glb, device: nil)
    }

    private func makePlainAnimationGLB(
        nodes inputNodes: [(String, Float)],
        vrmaHumanBones: [String: Int] = [:]
    ) throws -> Data {
        var floats: [Float] = []
        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []
        var channels: [[String: Any]] = []
        var samplers: [[String: Any]] = []
        var nodes: [[String: Any]] = []

        func addAccessor(_ values: [Float], type: String, count: Int) -> Int {
            let bvIndex = bufferViews.count
            let offset = floats.count * 4
            floats.append(contentsOf: values)
            bufferViews.append([
                "buffer": 0,
                "byteOffset": offset,
                "byteLength": values.count * 4,
            ])
            let accIndex = accessors.count
            accessors.append([
                "bufferView": bvIndex,
                "componentType": 5126,
                "count": count,
                "type": type,
            ])
            return accIndex
        }

        for (i, (name, angle)) in inputNodes.enumerated() {
            let q = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 0, 1))
            nodes.append(["name": name])
            let timeAcc = addAccessor([0.0, 1.0], type: "SCALAR", count: 2)
            let rotAcc = addAccessor([
                0, 0, 0, 1,
                q.imag.x, q.imag.y, q.imag.z, q.real,
            ], type: "VEC4", count: 2)
            let samplerIndex = samplers.count
            samplers.append([
                "input": timeAcc,
                "output": rotAcc,
                "interpolation": "LINEAR",
            ])
            channels.append([
                "sampler": samplerIndex,
                "target": ["node": i, "path": "rotation"],
            ])
        }

        var bin = Data()
        floats.withUnsafeBytes { bin.append(contentsOf: $0) }
        while bin.count % 4 != 0 { bin.append(0) }

        var json: [String: Any] = [
            "asset": ["version": "2.0"],
            "scene": 0,
            "scenes": [["nodes": Array(0..<inputNodes.count)]],
            "nodes": nodes,
            "buffers": [["byteLength": bin.count]],
            "bufferViews": bufferViews,
            "accessors": accessors,
            "animations": [[
                "name": "HeuristicTest",
                "channels": channels,
                "samplers": samplers,
            ]],
        ]
        if !vrmaHumanBones.isEmpty {
            let mapped = Dictionary(uniqueKeysWithValues: vrmaHumanBones.map { ($0.key, ["node": $0.value]) })
            json["extensionsUsed"] = ["VRMC_vrm_animation"]
            json["extensions"] = [
                "VRMC_vrm_animation": [
                    "specVersion": "1.0",
                    "humanoid": ["humanBones": mapped],
                ]
            ]
        }

        var jsonData = try JSONSerialization.data(withJSONObject: json)
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }

        var glb = Data()
        func appendU32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { glb.append(contentsOf: $0) }
        }
        let total = UInt32(12 + 8 + jsonData.count + 8 + bin.count)
        appendU32(0x46546C67)
        appendU32(2)
        appendU32(total)
        appendU32(UInt32(jsonData.count))
        appendU32(0x4E4F534A)
        glb.append(jsonData)
        appendU32(UInt32(bin.count))
        appendU32(0x004E4942)
        glb.append(bin)
        return glb
    }
}
