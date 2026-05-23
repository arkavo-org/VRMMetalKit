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
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import VRMMetalKit

/// VMK#290 — glTF 2.0 `normalTextureInfo.scale` was silently dropped on
/// MToon materials. The parser read `normalTexture.index` but never
/// `.scale`, and the shader sampled the unpacked normal without the
/// `vec3(scale, scale, 1.0)` amplification the spec defines. As a
/// result, every `scale` value rendered identically — verified by the
/// vrm-conformance `mtoon_pbrtex_normal_*` sweep producing one VMK hash
/// across multiple declared scales, while UniVRM and three-vrm both
/// produced distinct outputs.
///
/// This test synthesises a textured VRM 1.0 in-memory with a
/// procedural tangent-space normal map and asserts that three distinct
/// `scale` values (0.5, 1.0, 2.0) produce three distinct render hashes.
final class MToonNormalScaleRenderTests: XCTestCase {

    private let renderWidth = 256
    private let renderHeight = 256
    private let cameraPosition = SIMD3<Float>(0, 0, 1.4)
    private let cameraTarget   = SIMD3<Float>(0, 0, 0)
    private let cameraUp       = SIMD3<Float>(0, 1, 0)
    private let cameraFovYDeg: Float = 30
    // Side lighting maximises sensitivity to normal-map perturbations —
    // direct top-down or front lighting would minimise the visible effect
    // of varying the normal-scale amplification factor.
    private let keyLightDir   = SIMD3<Float>(-0.7, -0.3, -0.7)
    private let keyLightColor = SIMD3<Float>(1, 1, 1)
    private let keyLightIntensity: Float = 1.0
    private let ambientColor: SIMD3<Float> = SIMD3<Float>(0.5, 0.5, 0.5) * 0.3

    /// Three `scale` variants must produce three distinct hashes.
    /// 0.5 attenuates the perturbation, 1.0 is the spec default,
    /// 2.0 amplifies — each lands a different shading boundary on the
    /// rendered checkerboard.
    func testNormalScaleSweepRendersDistinctHashes() async throws {
        try await assertDistinctHashes(scales: [0.5, 1.0, 2.0])
    }

    // MARK: - Harness

