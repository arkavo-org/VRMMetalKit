//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Verifies cross-avatar occlusion in a SHARED depth buffer — the configuration
/// a host app uses to draw multiple avatars in one 3D scene (crowd / dialogue).
///
/// Invariant: when avatar B is rendered fully behind avatar A into the same
/// color+depth buffer, B must not appear over the parts of A that are solid
/// foreground. This exercises the live render path (`drawOffscreenHeadless` ->
/// `drawCore`): depth writes during the first model's draw and depth `.load`
/// across the second model's pass must correctly occlude the background avatar.
///
/// (Added while investigating issue #302. The depth-bias-bleed hypothesis there
/// was refuted — bias is per-material-type, so it shifts both avatars' matching
/// surfaces equally and preserves their order. This test guards the broader
/// shared-depth-buffer occlusion property, which a real regression *would*
/// break: a measured floor of ~0.1% vs ~7% when occlusion fails.)
@MainActor
final class MultiModelOcclusionTests: XCTestCase {

    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!

    override func setUp() async throws {
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else { throw XCTSkip("Metal device not available") }
        commandQueue = device.makeCommandQueue()
    }

    private var projectRoot: String {
        let fm = FileManager.default
        let candidates: [String?] = [
            ProcessInfo.processInfo.environment["PROJECT_ROOT"],
            URL(fileURLWithPath: #file).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().path,
            fm.currentDirectoryPath
        ]
        for c in candidates.compactMap({ $0 }) where fm.fileExists(atPath: "\(c)/Package.swift") {
            return c
        }
        return fm.currentDirectoryPath
    }

    func testBackgroundAvatarIsOccludedInSharedDepthBuffer() async throws {
        let modelPath = "\(projectRoot)/vroid_default_F_1_0.vrm"
        try XCTSkipIf(!FileManager.default.fileExists(atPath: modelPath),
                      "Model not found at \(modelPath)")
        let url = URL(fileURLWithPath: modelPath)

        let width = 384, height = 384

        let foreground = VRMRenderer(device: device)
        foreground.loadModel(try await VRMModel.load(from: url, device: device))
        configureLights(foreground)

        let behind = VRMRenderer(device: device)
        behind.loadModel(try await VRMModel.load(from: url, device: device))
        configureLights(behind)

        let aspect = Float(width) / Float(height)
        let proj = makePerspective(fovY: .pi / 4, aspect: aspect, near: 0.05, far: 50)
        let view = makeLookAt(eye: SIMD3(0, 1.0, 1.4), center: SIMD3(0, 1.0, 0), up: SIMD3(0, 1, 0))
        foreground.projectionMatrix = proj
        foreground.viewMatrix = view
        behind.projectionMatrix = proj
        // 0.3 m directly behind the foreground avatar: fully occluded by it.
        behind.viewMatrix = view * translation(SIMD3(0, 0, -0.3))

        let (fgOnly, composited) = try renderForegroundThenBehind(
            foreground: foreground, behind: behind, width: width, height: height)

        // Count foreground coverage and "bleed" = solid-foreground pixels that the
        // (occluded) background avatar changed. Background pixels are A's real gaps
        // (between arms/torso, around the neck) where B is legitimately visible and
        // must NOT be counted.
        let bg = SIMD3<UInt8>(31, 36, 46)  // matches render() clear color
        var coverage = 0
        var bleed = 0
        for i in stride(from: 0, to: fgOnly.count, by: 4) {
            let isForeground = channelDelta(fgOnly, i, bg) > 24
            guard isForeground else { continue }
            coverage += 1
            let d = max(abs(Int(fgOnly[i]) - Int(composited[i])),
                        abs(Int(fgOnly[i+1]) - Int(composited[i+1])),
                        abs(Int(fgOnly[i+2]) - Int(composited[i+2])))
            if d > 24 { bleed += 1 }
        }
        XCTAssertGreaterThan(coverage, 5000, "Sanity: foreground avatar should cover a meaningful area")

        let ratio = Double(bleed) / Double(coverage)
        // Floor is ~0.1% (silhouette antialiasing). A broken shared-depth path
        // (e.g. the background avatar drawing over solid foreground) spikes to
        // several percent. 1% sits well above the floor and well below failure.
        XCTAssertLessThan(ratio, 0.01,
            "Background avatar bled through foreground in shared depth buffer: \(bleed)/\(coverage) px (\(String(format: "%.2f", ratio * 100))%)")
    }

    // MARK: - Rendering

    private func configureLights(_ r: VRMRenderer) {
        r.setLight(0, direction: SIMD3(-0.2, 0.5, -0.85), color: SIMD3(1, 1, 1), intensity: 1.0)
        r.disableLight(1)
        r.setAmbientColor(SIMD3(0.04, 0.04, 0.04))
        r.setLightNormalizationMode(.radiometric)
    }

    /// Render `foreground` (clears the buffer), snapshot the color, then composite
    /// `behind` into the SAME color+depth buffer. Returns (foreground-only,
    /// foreground+behind). The foreground is rendered exactly once, so its
    /// contribution is byte-identical in both images (rendering it twice would
    /// diverge via springbone/time state and mask the cross-model effect).
    private func renderForegroundThenBehind(
        foreground: VRMRenderer, behind: VRMRenderer, width: Int, height: Int
    ) throws -> ([UInt8], [UInt8]) {
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .shared
        let snapDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        snapDesc.usage = [.shaderRead, .shaderWrite]
        snapDesc.storageMode = .shared
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private
        guard let color = device.makeTexture(descriptor: colorDesc),
              let snapshot = device.makeTexture(descriptor: snapDesc),
              let depth = device.makeTexture(descriptor: depthDesc),
              let cmd = commandQueue.makeCommandBuffer() else {
            throw ZFightingTestError.renderFailed("texture/command buffer allocation failed")
        }

        let rpdFg = MTLRenderPassDescriptor()
        rpdFg.colorAttachments[0].texture = color
        rpdFg.colorAttachments[0].loadAction = .clear
        rpdFg.colorAttachments[0].storeAction = .store
        rpdFg.colorAttachments[0].clearColor = MTLClearColor(red: 31/255, green: 36/255, blue: 46/255, alpha: 1)
        rpdFg.depthAttachment.texture = depth
        rpdFg.depthAttachment.loadAction = .clear
        rpdFg.depthAttachment.storeAction = .store
        rpdFg.depthAttachment.clearDepth = 1.0
        foreground.drawOffscreenHeadless(to: color, depth: depth, commandBuffer: cmd, renderPassDescriptor: rpdFg)

        // Snapshot foreground-only color into a separate texture.
        if let blit = cmd.makeBlitCommandEncoder() {
            blit.copy(from: color, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1),
                      to: snapshot, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }

        let rpdBg = MTLRenderPassDescriptor()
        rpdBg.colorAttachments[0].texture = color
        rpdBg.colorAttachments[0].loadAction = .load
        rpdBg.colorAttachments[0].storeAction = .store
        rpdBg.depthAttachment.texture = depth
        rpdBg.depthAttachment.loadAction = .load
        rpdBg.depthAttachment.storeAction = .store
        behind.drawOffscreenHeadless(to: color, depth: depth, commandBuffer: cmd, renderPassDescriptor: rpdBg)

        cmd.commit()
        cmd.waitUntilCompleted()

        func read(_ tex: MTLTexture) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: width * height * 4)
            out.withUnsafeMutableBytes { ptr in
                tex.getBytes(ptr.baseAddress!, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            return out
        }
        return (read(snapshot), read(color))
    }

    private func channelDelta(_ px: [UInt8], _ i: Int, _ bg: SIMD3<UInt8>) -> Int {
        max(abs(Int(px[i]) - Int(bg.x)), abs(Int(px[i+1]) - Int(bg.y)), abs(Int(px[i+2]) - Int(bg.z)))
    }

    // MARK: - Matrix helpers

    private func translation(_ t: SIMD3<Float>) -> float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t.x, t.y, t.z, 1)
        return m
    }

    private func makeLookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
        let f = normalize(center - eye)
        let s = normalize(cross(f, up))
        let u = cross(s, f)
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4(s.x, u.x, -f.x, 0)
        m.columns.1 = SIMD4(s.y, u.y, -f.y, 0)
        m.columns.2 = SIMD4(s.z, u.z, -f.z, 0)
        m.columns.3 = SIMD4(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)
        return m
    }

    private func makePerspective(fovY: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let ys = 1 / tan(fovY * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        var m = float4x4()
        m.columns.0 = SIMD4(xs, 0, 0, 0)
        m.columns.1 = SIMD4(0, ys, 0, 0)
        m.columns.2 = SIMD4(0, 0, zs, -1)
        m.columns.3 = SIMD4(0, 0, zs * near, 0)
        return m
    }
}
