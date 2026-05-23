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
@testable import VRMMetalKit

/// vrm-conformance VMK#240 (and groundwork for VMK#236): render-level
/// reproduction of the spring-bone SHA collapse.
///
/// The sim-level test (`SpringBoneSwingTrajectoryTests`) confirms that
/// the spring-bone integrator differentiates all four stiffness values at
/// the joint-position level. The conformance harness still reports
/// stiffness 0 / 0.8 / 1 producing identical PNG SHAs in VMK while
/// three-vrm 3.5.0 differentiates them — so the bug has to live in the
/// **render path** (snapshot lag in `writeBonesToNodes`, skinning
/// not picking up updated positions, or similar).
///
/// This test replicates the full conformance flow in Swift: load → warmup
/// → animate root via `drawOffscreenHeadless` → final headless render →
/// hash the framebuffer. If VMK still collides hashes across stiffness
/// values, the bug is reproduced here in a fixable, debuggable form.
final class SpringBoneRenderConformanceTests: XCTestCase {

    // Conformance test.yaml `animation.root_transform` block.
    private let swingTranslationEnd = SIMD3<Float>(0.15, 0, 0)
    private let swingDurationSeconds: Float = 0.25
    private let swingFPS: Int = 60
    private let warmupSteps: Int = 30

    // Conformance test.yaml `camera` + `lighting` + `output` blocks.
    private let cameraPosition = SIMD3<Float>(0, 1.4, 1.5)
    private let cameraTarget   = SIMD3<Float>(0, 1.4, 0)
    private let cameraUp       = SIMD3<Float>(0, 1, 0)
    private let cameraFovYDeg: Float = 30
    private let keyLightDir   = SIMD3<Float>(-0.3, -0.6, -0.7)
    private let keyLightColor = SIMD3<Float>(1, 1, 1)
    private let keyLightIntensity: Float = 1.0
    private let ambientColor: SIMD3<Float> = SIMD3<Float>(0.5, 0.5, 0.5) * 0.3
    private let renderWidth = 256
    private let renderHeight = 256