    private func assertDistinctHashes(scales: [Float]) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }
        guard let queue = device.makeCommandQueue() else {
            XCTFail("Could not create command queue"); return
        }

        let cameraPos = cameraPosition
        let cameraTgt = cameraTarget
        let cameraUpV = cameraUp
        let fovYDeg = cameraFovYDeg
        let lightDir = keyLightDir
        let lightCol = keyLightColor
        let lightInt = keyLightIntensity
        let ambient = ambientColor
        let w = renderWidth
        let h = renderHeight

        var hashes: [Float: String] = [:]
        for scale in scales {
            let glb = try Self.buildNormalMappedQuadVRMGLB(normalScale: scale)
            let model = try await VRMModel.load(from: glb, device: device)
            hashes[scale] = await MainActor.run {
                Self.renderModelToHash(
                    model: model, device: device, commandQueue: queue,
                    cameraPosition: cameraPos, cameraTarget: cameraTgt, cameraUp: cameraUpV,
                    cameraFovYDeg: fovYDeg,
                    keyLightDir: lightDir, keyLightColor: lightCol, keyLightIntensity: lightInt,
                    ambientColor: ambient,
                    renderWidth: w, renderHeight: h
                )
            }
        }

        let unique = Set(hashes.values)
        XCTAssertEqual(unique.count, scales.count,
            "VMK#290: normalTexture.scale must produce distinct pixels for " +
            "each value. Got \(unique.count) distinct out of \(scales.count) " +
            "scales. Hashes: " +
            "\(hashes.map { "scale=\($0.key) → \($0.value.prefix(8))" }.sorted().joined(separator: ", ")). " +
            "Collision means the per-textureInfo scale isn't reaching the " +
            "MToon fragment shader's normal-map perturbation path.")
    }

    @MainActor
    private static func renderModelToHash(
        model: VRMModel,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        cameraPosition: SIMD3<Float>,
        cameraTarget: SIMD3<Float>,
        cameraUp: SIMD3<Float>,
        cameraFovYDeg: Float,
        keyLightDir: SIMD3<Float>,
        keyLightColor: SIMD3<Float>,
        keyLightIntensity: Float,
        ambientColor: SIMD3<Float>,
        renderWidth: Int,
        renderHeight: Int
    ) -> String {
        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        config.synchronousSpringBone = true
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)

        let aspect = Float(renderWidth) / Float(renderHeight)
        let fovY = cameraFovYDeg * .pi / 180
        renderer.projectionMatrix = perspectiveProjection(
            fovY: fovY, aspect: aspect, near: 0.05, far: 100
        )
        renderer.viewMatrix = lookAt(
            eye: cameraPosition, target: cameraTarget, up: cameraUp
        )
        renderer.setLight(0, direction: keyLightDir, color: keyLightColor,
                          intensity: keyLightIntensity)
        renderer.setAmbientColor(ambientColor)

        let colorTexture = makeTexture(
            device: device, width: renderWidth, height: renderHeight,
            format: .bgra8Unorm, usage: [.renderTarget, .shaderRead], storage: .shared
        )
        let depthTexture = makeTexture(
            device: device, width: renderWidth, height: renderHeight,
            format: .depth32Float, usage: [.renderTarget], storage: .private
        )
        guard let cb = commandQueue.makeCommandBuffer() else {
            XCTFail("makeCommandBuffer failed"); return ""
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = colorTexture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.depthAttachment.texture = depthTexture
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.storeAction = .dontCare
        rpd.depthAttachment.clearDepth = 1.0
        renderer.drawOffscreenHeadless(to: colorTexture, depth: depthTexture,
                                        commandBuffer: cb, renderPassDescriptor: rpd)
        let sem = DispatchSemaphore(value: 0)
        cb.addCompletedHandler { _ in sem.signal() }
        cb.commit()
        sem.wait()

        let bytesPerRow = renderWidth * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * renderHeight)
        pixels.withUnsafeMutableBufferPointer { ptr in
            colorTexture.getBytes(ptr.baseAddress!, bytesPerRow: bytesPerRow,
                                  from: MTLRegionMake2D(0, 0, renderWidth, renderHeight),
                                  mipmapLevel: 0)
        }
        let digest = SHA256.hash(data: Data(pixels))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Minimal normal-mapped VRM GLB builder

    /// Builds a minimal valid VRM 1.0 GLB with a single quad facing +Z,
    /// one MToon material with `pbrMetallicRoughness.normalTexture`
    /// pointing at a procedural 16×16 tangent-space normal map with
    /// distinct per-quadrant directions. The supplied `normalScale` lands
    /// on `material.normalTexture.scale`.
    private static func buildNormalMappedQuadVRMGLB(normalScale: Float) throws -> Data {
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

        let pngBytes = try makeQuadrantNormalMapPNG()
        let imageOffset = bin.count
        bin.append(pngBytes)
        let imageLength = pngBytes.count
        while bin.count % 4 != 0 { bin.append(0) }

        // normalTexture is a glTF-core textureInfo; `scale` is a sibling
        // of `index` on that struct (not under `extensions`).
        let normalTextureJSON: [String: Any] = [
            "index": 0,
            "scale": Double(normalScale),
        ]

        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "VMK290-test"],
            "extensionsUsed": ["VRMC_vrm", "VRMC_materials_mtoon"],
            "extensions": [
                "VRMC_vrm": [
                    "specVersion": "1.0",
                    "meta": [
                        "name": "vmk290-fixture",
                        "version": "1.0",
                        "authors": ["VMK290 test"],
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
            "materials": [[
                "name": "fixture-mtoon",
                "pbrMetallicRoughness": [
                    "baseColorFactor": [0.7, 0.7, 0.7, 1],
                    "metallicFactor": 0,
                    "roughnessFactor": 1,
                ],
                "normalTexture": normalTextureJSON,
                "doubleSided": true,
                "extensions": [
                    "VRMC_materials_mtoon": [
                        "specVersion": "1.0",
                        "transparentWithZWrite": false,
                        "renderQueueOffsetNumber": 0,
                    ],
                ],
            ]],
            "textures": [["source": 0, "sampler": 0]],
            "samplers": [[
                "magFilter": 9729, "minFilter": 9729,
                "wrapS": 10497, "wrapT": 10497,
            ]],
            "images": [["bufferView": 4, "mimeType": "image/png"]],
            "buffers": [["byteLength": bin.count]],
            "bufferViews": [
                ["buffer": 0, "byteOffset": positionsOffset, "byteLength": positionsLength],
                ["buffer": 0, "byteOffset": normalsOffset,   "byteLength": normalsLength],
                ["buffer": 0, "byteOffset": uvsOffset,       "byteLength": uvsLength],
                ["buffer": 0, "byteOffset": indicesOffset,   "byteLength": indicesLength],
                ["buffer": 0, "byteOffset": imageOffset,     "byteLength": imageLength],
            ],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": 4,
                 "type": "VEC3", "min": [-1, -1, 0], "max": [1, 1, 0]],
                ["bufferView": 1, "componentType": 5126, "count": 4, "type": "VEC3"],
                ["bufferView": 2, "componentType": 5126, "count": 4, "type": "VEC2"],
                ["bufferView": 3, "componentType": 5123, "count": 6, "type": "SCALAR"],
            ],
        ]

        var jsonData = try JSONSerialization.data(withJSONObject: json, options: [])
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }

        let total = 12 + 8 + jsonData.count + 8 + bin.count
        var glb = Data()
        glb.appendUInt32LE(0x46546C67)
        glb.appendUInt32LE(2)
        glb.appendUInt32LE(UInt32(total))
        glb.appendUInt32LE(UInt32(jsonData.count))
        glb.appendUInt32LE(0x4E4F534A)
        glb.append(jsonData)
        glb.appendUInt32LE(UInt32(bin.count))
        glb.appendUInt32LE(0x004E4942)
        glb.append(bin)
        return glb
    }

    /// 16×16 RGBA tangent-space normal map with four distinct quadrant
    /// directions. Quadrant normals are encoded per the glTF spec
    /// `byte = (xyz + 1) * 127.5`. The four directions are deliberately
    /// asymmetric so a side-lit render shows different shading per
    /// quadrant — which is what makes scale variation visible.
    private static func makeQuadrantNormalMapPNG() throws -> Data {
        let size = 16
        let half = size / 2
        // Tangent-space normals per quadrant: TL/TR/BL/BR each tilted 30°
        // in distinct directions so the side-lit shading differs visibly
        // when the perturbation is amplified by `scale`.
        func encode(_ x: Float, _ y: Float, _ z: Float) -> (UInt8, UInt8, UInt8) {
            (UInt8(min(255, max(0, (x + 1) * 127.5))),
             UInt8(min(255, max(0, (y + 1) * 127.5))),
             UInt8(min(255, max(0, (z + 1) * 127.5))))
        }
        // 30° tilts in four diagonal directions
        let s = sin(Float.pi / 6)   // sin 30° ≈ 0.5
        let c = cos(Float.pi / 6)   // cos 30° ≈ 0.866
        let tl = encode(-s, +s, c)
        let tr = encode(+s, +s, c)
        let bl = encode(-s, -s, c)
        let br = encode(+s, -s, c)

        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let (r, g, b): (UInt8, UInt8, UInt8) = {
                    if y < half && x < half  { return tl }
                    if y < half && x >= half { return tr }
                    if y >= half && x < half { return bl }
                    return br
                }()
                let i = (y * size + x) * 4
                pixels[i+0] = r
                pixels[i+1] = g
                pixels[i+2] = b
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
            throw NSError(domain: "MToonNormalScaleRenderTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create CGImage"])
        }

        let cfData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            cfData as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw NSError(domain: "MToonNormalScaleRenderTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create PNG destination"])
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "MToonNormalScaleRenderTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
        }
        return cfData as Data
    }

    private static func appendFloats(_ data: inout Data, _ floats: [Float]) {
        for var f in floats {
            Swift.withUnsafeBytes(of: &f) { data.append(contentsOf: $0) }
        }
    }

    private static func appendUInt16s(_ data: inout Data, _ values: [UInt16]) {
        for var v in values {
            v = v.littleEndian
            Swift.withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
    }

    // MARK: - Math + texture helpers

    private static func perspectiveProjection(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
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

    private static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
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

    private static func makeTexture(
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
}

private extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
