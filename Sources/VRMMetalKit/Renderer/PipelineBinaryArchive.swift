//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

import Foundation
import Metal

/// On-disk persistence layer for compiled `MTLRenderPipelineState`s.
///
/// Wraps an `MTLBinaryArchive` and a backing file URL so that pipeline states
/// compiled in one process can be reloaded — without the multi-millisecond
/// per-variant compile — on the next launch. The archive is GPU-family-specific
/// and keyed (via ``cacheURL(in:deviceName:shaderHash:)``) on both the device
/// name and the shader-source hash so a changed `.metallib` never serves stale
/// function signatures.
///
/// `@unchecked Sendable`: both stored properties are immutable (`let`) and the
/// wrapped `MTLBinaryArchive` is itself `Sendable`. The owner
/// (``VRMPipelineCache``) further confines all mutating calls (`record`,
/// `serialize`) to its `Mutex`-protected critical section, so cross-thread use
/// is serialised.
public final class PipelineBinaryArchive: @unchecked Sendable {

    /// Backing file the archive serialises to and loads from.
    public let url: URL
    /// Whether the backing file already existed when this archive was opened.
    /// A preloaded archive serves lookups but cannot be appended to and
    /// re-serialized in place — the gpuarchiver packer rejects the combined
    /// archive ("expecting 'fragment' stage in pipeline no. N") whenever the
    /// loaded entries were recorded in a process that also built them, which
    /// is every archive this cache writes. Callers heal a partial preloaded
    /// archive via ``rebuildAndSerialize(descriptors:)`` instead.
    public let wasPreloaded: Bool
    private let device: MTLDevice
    private let archive: any MTLBinaryArchive

    /// Opens the archive at `url`, loading existing contents when the file is
    /// present and starting empty otherwise (the first-launch path).
    ///
    /// - Throws: the underlying Metal error if `makeBinaryArchive` rejects an
    ///   existing file (e.g. wrong GPU family or corrupt archive).
    init(device: MTLDevice, url: URL) throws {
        self.url = url
        self.device = device
        let preloaded = FileManager.default.fileExists(atPath: url.path)
        self.wasPreloaded = preloaded
        let descriptor = MTLBinaryArchiveDescriptor()
        if preloaded {
            descriptor.url = url
        }
        self.archive = try device.makeBinaryArchive(descriptor: descriptor)
    }

    /// Points `descriptor.binaryArchives` at this archive so a subsequent
    /// `makeRenderPipelineState(descriptor:)` is served from the archive when
    /// the matching function set is already present (a lookup, not a compile).
    func prepare(_ descriptor: MTLRenderPipelineDescriptor) {
        descriptor.binaryArchives = [archive]
    }

    /// Records the render-pipeline functions described by `descriptor` into the
    /// archive so they survive ``serialize()``.
    func record(_ descriptor: MTLRenderPipelineDescriptor) throws {
        try archive.addRenderPipelineFunctions(descriptor: descriptor)
    }

    /// Writes the archive to its backing ``url``.
    func serialize() throws {
        try archive.serialize(to: url)
    }

    /// Replaces the on-disk file with a fresh archive containing exactly
    /// `descriptors` — the heal path for a partial *preloaded* archive, which
    /// cannot be appended to and re-serialized in place (see ``wasPreloaded``).
    /// Variants present in the old file but absent from `descriptors` are
    /// dropped; the archive converges to the variants actually requested.
    /// Recording descriptors whose pipelines were already built this session
    /// is served from the Metal compiler cache, not recompiled.
    func rebuildAndSerialize(descriptors: [MTLRenderPipelineDescriptor]) throws {
        let fresh = try device.makeBinaryArchive(descriptor: MTLBinaryArchiveDescriptor())
        for descriptor in descriptors {
            try fresh.addRenderPipelineFunctions(descriptor: descriptor)
        }
        try fresh.serialize(to: url)
    }

    // MARK: - Cache key

    /// Derives the archive file URL, keyed on the GPU and the shader-source
    /// hash. The device key prevents loading another GPU family's archive
    /// (Metal rejects it); the shader hash invalidates the archive whenever the
    /// compiled `.metallib` changes, so stale function signatures are never
    /// served.
    public static func cacheURL(in directory: URL, deviceName: String, shaderHash: String) -> URL {
        let safeDevice = deviceName.replacingOccurrences(of: " ", with: "-")
        return directory.appendingPathComponent("vrm-pipeline-\(safeDevice)-\(shaderHash).metallib")
    }
}
