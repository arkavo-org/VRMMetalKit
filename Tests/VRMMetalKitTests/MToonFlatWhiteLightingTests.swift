// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0

import XCTest
import Metal
import simd
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import VRMMetalKit

/// Regression / instrumentation for vrm-conformance issue #183:
/// "Generated VRM sphere renders as flat white — MToon per-pixel lighting not applied".
///
/// The QA team's N-way cross-renderer suite caught a default-MToon sphere
/// (baseColor=1, shadeColor=0.5, toony=0.9) rendering as a uniform (255,255,255)
/// in vrm-metal-kit, whereas three-vrm shows the expected directional gradient
/// with shadeColor reaching the shadow side. Even with `shadingToonyFactor=0.0`
/// (which should produce a smooth NdotL gradient instead of the binary toon ramp),
/// vrm-metal-kit's output is still uniformly white. SSIM vs three-vrm: 0.71
/// (threshold 0.985).
///
/// This test reproduces the symptom in a minimal in-process repro:
/// two triangles with opposite vertex normals, lit from a known direction.
/// A correctly-functioning MToon shader yields a clearly brighter pixel on
/// the lit-side triangle than on the shadow-side triangle. The bug manifests
/// as the two pixel values being essentially equal (and both saturating to
/// white).
@MainActor
final class MToonFlatWhiteLightingTests: XCTestCase {

    private var device: MTLDevice!

