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
import simd

/// Sprite cache system for optimizing multi-character 2.5D rendering
/// Caches pre-rendered character poses as textures to achieve 60 FPS with 5+ characters
public class SpriteCacheSystem {

    // MARK: - Cache Entry

    /// A cached sprite representing a specific character pose
    public struct CachedPose {
        /// Rendered sprite texture (RGBA8 or BGRA8)
        public let texture: MTLTexture

        /// Deterministic hash of the pose state
        public let poseHash: UInt64

        /// Timestamp for LRU eviction
        public var timestamp: TimeInterval

        /// Texture resolution
        public let resolution: CGSize

        /// Character identifier (for multi-character scenes)
        public let characterID: String

        /// Memory footprint in bytes
        public var memoryBytes: Int {
            let bytesPerPixel = 4  // RGBA8
            return Int(resolution.width * resolution.height) * bytesPerPixel
        }

        public init(
            texture: MTLTexture,
            poseHash: UInt64,
            timestamp: TimeInterval,
            resolution: CGSize,
            characterID: String
        ) {
            self.texture = texture
            self.poseHash = poseHash
            self.timestamp = timestamp
            self.resolution = resolution
            self.characterID = characterID
        }
    }

    // MARK: - Configuration

    /// Maximum number of cached poses
    public var maxCacheSize: Int = 100

    /// Maximum memory usage in bytes (default: 256MB)
    public var maxMemoryBytes: Int = 256 * 1024 * 1024

    /// Default sprite resolution
    public var defaultResolution: CGSize = CGSize(width: 512, height: 512)

    /// Quantization precision for pose hashing
    public var expressionQuantization: Float = 0.01  // 1% precision
    public var rotationQuantization: Float = 5.0     // 5° buckets

    // MARK: - Cache State

    private var cache: [UInt64: CachedPose] = [:]
    private var pendingRenders: Set<UInt64> = []
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let callbackQueue: DispatchQueue
    private let cacheLock = NSLock()

    // Statistics
    private var cacheHits: Int = 0
    private var cacheMisses: Int = 0

    // MARK: - Initialization

    public init(device: MTLDevice, commandQueue: MTLCommandQueue, callbackQueue: DispatchQueue = .main) {
        self.device = device
        self.commandQueue = commandQueue
        self.callbackQueue = callbackQueue
    }

    private struct PendingPose {
        let texture: MTLTexture
        let poseHash: UInt64
        let characterID: String
        let resolution: CGSize
    }

    private func locked<T>(_ body: () -> T) -> T {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return body()
    }

    private func cancelPendingRender(for poseHash: UInt64) {
        locked {
            pendingRenders.remove(poseHash)
        }
    }

    // MARK: - Pose Hashing

    /// Compute deterministic hash for a character pose
    /// - Parameters:
    ///   - characterID: Unique character identifier
    ///   - expressionWeights: VRM expression weights (quantized)
    ///   - animationFrame: Animation frame index (for looping animations)
    ///   - headRotation: Head rotation in radians (quantized to buckets)
    ///   - bodyRotation: Body rotation in radians (quantized to buckets)
    /// - Returns: 64-bit hash uniquely identifying this pose
    public func computePoseHash(
        characterID: String,
        expressionWeights: [String: Float],
        animationFrame: Int? = nil,
        headRotation: SIMD3<Float>? = nil,
        bodyRotation: SIMD3<Float>? = nil
    ) -> UInt64 {
        var hasher = Hasher()

        // Character ID
        hasher.combine(characterID)

        // Expression weights (sorted for determinism)
        for (name, weight) in expressionWeights.sorted(by: { $0.key < $1.key }) {
            hasher.combine(name)
            // Quantize to expressionQuantization (default 0.01)
            let quantized = Int(weight / expressionQuantization)
            hasher.combine(quantized)
        }

        // Animation frame
        if let frame = animationFrame {
            hasher.combine(frame)
        }

        // Head rotation (quantized to rotationQuantization buckets)
        if let rotation = headRotation {
            let qx = Int(rotation.x * 180 / .pi / rotationQuantization)
            let qy = Int(rotation.y * 180 / .pi / rotationQuantization)
            let qz = Int(rotation.z * 180 / .pi / rotationQuantization)
            hasher.combine(qx)
            hasher.combine(qy)
            hasher.combine(qz)
        }

        // Body rotation
        if let rotation = bodyRotation {
            let qx = Int(rotation.x * 180 / .pi / rotationQuantization)
            let qy = Int(rotation.y * 180 / .pi / rotationQuantization)
            let qz = Int(rotation.z * 180 / .pi / rotationQuantization)
            hasher.combine(qx)
            hasher.combine(qy)
            hasher.combine(qz)
        }

        return UInt64(hasher.finalize())
    }

