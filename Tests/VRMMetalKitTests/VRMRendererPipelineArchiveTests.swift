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

    /// With the flag on, constructing a renderer must build pipelines through
    /// the archive and flush a non-empty archive file into the configured dir.
    func testRendererWritesArchiveWhenFlagEnabled() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmk-rend-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var config = RendererConfig()
        config.strict = .off
        config.enablePipelineArchive = true
        config.pipelineArchiveDirectory = dir
        _ = VRMRenderer(device: device, config: config)

        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(
            files.contains { $0.hasSuffix(".metallib") },
            "Renderer with enablePipelineArchive must write a pipeline archive; found \(files)")
    }

    /// After init, the renderer must not leave the archive enabled on the
    /// process-wide shared cache — otherwise later renderers (incl. on other
    /// GPUs, or with the flag off) keep recording into the first renderer's
    /// archive. (Gitar review #334, finding 2.)
    func testRendererDisablesArchiveOnSharedAfterInit() throws {
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
