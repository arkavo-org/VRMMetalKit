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
@testable import VRMMetalKit

/// Regression for vrm-conformance issue #226. The MToon parametric-rim
/// fresnel block in `MToonShader.metal` computed `dot(viewNormal, V')` where
/// `viewNormal` was built from a compound `viewMatrix * normalMatrix * float4(N, 0)`
/// — and that compound carries a w-component leak whenever the model has a
/// non-zero translation AND the view matrix has a non-zero translation:
///
///   `normalMatrix = modelMatrix.inverse.transpose` of a translated
///   `modelMatrix` puts the negated translation into the *4th row* of the
///   inverse, and the transpose moves that into the *w-component* of the
///   per-axis columns. So `normalMatrix * float4(N, 0)` produces a vec4
///   with non-zero `w`, and the subsequent `viewMatrix * …` applies
///   `viewMatrix`'s translation column scaled by that `w`, contaminating the
///   `xyz` we then normalize.
///
/// The bug was asymptomatic for tests with an identity view matrix (no
/// translation column to multiply into), but bit every realistic camera
/// setup — including the conformance corpus's `lookAt(eye=(0,1.4,1.5), ...)`
/// against a sphere translated to `y=1.4`. The rim ended up appearing at
/// the *bottom* of the sphere (where the sign-flipped w-leak saturated
/// NdotV to 0 → full rim) while *vanishing* at the top (where w-leak
/// inflated NdotV toward 1 → rimF^5 ≈ 0, invisible at 8-bit). Sweep-
/// invariant SSIM 0.91 vs the three other reference renderers' 0.98+
/// cluster.
///
/// Fix: compute the rim fresnel in *world space*, mirroring the
/// `additiveDirectionalRim` block in the same shader. `worldNormal` is
/// already correctly computed (single matrix multiply + explicit `.xyz`
/// extraction → no compound w-leak). `viewDirection` is also already
/// world-space. The MToon-1.0 spec defines the rim fresnel in world
/// space, three-vrm + UniVRM Built-in RP both implement it that way.
@MainActor
final class MToonRimFresnelTests: XCTestCase {

