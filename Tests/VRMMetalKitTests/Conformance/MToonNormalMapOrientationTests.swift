// Copyright 2026 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import VRMMetalKit

/// The tangent frame of a glTF normal map: +X follows increasing U, +Y follows
/// decreasing V (glTF UVs start at the top left and the map's green axis
/// points up), and +Z is the surface normal.
///
/// The fixture is a quad facing the camera whose U runs along world +X and
/// whose V runs along world -Y, so the glTF frame is the world frame. A normal
/// map texel `n` must therefore shade like the same quad with no normal map and
/// a vertex normal of `n`.
@MainActor
final class MToonNormalMapOrientationTests: XCTestCase {

    private var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        self.device = device
    }

    func testTangentSpacePlusXFollowsIncreasingU() async throws {
        let tilt = SIMD3<Float>(0.5, 0, 0.866)
        try await assertNormalMapShadesLikeVertexNormal(tilt, mirrored: SIMD3<Float>(-tilt.x, tilt.y, tilt.z))
    }

    func testTangentSpacePlusYFollowsDecreasingV() async throws {
        let tilt = SIMD3<Float>(0, 0.5, 0.866)
        try await assertNormalMapShadesLikeVertexNormal(tilt, mirrored: SIMD3<Float>(tilt.x, -tilt.y, tilt.z))
    }

    // MARK: - Harness

    private func assertNormalMapShadesLikeVertexNormal(
        _ tilt: SIMD3<Float>,
        mirrored: SIMD3<Float>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let mapped = try await centerLuma(vertexNormal: [0, 0, 1], mapNormal: tilt)
        let expected = try await centerLuma(vertexNormal: tilt, mapNormal: nil)
        let wrong = try await centerLuma(vertexNormal: mirrored, mapNormal: nil)
        XCTAssertGreaterThan(abs(expected - wrong), 0.05,
            "The light does not separate the two tilts, so the test cannot tell them apart",
            file: file, line: line)
        XCTAssertLessThan(abs(mapped - expected), abs(mapped - wrong),
            "Normal map texel \(tilt) shaded like vertex normal \(mirrored), not \(tilt): luma mapped \(mapped), expected \(expected), mirrored \(wrong)",
            file: file, line: line)
    }

    private func centerLuma(vertexNormal: SIMD3<Float>, mapNormal: SIMD3<Float>?) async throws -> Double {
        let glb = try Self.quadGLB(vertexNormal: simd_normalize(vertexNormal), mapNormal: mapNormal.map(simd_normalize))
        let model = try await VRMModel.load(from: glb, device: device)
        var setup = SwatchScene.Setup()
        setup.lightDirection = simd_normalize(SIMD3<Float>(-0.6, -0.6, -0.5))
        setup.lightIntensity = 3.0
        let frame = try SwatchScene.render(model, device: device, setup: setup)
        let size = setup.size
        let region = (size * 7 / 20)..<(size * 13 / 20)
        var sum = 0.0
        for y in region {
            for x in region {
                sum += SwatchScene.luma(frame, (y * size + x) * 4)
            }
        }
        return sum / Double(region.count * region.count)
    }

    // MARK: - Fixture

    private static func quadGLB(vertexNormal: SIMD3<Float>, mapNormal: SIMD3<Float>?) throws -> Data {
        var bin = Data()
        func appendFloats(_ values: [Float]) {
            for var value in values { Swift.withUnsafeBytes(of: &value) { bin.append(contentsOf: $0) } }
        }
        func align() { while bin.count % 4 != 0 { bin.append(0) } }

        var views: [[String: Any]] = []
        func view(_ start: Int) { views.append(["buffer": 0, "byteOffset": start, "byteLength": bin.count - start]) }

        var start = bin.count
        appendFloats([-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0])
        view(start)
        start = bin.count
        appendFloats(Array(repeating: [vertexNormal.x, vertexNormal.y, vertexNormal.z], count: 4).flatMap { $0 })
        view(start)
        start = bin.count
        appendFloats([0, 1, 1, 1, 1, 0, 0, 0])
        view(start)
        start = bin.count
        for var index in [UInt16]([0, 1, 2, 0, 2, 3]) {
            index = index.littleEndian
            Swift.withUnsafeBytes(of: &index) { bin.append(contentsOf: $0) }
        }
        view(start)
        align()

        var material: [String: Any] = [
            "name": "normal-orientation",
            "pbrMetallicRoughness": ["baseColorFactor": [0.8, 0.8, 0.8, 1]],
            "doubleSided": true,
            "extensions": [
                "VRMC_materials_mtoon": [
                    "specVersion": "1.0",
                    "shadeColorFactor": [0, 0, 0],
                    "shadingToonyFactor": 0,
                    "shadingShiftFactor": 0,
                    "giEqualizationFactor": 0,
                ],
            ],
        ]
        var extra: [String: Any] = [:]
        if let mapNormal {
            start = bin.count
            bin.append(try solidPNG(mapNormal))
            view(start)
            align()
            material["normalTexture"] = ["index": 0]
            extra = [
                "textures": [["source": 0, "sampler": 0]],
                "samplers": [["magFilter": 9728, "minFilter": 9728]],
                "images": [["bufferView": 4, "mimeType": "image/png"]],
            ]
        }

        var json: [String: Any] = [
            "asset": ["version": "2.0"],
            "extensionsUsed": ["VRMC_vrm", "VRMC_materials_mtoon"],
            "extensions": [
                "VRMC_vrm": [
                    "specVersion": "1.0",
                    "meta": [
                        "name": "normal-orientation",
                        "authors": ["VRMMetalKit tests"],
                        "licenseUrl": "https://vrm.dev/licenses/1.0/",
                    ],
                    "humanoid": ["humanBones": [
                        "hips": ["node": 0], "spine": ["node": 0], "head": ["node": 0],
                        "leftUpperArm": ["node": 0], "leftLowerArm": ["node": 0], "leftHand": ["node": 0],
                        "rightUpperArm": ["node": 0], "rightLowerArm": ["node": 0], "rightHand": ["node": 0],
                        "leftUpperLeg": ["node": 0], "leftLowerLeg": ["node": 0], "leftFoot": ["node": 0],
                        "rightUpperLeg": ["node": 0], "rightLowerLeg": ["node": 0], "rightFoot": ["node": 0],
                    ] as [String: Any]],
                ],
            ],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]],
            "meshes": [["primitives": [[
                "attributes": ["POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2],
                "indices": 3,
                "material": 0,
            ]]]],
            "materials": [material],
            "buffers": [["byteLength": bin.count]],
            "bufferViews": views,
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3", "min": [-1, -1, 0], "max": [1, 1, 0]],
                ["bufferView": 1, "componentType": 5126, "count": 4, "type": "VEC3"],
                ["bufferView": 2, "componentType": 5126, "count": 4, "type": "VEC2"],
                ["bufferView": 3, "componentType": 5123, "count": 6, "type": "SCALAR"],
            ],
        ]
        json.merge(extra) { $1 }

        var jsonData = try JSONSerialization.data(withJSONObject: json)
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }
        var glb = Data()
        func appendUInt32(_ value: UInt32) {
            var little = value.littleEndian
            Swift.withUnsafeBytes(of: &little) { glb.append(contentsOf: $0) }
        }
        appendUInt32(0x4654_6C67)
        appendUInt32(2)
        appendUInt32(UInt32(12 + 8 + jsonData.count + 8 + bin.count))
        appendUInt32(UInt32(jsonData.count))
        appendUInt32(0x4E4F_534A)
        glb.append(jsonData)
        appendUInt32(UInt32(bin.count))
        appendUInt32(0x004E_4942)
        glb.append(bin)
        return glb
    }

    /// 4×4 PNG holding one tangent-space normal, encoded as `(n + 1) / 2`.
    private static func solidPNG(_ normal: SIMD3<Float>) throws -> Data {
        let encoded = (normal + 1) * 127.5
        let texel: [UInt8] = [UInt8(encoded.x.rounded()), UInt8(encoded.y.rounded()), UInt8(encoded.z.rounded()), 255]
        var pixels = Array(repeating: texel, count: 16).flatMap { $0 }
        let image = try XCTUnwrap(pixels.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        })
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
