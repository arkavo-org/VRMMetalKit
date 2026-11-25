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
/// Mixamo, Blender, namespace prefixes, and synonyms alongside VRM 1.0 and Unity.
final class VRMABoneHeuristicTests: XCTestCase {

    func testMixamoBoneNames() {
        let cases: [(String, VRMHumanoidBone)] = [
            ("mixamorig:Hips", .hips),
            ("mixamorig:Spine", .spine),
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

    func testNonHumanoidAndLeafEndBonesReturnNil() {
        let ignored = [
            "",
            "mixamorig:HeadTop_End",
            "mixamorig:LeftToe_End",
            "mixamorig:LeftHandThumb1",
            "mixamorig:RightHandIndex2",
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
                "Non-humanoid or leaf bone '\(name)' must not map to a humanoid bone")
        }
    }

    /// End-to-end test loading an animation GLB without `VRMC_vrm_animation`
    /// containing Mixamo-prefixed bones against a VRM 1.0 model.
    func testLoadVRMARetargetsMixamoNamedAnimationOnVRM1Model() async throws {
        let modelData = try VRMBuilder().setSkeleton(.defaultHumanoid).build().serialize()
        let model = try await VRMModel.load(from: modelData, device: nil)

        let glb = try makePlainAnimationGLB(nodeNames: [
            "mixamorig:Hips",
            "mixamorig:LeftArm",
            "mixamorig:LeftForeArm",
            "mixamorig:RightUpLeg",
            "mixamorig:RightLeg",
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixamo-\(UUID().uuidString).vrma")
        try glb.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = try VRMAnimationLoader.loadVRMA(from: url, model: model)
        let mappedBones = Set(clip.jointTracks.map(\.bone))

        XCTAssertTrue(mappedBones.contains(.hips))
        XCTAssertTrue(mappedBones.contains(.leftUpperArm))
        XCTAssertTrue(mappedBones.contains(.leftLowerArm))
        XCTAssertTrue(mappedBones.contains(.rightUpperLeg))
        XCTAssertTrue(mappedBones.contains(.rightLowerLeg))
    }

    /// End-to-end test loading an animation GLB without `VRMC_vrm_animation`
    /// containing Blender `.L`/`.R` and `Armature|` bones against a VRM 1.0 model.
    func testLoadVRMARetargetsBlenderNamedAnimationOnVRM1Model() async throws {
        let modelData = try VRMBuilder().setSkeleton(.defaultHumanoid).build().serialize()
        let model = try await VRMModel.load(from: modelData, device: nil)

        let glb = try makePlainAnimationGLB(nodeNames: [
            "Armature|Hips",
            "arm.L",
            "forearm.R",
            "thigh.R",
            "shin.L",
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blender-\(UUID().uuidString).vrma")
        try glb.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = try VRMAnimationLoader.loadVRMA(from: url, model: model)
        let mappedBones = Set(clip.jointTracks.map(\.bone))

        XCTAssertTrue(mappedBones.contains(.hips))
        XCTAssertTrue(mappedBones.contains(.leftUpperArm))
        XCTAssertTrue(mappedBones.contains(.rightLowerArm))
        XCTAssertTrue(mappedBones.contains(.rightUpperLeg))
        XCTAssertTrue(mappedBones.contains(.leftLowerLeg))
    }

    // MARK: - Helper

    private func makePlainAnimationGLB(nodeNames: [String]) throws -> Data {
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

        let angle: Float = 0.5
        let q = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 0, 1))
        for (i, name) in nodeNames.enumerated() {
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

        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "scene": 0,
            "scenes": [["nodes": Array(0..<nodeNames.count)]],
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
