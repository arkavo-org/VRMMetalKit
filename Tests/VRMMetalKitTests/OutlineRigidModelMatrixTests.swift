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
@testable import VRMMetalKit

/// Regression for vrm-conformance issue #185:
/// "0.13.1: outline rendering regression — outlines invisible in MToon corpus."
///
/// PR #184 (fix for #181) switched the main pass's per-draw `Uniforms` binding
/// from a write-into-shared-buffer pattern to `setVertexBytes`. The outline
/// pass kept reading from the shared `uniformsBuffer` at the same slot. Before
/// #184 the shared buffer happened to contain the last main-pass draw's
/// `modelMatrix` (a coincidental side effect that mostly worked); after #184
/// the buffer keeps the frame-init `modelMatrix = identity`. For non-skinned
/// (rigid) meshes that aren't at the origin, the outline pass renders the
/// inverted hull at world origin instead of at the node's world position —
/// the outline geometry lands off the mesh and (typically) off-screen, looking
/// invisible.
///
/// Test strategy: compare the rendered framebuffer of `mtoon_outline_world_0p1`
/// (outline enabled) against `mtoon_outline_none` (outline disabled) from the
/// vrm-conformance test corpus. With the regression present, the two render
/// byte-identical (outline pass produces no visible pixels). With the fix, the
/// outline asset's mesh region differs substantially — the outline colors the
/// silhouette band (and, due to a separate pre-existing flood bug that also
/// affects three-vrm, often the entire interior).
///
/// Skip if the conformance corpus isn't generated locally — emit with:
///   cd ../vrm-conformance && cargo run --release -p vrm-asset-generator -- \
///       emit-sweep --output-dir /tmp/repro185
@MainActor
final class OutlineRigidModelMatrixTests: XCTestCase {

    private var device: MTLDevice!

    private func ensureDevice() throws {
        if device != nil { return }
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available on this host")
        }
        device = dev
    }

    func testOutlineAssetDiffersFromOutlineNoneAsset() async throws {
        try ensureDevice()
        let outlinePath = "/tmp/repro185/mtoon_outline_world_0p1.vrm"
        let nonePath    = "/tmp/repro185/mtoon_outline_none.vrm"
        for path in [outlinePath, nonePath] {
            guard FileManager.default.fileExists(atPath: path) else {
                throw XCTSkip("vrm-conformance corpus not at \(path) — see file header docs to regenerate.")
            }
        }

        let outlinePixels = try await renderAsset(at: outlinePath)
        let nonePixels    = try await renderAsset(at: nonePath)

        // Per-pixel diff over the mesh's bounding region (sphere is centered at
        // ~(0,1.4,0); with the test plan's camera framing it lives in the
        // middle of the framebuffer). Count pixels that differ by >32 on any
        // channel — pre-fix these two assets render byte-identical (or near-so);
        // post-fix the outline_world_0p1 asset paints its silhouette with the
        // outline color and differs substantially from outline_none.
        let differingPixels = countDifferingPixels(outlinePixels, nonePixels, tolerance: 32)
        print("[#185] differingPixels=\(differingPixels) of \(Self.renderSize * Self.renderSize)")

        // The two assets should differ in at least ~5% of pixels (the silhouette
        // band, or — given the separate three-vrm flood-style behavior we
        // currently match — the entire sphere interior). Pre-regression-fix the
        // count is effectively 0.
        let total = Self.renderSize * Self.renderSize
        let minDifference = total / 20  // 5%
        XCTAssertGreaterThan(differingPixels, minDifference,
            "outline_world_0p1.vrm and outline_none.vrm produce nearly identical output " +
            "(\(differingPixels) differing pixels of \(total)) — the outline pass is not " +
            "applying. This is the #185 regression: PR #184's switch to setVertexBytes " +
            "for the main pass left the outline pass reading the shared uniformsBuffer's " +
            "frame-init modelMatrix=identity, dispatching the inverted hull at world origin.")
    }

    // MARK: - Asset render helper

    private func renderAsset(at path: String) async throws -> [UInt8] {
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)

        let aspect: Float = 1.0
        let fov: Float = 30.0 * .pi / 180.0
        renderer.projectionMatrix = makePerspective(fovRadians: fov, aspect: aspect, near: 0.01, far: 100.0)
        renderer.viewMatrix = makeLookAt(
            eye:    SIMD3<Float>(0.0, 1.4, 1.5),
            center: SIMD3<Float>(0.0, 1.4, 0.0),
            up:     SIMD3<Float>(0.0, 1.0, 0.0)
        )
        renderer.setLight(0, direction: -SIMD3<Float>(-0.3, -0.6, -0.7), color: SIMD3<Float>(1, 1, 1), intensity: 1.0)
        renderer.disableLight(1)
        renderer.disableLight(2)
        renderer.setAmbientColor(SIMD3<Float>(0.5, 0.5, 0.5) * 0.3)

        return try renderOffscreen(renderer: renderer, size: Self.renderSize)
    }

    // MARK: - Camera helpers

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

    // MARK: - Offscreen + diff

    private static let renderSize = 128

    private func renderOffscreen(renderer: VRMRenderer, size: Int) throws -> [UInt8] {
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
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.06, blue: 0.11, alpha: 1)
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

    private func countDifferingPixels(_ a: [UInt8], _ b: [UInt8], tolerance: Int) -> Int {
        precondition(a.count == b.count)
        var count = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            let db = abs(Int(a[i])     - Int(b[i]))
            let dg = abs(Int(a[i + 1]) - Int(b[i + 1]))
            let dr = abs(Int(a[i + 2]) - Int(b[i + 2]))
            if db > tolerance || dg > tolerance || dr > tolerance {
                count += 1
            }
        }
        return count
    }
}
