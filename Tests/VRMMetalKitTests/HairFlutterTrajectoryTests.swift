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

        let samples = try await renderTrajectory(
            vrmPath: aliciaPath,
            vrmaPath: idlePath,
            fps: 30,
            frameCount: 150,
            filter: "hair[0-9]+_(L|R)"
        )
        XCTAssertGreaterThan(samples.count, 0, "Dumper produced no samples")

        // hair8_L is the chain tip on Alicia's left side — most sensitive to
        // accumulated flutter at the chain end.
        //
        // Window 60..<150 skips the first ~2 seconds of settling so we
        // measure steady-state behavior only.
        //
        // Threshold context: Idle.vrma loops, so the chain reaches a small
        // dynamic equilibrium (~16 mm RMS) rather than truly damping. Decay
        // ratio cycles between 0.55 and 3.1 depending on which window of the
        // cycle you sample. Pre-audit (all bugs present): decay ≈ 2.1× in
        // this window — clear sustained pumping. Post-audit-fix (PR A + PR
        // B): decay ≈ 1.2× — the chain is small-amplitude noisy but no
        // longer pumping. minDecayRatio is set to 2.0 so this catches the
        // pre-fix flutter signal while accepting realistic small-amplitude
        // variation under a cyclic animation. Bug #6's compensation only
        // engages above ~2 mm/frame parent motion (smoothstep gate); Idle's
        // sub-mm twitches don't trigger it, which is by design — fast-motion
        // gating belongs in a separate trajectory test.
        //
        // maxRMS catches gross chain explosion regressions.
        assertNoFlutter(
            samples: samples,
            bone: "hair8_L",
            settledWindow: 60..<150,
            maxRMS: 0.050,
            minDecayRatio: 2.0
        )
    }

    /// AliciaSolid + Action_Jump.vrma — a fast-motion clip with crouch, push-off,
    /// peak, and landing phases. The spring physics should stay sane through all
    /// of it: no NaN/Inf, no bone teleporting outside reasonable world bounds, no
    /// chain link stretching catastrophically. This is a regression guardrail —
    /// it passes today and should keep passing as Bug fixes land.
    @MainActor
    func testAliciaJumpRunsWithoutNaNOrChainExplosion() async throws {
        let aliciaPath = Self.assetPath(
            envKey: "MUSE_RESOURCES_PATH",
            envSuffix: "/VRM/AliciaSolid.vrm",
            fallback: "/Users/arkavo/Projects/Muse/Resources/VRM/AliciaSolid.vrm"
        )
        let jumpPath = Self.assetPath(
            envKey: "VRMA_AVATAR_MEGA_PACK",
            envSuffix: "/Action_Jump.vrma",
            fallback: "/Users/arkavo/Projects/VRMMetalKit/VRMA_Avatar_Mega_Pack/Action_Jump.vrma"
        )

        guard FileManager.default.fileExists(atPath: aliciaPath) else {
            throw XCTSkip("AliciaSolid.vrm not found at \(aliciaPath)")
        }
        guard FileManager.default.fileExists(atPath: jumpPath) else {
            throw XCTSkip("Action_Jump.vrma not found at \(jumpPath)")
        }

        let samples = try await renderTrajectory(
            vrmPath: aliciaPath,
            vrmaPath: jumpPath,
            fps: 30,
            frameCount: 120,
            filter: "(hair|skirt|mituami)[0-9_]*(L|R)?"
        )
        XCTAssertGreaterThan(samples.count, 0, "Dumper produced no samples")

        // Alicia is human-scale — every spring joint should stay within ±5 m of
        // world origin. Hair link rest lengths are ≤100 mm, skirt links similar;
        // 0.3 m is comfortable headroom for fast motion without flagging
        // legitimate physics swings.
        assertSpringChainsStable(
            samples: samples,
            maxAbsoluteCoordinate: 5.0,
            maxLinkLength: 0.3
        )
    }

    // MARK: - Helpers

    /// Run a 5-second physics simulation through `VRMRenderer.drawOffscreenHeadless`
    /// and collect the trajectory in memory. Shared by all renderer-driven tests
    /// in this file.
    @MainActor
    private func renderTrajectory(
        vrmPath: String,
        vrmaPath: String,
        fps: Float,
        frameCount: Int,
        filter: String
    ) async throws -> [BoneTrajectoryDumper.Sample] {
        let model = try await VRMModel.load(
            from: URL(fileURLWithPath: vrmPath),
            device: device
        )
        let clip = try VRMAnimationLoader.loadVRMA(
            from: URL(fileURLWithPath: vrmaPath),
            model: model
        )
        let player = AnimationPlayer()
        player.load(clip)
        player.play()

        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.enableSpringBone = true
        renderer.viewMatrix = matrix_identity_float4x4
        renderer.projectionMatrix = matrix_identity_float4x4

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

        let dumper = try BoneTrajectoryDumper(filterPattern: filter)
        let dt: Float = 1.0 / fps

        for frameIndex in 0..<frameCount {
            player.update(deltaTime: dt, model: model)

            guard let cb = queue.makeCommandBuffer() else {
                XCTFail("Could not create command buffer at frame \(frameIndex)")
                return dumper.inMemorySamples
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

        return dumper.inMemorySamples
    }


    private static func assetPath(envKey: String, envSuffix: String, fallback: String) -> String {
        if let base = ProcessInfo.processInfo.environment[envKey], !base.isEmpty {
            return base + envSuffix
        }
        return fallback
    }
}