    // MARK: - Cache Lookup

    /// Check if a pose is cached
    public func isCached(poseHash: UInt64) -> Bool {
        return locked {
            cache[poseHash] != nil
        }
    }

    /// Retrieve cached pose if available
    /// - Parameter poseHash: Pose hash to lookup
    /// - Returns: Cached pose texture or nil if not found
    public func getCachedPose(poseHash: UInt64) -> CachedPose? {
        return locked {
            if var pose = cache[poseHash] {
                pose.timestamp = Date().timeIntervalSince1970
                cache[poseHash] = pose
                cacheHits += 1
                return pose
            } else {
                cacheMisses += 1
                return nil
            }
        }
    }

    // MARK: - Cache Storage

    @discardableResult
    private func storePoseLocked(_ pose: CachedPose) -> Bool {
        while shouldEvictLocked(additionalBytes: pose.memoryBytes) {
            evictLRULocked()
        }
        cache[pose.poseHash] = pose
        pendingRenders.remove(pose.poseHash)
        return true
    }

    private func finalizePendingPose(_ pending: PendingPose) -> CachedPose? {
        let pose = CachedPose(
            texture: pending.texture,
            poseHash: pending.poseHash,
            timestamp: Date().timeIntervalSince1970,
            resolution: pending.resolution,
            characterID: pending.characterID
        )

        return locked {
            _ = storePoseLocked(pose)
            return cache[pose.poseHash]
        }
    }

    /// Add a rendered pose to the cache
    /// - Parameters:
    ///   - texture: Pre-rendered sprite texture
    ///   - poseHash: Hash identifying this pose
    ///   - characterID: Character identifier
    /// - Returns: True if successfully cached
    @discardableResult
    public func cachePose(
        texture: MTLTexture,
        poseHash: UInt64,
        characterID: String
    ) -> Bool {
        let resolution = CGSize(
            width: texture.width,
            height: texture.height
        )

        let pose = CachedPose(
            texture: texture,
            poseHash: poseHash,
            timestamp: Date().timeIntervalSince1970,
            resolution: resolution,
            characterID: characterID
        )

        return locked {
            storePoseLocked(pose)
        }
    }

    // MARK: - Rendering to Cache

    /// Render a character pose directly to a cached texture
    /// - Parameters:
    ///   - characterID: Character identifier
    ///   - poseHash: Pose hash for cache key
    ///   - resolution: Texture resolution (nil = use default)
    ///   - renderBlock: Closure that performs the actual rendering
    /// - Returns: Cached pose or nil on failure
    @discardableResult
    public func renderToCache(
        characterID: String,
        poseHash: UInt64,
        resolution: CGSize? = nil,
        commandBuffer externalCommandBuffer: MTLCommandBuffer? = nil,
        waitUntilCompleted: Bool = false,
        completion: ((CachedPose?) -> Void)? = nil,
        renderBlock: (MTLRenderCommandEncoder, MTLTexture) -> Void
    ) -> CachedPose? {
        let targetResolution = resolution ?? defaultResolution

        var insertedPending = false
        let alreadyPending = locked {
            if pendingRenders.contains(poseHash) {
                return true
            }
            pendingRenders.insert(poseHash)
            insertedPending = true
            return false
        }

        if alreadyPending {
            return nil
        }

        // Create texture descriptor for sprite
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(targetResolution.width),
            height: Int(targetResolution.height),
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            vrmLog("[SpriteCacheSystem] Failed to create texture")
            if insertedPending {
                cancelPendingRender(for: poseHash)
            }
            return nil
        }

