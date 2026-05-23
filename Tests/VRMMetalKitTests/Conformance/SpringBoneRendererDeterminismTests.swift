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

/// VMK#283 — renderer-level determinism for the animated spring-bone path.
///
/// `SpringBoneAnimatedDeterminismTests` covers the sim-level contract by
/// calling `SpringBoneComputeSystem.update` directly with an explicit
/// `deltaTime`. The conformance adapter goes through `VRMRenderer`'s
/// `drawOffscreenHeadless`, which derives `deltaTime` from
/// `CACurrentMediaTime()` whenever `simulationDeltaTime` is nil
/// (VRMRenderer.swift:1385-1389). Wall-clock pacing between frames varies
/// run-to-run, the XPBD substep accumulator picks up a different number of
/// substeps each frame, and the simulation diverges across repeated runs of
/// the same input — the race the adapter reproducer hits.
///
/// `config.synchronousSpringBone` is documented as the offline-render path
/// ("fine for offline rendering" — StrictMode.swift). Offline rendering and
/// wall-clock pacing are incompatible: this test asserts that enabling
/// synchronous mode is enough on its own to get bit-deterministic output,
/// without callers having to know about `simulationDeltaTime` too.
final class SpringBoneRendererDeterminismTests: XCTestCase {

    private let swingTranslationEnd = SIMD3<Float>(0, 0, -0.15)
    private let swingFrames = 15
    private let warmupSteps = 30
    private let fixture = "swing_springbone_stiffness_0p2"
    private let runCount = 12

    /// Driving the renderer with `synchronousSpringBone = true` and no
    /// explicit `simulationDeltaTime` must produce byte-identical
    /// `bonePosCurr` across repeated runs of the same input. Pre-fix the
    /// renderer's wall-clock `deltaTime` varies run-to-run, the substep
    /// accumulator picks up different substep counts per frame, and joint
    /// positions diverge (issue #283 conformance reproducer).
    func testSynchronousSpringBoneIsDeterministicAcrossRendererRuns() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }
        guard let queue = device.makeCommandQueue() else {
            XCTFail("Could not create command queue"); return
        }

        let swingEnd = swingTranslationEnd
        let frames = swingFrames
        let warmup = warmupSteps
        let fixtureURL = try bundleURL(for: fixture)

        var runs: [[UInt32]] = []
        for _ in 0..<runCount {
            let model = try await VRMModel.load(from: fixtureURL, device: device)
            let bits = await MainActor.run {
                Self.simulateThroughRenderer(
                    model: model, device: device, commandQueue: queue,
                    swingTranslationEnd: swingEnd, swingFrames: frames,
                    warmupSteps: warmup
                )
            }
            runs.append(bits)
        }

        let reference = runs[0]
        XCTAssertFalse(reference.isEmpty, "no joint positions captured")
        for (index, run) in runs.enumerated() {
            XCTAssertEqual(run, reference,
                "Run \(index) diverged from run 0 — the renderer-driven " +
                "spring-bone path is non-deterministic even with " +
                "synchronousSpringBone=true. Issue #283 conformance " +
                "reproducer.")
        }
    }

    // MARK: - Harness

    private func bundleURL(for fixture: String) throws -> URL {
        guard let url = Bundle.module.url(
            forResource: fixture, withExtension: "vrm",
            subdirectory: "TestData/Conformance"
        ) else {
            throw XCTSkip("\(fixture).vrm not bundled in Conformance/")
        }
        return url
    }

    /// Drive the swing through `VRMRenderer.drawOffscreenHeadless` with
    /// `synchronousSpringBone = true` and `simulationDeltaTime = nil`,
    /// mirroring how the conformance adapter exercises the renderer in
    /// `handleAnimateRootTransform`. Renders into a 64×64 throwaway target
    /// so the cost is dominated by the spring-bone path under test.
    @MainActor
    private static func simulateThroughRenderer(
        model: VRMModel, device: MTLDevice, commandQueue: MTLCommandQueue,
        swingTranslationEnd: SIMD3<Float>, swingFrames: Int, warmupSteps: Int
    ) -> [UInt32] {
        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        config.synchronousSpringBone = true
        // Intentionally NOT setting simulationDeltaTime — the contract under
        // test is that synchronousSpringBone alone is sufficient for
        // offline-render determinism.
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.enableSpringBone = true

        renderer.warmupPhysics(steps: warmupSteps)

        let rootNodes = model.nodes.filter { $0.parent == nil }
        let originals = rootNodes.map { $0.translation }

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false
        )
        colorDesc.usage = [.renderTarget]
        colorDesc.storageMode = .private
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: 64, height: 64, mipmapped: false
        )
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private
        guard let dummyColor = device.makeTexture(descriptor: colorDesc),
              let dummyDepth = device.makeTexture(descriptor: depthDesc)
        else {
            XCTFail("Could not create throwaway render targets")
            return []
        }

        for frame in 1...swingFrames {
            let t = Float(frame) / Float(swingFrames)
            let offset = swingTranslationEnd * t
            for (idx, root) in rootNodes.enumerated() {
                root.translation = originals[idx] + offset
                root.updateWorldTransform()
            }

            guard let cb = commandQueue.makeCommandBuffer() else {
                XCTFail("makeCommandBuffer failed at frame \(frame)")
                return []
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

        guard let buffers = model.springBoneBuffers,
              let bonePosCurr = buffers.bonePosCurr,
              buffers.numBones > 0 else {
            XCTFail("\(model): no spring-bone buffers after simulation")
            return []
        }
        let ptr = bonePosCurr.contents().bindMemory(
            to: SIMD3<Float>.self, capacity: buffers.numBones)
        var bits: [UInt32] = []
        bits.reserveCapacity(buffers.numBones * 3)
        for i in 0..<buffers.numBones {
            let p = ptr[i]
            XCTAssertTrue(p.x.isFinite && p.y.isFinite && p.z.isFinite,
                "joint \(i) is non-finite: \(p)")
            bits.append(p.x.bitPattern)
            bits.append(p.y.bitPattern)
            bits.append(p.z.bitPattern)
        }
        return bits
    }
}
