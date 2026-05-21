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
/// `@unchecked Sendable`. Backed by an `NSLock` that protects the internal
/// `libraries` and `pipelineStates` dictionaries. The Metal objects stored in
/// those dictionaries (`MTLLibrary`, `MTLRenderPipelineState`) are immutable
/// after creation, so concurrent reads of returned values are safe. Callers
/// may invoke any method from any thread.
public final class VRMPipelineCache: @unchecked Sendable {
    /// Process-wide shared instance. ``VRMRenderer`` routes all pipeline lookups through this singleton.
    public static let shared = VRMPipelineCache()

    private let lock = NSLock()
    private var libraries: [String: MTLLibrary] = [:]
    private var pipelineStates: [String: MTLRenderPipelineState] = [:]

    private init() {
        lock.name = "com.arkavo.VRMMetalKit.PipelineCache"
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
        return try lock.withLock {
            let key = "VRMMetalKitShaders"

            // Return cached library if available
            if let cached = libraries[key] {
                vrmLog("[VRMPipelineCache] ✅ Using cached shader library")
                return cached
            }

            // Load the platform-appropriate metallib slice via the shared loader.
            do {
                let library = try VRMShaderLibraryLoader.loadBundledLibrary(device: device)
                libraries[key] = library
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
        return try lock.withLock {
            // Return cached pipeline state if available
            if let cached = pipelineStates[key] {
                vrmLog("[VRMPipelineCache] ✅ Using cached pipeline state: \(key)")
                return cached
            }

            // Create new pipeline state
            vrmLog("[VRMPipelineCache] 🔨 Creating new pipeline state: \(key)")
            let startTime = CACurrentMediaTime()

            let state = try device.makeRenderPipelineState(descriptor: descriptor)

            let elapsed = (CACurrentMediaTime() - startTime) * 1000
            vrmLog("[VRMPipelineCache] ✅ Pipeline state created in \(String(format: "%.2f", elapsed))ms")

            pipelineStates[key] = state
            return state
        }
    }

    /// Drops every cached shader library and pipeline state.
    ///
    /// The next call to ``getLibrary(device:)`` or ``getPipelineState(device:descriptor:key:)``
    /// will rebuild from scratch. Useful for memory pressure response,
    /// test isolation, and forcing a shader reload during development.
    public func clearCache() {
        lock.withLock {
            let libraryCount = libraries.count
            let pipelineCount = pipelineStates.count

            libraries.removeAll()
            pipelineStates.removeAll()

            vrmLog("[VRMPipelineCache] 🗑️ Cache cleared: \(libraryCount) libraries, \(pipelineCount) pipeline states")
        }
    }

    /// Returns a snapshot of current cache occupancy. Useful for diagnostics dashboards.
    public func getStatistics() -> CacheStatistics {
        return lock.withLock {
            CacheStatistics(
                libraryCount: libraries.count,
                pipelineStateCount: pipelineStates.count
            )
        }
    }

    /// Snapshot of cache occupancy returned by ``getStatistics()``.
    public struct CacheStatistics {
        /// Number of cached `MTLLibrary` instances (currently always 0 or 1 — the bundled metallib).
        public let libraryCount: Int
        /// Number of distinct compiled `MTLRenderPipelineState` instances retained by the cache.
        public let pipelineStateCount: Int
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
