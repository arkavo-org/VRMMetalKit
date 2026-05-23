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

/// VMK#289 — MToon's `outlineWidthMultiplyTexture` was set on the
/// fragment uniform side (`hasOutlineWidthMultiplyTexture = 1`) but
/// the renderer never called `setVertexTexture` for the outline pass.
/// The outline vertex shader sampled an unbound texture slot, the
/// resulting `widthMultiplier` was undefined (effectively zero in
/// practice), and the multiplication zeroed the outline width — which
/// cascaded into making `outlineWidthFactor` and `outlineWidthMode`
/// observationally inert. Plus the shader was sampling `.r` while the
/// VRMC_materials_mtoon-1.0 spec explicitly specifies G.
///
/// vrm-conformance reproducer: 5 variants of `outlineWidthMultiplyTexture`
/// (mode/factor sweep) produced 3 byte-identical hashes on VMK while
/// three-vrm produced 5 distinct outputs.
///
/// This test asserts the three axes the spec mandates are independently
/// honoured at render time.
final class MToonOutlineWidthMultiplyTextureRenderTests: XCTestCase {

    private let renderWidth = 256
    private let renderHeight = 256
    // Off-axis camera so the cube shows three faces — silhouette edges
    // (where outline modulation is most visible) cross the image.
    private let cameraPosition = SIMD3<Float>(1.2, 0.9, 1.6)
    private let cameraTarget   = SIMD3<Float>(0, 0, 0)
    private let cameraUp       = SIMD3<Float>(0, 1, 0)
    private let cameraFovYDeg: Float = 30
    private let keyLightDir   = SIMD3<Float>(-0.3, -0.6, -0.7)
    private let keyLightColor = SIMD3<Float>(1, 1, 1)
    private let keyLightIntensity: Float = 1.0
    private let ambientColor: SIMD3<Float> = SIMD3<Float>(0.5, 0.5, 0.5) * 0.3

    private enum OutlineMode: String { case world = "worldCoordinates", screen = "screenCoordinates" }

    /// All three spec axes (texture-modulated G channel, factor, and
    /// mode) must independently affect the rendered output. Pre-fix all
    /// four texture-present variants collapsed to the same hash.
    func testOutlineMultiplyTexturePathHonoursAllThreeAxes() async throws {
        // Larger outline factors than the conformance sweep so the
        // pixel-level effect of varying factor is super-resolved at the
        // 256×256 render size used here (the conformance suite renders
        // at 1024×1024). 0.20 and 0.50 are well within the spec's
        // [0, 1] guideline; the shader's distanceScale further attenuates
        // the world-space extrusion to a few pixels.
        try await assertDistinctHashes(variants: [
            ("baseline_no_texture",       false, .world,  0.20),
            ("texture_world_factor_20",   true,  .world,  0.20),
            ("texture_screen_factor_20",  true,  .screen, 0.20),
            ("texture_world_factor_50",   true,  .world,  0.50),
        ])
    }

    // MARK: - Harness