    /// End-to-end repro against the actual conformance asset that surfaced
    /// the bug. Skips if the asset isn't on disk — regenerate from a checkout
    /// of `github.com/arkavo-org/vrm-conformance` via:
    ///
    ///     cargo run --release -p vrm-asset-generator -- \
    ///       emit-sweep --output-dir /tmp/repro226
    ///
    /// then copy `mtoon_rimLightingMix_1.vrm` to the path below.
    ///
    /// Pre-fix: VMK renders the sphere with NO rim at the top half (gray)
    /// and a sharp horizontal band of orange at the bottom. The horizontal
    /// centerline shows the rim is *missing where it should be*. The
    /// test asserts the rim is visible across the silhouette — specifically
    /// that the left edge of the visible sphere carries an orange tint
    /// (`R > B + ε`) where pre-fix it was pure gray.
    func testRimVisibleAtLeftSilhouetteOfConformanceAsset() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let path = "/tmp/repro226/mtoon_rimLightingMix_1.vrm"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("vrm-conformance rim asset not at \(path). " +
                "Regenerate from a checkout of github.com/arkavo-org/vrm-conformance with: " +
                "`cargo run --release -p vrm-asset-generator -- emit-sweep --output-dir /tmp/repro226`")
        }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)

        // Conformance pipeline + cache key fix lands separately in #214.
        // Construct the renderer with the same setup the QA adapter uses
        // (sRGB framebuffer, 4× MSAA, the conformance test_yaml camera +
        // lighting).
        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        config.colorPixelFormat = .rgba8Unorm_srgb
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)

        let size = 256
        let aspect: Float = 1.0
        let fov: Float = 30.0 * .pi / 180.0
        renderer.projectionMatrix = makePerspective(fovRadians: fov, aspect: aspect, near: 0.01, far: 100.0)
        renderer.viewMatrix = makeLookAt(
            eye:    SIMD3<Float>(0, 1.4, 1.5),
            center: SIMD3<Float>(0, 1.4, 0),
            up:     SIMD3<Float>(0, 1, 0)
        )
        // Dimmer than the conformance corpus's `intensity: 1.0` — with the
        // Half-Lambert remap restored (#183 revert), full-intensity scene
        // light + bright rim both saturate at silhouette, hiding the
        // orange tint that this test measures. Lower intensity keeps the
        // rim's orange contribution visible against the body without
        // changing what the test actually verifies (rim fires across all
        // silhouette directions, not just the pre-#226 w-leak direction).
        renderer.setLight(0, direction: SIMD3<Float>(-0.3, -0.6, -0.7), color: SIMD3<Float>(1, 1, 1), intensity: 0.3)
        renderer.disableLight(1)
        renderer.disableLight(2)
        renderer.setAmbientColor(SIMD3<Float>(0.05, 0.05, 0.05))

        let pixels = try renderFrame(renderer: renderer, device: device, size: size)

        // The sphere's visible disk fills roughly x=12-88% of the image (30°
        // FOV, sphere radius 0.3 at distance 1.5). Sample close to the left
        // silhouette where rimF^5 ≈ 1 (vf=1 → full rim). Sampling at
        // x=18-22% is *inside* the body where rimF drops to ~0.06 and the
        // rim tint disappears at 8-bit; that won't surface the bug.
        let xRange = Int(Double(size) * 0.13)...Int(Double(size) * 0.16)
        let yRange = Int(Double(size) * 0.47)...Int(Double(size) * 0.53)
        let stripR = sampleMeanChannel(pixels, size: size, channel: 0, xRange: xRange, yRange: yRange)
        let stripG = sampleMeanChannel(pixels, size: size, channel: 1, xRange: xRange, yRange: yRange)
        let stripB = sampleMeanChannel(pixels, size: size, channel: 2, xRange: xRange, yRange: yRange)

        print("[#226] left silhouette R/G/B = (\(stripR), \(stripG), \(stripB))")

        XCTAssertGreaterThan(stripR, stripG + 0.05,
            "Left silhouette strip must show orange rim (R > G). Got R=\(stripR), G=\(stripG). " +
            "Pre-fix #226 the parametric-rim fresnel only fired at one specific normal direction " +
            "(the sign-aligned w-leak in compound viewMatrix·normalMatrix) — every other silhouette " +
            "point received zero rim.")
        // The G-B gap is intentionally smaller than R-G because the rim
        // colour (1, 0.5, 0) is blended *additively* on top of the shadow-
        // side body (gray) — G picks up 0.5·rimF, B picks up 0·rimF, so the
        // G-B delta is half the R-G delta when both come from the rim term.
        XCTAssertGreaterThan(stripG, stripB + 0.04,
            "Left silhouette strip must show orange (G > B). Got G=\(stripG), B=\(stripB).")
    }

    /// Same asset, top-silhouette sample. Pre-fix this is pure gray (181,181,181
    /// in 8-bit) because the w-leak's NdotV ≈ 0.4 → vf=0.6 → rimF=0.07, invisible
    /// at 8-bit. Post-fix the top silhouette carries the same orange rim as the
    /// rest of the visible disk's edge.
    func testRimVisibleAtTopSilhouetteOfConformanceAsset() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        let path = "/tmp/repro226/mtoon_rimLightingMix_1.vrm"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("vrm-conformance rim asset not at \(path). " +
                "Regenerate as in `testRimVisibleAtLeftSilhouetteOfConformanceAsset`'s skip note.")
        }
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        config.colorPixelFormat = .rgba8Unorm_srgb
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)

        let size = 256
        let aspect: Float = 1.0
        let fov: Float = 30.0 * .pi / 180.0
        renderer.projectionMatrix = makePerspective(fovRadians: fov, aspect: aspect, near: 0.01, far: 100.0)
        renderer.viewMatrix = makeLookAt(
            eye:    SIMD3<Float>(0, 1.4, 1.5),
            center: SIMD3<Float>(0, 1.4, 0),
            up:     SIMD3<Float>(0, 1, 0)
        )
        // Dimmer than the conformance corpus's `intensity: 1.0` — with the
        // Half-Lambert remap restored (#183 revert), full-intensity scene
        // light + bright rim both saturate at silhouette, hiding the
        // orange tint that this test measures. Lower intensity keeps the
        // rim's orange contribution visible against the body without
        // changing what the test actually verifies (rim fires across all
        // silhouette directions, not just the pre-#226 w-leak direction).
        renderer.setLight(0, direction: SIMD3<Float>(-0.3, -0.6, -0.7), color: SIMD3<Float>(1, 1, 1), intensity: 0.3)
        renderer.disableLight(1)
        renderer.disableLight(2)
        renderer.setAmbientColor(SIMD3<Float>(0.05, 0.05, 0.05))

        let pixels = try renderFrame(renderer: renderer, device: device, size: size)

        // Top silhouette: just inside the sphere top edge. Sphere visible
        // disk fills y=12-88%, so y=15-18% is one band inside the top edge
        // where NdotV ≈ 0 and rimF ≈ 1.
        let xRange = Int(Double(size) * 0.47)...Int(Double(size) * 0.53)
        let yRange = Int(Double(size) * 0.15)...Int(Double(size) * 0.18)
        let stripR = sampleMeanChannel(pixels, size: size, channel: 0, xRange: xRange, yRange: yRange)
        let stripG = sampleMeanChannel(pixels, size: size, channel: 1, xRange: xRange, yRange: yRange)
        let stripB = sampleMeanChannel(pixels, size: size, channel: 2, xRange: xRange, yRange: yRange)

        print("[#226] top silhouette R/G/B = (\(stripR), \(stripG), \(stripB))")

        XCTAssertGreaterThan(stripR, stripG + 0.05,
            "Top silhouette strip must show orange rim (R > G). Got R=\(stripR), G=\(stripG). " +
            "Pre-fix #226 this was pure gray because the w-leak inflated NdotV at +Y normals.")
        XCTAssertGreaterThan(stripG, stripB + 0.10,
            "Top silhouette strip must show orange (G > B). Got G=\(stripG), B=\(stripB).")
    }

    // MARK: - Helpers

    private func renderFrame(renderer: VRMRenderer, device: MTLDevice, size: Int) throws -> [UInt8] {
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb, width: size, height: size, mipmapped: false)
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
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 1.0, green: 0.0, blue: 1.0, alpha: 1.0)
        rpd.colorAttachments[0].storeAction = .store
        rpd.depthAttachment.texture = depthTex
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1.0
        rpd.depthAttachment.storeAction = .dontCare

        renderer.drawOffscreenHeadless(to: colorTex, depth: depthTex, commandBuffer: cb, renderPassDescriptor: rpd)
        cb.commit()
        cb.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        bytes.withUnsafeMutableBytes { buf in
            colorTex.getBytes(buf.baseAddress!, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        }
        return bytes
    }

    /// Mean of a single channel (0=R, 1=G, 2=B) across a rectangular sub-region,
    /// skipping pixels that match the magenta clear color (255, 0, 255).
    /// rgba8Unorm_srgb stores RGBA in memory order.
    private func sampleMeanChannel(
        _ bytes: [UInt8], size: Int, channel: Int,
        xRange: ClosedRange<Int>, yRange: ClosedRange<Int>
    ) -> Float {
        var sum: Float = 0
        var count: Int = 0
        for y in yRange {
            for x in xRange {
                let base = (y * size + x) * 4
                let r = bytes[base], g = bytes[base + 1], b = bytes[base + 2]
                // Magenta clear color sentinel — skip regardless of which
                // channel we're sampling so the mean doesn't fold the
                // background's G=0 into a mostly-rim region.
                if r == 255 && g == 0 && b == 255 { continue }
                sum += Float(bytes[base + channel]) / 255.0
                count += 1
            }
        }
        return count > 0 ? sum / Float(count) : 0
    }

    // MARK: - Matrix helpers (verbatim from MToonFlatWhiteLightingTests)

    private func makePerspective(fovRadians: Float, aspect: Float, near: Float, far: Float) -> matrix_float4x4 {
        let yScale = 1.0 / tan(fovRadians * 0.5)
        let xScale = yScale / aspect
        let zRange = far - near
        return matrix_float4x4(columns: (
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, -(far + near) / zRange, -1),
            SIMD4<Float>(0, 0, -2.0 * far * near / zRange, 0)
        ))
    }

    private func makeLookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> matrix_float4x4 {
        let f = normalize(center - eye)
        let s = normalize(cross(f, up))
        let u = cross(s, f)
        return matrix_float4x4(columns: (
            SIMD4<Float>(s.x, u.x, -f.x, 0),
            SIMD4<Float>(s.y, u.y, -f.y, 0),
            SIMD4<Float>(s.z, u.z, -f.z, 0),
            SIMD4<Float>(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)
        ))
    }
}