    /// VMK#240 closed: all four stiffness sweep fixtures
    /// (`{0, 0.2, 0.8, 1}`) now render with **distinct** SHA256 hashes.
    /// The fix was at the warmup boundary, not in the PBD math — warmup
    /// now consumes the `settlingFrames` counter, so the post-warmup
    /// animation runs with stiffness fully engaged instead of scaled to
    /// zero by the lingering settling damping. Pre-fix all four collapsed
    /// to one SHA because `1 - smoothstep(0, 60, settlingFrames)` zeroed
    /// the stiffness contribution for the entire 0.25 s swing window.
    func testStiffnessSweepRendersFourDistinctHashes() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }
        guard let queue = device.makeCommandQueue() else {
            XCTFail("Could not create command queue"); return
        }

        let fixtures = [
            "swing_springbone_stiffness_0",
            "swing_springbone_stiffness_0p2",
            "swing_springbone_stiffness_0p8",
            "swing_springbone_stiffness_1"
        ]

        // Snapshot the configuration locally so the MainActor closure doesn't
        // capture `self` (XCTestCase isn't Sendable).
        let swingEnd = swingTranslationEnd
        let swingDuration = swingDurationSeconds
        let fps = swingFPS
        let warmup = warmupSteps
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
        for fixture in fixtures {
            let model = try await VRMModel.load(
                from: try bundleURL(for: fixture),
                device: device
            )
            hashes[fixture] = await MainActor.run {
                Self.renderFixtureToHash(
                    model: model, device: device, commandQueue: queue,
                    swingTranslationEnd: swingEnd, swingDurationSeconds: swingDuration,
                    swingFPS: fps, warmupSteps: warmup,
                    cameraPosition: cameraPos, cameraTarget: cameraTgt, cameraUp: cameraUpV,
                    cameraFovYDeg: fovYDeg,
                    keyLightDir: lightDir, keyLightColor: lightCol, keyLightIntensity: lightInt,
                    ambientColor: ambient,
                    renderWidth: w, renderHeight: h
                )
            }
        }

        let unique = Set(hashes.values)
        XCTAssertEqual(unique.count, 4,
            "Stiffness sweep should produce 4 distinct hashes; got \(unique.count). " +
            "Per-fixture hashes: \(hashes.map { "\($0.key) → \($0.value.prefix(8))" }.joined(separator: ", ")). " +
            "Regression of VMK#240 — most likely cause is that warmupPhysics " +
            "stopped decrementing `settlingFrames`, so the post-warmup animation " +
            "is running with the lingering settling damping zeroing stiffness.")
    }

    /// VMK#292 — same stiffness sweep on the `synchronousSpringBone` branch
    /// (PR #291's deterministic offline-render path). The conformance adapter
    /// takes this branch — it sets `synchronousSpringBone = true` and leaves
    /// `simulationDeltaTime` unset, so the renderer falls back to a fixed
    /// 1/60 s timestep. Pre-#291 the adapter's near-zero wall-clock
    /// `deltaTime` meant the integrator ran no substeps offline; post-#291
    /// it runs two substeps per frame (1/60 ÷ 1/120 = 2), which drains
    /// `settlingFrames` past the smoothstep gate during the swing window
    /// and collapses the stiffness axis to a single output.
    ///
    /// `testStiffnessSweepRendersFourDistinctHashes` above doesn't cover
    /// this branch because it sets `simulationDeltaTime = 1/60` explicitly
    /// and takes the override-first path in `VRMRenderer.swift:1394`.
    func testStiffnessSweepRendersFourDistinctHashesUnderSynchronousMode() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }
        guard let queue = device.makeCommandQueue() else {
            XCTFail("Could not create command queue"); return
        }

        let fixtures = [
            "swing_springbone_stiffness_0",
            "swing_springbone_stiffness_0p2",
            "swing_springbone_stiffness_0p8",
            "swing_springbone_stiffness_1"
        ]

        let swingEnd = swingTranslationEnd
        let swingDuration = swingDurationSeconds
        let fps = swingFPS
        let warmup = warmupSteps
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
        for fixture in fixtures {
            let model = try await VRMModel.load(
                from: try bundleURL(for: fixture),
                device: device
            )
            hashes[fixture] = await MainActor.run {
                Self.renderFixtureToHash(
                    model: model, device: device, commandQueue: queue,
                    swingTranslationEnd: swingEnd, swingDurationSeconds: swingDuration,
                    swingFPS: fps, warmupSteps: warmup,
                    cameraPosition: cameraPos, cameraTarget: cameraTgt, cameraUp: cameraUpV,
                    cameraFovYDeg: fovYDeg,
                    keyLightDir: lightDir, keyLightColor: lightCol, keyLightIntensity: lightInt,
                    ambientColor: ambient,
                    renderWidth: w, renderHeight: h,
                    useSynchronousSpringBoneFallback: true
                )
            }
        }

        let unique = Set(hashes.values)
        XCTAssertEqual(unique.count, 4,
            "VMK#292: stiffness sweep must produce 4 distinct hashes on the " +
            "synchronousSpringBone fallback branch too, not just when " +
            "simulationDeltaTime is set explicitly. Got \(unique.count). " +
            "Per-fixture hashes: \(hashes.map { "\($0.key) → \($0.value.prefix(8))" }.joined(separator: ", ")). " +
            "Collision on this branch means warmupPhysics isn't fully draining " +
            "settlingFrames; the post-warmup animation runs through the " +
            "`1 - smoothstep(0, 60, settlingFrames)` gate while still inside " +
            "the warmup band, zeroing the stiffness contribution for the " +
            "entire swing window — exact regression signature of VMK#240.")
    }

    // MARK: - Render harness

    private func bundleURL(for fixture: String) throws -> URL {
        guard let url = Bundle.module.url(
            forResource: fixture,
            withExtension: "vrm",
            subdirectory: "TestData/Conformance"
        ) else {
            throw XCTSkip("\(fixture).vrm not bundled in Conformance/")
        }
        return url
    }

    @MainActor
    private static func renderFixtureToHash(
        model: VRMModel,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        swingTranslationEnd: SIMD3<Float>,
        swingDurationSeconds: Float,
        swingFPS: Int,
        warmupSteps: Int,
        cameraPosition: SIMD3<Float>,
        cameraTarget: SIMD3<Float>,
        cameraUp: SIMD3<Float>,
        cameraFovYDeg: Float,
        keyLightDir: SIMD3<Float>,
        keyLightColor: SIMD3<Float>,
        keyLightIntensity: Float,
        ambientColor: SIMD3<Float>,
        renderWidth: Int,
        renderHeight: Int,
        useSynchronousSpringBoneFallback: Bool = false
    ) -> String {
        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        // The conformance adapter takes the synchronousSpringBone fallback
        // (sync flag on, no explicit simulationDeltaTime) — the path PR #291
        // shipped for VMK#283 determinism. The original VMK#240 test below
        // takes the explicit-override path. Both must produce four distinct
        // stiffness hashes (VMK#292).
        config.synchronousSpringBone = useSynchronousSpringBoneFallback
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.enableSpringBone = true
        // Deterministic frame pacing: per-frame physics deltaTime matches
        // the swing fps so the integrator runs the same number of substeps
        // regardless of wall-clock test speed. On the sync-fallback branch
        // we leave `simulationDeltaTime` unset so the renderer falls back
        // to a fixed 1/60 s — the path the conformance adapter exercises.
        if !useSynchronousSpringBoneFallback {
            renderer.simulationDeltaTime = 1.0 / Double(swingFPS)
        }

        // Camera + lighting matched to the conformance test.yaml.
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

        renderer.warmupPhysics(steps: warmupSteps)

        // Animate root translation: snapshot originals, drive frames through
        // single-sample dummy targets (matches the conformance adapter so
        // the snapshot-readback timing is realistic).
        let rootNodes = model.nodes.filter { $0.parent == nil }
        let originals = rootNodes.map { $0.translation }
        let totalFrames = max(1, Int((swingDurationSeconds * Float(swingFPS)).rounded()))

        let dummyColor = makeTexture(
            device: device, width: 64, height: 64,
            format: .bgra8Unorm, usage: [.renderTarget], storage: .private
        )
        let dummyDepth = makeTexture(
            device: device, width: 64, height: 64,
            format: .depth32Float, usage: [.renderTarget], storage: .private
        )

        for frame in 1...totalFrames {
            let t = Float(frame) / Float(totalFrames)
            let offset = swingTranslationEnd * t
            for (idx, root) in rootNodes.enumerated() {
                root.translation = originals[idx] + offset
                root.updateWorldTransform()
            }

            guard let cb = commandQueue.makeCommandBuffer() else {
                XCTFail("makeCommandBuffer failed at frame \(frame)")
                return ""
            }
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = dummyColor
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            rpd.depthAttachment.texture = dummyDepth
            rpd.depthAttachment.loadAction = .clear
            rpd.depthAttachment.storeAction = .dontCare
            rpd.depthAttachment.clearDepth = 1.0
            renderer.drawOffscreenHeadless(to: dummyColor, depth: dummyDepth,
                                            commandBuffer: cb, renderPassDescriptor: rpd)
            let sem = DispatchSemaphore(value: 0)
            cb.addCompletedHandler { _ in sem.signal() }
            cb.commit()
            sem.wait()
        }

        // TODO(VMK#240): no snapshot-drain pass here. The renderer's
        // writeBonesToNodes consumes the *previous* frame's GPU snapshot,
        // so without a drain the final hashed render sees positions from
        // swing frame N-1. That's what the conformance harness sees too
        // (it doesn't drain either) — keeping the lag in mirrors the
        // adapter's behaviour. A future PR that fixes the snapshot lag
        // (or that closes #240 via PBD tuning) may want to add a drain
        // pass; the hashes will need re-baselining either way.

        // Final render — full-size, shareable color target so we can hash pixels.
        let colorTexture = makeTexture(
            device: device, width: renderWidth, height: renderHeight,
            format: .bgra8Unorm, usage: [.renderTarget, .shaderRead], storage: .shared
        )
        let depthTexture = makeTexture(
            device: device, width: renderWidth, height: renderHeight,
            format: .depth32Float, usage: [.renderTarget], storage: .private
        )
        guard let finalCB = commandQueue.makeCommandBuffer() else {
            XCTFail("makeCommandBuffer failed for final render")
            return ""
        }
        let finalRPD = MTLRenderPassDescriptor()
        finalRPD.colorAttachments[0].texture = colorTexture
        finalRPD.colorAttachments[0].loadAction = .clear
        finalRPD.colorAttachments[0].storeAction = .store
        finalRPD.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        finalRPD.depthAttachment.texture = depthTexture
        finalRPD.depthAttachment.loadAction = .clear
        finalRPD.depthAttachment.storeAction = .dontCare
        finalRPD.depthAttachment.clearDepth = 1.0
        renderer.drawOffscreenHeadless(to: colorTexture, depth: depthTexture,
                                        commandBuffer: finalCB, renderPassDescriptor: finalRPD)
        let finalSem = DispatchSemaphore(value: 0)
        finalCB.addCompletedHandler { _ in finalSem.signal() }
        finalCB.commit()
        finalSem.wait()

        // Hash the pixel bytes.
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

    // MARK: - Camera helpers (copy of conformance camera convention)

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
