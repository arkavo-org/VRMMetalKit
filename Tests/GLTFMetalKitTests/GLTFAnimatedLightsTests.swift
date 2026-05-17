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
import Metal
import simd
@testable import GLTFMetalKit

/// PR #241 reviewer suggestion: exercise `KHR_lights_punctual` and the
/// animation runtime together — the parse path branches on extensions, and
/// the rebuild path walks the same node tree the light is attached to.
/// Locks down that a punctual light parses correctly alongside a TRS
/// animation channel on the same node, and that animated rebuilds don't
/// regress the light array.
final class GLTFAnimatedLightsTests: XCTestCase {

    func testKHRLightsPunctualLoadsAlongsideAnimationChannel() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }

        let asset = try await loadAsset(json: makeAnimatedLightJSON(), device: device)

        XCTAssertEqual(asset.lights.count, 1, "KHR_lights_punctual lights array must include the directional light.")
        XCTAssertGreaterThan(asset.animations.count, 0, "Animation clip must be parsed.")
        XCTAssertGreaterThan(asset.animations[0].duration, 0)
    }

    func testAnimatedRebuildPreservesLights() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }

        let asset = try await loadAsset(json: makeAnimatedLightJSON(), device: device)
        guard !asset.animations.isEmpty else { XCTFail("missing animation"); return }
        let duration = asset.animations[0].duration

        // The light array should still be intact after sampling animation
        // at a non-zero time — rebuild walks the same scene graph but must
        // not clobber the parsed lights.
        let drawsAtT0 = asset.drawCalls(animationIndex: 0, time: 0)
        let drawsAtMid = asset.drawCalls(animationIndex: 0, time: duration * 0.5)

        XCTAssertEqual(asset.lights.count, 1)
        // Without a mesh node these draw lists are empty by design — the
        // point is that the rebuild path completes without crashing on a
        // light-only animated scene.
        XCTAssertEqual(drawsAtT0.count, 0)
        XCTAssertEqual(drawsAtMid.count, 0)
    }

    // MARK: - Helpers

    /// Builds a JSON glTF with:
    ///   - A directional light registered via KHR_lights_punctual.
    ///   - A single node carrying the light and a translation TRS animation
    ///     from (0,0,0) at t=0 to (1,0,0) at t=1.
    ///   - The animation samplers reference a base64 data-URI buffer
    ///     containing the input timestamps and output translations.
    private func makeAnimatedLightJSON() -> [String: Any] {
        // 8 bytes timestamps (2 floats), 24 bytes output (2 vec3).
        var bytes = [UInt8]()
        appendFloat(0.0, to: &bytes)
        appendFloat(1.0, to: &bytes)
        appendFloat(0.0, to: &bytes); appendFloat(0.0, to: &bytes); appendFloat(0.0, to: &bytes)
        appendFloat(1.0, to: &bytes); appendFloat(0.0, to: &bytes); appendFloat(0.0, to: &bytes)
        let base64 = Data(bytes).base64EncodedString()
        let uri = "data:application/octet-stream;base64,\(base64)"

        return [
            "asset": ["version": "2.0"],
            "extensionsUsed": ["KHR_lights_punctual"],
            "extensions": [
                "KHR_lights_punctual": [
                    "lights": [
                        ["type": "directional", "color": [1.0, 1.0, 1.0], "intensity": 1.0]
                    ]
                ]
            ],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [
                [
                    "translation": [0.0, 0.0, 0.0],
                    "extensions": ["KHR_lights_punctual": ["light": 0]]
                ]
            ],
            "buffers": [["byteLength": 32, "uri": uri]],
            "bufferViews": [
                ["buffer": 0, "byteOffset": 0, "byteLength": 8],
                ["buffer": 0, "byteOffset": 8, "byteLength": 24]
            ],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": 2,
                 "type": "SCALAR", "min": [0.0], "max": [1.0]],
                ["bufferView": 1, "componentType": 5126, "count": 2, "type": "VEC3"]
            ],
            "animations": [
                [
                    "samplers": [
                        ["input": 0, "output": 1, "interpolation": "LINEAR"]
                    ],
                    "channels": [
                        ["sampler": 0, "target": ["node": 0, "path": "translation"]]
                    ]
                ]
            ]
        ]
    }

    private func appendFloat(_ value: Float, to bytes: inout [UInt8]) {
        var v = value
        withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) }
    }

    private func loadAsset(json: [String: Any], device: MTLDevice) async throws -> GLTFAsset {
        var jsonData = try JSONSerialization.data(withJSONObject: json, options: [])
        let pad = (4 - jsonData.count % 4) % 4
        jsonData.append(contentsOf: Array(repeating: UInt8(0x20), count: pad))

        var glb = Data()
        let totalLength = UInt32(12 + 8 + jsonData.count)
        glb.append(contentsOf: [0x67, 0x6C, 0x54, 0x46])
        glb.append(contentsOf: UInt32(2).littleEndianBytes())
        glb.append(contentsOf: totalLength.littleEndianBytes())
        glb.append(contentsOf: UInt32(jsonData.count).littleEndianBytes())
        glb.append(contentsOf: [0x4A, 0x53, 0x4F, 0x4E])
        glb.append(jsonData)

        let parser = GLTFParser()
        let parsed = try parser.parse(data: glb)
        let loader = GLTFAssetLoader()
        return try await loader.build(
            document: parsed.document,
            binaryData: nil,
            baseURL: nil,
            device: device
        )
    }
}

private extension UInt32 {
    func littleEndianBytes() -> [UInt8] {
        var le = littleEndian
        return withUnsafeBytes(of: &le) { Array($0) }
    }
}
