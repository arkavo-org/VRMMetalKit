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

/// TDD for wiring the on-disk pipeline binary archive into `VRMRenderer` behind
/// `RendererConfig.enablePipelineArchive`. Confined to its own class with a
/// tearDown that resets the process-wide cache, so toggling archive state on
/// the shared singleton does not leak into other (parallel) test classes.
@MainActor
final class VRMRendererPipelineArchiveTests: XCTestCase {

    private var device: MTLDevice!

    override func setUp() async throws {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no GPU") }
        device = d
    }

    override func tearDown() async throws {
        VRMPipelineCache.shared.disablePersistentArchive()
        VRMPipelineCache.shared.clearCache()
    }

    /// The capability query must report `false` exactly on the simulator, where
    /// `MTLBinaryArchive.serialize(to:)` trips an uncatchable Metal assertion
    /// (`+[MTLLoader sliceIDForDevice:...] 'Target device architecture is nil'`),
    /// and `true` on every real-GPU platform.
    func testPersistentArchiveSupportMatchesPlatform() {
        #if targetEnvironment(simulator)
        XCTAssertFalse(VRMPipelineCache.isPersistentArchiveSupported,
                       "Archive serialisation aborts on the simulator; support must be reported false.")
        #else
        XCTAssertTrue(VRMPipelineCache.isPersistentArchiveSupported,
                      "Archive serialisation works on real GPUs; support must be reported true.")
        #endif
    }

    /// With the flag on, constructing a renderer must build pipelines through
    /// the archive and flush a non-empty archive file into the configured dir —
    /// unless the platform cannot serialise archives, where the request must
    /// degrade silently to in-memory caching rather than abort the process.
    func testRendererWritesArchiveWhenFlagEnabled() throws {
        try skipOnBetaMetalDriverAborts()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmk-rend-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var config = RendererConfig()
        config.strict = .off
        config.enablePipelineArchive = true
        config.pipelineArchiveDirectory = dir
        let enabled = VRMRenderer.enablePipelineArchiveIfRequested(device: device, config: config)
        _ = VRMRenderer(device: device, config: config)

        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        if VRMPipelineCache.isPersistentArchiveSupported {
            XCTAssertTrue(enabled, "Archive must be enabled on a platform that supports serialisation.")
            XCTAssertTrue(
                files.contains { $0.hasSuffix(".metallib") },
                "Renderer with enablePipelineArchive must write a pipeline archive; found \(files)")
        } else {
            XCTAssertFalse(enabled, "Archive must bail out on a platform that cannot serialise it.")
            XCTAssertTrue(files.isEmpty,
                          "Unsupported platform must write no archive; found \(files)")
        }
    }

    /// The public choke point must be safe on its own: a consumer that wires
    /// ``VRMPipelineCache/enablePersistentArchive(device:directory:shaderHash:)``
    /// directly (as `VRMBenchmark` does) and then flushes must not abort on the
    /// simulator. `flushPersistentArchive()` is documented to *throw* on failure,
    /// so a `try?` at the call site is the only defence a consumer has — and an
    /// assertion walks straight through it.
    func testDirectArchiveWiringNeverAborts() throws {
        try skipOnBetaMetalDriverAborts()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmk-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try VRMPipelineCache.shared.enablePersistentArchive(
            device: device, directory: dir, shaderHash: "test-hash")

        XCTAssertEqual(
            VRMPipelineCache.shared.getStatistics().persistentArchiveEnabled,
            VRMPipelineCache.isPersistentArchiveSupported,
            "Persistence must engage only where the archive can actually be serialised.")

        var config = RendererConfig()
        config.strict = .off
        _ = VRMRenderer(device: device, config: config)

        // Must return (or throw) — never trap.
        let flushed = try VRMPipelineCache.shared.flushPersistentArchive()
        if !VRMPipelineCache.isPersistentArchiveSupported {
            XCTAssertFalse(flushed, "Flush must be a no-op where persistence never engaged.")
        }
    }

    /// After init, the renderer must not leave the archive enabled on the
    /// process-wide shared cache — otherwise later renderers (incl. on other
    /// GPUs, or with the flag off) keep recording into the first renderer's
    /// archive. (Gitar review #334, finding 2.)
    func testRendererDisablesArchiveOnSharedAfterInit() throws {
        try skipOnBetaMetalDriverAborts()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmk-rend-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var config = RendererConfig()
        config.strict = .off
        config.enablePipelineArchive = true
        config.pipelineArchiveDirectory = dir
        _ = VRMRenderer(device: device, config: config)

        XCTAssertFalse(
            VRMPipelineCache.shared.getStatistics().persistentArchiveEnabled,
            "VRMRenderer must disable persistence on the shared cache after the init-time flush.")
    }

    /// With the flag off (default), constructing a renderer must not write any
    /// archive into the configured dir.
    func testRendererWritesNothingWhenFlagDisabled() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmk-rend-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var config = RendererConfig()
        config.strict = .off
        config.enablePipelineArchive = false
        config.pipelineArchiveDirectory = dir
        _ = VRMRenderer(device: device, config: config)

        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(files.isEmpty,
                      "Renderer without the flag must not write an archive; found \(files)")
    }
}
