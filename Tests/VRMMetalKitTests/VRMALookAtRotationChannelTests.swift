//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

import XCTest
import simd
@testable import VRMMetalKit

/// VMK#286 — `VRMAnimationLoader` must populate `clip.lookAtTargetSampler`
/// when the VRMC_vrm_animation `lookAt.node` carries either a translation
/// channel (spec-literal reading) or a rotation channel (what
/// `@pixiv/three-vrm-animation` and Pixiv's distributed VRMA samples emit).
/// Pre-fix the rotation case was silently dropped and `apply_vrma` was a
/// no-op for gaze on the entire `vrma_lookat_*` conformance corpus.
///
/// These tests synthesise minimal VRMA-shaped GLBs in-memory so the loader
/// runs against a known input. The fixture is intentionally small — one
/// animation, one channel, two keyframes — so the only thing under test is
/// which channel path the loader picks up.
final class VRMALookAtRotationChannelTests: XCTestCase {

    /// The fix path: a rotation channel on the lookAt node must produce a
    /// non-nil sampler whose value at t=0 is the head-local forward
    /// rotated by the keyframe's quaternion. Identity → (0, 0, -1).
    func testRotationChannelLookAtPopulatesSampler() throws {
        let identityQuat: [Float] = [0, 0, 0, 1]
        let yaw90Quat: [Float] = quaternionAxisAngle(axis: SIMD3<Float>(0, 1, 0), angle: .pi / 2)

        let glb = makeVRMA(rotationKeyframes: [(time: 0, quat: identityQuat),
                                               (time: 1, quat: yaw90Quat)])
        let url = try writeTempVRMA(glb)
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = try VRMAnimationLoader.loadVRMA(from: url, model: nil)

        guard let sampler = clip.lookAtTargetSampler else {
            XCTFail("rotation-channel lookAt must populate lookAtTargetSampler (#286)")
            return
        }

        let p0 = sampler(0)
        XCTAssertEqual(p0.x,  0, accuracy: 1e-5, "identity rotation → forward.x = 0")
        XCTAssertEqual(p0.y,  0, accuracy: 1e-5, "identity rotation → forward.y = 0")
        XCTAssertEqual(p0.z, -1, accuracy: 1e-5, "identity rotation → forward.z = -1")

        // 90° around +Y: head-local forward (-Z) rotates to head-local -X.
        let p1 = sampler(1)
        XCTAssertEqual(p1.x, -1, accuracy: 1e-5, "yaw 90° around +Y → forward.x = -1")
        XCTAssertEqual(p1.y,  0, accuracy: 1e-5, "yaw 90° around +Y → forward.y = 0")
        XCTAssertEqual(p1.z,  0, accuracy: 1e-5, "yaw 90° around +Y → forward.z = 0")
    }

    /// Regression guard for the spec-literal path: a translation channel
    /// on the lookAt node must still populate the sampler and return the
    /// keyframe values verbatim.
    func testTranslationChannelLookAtStillPopulatesSampler() throws {
        let p0: SIMD3<Float> = .init( 0, 0, -1)
        let p1: SIMD3<Float> = .init(-1, 0,  0)

        let glb = makeVRMA(translationKeyframes: [(time: 0, vec: p0),
                                                  (time: 1, vec: p1)])
        let url = try writeTempVRMA(glb)
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = try VRMAnimationLoader.loadVRMA(from: url, model: nil)

        guard let sampler = clip.lookAtTargetSampler else {
            XCTFail("translation-channel lookAt must still populate sampler")
            return
        }

        let s0 = sampler(0)
        XCTAssertEqual(s0.x, p0.x, accuracy: 1e-5)
        XCTAssertEqual(s0.y, p0.y, accuracy: 1e-5)
        XCTAssertEqual(s0.z, p0.z, accuracy: 1e-5)

        let s1 = sampler(1)
        XCTAssertEqual(s1.x, p1.x, accuracy: 1e-5)
        XCTAssertEqual(s1.y, p1.y, accuracy: 1e-5)
        XCTAssertEqual(s1.z, p1.z, accuracy: 1e-5)
    }

    // MARK: - Minimal VRMA GLB builder

    private struct RotationKeyframe { let time: Float; let quat: [Float] }
    private struct TranslationKeyframe { let time: Float; let vec: SIMD3<Float> }

    /// Build a minimal in-memory VRMA GLB with a single animation, one
    /// channel targeting `nodes[0]` on the supplied path, and a
    /// `VRMC_vrm_animation.lookAt` extension pointing at `nodes[0]`.
    private func makeVRMA(rotationKeyframes: [(time: Float, quat: [Float])]) -> Data {
        let frames = rotationKeyframes.map { RotationKeyframe(time: $0.time, quat: $0.quat) }
        return buildGLB(rotation: frames, translation: nil)
    }

