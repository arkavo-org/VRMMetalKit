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

/// Issue #250: light direction should use the inverse-transpose of the parent's
/// upper-3×3 so non-orthogonal explicit-matrix parents don't skew the axis.
/// For TRS-decomposed parents (rotation + diagonal scale) the two formulations
/// produce the same normalized direction, so the regression is only visible
/// with an explicit non-orthogonal `matrix` node property.
final class GLTFLightDirectionTests: XCTestCase {

    func testDirectionalLightUnderNonOrthogonalParentUsesInverseTranspose() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }

        // Z-axis sheared by X (column-major flat for glTF `matrix`):
        //   col 0 = (1, 0, 1),  col 1 = (0, 1, 0),  col 2 = (0, 0, 1),  col 3 = origin.
        // M  * (0,0,-1) -> (0, 0, -1)              (old behaviour)
        // M^{-T} * (0,0,-1) -> (1, 0, -1) -> normalize -> (0.707, 0, -0.707)  (new)
        let json: [String: Any] = [
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
                    "matrix": [
                        1.0, 0.0, 1.0, 0.0,
                        0.0, 1.0, 0.0, 0.0,
                        0.0, 0.0, 1.0, 0.0,
                        0.0, 0.0, 0.0, 1.0
                    ],
                    "extensions": ["KHR_lights_punctual": ["light": 0]]
                ]
            ]
        ]

        let asset = try await loadAsset(json: json, device: device)

        XCTAssertEqual(asset.lights.count, 1)
        let dir = asset.lights[0].direction
        let expected = normalize(SIMD3<Float>(1, 0, -1))
        XCTAssertEqual(dir.x, expected.x, accuracy: 1e-5,
            "inverse-transpose direction x mismatch: got \(dir.x), expected \(expected.x)")
        XCTAssertEqual(dir.y, expected.y, accuracy: 1e-5)
        XCTAssertEqual(dir.z, expected.z, accuracy: 1e-5,
            "inverse-transpose direction z mismatch: got \(dir.z), expected \(expected.z)")
    }

    func testDirectionalLightUnderTRSParentMatchesRotationOnly() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }

        // 90° rotation around Y + non-uniform scale (2, 1, 0.5).
        // Quaternion for 90° about Y: (0, sin(45°), 0, cos(45°)).
        // Both regular `M*v` and `M^{-T}*v` should produce R*(0,0,-1) after
        // normalize, which is -col2(R(90°)) = -(1, 0, 0) = (-1, 0, 0).
        let halfAngle = Float.pi / 4
        let qy = sin(halfAngle)
        let qw = cos(halfAngle)
        let json: [String: Any] = [
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
                    "rotation": [0.0, Double(qy), 0.0, Double(qw)],
                    "scale": [2.0, 1.0, 0.5],
                    "extensions": ["KHR_lights_punctual": ["light": 0]]
                ]
            ]
        ]

        let asset = try await loadAsset(json: json, device: device)

        XCTAssertEqual(asset.lights.count, 1)
        let dir = asset.lights[0].direction
        let expected = SIMD3<Float>(-1, 0, 0)
        XCTAssertEqual(dir.x, expected.x, accuracy: 1e-4)
        XCTAssertEqual(dir.y, expected.y, accuracy: 1e-4)
        XCTAssertEqual(dir.z, expected.z, accuracy: 1e-4)
    }

    // MARK: - Helpers

    /// Wraps a JSON dictionary in the minimal GLB container the parser expects:
    /// 12-byte header (`glTF` magic, version 2, total length) + 8-byte JSON
    /// chunk header (length, `JSON` type) + the JSON payload. JSON chunks must
    /// be 4-byte aligned per the glTF 2.0 spec.
    private func loadAsset(json: [String: Any], device: MTLDevice) async throws -> GLTFAsset {
        var jsonData = try JSONSerialization.data(withJSONObject: json, options: [])
        // Pad JSON to a 4-byte boundary with ASCII spaces.
        let pad = (4 - jsonData.count % 4) % 4
        jsonData.append(contentsOf: Array(repeating: UInt8(0x20), count: pad))

        var glb = Data()
        let totalLength = UInt32(12 + 8 + jsonData.count)
        glb.append(contentsOf: [0x67, 0x6C, 0x54, 0x46])           // "glTF" magic
        glb.append(contentsOf: UInt32(2).littleEndianBytes())                  // version
        glb.append(contentsOf: totalLength.littleEndianBytes())                // total length
        glb.append(contentsOf: UInt32(jsonData.count).littleEndianBytes())     // chunk length
        glb.append(contentsOf: [0x4A, 0x53, 0x4F, 0x4E])           // "JSON" chunk type
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
