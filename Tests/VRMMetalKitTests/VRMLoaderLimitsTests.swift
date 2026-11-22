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
import Metal
@testable import VRMMetalKit
@testable import GLTFCore

/// Tests for issue #179: configurable `VRMLoaderLimits` across all six quota sites.
final class VRMLoaderLimitsTests: XCTestCase {

    // MARK: - Presets & Error Description

    func testPresetsAndOrdering() {
        let strict = VRMLoaderLimits.strict
        let def = VRMLoaderLimits.default
        let permissive = VRMLoaderLimits.permissive

        XCTAssertLessThan(strict.maxAccessorElements, def.maxAccessorElements)
        XCTAssertLessThan(def.maxAccessorElements, permissive.maxAccessorElements)

        XCTAssertLessThan(strict.maxTotalBufferBytes, def.maxTotalBufferBytes)
        XCTAssertLessThan(def.maxTotalBufferBytes, permissive.maxTotalBufferBytes)

        XCTAssertLessThan(strict.maxAnimationSamplers, def.maxAnimationSamplers)
        XCTAssertLessThan(def.maxAnimationSamplers, permissive.maxAnimationSamplers)

        XCTAssertLessThan(strict.maxKeyframesPerSampler, def.maxKeyframesPerSampler)
        XCTAssertLessThan(def.maxKeyframesPerSampler, permissive.maxKeyframesPerSampler)

        XCTAssertLessThan(strict.maxSpringBones, def.maxSpringBones)
        XCTAssertLessThan(def.maxSpringBones, permissive.maxSpringBones)

        XCTAssertLessThan(strict.maxCustomExpressions, def.maxCustomExpressions)
        XCTAssertLessThan(def.maxCustomExpressions, permissive.maxCustomExpressions)

        XCTAssertEqual(VRMLoadingOptions.default.limits, .default)
    }