    private func makeVRMA(translationKeyframes: [(time: Float, vec: SIMD3<Float>)]) -> Data {
        let frames = translationKeyframes.map { TranslationKeyframe(time: $0.time, vec: $0.vec) }
        return buildGLB(rotation: nil, translation: frames)
    }

    private func buildGLB(rotation: [RotationKeyframe]?,
                          translation: [TranslationKeyframe]?) -> Data {
        // Binary layout: [times | values]. Both kinds of values share the
        // same accessor pattern: float SCALAR for times, float VEC4 (quat)
        // or VEC3 (vec) for values.
        var bin = Data()
        let path: String
        let componentType = 5126            // FLOAT
        let valueType: String
        let valueCount: Int
        let times: [Float]
        if let rot = rotation {
            path = "rotation"
            valueType = "VEC4"
            valueCount = rot.count
            times = rot.map { $0.time }
            for f in rot { appendFloats(&bin, f.quat) }
            // Times appended after values? No — convention is order-free;
            // we'll point bufferViews at the correct offsets explicitly.
        } else if let trans = translation {
            path = "translation"
            valueType = "VEC3"
            valueCount = trans.count
            times = trans.map { $0.time }
            for f in trans { appendFloats(&bin, [f.vec.x, f.vec.y, f.vec.z]) }
        } else {
            preconditionFailure("must supply either rotation or translation keyframes")
        }
        let valuesByteLength = bin.count
        let timesOffset = bin.count
        appendFloats(&bin, times)
        let timesByteLength = bin.count - timesOffset
        // Pad to 4 bytes (already aligned for floats, but be safe).
        while bin.count % 4 != 0 { bin.append(0) }

        let bufferLength = bin.count

        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "VMK286-test"],
            "nodes": [["name": "lookAt"]],
            "buffers": [["byteLength": bufferLength]],
            "bufferViews": [
                // 0: values
                ["buffer": 0, "byteOffset": 0, "byteLength": valuesByteLength],
                // 1: times
                ["buffer": 0, "byteOffset": timesOffset, "byteLength": timesByteLength]
            ],
            "accessors": [
                // 0: values accessor (VEC4 quat or VEC3 vec)
                ["bufferView": 0, "componentType": componentType, "count": valueCount, "type": valueType],
                // 1: times accessor (SCALAR float)
                ["bufferView": 1, "componentType": componentType, "count": times.count, "type": "SCALAR"]
            ],
            "animations": [[
                "channels": [["sampler": 0, "target": ["node": 0, "path": path]]],
                "samplers": [["input": 1, "output": 0, "interpolation": "LINEAR"]]
            ]],
            "extensions": [
                "VRMC_vrm_animation": [
                    "specVersion": "1.0",
                    "lookAt": ["node": 0, "offsetFromHeadBone": [0, 0.06, 0]]
                ]
            ],
            "extensionsUsed": ["VRMC_vrm_animation"]
        ]

        var jsonData = try! JSONSerialization.data(withJSONObject: json, options: [])
        while jsonData.count % 4 != 0 { jsonData.append(0x20) } // pad with spaces

        // GLB layout: header(12) + JSON chunk header(8) + JSON + BIN chunk header(8) + BIN.
        let total = 12 + 8 + jsonData.count + 8 + bin.count
        var glb = Data()
        glb.appendUInt32LE(0x46546C67)        // 'glTF'
        glb.appendUInt32LE(2)
        glb.appendUInt32LE(UInt32(total))
        glb.appendUInt32LE(UInt32(jsonData.count))
        glb.appendUInt32LE(0x4E4F534A)        // 'JSON'
        glb.append(jsonData)
        glb.appendUInt32LE(UInt32(bin.count))
        glb.appendUInt32LE(0x004E4942)        // 'BIN\0'
        glb.append(bin)
        return glb
    }

    private func appendFloats(_ data: inout Data, _ floats: [Float]) {
        for var f in floats {
            withUnsafeBytes(of: &f) { data.append(contentsOf: $0) }
        }
    }

    private func writeTempVRMA(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "vmk286-\(UUID().uuidString).vrma")
        try data.write(to: url)
        return url
    }

    private func quaternionAxisAngle(axis: SIMD3<Float>, angle: Float) -> [Float] {
        let half = angle * 0.5
        let s = sin(half)
        return [axis.x * s, axis.y * s, axis.z * s, cos(half)]
    }
}

private extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
