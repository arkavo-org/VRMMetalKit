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

/// Spec §6.1: three-layer default-path identity. (i) exact CPU identity of
/// effective values; (ii) a bit-exact GPU spring baseline captured BEFORE any
/// kernel change — this, not the 1mm-envelope CSVs, certifies the recompiled
/// metallib. Serialization is Float.bitPattern text, the PipelineBaseline
/// discipline; regeneration is env-gated so a normal run cannot overwrite its
/// own oracle.
final class SpringBoneBitBaselineTests: XCTestCase {

    private static let frames = 90
    private static let fps: Float = 30
    private static let minFrameIntervalNanos: UInt64 = 35_000_000

    @MainActor private func load(_ filename: String, fit: Bool) async throws -> VRMModel {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let path = getTestModelPath(filename)
        try requireFixture(path, hint: filename)
        var options = VRMLoadingOptions(augmentSpringBoneColliders: true)
        options.fitClothCollisionToMesh = fit
        let model = try await VRMModel.load(from: URL(fileURLWithPath: path), device: device, options: options)
        model.updateNodeTransforms()
        return model
    }

    /// 6.1(i): flag off, effective == authored, every joint, three fixtures.
    @MainActor func testFlagOffEffectiveEqualsAuthored() async throws {
        for f in ["AvatarSample_A_1.0.vrm.glb", "AvatarSample_U_1.0.vrm.glb", "AvatarSample_M_1.0.vrm"] {
            let model = try await load(f, fit: false)
            guard let sb = model.springBone else { continue }
            for (si, spring) in sb.springs.enumerated() {
                for (ji, joint) in spring.joints.enumerated() {
                    XCTAssertEqual(joint.effectiveHitRadius ?? joint.hitRadius, joint.hitRadius,
                        "\(f) s\(si) j\(ji): flag off must leave effective == authored")
                }
            }
        }
    }

    /// Flag ON must actually change something (the discriminating direction —
    /// without this, (i) could pass with the plumbing dead).
    @MainActor func testFlagOnRaisesAtLeastOneJoint() async throws {
        let model = try await load("AvatarSample_M_1.0.vrm", fit: true)
        guard let sb = model.springBone else { return XCTFail("no springbone") }
        let raised = sb.springs.flatMap(\.joints).filter { ($0.effectiveHitRadius ?? $0.hitRadius) > $0.hitRadius + 1e-6 }
        XCTAssertGreaterThan(raised.count, 10,
            "flag on raised only \(raised.count) joints on M — plumbing is not wired")
    }

    // MARK: - 6.1(ii) bit-exact GPU baseline

    private func fixturePath() -> String {
        let name = "avatar_a_ultra_flagoff"
        if let root = Bundle.module.resourceURL {
            let bundled = root.appendingPathComponent("Fixtures/SpringBitBaseline/\(name).txt")
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled.path }
        }
        return "\(getProjectRoot())/Tests/VRMMetalKitTests/Fixtures/SpringBitBaseline/\(name).txt"
    }

    private func sourceTreeFixturePath() -> String {
        "\(getProjectRoot())/Tests/VRMMetalKitTests/Fixtures/SpringBitBaseline/avatar_a_ultra_flagoff.txt"
    }

    /// Drives `frames` steps of the renderer's synchronous spring path and
    /// invokes `perFrame` after each committed frame, mirroring the offscreen
    /// loop in SpringBoneStressPosePenetrationTests (renderer,
    /// synchronousSpringBone, drawOffscreenHeadless, commit, spin).
    @MainActor private func runOffscreenFrames(
        renderer: VRMRenderer,
        player: AnimationPlayer,
        model: VRMModel,
        device: MTLDevice,
        frames: Int,
        fps: Float,
        perFrame: (Int) -> Void
    ) async throws {
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .private
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: 64, height: 64, mipmapped: false)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private
        guard let colorTex = device.makeTexture(descriptor: colorDesc),
              let depthTex = device.makeTexture(descriptor: depthDesc),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Could not allocate Metal resources")
        }

        let dt: Float = 1.0 / fps

        for frameIndex in 0..<frames {
            if frameIndex > 0 {
                try await Task.sleep(nanoseconds: Self.minFrameIntervalNanos)
            }

            player.update(deltaTime: dt, model: model)

            guard let cb = queue.makeCommandBuffer() else {
                XCTFail("Could not create command buffer at frame \(frameIndex)")
                break
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
                commandBuffer: cb, renderPassDescriptor: rpd)
            cb.commit()
            while cb.status != .completed && cb.status != .error { await Task.yield() }

            perFrame(frameIndex)
        }
    }

    @MainActor private func captureSequence() async throws -> [String] {
        let model = try await load("AvatarSample_A_1.0.vrm.glb", fit: false)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        var config = RendererConfig(); config.sampleCount = 1; config.strict = .off
        config.synchronousSpringBone = true
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.enableSpringBone = true
        renderer.springBoneQuality = .ultra
        renderer.viewMatrix = matrix_identity_float4x4
        renderer.projectionMatrix = matrix_identity_float4x4
        let player = AnimationPlayer()
        player.load(StressPoseFactory.clip(.armsCrossed, duration: Float(Self.frames) / Self.fps))
        player.play()

        var jointNodes: [Int] = []
        if let sb = model.springBone {
            for spring in sb.springs { for (i, j) in spring.joints.enumerated() where i > 0 { jointNodes.append(j.node) } }
        }

        var lines: [String] = []
        try await runOffscreenFrames(renderer: renderer, player: player, model: model,
                                     device: device, frames: Self.frames, fps: Self.fps) { _ in
            for n in jointNodes {
                let p = model.nodes[n].worldPosition
                lines.append("\(p.x.bitPattern) \(p.y.bitPattern) \(p.z.bitPattern)")
            }
        }
        return lines
    }

    /// Opt-in regeneration only — a normal run cannot overwrite the oracle.
    @MainActor func testGenerateBitBaseline() async throws {
        guard ProcessInfo.processInfo.environment["SPRING_BIT_BASELINE_GENERATE"] == "1" else {
            throw XCTSkip("generation is opt-in: SPRING_BIT_BASELINE_GENERATE=1")
        }
        let lines = try await captureSequence()
        let dir = (sourceTreeFixturePath() as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(toFile: sourceTreeFixturePath(), atomically: true, encoding: .utf8)
    }

    @MainActor func testBitBaselineMatches() async throws {
        let path = fixturePath()
        guard FileManager.default.fileExists(atPath: path) else {
            return XCTFail("missing committed bit baseline at \(path) — generate with SPRING_BIT_BASELINE_GENERATE=1 BEFORE any kernel change")
        }
        let expected = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let actual = try await captureSequence()
        XCTAssertEqual(actual.count, expected.count, "sequence length changed")
        var firstDiff: Int? = nil
        for i in 0..<min(actual.count, expected.count) where actual[i] != expected[i] { firstDiff = i; break }
        XCTAssertNil(firstDiff, "bit divergence at sample \(firstDiff ?? -1) of \(expected.count)")
    }
}
