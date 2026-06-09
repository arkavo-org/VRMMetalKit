//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//


import Foundation
import Metal
import QuartzCore
import Synchronization

/// Process-wide cache for compiled Metal shader libraries and pipeline states shared by every ``VRMRenderer``.
///
/// ## Discussion
/// Pipeline state creation is one of the slower operations in Metal (tens of
/// milliseconds for a complex MToon variant). The renderer relies on this
/// cache to make repeat avatar loads, swapping between renderers in the same
/// process, and re-creating ``VRMRenderer`` instances after a Metal device
/// reset essentially free for the second-and-subsequent occurrences.
///
/// Most callers never interact with this type directly — ``VRMRenderer``
/// already routes its library and pipeline-state lookups through the
/// ``shared`` singleton. The public API exists for:
///
/// - **Testing**: ``clearCache()`` lets unit tests start from a clean cache.
/// - **Memory pressure**: hosts handling `UIApplication.didReceiveMemoryWarningNotification`
///   can call ``clearCache()`` to drop cached pipeline states.
/// - **Diagnostics**: ``getStatistics()`` reports current cache occupancy.
///
/// The cache is keyed by:
/// - Shader library: one of three bundled `VRMMetalKitShaders*.metallib` slices (macOS / iOS device / iOS Simulator).
/// - Pipeline state: caller-supplied `key` string that must encode shader
///   function names, pixel format, alpha mode, MSAA sample count, and any
///   other discriminator that would change the compiled pipeline.
///
/// ## Thread Safety
/// All mutable state (`libraries`, `pipelineStates`) is bundled in a single `Mutex`-protected
/// `State` struct. `Mutex` serialises access from any thread; Metal objects stored there
/// (`MTLLibrary`, `MTLRenderPipelineState`) are immutable after creation. Callers may invoke
/// any method from any thread.
public final class VRMPipelineCache: Sendable {
    /// Process-wide shared instance. ``VRMRenderer`` routes all pipeline lookups through this singleton.
    public static let shared = VRMPipelineCache()

    private struct State {
        var libraries: [String: MTLLibrary] = [:]
        var pipelineStates: [String: MTLRenderPipelineState] = [:]
        /// Optional on-disk archive; when present, pipeline builds are served
        /// from / recorded into it so compiled states survive process restarts.
        var archive: PipelineBinaryArchive?
        /// Set when a new pipeline is recorded into `archive`, so
        /// ``flushPersistentArchive()`` only writes when there is new content.
        var archiveDirty: Bool = false
        /// Pipeline keys already harvested into the current `archive`, so each
        /// is recorded at most once per archive session.
        var archivedKeys: Set<String> = []
        /// `true` when `archive` was loaded from an existing file. A preloaded
        /// archive is treated as complete, so builds are served from it without
        /// re-recording or re-serializing on a warm relaunch.
        var archivePreloaded: Bool = false
    }

    private let _state: Mutex<State>

    /// Creates an isolated cache. Production code uses the ``shared`` singleton;
    /// this initialiser exists so tests (and hosts wanting a private cache) can
    /// own cache state without polluting the process-wide instance.
    init() {
        self._state = Mutex(State())
    }

    /// Returns the bundled MToon/SpringBone `MTLLibrary`, loading it from the package resources on first call.
    ///
    /// The appropriate platform slice (`VRMMetalKitShaders*.metallib` for
    /// macOS, iOS device, or iOS Simulator) is selected at runtime and compiled
    /// by `make shaders`. The first call on a given process pays the disk +
    /// Metal-validation cost; later calls return the same cached library instance.
    ///
    /// - Parameter device: The `MTLDevice` to create the library against.
    /// - Returns: The compiled shader library.
    /// - Throws: ``PipelineCacheError/shaderLibraryNotFound`` if the bundled
    ///   metallib is missing, or ``PipelineCacheError/shaderLibraryLoadFailed(_:)``
    ///   wrapping the underlying Metal error.
    public func getLibrary(device: MTLDevice) throws -> MTLLibrary {
        return try _state.withLock { state in
            // The bundled library is platform-specific; key the cache on the
            // resolved slice name so the entry is self-documenting.
            let key = VRMShaderLibraryLoader.bundledLibraryName

            if let cached = state.libraries[key] {
                vrmLog("[VRMPipelineCache] ✅ Using cached shader library")
                return cached
            }

            do {
                let library = try VRMShaderLibraryLoader.loadBundledLibrary(device: device)
                state.libraries[key] = library
                return library
            } catch VRMShaderLibraryLoaderError.shaderLibraryMissing(let name) {
                vrmLog("[VRMPipelineCache] ❌ \(name).metallib not found in package resources")
                throw PipelineCacheError.shaderLibraryNotFound
            } catch VRMShaderLibraryLoaderError.shaderLibraryLoadFailed(_, let underlying) {
                throw PipelineCacheError.shaderLibraryLoadFailed(underlying)
            }
        }
    }

