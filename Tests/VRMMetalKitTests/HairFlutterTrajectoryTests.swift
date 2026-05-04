// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// In-process trajectory-driven physics tests that catch Bug #6 (inertia
/// compensation disabled in `SpringBonePredict.metal`) by measuring whether
/// post-settle hair amplitude **decays** or **grows** over time. Sustained
/// or growing oscillation in the absence of input motion is the flutter
/// signature.
///
/// The test uses `VRMRenderer.drawOffscreenHeadless(...)` against a tiny
/// throwaway color/depth texture — that gets the production model-init
/// path (`populateSpringBoneData`, `warmupPhysics`, the per-frame
/// `update` → `writeBonesToNodes` → `updateNodeTransforms` chain) for
/// free. After each frame completes on the GPU,
/// `BoneTrajectoryDumper` reads `node.worldMatrix` into in-memory samples
/// that the assertion helpers consume.
///
/// Test assets are looked up via env vars with hard-coded local fallbacks.
/// CI without the assets gets `XCTSkip`, not a failure.
final class HairFlutterTrajectoryTests: XCTestCase {

    private var device: MTLDevice!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        self.device = device
    }

    /// AliciaSolid + Idle.vrma. After the bind-pose-to-gravity settling
    /// completes (~first 2 seconds at 30 fps), the chain tip should not
    /// keep growing in amplitude. Today this fails because Bug #6's
    /// inertia compensation is disabled — without it, even tiny idle
    /// animation movements pump the chain into sustained oscillation.
    @MainActor
    func testAliciaIdleHairChainDoesNotFlutterPostSettle() async throws {
        let aliciaPath = Self.assetPath(
            envKey: "MUSE_RESOURCES_PATH",
            envSuffix: "/VRM/AliciaSolid.vrm",
            fallback: "/Users/arkavo/Projects/Muse/Resources/VRM/AliciaSolid.vrm"
        )
        let idlePath = Self.assetPath(
            envKey: "VRMA_LOCOMOTION_PACK",
            envSuffix: "/Idle.vrma",
            fallback: "/Users/arkavo/Projects/VRMMetalKit/VRMA_Locomotion_Pack/Idle.vrma"
        )

        guard FileManager.default.fileExists(atPath: aliciaPath) else {
            throw XCTSkip("AliciaSolid.vrm not found at \(aliciaPath)")
        }
        guard FileManager.default.fileExists(atPath: idlePath) else {
            throw XCTSkip("Idle.vrma not found at \(idlePath)")
        }

        let model = try await VRMModel.load(
            from: URL(fileURLWithPath: aliciaPath),
            device: device
        )
        let clip = try VRMAnimationLoader.loadVRMA(
            from: URL(fileURLWithPath: idlePath),
            model: model
        )
        let player = AnimationPlayer()
        player.load(clip)
        player.play()

        // Use the production renderer for setup + per-frame physics so we
        // pick up populateSpringBoneData + warmupPhysics + the same
        // update/writeBonesToNodes/updateNodeTransforms ordering the .mov
        // pipeline uses.
        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.enableSpringBone = true

        // Tiny throwaway textures. We don't read pixels — drawOffscreenHeadless
        // just needs a valid render pass to drive the per-frame physics path.
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .private
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: 64, height: 64, mipmapped: false)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private
        guard let colorTex = device.makeTexture(descriptor: colorDesc),
              let depthTex = device.makeTexture(descriptor: depthDesc) else {
            XCTFail("Could not create throwaway textures")
            return
        }

        // Physics is independent of view/projection. Identity is fine.
        renderer.viewMatrix = matrix_identity_float4x4
        renderer.projectionMatrix = matrix_identity_float4x4

        guard let queue = device.makeCommandQueue() else {
            XCTFail("Could not create command queue")
            return
        }

        let dumper = try BoneTrajectoryDumper(filterPattern: "hair[0-9]+_(L|R)")

        let fps: Float = 30
        let dt: Float = 1.0 / fps
        let frameCount = 150  // 5 s — frames 60..<150 are the post-settle window.

        for frameIndex in 0..<frameCount {
            player.update(deltaTime: dt, model: model)

            guard let cb = queue.makeCommandBuffer() else {
                XCTFail("Could not create command buffer at frame \(frameIndex)")
                return
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
            while cb.status != .completed && cb.status != .error {
                await Task.yield()
            }

            dumper.recordFrame(
                model: model,
                frameIndex: frameIndex,
                timeSeconds: Double(frameIndex) * Double(dt)
            )
        }

        let samples = dumper.inMemorySamples
        XCTAssertGreaterThan(samples.count, 0, "Dumper produced no samples")

        // hair8_L is the chain tip on Alicia's left side — most sensitive to
        // accumulated flutter at the chain end.
        //
        // Window 60..<150 skips the first ~2 seconds of settling so we
        // measure steady-state behavior only.
        //
        // - Today (Bug #6 disabled): decay ratio ≥ 1.0 — amplitude is
        //   sustained or growing across the window.
        // - Once Bug #6 is fixed: amplitude should decay (ratio < 1).
        //
        // maxRMS is intentionally generous (50 mm) — the decay-ratio check
        // is the primary signal. The RMS sanity check is only here to
        // catch regressions where the chain explodes outright.
        assertNoFlutter(
            samples: samples,
            bone: "hair8_L",
            settledWindow: 60..<150,
            maxRMS: 0.050,
            minDecayRatio: 1.0
        )
    }

    // MARK: - Helpers

    private static func assetPath(envKey: String, envSuffix: String, fallback: String) -> String {
        if let base = ProcessInfo.processInfo.environment[envKey], !base.isEmpty {
            return base + envSuffix
        }
        return fallback
    }
}
