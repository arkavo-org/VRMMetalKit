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
import simd
@testable import VRMMetalKit

/// Tests for six VRMA spec deviations (B1–B6).
///
/// All tests build minimal in-memory GLB files using float32 binary buffers so
/// they run without any external fixture files.
final class VRMASpecComplianceTests: XCTestCase {

    // MARK: - B2: Expression weight clamping

    /// Spec: "The implementation must clamp the value to the range of [0, 1]".
    /// A translation.x value of 1.5 must be clamped to 1.0 before being returned.
    func testB2_expressionWeightClamped() throws {
        let overWeight: Float = 1.5
        let glb = try VRMAGLBBuilder()
            .addExpressionPreset(name: "happy", nodeIndex: 1, weight: overWeight)
            .build()

        let url = try writeTemp(glb)
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = try VRMAnimationLoader.loadVRMA(from: url, model: nil)

        guard let track = clip.morphTracks.first(where: { $0.key == "happy" }) else {
            XCTFail("Expected 'happy' morph track")
            return
        }

        let sampled = track.sampler(0)
        XCTAssertLessThanOrEqual(sampled, 1.0, "Expression weight \(sampled) must be clamped to [0,1]")
    }

    /// A translation.x value below 0 must be clamped to 0.0.
    func testB2_expressionWeightClampedNegative() throws {
        let underWeight: Float = -0.5
        let glb = try VRMAGLBBuilder()
            .addExpressionPreset(name: "sad", nodeIndex: 1, weight: underWeight)
            .build()

        let url = try writeTemp(glb)
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = try VRMAnimationLoader.loadVRMA(from: url, model: nil)

        guard let track = clip.morphTracks.first(where: { $0.key == "sad" }) else {
            XCTFail("Expected 'sad' morph track")
            return
        }

        let sampled = track.sampler(0)
        XCTAssertGreaterThanOrEqual(sampled, 0.0, "Expression weight \(sampled) must be clamped to [0,1]")
    }

    // MARK: - B3: Gaze preset exclusion

    /// Spec: "lookUp, lookDown, lookLeft, and lookRight cannot have animation data."
    /// The loader must silently drop these presets; no morph or expression track for them.
    func testB3_gazePresetExcluded() throws {
        let glb = try VRMAGLBBuilder()
            .addExpressionPreset(name: "lookUp", nodeIndex: 1, weight: 0.8)
            .addExpressionPreset(name: "lookDown", nodeIndex: 2, weight: 0.8)
            .addExpressionPreset(name: "lookLeft", nodeIndex: 3, weight: 0.8)
            .addExpressionPreset(name: "lookRight", nodeIndex: 4, weight: 0.8)
            .build()

        let url = try writeTemp(glb)
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = try VRMAnimationLoader.loadVRMA(from: url, model: nil)

        let gazeNames: Set<String> = ["lookUp", "lookDown", "lookLeft", "lookRight"]
        let loadedGazeKeys = clip.morphTracks.map { $0.key }.filter { gazeNames.contains($0) }
        XCTAssertTrue(loadedGazeKeys.isEmpty,
                      "Gaze presets must be excluded but found: \(loadedGazeKeys)")
    }

    // MARK: - B4: Eye-bone exclusion from humanoid track map

    /// Spec: "leftEye and rightEye cannot have animation data for Humanoid bones."
    /// A VRMA that maps leftEye and rightEye in humanBones must not produce JointTracks for them.
    func testB4_eyeBoneExcluded() throws {
        let glb = try VRMAGLBBuilder()
            .addHumanoidBone(name: "leftEye", nodeIndex: 1)
            .addHumanoidBone(name: "rightEye", nodeIndex: 2)
            .addRotationTrack(nodeIndex: 1)
            .addRotationTrack(nodeIndex: 2)
            .build()

        let url = try writeTemp(glb)
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = try VRMAnimationLoader.loadVRMA(from: url, model: nil)

        let eyeBones: [VRMHumanoidBone] = [.leftEye, .rightEye]
        for bone in eyeBones {
            let found = clip.jointTracks.contains { $0.bone == bone }
            XCTAssertFalse(found, "JointTrack for \(bone) must not be created per spec")
        }
    }

    // MARK: - B5: Scale-track exclusion for humanoid bones

