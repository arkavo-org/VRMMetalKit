// Copyright 2025 Arkavo Inc. and contributors
// Licensed under the Apache License, Version 2.0

import XCTest
import Metal
import simd
@testable import VRMMetalKit

/// Shared test fixtures for SpringBone unit tests.
///
/// Centralizes the four helpers that were independently redefined across
/// ~8 spring-bone test files: GLTF node construction, single-chain model
/// builders, `SpringBoneGlobalParams` defaults, and — most importantly —
/// the deterministic `runFrame` helper that drives the compute system
/// with a host-owned `MTLCommandBuffer.waitUntilCompleted()` instead of
/// `Thread.sleep` (the P0 issue called out in the test-suite review).
///
/// The buffer-readback helpers (`readBonePosition`, `readBonePositions`)
/// assume `.storageModeShared` Metal buffers, which is what
/// `SpringBoneBuffers.allocateBuffers(...)` produces.
enum SpringBoneTestFixtures {

    // MARK: - Node / chain builders

    /// Decode a minimal `GLTFNode` from a translation. Rotation is identity,
    /// scale is unit. Use this when you want a controlled bind pose without
    /// going through the full VRM loader.
    static func makeGLTFNode(name: String, translation: SIMD3<Float>) throws -> GLTFNode {
        let json = """
        {
            "name": "\(name)",
            "translation": [\(translation.x), \(translation.y), \(translation.z)],
            "rotation": [0.0, 0.0, 0.0, 1.0],
            "scale": [1.0, 1.0, 1.0]
        }
        """
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(GLTFNode.self, from: data)
    }

    /// Build a minimal `VRMModel` whose `nodes` form a single chain: node `i`
    /// is parented to node `i-1`, world transforms are precomputed, and the
    /// model's `device` is set to the supplied Metal device. The first node
    /// is the root (no parent).
    ///
    /// - Parameters:
    ///   - device: Metal device to attach to the model.
    ///   - names: Per-node names (one per chain link).
    ///   - translations: Local translation per node, in the same order as `names`.
    static func makeChainModel(
        device: MTLDevice,
        names: [String],
        translations: [SIMD3<Float>]
    ) throws -> VRMModel {
        precondition(names.count == translations.count,
                     "names and translations must have matching counts")
        let model = try VRMBuilder().setSkeleton(.defaultHumanoid).build()
        model.nodes.removeAll()
        var previous: VRMNode?
        for (i, name) in names.enumerated() {
            let gltf = try makeGLTFNode(name: name, translation: translations[i])
            let node = VRMNode(index: i, gltfNode: gltf)
            if let prev = previous {
                node.parent = prev
                prev.children.append(node)
            }
            model.nodes.append(node)
            previous = node
        }
        for n in model.nodes where n.parent == nil {
            n.updateWorldTransform()
        }
        model.device = device
        return model
    }

    /// Build a vertical chain rooted at world `(0, rootY, 0)` with successive
    /// joints displaced by `-boneLength` on the Y axis. Returns a fully
    /// initialized `VRMModel` whose world transforms are up to date.
    static func makeVerticalChain(
        device: MTLDevice,
        boneCount: Int,
        boneLength: Float = 0.1,
        rootY: Float = 1.0,
        namePrefix: String = "spring_bone_"
    ) throws -> VRMModel {
        var names: [String] = []
        var translations: [SIMD3<Float>] = []
        for i in 0..<boneCount {
            names.append("\(namePrefix)\(i)")
            translations.append(SIMD3<Float>(0, i == 0 ? rootY : -boneLength, 0))
        }
        return try makeChainModel(device: device, names: names, translations: translations)
    }

    // MARK: - Global-params defaults

    /// Default `SpringBoneGlobalParams` for unit tests. 120 Hz substep dt,
    /// standard gravity, no wind. Override individual fields as needed.
    ///
    /// `numBones` *must* match the chain length; other counts default to 0.
    static func defaultGlobalParams(
        numBones: Int,
        numSpheres: Int = 0,
        numCapsules: Int = 0,
        numPlanes: Int = 0,
        gravity: SIMD3<Float> = SIMD3<Float>(0, -9.8, 0),
        windAmplitude: Float = 0.0,
        windFrequency: Float = 0.0,
        windPhase: Float = 0.0,
        windDirection: SIMD3<Float> = SIMD3<Float>(1, 0, 0),
        externalVelocity: SIMD3<Float> = .zero,
        dragMultiplier: Float = 1.0
    ) -> SpringBoneGlobalParams {
        SpringBoneGlobalParams(
            gravity: gravity,
            dtSub: Float(1.0 / 120.0),
            windAmplitude: windAmplitude,
            windFrequency: windFrequency,
            windPhase: windPhase,
            windDirection: windDirection,
            substeps: 1,
            numBones: UInt32(numBones),
            numSpheres: UInt32(numSpheres),
            numCapsules: UInt32(numCapsules),
            numPlanes: UInt32(numPlanes),
            settlingFrames: 0,
            externalVelocity: externalVelocity,
            dragMultiplier: dragMultiplier
        )
    }

    /// Standard joint defaults for unit tests: low stiffness, modest gravity,
    /// modest drag, no angle limit. Override fields on the returned value.
    static func defaultJoint(node: Int) -> VRMSpringJoint {
        var j = VRMSpringJoint(node: node)
        j.hitRadius = 0.02
        j.stiffness = 0.5
        j.gravityPower = 0.5
        j.gravityDir = SIMD3<Float>(0, -1, 0)
        j.dragForce = 0.4
        return j
    }

