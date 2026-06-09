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
@testable import VRMMetalKit

/// TDD for the on-disk pipeline binary archive that persists compiled MToon
/// pipeline states across process restarts (eliminating the cold first-launch
/// compile cost measured by `VRMBenchmark --mode pipeline`).
final class PipelineBinaryArchiveTests: XCTestCase {

    // MARK: - Cache-key invalidation (pure logic, no GPU)

    /// A shader-source change must route to a different archive file so a stale
    /// archive is never loaded against incompatible function signatures.
    func testArchiveURLChangesWithShaderHash() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vmk-test")
        let a = PipelineBinaryArchive.cacheURL(in: dir, deviceName: "Apple M4 Max", shaderHash: "aaa")
        let b = PipelineBinaryArchive.cacheURL(in: dir, deviceName: "Apple M4 Max", shaderHash: "bbb")
        XCTAssertNotEqual(a, b, "Different shader hashes must map to different archive files.")
    }

    /// Binary archives are GPU-family-specific; a different device must not load
    /// another device's archive (Metal would reject it at load time).
    func testArchiveURLChangesWithDevice() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vmk-test")
        let a = PipelineBinaryArchive.cacheURL(in: dir, deviceName: "Apple M4 Max", shaderHash: "aaa")
        let b = PipelineBinaryArchive.cacheURL(in: dir, deviceName: "Apple M1", shaderHash: "aaa")
        XCTAssertNotEqual(a, b, "Different devices must map to different archive files.")
    }

    // MARK: - Serialize / reload round-trip (needs GPU)

    /// Recording a compiled pipeline and serializing must produce a non-empty
    /// file that re-opens without error in a fresh archive instance — the
    /// across-process-restart path.
    func testSerializeWritesReloadableArchive() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no GPU") }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmk-archive-\(UUID().uuidString).metallib")
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try PipelineBinaryArchive(device: device, url: url)
        let descriptor = try makeMToonOpaqueDescriptor(device: device)
        archive.prepare(descriptor)
        _ = try device.makeRenderPipelineState(descriptor: descriptor)
        try archive.record(descriptor)
        try archive.serialize()

        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0, "Serialized binary archive must be a non-empty file.")

        XCTAssertNoThrow(
            try PipelineBinaryArchive(device: device, url: url),
            "A serialized archive must re-open without error in a fresh instance."
        )
    }

    /// Opening an archive whose backing file does not exist must succeed (empty
    /// archive), not throw — the first-launch path before anything is cached.
    func testInitWithMissingFileCreatesEmptyArchive() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no GPU") }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmk-absent-\(UUID().uuidString).metallib")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNoThrow(try PipelineBinaryArchive(device: device, url: url))
    }

    // MARK: - VRMPipelineCache integration (needs GPU)

    /// Enabling the persistent archive on a cache, building a pipeline, and
    /// flushing must write a non-empty archive keyed to this device+hash; a
    /// second cache pointed at the same directory+hash must reload it and still
    /// build the pipeline (the cross-restart path, exercised in-process via two
    /// isolated cache instances).
    func testPersistentArchiveRoundTripsThroughCache() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no GPU") }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmk-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // First "process": cold build, record, flush.
        let writer = VRMPipelineCache()
        try writer.enablePersistentArchive(device: device, directory: dir, shaderHash: "testhash")
        _ = try writer.getPipelineState(
            device: device,
            descriptor: try makeMToonOpaqueDescriptor(device: device),
            key: "mtoon_opaque_archive_test")
        try writer.flushPersistentArchive()

        let url = PipelineBinaryArchive.cacheURL(in: dir, deviceName: device.name, shaderHash: "testhash")
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0, "Flushing the archive must write a non-empty file.")

        // Second "process": load the archive and build the same pipeline.
        let reader = VRMPipelineCache()
        try reader.enablePersistentArchive(device: device, directory: dir, shaderHash: "testhash")
        XCTAssertNoThrow(
            try reader.getPipelineState(
                device: device,
                descriptor: try makeMToonOpaqueDescriptor(device: device),
                key: "mtoon_opaque_archive_test"),
            "A cache reloading a serialized archive must still build pipelines.")
    }

    /// A warm relaunch (archive preloaded from disk) must not re-serialize the
    /// archive — the pipelines are already on disk, so the flush is a no-op.
    /// Guards the dirty-flag optimization from being defeated by re-recording
    /// every key on enable. (Gitar review #334, finding 1.)
    func testWarmReloadDoesNotRewriteArchive() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no GPU") }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmk-warm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let cold = VRMPipelineCache()
        try cold.enablePersistentArchive(device: device, directory: dir, shaderHash: "warmtest")
        _ = try cold.getPipelineState(
            device: device, descriptor: try makeMToonOpaqueDescriptor(device: device), key: "k")
        XCTAssertTrue(try cold.flushPersistentArchive(), "Cold flush must write the archive.")

        let warm = VRMPipelineCache()
        try warm.enablePersistentArchive(device: device, directory: dir, shaderHash: "warmtest")
        _ = try warm.getPipelineState(
            device: device, descriptor: try makeMToonOpaqueDescriptor(device: device), key: "k")
        XCTAssertFalse(
            try warm.flushPersistentArchive(),
            "A warm relaunch must not re-serialize an already-complete preloaded archive.")
    }

    /// The benchmark and any host keying its own archive need a stable, non-nil
    /// shader hash so the archive invalidates when shaders change. (Finding 3.)
    func testBundledShaderHashIsStableAndNonNil() {
        let a = VRMPipelineCache.bundledShaderHash()
        let b = VRMPipelineCache.bundledShaderHash()
        XCTAssertNotNil(a, "Bundled shader hash must resolve from the package metallib.")
        XCTAssertEqual(a, b, "Bundled shader hash must be stable across calls.")
    }

    // MARK: - Helpers

    /// Builds a valid MToon opaque pipeline descriptor mirroring the renderer's
    /// own (`VRMRenderer+Pipeline`) so `makeRenderPipelineState` actually
    /// compiles and the archive has a real function to record.
    private func makeMToonOpaqueDescriptor(device: MTLDevice) throws -> MTLRenderPipelineDescriptor {
        let library = try VRMPipelineCache.shared.getLibrary(device: device)
        guard let vfn = library.makeFunction(name: "mtoon_vertex"),
              let ffn = library.makeFunction(name: "mtoon_fragment_v2") else {
            throw XCTSkip("MToon shader functions not present in bundled library.")
        }
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3
        vd.attributes[0].offset = MemoryLayout<VRMVertex>.offset(of: \.position)!
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float3
        vd.attributes[1].offset = MemoryLayout<VRMVertex>.offset(of: \.normal)!
        vd.attributes[1].bufferIndex = 0
        vd.attributes[2].format = .float2
        vd.attributes[2].offset = MemoryLayout<VRMVertex>.offset(of: \.texCoord)!
        vd.attributes[2].bufferIndex = 0
        vd.attributes[3].format = .float4
        vd.attributes[3].offset = MemoryLayout<VRMVertex>.offset(of: \.color)!
        vd.attributes[3].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<VRMVertex>.stride

        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vfn
        d.fragmentFunction = ffn
        d.vertexDescriptor = vd
        d.depthAttachmentPixelFormat = .depth32Float
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        return d
    }
}