    /// Spec: "The animation data for Humanoid bone must not include scales."
    /// A VRMA with a scale track on a humanoid bone must produce a JointTrack with nil scaleSampler.
    func testB5_humanoidBoneScaleDropped() throws {
        let glb = try VRMAGLBBuilder()
            .addHumanoidBone(name: "head", nodeIndex: 1)
            .addScaleTrack(nodeIndex: 1)
            .build()

        let url = try writeTemp(glb)
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = try VRMAnimationLoader.loadVRMA(from: url, model: nil)

        let headTrack = clip.jointTracks.first { $0.bone == .head }
        if let track = headTrack {
            XCTAssertNil(track.scaleSampler,
                         "scaleSampler must be nil for humanoid bones per spec")
        }
    }

    // MARK: - B6: Translation-track restricted to hips

    /// Spec: "must not include translations for bones other than the Hips bone."
    /// A non-hips bone with a translation track must produce a JointTrack with nil translationSampler.
    func testB6_nonHipsTranslationDropped() throws {
        let glb = try VRMAGLBBuilder()
            .addHumanoidBone(name: "head", nodeIndex: 1)
            .addTranslationTrack(nodeIndex: 1)
            .build()

        let url = try writeTemp(glb)
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = try VRMAnimationLoader.loadVRMA(from: url, model: nil)

        let headTrack = clip.jointTracks.first { $0.bone == .head }
        if let track = headTrack {
            XCTAssertNil(track.translationSampler,
                         "translationSampler must be nil for non-hips humanoid bones per spec")
        }
    }

    /// Hips bone MUST retain translation track.
    func testB6_hipsTranslationRetained() throws {
        let glb = try VRMAGLBBuilder()
            .addHumanoidBone(name: "hips", nodeIndex: 1)
            .addTranslationTrack(nodeIndex: 1)
            .build()

        let url = try writeTemp(glb)
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = try VRMAnimationLoader.loadVRMA(from: url, model: nil)

        let hipsTrack = clip.jointTracks.first { $0.bone == .hips }
        if let track = hipsTrack {
            XCTAssertNotNil(track.translationSampler,
                            "translationSampler must be present for hips bone per spec")
        }
    }

    // MARK: - B1: lookAt block parsing + lookAtTargetSampler

    /// Spec: VRMC_vrm_animation "lookAt" block with a node whose translation drives the look target.
    /// The loaded clip must expose a non-nil lookAtTargetSampler.
    func testB1_lookAtTargetSamplerPresent() throws {
        let lookAtNodeIndex = 5
        let targetPos = SIMD3<Float>(0.1, 0.2, 0.3)
        let glb = try VRMAGLBBuilder()
            .addLookAtNode(nodeIndex: lookAtNodeIndex, position: targetPos)
            .build()

        let url = try writeTemp(glb)
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = try VRMAnimationLoader.loadVRMA(from: url, model: nil)

        XCTAssertNotNil(clip.lookAtTargetSampler,
                        "lookAtTargetSampler must be non-nil when VRMA has a lookAt block")
    }

    /// When no lookAt block is present the sampler must be nil.
    func testB1_lookAtTargetSamplerNilWhenAbsent() throws {
        let glb = try VRMAGLBBuilder()
            .addHumanoidBone(name: "hips", nodeIndex: 1)
            .addRotationTrack(nodeIndex: 1)
            .build()

        let url = try writeTemp(glb)
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = try VRMAnimationLoader.loadVRMA(from: url, model: nil)

        XCTAssertNil(clip.lookAtTargetSampler,
                     "lookAtTargetSampler must be nil when VRMA has no lookAt block")
    }

    /// The sampler must return the correct head-local target position at t=0.
    func testB1_lookAtTargetSamplerReturnsPosition() throws {
        let lookAtNodeIndex = 5
        let targetPos = SIMD3<Float>(0.1, 0.2, 0.3)
        let glb = try VRMAGLBBuilder()
            .addLookAtNode(nodeIndex: lookAtNodeIndex, position: targetPos)
            .build()

        let url = try writeTemp(glb)
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = try VRMAnimationLoader.loadVRMA(from: url, model: nil)

        guard let sampler = clip.lookAtTargetSampler else {
            XCTFail("lookAtTargetSampler is nil")
            return
        }

        let result = sampler(0)
        XCTAssertEqual(result.x, targetPos.x, accuracy: 0.001)
        XCTAssertEqual(result.y, targetPos.y, accuracy: 0.001)
        XCTAssertEqual(result.z, targetPos.z, accuracy: 0.001)
    }

