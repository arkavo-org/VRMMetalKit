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

/// VMK#396 — per-substep host writes must reach the GPU per substep.
///
/// `update()` rewrites `globalParams`, `bindDirections` and the collider
/// buffers from the host inside the substep loop, but historically only
/// `animatedRootPositions` was segmented by substep index (the #278 fix). The
/// other three were single regions every dispatch read at offset 0, which
/// failed differently on each command-buffer path:
///
/// - Self-committed (`synchronousSpringBone`): each substep is committed
///   immediately, so substep i+1's host write landed while substep i was still
///   reading it — a race, visible as run-to-run divergence under load (#394).
/// - Shared-buffer: every substep is encoded before the caller commits, so no
///   dispatch had run by the time the last write landed and *every* substep
///   read the final substep's values. Deterministic, silent, wrong.
///
/// `warmupPhysics` already documents this race and pays a full GPU drain per
/// step to dodge it; the runtime loop cannot afford that, so it segments
/// instead.
///
/// These tests assert the GPU-visible buffer state directly. A physics-output
/// assertion cannot isolate the defect: the two paths also differ by design
/// (the sleep gate is async-only, and `writeBonesToNodes` consumes the previous
/// frame's snapshot on the async path — the #267 one-frame lag), so they are
/// not expected to agree bit-for-bit even when segmentation is correct.
@MainActor
final class SpringBoneSubstepSegmentationTests: XCTestCase {

    private let fixture = "swing_springbone_stiffness_0p2"
    private let warmupSteps = 30

    /// Every buffer the substep loop rewrites must have room for one slot per
    /// substep. Without the capacity there is nowhere for substep i's values to
    /// live while substep i-1 is still reading its own.
    func testHostRewrittenBuffersAreAllocatedOneSlotPerSubstep() async throws {
        let (_, model) = try await loadSimulated()
        guard let buffers = model.springBoneBuffers else {
            XCTFail("no spring-bone buffers"); return
        }
        let slots = SpringBoneBuffers.substepSlots
        XCTAssertGreaterThan(slots, 1, "segmentation is meaningless with a single slot")

        XCTAssertGreaterThan(buffers.bindDirectionsStride, 0)
        XCTAssertGreaterThanOrEqual(
            buffers.bindDirections?.length ?? 0, buffers.bindDirectionsStride * slots,
            "bindDirections must hold one slot per substep (VMK#396)")

        if buffers.numSpheres > 0 {
            XCTAssertGreaterThanOrEqual(
                buffers.sphereColliders?.length ?? 0, buffers.sphereColliderStride * slots,
                "sphereColliders must hold one slot per substep (VMK#396)")
        }
        if buffers.numCapsules > 0 {
            XCTAssertGreaterThanOrEqual(
                buffers.capsuleColliders?.length ?? 0, buffers.capsuleColliderStride * slots,
                "capsuleColliders must hold one slot per substep (VMK#396)")
        }
    }

    /// Two substeps of one frame interpolate to different `t`, so each must
    /// land in its own slot. Driving the interpolation directly keeps this
    /// independent of when `update()` captures its targets.
    ///
    /// `globalParams` is deliberately not asserted: every substep writes
    /// byte-identical params today (`var params = globalParams` copies a stale
    /// `let`, and neither `windPhase` nor `settlingFrames` is written back), so
    /// its slots carry no per-substep signal to check.
    func testEachSubstepInterpolatesIntoItsOwnSlot() async throws {
        let (system, model) = try await loadSimulated()
        guard let buffers = model.springBoneBuffers, buffers.numBones > 0,
              let bindDirections = buffers.bindDirections else {
            XCTFail("no spring-bone buffers"); return
        }
        try XCTSkipIf(SpringBoneBuffers.substepSlots < 2, "needs >= 2 slots")

        // Known interpolation endpoints: straight down -> straight forward.
        let count = buffers.numBones
        system.previousWorldBindDirections = Array(repeating: SIMD3<Float>(0, -1, 0), count: count)
        system.targetWorldBindDirections = Array(repeating: SIMD3<Float>(0, 0, -1), count: count)

        system.interpolateAllTransforms(t: 0.5, buffers: buffers, substepIndex: 0)
        system.interpolateAllTransforms(t: 1.0, buffers: buffers, substepIndex: 1)

        func slot(_ index: Int) -> [SIMD3<Float>] {
            let ptr = bindDirections.contents()
                .advanced(by: index * buffers.bindDirectionsStride)
                .bindMemory(to: SIMD3<Float>.self, capacity: count)
            return (0..<count).map { ptr[$0] }
        }

        let halfway = simd_normalize(SIMD3<Float>(0, -0.5, -0.5))
        let end = SIMD3<Float>(0, 0, -1)

        for i in 0..<count {
            XCTAssertEqual(
                simd_length(slot(0)[i] - halfway), 0, accuracy: 1e-5,
                "substep 0 wrote \(slot(0)[i]); its slot must hold the t=0.5 interpolant. "
                    + "A later substep overwriting it is the VMK#396 defect.")
            XCTAssertEqual(
                simd_length(slot(1)[i] - end), 0, accuracy: 1e-5,
                "substep 1 wrote \(slot(1)[i]); its slot must hold the t=1.0 interpolant (VMK#396).")
        }
    }

