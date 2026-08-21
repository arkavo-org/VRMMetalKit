//
// Copyright 2026 Arkavo
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

/// A correct reverse-Z path is invisible: flipping the depth direction
/// changes what the depth buffer stores, not what the viewer sees. These
/// tests pin that property end to end — full model, all material modes,
/// face-sort, and every depth-bias site included.
///
/// The reverse-Z projection is built as `flipZ * P` where `flipZ` maps clip
/// z → w − z: x, y, and w are bit-identical to the standard render, so any
/// color difference can only come from the depth direction handling
/// (compare functions, clear value, bias polarity) — exactly the code under
/// test.
///
/// Exact byte-identity is not achievable in principle: `w − z` rounds
/// differently from `z` (it is exact only under Sterbenz conditions), so
/// where two surfaces land within an ulp of each other a depth-test tie can
/// break the other way. Measured on Apple silicon this flips exactly 1
/// pixel of 65,536 at max|d| 3, stably across runs; a real direction bug
/// (wrong compare, unflipped bias polarity, wrong clear) lights up
/// thousands. The assertion budget sits two orders of magnitude below the
/// failure signature and two above the rounding floor.
///
/// Every render loads its own `VRMModel`: drawing mutates model-held state,
/// so two draws of a shared instance are NOT byte-identical (the
/// determinism test below pins this precondition — if it ever fails, the
/// A/B comparison cannot attribute differences to reverse-Z).
@MainActor
final class ReverseZPixelIdentityTests: XCTestCase {

    private var device: MTLDevice!

    override func setUp() async throws {
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else {
            throw XCTSkip("Metal device not available")
        }
    }

    /// Determinism baseline: two standard-Z renders, each from its own model
    /// load, must be byte-identical — otherwise the reverse-Z A/B below
    /// cannot prove anything.
    func testStandardZRenderIsDeterministic() async throws {
        let first = try render(model: try await loadAvatarSampleA(), reverseZ: false, clearDepth: 1.0).color
        let second = try render(model: try await loadAvatarSampleA(), reverseZ: false, clearDepth: 1.0).color
        let mismatched = zip(first, second).filter { $0 != $1 }.count
        XCTAssertEqual(mismatched, 0,
                       "Standard-Z rendering is nondeterministic across fresh model loads (\(mismatched) bytes differ) — the reverse-Z identity test is not attributable until this is fixed")
    }

    /// Reverse-Z and standard-Z renders of AvatarSample_A are pixel-identical
    /// up to depth-test ties at z-fight-marginal pixels (see the type doc for
    /// why exact byte-identity is unachievable and how the budget is set).
    func testReverseZRendersPixelIdenticalToStandardZ() async throws {
        let standard = try render(model: try await loadAvatarSampleA(), reverseZ: false, clearDepth: 1.0).color
        let reversed = try render(model: try await loadAvatarSampleA(), reverseZ: true, clearDepth: 0.0).color

        // Guard against a trivially-passing empty render (asset missing from
        // the frame, camera wrong): a real render covers far more pixels.
        let drawn = stride(from: 3, to: standard.count, by: 4).filter { standard[$0] > 0 }.count
        XCTAssertGreaterThan(drawn, 5000, "Standard render drew almost nothing — fixture/camera setup wrong")

        let pixelCount = standard.count / 4
        var mismatchedPixels = 0
        var maxDelta = 0
        var signedSum = [0.0, 0.0, 0.0, 0.0]
        for p in 0..<pixelCount {
            var pixelDiffers = false
            for c in 0..<4 {
                let d = Int(reversed[p * 4 + c]) - Int(standard[p * 4 + c])
                if d != 0 { pixelDiffers = true }
                maxDelta = max(maxDelta, abs(d))
                signedSum[c] += Double(d)
            }
            if pixelDiffers { mismatchedPixels += 1 }
        }

        // Budget: ≤0.05% of pixels and max|d| ≤ 16 — two orders of magnitude
        // below the failure signature (a wrong compare direction or bias
        // polarity differs at thousands of pixels), two above the measured
        // rounding floor (1 pixel, max|d| 3).
        let pixelBudget = pixelCount / 2000
        XCTAssertLessThanOrEqual(mismatchedPixels, pixelBudget,
                                 "Reverse-Z render differs from standard-Z at \(mismatchedPixels)/\(pixelCount) pixels (budget \(pixelBudget), max|d| \(maxDelta)) — the depth-direction flip leaked into color output")
        XCTAssertLessThanOrEqual(maxDelta, 16,
                                 "Reverse-Z color delta max|d| \(maxDelta) exceeds the depth-tie rounding floor — a layer resolved to different content, not a tie-break")
        for c in 0..<4 {
            XCTAssertLessThan(abs(signedSum[c] / Double(pixelCount)), 0.01,
                              "Channel \(c) mean shifted by \(signedSum[c] / Double(pixelCount)) — reverse-Z must not tone-shift the render")
        }
    }

