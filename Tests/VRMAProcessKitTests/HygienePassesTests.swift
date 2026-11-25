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
@testable import VRMAProcessKit

final class HygienePassesTests: XCTestCase {

    // MARK: - Helpers

    private struct TrackSpec {
        let node: Int
        let path: String
        let times: [Float]
        let values: [Float]
        let type: String
        let interpolation: String

        init(node: Int, path: String, times: [Float], values: [Float], type: String, interpolation: String = "LINEAR") {
            self.node = node
            self.path = path
            self.times = times
            self.values = values
            self.type = type
            self.interpolation = interpolation
        }
    }

    private func buildVRMA(
        nodes: [[String: Any]],
        humanBones: [String: Int],
        presetExpressions: [String: Int] = [:],
        customExpressions: [String: Int] = [:],
        lookAtNode: Int? = nil,
        tracks: [TrackSpec]
    ) throws -> GLBContainer {
        var bin = Data()
        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []
        var samplers: [[String: Any]] = []
        var channels: [[String: Any]] = []

        func appendAccessor(_ floats: [Float], type: String, count: Int) -> Int {
            while bin.count % 4 != 0 { bin.append(0) }
            let off = bin.count
            floats.withUnsafeBytes { bin.append(contentsOf: $0) }
            bufferViews.append(["buffer": 0, "byteOffset": off, "byteLength": floats.count * 4])
            var acc: [String: Any] = [
                "bufferView": bufferViews.count - 1,
                "componentType": 5126,
                "count": count,
                "type": type,
            ]
            if type == "SCALAR", let first = floats.first, let last = floats.last {
                acc["min"] = [first]
                acc["max"] = [last]
            }
            accessors.append(acc)
            return accessors.count - 1
        }

        for track in tracks {
            let inAcc = appendAccessor(track.times, type: "SCALAR", count: track.times.count)
            let comps = track.type == "VEC4" ? 4 : (track.type == "VEC3" ? 3 : 1)
            let outAcc = appendAccessor(track.values, type: track.type, count: track.values.count / comps)
            let sIdx = samplers.count
            samplers.append(["input": inAcc, "output": outAcc, "interpolation": track.interpolation])
            channels.append(["sampler": sIdx, "target": ["node": track.node, "path": track.path]])
        }

        var hbDict: [String: Any] = [:]
        for (name, idx) in humanBones { hbDict[name] = ["node": idx] }
        var vrmaExt: [String: Any] = [
            "specVersion": "1.0",
            "humanoid": ["humanBones": hbDict],
        ]
        var exprDict: [String: Any] = [:]
        if !presetExpressions.isEmpty {
            var preset: [String: Any] = [:]
            for (k, v) in presetExpressions { preset[k] = ["node": v] }
            exprDict["preset"] = preset
        }
        if !customExpressions.isEmpty {
            var custom: [String: Any] = [:]
            for (k, v) in customExpressions { custom[k] = ["node": v] }
            exprDict["custom"] = custom
        }
        if !exprDict.isEmpty { vrmaExt["expressions"] = exprDict }
        if let la = lookAtNode { vrmaExt["lookAt"] = ["node": la] }

        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "buffers": [["byteLength": max(bin.count, 1)]],
            "bufferViews": bufferViews,
            "accessors": accessors,
            "nodes": nodes,
            "animations": [["channels": channels, "samplers": samplers]],
            "extensions": ["VRMC_vrm_animation": vrmaExt],
        ]
        if bin.isEmpty { bin.append(0) }
        return try GLBContainer(data: try GLBContainer(json: json, bin: bin).serialize())
    }

    private func quatFloats(_ quats: [simd_quatf]) -> [Float] {
        quats.flatMap { [$0.imag.x, $0.imag.y, $0.imag.z, $0.real] }
    }

    // MARK: - 1. Expression & lookAt preservation in stripNonHumanoidChannels

    func testStripNonHumanoidPreservesExpressionsAndLookAt() throws {
        let times: [Float] = [0, 0.5, 1.0]
        let idQ = quatFloats([
            simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
        ])
        let exprVals: [Float] = [0, 0, 0, 0.8, 0, 0, 0, 0, 0]
        let lookVals: [Float] = [0, 0, 1, 0.3, 0, 1, 0, 0, 1]

        let nodes: [[String: Any]] = [
            ["name": "Hips"],               // 0 - humanoid
            ["name": "Expr_Happy"],         // 1 - preset expression
            ["name": "Expr_CustomWink"],    // 2 - custom expression
            ["name": "LookAtTarget"],       // 3 - lookAt
            ["name": "J_Sec_Hair1_01"],     // 4 - baked hair (drop)
            ["name": "Prop_Sword"],         // 5 - accessory (drop)
        ]

        let container = try buildVRMA(
            nodes: nodes,
            humanBones: ["hips": 0],
            presetExpressions: ["happy": 1],
            customExpressions: ["wink": 2],
            lookAtNode: 3,
            tracks: [
                TrackSpec(node: 0, path: "rotation", times: times, values: idQ, type: "VEC4"),
                TrackSpec(node: 1, path: "translation", times: times, values: exprVals, type: "VEC3"),
                TrackSpec(node: 2, path: "translation", times: times, values: exprVals, type: "VEC3"),
                TrackSpec(node: 3, path: "translation", times: times, values: lookVals, type: "VEC3"),
                TrackSpec(node: 4, path: "rotation", times: times, values: idQ, type: "VEC4"),
                TrackSpec(node: 5, path: "rotation", times: times, values: idQ, type: "VEC4"),
            ]
        )

        var editor = VRMAClipEditor(container: container)
        let dropped = try editor.stripNonHumanoidChannels()
        XCTAssertEqual(dropped, 2, "Only hair and accessory channels should be dropped")

        let anim = (editor.container.json["animations"] as! [[String: Any]])[0]
        let remainingNodes = Set((anim["channels"] as! [[String: Any]]).compactMap {
            ($0["target"] as? [String: Any])?["node"] as? Int
        })
        XCTAssertEqual(remainingNodes, [0, 1, 2, 3], "Humanoid, preset/custom expressions, and lookAt must survive")
    }

    // MARK: - 2. stripEyeChannels

    func testStripEyeChannelsDropsConstantKeepsAnimatedByDefault() throws {
        let times: [Float] = [0, 0.5, 1.0]
        let constIdentity = quatFloats([
            simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            simd_quatf(ix: 0, iy: 0, iz: 0, r: -1), // antipodal same rotation!
            simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
        ])
        let animatedEye = quatFloats([
            simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            simd_quatf(angle: 0.25, axis: SIMD3<Float>(0, 1, 0)),
            simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
        ])
        let constNonIdentity = quatFloats(Array(repeating: simd_quatf(angle: 0.1, axis: SIMD3<Float>(1, 0, 0)), count: 3))

        let nodes: [[String: Any]] = [
            ["name": "Hips"],
            ["name": "LeftEye"],
            ["name": "RightEye"],
            ["name": "J_Adj_L_FaceEye"],
        ]

        let container = try buildVRMA(
            nodes: nodes,
            humanBones: ["hips": 0, "leftEye": 1, "rightEye": 2],
            tracks: [
                TrackSpec(node: 0, path: "rotation", times: times, values: constIdentity, type: "VEC4"),
                TrackSpec(node: 1, path: "rotation", times: times, values: constIdentity, type: "VEC4"),
                TrackSpec(node: 2, path: "rotation", times: times, values: animatedEye, type: "VEC4"),
                TrackSpec(node: 3, path: "rotation", times: times, values: constNonIdentity, type: "VEC4"),
            ]
        )

        // onlyIfConstant: true drops constant leftEye (1) and constant J_Adj_L_FaceEye (3), keeps animated rightEye (2)
        var editor1 = VRMAClipEditor(container: container)
        let droppedConst = try editor1.stripEyeChannels(onlyIfConstant: true)
        XCTAssertEqual(droppedConst, 2)
        let rem1 = Set((((editor1.container.json["animations"] as! [[String: Any]])[0]["channels"] as! [[String: Any]])).compactMap {
            ($0["target"] as? [String: Any])?["node"] as? Int
        })
        XCTAssertEqual(rem1, [0, 2])

        // onlyIfConstant: false drops all three eye channels
        var editor2 = VRMAClipEditor(container: container)
        let droppedAll = try editor2.stripEyeChannels(onlyIfConstant: false)
        XCTAssertEqual(droppedAll, 3)
        let rem2 = Set((((editor2.container.json["animations"] as! [[String: Any]])[0]["channels"] as! [[String: Any]])).compactMap {
            ($0["target"] as? [String: Any])?["node"] as? Int
        })
        XCTAssertEqual(rem2, [0])
    }

    // MARK: - 3. normalizeRestPose

    func testNormalizeRestPoseBakesRotationsUpdatesTranslationsAndHemisphere() throws {
        let times: [Float] = [0, 0.5, 1.0]
        let armRest = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
        let hipsRest = simd_quatf(angle: 97.2 * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
        let spineRest = simd_quatf(angle: 25.0 * .pi / 180, axis: SIMD3<Float>(0, 0, 1))

        // Deliberately flip the sign of keyframe 1 to test hemisphere continuity enforcement.
        let qH0 = hipsRest
        let qH1 = -(hipsRest * simd_quatf(angle: 0.2, axis: SIMD3<Float>(0, 1, 0)))
        let qH2 = hipsRest * simd_quatf(angle: 0.4, axis: SIMD3<Float>(0, 1, 0))

        let qS0 = spineRest
        let qS1 = spineRest * simd_quatf(angle: -0.15, axis: SIMD3<Float>(1, 0, 0))
        let qS2 = spineRest

        let nodes: [[String: Any]] = [
            [
                "name": "Armature",
                "rotation": [armRest.imag.x, armRest.imag.y, armRest.imag.z, armRest.real],
                "children": [1],
            ],
            [
                "name": "Hips",
                "translation": [0.0, 0.0, 0.9], // in -90° X Armature frame, +Z maps to +Y (0, 0.9, 0)!
                "rotation": [hipsRest.imag.x, hipsRest.imag.y, hipsRest.imag.z, hipsRest.real],
                "children": [2],
            ],
            [
                "name": "Spine",
                "translation": [0.0, 0.15, 0.0],
                "rotation": [spineRest.imag.x, spineRest.imag.y, spineRest.imag.z, spineRest.real],
            ],
        ]

        let container = try buildVRMA(
            nodes: nodes,
            humanBones: ["hips": 1, "spine": 2],
            tracks: [
                TrackSpec(node: 1, path: "rotation", times: times, values: quatFloats([qH0, qH1, qH2]), type: "VEC4"),
                TrackSpec(node: 2, path: "rotation", times: times, values: quatFloats([qS0, qS1, qS2]), type: "VEC4"),
                TrackSpec(node: 1, path: "translation", times: times, values: [0, 0, 0.9, 0, 0, 0.92, 0, 0, 0.9], type: "VEC3"),
            ]
        )

        var editor = VRMAClipEditor(container: container)
        let normalizedCount = try editor.normalizeRestPose()
        XCTAssertEqual(normalizedCount, 3, "Armature, Hips, and Spine should all be normalized")

        // Second pass must be idempotent (0 nodes changed).
        XCTAssertEqual(try editor.normalizeRestPose(), 0)

        let outNodes = editor.container.json["nodes"] as! [[String: Any]]
        for idx in 0..<3 {
            XCTAssertNil(outNodes[idx]["rotation"], "Node \(idx) rest rotation should be canonical identity")
        }

        // Hips translation was [0, 0, 0.9] under -90° X Armature -> world [0, +0.9, 0].
        let hipsT = (outNodes[1]["translation"] as! [NSNumber]).map(\.floatValue)
        XCTAssertEqual(hipsT[0], 0, accuracy: 1e-5)
        XCTAssertEqual(hipsT[1], 0.9, accuracy: 1e-5)
        XCTAssertEqual(hipsT[2], 0, accuracy: 1e-5)

        // Inspector's hipsRestHeight should now read +0.9m in canonical Y-up space!
        let inspector = try VRMAClipInspector(container: editor.container)
        XCTAssertEqual(try inspector.hipsRestHeight(), 0.9, accuracy: 1e-4)

        // Hemisphere continuity on hips rotation track: every consecutive dot >= 0.
        let anim = (editor.container.json["animations"] as! [[String: Any]])[0]
        let channels = anim["channels"] as! [[String: Any]]
        let samplers = anim["samplers"] as! [[String: Any]]
        let hipsRotCh = channels.first {
            let t = $0["target"] as! [String: Any]
            return t["node"] as? Int == 1 && t["path"] as? String == "rotation"
        }!
        let outAcc = samplers[hipsRotCh["sampler"] as! Int]["output"] as! Int
        let vals = try inspector.floats(accessor: outAcc)
        for k in 1..<(vals.count / 4) {
            let dot = vals[(k - 1) * 4] * vals[k * 4]
                + vals[(k - 1) * 4 + 1] * vals[k * 4 + 1]
                + vals[(k - 1) * 4 + 2] * vals[k * 4 + 2]
                + vals[(k - 1) * 4 + 3] * vals[k * 4 + 3]
            XCTAssertGreaterThanOrEqual(dot, 0, "Consecutive keyframes must stay in the same hemisphere")
        }

        // At rest keyframe k=0 (where Q(0) == L_A), normalized rotation must be identity!
        XCTAssertEqual(abs(vals[3]), 1.0, accuracy: 1e-6)
    }

    // MARK: - 4. enforceMinimumArmAbduction

    func testEnforceMinimumArmAbductionFloorsHangingArmsPreservesLoopAndRaisedGestures() throws {
        // Hanging arm at 6° outward abduction:
        // Left arm rest = +X, rotate by -(90° - 6°) = -84° around +Z -> hangs down with 6° outward (+X)
        // Right arm rest = -X, rotate by +(90° - 6°) = +84° around +Z -> hangs down with 6° outward (-X)
        let n = 31
        var times: [Float] = []
        var leftQuats: [simd_quatf] = []
        var rightQuats: [simd_quatf] = []
        for i in 0..<n {
            let t = Float(i) / Float(n - 1)
            times.append(t)
            let swayDeg: Float = 2.0 * sin(2 * .pi * t) // 4°..8° loop-continuous
            let abdRad = (6.0 + swayDeg) * .pi / 180.0
            let leftAngle = -(.pi / 2 - abdRad)
            let rightAngle = (.pi / 2 - abdRad)
            leftQuats.append(simd_quatf(angle: leftAngle, axis: SIMD3<Float>(0, 0, 1)))
            rightQuats.append(simd_quatf(angle: rightAngle, axis: SIMD3<Float>(0, 0, 1)))
        }

        let nodes: [[String: Any]] = [
            ["name": "Hips"],
            ["name": "LeftUpperArm"],
            ["name": "RightUpperArm"],
        ]
        let container = try buildVRMA(
            nodes: nodes,
            humanBones: ["hips": 0, "leftUpperArm": 1, "rightUpperArm": 2],
            tracks: [
                TrackSpec(node: 1, path: "rotation", times: times, values: quatFloats(leftQuats), type: "VEC4"),
                TrackSpec(node: 2, path: "rotation", times: times, values: quatFloats(rightQuats), type: "VEC4"),
            ]
        )

        var editor = VRMAClipEditor(container: container)
        let modified = try editor.enforceMinimumArmAbduction(minDegrees: 18.0)
        XCTAssertEqual(modified, 2, "Both narrow hanging arms should be adjusted")

        let inspector = try VRMAClipInspector(container: editor.container)
        let anim = (editor.container.json["animations"] as! [[String: Any]])[0]
        let channels = anim["channels"] as! [[String: Any]]
        let samplers = anim["samplers"] as! [[String: Any]]

        for (nodeIdx, sign) in [(1, Float(1)), (2, Float(-1))] {
            let ch = channels.first { ($0["target"] as! [String: Any])["node"] as? Int == nodeIdx }!
            let vals = try inspector.floats(accessor: samplers[ch["sampler"] as! Int]["output"] as! Int)
            var alphas: [Float] = []
            for k in 0..<n {
                let q = simd_quatf(ix: vals[k * 4], iy: vals[k * 4 + 1], iz: vals[k * 4 + 2], r: vals[k * 4 + 3])
                let d = q.act(SIMD3<Float>(sign, 0, 0))
                let alphaDeg = atan2(sign * d.x, -d.y) * 180 / .pi
                alphas.append(alphaDeg)
                XCTAssertGreaterThanOrEqual(alphaDeg, 17.99, "Frame \(k) abduction must meet 18° floor")
            }
            // Loop continuity: first and last frames match!
            XCTAssertEqual(alphas.first!, alphas.last!, accuracy: 1e-4, "Abduction floor must preserve loop continuity")
        }
    }

    func testEnforceMinimumArmAbductionLeavesRaisedGesturesUntouched() throws {
        let times: [Float] = [0, 0.5, 1.0]
        // Raised wave: +45° around +Z for left arm -> pointing up & outward (dir.y > 0)
        // Horizontal T-pose: 0° -> dir.y == 0
        let leftRaised = [
            simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 0, 1)),
            simd_quatf(angle: .pi / 3, axis: SIMD3<Float>(0, 0, 1)),
        ]
        // Right arm hanging wide at 35° (well above 18° + 6° transition band)
        let rightWide = Array(repeating: simd_quatf(angle: (90.0 - 35.0) * .pi / 180.0, axis: SIMD3<Float>(0, 0, 1)), count: 3)

        let nodes: [[String: Any]] = [
            ["name": "Hips"],
            ["name": "LeftUpperArm"],
            ["name": "RightUpperArm"],
        ]
        let container = try buildVRMA(
            nodes: nodes,
            humanBones: ["hips": 0, "leftUpperArm": 1, "rightUpperArm": 2],
            tracks: [
                TrackSpec(node: 1, path: "rotation", times: times, values: quatFloats(leftRaised), type: "VEC4"),
                TrackSpec(node: 2, path: "rotation", times: times, values: quatFloats(rightWide), type: "VEC4"),
            ]
        )

        var editor = VRMAClipEditor(container: container)
        let modified = try editor.enforceMinimumArmAbduction(minDegrees: 18.0)
        XCTAssertEqual(modified, 0, "Raised gestures and already-wide arms must not be disturbed")
    }

    func testEnforceMinimumArmAbductionIsC1SmoothAndMonotonic() throws {
        // Sweep abduction linearly from 0° to 35° in 0.5° increments and check
        // monotonicity and C¹ smoothness of the output curve.
        let steps = 71
        var times: [Float] = []
        var quats: [simd_quatf] = []
        for i in 0..<steps {
            let deg = Float(i) * 0.5
            times.append(Float(i) / 30.0)
            let angle = -(.pi / 2 - deg * .pi / 180.0)
            quats.append(simd_quatf(angle: angle, axis: SIMD3<Float>(0, 0, 1)))
        }

        let container = try buildVRMA(
            nodes: [["name": "Hips"], ["name": "LeftUpperArm"]],
            humanBones: ["hips": 0, "leftUpperArm": 1],
            tracks: [TrackSpec(node: 1, path: "rotation", times: times, values: quatFloats(quats), type: "VEC4")]
        )

        var editor = VRMAClipEditor(container: container)
        XCTAssertEqual(try editor.enforceMinimumArmAbduction(minDegrees: 18.0), 1)

        let inspector = try VRMAClipInspector(container: editor.container)
        let anim = (editor.container.json["animations"] as! [[String: Any]])[0]
        let outAcc = ((anim["samplers"] as! [[String: Any]])[0]["output"] as! Int)
        let vals = try inspector.floats(accessor: outAcc)

        var outDegs: [Float] = []
        for k in 0..<steps {
            let q = simd_quatf(ix: vals[k * 4], iy: vals[k * 4 + 1], iz: vals[k * 4 + 2], r: vals[k * 4 + 3])
            let d = q.act(SIMD3<Float>(1, 0, 0))
            outDegs.append(atan2(d.x, -d.y) * 180 / .pi)
        }

        for k in 0..<steps {
            XCTAssertGreaterThanOrEqual(outDegs[k], 17.99, "Every swept angle must be >= 18°")
            if k > 0 {
                XCTAssertGreaterThanOrEqual(outDegs[k], outDegs[k - 1] - 1e-4, "Floor output must be monotonically non-decreasing")
            }
            // Above 18° + 6° = 24°, output must match input exactly.
            let inDeg = Float(k) * 0.5
            if inDeg >= 24.0 {
                XCTAssertEqual(outDegs[k], inDeg, accuracy: 1e-3)
            }
        }
        // Second difference bounded -> no C0 kink in slope.
        for k in 1..<(steps - 1) {
            let d2 = abs((outDegs[k + 1] - outDegs[k]) - (outDegs[k] - outDegs[k - 1]))
            XCTAssertLessThan(d2, 0.05, "Second difference at step \(k) should stay smooth (C¹)")
        }
    }

    func testEnforceMinimumArmAbductionRejectsInvalidDegrees() throws {
        let container = try GLBContainer(data: try SyntheticVRMA.make())
        var editor = VRMAClipEditor(container: container)
        XCTAssertThrowsError(try editor.enforceMinimumArmAbduction(minDegrees: -5))
        XCTAssertThrowsError(try editor.enforceMinimumArmAbduction(minDegrees: 90))
        XCTAssertThrowsError(try editor.enforceMinimumArmAbduction(minDegrees: .nan))
        XCTAssertThrowsError(try editor.enforceMinimumArmAbduction(minDegrees: .infinity))
        XCTAssertEqual(try editor.enforceMinimumArmAbduction(minDegrees: 0), 0)
    }

    // MARK: - 5. Empty VRMA diagnostics & ingest guard

    func testDiagnoseDetectsEmptyAndZeroDurationClip() throws {
        let emptyContainer = try buildVRMA(
            nodes: [["name": "Hips"]],
            humanBones: ["hips": 0],
            tracks: []
        )
        let issues = VRMAClipInspector.diagnose(container: emptyContainer)
        XCTAssertTrue(issues.contains(.emptyAnimation(channelCount: 0, samplerCount: 0)))
        XCTAssertTrue(issues.contains(.zeroDuration(rawDuration: 0)))

        let glb = try emptyContainer.serialize()
        XCTAssertThrowsError(try LocomotionIngest.process(glb: glb, mode: .auto)) { error in
            guard case LocomotionIngest.IngestError.emptyAnimation = error else {
                return XCTFail("Expected IngestError.emptyAnimation, got \(error)")
            }
        }
        XCTAssertThrowsError(try LocomotionIngest.processHygiene(glb: glb)) { error in
            guard case LocomotionIngest.IngestError.emptyAnimation = error else {
                return XCTFail("Expected IngestError.emptyAnimation, got \(error)")
            }
        }
    }

    func testProcessHygienePreservesHipsMotionAndStripsNoise() throws {
        let glb = try SyntheticVRMA.make(duration: 2.0, vx: 1.5, includeHairTrack: true)
        let out = try LocomotionIngest.processHygiene(glb: glb)
        let container = try GLBContainer(data: out)
        let inspector = try VRMAClipInspector(container: container)
        // Hips XZ travel preserved (not stripped in hygiene-only mode)
        XCTAssertEqual(try inspector.meanHipsXZSpeed(), 1.5, accuracy: 0.05)
        // No locomotion extras stamped
        XCTAssertNil(LocomotionExtras.read(from: container))
        // Hair track stripped
        let issues = inspector.diagnose()
        XCTAssertTrue(issues.isEmpty, "Hygiene-processed clip should have zero issues, got \(issues)")
    }
}