    /// VMK#286: the rotation-channel encoding (what `@pixiv/three-vrm-animation`
    /// consumes and Pixiv's distributed VRMA samples emit) must also populate
    /// the sampler. Identity rotation → head-local forward = (0, 0, -1).
    func testB1_lookAtTargetSamplerPresentForRotationChannel() throws {
        let lookAtNodeIndex = 5
        let glb = try VRMAGLBBuilder()
            .addLookAtNode(nodeIndex: lookAtNodeIndex,
                           rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
            .build()

        let url = try writeTemp(glb)
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = try VRMAnimationLoader.loadVRMA(from: url, model: nil)

        XCTAssertNotNil(clip.lookAtTargetSampler,
                        "rotation-channel lookAt must populate lookAtTargetSampler (#286)")
    }

    /// VMK#286: applying the keyframe rotation to head-local forward (-Z)
    /// must produce the expected gaze direction. 90° around +Y rotates
    /// (0,0,-1) → (-1,0,0).
    func testB1_lookAtTargetSamplerReturnsDirectionForRotationChannel() throws {
        let lookAtNodeIndex = 5
        let yaw90 = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        let glb = try VRMAGLBBuilder()
            .addLookAtNode(nodeIndex: lookAtNodeIndex, rotation: yaw90)
            .build()

        let url = try writeTemp(glb)
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = try VRMAnimationLoader.loadVRMA(from: url, model: nil)

        guard let sampler = clip.lookAtTargetSampler else {
            XCTFail("rotation-channel lookAt must populate lookAtTargetSampler (#286)")
            return
        }

        let dir = sampler(0)
        XCTAssertEqual(dir.x, -1, accuracy: 1e-5, "yaw 90° around +Y → forward.x = -1")
        XCTAssertEqual(dir.y,  0, accuracy: 1e-5, "yaw 90° around +Y → forward.y = 0")
        XCTAssertEqual(dir.z,  0, accuracy: 1e-5, "yaw 90° around +Y → forward.z = 0")
    }

    // MARK: - Helpers

    private func writeTemp(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("vrma")
        try data.write(to: url)
        return url
    }
}

// MARK: - Minimal VRMA GLB Builder for Tests

/// Builds a minimal but valid GLB binary that VRMAnimationLoader can parse.
///
/// The binary chunk contains all float32 accessor data packed sequentially.
/// JSON references accessors via bufferViews with correct byteOffset/byteLength.
private final class VRMAGLBBuilder {
    /// Two channel encodings the loader needs to accept on the lookAt node:
    /// `translation` is the spec-literal reading; `rotation` is what
    /// `@pixiv/three-vrm-animation` consumes and Pixiv's distributed VRMA
    /// samples emit (VMK#286). Tests should exercise both.
    enum LookAtChannel {
        case translation(SIMD3<Float>)
        case rotation(simd_quatf)
    }

    private var humanoidBones: [(name: String, nodeIndex: Int)] = []
    private var expressionPresets: [(name: String, nodeIndex: Int, weight: Float)] = []
    private var rotationTrackNodes: [Int] = []
    private var scaleTrackNodes: [Int] = []
    private var translationTrackNodes: [Int] = []
    private var lookAtNode: (nodeIndex: Int, channel: LookAtChannel)?

    @discardableResult
    func addHumanoidBone(name: String, nodeIndex: Int) -> Self {
        humanoidBones.append((name, nodeIndex))
        return self
    }

    @discardableResult
    func addExpressionPreset(name: String, nodeIndex: Int, weight: Float) -> Self {
        expressionPresets.append((name, nodeIndex, weight))
        return self
    }

    @discardableResult
    func addRotationTrack(nodeIndex: Int) -> Self {
        rotationTrackNodes.append(nodeIndex)
        return self
    }

    @discardableResult
    func addScaleTrack(nodeIndex: Int) -> Self {
        scaleTrackNodes.append(nodeIndex)
        return self
    }

    @discardableResult
    func addTranslationTrack(nodeIndex: Int) -> Self {
        translationTrackNodes.append(nodeIndex)
        return self
    }

