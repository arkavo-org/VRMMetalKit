//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

import Foundation
import Metal
import simd
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Shared builder for a minimal VRM 1.0 GLB carrying a flat MToon quad and
/// an optional glTF-core `occlusionTexture` (procedural quadrant AO map).
/// Used by the VMK#293 hash-distinctness tests and the VMK#310 behavioral
/// directly-lit-invariant tests.
enum MToonOcclusionFixture {

    /// Builds a minimal valid VRM 1.0 GLB: a single quad facing +Z with one
    /// MToon material. When `strength` is non-nil, attaches a procedural
    /// 16×16 quadrant occlusion map (R channel carries the occlusion value,
    /// 0=heavy 1=none) as `material.occlusionTexture` with the supplied
    /// `strength`. When `strength` is nil, omits the texture entirely.
    static func buildVRMGLB(strength: Float?) throws -> Data {
        var bin = Data()

        let positions: [Float] = [
            -1, -1, 0,  1, -1, 0,  1, 1, 0,  -1, 1, 0,
        ]
        let normals: [Float] = [
            0, 0, 1,  0, 0, 1,  0, 0, 1,  0, 0, 1,
        ]
        let uvs: [Float] = [
            0, 1,  1, 1,  1, 0,  0, 0,
        ]
        let indices: [UInt16] = [0, 1, 2, 0, 2, 3]

        let positionsOffset = bin.count
        appendFloats(&bin, positions)
        let positionsLength = bin.count - positionsOffset

        let normalsOffset = bin.count
        appendFloats(&bin, normals)
        let normalsLength = bin.count - normalsOffset

        let uvsOffset = bin.count
        appendFloats(&bin, uvs)
        let uvsLength = bin.count - uvsOffset

        let indicesOffset = bin.count
        appendUInt16s(&bin, indices)
        let indicesLength = bin.count - indicesOffset
        while bin.count % 4 != 0 { bin.append(0) }

        var imageOffset = 0
        var imageLength = 0
        if strength != nil {
            let pngBytes = try makeQuadrantOcclusionPNG()
            imageOffset = bin.count
            bin.append(pngBytes)
            imageLength = pngBytes.count
            while bin.count % 4 != 0 { bin.append(0) }
        }

        var bufferViews: [[String: Any]] = [
            ["buffer": 0, "byteOffset": positionsOffset, "byteLength": positionsLength],
            ["buffer": 0, "byteOffset": normalsOffset,   "byteLength": normalsLength],
            ["buffer": 0, "byteOffset": uvsOffset,       "byteLength": uvsLength],
            ["buffer": 0, "byteOffset": indicesOffset,   "byteLength": indicesLength],
        ]
        if strength != nil {
            bufferViews.append(["buffer": 0, "byteOffset": imageOffset, "byteLength": imageLength])
        }

        var material: [String: Any] = [
            "name": "fixture-mtoon",
            "pbrMetallicRoughness": [
                "baseColorFactor": [0.7, 0.7, 0.7, 1],
                "metallicFactor": 0,
                "roughnessFactor": 1,
            ],
            "doubleSided": true,
            "extensions": [
                "VRMC_materials_mtoon": [
                    "specVersion": "1.0",
                    "transparentWithZWrite": false,
                    "renderQueueOffsetNumber": 0,
                ],
            ],
        ]
        if let s = strength {
            material["occlusionTexture"] = [
                "index": 0,
                "strength": Double(s),
            ]
        }

        var json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "VMK-occlusion-test"],
            "extensionsUsed": ["VRMC_vrm", "VRMC_materials_mtoon"],
            "extensions": [
                "VRMC_vrm": [
                    "specVersion": "1.0",
                    "meta": [
                        "name": "vmk-occlusion-fixture",
                        "version": "1.0",
                        "authors": ["VMK occlusion test"],
                        "licenseUrl": "https://vrm.dev/licenses/1.0/",
                    ],
                    "humanoid": [
                        "humanBones": [
                            "hips":          ["node": 0],
                            "spine":         ["node": 0],
                            "head":          ["node": 0],
                            "leftUpperArm":  ["node": 0],
                            "leftLowerArm":  ["node": 0],
                            "leftHand":      ["node": 0],
                            "rightUpperArm": ["node": 0],
                            "rightLowerArm": ["node": 0],
                            "rightHand":     ["node": 0],
                            "leftUpperLeg":  ["node": 0],
                            "leftLowerLeg":  ["node": 0],
                            "leftFoot":      ["node": 0],
                            "rightUpperLeg": ["node": 0],
                            "rightLowerLeg": ["node": 0],
                            "rightFoot":     ["node": 0],
                        ] as [String: Any],
                    ],
                ],
            ],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]],
            "meshes": [[
                "primitives": [[
                    "attributes": [
                        "POSITION": 0,
                        "NORMAL": 1,
                        "TEXCOORD_0": 2,
                    ],
                    "indices": 3,
                    "material": 0,
                ]],
            ]],
            "materials": [material],
            "buffers": [["byteLength": bin.count]],
            "bufferViews": bufferViews,
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": 4,
                 "type": "VEC3", "min": [-1, -1, 0], "max": [1, 1, 0]],
                ["bufferView": 1, "componentType": 5126, "count": 4, "type": "VEC3"],
                ["bufferView": 2, "componentType": 5126, "count": 4, "type": "VEC2"],
                ["bufferView": 3, "componentType": 5123, "count": 6, "type": "SCALAR"],
            ],
        ]
        if strength != nil {
            json["textures"] = [["source": 0, "sampler": 0]]
            json["samplers"] = [[
                "magFilter": 9729, "minFilter": 9729,
                "wrapS": 10497, "wrapT": 10497,
            ]]
            json["images"] = [["bufferView": 4, "mimeType": "image/png"]]
        }

        var jsonData = try JSONSerialization.data(withJSONObject: json, options: [])
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }

        let total = 12 + 8 + jsonData.count + 8 + bin.count
        var glb = Data()
        appendUInt32LE(&glb, 0x46546C67)
        appendUInt32LE(&glb, 2)
        appendUInt32LE(&glb, UInt32(total))
        appendUInt32LE(&glb, UInt32(jsonData.count))
        appendUInt32LE(&glb, 0x4E4F534A)
        glb.append(jsonData)
        appendUInt32LE(&glb, UInt32(bin.count))
        appendUInt32LE(&glb, 0x004E4942)
        glb.append(bin)
        return glb
    }

    /// 16×16 RGBA quadrant occlusion map. R channel carries the occlusion
    /// value per glTF — TL=0.1 (heavy), TR=0.3, BL=0.7, BR=1.0 (none).
    static func makeQuadrantOcclusionPNG() throws -> Data {
        let size = 16
        let half = size / 2
        let tl: UInt8 = UInt8((0.1 * 255.0).rounded())
        let tr: UInt8 = UInt8((0.3 * 255.0).rounded())
        let bl: UInt8 = UInt8((0.7 * 255.0).rounded())
        let br: UInt8 = UInt8((1.0 * 255.0).rounded())

        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let r: UInt8 = {
                    if y < half && x < half  { return tl }
                    if y < half && x >= half { return tr }
                    if y >= half && x < half { return bl }
                    return br
                }()
                let i = (y * size + x) * 4
                pixels[i+0] = r
                pixels[i+1] = 255
                pixels[i+2] = 255
                pixels[i+3] = 255
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &pixels, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: colorSpace, bitmapInfo: bitmapInfo
        ), let cgImage = context.makeImage() else {
            throw NSError(domain: "MToonOcclusionFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create CGImage"])
        }

        let cfData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            cfData as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw NSError(domain: "MToonOcclusionFixture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create PNG destination"])
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "MToonOcclusionFixture", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
        }
        return cfData as Data
    }

    // MARK: - Math + texture helpers

    static func perspectiveProjection(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0)
        )
    }

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = normalize(eye - target)
        let x = normalize(cross(up, z))
        let y = cross(z, x)
        return simd_float4x4(
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
        )
    }

    static func makeTexture(
        device: MTLDevice, width: Int, height: Int,
        format: MTLPixelFormat, usage: MTLTextureUsage, storage: MTLStorageMode
    ) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false
        )
        desc.usage = usage
        desc.storageMode = storage
        return device.makeTexture(descriptor: desc)!
    }

    static func appendFloats(_ data: inout Data, _ floats: [Float]) {
        for var f in floats {
            Swift.withUnsafeBytes(of: &f) { data.append(contentsOf: $0) }
        }
    }

    static func appendUInt16s(_ data: inout Data, _ values: [UInt16]) {
        for var v in values {
            v = v.littleEndian
            Swift.withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
    }

    static func appendUInt32LE(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
}
