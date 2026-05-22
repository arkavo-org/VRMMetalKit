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

/// VMK#283: the animated spring-bone path must be deterministic.
///
/// The vrm-conformance adapter loads a VRM, runs `warmupPhysics`, drives a
/// per-frame `animate_root_transform` loop, and renders. From 0.16.0-rc.1 the
/// same binary on the same input produced multiple distinct PNGs across
/// repeated runs — a CPU/GPU data race localised to the animated multi-joint
/// spring-bone path.
///
/// Root cause: the self-committed `SpringBoneComputeSystem.update()` path
/// (no host-owned `commandBuffer:`) overwrites `animatedRootPositionsBuffer`
/// and `animatedRootPositionsPrevBuffer` for frame N+1 while frame N's
/// per-substep command buffers may still be reading them on the GPU. The
/// per-substep aligned-offset buffering added in #278 de-conflicts substeps
/// *within* a frame but the same slots are reused every frame, so nothing
/// orders frame N's GPU reads before frame N+1's host writes.
///
/// These tests drive the exact conformance flow at the sim level and assert
/// (a) byte-identical joint positions across repeated runs and (b) that the
/// self-committed result matches the race-free host-synchronised path.
final class SpringBoneAnimatedDeterminismTests: XCTestCase {

    /// Mirrors the conformance fixture's `animation.root_transform` block:
    /// 60 frames at 60 Hz translating the root to (0, 0, -0.15).
    private let swingTranslationEnd = SIMD3<Float>(0, 0, -0.15)
    private let swingFrames = 60
    private let swingFPS: Double = 60
    private let warmupSteps = 30
    private let fixture = "swing_springbone_stiffness_0p8"

    /// The animated swing must produce byte-identical joint positions every
    /// run. Pre-fix, the self-committed path raced and collapsed to several
    /// distinct outputs (issue #283 observed 3 distinct PNGs across 5 runs).
    func testAnimatedSwingIsDeterministicAcrossRuns() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }

        let runCount = 12
        var runs: [[UInt32]] = []
        for _ in 0..<runCount {
            runs.append(try await simulateSwingSelfCommitted(device: device))
        }

        let reference = runs[0]
        XCTAssertFalse(reference.isEmpty, "no joint positions captured")
        for (index, run) in runs.enumerated() {
            XCTAssertEqual(run, reference,
                "Run \(index) diverged from run 0 — the animated spring-bone " +
                "path is non-deterministic (issue #283). Distinct outputs " +
                "across \(runCount) identical runs.")
        }
    }

    /// The self-committed path (no `commandBuffer:`) must match the race-free
    /// host-owned path that commits and waits per frame. This pins the fix to
    /// the *correct* result, not merely a deterministic one.
    func testSelfCommittedSwingMatchesHostSynchronisedPath() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (CI without GPU)")
        }
        guard let queue = device.makeCommandQueue() else {
            XCTFail("Could not create command queue"); return
        }

        let selfCommitted = try await simulateSwingSelfCommitted(device: device)
        let synchronised = try await simulateSwingHostSynchronised(
            device: device, commandQueue: queue)

        XCTAssertEqual(selfCommitted.count, synchronised.count,
            "joint count mismatch between drive paths")
        XCTAssertEqual(selfCommitted, synchronised,
            "Self-committed animated swing diverged from the host-synchronised " +
            "(race-free) path — issue #283.")
    }

    // MARK: - Harness

    /// Drive the swing through the self-committed `update()` path with no
    /// per-frame GPU synchronisation — exactly what the conformance adapter
    /// and any direct `SpringBoneComputeSystem.update()` caller does.
    private func simulateSwingSelfCommitted(device: MTLDevice) async throws -> [UInt32] {
        let (model, system) = try await loadAndWarmup(device: device)
        let rootNodes = model.nodes.filter { $0.parent == nil }
        let originals = rootNodes.map { $0.translation }

        for frame in 1...swingFrames {
            applyRootTransform(frame: frame, rootNodes: rootNodes, originals: originals)
            system.update(model: model, deltaTime: 1.0 / swingFPS)
        }
        // Drain the spring system's own command queue so bonePosCurr reflects
        // the final substep before we read it.
        system.waitForPendingFrame()
        return try captureJointBits(model: model)
    }

    /// Drive the swing through the host-owned shared command-buffer path,
    /// committing and waiting per frame. This path has no CPU/GPU race because
    /// frame N fully completes before frame N+1 is encoded.
    private func simulateSwingHostSynchronised(
        device: MTLDevice, commandQueue: MTLCommandQueue
    ) async throws -> [UInt32] {
        let (model, system) = try await loadAndWarmup(device: device)
        let rootNodes = model.nodes.filter { $0.parent == nil }
        let originals = rootNodes.map { $0.translation }

        for frame in 1...swingFrames {
            applyRootTransform(frame: frame, rootNodes: rootNodes, originals: originals)
            guard let cb = commandQueue.makeCommandBuffer() else {
                XCTFail("Could not create command buffer"); return []
            }
            system.update(model: model, deltaTime: 1.0 / swingFPS, commandBuffer: cb)
            cb.commit()
            await cb.completed()
        }
        return try captureJointBits(model: model)
    }

    private func loadAndWarmup(device: MTLDevice) async throws
        -> (VRMModel, SpringBoneComputeSystem) {
        guard let url = Bundle.module.url(
            forResource: fixture, withExtension: "vrm",
            subdirectory: "TestData/Conformance"
        ) else {
            throw XCTSkip("\(fixture).vrm not bundled in Conformance/")
        }
        let model = try await VRMModel.load(from: url, device: device)
        let system = try SpringBoneComputeSystem(device: device)
        try system.populateSpringBoneData(model: model)
        system.warmupPhysics(model: model, steps: warmupSteps)
        return (model, system)
    }

    private func applyRootTransform(
        frame: Int, rootNodes: [VRMNode], originals: [SIMD3<Float>]
    ) {
        let t = Float(frame) / Float(swingFrames)
        let offset = swingTranslationEnd * t
        for (idx, root) in rootNodes.enumerated() {
            root.translation = originals[idx] + offset
            root.updateWorldTransform()
        }
    }

    /// Capture every joint's `bonePosCurr` as raw float bit patterns so the
    /// comparison is exact (byte-identical), matching the conformance suite's
    /// blake3-of-PNG determinism check.
    private func captureJointBits(model: VRMModel) throws -> [UInt32] {
        guard let buffers = model.springBoneBuffers,
              let bonePosCurr = buffers.bonePosCurr,
              buffers.numBones > 0 else {
            XCTFail("\(fixture): no spring-bone buffers after simulation")
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