    func testLimitExceededErrorDescription() {
        let error = VRMError.limitExceeded(kind: "springBones", limit: 1, observed: 4)
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains("springBones"))
        XCTAssertTrue(desc.contains("1"))
        XCTAssertTrue(desc.contains("4"))
        XCTAssertTrue(desc.contains("VRMLoaderLimits"))
    }

    // MARK: - 1. maxAccessorElements

    func testMaxAccessorElementsRejectsAtOneAndAcceptsAtMax() async throws {
        let glb = try makeMinimalVRMWithTriangle()

        var tight = VRMLoaderLimits.default
        tight.maxAccessorElements = 1
        do {
            _ = try await VRMModel.load(from: glb, limits: tight)
            XCTFail("Expected VRMError.limitExceeded for maxAccessorElements=1")
        } catch VRMError.limitExceeded(let kind, let limit, let observed) {
            XCTAssertEqual(kind, "accessorElements")
            XCTAssertEqual(limit, 1)
            XCTAssertGreaterThan(observed, 1)
        }

        // Parallel mesh loading must also enforce the limit rather than swallowing it.
        do {
            let options = VRMLoadingOptions(optimizations: [.parallelMeshLoading], limits: tight)
            _ = try await VRMModel.load(from: glb, options: options)
            XCTFail("Expected VRMError.limitExceeded with parallelMeshLoading")
        } catch VRMError.limitExceeded(let kind, _, _) {
            XCTAssertEqual(kind, "accessorElements")
        }

        var unlimited = VRMLoaderLimits.default
        unlimited.maxAccessorElements = Int.max
        let model = try await VRMModel.load(from: glb, limits: unlimited)
        XCTAssertEqual(model.meshes.count, 1)
    }

    // MARK: - 2. maxTotalBufferBytes

    func testMaxTotalBufferBytesRejectsAtOneAndAcceptsAtMax() async throws {
        let glb = try makeMinimalVRMWithTriangle()

        var tight = VRMLoaderLimits.default
        tight.maxTotalBufferBytes = 1
        do {
            _ = try await VRMModel.load(from: glb, limits: tight)
            XCTFail("Expected VRMError.limitExceeded for maxTotalBufferBytes=1")
        } catch VRMError.limitExceeded(let kind, let limit, let observed) {
            XCTAssertEqual(kind, "totalBufferBytes")
            XCTAssertEqual(limit, 1)
            XCTAssertGreaterThan(observed, 1)
        }

        var unlimited = VRMLoaderLimits.default
        unlimited.maxTotalBufferBytes = Int.max
        let model = try await VRMModel.load(from: glb, limits: unlimited)
        XCTAssertEqual(model.meshes.count, 1)
    }

    func testBufferLoaderDirectEnforcesLimits() throws {
        let bytes = Data(repeating: 0, count: 36) // 3 VEC3 floats = 9 elements
        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "buffers": [["byteLength": bytes.count]],
            "bufferViews": [["buffer": 0, "byteOffset": 0, "byteLength": bytes.count]],
            "accessors": [[
                "bufferView": 0, "byteOffset": 0,
                "componentType": 5126, "count": 3, "type": "VEC3"
            ]]
        ]
        let doc = try JSONDecoder().decode(GLTFDocument.self, from: JSONSerialization.data(withJSONObject: json))

        var elemTight = VRMLoaderLimits.default
        elemTight.maxAccessorElements = 1
        let elemLoader = BufferLoader(document: doc, binaryData: bytes, limits: elemTight)
        XCTAssertThrowsError(try elemLoader.loadAccessorAsFloat(0)) { error in
            guard case GLTFError.limitExceeded(let kind, let limit, let observed) = error else {
                return XCTFail("Expected GLTFError.limitExceeded, got \(error)")
            }
            XCTAssertEqual(kind, "accessorElements")
            XCTAssertEqual(limit, 1)
            XCTAssertEqual(observed, 9)
        }

        var byteTight = VRMLoaderLimits.default
        byteTight.maxTotalBufferBytes = 1
        let byteLoader = BufferLoader(document: doc, binaryData: bytes, limits: byteTight)
        XCTAssertThrowsError(try byteLoader.loadAccessorAsFloat(0)) { error in
            guard case GLTFError.limitExceeded(let kind, let limit, let observed) = error else {
                return XCTFail("Expected GLTFError.limitExceeded, got \(error)")
            }
            XCTAssertEqual(kind, "totalBufferBytes")
            XCTAssertEqual(limit, 1)
            XCTAssertEqual(observed, 36)
        }
    }

    // MARK: - 3. maxAnimationSamplers

    func testMaxAnimationSamplersRejectsAtOneAndAcceptsAtMax() throws {
        let url = try writeSyntheticVRMA(samplerCount: 2, keyframeCount: 3)
        defer { try? FileManager.default.removeItem(at: url) }

        var tight = VRMLoaderLimits.default
        tight.maxAnimationSamplers = 1
        XCTAssertThrowsError(try VRMAnimationLoader.loadVRMA(from: url, limits: tight)) { error in
            guard case VRMError.limitExceeded(let kind, let limit, let observed) = error else {
                return XCTFail("Expected VRMError.limitExceeded, got \(error)")
            }
            XCTAssertEqual(kind, "animationSamplers")
            XCTAssertEqual(limit, 1)
            XCTAssertEqual(observed, 2)
        }

        var unlimited = VRMLoaderLimits.default
        unlimited.maxAnimationSamplers = Int.max
        let clip = try VRMAnimationLoader.loadVRMA(from: url, limits: unlimited)
        XCTAssertGreaterThan(clip.duration, 0)
    }

    // MARK: - 4. maxKeyframesPerSampler

    func testMaxKeyframesPerSamplerRejectsAtOneAndAcceptsAtMax() throws {
        let url = try writeSyntheticVRMA(samplerCount: 1, keyframeCount: 4)
        defer { try? FileManager.default.removeItem(at: url) }

        var tight = VRMLoaderLimits.default
        tight.maxKeyframesPerSampler = 1
        XCTAssertThrowsError(try VRMAnimationLoader.loadVRMA(from: url, limits: tight)) { error in
            guard case VRMError.limitExceeded(let kind, let limit, let observed) = error else {
                return XCTFail("Expected VRMError.limitExceeded, got \(error)")
            }
            XCTAssertEqual(kind, "keyframesPerSampler")
            XCTAssertEqual(limit, 1)
            XCTAssertEqual(observed, 4)
        }

        var unlimited = VRMLoaderLimits.default
        unlimited.maxKeyframesPerSampler = Int.max
        let clip = try VRMAnimationLoader.loadVRMA(from: url, limits: unlimited)
        XCTAssertGreaterThan(clip.duration, 0)
    }

    // MARK: - 5. maxSpringBones

    func testMaxSpringBonesRejectsAtOneAndAcceptsAtMax() async throws {
        let glb = try makeMinimalVRMWithSpringBones(jointCount: 3)

        var tight = VRMLoaderLimits.default
        tight.maxSpringBones = 1

        // Headless (device == nil) must still reject.
        do {
            _ = try await VRMModel.load(from: glb, device: nil, limits: tight)
            XCTFail("Expected VRMError.limitExceeded for maxSpringBones=1")
        } catch VRMError.limitExceeded(let kind, let limit, let observed) {
            XCTAssertEqual(kind, "springBones")
            XCTAssertEqual(limit, 1)
            XCTAssertEqual(observed, 3)
        }

        var unlimited = VRMLoaderLimits.default
        unlimited.maxSpringBones = Int.max
        let model = try await VRMModel.load(from: glb, device: MTLCreateSystemDefaultDevice(), limits: unlimited)
        XCTAssertEqual(model.springBone?.springs.first?.joints.count, 3)

        // Direct SpringBoneBuffers limit check if Metal is available.
        if let device = MTLCreateSystemDefaultDevice() {
            let buffers = SpringBoneBuffers(device: device)
            XCTAssertThrowsError(try buffers.allocateBuffers(numBones: 3, numSpheres: 0, numCapsules: 0, limits: tight)) { error in
                guard case VRMError.limitExceeded(let kind, let limit, let observed) = error else {
                    return XCTFail("Expected VRMError.limitExceeded, got \(error)")
                }
                XCTAssertEqual(kind, "springBones")
                XCTAssertEqual(limit, 1)
                XCTAssertEqual(observed, 3)
            }
        }
    }

    // MARK: - 6. maxCustomExpressions (VRM 1.0 & VRM 0.x)

    func testMaxCustomExpressionsVRM1RejectsAtOneAndAcceptsAtMax() async throws {
        let glb = try makeMinimalVRMWithCustomExpressions(count: 3, vrm0: false)

        var tight = VRMLoaderLimits.default
        tight.maxCustomExpressions = 1
        do {
            _ = try await VRMModel.load(from: glb, limits: tight)
            XCTFail("Expected VRMError.limitExceeded for VRM 1.0 customExpressions=1")
        } catch VRMError.limitExceeded(let kind, let limit, let observed) {
            XCTAssertEqual(kind, "customExpressions")
            XCTAssertEqual(limit, 1)
            XCTAssertEqual(observed, 3)
        }

        var unlimited = VRMLoaderLimits.default
        unlimited.maxCustomExpressions = Int.max
        let model = try await VRMModel.load(from: glb, limits: unlimited)
        XCTAssertEqual(model.expressions?.custom.count, 3)
    }

    func testMaxCustomExpressionsVRM0RejectsAtOneAndAcceptsAtMax() async throws {
        let glb = try makeMinimalVRMWithCustomExpressions(count: 3, vrm0: true)

        var tight = VRMLoaderLimits.default
        tight.maxCustomExpressions = 1
        do {
            _ = try await VRMModel.load(from: glb, limits: tight)
            XCTFail("Expected VRMError.limitExceeded for VRM 0.x customExpressions=1")
        } catch VRMError.limitExceeded(let kind, let limit, let observed) {
            XCTAssertEqual(kind, "customExpressions")
            XCTAssertEqual(limit, 1)
            XCTAssertGreaterThan(observed, 1)
        }

        var unlimited = VRMLoaderLimits.default
        unlimited.maxCustomExpressions = Int.max
        let model = try await VRMModel.load(from: glb, limits: unlimited)
        XCTAssertEqual(model.expressions?.custom.count, 3)
    }

    // MARK: - Fixtures

    private static let minimalBoneNames = [
        "hips", "spine", "head",
        "leftUpperArm", "leftLowerArm", "leftHand",
        "rightUpperArm", "rightLowerArm", "rightHand",
        "leftUpperLeg", "leftLowerLeg", "leftFoot",
        "rightUpperLeg", "rightLowerLeg", "rightFoot",
    ]

    private func packGLB(json: [String: Any], binary: Data? = nil) throws -> Data {
        var jsonData = try JSONSerialization.data(withJSONObject: json)
        let jsonPad = (4 - jsonData.count % 4) % 4
        jsonData.append(contentsOf: Array(repeating: UInt8(0x20), count: jsonPad))

        var binData = binary
        if var b = binData {
            let binPad = (4 - b.count % 4) % 4
            b.append(contentsOf: Array(repeating: UInt8(0x00), count: binPad))
            binData = b
        }

        var totalLength = 12 + 8 + jsonData.count
        if let b = binData { totalLength += 8 + b.count }

        var glb = Data()
        glb.append(contentsOf: [0x67, 0x6C, 0x54, 0x46])
        glb.append(contentsOf: withUnsafeBytes(of: UInt32(2).littleEndian) { Array($0) })
        glb.append(contentsOf: withUnsafeBytes(of: UInt32(totalLength).littleEndian) { Array($0) })
        glb.append(contentsOf: withUnsafeBytes(of: UInt32(jsonData.count).littleEndian) { Array($0) })
        glb.append(contentsOf: [0x4A, 0x53, 0x4F, 0x4E])
        glb.append(jsonData)
        if let b = binData {
            glb.append(contentsOf: withUnsafeBytes(of: UInt32(b.count).littleEndian) { Array($0) })
            glb.append(contentsOf: [0x42, 0x49, 0x4E, 0x00])
            glb.append(b)
        }
        return glb
    }

    private func baseVRM1Root() -> ([String: Any], [[String: Any]]) {
        var humanBones: [String: Any] = [:]
        var nodes: [[String: Any]] = []
        for (idx, name) in Self.minimalBoneNames.enumerated() {
            humanBones[name] = ["node": idx]
            nodes.append(["name": name])
        }
        let root: [String: Any] = [
            "asset": ["version": "2.0"],
            "extensions": [
                "VRMC_vrm": [
                    "specVersion": "1.0",
                    "meta": ["name": "LimitsFixture", "licenseUrl": "https://vrm.dev/licenses/1.0/"],
                    "humanoid": ["humanBones": humanBones],
                ],
            ],
            "nodes": nodes,
            "scenes": [["nodes": Array(0..<nodes.count)]],
            "scene": 0,
        ]
        return (root, nodes)
    }

    private func makeMinimalVRMWithTriangle() throws -> Data {
        var (root, nodes) = baseVRM1Root()
        let positions: [Float] = [0, 0, 0,  1, 0, 0,  0, 1, 0]
        let bin = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        nodes.append(["name": "meshNode", "mesh": 0])
        root["nodes"] = nodes
        root["buffers"] = [["byteLength": bin.count]]
        root["bufferViews"] = [["buffer": 0, "byteOffset": 0, "byteLength": bin.count]]
        root["accessors"] = [[
            "bufferView": 0, "byteOffset": 0,
            "componentType": 5126, "count": 3, "type": "VEC3",
            "min": [0.0, 0.0, 0.0], "max": [1.0, 1.0, 0.0],
        ]]
        root["meshes"] = [[
            "name": "tri",
            "primitives": [["attributes": ["POSITION": 0]]]
        ]]
        return try packGLB(json: root, binary: bin)
    }

    private func makeMinimalVRMWithSpringBones(jointCount: Int) throws -> Data {
        var (root, nodes) = baseVRM1Root()
        let baseIdx = nodes.count
        var joints: [[String: Any]] = []
        for i in 0..<jointCount {
            nodes.append(["name": "hair_\(i)", "translation": [0.0, -0.1 * Double(i), 0.0]])
            joints.append(["node": baseIdx + i, "stiffness": 1.0, "dragForce": 0.4, "hitRadius": 0.02])
        }
        root["nodes"] = nodes
        var extensions = root["extensions"] as! [String: Any]
        extensions["VRMC_springBone"] = [
            "specVersion": "1.0",
            "springs": [["name": "hair", "joints": joints]],
        ]
        root["extensions"] = extensions
        return try packGLB(json: root)
    }

    private func makeMinimalVRMWithCustomExpressions(count: Int, vrm0: Bool) throws -> Data {
        var (root, _) = baseVRM1Root()
        if vrm0 {
            var groups: [[String: Any]] = []
            for i in 0..<count {
                groups.append(["name": "custom_\(i)", "presetName": "unknown", "binds": []])
            }
            var humanBones: [[String: Any]] = []
            for (idx, name) in Self.minimalBoneNames.enumerated() {
                humanBones.append(["bone": name, "node": idx, "useDefaultValues": true])
            }
            root["extensions"] = [
                "VRM": [
                    "specVersion": "0.0",
                    "meta": ["title": "LimitsVRM0", "author": "Tests"],
                    "humanoid": ["humanBones": humanBones],
                    "blendShapeMaster": ["blendShapeGroups": groups],
                ],
            ]
        } else {
            var custom: [String: Any] = [:]
            for i in 0..<count {
                custom["custom_\(i)"] = ["isBinary": false, "morphTargetBinds": []]
            }
            var extensions = root["extensions"] as! [String: Any]
            var vrm = extensions["VRMC_vrm"] as! [String: Any]
            vrm["expressions"] = ["preset": [:], "custom": custom]
            extensions["VRMC_vrm"] = vrm
            root["extensions"] = extensions
        }
        return try packGLB(json: root)
    }

    private func writeSyntheticVRMA(samplerCount: Int, keyframeCount: Int) throws -> URL {
        var bin = Data()
        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []
        var samplers: [[String: Any]] = []
        var channels: [[String: Any]] = []

        let times = (0..<keyframeCount).map { Float($0) * 0.5 }
        let quats = (0..<keyframeCount).flatMap { _ -> [Float] in [0, 0, 0, 1] }

        for s in 0..<samplerCount {
            let tOffset = bin.count
            let tData = times.withUnsafeBufferPointer { Data(buffer: $0) }
            bin.append(tData)
            let tBV = bufferViews.count
            bufferViews.append(["buffer": 0, "byteOffset": tOffset, "byteLength": tData.count])
            let tAcc = accessors.count
            accessors.append([
                "bufferView": tBV, "byteOffset": 0,
                "componentType": 5126, "count": keyframeCount, "type": "SCALAR",
                "min": [times.first ?? 0], "max": [times.last ?? 0],
            ])

            let qOffset = bin.count
            let qData = quats.withUnsafeBufferPointer { Data(buffer: $0) }
            bin.append(qData)
            let qBV = bufferViews.count
            bufferViews.append(["buffer": 0, "byteOffset": qOffset, "byteLength": qData.count])
            let qAcc = accessors.count
            accessors.append([
                "bufferView": qBV, "byteOffset": 0,
                "componentType": 5126, "count": keyframeCount, "type": "VEC4",
            ])

            samplers.append(["input": tAcc, "output": qAcc, "interpolation": "LINEAR"])
            channels.append(["sampler": s, "target": ["node": 0, "path": "rotation"]])
        }

        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "nodes": [["name": "hips"]],
            "scenes": [["nodes": [0]]],
            "scene": 0,
            "buffers": [["byteLength": bin.count]],
            "bufferViews": bufferViews,
            "accessors": accessors,
            "animations": [["name": "clip", "samplers": samplers, "channels": channels]],
            "extensions": [
                "VRMC_vrm_animation": [
                    "specVersion": "1.0",
                    "humanoid": ["humanBones": ["hips": ["node": 0]]],
                ]
            ],
        ]

        let glb = try packGLB(json: json, binary: bin)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("limits-vrma-\(UUID().uuidString).vrma")
        try glb.write(to: url)
        return url
    }
}