    // MARK: - Deterministic GPU sync

    /// Run one frame of the spring-bone compute system using a caller-owned
    /// command buffer, then block until the GPU has finished. This replaces
    /// the `Thread.sleep(forTimeInterval: 0.2)` pattern that produced flaky
    /// tests under CI load.
    ///
    /// `SpringBoneComputeSystem.update(..., commandBuffer:)` encodes all
    /// substep work into the supplied buffer without committing; we commit
    /// and wait here so a subsequent CPU read of `bonePosCurr` sees the
    /// post-frame state.
    @discardableResult
    static func runFrame(
        system: SpringBoneComputeSystem,
        model: VRMModel,
        commandQueue: MTLCommandQueue,
        deltaTime: TimeInterval = 1.0 / 60.0
    ) throws -> MTLCommandBuffer {
        guard let cb = commandQueue.makeCommandBuffer() else {
            throw XCTSkip("Could not create command buffer")
        }
        system.update(model: model, deltaTime: deltaTime, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
        return cb
    }

    /// Run `frameCount` frames sequentially with `runFrame`. Each frame uses
    /// a fresh command buffer so the GPU has a deterministic boundary.
    static func runFrames(
        _ frameCount: Int,
        system: SpringBoneComputeSystem,
        model: VRMModel,
        commandQueue: MTLCommandQueue,
        deltaTime: TimeInterval = 1.0 / 60.0
    ) throws {
        for _ in 0..<frameCount {
            try runFrame(system: system, model: model,
                         commandQueue: commandQueue, deltaTime: deltaTime)
        }
    }

    // MARK: - Position readback

    /// Read a single bone's current world-space position from the SoA buffer.
    /// Returns `.zero` if buffers are missing or `boneIndex` is out of range —
    /// callers should `XCTAssert` on bounds before reading.
    static func readBonePosition(model: VRMModel, boneIndex: Int) -> SIMD3<Float> {
        guard let buffers = model.springBoneBuffers,
              boneIndex >= 0, boneIndex < buffers.numBones,
              let buf = buffers.bonePosCurr else { return .zero }
        let ptr = buf.contents().bindMemory(to: SIMD3<Float>.self,
                                            capacity: buffers.numBones)
        return ptr[boneIndex]
    }

    /// Read a single bone's previous-frame world-space position.
    static func readBonePrevPosition(model: VRMModel, boneIndex: Int) -> SIMD3<Float> {
        guard let buffers = model.springBoneBuffers,
              boneIndex >= 0, boneIndex < buffers.numBones,
              let buf = buffers.bonePosPrev else { return .zero }
        let ptr = buf.contents().bindMemory(to: SIMD3<Float>.self,
                                            capacity: buffers.numBones)
        return ptr[boneIndex]
    }

    /// Read every bone's current position into an array.
    static func readBonePositions(model: VRMModel) -> [SIMD3<Float>] {
        guard let buffers = model.springBoneBuffers,
              buffers.numBones > 0,
              let buf = buffers.bonePosCurr else { return [] }
        let ptr = buf.contents().bindMemory(to: SIMD3<Float>.self,
                                            capacity: buffers.numBones)
        return Array(UnsafeBufferPointer(start: ptr, count: buffers.numBones))
    }

    /// Sanity check: every bone position is finite and within a generous bound.
    /// Use this once at the end of physics tests so failures surface as
    /// "exploded into NaN" rather than downstream assertions on garbage values.
    static func assertNoNaNPositions(
        model: VRMModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let positions = readBonePositions(model: model)
        for (i, pos) in positions.enumerated() {
            XCTAssertTrue(pos.x.isFinite && pos.y.isFinite && pos.z.isFinite,
                "Bone \(i) position is not finite: \(pos)",
                file: file, line: line)
            XCTAssertLessThan(simd_length(pos), 1000.0,
                "Bone \(i) position exploded: \(pos)",
                file: file, line: line)
        }
    }

    // MARK: - Buffer overrides for controlled physics tests

    /// Seed `bonePosCurr` and `bonePosPrev` directly so a test can place a
    /// bone at a known starting state independent of whatever
    /// `populateSpringBoneData` chose. `prev` defaults to `curr` (zero
    /// velocity); pass distinct values to inject an initial velocity.
    static func seedBonePosition(
        buffers: SpringBoneBuffers,
        boneIndex: Int,
        curr: SIMD3<Float>,
        prev: SIMD3<Float>? = nil
    ) {
        guard boneIndex >= 0, boneIndex < buffers.numBones,
              let currBuf = buffers.bonePosCurr,
              let prevBuf = buffers.bonePosPrev else { return }
        let c = currBuf.contents().bindMemory(to: SIMD3<Float>.self,
                                              capacity: buffers.numBones)
        let p = prevBuf.contents().bindMemory(to: SIMD3<Float>.self,
                                              capacity: buffers.numBones)
        c[boneIndex] = curr
        p[boneIndex] = prev ?? curr
    }

    /// Override the rest length of a single bone after `populateSpringBoneData`.
    /// Useful for tests that build a chain with a non-default bone length and
    /// want the distance constraint to honor it.
    static func setRestLength(
        buffers: SpringBoneBuffers,
        boneIndex: Int,
        length: Float
    ) {
        guard boneIndex >= 0, boneIndex < buffers.numBones,
              let buf = buffers.restLengths else { return }
        let r = buf.contents().bindMemory(to: Float.self,
                                          capacity: buffers.numBones)
        r[boneIndex] = length
    }
}