    private func assertDistinctHashes(
        variants: [(label: String, hasMultiplyTexture: Bool, mode: OutlineMode, factor: Float)]
    ) async throws {
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

        var hashes: [String: String] = [:]
        for variant in variants {
            let glb = try Self.buildOutlineFixtureVRMGLB(
                hasMultiplyTexture: variant.hasMultiplyTexture,
                outlineMode: variant.mode.rawValue,
                outlineFactor: variant.factor
            )
            let model = try await VRMModel.load(from: glb, device: device)
            hashes[variant.label] = await MainActor.run {
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
        XCTAssertEqual(unique.count, variants.count,
            "VMK#289: outlineWidthMultiplyTexture path must honour all three " +
            "axes (G-channel modulation, outlineWidthFactor, outlineWidthMode). " +
            "Got \(unique.count) distinct out of \(variants.count) variants. " +
            "Hashes: " +
            "\(hashes.map { "\($0.key) → \($0.value.prefix(8))" }.sorted().joined(separator: ", ")). " +
            "Pre-fix the four texture-present variants collapsed to a single " +
            "hash because the renderer never bound the multiply texture to " +
            "the outline vertex stage — `widthMultiplier` sampled an unbound " +
            "slot, the outline-width product zeroed, and mode/factor became " +
            "inert.")
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

    // MARK: - Minimal outline-multiply VRM GLB builder

    /// Builds a minimal valid VRM 1.0 GLB with one MToon material whose
    /// outline parameters are configurable. When `hasMultiplyTexture` is
    /// true, attaches a 16×16 RGBY quadrant-checkerboard texture as
    /// `outlineWidthMultiplyTexture` so the G channel modulates outline
    /// width per quadrant (G=0 in R/B quadrants, G=255 in G/Y quadrants).
    private static func buildOutlineFixtureVRMGLB(
        hasMultiplyTexture: Bool,
        outlineMode: String,
        outlineFactor: Float
    ) throws -> Data {
        var bin = Data()

        // Cube centred at origin, faces ±0.5 — inverted-hull outline
        // rendering needs a closed mesh so back faces become the
        // silhouette after the outline pass culls front-facing
        // triangles. A flat quad fixture would produce no outline at
        // all because culling .front against a CCW front face removes
        // the only visible geometry.
        let positions: [Float] = [
            // +Z face (front)
            -0.5, -0.5,  0.5,   0.5, -0.5,  0.5,   0.5,  0.5,  0.5,  -0.5,  0.5,  0.5,
            // -Z face (back)
             0.5, -0.5, -0.5,  -0.5, -0.5, -0.5,  -0.5,  0.5, -0.5,   0.5,  0.5, -0.5,
            // +X face (right)
             0.5, -0.5,  0.5,   0.5, -0.5, -0.5,   0.5,  0.5, -0.5,   0.5,  0.5,  0.5,
            // -X face (left)
            -0.5, -0.5, -0.5,  -0.5, -0.5,  0.5,  -0.5,  0.5,  0.5,  -0.5,  0.5, -0.5,
            // +Y face (top)
            -0.5,  0.5,  0.5,   0.5,  0.5,  0.5,   0.5,  0.5, -0.5,  -0.5,  0.5, -0.5,
            // -Y face (bottom)
            -0.5, -0.5, -0.5,   0.5, -0.5, -0.5,   0.5, -0.5,  0.5,  -0.5, -0.5,  0.5,
        ]
        let normals: [Float] = [
            0, 0, 1,  0, 0, 1,  0, 0, 1,  0, 0, 1,    // +Z
            0, 0, -1, 0, 0, -1, 0, 0, -1, 0, 0, -1,   // -Z
            1, 0, 0,  1, 0, 0,  1, 0, 0,  1, 0, 0,    // +X
            -1, 0, 0, -1, 0, 0, -1, 0, 0, -1, 0, 0,   // -X
            0, 1, 0,  0, 1, 0,  0, 1, 0,  0, 1, 0,    // +Y
            0, -1, 0, 0, -1, 0, 0, -1, 0, 0, -1, 0,   // -Y
        ]
        // Each face maps the full UV square [0,1]×[0,1] — the
        // checkerboard's four quadrants land on every face so the
        // G-channel sample varies across each face.
        let uvs: [Float] = [
            0, 1,  1, 1,  1, 0,  0, 0,   // +Z
            0, 1,  1, 1,  1, 0,  0, 0,   // -Z
            0, 1,  1, 1,  1, 0,  0, 0,   // +X
            0, 1,  1, 1,  1, 0,  0, 0,   // -X
            0, 1,  1, 1,  1, 0,  0, 0,   // +Y
            0, 1,  1, 1,  1, 0,  0, 0,   // -Y
        ]
        // Each face: two triangles, indices 4k+0,1,2 and 4k+0,2,3.
        var indices: [UInt16] = []
        for f in 0..<6 {
            let base = UInt16(f * 4)
            indices.append(contentsOf: [base, base+1, base+2, base, base+2, base+3])
        }

        let positionsOffset = bin.count
        appendFloats(&bin, positions); let positionsLength = bin.count - positionsOffset
        let normalsOffset = bin.count
        appendFloats(&bin, normals);   let normalsLength = bin.count - normalsOffset
        let uvsOffset = bin.count
        appendFloats(&bin, uvs);       let uvsLength = bin.count - uvsOffset
        let indicesOffset = bin.count
        appendUInt16s(&bin, indices);  let indicesLength = bin.count - indicesOffset
        while bin.count % 4 != 0 { bin.append(0) }

        var imageOffset = 0
        var imageLength = 0
        if hasMultiplyTexture {
            let pngBytes = try makeQuadrantCheckerboardPNG()
            imageOffset = bin.count
            bin.append(pngBytes)
            imageLength = pngBytes.count
            while bin.count % 4 != 0 { bin.append(0) }
        }

        var mtoonExtension: [String: Any] = [
            "specVersion": "1.0",
            "transparentWithZWrite": false,
            "renderQueueOffsetNumber": 0,
            "outlineWidthMode": outlineMode,
            "outlineWidthFactor": Double(outlineFactor),
            "outlineColorFactor": [0, 0, 0],
        ]
        if hasMultiplyTexture {
            mtoonExtension["outlineWidthMultiplyTexture"] = ["index": 0]
        }

        var bufferViews: [[String: Any]] = [
            ["buffer": 0, "byteOffset": positionsOffset, "byteLength": positionsLength],
            ["buffer": 0, "byteOffset": normalsOffset,   "byteLength": normalsLength],
            ["buffer": 0, "byteOffset": uvsOffset,       "byteLength": uvsLength],
            ["buffer": 0, "byteOffset": indicesOffset,   "byteLength": indicesLength],
        ]
        if hasMultiplyTexture {
            bufferViews.append(["buffer": 0, "byteOffset": imageOffset, "byteLength": imageLength])
        }

        var json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "VMK289-test"],
            "extensionsUsed": ["VRMC_vrm", "VRMC_materials_mtoon"],
            "extensions": [
                "VRMC_vrm": [
                    "specVersion": "1.0",
                    "meta": [
                        "name": "vmk289-fixture",
                        "version": "1.0",
                        "authors": ["VMK289 test"],
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
                    "attributes": ["POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2],
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
                "doubleSided": true,
                "extensions": ["VRMC_materials_mtoon": mtoonExtension],
            ]],
            "buffers": [["byteLength": bin.count]],
            "bufferViews": bufferViews,
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": 24,
                 "type": "VEC3", "min": [-0.5, -0.5, -0.5], "max": [0.5, 0.5, 0.5]],
                ["bufferView": 1, "componentType": 5126, "count": 24, "type": "VEC3"],
                ["bufferView": 2, "componentType": 5126, "count": 24, "type": "VEC2"],
                ["bufferView": 3, "componentType": 5123, "count": 36, "type": "SCALAR"],
            ],
        ]
        if hasMultiplyTexture {
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

    /// 16×16 RGBA quadrant checkerboard: R top-left, G top-right, B
    /// bottom-left, Y bottom-right. G-channel values per quadrant:
    /// R=0, G=255, B=0, Y=255 — gives the outline-width multiplier
    /// distinct G values across the quad's UV space.
    private static func makeQuadrantCheckerboardPNG() throws -> Data {
        let size = 16
        let half = size / 2
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let topHalf = y < half
                let leftHalf = x < half
                let (r, g, b): (UInt8, UInt8, UInt8) = {
                    if topHalf && leftHalf  { return (255,   0,   0) } // red
                    if topHalf && !leftHalf { return (0,   255,   0) } // green
                    if !topHalf && leftHalf { return (0,     0, 255) } // blue
                    return                        (255, 255,   0)     // yellow
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
            throw NSError(domain: "MToonOutlineWidthMultiplyTextureRenderTests",
                          code: 1, userInfo: [NSLocalizedDescriptionKey: "CGImage failed"])
        }

        let cfData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            cfData as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw NSError(domain: "MToonOutlineWidthMultiplyTextureRenderTests",
                          code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG dest failed"])
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "MToonOutlineWidthMultiplyTextureRenderTests",
                          code: 3, userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
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