        // Create render pass descriptor
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        // Optional depth buffer for 3D rendering
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: Int(targetResolution.width),
            height: Int(targetResolution.height),
            mipmapped: false
        )
        depthDescriptor.usage = .renderTarget
        depthDescriptor.storageMode = .private

        guard let depthTexture = device.makeTexture(descriptor: depthDescriptor) else {
            vrmLog("[SpriteCacheSystem] Failed to create depth texture")
            if insertedPending {
                cancelPendingRender(for: poseHash)
            }
            return nil
        }

        renderPassDescriptor.depthAttachment.texture = depthTexture
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.clearDepth = 1.0
        renderPassDescriptor.depthAttachment.storeAction = .dontCare

        guard let commandBuffer = externalCommandBuffer ?? commandQueue.makeCommandBuffer() else {
            vrmLog("[SpriteCacheSystem] Failed to create command buffer")
            if insertedPending {
                cancelPendingRender(for: poseHash)
            }
            return nil
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            vrmLog("[SpriteCacheSystem] Failed to create render encoder")
            if insertedPending {
                cancelPendingRender(for: poseHash)
            }
            return nil
        }

        encoder.label = "Sprite Cache Render"

        // Execute user's rendering
        renderBlock(encoder, texture)

        encoder.endEncoding()

        let pending = PendingPose(texture: texture, poseHash: poseHash, characterID: characterID, resolution: targetResolution)
        let shouldSynchronize = waitUntilCompleted && externalCommandBuffer == nil

        if waitUntilCompleted && externalCommandBuffer != nil {
            vrmLog("[SpriteCacheSystem] waitUntilCompleted ignored when external command buffer is supplied.")
        }

        if shouldSynchronize {
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            let cached = finalizePendingPose(pending)
            completion?(cached)
            return cached
        } else {
            commandBuffer.addCompletedHandler { [weak self] _ in
                guard let self = self else { return }
                let cached = self.finalizePendingPose(pending)
                if let completion = completion {
                    self.callbackQueue.async {
                        completion(cached)
                    }
                }
            }
            if externalCommandBuffer == nil {
                commandBuffer.commit()
            }
            return nil
        }
    }

    /// Get cached pose or render and cache if missing
    /// - Parameters:
    ///   - characterID: Character identifier
    ///   - poseHash: Pose hash
    ///   - resolution: Target resolution
    ///   - commandBuffer: Optional command buffer to encode into (nil = system creates one)
    ///   - waitForCompletion: If true and the system creates the command buffer, block until the sprite is ready
    ///   - completion: Invoked when the sprite finishes rendering (async path)
    ///   - renderBlock: Rendering closure (called only on cache miss)
    /// - Returns: Cached pose (existing or newly rendered)
    public func getOrRender(
        characterID: String,
        poseHash: UInt64,
        resolution: CGSize? = nil,
        commandBuffer: MTLCommandBuffer? = nil,
        waitForCompletion: Bool = false,
        completion: ((CachedPose?) -> Void)? = nil,
        renderBlock: (MTLRenderCommandEncoder, MTLTexture) -> Void
    ) -> CachedPose? {
        // Check cache first
        if let cached = getCachedPose(poseHash: poseHash) {
            return cached
        }

        // Cache miss - render and cache
        return renderToCache(
            characterID: characterID,
            poseHash: poseHash,
            resolution: resolution,
            commandBuffer: commandBuffer,
            waitUntilCompleted: waitForCompletion,
            completion: completion,
            renderBlock: renderBlock
        )
    }

    // MARK: - Cache Management

    /// Check if we should evict entries to make room
    private func shouldEvictLocked(additionalBytes: Int) -> Bool {
        let currentMemory = cache.values.reduce(0) { $0 + $1.memoryBytes }

        // Evict if over memory limit or cache size limit
        return (currentMemory + additionalBytes > maxMemoryBytes) || (cache.count >= maxCacheSize)
    }

    /// Evict least recently used entry
    private func evictLRULocked() {
        guard let lruEntry = cache.values.min(by: { $0.timestamp < $1.timestamp }) else {
            return
        }

        cache.removeValue(forKey: lruEntry.poseHash)
        vrmLog("[SpriteCacheSystem] Evicted LRU entry (hash: \(lruEntry.poseHash), age: \(Date().timeIntervalSince1970 - lruEntry.timestamp)s)")
    }

    /// Clear entire cache
    public func clearCache() {
        locked {
            cache.removeAll()
            pendingRenders.removeAll()
            cacheHits = 0
            cacheMisses = 0
        }
        vrmLog("[SpriteCacheSystem] Cache cleared")
    }

    /// Clear cache entries for a specific character
    public func clearCharacter(_ characterID: String) {
        let removedCount = locked {
            let removed = cache.filter { $0.value.characterID == characterID }
            for (hash, _) in removed {
                cache.removeValue(forKey: hash)
                pendingRenders.remove(hash)
            }
            return removed.count
        }
        vrmLog("[SpriteCacheSystem] Cleared \(removedCount) entries for character '\(characterID)'")
    }

    // MARK: - Statistics

    /// Get cache statistics
    public func getStatistics() -> CacheStatistics {
        return locked {
            let totalMemory = cache.values.reduce(0) { $0 + $1.memoryBytes }
            let hitRate = cacheHits + cacheMisses > 0
                ? Float(cacheHits) / Float(cacheHits + cacheMisses)
                : 0.0

            return CacheStatistics(
                entryCount: cache.count,
                totalMemoryBytes: totalMemory,
                maxMemoryBytes: maxMemoryBytes,
                cacheHits: cacheHits,
                cacheMisses: cacheMisses,
                hitRate: hitRate,
                pendingRenders: pendingRenders.count
            )
        }
    }

    /// Reset statistics counters
    public func resetStatistics() {
        locked {
            cacheHits = 0
            cacheMisses = 0
        }
    }

    /// Cache statistics snapshot
    public struct CacheStatistics {
        public let entryCount: Int
        public let totalMemoryBytes: Int
        public let maxMemoryBytes: Int
        public let cacheHits: Int
        public let cacheMisses: Int
        public let hitRate: Float
        public let pendingRenders: Int

        public var memoryUsagePercent: Float {
            return Float(totalMemoryBytes) / Float(maxMemoryBytes) * 100
        }

        public var description: String {
            let mb = Float(totalMemoryBytes) / (1024 * 1024)
            let maxMb = Float(maxMemoryBytes) / (1024 * 1024)
            return """
            Sprite Cache Statistics:
              Entries: \(entryCount)
              Memory: \(String(format: "%.1f", mb)) MB / \(String(format: "%.1f", maxMb)) MB (\(String(format: "%.1f", memoryUsagePercent))%)
              Hit Rate: \(String(format: "%.1f", hitRate * 100))%
              Hits: \(cacheHits), Misses: \(cacheMisses)
            """
        }
    }
}

// MARK: - Sprite Rendering Helper

extension SpriteCacheSystem {

    /// Render a sprite quad to the screen
    /// - Parameters:
    ///   - encoder: Render command encoder
    ///   - texture: Sprite texture
    ///   - position: Screen position (center)
    ///   - scale: Sprite scale
    ///   - pipelineState: Pipeline state for sprite rendering
    public func renderSprite(
        encoder: MTLRenderCommandEncoder,
        texture: MTLTexture,
        position: SIMD2<Float>,
        scale: Float,
        pipelineState: MTLRenderPipelineState
    ) {
        // Note: This is a simplified API
        // In production, you'd use a sprite batch renderer with instancing

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)

        // TODO: Bind sprite quad vertex buffer and uniforms
        // This requires a sprite shader and quad mesh

        vrmLog("[SpriteCacheSystem] Sprite rendering stub called - implement sprite shader")
    }
}
