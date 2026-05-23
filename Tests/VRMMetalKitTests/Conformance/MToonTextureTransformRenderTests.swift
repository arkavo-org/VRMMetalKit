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

/// VMK#288 — `KHR_texture_transform` on an MToon `baseColorTexture` must
/// actually shift / rotate / scale the sampled UVs. Pre-fix the parser
/// and uniform-population chain was wired correctly all the way down
/// to `MToonMaterial.textureTransform*` shader fields, but the vertex
/// shader fed `applyTextureTransform()` into `animatedTexCoord` only
/// while the fragment shader's primary sampler used the raw
/// `in.texCoord`. The transform never reached pixels for any asset
/// without a `uvAnimationMaskTexture`.
///
/// These tests synthesise a minimal textured VRM 1.0 in-memory — one
/// quad mesh, one MToon material, one 16×16 quadrant-checkerboard
/// texture — and render-hash each variant through the same harness as
/// `MToonShadingBoundaryRenderTests`. The checkerboard's four colored
/// quadrants (R/G/B/Y) make any UV transform produce visibly different
/// pixels.
final class MToonTextureTransformRenderTests: XCTestCase {

    private let renderWidth = 256
    private let renderHeight = 256
    private let cameraPosition = SIMD3<Float>(0, 0, 1.4)
    private let cameraTarget   = SIMD3<Float>(0, 0, 0)
    private let cameraUp       = SIMD3<Float>(0, 1, 0)
    private let cameraFovYDeg: Float = 30
    private let keyLightDir   = SIMD3<Float>(-0.3, -0.6, -0.7)
    private let keyLightColor = SIMD3<Float>(1, 1, 1)
    private let keyLightIntensity: Float = 1.0
    private let ambientColor: SIMD3<Float> = SIMD3<Float>(0.5, 0.5, 0.5) * 0.3

    /// Three offset variants must produce three distinct pixel hashes.
    /// Identity → `(0.5, 0)` → `(0, 0.5)` exercises the spec's
    /// `Offset.x` and `Offset.y` channels separately.
    func testOffsetSweepRendersDistinctHashes() async throws {
        try await assertDistinctHashes(transforms: [
            ("identity",  nil),
            ("offset_x",  .init(offset: SIMD2<Float>(0.5, 0))),
            ("offset_y",  .init(offset: SIMD2<Float>(0, 0.5))),
        ])
    }

    /// Rotation variants — identity → π/4 → π/2 — must produce three
    /// distinct hashes. π/2 rotates the four-color quadrant pattern
    /// 90° around the origin so all four colors land in different
    /// screen quadrants vs the identity sample.
    func testRotationSweepRendersDistinctHashes() async throws {
        try await assertDistinctHashes(transforms: [
            ("identity",        nil),
            ("rotation_eighth", .init(rotation: .pi / 4)),
            ("rotation_quarter",.init(rotation: .pi / 2)),
        ])
    }

    /// Scale variants — identity → 2x → 0.5x — must produce three
    /// distinct hashes. Scaling the UVs causes more (2x) or fewer
    /// (0.5x) tiles of the 4-color checkerboard to land within the
    /// quad's UV [0,1] range.
    func testScaleSweepRendersDistinctHashes() async throws {
        try await assertDistinctHashes(transforms: [
            ("identity", nil),
            ("scale_2x", .init(scale: SIMD2<Float>(2, 2))),
            ("scale_half", .init(scale: SIMD2<Float>(0.5, 0.5))),
        ])
    }

    // MARK: - Harness