    private func ensureDevice() throws {
        if device != nil { return }
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available on this host")
        }
        device = dev
    }

    /// Two identical triangles, separated in NDC, with **opposite vertex normals**.
    /// A single key light shines from +Y (set so the "up-facing" triangle is lit
    /// and the "down-facing" triangle is in shadow). Asserts the lit triangle's
    /// rendered color is noticeably brighter than the shadow triangle's, with
    /// `shadingToonyFactor=0.0` (smooth gradient, the case the reporter said
    /// also fails for vrm-metal-kit).
    func testMToonShadingProducesGradientWithSmoothToon() throws {
        try ensureDevice()
        let model = try makeTwoNormalTrianglesModel(toony: 0.0)

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        let renderer = VRMRenderer(device: device, config: config)
        renderer.performanceTracker = PerformanceTracker()
        renderer.loadModel(model)
        renderer.viewMatrix = matrix_identity_float4x4
        renderer.projectionMatrix = matrix_identity_float4x4

        // VRMMetalKit convention: `setLight(direction:)` stores the parameter
        // verbatim in `uniforms.lightDirection`; the shader computes
        // `NdotL = dot(normal, -uniforms.lightDirection.xyz)`. So direction `(0,1,0)`
        // is "light shines toward +Y", which lights -Y-facing surfaces.
        renderer.setLight(0, direction: SIMD3<Float>(0, 1, 0), color: SIMD3<Float>(1, 1, 1), intensity: 1.0)
        renderer.disableLight(1)
        renderer.disableLight(2)
        renderer.setAmbientColor(SIMD3<Float>(0, 0, 0))

        let pixels = try renderOneOffscreenFrame(renderer: renderer)
        // With light direction `(0,1,0)`, -Y normals (bottom-left quadrant) are lit;
        // +Y normals (top-right quadrant) are in shadow.
        let litLuma = sampleLuma(pixels, quadrant: .bottomLeft)
        let shadowLuma = sampleLuma(pixels, quadrant: .topRight)

        print("[#183 toony=0] litLuma=\(litLuma) shadowLuma=\(shadowLuma) ratio=\(litLuma > 0 ? shadowLuma / litLuma : 0)")
        printPixelMap(pixels, prefix: "[#183 toony=0 pixmap]")

        // baseColor=(1,1,1), shadeColor=(0.5,0.5,0.5):
        //   lit-side: shadowStep≈1 → mix(0.5,1,1) = 1.0
        //   shadow-side: shadowStep≈0 → mix(0.5,1,0) = 0.5
        // Pre-fix the reporter observes both ≈ 1.0 (flat white).
        XCTAssertGreaterThan(litLuma, 0.0,
            "Lit triangle must produce non-zero output (geometry/material bound).")
        XCTAssertGreaterThan(shadowLuma, 0.0,
            "Shadow triangle must produce non-zero output too — full black means " +
            "shadeColor wasn't applied or normals are wrong.")
        XCTAssertGreaterThan(litLuma - shadowLuma, 0.10,
            "Lit / shadow pixel luminance must differ by >0.10 with shadeColor=0.5 + " +
            "toony=0. If they're equal, MToon lighting isn't being applied to this " +
            "asset class (factor-only MToon material with no textures) — that's #183.")
    }

    /// End-to-end repro driven from the real `.vrm` produced by
    /// vrm-conformance's `emit-default --id mtoon_default` (the exact asset the
    /// QA bug report quotes byte-for-byte centerline samples from). Configures
    /// camera + lighting from `mtoon_default.test.yaml` verbatim, renders
    /// 256x256 (smaller than QA's 1024 for test speed but same camera framing),
    /// reads back the centerline column, and asserts the dim-to-bright luma
    /// range exceeds a small threshold. Skips if the asset isn't available.
    func testQAEmittedAssetProducesLightingGradient() async throws {
        try ensureDevice()
        let path = "/tmp/repro183/mtoon_default.vrm"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("QA repro asset not at \(path). Build with: " +
                "cd /Users/arkavo/Projects/vrm-conformance && cargo run --release -p vrm-asset-generator -- emit-default --id mtoon_default --output-dir /tmp/repro183")
        }

        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        let renderer = VRMRenderer(device: device, config: config)
        renderer.performanceTracker = PerformanceTracker()
        renderer.loadModel(model)

        // Camera: match mtoon_default.test.yaml.
        let aspect: Float = 1.0
        let fov: Float = 30.0 * .pi / 180.0
        renderer.projectionMatrix = makePerspective(fovRadians: fov, aspect: aspect, near: 0.01, far: 100.0)
        renderer.viewMatrix = makeLookAt(
            eye:    SIMD3<Float>(0.0, 1.4, 1.5),
            center: SIMD3<Float>(0.0, 1.4, 0.0),
            up:     SIMD3<Float>(0.0, 1.0, 0.0)
        )

        // Lighting: single directional + ambient, exactly as the QA test plan.
        // Test-plan `dir = (-0.3, -0.6, -0.7)`. The conformance adapter negates
        // before calling setLight (its convention bridge), so we do the same.
        renderer.setLight(
            0,
            direction: -SIMD3<Float>(-0.3, -0.6, -0.7),
            color: SIMD3<Float>(1.0, 1.0, 1.0),
            intensity: 1.0
        )
        renderer.disableLight(1)
        renderer.disableLight(2)
        renderer.setAmbientColor(SIMD3<Float>(0.5, 0.5, 0.5) * 0.3)  // ambient * intensity

        let size = 256
        let pixels = try renderArbitrary(renderer: renderer, size: size, clear: (12, 16, 27))

        // Optional: dump the rendered pixels to a PNG for side-by-side comparison
        // against VRMRender output (`VRM183_DUMP_PNG=/path`). Off by default so
        // CI doesn't need write permission.
        if let dumpPath = ProcessInfo.processInfo.environment["VRM183_DUMP_PNG"] {
            try dumpBGRA(pixels: pixels, size: size, to: URL(fileURLWithPath: dumpPath))
        }

        // Compute min/max luma over the full sphere region (not just the
        // centerline — the QA's report samples y in [35%, 65%] but for this
        // asset's camera + light direction the lit highlight falls outside
        // that band; the entire centerline is in the uniform shadow region).
        let stats = lumaStatsOverSphere(pixels, size: size)
        print("[#183 e2e] sphere luma stats: min=\(stats.min) max=\(stats.max) range=\(stats.max - stats.min) count=\(stats.count)")
        printPixelMap(pixels, size: size, prefix: "[#183 e2e pixmap]")

        XCTAssertGreaterThan(stats.count, 100, "Sphere not visible — geometry/camera setup broken.")
        // Pre-fix #183 the entire visible sphere renders at exactly 1.0 (uniform
        // white). Post-fix it shows a clear shadow-to-lit gradient. Even with
        // the conservative threshold of 0.15, the gradient must register —
        // measured post-fix range is ≈ 0.36 (shadow 0.64 → lit-edge ≈ 1.0).
        XCTAssertGreaterThan(stats.max - stats.min, 0.15,
            "Sphere luma range (\(stats.max - stats.min)) below 0.15 — the whole " +
            "visible sphere renders at one brightness level (#183 flat-white). " +
            "MToon lighting collapsed for factor-only assets going through the " +
            "full VRMModel.load(...) path.")
    }

    /// Scan the rendered framebuffer for non-clear pixels and return luma min/max/count.
    private func lumaStatsOverSphere(_ bytes: [UInt8], size: Int) -> (min: Float, max: Float, count: Int) {
        var lo: Float = 1.0
        var hi: Float = 0.0
        var count = 0
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let b = bytes[i], g = bytes[i + 1], r = bytes[i + 2]
                if r < 40 && g < 40 && b < 40 { continue }   // clear sentinel
                let rF: Float = 0.2126 * Float(r)
                let gF: Float = 0.7152 * Float(g)
                let bF: Float = 0.0722 * Float(b)
                let luma = (rF + gF + bF) / 255.0
                if luma < lo { lo = luma }
                if luma > hi { hi = luma }
                count += 1
            }
        }
        return (lo, hi, count)
    }

    /// Same scaffolding, but `shadingToonyFactor=0.9` (the QA reporter's default).
    /// At 0.9 the toon ramp's transition window is narrow (`[-0.1, 0.1]`) so most
    /// of the visible hemisphere saturates to `shadowStep=1.0` even when MToon is
    /// working correctly. The shadow-side triangle (raw NdotL = -1) sits near the
    /// dim end of the Half-Lambert remap (0.0) and should still pick up shadeColor.
    func testMToonShadingProducesContrastWithDefaultToon() throws {
        try ensureDevice()
        let model = try makeTwoNormalTrianglesModel(toony: 0.9)

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        let renderer = VRMRenderer(device: device, config: config)
        renderer.performanceTracker = PerformanceTracker()
        renderer.loadModel(model)
        renderer.viewMatrix = matrix_identity_float4x4
        renderer.projectionMatrix = matrix_identity_float4x4

        renderer.setLight(0, direction: SIMD3<Float>(0, 1, 0), color: SIMD3<Float>(1, 1, 1), intensity: 1.0)
        renderer.disableLight(1)
        renderer.disableLight(2)
        renderer.setAmbientColor(SIMD3<Float>(0, 0, 0))

        let pixels = try renderOneOffscreenFrame(renderer: renderer)
        let litLuma = sampleLuma(pixels, quadrant: .bottomLeft)
        let shadowLuma = sampleLuma(pixels, quadrant: .topRight)

        print("[#183 toony=0.9] litLuma=\(litLuma) shadowLuma=\(shadowLuma)")

        XCTAssertGreaterThan(litLuma, shadowLuma,
            "Lit triangle must be at least slightly brighter than shadow triangle " +
            "even with toony=0.9; both equal at exactly 1.0 is the #183 symptom.")
    }

    // MARK: - Scene builder

    /// Build a model with:
    ///   - 1 mesh, 2 primitives.
    ///   - Primitive 0 ("up_normals"): triangle at top-right NDC, vertex normals all = (0, 1, 0).
    ///   - Primitive 1 ("down_normals"): triangle at bottom-left NDC, vertex normals all = (0, -1, 0).
    /// Both primitives reference material 0 (the MToon material with shadeColor=(0.5,0.5,0.5)).
    private func makeTwoNormalTrianglesModel(toony: Float) throws -> VRMModel {
        let gltfJSON = """
        {"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],
         "nodes":[{"name":"root","mesh":0}]}
        """
        let gltf = try JSONDecoder().decode(GLTFDocument.self, from: gltfJSON.data(using: .utf8)!)
        let model = VRMModel(
            specVersion: .v1_0,
            meta: VRMMeta(licenseUrl: "https://vrm.dev/licenses/1.0/"),
            humanoid: nil,
            gltf: gltf
        )
        for (i, gltfNode) in (gltf.nodes ?? []).enumerated() {
            model.nodes.append(VRMNode(index: i, gltfNode: gltfNode))
        }
        for n in model.nodes { n.updateWorldTransform() }

        let mesh = VRMMesh(name: "two_normals")
        mesh.primitives = [
            makeTriangle(normal: SIMD3<Float>( 0,  1, 0), vertexOffset: SIMD3<Float>( 0.5,  0.5, 0)),
            makeTriangle(normal: SIMD3<Float>( 0, -1, 0), vertexOffset: SIMD3<Float>(-0.5, -0.5, 0))
        ]
        model.meshes = [mesh]

        // Build material via the JSON path so the MToon extension parser runs end-to-end —
        // this is the same path the production loader uses.
        let materialJSON = """
        {
          "name":"mtoon_test",
          "pbrMetallicRoughness":{"baseColorFactor":[1.0,1.0,1.0,1.0]},
          "extensions":{
            "VRMC_materials_mtoon":{
              "specVersion":"1.0",
              "shadeColorFactor":[0.5,0.5,0.5],
              "shadingToonyFactor":\(toony),
              "shadingShiftFactor":0.0,
              "giEqualizationFactor":0.9
            }
          }
        }
        """
        let gltfMat = try JSONDecoder().decode(GLTFMaterial.self, from: materialJSON.data(using: .utf8)!)
        let material = VRMMaterial(from: gltfMat, textures: [], vrm0MaterialProperty: nil, vrmVersion: .v1_0)
        model.materials = [material]

        return model
    }

    private func makeTriangle(normal: SIMD3<Float>, vertexOffset: SIMD3<Float>) -> VRMPrimitive {
        let primitive = VRMPrimitive()
        var verts = [VRMVertex(), VRMVertex(), VRMVertex()]
        verts[0].position = SIMD3<Float>(-0.15, -0.15, 0) + vertexOffset
        verts[1].position = SIMD3<Float>( 0.15, -0.15, 0) + vertexOffset
        verts[2].position = SIMD3<Float>( 0.00,  0.15, 0) + vertexOffset
        for i in 0..<3 {
            verts[i].normal = normal
            verts[i].texCoord = SIMD2<Float>(0, 0)
            verts[i].color = SIMD4<Float>(1, 1, 1, 1)
        }
        primitive.vertexCount = 3
        primitive.vertexBuffer = device.makeBuffer(
            bytes: verts,
            length: 3 * MemoryLayout<VRMVertex>.stride,
            options: .storageModeShared
        )
        primitive.localMin = SIMD3<Float>(-0.15, -0.15, 0) + vertexOffset
        primitive.localMax = SIMD3<Float>( 0.15,  0.15, 0) + vertexOffset

        let indices: [UInt16] = [0, 1, 2]
        primitive.indexBuffer = device.makeBuffer(
            bytes: indices,
            length: 3 * MemoryLayout<UInt16>.stride,
            options: .storageModeShared
        )
        primitive.indexCount = 3
        primitive.indexType = .uint16
        primitive.indexBufferOffset = 0
        primitive.primitiveType = .triangle
        primitive.hasNormals = true
        primitive.hasTexCoords = false
        primitive.hasColors = false
        primitive.hasJoints = false
        primitive.hasWeights = false
        primitive.requiredPaletteSize = 0
        primitive.materialIndex = 0  // Use the MToon material
        return primitive
    }

    // MARK: - Offscreen render + readback (shared shape with NonSkinnedMeshDropTests)

    private static let renderSize = 64
    private static let clearColorBGRA: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 255)

    private enum Quadrant { case topRight, bottomLeft }

    private func renderOneOffscreenFrame(renderer: VRMRenderer) throws -> [UInt8] {
        let size = Self.renderSize
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .shared
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: size, height: size, mipmapped: false)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private

        guard let colorTex = device.makeTexture(descriptor: colorDesc),
              let depthTex = device.makeTexture(descriptor: depthDesc),
              let queue = device.makeCommandQueue(),
              let cb = queue.makeCommandBuffer() else {
            throw XCTSkip("Could not allocate Metal render targets")
        }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = colorTex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        rpd.depthAttachment.texture = depthTex
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1.0
        rpd.depthAttachment.storeAction = .dontCare

        renderer.drawOffscreenHeadless(
            to: colorTex, depth: depthTex,
            commandBuffer: cb, renderPassDescriptor: rpd
        )
        cb.commit()
        cb.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        let region = MTLRegionMake2D(0, 0, size, size)
        bytes.withUnsafeMutableBytes { buf in
            colorTex.getBytes(buf.baseAddress!, bytesPerRow: size * 4, from: region, mipmapLevel: 0)
        }
        return bytes
    }

    /// Mean luminance of non-clear pixels in the quadrant, normalized to [0, 1].
    /// bgra8Unorm: byte order in memory is B, G, R, A.
    private func sampleLuma(_ bytes: [UInt8], quadrant: Quadrant) -> Float {
        let size = Self.renderSize
        let half = size / 2
        let xRange: Range<Int>
        let yRange: Range<Int>
        switch quadrant {
        case .topRight:    xRange = half..<size; yRange = 0..<half
        case .bottomLeft:  xRange = 0..<half;    yRange = half..<size
        }
        var lumaSum: Float = 0
        var count: Int = 0
        for y in yRange {
            for x in xRange {
                let i = (y * size + x) * 4
                let b = bytes[i], g = bytes[i + 1], r = bytes[i + 2]
                let isClear = (b == Self.clearColorBGRA.0) &&
                              (g == Self.clearColorBGRA.1) &&
                              (r == Self.clearColorBGRA.2)
                if !isClear {
                    let luma = (0.2126 * Float(r) + 0.7152 * Float(g) + 0.0722 * Float(b)) / 255.0
                    lumaSum += luma
                    count += 1
                }
            }
        }
        return count > 0 ? lumaSum / Float(count) : 0
    }

    // MARK: - End-to-end helpers

    private func makePerspective(fovRadians: Float, aspect: Float, near: Float, far: Float) -> matrix_float4x4 {
        let yScale = 1.0 / tan(fovRadians * 0.5)
        let xScale = yScale / aspect
        let zRange = far - near
        let zScale = -(far + near) / zRange
        let wzScale = -2.0 * far * near / zRange
        return matrix_float4x4(columns: (
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, zScale, -1),
            SIMD4<Float>(0, 0, wzScale, 0)
        ))
    }

    private func makeLookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> matrix_float4x4 {
        let f = simd_normalize(center - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return matrix_float4x4(columns: (
            SIMD4<Float>(s.x, u.x, -f.x, 0),
            SIMD4<Float>(s.y, u.y, -f.y, 0),
            SIMD4<Float>(s.z, u.z, -f.z, 0),
            SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
        ))
    }

    /// Write a BGRA byte array to PNG for visual inspection.
    private func dumpBGRA(pixels: [UInt8], size: Int, to url: URL) throws {
        // Convert BGRA → RGBA in-place for CGImage.
        var rgba = pixels
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let b = rgba[i]
            rgba[i] = rgba[i + 2]   // R = original R (was at index 2)
            rgba[i + 2] = b         // B = original B (was at index 0)
        }
        let provider = CGDataProvider(data: NSData(bytes: rgba, length: rgba.count))!
        let cgImage = CGImage(
            width: size, height: size,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "dumpBGRA", code: 1)
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
    }

    private func renderArbitrary(renderer: VRMRenderer, size: Int, clear: (UInt8, UInt8, UInt8)) throws -> [UInt8] {
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .shared
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: size, height: size, mipmapped: false)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private

        guard let colorTex = device.makeTexture(descriptor: colorDesc),
              let depthTex = device.makeTexture(descriptor: depthDesc),
              let queue = device.makeCommandQueue(),
              let cb = queue.makeCommandBuffer() else {
            throw XCTSkip("Could not allocate Metal render targets")
        }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = colorTex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(
            red:   Double(clear.2) / 255.0,
            green: Double(clear.1) / 255.0,
            blue:  Double(clear.0) / 255.0,
            alpha: 1.0
        )
        rpd.colorAttachments[0].storeAction = .store
        rpd.depthAttachment.texture = depthTex
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1.0
        rpd.depthAttachment.storeAction = .dontCare

        renderer.drawOffscreenHeadless(
            to: colorTex, depth: depthTex,
            commandBuffer: cb, renderPassDescriptor: rpd
        )
        cb.commit()
        cb.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        let region = MTLRegionMake2D(0, 0, size, size)
        bytes.withUnsafeMutableBytes { buf in
            colorTex.getBytes(buf.baseAddress!, bytesPerRow: size * 4, from: region, mipmapLevel: 0)
        }
        return bytes
    }

    /// Sample the centerline column at x = size/2, y from 35% to 65% of height.
    /// Returns luma in [0,1] per sample; 0 for clear-color pixels.
    private func sampleCenterline(_ bytes: [UInt8], size: Int) -> [Float] {
        let x = size / 2
        let yStart = (size * 35) / 100
        let yEnd = (size * 65) / 100
        var result: [Float] = []
        for y in yStart..<yEnd {
            let i = (y * size + x) * 4
            let b = bytes[i], g = bytes[i + 1], r = bytes[i + 2]
            // Treat very dark pixels (clear color) as sentinel 0.
            if r < 40 && g < 40 && b < 40 {
                result.append(0)
            } else {
                let rF: Float = 0.2126 * Float(r)
                let gF: Float = 0.7152 * Float(g)
                let bF: Float = 0.0722 * Float(b)
                result.append((rF + gF + bF) / 255.0)
            }
        }
        return result
    }

    private func printPixelMap(_ bytes: [UInt8], size: Int, prefix: String) {
        print(prefix)
        for y in 0..<size {
            var line = ""
            for x in 0..<size {
                let i = (y * size + x) * 4
                let b = bytes[i], g = bytes[i + 1], r = bytes[i + 2]
                let rF: Float = 0.2126 * Float(r)
                let gF: Float = 0.7152 * Float(g)
                let bF: Float = 0.0722 * Float(b)
                let luma = Int(rF + gF + bF)
                if luma < 32 { line.append(".") }
                else if luma < 96 { line.append("-") }
                else if luma < 192 { line.append("o") }
                else { line.append("#") }
            }
            print("  \(line)")
        }
    }

    private func printPixelMap(_ bytes: [UInt8], prefix: String) {
        let size = Self.renderSize
        print(prefix)
        for y in 0..<size {
            var line = ""
            for x in 0..<size {
                let i = (y * size + x) * 4
                let b = bytes[i], g = bytes[i + 1], r = bytes[i + 2]
                let isClear = (b == Self.clearColorBGRA.0) &&
                              (g == Self.clearColorBGRA.1) &&
                              (r == Self.clearColorBGRA.2)
                if isClear {
                    line.append(".")
                } else {
                    // Show intensity bucket so we can see the gradient: low=- mid=o high=#
                    let rF: Float = 0.2126 * Float(r)
                    let gF: Float = 0.7152 * Float(g)
                    let bF: Float = 0.0722 * Float(b)
                    let luma = Int(rF + gF + bF)
                    if luma < 96 { line.append("-") }
                    else if luma < 192 { line.append("o") }
                    else { line.append("#") }
                }
            }
            print("  \(line)")
        }
    }
}