    // MARK: - Harness

    /// Runs a few frames of a translating swing on the self-committed path and
    /// returns the system plus its model, with all buffers populated.
    private func loadSimulated(rotating: Bool = false) async throws -> (SpringBoneComputeSystem, VRMModel) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Could not create command queue")
        }
        guard let url = Bundle.module.url(
            forResource: fixture, withExtension: "vrm",
            subdirectory: "TestData/Conformance"
        ) else {
            throw XCTSkip("\(fixture).vrm not bundled in Conformance/")
        }

        let model = try await VRMModel.load(from: url, device: device)
        guard let system = Self.drive(model: model, device: device, queue: queue,
                                      warmupSteps: warmupSteps, rotating: rotating) else {
            throw XCTSkip("could not drive the spring-bone system")
        }
        return (system, model)
    }

    /// Synchronous so the per-frame `DispatchSemaphore.wait()` is legal — it is
    /// unavailable from an async context.
    @MainActor
    private static func drive(model: VRMModel, device: MTLDevice, queue: MTLCommandQueue,
                              warmupSteps: Int, rotating: Bool) -> SpringBoneComputeSystem? {
        var config = RendererConfig()
        config.sampleCount = 1
        config.strict = .off
        config.synchronousSpringBone = true
        let renderer = VRMRenderer(device: device, config: config)
        renderer.loadModel(model)
        renderer.enableSpringBone = true
        renderer.simulationDeltaTime = 1.0 / 60.0
        renderer.warmupPhysics(steps: warmupSteps)

        let rootNodes = model.nodes.filter { $0.parent == nil }
        let originals = rootNodes.map { $0.translation }
        let originalRotations = rootNodes.map { $0.rotation }

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        colorDesc.usage = [.renderTarget]
        colorDesc.storageMode = .private
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: 64, height: 64, mipmapped: false)
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private
        guard let color = device.makeTexture(descriptor: colorDesc),
              let depth = device.makeTexture(descriptor: depthDesc) else {
            return nil
        }

        for frame in 1...4 {
            let t = Float(frame) / 4.0
            for (idx, root) in rootNodes.enumerated() {
                if rotating {
                    // Bind directions come from parent rotations, so only
                    // rotation makes them vary across a frame's substeps.
                    let pitch = simd_quatf(angle: t * .pi / 2, axis: SIMD3<Float>(1, 0, 0))
                    root.rotation = pitch * originalRotations[idx]
                } else {
                    root.translation = originals[idx] + SIMD3<Float>(0, 0, -0.15) * t
                }
                root.updateWorldTransform()
            }
            guard let cb = queue.makeCommandBuffer() else { return nil }
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = color
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.depthAttachment.texture = depth
            rpd.depthAttachment.loadAction = .clear
            rpd.depthAttachment.storeAction = .dontCare
            rpd.depthAttachment.clearDepth = 1.0
            renderer.drawOffscreenHeadless(to: color, depth: depth,
                                           commandBuffer: cb, renderPassDescriptor: rpd)
            let sem = DispatchSemaphore(value: 0)
            cb.addCompletedHandler { _ in sem.signal() }
            cb.commit()
            sem.wait()
        }

        return renderer.springBoneComputeSystem
    }
}