    /// Renders each `(label, transform)` variant to a 256×256 PNG and
    /// asserts every hash is distinct. `nil` transform means the
    /// extension is omitted from the asset (identity baseline).
    private func assertDistinctHashes(
        transforms: [(label: String, transform: GLTFKHRTextureTransform?)]
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
        for (label, transform) in transforms {
            let glb = try Self.buildTexturedQuadVRMGLB(textureTransform: transform)
            let model = try await VRMModel.load(from: glb, device: device)
            hashes[label] = await MainActor.run {
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
        XCTAssertEqual(unique.count, transforms.count,
            "VMK#288: KHR_texture_transform must produce distinct pixels for each " +
            "variant. Got \(unique.count) distinct out of \(transforms.count) variants. " +
            "Hashes: \(hashes.map { "\($0.key) → \($0.value.prefix(8))" }.sorted().joined(separator: ", ")). " +
            "Collision means the static UV transform isn't reaching the fragment-side " +
            "samplers (the MToonShader.metal:296 / :910 vertex sites must apply " +
            "`applyTextureTransform` to `texCoord` directly).")
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

    // MARK: - Minimal textured VRM GLB builder

    /// Builds a minimal valid VRM 1.0 GLB containing a single textured
    /// quad facing +Z, with one MToon material that references a 16×16
    /// procedural quadrant-checkerboard PNG. The supplied
    /// `textureTransform` (if non-nil) lands in
    /// `material.pbrMetallicRoughness.baseColorTexture.extensions.KHR_texture_transform`.
    private static func buildTexturedQuadVRMGLB(
        textureTransform: GLTFKHRTextureTransform?
    ) throws -> Data {
        // Binary chunk layout (everything offsets are bytes from BIN start):
        //   positions  (4 × VEC3 float = 48 bytes)
        //   normals    (4 × VEC3 float = 48 bytes)
        //   uvs        (4 × VEC2 float = 32 bytes)
        //   indices    (6 × ushort   = 12 bytes, padded to 4)
        //   pngBytes   (varies)
        var bin = Data()

        // Quad in the xy plane, facing +Z, spanning [-1, 1] × [-1, 1].
        let positions: [Float] = [
            -1, -1, 0,
             1, -1, 0,
             1,  1, 0,
            -1,  1, 0,
        ]
        let normals: [Float] = [
            0, 0, 1,
            0, 0, 1,
            0, 0, 1,
            0, 0, 1,
        ]
        let uvs: [Float] = [
            0, 1,  // bottom-left -> UV(0,1)  (glTF: UV origin top-left)
            1, 1,
            1, 0,
            0, 0,
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
        // Pad to 4-byte boundary before the image bytes.
        while bin.count % 4 != 0 { bin.append(0) }

        let pngBytes = try makeQuadrantCheckerboardPNG()
        let imageOffset = bin.count
        bin.append(pngBytes)
        let imageLength = pngBytes.count
        while bin.count % 4 != 0 { bin.append(0) }

        // Build glTF JSON. KHR_texture_transform only appears under
        // `extensionsUsed` and on the textureInfo when present.
        var extensionsUsed: [String] = ["VRMC_vrm", "VRMC_materials_mtoon"]
        if textureTransform != nil { extensionsUsed.append("KHR_texture_transform") }

        var baseColorTexture: [String: Any] = ["index": 0]
        if let xform = textureTransform {
            baseColorTexture["extensions"] = [
                "KHR_texture_transform": [
                    "offset": [Double(xform.offset.x), Double(xform.offset.y)],
                    "rotation": Double(xform.rotation),
                    "scale": [Double(xform.scale.x), Double(xform.scale.y)],
                ]
            ]
        }

        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "VMK288-test"],
            "extensionsUsed": extensionsUsed,
            "extensions": [
                "VRMC_vrm": [
                    "specVersion": "1.0",
                    "meta": [
                        "name": "vmk288-fixture",
                        "version": "1.0",
                        "authors": ["VMK288 test"],
                        "licenseUrl": "https://vrm.dev/licenses/1.0/",
                    ],
                    // VRMModel.load() calls validate() which requires the
                    // 15 standard humanoid bones to map to *some* node.
                    // We map them all to node 0 — the mesh root — since
                    // this fixture doesn't exercise skinning. The render
                    // doesn't read the bone-to-node mapping; it only needs
                    // validate() to pass.
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
                    "baseColorFactor": [1, 1, 1, 1],
                    "baseColorTexture": baseColorTexture,
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

    /// Generates a 16×16 RGBA PNG with four colored quadrants — red TL,
    /// green TR, blue BL, yellow BR — so a UV transform produces a
    /// visibly different rendered output across variants.
    private static func makeQuadrantCheckerboardPNG() throws -> Data {
        let size = 16
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let half = size / 2
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
            throw NSError(domain: "MToonTextureTransformRenderTests",
                          code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create CGImage"])
        }

        let cfData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            cfData as CFMutableData,
            UTType.png.identifier as CFString,
            1, nil
        ) else {
            throw NSError(domain: "MToonTextureTransformRenderTests",
                          code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create PNG destination"])
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "MToonTextureTransformRenderTests",
                          code: 3,
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

    // MARK: - Math + texture helpers (copy of conformance camera convention)

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
