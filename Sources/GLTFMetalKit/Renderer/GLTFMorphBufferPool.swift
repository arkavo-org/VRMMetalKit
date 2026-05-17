//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

import Metal
import simd

/// Triple-buffered `MTLBuffer` pool for per-primitive morphed vertex output.
///
/// Replaces the prior "allocate a fresh `MTLBuffer` every frame" path that
/// PR #241 review flagged as a heap-fragmentation + autorelease-pool hazard
/// at face-blendshape scale (issue #247). Each primitive gets a 3-deep ring
/// of buffers; the CPU writes the next slot while the GPU consumes the
/// prior one. When weights are unchanged from the last call for the same
/// primitive, the previously-written slot is returned without re-blending.
///
/// ## Lifetime
///
/// Allocates lazily on the first call for a primitive. The pool is owned by
/// the `GLTFAsset` and lives as long as the asset; the class semantics keep
/// the ring stable across `GLTFAsset` value copies.
///
/// ## Thread safety
///
/// Designed for single-threaded use from a render loop. The internal state
/// is guarded by `NSLock` so concurrent calls won't corrupt the ring, but
/// callers cannot rely on which slot a parallel call would return.
final class GLTFMorphBufferPool: @unchecked Sendable {

    /// Number of in-flight slots per primitive. Three matches the standard
    /// Metal triple-buffer pattern (frame N writes slot N%3, GPU consumes
    /// slot (N-1)%3 or earlier).
    static let framesInFlight = 3

    private struct Entry {
        let buffers: [MTLBuffer]
        var currentIndex: Int       // -1 == no slot written yet
        var lastWeights: [Float]
    }

    private let device: MTLDevice
    private var entries: [Int: Entry] = [:]
    private let lock = NSLock()

    init(device: MTLDevice) {
        self.device = device
    }

    /// Returns a Metal buffer holding the morphed vertices for the given
    /// primitive at the given weights. On the first call for a primitive,
    /// allocates the 3-deep ring; on subsequent calls with identical
    /// weights, returns the cached buffer without re-blending.
    ///
    /// - Parameters:
    ///   - primitiveID: Stable identifier for the primitive across calls.
    ///     `GLTFAssetLoader` packs this as `(meshIndex << 16) | primitiveIndex`,
    ///     which assumes both fit in 16 bits (65,535 meshes × 65,535 primitives
    ///     per mesh). Realistic glTF assets stay well under that bound; if a
    ///     future caller needs more, switch to `Hasher.combine(...)`.
    ///   - morph: The primitive's morph deltas + base attributes.
    ///   - weights: Per-target weights to blend. Shorter than `targetCount`
    ///     is zero-extended; longer is clipped.
    ///   - joints: Per-vertex `JOINTS_0` (required for skinned variant).
    ///   - skinWeights: Per-vertex `WEIGHTS_0` (required for skinned variant).
    ///   - skinned: When `true`, writes `GLTFSkinnedRenderableVertex` and
    ///     uses ``GLTFPrimitiveMorphData/skinnedMorphedVertices(weights:joints:skinWeights:)``.
    /// - Returns: A buffer the caller can bind as the vertex buffer for a
    ///   draw call, or `nil` if the underlying `MTLBuffer` allocation
    ///   fails on the first call for this primitive.
    func buffer(
        primitiveID: Int,
        morph: GLTFPrimitiveMorphData,
        weights: [Float],
        joints: [SIMD4<UInt16>]?,
        skinWeights: [SIMD4<Float>]?,
        skinned: Bool
    ) -> MTLBuffer? {
        lock.lock()
        defer { lock.unlock() }

        var entry: Entry
        if let existing = entries[primitiveID] {
            // Weights-unchanged guard: same weights as last call → reuse
            // the cached buffer without re-blending or rotating the ring.
            if existing.currentIndex >= 0, existing.lastWeights == weights {
                return existing.buffers[existing.currentIndex]
            }
            entry = existing
        } else {
            let vertexCount = morph.basePositions.count
            let stride = skinned
                ? MemoryLayout<GLTFSkinnedRenderableVertex>.stride
                : MemoryLayout<GLTFRenderableVertex>.stride
            var buffers: [MTLBuffer] = []
            buffers.reserveCapacity(Self.framesInFlight)
            for _ in 0..<Self.framesInFlight {
                guard let b = device.makeBuffer(
                    length: vertexCount * stride,
                    options: .storageModeShared
                ) else {
                    return nil
                }
                buffers.append(b)
            }
            entry = Entry(buffers: buffers, currentIndex: -1, lastWeights: [])
        }

        let nextIndex = (entry.currentIndex + 1) % Self.framesInFlight
        let target = entry.buffers[nextIndex]

        if skinned, let joints = joints, let skinWeights = skinWeights {
            let blended = morph.skinnedMorphedVertices(
                weights: weights, joints: joints, skinWeights: skinWeights
            )
            let byteCount = blended.count * MemoryLayout<GLTFSkinnedRenderableVertex>.stride
            blended.withUnsafeBufferPointer { ptr in
                target.contents().copyMemory(from: ptr.baseAddress!, byteCount: byteCount)
            }
        } else {
            let blended = morph.morphedVertices(weights: weights)
            let byteCount = blended.count * MemoryLayout<GLTFRenderableVertex>.stride
            blended.withUnsafeBufferPointer { ptr in
                target.contents().copyMemory(from: ptr.baseAddress!, byteCount: byteCount)
            }
        }

        entry.currentIndex = nextIndex
        entry.lastWeights = weights
        entries[primitiveID] = entry
        return target
    }

    /// Drop ring storage for any primitive ID **not** in `activeIDs`.
    /// Use this when an asset transitions between large sub-scenes — the
    /// pool grows monotonically as new primitives are seen and never
    /// reclaims storage on its own. For long-lived assets with stable
    /// primitive sets this is a no-op; for assets that swap visible
    /// primitive sets, call after the swap to release dead rings.
    func prune(activeIDs: Set<Int>) {
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { activeIDs.contains($0.key) }
    }

    /// Drop ring storage for every tracked primitive. Equivalent to a
    /// freshly-constructed pool; safe to call between unrelated asset loads
    /// that share the same pool instance.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: false)
    }

    /// Number of primitives currently tracked. Test-only accessor.
    var trackedPrimitiveCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    /// Number of buffers allocated for the given primitive, or `0` if the
    /// primitive hasn't been seen yet. Test-only accessor.
    func bufferCount(forPrimitiveID id: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        return entries[id]?.buffers.count ?? 0
    }
}