    /// Returns a cached `MTLRenderPipelineState` matching `key`, building it from `descriptor` on the first request.
    ///
    /// - Important: The cache key must include every input that would affect
    ///   pipeline compilation (vertex/fragment function names, pixel format,
    ///   alpha-to-coverage flag, MSAA sample count). Two callers that pass the
    ///   same `key` will receive the same compiled pipeline; if their
    ///   descriptors actually differ, only the first wins.
    ///
    /// - Parameters:
    ///   - device: The `MTLDevice` used when the pipeline must be built.
    ///   - descriptor: Pipeline configuration used on first request for `key`.
    ///   - key: Stable identifier discriminating this pipeline variant from others.
    /// - Returns: The cached or freshly created pipeline state.
    /// - Throws: The underlying `MTLDevice.makeRenderPipelineState` error if
    ///   pipeline compilation fails (`NSError` from the Metal driver).
    public func getPipelineState(
        device: MTLDevice,
        descriptor: MTLRenderPipelineDescriptor,
        key: String
    ) throws -> MTLRenderPipelineState {
        return try _state.withLock { state in
            let pipelineState: MTLRenderPipelineState
            if let cached = state.pipelineStates[key] {
                vrmLog("[VRMPipelineCache] ✅ Using cached pipeline state: \(key)")
                pipelineState = cached
            } else {
                vrmLog("[VRMPipelineCache] 🔨 Creating new pipeline state: \(key)")
                let startTime = CACurrentMediaTime()

                #if DEBUG
                descriptor.shaderValidation = .enabled
                #endif
                // When a persistent archive is active, point the descriptor at it
                // so the build is a lookup if the function set is already harvested.
                state.archive?.prepare(descriptor)
                pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)

                let elapsed = (CACurrentMediaTime() - startTime) * 1000
                vrmLog("[VRMPipelineCache] ✅ Pipeline state created in \(String(format: "%.2f", elapsed))ms")
                state.pipelineStates[key] = pipelineState
            }

            // Harvest into the archive once per key — even on an in-memory cache
            // hit. Without this, a pipeline already compiled before the archive
            // was enabled (e.g. a non-first renderer) would never reach disk.
            // Skipped when the archive was preloaded from disk: it already holds
            // these pipelines, so re-recording would only force a redundant
            // re-serialize on every warm relaunch. A record failure must never
            // break rendering — degrade silently.
            if state.archive != nil, !state.archivePreloaded, !state.archivedKeys.contains(key) {
                do {
                    try state.archive?.record(descriptor)
                    state.archivedKeys.insert(key)
                    state.archiveDirty = true
                } catch {
                    vrmLog("[VRMPipelineCache] ⚠️ Archive record failed for \(key): \(error)")
                }
            }

            return pipelineState
        }
    }

    /// Enables on-disk pipeline persistence, loading any archive already cached
    /// for this device + shader build.
    ///
    /// After enabling, ``getPipelineState(device:descriptor:key:)`` serves
    /// builds from the archive when the matching function set is present and
    /// records new builds into it; call ``flushPersistentArchive()`` to write
    /// the accumulated archive back to disk (e.g. after first-model load).
    ///
    /// - Parameters:
    ///   - device: The `MTLDevice` the archive is built against.
    ///   - directory: Directory holding the archive file. The filename is
    ///     derived from `device.name` and `shaderHash`.
    ///   - shaderHash: Hash of the compiled `.metallib`; a change routes to a
    ///     fresh archive so stale function signatures are never loaded.
    /// - Throws: the underlying Metal error if an existing archive file is
    ///   incompatible (wrong GPU family) or corrupt.
    public func enablePersistentArchive(device: MTLDevice, directory: URL, shaderHash: String) throws {
        let url = PipelineBinaryArchive.cacheURL(
            in: directory, deviceName: device.name, shaderHash: shaderHash)
        let archive = try PipelineBinaryArchive(device: device, url: url)
        _state.withLock { state in
            state.archive = archive
            state.archiveDirty = false
            state.archivePreloaded = archive.wasPreloaded
            state.archivedKeys.removeAll(keepingCapacity: true)
        }
    }

    /// Writes the in-memory archive to disk when new pipelines have been
    /// recorded since the last flush. No-op when persistence is disabled, the
    /// archive was preloaded unchanged, or nothing new was built.
    ///
    /// - Returns: `true` if the archive was actually serialized, `false` if the
    ///   flush was a no-op.
    /// - Throws: the underlying Metal error if serialisation fails.
    @discardableResult
    public func flushPersistentArchive() throws -> Bool {
        try _state.withLock { state in
            guard let archive = state.archive, state.archiveDirty else { return false }
            try archive.serialize()
            state.archiveDirty = false
            return true
        }
    }

    /// Turns off on-disk pipeline persistence, dropping the in-memory archive
    /// handle. Subsequent builds neither read from nor record to an archive
    /// until ``enablePersistentArchive(device:directory:shaderHash:)`` is called
    /// again. The on-disk file is left intact.
    public func disablePersistentArchive() {
        _state.withLock { state in
            state.archive = nil
            state.archiveDirty = false
            state.archivePreloaded = false
            state.archivedKeys.removeAll(keepingCapacity: true)
        }
    }

    /// A stable hash of the bundled shader library, suitable as the
    /// `shaderHash` key for ``enablePersistentArchive(device:directory:shaderHash:)``.
    /// Returns `nil` if the bundled metallib slice cannot be read.
    public static func bundledShaderHash() -> String? {
        VRMShaderLibraryLoader.bundledLibraryHash()
    }

    /// Drops every cached shader library and pipeline state.
    ///
    /// The next call to ``getLibrary(device:)`` or ``getPipelineState(device:descriptor:key:)``
    /// will rebuild from scratch. Useful for memory pressure response,
    /// test isolation, and forcing a shader reload during development.
    public func clearCache() {
        _state.withLock { state in
            let libraryCount = state.libraries.count
            let pipelineCount = state.pipelineStates.count

            state.libraries.removeAll()
            state.pipelineStates.removeAll()

            vrmLog("[VRMPipelineCache] 🗑️ Cache cleared: \(libraryCount) libraries, \(pipelineCount) pipeline states")
        }
    }

    /// Returns a snapshot of current cache occupancy. Useful for diagnostics dashboards.
    public func getStatistics() -> CacheStatistics {
        return _state.withLock { state in
            CacheStatistics(
                libraryCount: state.libraries.count,
                pipelineStateCount: state.pipelineStates.count,
                persistentArchiveEnabled: state.archive != nil
            )
        }
    }

    /// Snapshot of cache occupancy returned by ``getStatistics()``.
    public struct CacheStatistics {
        /// Number of cached `MTLLibrary` instances (currently always 0 or 1 — the bundled metallib).
        public let libraryCount: Int
        /// Number of distinct compiled `MTLRenderPipelineState` instances retained by the cache.
        public let pipelineStateCount: Int
        /// Whether on-disk pipeline persistence is currently enabled.
        public let persistentArchiveEnabled: Bool
    }
}

// MARK: - Error Types

/// Failures raised by ``VRMPipelineCache`` when locating or loading the bundled shader library.
public enum PipelineCacheError: Error, LocalizedError {
    /// The platform-appropriate `VRMMetalKitShaders*.metallib` slice is missing from the package's resource bundle.
    /// Usually means the package was built without first running `make shaders` to generate all platform slices.
    case shaderLibraryNotFound
    /// `MTLDevice.makeLibrary(URL:)` rejected the bundled metallib. The associated error carries
    /// the Metal-driver-level reason.
    case shaderLibraryLoadFailed(Error)

    /// Localized message with the failing condition and the underlying error (when present).
    public var errorDescription: String? {
        switch self {
        case .shaderLibraryNotFound:
            return "Bundled VRMMetalKit shader library not found in package resources. " +
                   "Run `make shaders` to rebuild all platform slices."
        case .shaderLibraryLoadFailed(let error):
            return "Failed to load bundled VRMMetalKit shader library: \(error.localizedDescription)"
        }
    }
}