    /// Negative control: reverse-Z against the WRONG clear depth (1.0) draws
    /// nothing, because every fragment fails the `.greater` test against a
    /// buffer cleared to the near-plane value. If `useReverseZ` silently
    /// stopped flipping the compare direction, this render would look like
    /// the standard one and the identity test above could pass vacuously.
    func testReverseZAgainstWrongClearDepthDrawsNothing() async throws {
        let pixels = try render(model: try await loadAvatarSampleA(), reverseZ: true, clearDepth: 1.0).color
        let drawn = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 0 }.count
        XCTAssertEqual(drawn, 0,
                       "\(drawn) pixels drew with reverse-Z compares against a far-cleared (standard) depth buffer — the depth direction did not actually flip")
    }

    /// Opaque content must leave non-clear depth behind, in BOTH directions.
    ///
    /// The color identity above cannot see everything: fault-injecting a
    /// prepass state whose compare direction is NOT flipped makes the
    /// prepass write nothing under reverse-Z, yet the color image still
    /// matches — the post-prepass main pass tests `.greaterEqual` against
    /// an empty buffer, everything passes, and draw order approximates
    /// depth order at this camera. Confirmed: the injected fault passes the
    /// pixel-identity budget. So this test asserts the depth buffer itself:
    /// drawn pixels must overwhelmingly carry depth that moved off the
    /// clear value. (Downstream this is load-bearing too — compositors
    /// treat far-plane depth as "no content".)
    func testOpaqueDepthIsWrittenInBothDirections() async throws {
        for (reverseZ, clear) in [(false, 1.0), (true, 0.0)] {
            let r = try render(model: try await loadAvatarSampleA(),
                               reverseZ: reverseZ, clearDepth: clear)
            var drawn = 0, wroteDepth = 0
            for p in 0..<(r.color.count / 4) where r.color[p * 4 + 3] > 0 {
                drawn += 1
                if r.depth[p] != Float(clear) { wroteDepth += 1 }
            }
            XCTAssertGreaterThan(drawn, 5000, "reverseZ=\(reverseZ): render drew almost nothing")
            let fraction = Double(wroteDepth) / Double(drawn)
            print("[ReverseZPixelIdentity] reverseZ=\(reverseZ): \(wroteDepth)/\(drawn) drawn px wrote depth")
            XCTAssertGreaterThan(fraction, 0.8,
                "reverseZ=\(reverseZ): only \(wroteDepth)/\(drawn) drawn pixels wrote depth — the opaque depth path (prepass included) is not writing under this depth direction")
        }
    }

    /// The two depth buffers must be exact mirrors: `d_reverse ≈ 1 − d_standard`
    /// at every pixel, because the reverse projection is exactly the standard
    /// one with clip z remapped to w − z. This is the end-to-end pin on
    /// depth-WRITING behavior the color image can mask: a pass that stops
    /// writing (or compares wrongly) under one direction only leaves its
    /// pixels' depth to whatever drew behind, and the mirror breaks by
    /// orders of magnitude more than rounding (measured floor ~2e-6 vs the
    /// 1e-3 line). A pass equally broken in both directions is out of scope
    /// by construction — that is not a reverse-Z regression.
    ///
    /// Two scope notes, both fault-injected rather than assumed: outlines
    /// are OFF because the outline pass draws depth-writing hulls over the
    /// whole body and their mirrored depth masks missing surface writes;
    /// and the depth PREPASS issues zero draws on this asset (no plain
    /// `opaque` non-face primitives), so its execution is beyond any
    /// AvatarSample render test — its compare direction is pinned by
    /// `testEveryDepthStateFlipsItsCompareDirection` instead.
    func testDepthBuffersAreExactMirrors() async throws {
        let standard = try render(model: try await loadAvatarSampleA(), reverseZ: false, clearDepth: 1.0, outlines: false)
        let reversed = try render(model: try await loadAvatarSampleA(), reverseZ: true, clearDepth: 0.0, outlines: false)

        var violations = 0
        var worst: Float = 0
        for p in 0..<standard.depth.count {
            let e = abs(reversed.depth[p] - (1 - standard.depth[p]))
            if e > 1e-3 { violations += 1 }
            worst = max(worst, e)
        }
        print("[ReverseZPixelIdentity] depth mirror: \(violations) px beyond 1e-3, worst \(worst)")

        // Same shape of budget as the color identity: depth-test ties at
        // z-fight-marginal pixels may resolve to a different surface, whose
        // depth legitimately differs. A broken direction-sensitive pass
        // violates at thousands of pixels.
        XCTAssertLessThanOrEqual(violations, standard.depth.count / 2000,
            "\(violations) pixels break the d_reverse = 1 − d_standard mirror (worst |e| \(worst)) — a depth-writing pass is not behaving symmetrically across depth directions")
    }

    /// The `MTKViewDelegate` resize hook must install a projection matching
    /// the active depth direction. Overwriting with the standard far→1
    /// mapping while the compares are `.greater` silently inverts occlusion
    /// on every resize, even for a host that cleared depth correctly.
    func testResizeCallbackHonorsReverseZ() throws {
        guard let device else { throw XCTSkip("Metal device not available") }
        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off

        func ndcDepth(_ projection: float4x4, viewZ: Float) -> Float {
            let clip = projection * SIMD4<Float>(0, 0, viewZ, 1)
            return clip.z / clip.w
        }

        let view = DummyView(size: CGSize(width: 640, height: 480))
        for reverseZ in [false, true] {
            let renderer = VRMRenderer(device: device, config: config)
            renderer.useReverseZ = reverseZ
            renderer.mtkView(view, drawableSizeWillChange: CGSize(width: 320, height: 240))

            let near = ndcDepth(renderer.projectionMatrix, viewZ: -0.1001)
            let far = ndcDepth(renderer.projectionMatrix, viewZ: -99.9)
            if reverseZ {
                XCTAssertGreaterThan(near, far,
                    "resize installed a far→\(far) mapping with reverse-Z compares active — occlusion inverts on resize")
                XCTAssertEqual(near, 1, accuracy: 0.01)
                XCTAssertEqual(far, 0, accuracy: 0.01)
            } else {
                XCTAssertLessThan(near, far)
                XCTAssertEqual(near, 0, accuracy: 0.01)
                XCTAssertEqual(far, 1, accuracy: 0.01)
            }
        }
    }

    /// Every cached depth-stencil state's compare direction, pinned by name
    /// in both modes. This is the test the render-level A/B cannot replace:
    /// fault-injecting a single unflipped state (prepass compare hardcoded
    /// `.less`) passed both the pixel-identity budget AND a drawn-pixels-
    /// wrote-depth check, because other writers cover the same pixels on
    /// this asset. `MTLDepthStencilState` is not introspectable, so the
    /// renderer records each descriptor's compare at creation (DEBUG only).
    func testEveryDepthStateFlipsItsCompareDirection() throws {
        guard let device else { throw XCTSkip("Metal device not available") }
        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off

        let expectations: [(key: String, standard: MTLCompareFunction, reversed: MTLCompareFunction)] = [
            ("opaque", .less, .greater),
            ("mask", .less, .greater),
            ("prepass", .less, .greater),
            ("blend", .lessEqual, .greaterEqual),
            ("face", .lessEqual, .greaterEqual),
            ("faceOverlay", .lessEqual, .greaterEqual),
            ("opaqueEqual", .lessEqual, .greaterEqual),
            ("always", .always, .always),
        ]

        for reverseZ in [false, true] {
            let renderer = VRMRenderer(device: device, config: config)
            renderer.useReverseZ = reverseZ
            XCTAssertEqual(renderer.depthCompareByKey.count, expectations.count,
                           "Depth-state table changed shape — extend this test for the new state")
            for e in expectations {
                XCTAssertEqual(renderer.depthCompareByKey[e.key], reverseZ ? e.reversed : e.standard,
                               "depth state '\(e.key)' has the wrong compare direction for useReverseZ=\(reverseZ)")
            }
        }
    }

    // MARK: - Helpers

    private func loadAvatarSampleA() async throws -> VRMModel {
        let path = getTestVRM10ModelPath()
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("AvatarSample_A_1.0.vrm.glb not found (set MUSE_RESOURCES_PATH)")
        }
        return try await VRMModel.load(from: URL(fileURLWithPath: path), device: device)
    }

    private func render(model: VRMModel, reverseZ: Bool,
                        clearDepth: Double,
                        outlines: Bool = true) throws -> (color: [UInt8], depth: [Float]) {
        let width = 256, height = 256

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        // Prepass ON so its selection/binding path is inside every A/B —
        // the depth-mirror test below is what catches it misbehaving.
        config.enableDepthPrepass = true
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.useReverseZ = reverseZ
        if !outlines { renderer.outlineWidth = 0 }

        let projection = makePerspectiveProjection(
            fovY: Float.pi / 4,
            aspectRatio: Float(width) / Float(height),
            nearZ: 0.01,
            farZ: 100.0
        )
        renderer.projectionMatrix = reverseZ ? reverseZProjection(projection) : projection
        renderer.viewMatrix = makeLookAt(
            eye: SIMD3<Float>(0, 1.4, 0.6),
            target: SIMD3<Float>(0, 1.4, 0),
            up: SIMD3<Float>(0, 1, 0)
        )

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .shared
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private
        guard let colorTex = device.makeTexture(descriptor: colorDesc),
              let depthTex = device.makeTexture(descriptor: depthDesc),
              let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer() else {
            throw NSError(domain: "ReverseZPixelIdentityTests", code: 1)
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colorTex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.depthAttachment.texture = depthTex
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = clearDepth
        pass.depthAttachment.storeAction = .store

        renderer.drawOffscreenHeadless(
            to: colorTex, depth: depthTex,
            commandBuffer: commandBuffer, renderPassDescriptor: pass)

        // Depth is .private; blit it out so the depth-write test can read it.
        guard let depthReadback = device.makeBuffer(length: width * height * 4,
                                                    options: .storageModeShared),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw NSError(domain: "ReverseZPixelIdentityTests", code: 2)
        }
        blit.copy(from: depthTex, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: depthReadback, destinationOffset: 0,
                  destinationBytesPerRow: width * 4,
                  destinationBytesPerImage: width * height * 4)
        blit.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { buf in
            colorTex.getBytes(buf.baseAddress!, bytesPerRow: bytesPerRow,
                              from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        let depths = [Float](UnsafeBufferPointer(
            start: depthReadback.contents().assumingMemoryBound(to: Float.self),
            count: width * height))
        return (pixels, depths)
    }
}