    @discardableResult
    func addLookAtNode(nodeIndex: Int, position: SIMD3<Float>) -> Self {
        lookAtNode = (nodeIndex, .translation(position))
        return self
    }

    @discardableResult
    func addLookAtNode(nodeIndex: Int, rotation: simd_quatf) -> Self {
        lookAtNode = (nodeIndex, .rotation(rotation))
        return self
    }

    func build() throws -> Data {
        // Collect all unique node indices referenced by animation channels
        var allNodeIndices = Set<Int>()
        for (_, nodeIndex) in humanoidBones { allNodeIndices.insert(nodeIndex) }
        for (_, nodeIndex, _) in expressionPresets { allNodeIndices.insert(nodeIndex) }
        rotationTrackNodes.forEach { allNodeIndices.insert($0) }
        scaleTrackNodes.forEach { allNodeIndices.insert($0) }
        translationTrackNodes.forEach { allNodeIndices.insert($0) }
        if let la = lookAtNode { allNodeIndices.insert(la.nodeIndex) }

        let maxNodeIndex = allNodeIndices.max() ?? 0
        let nodeCount = maxNodeIndex + 1

        // Binary buffer layout: each track gets a time accessor (1 keyframe at t=0) and value accessor.
        // We use a single-keyframe animation (t=0) so sampling is deterministic.
        var binaryFloats: [Float] = []

        // Helper: append floats, return byte offset before appending
        var binaryOffset: Int { binaryFloats.count * 4 }

        struct AccessorRef {
            let bufferViewIndex: Int
            let count: Int
            let type: String     // "SCALAR", "VEC3", "VEC4"
            let componentType: Int // 5126 = FLOAT
        }

        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []

        func addAccessor(floats: [Float], type: String, componentType: Int = 5126) -> Int {
            let bvIndex = bufferViews.count
            let byteOffset = binaryOffset
            binaryFloats.append(contentsOf: floats)
            let byteLength = floats.count * 4
            bufferViews.append([
                "buffer": 0,
                "byteOffset": byteOffset,
                "byteLength": byteLength
            ])
            let componentCount: Int
            switch type {
            case "SCALAR": componentCount = 1
            case "VEC3": componentCount = 3
            case "VEC4": componentCount = 4
            default: componentCount = 1
            }
            let elemCount = floats.count / componentCount
            let aIndex = accessors.count
            accessors.append([
                "bufferView": bvIndex,
                "componentType": componentType,
                "count": elemCount,
                "type": type
            ])
            _ = bvIndex
            return aIndex
        }

        // Build animation channels and samplers
        var channels: [[String: Any]] = []
        var samplers: [[String: Any]] = []

        func addChannel(nodeIndex: Int, path: String, valueFloats: [Float], valueType: String) {
            let timeAccessor = addAccessor(floats: [Float(0.0)], type: "SCALAR")
            let valueAccessor = addAccessor(floats: valueFloats, type: valueType)
            let sIdx = samplers.count
            samplers.append(["input": timeAccessor, "output": valueAccessor, "interpolation": "LINEAR"])
            channels.append(["sampler": sIdx, "target": ["node": nodeIndex, "path": path]])
        }

        // Rotation tracks
        for nodeIndex in rotationTrackNodes {
            addChannel(nodeIndex: nodeIndex, path: "rotation",
                       valueFloats: [0, 0, 0, 1], valueType: "VEC4")
        }

        // Scale tracks
        for nodeIndex in scaleTrackNodes {
            addChannel(nodeIndex: nodeIndex, path: "scale",
                       valueFloats: [1, 1, 1], valueType: "VEC3")
        }

        // Translation tracks (for regular bones)
        for nodeIndex in translationTrackNodes {
            addChannel(nodeIndex: nodeIndex, path: "translation",
                       valueFloats: [0, 0, 0], valueType: "VEC3")
        }

        // Expression preset tracks (translation.x = weight)
        for (_, nodeIndex, weight) in expressionPresets {
            addChannel(nodeIndex: nodeIndex, path: "translation",
                       valueFloats: [weight, 0, 0], valueType: "VEC3")
        }

        // lookAt node channel — emitted in whichever form the caller selected.
        if let la = lookAtNode {
            switch la.channel {
            case .translation(let pos):
                addChannel(nodeIndex: la.nodeIndex, path: "translation",
                           valueFloats: [pos.x, pos.y, pos.z], valueType: "VEC3")
            case .rotation(let q):
                // glTF quaternion accessor stores [x, y, z, w].
                addChannel(nodeIndex: la.nodeIndex, path: "rotation",
                           valueFloats: [q.imag.x, q.imag.y, q.imag.z, q.real],
                           valueType: "VEC4")
            }
        }

        let totalByteLength = binaryFloats.count * 4

        // Build VRMC_vrm_animation extension
        var humanBonesDict: [String: Any] = [:]
        for (name, nodeIndex) in humanoidBones {
            humanBonesDict[name] = ["node": nodeIndex]
        }

        var expressionPresetDict: [String: Any] = [:]
        for (name, nodeIndex, _) in expressionPresets {
            expressionPresetDict[name] = ["node": nodeIndex]
        }

        var vrmAnimExt: [String: Any] = [
            "specVersion": "1.0",
            "humanoid": ["humanBones": humanBonesDict],
            "expressions": ["preset": expressionPresetDict]
        ]

        if let la = lookAtNode {
            vrmAnimExt["lookAt"] = ["node": la.nodeIndex]
        }

        // Build glTF nodes array (minimal — just enough entries to satisfy index bounds)
        var nodes: [[String: Any]] = []
        for _ in 0..<nodeCount {
            nodes.append(["name": "node"])
        }

        var gltfJSON: [String: Any] = [
            "asset": ["version": "2.0"],
            "extensionsUsed": ["VRMC_vrm_animation"],
            "extensions": ["VRMC_vrm_animation": vrmAnimExt],
            "nodes": nodes,
            "buffers": [["byteLength": max(1, totalByteLength)]],
            "bufferViews": bufferViews,
            "accessors": accessors,
        ]

        if !channels.isEmpty {
            gltfJSON["animations"] = [["channels": channels, "samplers": samplers]]
        } else {
            // Provide a dummy animation so the loader doesn't throw "No animations"
            let dummyTimeAccessor = addAccessor(floats: [0], type: "SCALAR")
            let dummyValAccessor = addAccessor(floats: [0, 0, 0, 1], type: "VEC4")
            gltfJSON["bufferViews"] = bufferViews
            gltfJSON["accessors"] = accessors
            gltfJSON["buffers"] = [["byteLength": max(1, binaryFloats.count * 4)]]
            let dummyNodeIndex = 0
            gltfJSON["animations"] = [[
                "channels": [["sampler": 0, "target": ["node": dummyNodeIndex, "path": "rotation"]]],
                "samplers": [["input": dummyTimeAccessor, "output": dummyValAccessor, "interpolation": "LINEAR"]]
            ]]
        }

        let jsonData = try JSONSerialization.data(withJSONObject: gltfJSON, options: [])
        let jsonPadding = (4 - (jsonData.count % 4)) % 4
        var paddedJSON = jsonData
        if jsonPadding > 0 { paddedJSON.append(Data(repeating: 0x20, count: jsonPadding)) }

        var binaryData = Data()
        for f in binaryFloats {
            var v = f
            binaryData.append(Data(bytes: &v, count: 4))
        }
        // Ensure at least 1 byte in binary chunk
        if binaryData.isEmpty { binaryData.append(0) }
        let binPadding = (4 - (binaryData.count % 4)) % 4
        if binPadding > 0 { binaryData.append(Data(repeating: 0, count: binPadding)) }

        let totalLength = 12 + 8 + paddedJSON.count + 8 + binaryData.count
        var glb = Data()
        glb.append(uint32LE(0x46546C67)) // magic "glTF"
        glb.append(uint32LE(2))           // version
        glb.append(uint32LE(UInt32(totalLength)))
        glb.append(uint32LE(UInt32(paddedJSON.count)))
        glb.append(uint32LE(0x4E4F534A)) // "JSON"
        glb.append(paddedJSON)
        glb.append(uint32LE(UInt32(binaryData.count)))
        glb.append(uint32LE(0x004E4942)) // "BIN\0"
        glb.append(binaryData)

        return glb
    }

    private func uint32LE(_ value: UInt32) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 4)
    }
}
