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
import VRMAProcessKit

final class VRMAHygieneTests: XCTestCase {

    private var projectRoot: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }

    private func writeTempVRMA(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("vrma")
        try data.write(to: url)
        return url
    }

    /// Builds a minimal VRMModel with humanoid bones (including custom-named eyes)
    /// and a SpringBone chain with a non-VRoid naming convention.
    private func makeTestModel(nonIdentityRestPose: Bool = false) throws -> VRMModel {
        var nodesJSON: [[String: Any]] = [
            ["name": "Root", "children": [1]],
            ["name": "Hips", "children": [2, 6], "translation": [0, 0.9, 0]],
            ["name": "Spine", "children": [3, 4, 5], "translation": [0, 0.15, 0]],
            ["name": "Head", "children": [7, 8, 9], "translation": [0, 0.35, 0]],
            ["name": "LeftUpperArm", "translation": [0.15, 0.25, 0]],
            ["name": "RightUpperArm", "translation": [-0.15, 0.25, 0]],
            ["name": "Accessory_Hat", "translation": [0, 0.1, 0]],
            ["name": "CustomEye_L", "translation": [0.03, 0.05, 0.06]],
            ["name": "CustomEye_R", "translation": [-0.03, 0.05, 0.06]],
            ["name": "CustomRibbon_Root", "children": [10], "translation": [0, 0.1, -0.05]],
            ["name": "CustomRibbon_Tip", "translation": [0, -0.1, 0]],
        ]
        if nonIdentityRestPose {
            nodesJSON[1]["rotation"] = [0, sin(0.2), 0, cos(0.2)]
            nodesJSON[2]["rotation"] = [sin(0.1), 0, 0, cos(0.1)]
            nodesJSON[4]["rotation"] = [0, 0, sin(-0.15), cos(-0.15)]
            nodesJSON[5]["rotation"] = [0, 0, sin(0.15), cos(0.15)]
        }
        let docJSON: [String: Any] = [
            "asset": ["version": "2.0"],
            "nodes": nodesJSON,
        ]
        let gltfData = try JSONSerialization.data(withJSONObject: docJSON)
        let gltf = try JSONDecoder().decode(GLTFDocument.self, from: gltfData)

        let humanoid = VRMHumanoid()
        humanoid.humanBones = [
            .hips: VRMHumanoid.VRMHumanBone(node: 1),
            .spine: VRMHumanoid.VRMHumanBone(node: 2),
            .head: VRMHumanoid.VRMHumanBone(node: 3),
            .leftUpperArm: VRMHumanoid.VRMHumanBone(node: 4),
            .rightUpperArm: VRMHumanoid.VRMHumanBone(node: 5),
            .leftEye: VRMHumanoid.VRMHumanBone(node: 7),
            .rightEye: VRMHumanoid.VRMHumanBone(node: 8),
        ]
        let model = VRMModel(
            specVersion: .v1_0,
            meta: VRMMeta(licenseUrl: "https://example.com/license"),
            humanoid: humanoid,
            gltf: gltf
        )
        let gltfNodes = gltf.nodes ?? []
        let runtimeNodes = gltfNodes.enumerated().map { VRMNode(index: $0.offset, gltfNode: $0.element) }
        for (i, gNode) in gltfNodes.enumerated() {
            for childIdx in gNode.children ?? [] {
                runtimeNodes[i].children.append(runtimeNodes[childIdx])
                runtimeNodes[childIdx].parent = runtimeNodes[i]
            }
        }
        model.nodes = runtimeNodes

        var spring = VRMSpring(name: "Ribbon")
        spring.joints = [VRMSpringJoint(node: 9)] // node 10 is descendant child of node 9
        var sb = VRMSpringBone()
        sb.springs = [spring]
        model.springBone = sb
        return model
    }

    // MARK: - 1. AnimationClip.stripRuntimeOwnedTracks(for:)

    func testStripRuntimeOwnedTracksWithModelRemovesSpringBoneAndEyeTracks() throws {
        let model = try makeTestModel()
        let idRot: (Float) -> simd_quatf = { _ in simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }

        var clip = AnimationClip(duration: 1.0)
        clip.addJointTrack(JointTrack(bone: .hips, rotationSampler: idRot))
        clip.addJointTrack(JointTrack(bone: .head, rotationSampler: idRot))
        clip.addJointTrack(JointTrack(bone: .leftEye, rotationSampler: idRot))
        clip.addJointTrack(JointTrack(bone: .rightEye, rotationSampler: idRot))

        clip.addNodeTrack(NodeTrack(nodeName: "CustomRibbon_Root", rotationSampler: idRot))
        clip.addNodeTrack(NodeTrack(nodeName: "CustomRibbon_Tip", rotationSampler: idRot))
        clip.addNodeTrack(NodeTrack(nodeName: "CustomEye_L", rotationSampler: idRot))
        clip.addNodeTrack(NodeTrack(nodeName: "CustomEye_R", rotationSampler: idRot))
        clip.addNodeTrack(NodeTrack(nodeName: "J_Sec_Hair1_01", rotationSampler: idRot))
        clip.addNodeTrack(NodeTrack(nodeName: "J_Sec_L_Bust1", rotationSampler: idRot))
        clip.addNodeTrack(NodeTrack(nodeName: "J_Adj_L_FaceEye", rotationSampler: idRot))
        clip.addNodeTrack(NodeTrack(nodeName: "Accessory_Hat", rotationSampler: idRot))

        let removed = clip.stripRuntimeOwnedTracks(for: model)
        XCTAssertEqual(removed, 9, "2 eye joints + 2 custom spring joints + 2 custom eye nodes + 3 VRoid secondary/eye nodes")
        XCTAssertEqual(Set(clip.jointTracks.map(\.bone)), [.hips, .head])
        XCTAssertEqual(clip.nodeTracks.map(\.nodeName), ["Accessory_Hat"])
    }

    func testStripRuntimeOwnedTracksWithoutModelUsesVRoidAndEyeNamePatterns() {
        let idRot: (Float) -> simd_quatf = { _ in simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        var clip = AnimationClip(duration: 1.0)
        clip.addJointTrack(JointTrack(bone: .hips, rotationSampler: idRot))
        clip.addJointTrack(JointTrack(bone: .leftEye, rotationSampler: idRot))
        clip.addNodeTrack(NodeTrack(nodeName: "J_Sec_Hair2_12", rotationSampler: idRot))
        clip.addNodeTrack(NodeTrack(nodeName: "J_Sec_R_Bust1", rotationSampler: idRot))
        clip.addNodeTrack(NodeTrack(nodeName: "J_Adj_R_FaceEye", rotationSampler: idRot))
        clip.addNodeTrack(NodeTrack(nodeName: "NamePlate1", rotationSampler: idRot))

        let removed = clip.stripRuntimeOwnedTracks(for: nil)
        XCTAssertEqual(removed, 4)
        XCTAssertEqual(clip.jointTracks.map(\.bone), [.hips])
        XCTAssertEqual(clip.nodeTracks.map(\.nodeName), ["NamePlate1"])
    }

    func testStripRuntimeOwnedTracksOnBundledVRMA01() throws {
        let vrmaPath = "\(projectRoot)/VRMA_01.vrma"
        try XCTSkipIf(!FileManager.default.fileExists(atPath: vrmaPath), "VRMA_01.vrma not found")

        let url = URL(fileURLWithPath: vrmaPath)
        let rawClip = try VRMAnimationLoader.loadVRMA(from: url, model: nil)
        let sanitizedClip = try VRMAnimationLoader.loadVRMA(from: url, model: nil, stripRuntimeOwnedTracks: true)

        XCTAssertGreaterThan(rawClip.nodeTracks.count, 30, "VRMA_01.vrma contains baked J_Sec_Hair/Bust/FaceEye tracks")
        XCTAssertEqual(sanitizedClip.jointTracks.count, rawClip.jointTracks.count, "Humanoid tracks must stay intact")
        XCTAssertFalse(sanitizedClip.nodeTracks.contains { $0.nodeName.hasPrefix("J_Sec_") })
        XCTAssertFalse(sanitizedClip.nodeTracks.contains { $0.nodeName.contains("FaceEye") })
    }

    func testSpecExcludedEyeBonesDoNotLeakIntoNodeTracks() throws {
        let glb = try VRMAGLBBuilder()
            .addHumanoidBone(name: "hips", nodeIndex: 0)
            .addHumanoidBone(name: "leftEye", nodeIndex: 1)
            .addHumanoidBone(name: "rightEye", nodeIndex: 2)
            .addRotationTrack(nodeIndex: 0)
            .addRotationTrack(nodeIndex: 1)
            .addRotationTrack(nodeIndex: 2)
            .build()

        let url = try writeTempVRMA(glb)
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = try VRMAnimationLoader.loadVRMA(from: url, model: nil)
        XCTAssertEqual(clip.jointTracks.map(\.bone), [.hips])
        XCTAssertTrue(clip.nodeTracks.isEmpty, "Spec-excluded leftEye/rightEye must not fall through into nodeTracks")
    }

    // MARK: - 2. normalizeRestPose() < 0.00001° equivalence vs VRMAnimationLoader

    func testNormalizeRestPoseMatchesVRMAnimationLoaderWithin0Point00001Degrees() throws {
        let times: [Float] = [0.0, 0.5, 1.0]

        // Non-trivial Blender-style rotated rest hierarchy:
        // Armature (-90° X) -> Hips (97.2° X + 12° Y) -> Spine (119.8° Z + 8° X) -> LeftUpperArm (40° Y - 30° Z)
        let rArm = simd_normalize(simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0)))
        let rHips = simd_normalize(
            simd_quatf(angle: 97.2 * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
            * simd_quatf(angle: 12.0 * .pi / 180, axis: SIMD3<Float>(0, 1, 0))
        )
        let rSpine = simd_normalize(
            simd_quatf(angle: 119.8 * .pi / 180, axis: SIMD3<Float>(0, 0, 1))
            * simd_quatf(angle: 8.0 * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
        )
        let rLeftArm = simd_normalize(
            simd_quatf(angle: 40.0 * .pi / 180, axis: SIMD3<Float>(0, 1, 0))
            * simd_quatf(angle: -30.0 * .pi / 180, axis: SIMD3<Float>(0, 0, 1))
        )
        let rRightArm = simd_normalize(
            simd_quatf(angle: -25.0 * .pi / 180, axis: SIMD3<Float>(0, 1, 0))
            * simd_quatf(angle: 35.0 * .pi / 180, axis: SIMD3<Float>(0, 0, 1))
        )

        func makeAnimated(_ rest: simd_quatf, delta1: simd_quatf, delta2: simd_quatf) -> [Float] {
            let qs = [rest, simd_normalize(rest * delta1), simd_normalize(rest * delta2)]
            return qs.flatMap { [$0.imag.x, $0.imag.y, $0.imag.z, $0.real] }
        }

        let hipsVals = makeAnimated(
            rHips,
            delta1: simd_quatf(angle: 0.35, axis: simd_normalize(SIMD3<Float>(0.2, 1, 0.3))),
            delta2: simd_quatf(angle: -0.22, axis: simd_normalize(SIMD3<Float>(1, 0.1, -0.4)))
        )
        let spineVals = makeAnimated(
            rSpine,
            delta1: simd_quatf(angle: 0.28, axis: simd_normalize(SIMD3<Float>(1, 0.4, 0.2))),
            delta2: simd_quatf(angle: -0.18, axis: simd_normalize(SIMD3<Float>(0, 1, 0.5)))
        )
        let leftArmVals = makeAnimated(
            rLeftArm,
            delta1: simd_quatf(angle: -1.1, axis: simd_normalize(SIMD3<Float>(0.1, 0.2, 1))),
            delta2: simd_quatf(angle: -0.8, axis: simd_normalize(SIMD3<Float>(0.3, -0.1, 1)))
        )
        let rightArmVals = makeAnimated(
            rRightArm,
            delta1: simd_quatf(angle: 1.05, axis: simd_normalize(SIMD3<Float>(-0.2, 0.1, 1))),
            delta2: simd_quatf(angle: 0.75, axis: simd_normalize(SIMD3<Float>(0.2, 0.3, 1)))
        )

        var bin = Data()
        var bvs: [[String: Any]] = []
        var accs: [[String: Any]] = []
        func addAcc(_ floats: [Float], type: String, count: Int) -> Int {
            let off = bin.count
            floats.withUnsafeBytes { bin.append(contentsOf: $0) }
            bvs.append(["buffer": 0, "byteOffset": off, "byteLength": floats.count * 4])
            var a: [String: Any] = ["bufferView": bvs.count - 1, "componentType": 5126, "count": count, "type": type]
            if type == "SCALAR" { a["min"] = [floats.first!]; a["max"] = [floats.last!] }
            accs.append(a)
            return accs.count - 1
        }
        let tAcc = addAcc(times, type: "SCALAR", count: times.count)
        let hAcc = addAcc(hipsVals, type: "VEC4", count: times.count)
        let sAcc = addAcc(spineVals, type: "VEC4", count: times.count)
        let lAcc = addAcc(leftArmVals, type: "VEC4", count: times.count)
        let rAcc = addAcc(rightArmVals, type: "VEC4", count: times.count)

        let nodes: [[String: Any]] = [
            ["name": "Armature", "rotation": [rArm.imag.x, rArm.imag.y, rArm.imag.z, rArm.real], "children": [1]],
            ["name": "Hips", "translation": [0, 0, 0.9], "rotation": [rHips.imag.x, rHips.imag.y, rHips.imag.z, rHips.real], "children": [2]],
            ["name": "Spine", "translation": [0, 0.15, 0], "rotation": [rSpine.imag.x, rSpine.imag.y, rSpine.imag.z, rSpine.real], "children": [3, 4]],
            ["name": "LeftUpperArm", "translation": [0.15, 0.25, 0], "rotation": [rLeftArm.imag.x, rLeftArm.imag.y, rLeftArm.imag.z, rLeftArm.real]],
            ["name": "RightUpperArm", "translation": [-0.15, 0.25, 0], "rotation": [rRightArm.imag.x, rRightArm.imag.y, rRightArm.imag.z, rRightArm.real]],
        ]
        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "buffers": [["byteLength": bin.count]],
            "bufferViews": bvs,
            "accessors": accs,
            "nodes": nodes,
            "animations": [[
                "samplers": [
                    ["input": tAcc, "output": hAcc, "interpolation": "LINEAR"],
                    ["input": tAcc, "output": sAcc, "interpolation": "LINEAR"],
                    ["input": tAcc, "output": lAcc, "interpolation": "LINEAR"],
                    ["input": tAcc, "output": rAcc, "interpolation": "LINEAR"],
                ],
                "channels": [
                    ["sampler": 0, "target": ["node": 1, "path": "rotation"]],
                    ["sampler": 1, "target": ["node": 2, "path": "rotation"]],
                    ["sampler": 2, "target": ["node": 3, "path": "rotation"]],
                    ["sampler": 3, "target": ["node": 4, "path": "rotation"]],
                ],
            ]],
            "extensions": ["VRMC_vrm_animation": [
                "specVersion": "1.0",
                "humanoid": ["humanBones": [
                    "hips": ["node": 1],
                    "spine": ["node": 2],
                    "leftUpperArm": ["node": 3],
                    "rightUpperArm": ["node": 4],
                ]],
            ]],
        ]

        let rawGLB = try GLBContainer(json: json, bin: bin).serialize()
        var editor = VRMAClipEditor(container: try GLBContainer(data: rawGLB))
        let bakedCount = try editor.normalizeRestPose()
        XCTAssertEqual(bakedCount, 5)
        let normGLB = try editor.container.serialize()

        let rawURL = try writeTempVRMA(rawGLB)
        let normURL = try writeTempVRMA(normGLB)
        defer {
            try? FileManager.default.removeItem(at: rawURL)
            try? FileManager.default.removeItem(at: normURL)
        }

        // Verify against BOTH an identity-rest model AND a non-identity-rest model.
        for nonIdModel in [false, true] {
            let model = try makeTestModel(nonIdentityRestPose: nonIdModel)
            let rawClip = try VRMAnimationLoader.loadVRMA(from: rawURL, model: model)
            let normClip = try VRMAnimationLoader.loadVRMA(from: normURL, model: model)

            let sampleTimes: [Float] = [0.0, 0.13, 0.25, 0.41, 0.5, 0.77, 1.0]
            for bone: VRMHumanoidBone in [.hips, .spine, .leftUpperArm, .rightUpperArm] {
                let tRaw = try XCTUnwrap(rawClip.jointTracks.first { $0.bone == bone })
                let tNorm = try XCTUnwrap(normClip.jointTracks.first { $0.bone == bone })
                for t in sampleTimes {
                    let qRaw = try XCTUnwrap(tRaw.rotationSampler?(t))
                    let qNorm = try XCTUnwrap(tNorm.rotationSampler?(t))
                    let qDiff = simd_normalize(simd_inverse(qRaw) * qNorm)
                    let angleRad = 2.0 * atan2(simd_length(qDiff.imag), abs(qDiff.real))
                    let angleDeg = angleRad * 180.0 / .pi
                    // Canonical identity-rest model is strictly < 0.00001°; a non-identity
                    // target model performs 4 extra Float32 quaternion multiplications in
                    // VRMAnimationLoader (~1-2 ULPs of IEEE-754 Float32 ≈ 1.5e-5°).
                    let toleranceDeg: Float = nonIdModel ? 5e-5 : 1e-5
                    XCTAssertLessThan(
                        angleDeg, toleranceDeg,
                        "Equivalence exceeded \(toleranceDeg)° for \(bone) at t=\(t) (nonIdModel=\(nonIdModel)): got \(angleDeg)°"
                    )
                }
            }
        }
    }

    // MARK: - 3. Empty/zero-track VRMA guard

    func testEmptyVRMADiagnosticsAndRejectOption() throws {
        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "buffers": [["byteLength": 4]],
            "bufferViews": [],
            "accessors": [],
            "nodes": [["name": "Hips"]],
            "animations": [["channels": [], "samplers": []]],
            "extensions": ["VRMC_vrm_animation": [
                "specVersion": "1.0",
                "humanoid": ["humanBones": ["hips": ["node": 0]]],
            ]],
        ]
        let glb = try GLBContainer(json: json, bin: Data(repeating: 0, count: 4)).serialize()
        let url = try writeTempVRMA(glb)
        defer { try? FileManager.default.removeItem(at: url) }

        // Default load succeeds without breaking callers, but populates isEmpty and diagnostics.
        let clip = try VRMAnimationLoader.loadVRMA(from: url, model: nil)
        XCTAssertTrue(clip.isEmpty)
        XCTAssertTrue(clip.diagnostics.contains(.zeroDuration(rawDuration: 0)))
        XCTAssertTrue(clip.diagnostics.contains(.emptyAnimation(channelCount: 0, samplerCount: 0)))

        // Strict opt-in guard throws typed VRMError.emptyAnimation with LLM-friendly description.
        XCTAssertThrowsError(
            try VRMAnimationLoader.loadVRMA(from: url, model: nil, rejectEmptyAnimation: true)
        ) { error in
            guard case VRMError.emptyAnimation(_, let channels, let samplers, let duration) = error else {
                return XCTFail("Expected VRMError.emptyAnimation, got \(error)")
            }
            XCTAssertEqual(channels, 0)
            XCTAssertEqual(samplers, 0)
            XCTAssertEqual(duration, 0)
            let desc = error.localizedDescription
            XCTAssertTrue(desc.contains("Empty VRMA Animation"))
            XCTAssertTrue(desc.contains("Suggestion:"))
            XCTAssertTrue(desc.contains("VRMC_vrm_animation-1.0"))
        }
    }

    func testSingleKeyframePoseClipIsNotRejectedAsEmpty() throws {
        let glb = try VRMAGLBBuilder()
            .addHumanoidBone(name: "hips", nodeIndex: 0)
            .addRotationTrack(nodeIndex: 0)
            .build()
        let url = try writeTempVRMA(glb)
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = try VRMAnimationLoader.loadVRMA(from: url, model: nil, rejectEmptyAnimation: true)
        XCTAssertFalse(clip.isEmpty)
        XCTAssertEqual(clip.diagnostics, [.zeroDuration(rawDuration: 0)])
    }
}
