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

/// Global pipeline state cache to avoid recompiling shaders and recreating pipeline states
/// Shared across all VRMRenderer instances for optimal performance
///
/// ## Thread Safety (@unchecked Sendable)
///
/// This class is marked `@unchecked Sendable` because:
/// 1. **Metal types are not Sendable**: `MTLDevice`, `MTLLibrary`, and `MTLRenderPipelineState`
///    do not conform to `Sendable`, but Metal's thread-safety guarantees allow concurrent access:
///    - Libraries are immutable after creation
///    - Pipeline states are immutable after creation
///    - Device is thread-safe for resource creation
///
/// 2. **NSLock protection**: All mutable state (`libraries`, `pipelineStates`) is protected
///    by `lock` using the `withLock { }` helper for scoped access.
///
/// 3. **Immutable after creation**: Once a library or pipeline state is created and cached,
///    it is never modified, only read by multiple threads.
///
/// **Safety contract**: Callers may invoke methods from any thread. Internal synchronization
/// ensures correctness. All Metal objects are created once and reused safely.
public final class VRMPipelineCache: @unchecked Sendable {
    /// Shared singleton instance
    public static let shared = VRMPipelineCache()
    
    private let lock = NSLock()
    private var libraries: [String: MTLLibrary] = [:]
    private var pipelineStates: [String: MTLRenderPipelineState] = [:]
    
    private init() {
        lock.name = "com.arkavo.VRMMetalKit.PipelineCache"
    }
    
    /// Load or retrieve cached shader library
    ///
    /// This method attempts to load shaders in the following order:
    /// 1. Return cached library if already loaded
    /// 2. Try loading from default library (for development with Xcode)
    /// 3. Load from packaged VRMMetalKitShaders.metallib
    ///
    /// - Parameter device: Metal device to create library with
    /// - Returns: Cached or newly loaded MTLLibrary
    /// - Throws: VRMError if library cannot be loaded
    public func getLibrary(device: MTLDevice) throws -> MTLLibrary {
        return try lock.withLock {
            let key = "VRMMetalKitShaders"
            
            // Return cached library if available
            if let cached = libraries[key] {
                vrmLog("[VRMPipelineCache] ✅ Using cached shader library")
                return cached
            }
            
            // Try loading from default library first (for development with Xcode)
            // This allows shader debugging and hot-reloading during development
            if let defaultLib = device.makeDefaultLibrary() {
                // Check if it has VRM shaders
                if defaultLib.makeFunction(name: "mtoon_vertex") != nil {
                    vrmLog("[VRMPipelineCache] ✅ Loaded from default library (development mode) - has VRM shaders")
                    libraries[key] = defaultLib
                    return defaultLib
                } else {
                    vrmLog("[VRMPipelineCache] ⚠️ Default library exists but missing VRM shaders, trying package bundle...")
                }
            }
            
            // Load from packaged metallib (production)
            guard let url = Bundle.module.url(forResource: "VRMMetalKitShaders",
                                             withExtension: "metallib") else {
                vrmLog("[VRMPipelineCache] ❌ VRMMetalKitShaders.metallib not found in package resources")
                throw PipelineCacheError.shaderLibraryNotFound
            }
            
            do {
                let library = try device.makeLibrary(URL: url)
                vrmLog("[VRMPipelineCache] ✅ Loaded from VRMMetalKitShaders.metallib")
                libraries[key] = library
                return library
            } catch {
                vrmLog("[VRMPipelineCache] ❌ Failed to load metallib: \(error)")
                throw PipelineCacheError.shaderLibraryLoadFailed(error)
            }
        }
    }
    
    /// Get or create cached pipeline state
    ///
    /// Pipeline states are expensive to create, so we cache them by a unique key.
    /// The key should include all relevant pipeline configuration (shader functions,
    /// pixel format, alpha mode, etc.)
    ///
    /// - Parameters:
    ///   - device: Metal device to create pipeline state with
    ///   - descriptor: Pipeline descriptor defining the pipeline configuration
    ///   - key: Unique key identifying this pipeline configuration
    /// - Returns: Cached or newly created MTLRenderPipelineState
    /// - Throws: Error if pipeline state creation fails
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
    
    /// Clear all cached libraries and pipeline states
    ///
    /// This is useful for:
    /// - Testing (reset state between tests)
    /// - Memory pressure (free cached resources)
    /// - Development (force reload of shaders)
    public func clearCache() {
        lock.withLock {
            let libraryCount = libraries.count
            let pipelineCount = pipelineStates.count
            
            libraries.removeAll()
            pipelineStates.removeAll()
            
            vrmLog("[VRMPipelineCache] 🗑️ Cache cleared: \(libraryCount) libraries, \(pipelineCount) pipeline states")
        }
    }
    
    /// Get cache statistics for monitoring
    public func getStatistics() -> CacheStatistics {
        return lock.withLock {
            CacheStatistics(
                libraryCount: libraries.count,
                pipelineStateCount: pipelineStates.count
            )
        }
    }
    
    /// Cache statistics snapshot
    public struct CacheStatistics {
        public let libraryCount: Int
        public let pipelineStateCount: Int
    }
}

// MARK: - Error Types

public enum PipelineCacheError: Error, LocalizedError {
    case shaderLibraryNotFound
    case shaderLibraryLoadFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .shaderLibraryNotFound:
            return "VRMMetalKitShaders.metallib not found in package resources"
        case .shaderLibraryLoadFailed(let error):
            return "Failed to load VRMMetalKitShaders.metallib: \(error.localizedDescription)"
        }
    }
}
