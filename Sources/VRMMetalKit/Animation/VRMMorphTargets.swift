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


@preconcurrency import Foundation
import Metal
import simd
import QuartzCore

// MARK: - Morph Target Errors

/// Errors raised by ``VRMMorphTargetSystem`` during initialisation or dispatch.
public enum VRMMorphTargetError: Error, LocalizedError {
    /// `MTLDevice.makeCommandQueue()` returned `nil` during system construction. Indicates a device-level allocation failure.
    case failedToCreateCommandQueue
    /// `MTLDevice.makeComputePipelineState(function:)` failed; the associated string carries the underlying reason.
    case failedToCreateComputePipeline(String)
    /// The Metal library is missing the named shader function (typically `"morph_accumulate_positions"`). The string carries the missing name and a remediation hint.
    case missingShaderFunction(String)
    /// Reserved for a future code path that will throw on dispatch with an uninitialised active-set buffer; not currently raised by any API.
    case activeSetBufferNotInitialized

    /// Human-readable, LLM-friendly description suitable for logging.
    public var errorDescription: String? {
        switch self {
        case .failedToCreateCommandQueue:
            return "❌ [VRMMorphTargetSystem] Failed to create Metal command queue"
        case .failedToCreateComputePipeline(let reason):
            return "❌ [VRMMorphTargetSystem] Failed to create morph compute pipeline: \(reason)"
        case .missingShaderFunction(let name):
            return "❌ [VRMMorphTargetSystem] Failed to find shader function '\(name)'"
        case .activeSetBufferNotInitialized:
            return "❌ [VRMMorphTargetSystem] Active set buffer not initialized"
        }
    }
}

// MARK: - Morph Target System

/// One entry in the active-morph set: `(index, weight)` pair the compute shader reads to accumulate per-vertex deltas.
public struct ActiveMorph {
    /// Index of the morph target within the primitive's deltas.
    public var index: UInt32
    /// Signed weight applied to this morph (negative values run the delta in reverse).
    public var weight: Float

    /// Creates an active-morph entry.
    public init(index: UInt32, weight: Float) {
        self.index = index
        self.weight = weight
    }
}

/// GPU compute system that accumulates morph-target deltas into per-primitive position (and normal) buffers.
///
/// ## Discussion
/// `VRMMorphTargetSystem` is the morph-side counterpart to
/// ``VRMSkinningSystem``. It manages three buffer families:
/// 1. A flat weights buffer of size ``VRMConstants/Rendering/maxMorphTargets``,
///    written by ``updateMorphWeights(_:)`` for legacy single-pass paths.
/// 2. An "active set" buffer of at most ``maxActiveMorphs`` (8) entries,
///    rebuilt each frame by ``buildActiveSet(weights:)``: weights with
///    absolute value above ``morphEpsilon`` are sorted by `|weight|`
///    descending and the top entries kept.
/// 3. Per-primitive private-storage output buffers, allocated lazily by
///    ``getOrCreateMorphedPositionBuffer(primitiveID:vertexCount:)`` and
///    ``getOrCreateMorphedNormalBuffer(primitiveID:vertexCount:)``.
///
/// ### Active set and dispatch policy
/// Every dispatch reads the active set: when the set is empty,
/// ``applyMorphsCompute(basePositions:deltaPositions:outputPositions:vertexCount:morphCount:commandBuffer:)``
/// blit-copies base positions into the output (so the output is always
/// well-defined). When the set is non-empty, the
/// `morph_accumulate_positions` kernel reads the SoA delta buffer and
/// accumulates `weight_i * delta_i` for each active morph. The active-set
/// cap of ``maxActiveMorphs`` (8) keeps shader register pressure bounded
/// — additional active morphs beyond the cap are silently dropped after
/// sorting by absolute weight.
///
/// ### Threading
/// All public methods are intended to be called on the same thread that
/// owns the encoded command buffer. The system is not internally
/// synchronised.
public final class VRMMorphTargetSystem {
    private let device: MTLDevice
    private var morphWeightsBuffer: MTLBuffer?
    private let maxMorphTargets = VRMConstants.Rendering.maxMorphTargets

    /// Maximum number of morphs the compute kernel will accumulate in a single dispatch (sourced from ``VRMConstants/Rendering/maxActiveMorphs``).
    public static let maxActiveMorphs = VRMConstants.Rendering.maxActiveMorphs
    /// Weights with absolute value below this threshold are filtered out by ``buildActiveSet(weights:)``.
    public static let morphEpsilon = VRMConstants.Physics.morphEpsilon
    private var activeSet: [ActiveMorph] = []
    private var activeSetBuffer: MTLBuffer?
    private var lastActiveSetWeights: [Float]?

    // Morphed output buffers (per primitive, keyed by ObjectIdentifier)
    private var morphedPositionBuffers: [ObjectIdentifier: MTLBuffer] = [:]
    private var morphedNormalBuffers: [ObjectIdentifier: MTLBuffer] = [:]

    internal var cachedPositionBufferCount: Int { morphedPositionBuffers.count }
    internal var cachedNormalBufferCount: Int { morphedNormalBuffers.count }

    /// The precompiled `morph_accumulate_positions` compute pipeline state used by ``applyMorphsCompute(basePositions:deltaPositions:outputPositions:vertexCount:morphCount:commandBuffer:)``.
    public var morphAccumulatePipelineState: MTLComputePipelineState?
    private let commandQueue: MTLCommandQueue

    /// Builds the morph system and compiles its compute pipeline.
    ///
    /// Looks up `VRMMetalKitShaders.metallib` in `Bundle.module` first,
    /// falling back to the device's default library.
    ///
    /// - Throws: ``VRMMorphTargetError/failedToCreateCommandQueue`` when
    ///   `device.makeCommandQueue()` returns `nil`;
    ///   ``VRMMorphTargetError/failedToCreateComputePipeline(_:)`` when no
    ///   Metal library is available or pipeline creation fails;
    ///   ``VRMMorphTargetError/missingShaderFunction(_:)`` when the
    ///   `morph_accumulate_positions` kernel is missing from the library.
    public init(device: MTLDevice) throws {
        self.device = device
        let queue = MetalQueueFactory.makeCommandQueue(device: device)
        guard let queue else {
            throw VRMMorphTargetError.failedToCreateCommandQueue
        }
        self.commandQueue = queue
        setupBuffers()
        try setupComputePipeline()
    }

    private func setupBuffers() {
        // Pre-allocate buffer for morph weights
        let bufferSize = MemoryLayout<Float>.stride * maxMorphTargets
        morphWeightsBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)
        morphWeightsBuffer?.label = "Morph Weights"

        // Pre-allocate active set buffer
        let activeSetSize = MemoryLayout<ActiveMorph>.stride * VRMMorphTargetSystem.maxActiveMorphs
        activeSetBuffer = device.makeBuffer(length: activeSetSize, options: .storageModeShared)
        activeSetBuffer?.label = "Morph ActiveSet"
    }

    private func setupComputePipeline() throws {
        // Try to load compute pipeline from compiled Metal library.
        // First try the platform-appropriate metallib slice via the shared
        // loader, then fall back to the device's default library.
        var library: MTLLibrary?

        do {
            library = try VRMShaderLibraryLoader.loadBundledLibrary(device: device)
            vrmLog("[VRMMorphTargetSystem] Using package Metal library (\(VRMShaderLibraryLoader.bundledLibraryName))")
        } catch {
            // Log the loader's actionable message before falling back, so the
            // slice-name + `make shaders` hint isn't lost when the default
            // library happens to satisfy the lookup.
            vrmLog("[VRMMorphTargetSystem] Bundled library load failed: \(error.localizedDescription)")
            if let defaultLib = device.makeDefaultLibrary() {
                library = defaultLib
                vrmLog("[VRMMorphTargetSystem] Using default Metal library")
            }
        }

        // Fail fast if no library available
        guard let validLibrary = library else {
            throw VRMMorphTargetError.failedToCreateComputePipeline(
                "No Metal shader library available. " +
                "Ensure VRMMetalKitShaders metallib slices are bundled (run `make shaders`)."
            )
        }

        guard let function = validLibrary.makeFunction(name: "morph_accumulate_positions") else {
            throw VRMMorphTargetError.missingShaderFunction(
                "morph_accumulate_positions not found in shader library. " +
                "Ensure shaders are compiled and bundled correctly."
            )
        }
        
        // Create pipeline from precompiled library (single code path, no JIT fallback)
        do {
            #if DEBUG
            let pipelineDesc = MTLComputePipelineDescriptor()
            pipelineDesc.computeFunction = function
            pipelineDesc.shaderValidation = .enabled
            morphAccumulatePipelineState = try device.makeComputePipelineState(descriptor: pipelineDesc, options: [], reflection: nil)
            #else
            morphAccumulatePipelineState = try device.makeComputePipelineState(function: function)
            #endif
            vrmLog("[VRMMorphTargetSystem] Morph accumulate compute pipeline created from precompiled library")
        } catch {
            throw VRMMorphTargetError.failedToCreateComputePipeline(error.localizedDescription)
        }
    }

    /// Copies up to ``VRMConstants/Rendering/maxMorphTargets`` values from `weights` into the dense weights buffer.
    ///
    /// Used by legacy single-pass shader paths; the compute path in
    /// ``applyMorphsCompute(basePositions:deltaPositions:outputPositions:vertexCount:morphCount:commandBuffer:)``
    /// reads ``getActiveSetBuffer()`` instead.
    public func updateMorphWeights(_ weights: [Float]) {
        guard let buffer = morphWeightsBuffer else { return }

        let count = min(weights.count, maxMorphTargets)
        let pointer = buffer.contents().bindMemory(to: Float.self, capacity: count)
        for i in 0..<count {
            pointer[i] = weights[i]
        }
    }

    /// Returns the dense weights buffer, or `nil` before allocation. Indexed by morph index.
    public func getMorphWeightsBuffer() -> MTLBuffer? {
        return morphWeightsBuffer
    }

    // MARK: - Active Set Management

    /// Filters `weights` against ``morphEpsilon``, sorts the survivors by `|weight|` descending, and keeps up to ``maxActiveMorphs``.
    ///
    /// Updates the GPU active-set buffer and the cached ``getActiveSet()``
    /// in place; returns the resulting array for callers that want to
    /// inspect it.
    public func buildActiveSet(weights: [Float]) -> [ActiveMorph] {
        return buildActiveSetImpl(weights)
    }

    internal func buildActiveSet(weights: ArraySlice<Float>) -> [ActiveMorph] {
        return buildActiveSetImpl(weights)
    }

    private func buildActiveSetImpl<C: Collection>(_ weights: C) -> [ActiveMorph] where C.Element == Float {
        let epsilon = VRMMorphTargetSystem.morphEpsilon

        // Fast path when the weights are empty or all effectively zero.
        var anyActive = false
        for w in weights {
            if abs(w) > epsilon {
                anyActive = true
                break
            }
        }
        if !anyActive {
            activeSet.removeAll(keepingCapacity: true)
            lastActiveSetWeights?.removeAll(keepingCapacity: true)
            if lastActiveSetWeights == nil {
                lastActiveSetWeights = []
            }
            return activeSet
        }

        // Reuse the previously-built active set if the weights haven't changed.
        if let last = lastActiveSetWeights, last.count == weights.count {
            var changed = false
            var i = 0
            for w in weights {
                if abs(last[i] - w) > epsilon {
                    changed = true
                    break
                }
                i += 1
            }
            if !changed {
                return activeSet
            }
        }

        // Maintain top-K (K = maxActiveMorphs = 8) directly in `activeSet`,
        // sorted descending by |weight| with stable lower-index tie-breaking.
        // Avoids copying `weights` into a temporary Array and avoids O(m log m)
        // sorting of all active morphs when K is small.
        let maxActive = VRMMorphTargetSystem.maxActiveMorphs
        activeSet.removeAll(keepingCapacity: true)
        if activeSet.capacity < maxActive {
            activeSet.reserveCapacity(maxActive)
        }
        var minAbsInTop: Float = 0

        var idx: UInt32 = 0
        for weight in weights {
            let aw = abs(weight)
            if aw > epsilon {
                if activeSet.count < maxActive || aw > minAbsInTop {
                    let entry = ActiveMorph(index: idx, weight: weight)
                    var insertAt = activeSet.count
                    while insertAt > 0 && aw > abs(activeSet[insertAt - 1].weight) {
                        insertAt -= 1
                    }
                    if activeSet.count < maxActive {
                        activeSet.insert(entry, at: insertAt)
                    } else if insertAt < maxActive {
                        activeSet.removeLast()
                        activeSet.insert(entry, at: insertAt)
                    }
                    if activeSet.count == maxActive {
                        minAbsInTop = abs(activeSet[maxActive - 1].weight)
                    }
                }
            }
            idx &+= 1
        }

        // Update active set buffer
        if let buffer = activeSetBuffer, !activeSet.isEmpty {
            let pointer = buffer.contents().bindMemory(to: ActiveMorph.self, capacity: activeSet.count)
            for i in 0..<activeSet.count {
                pointer[i] = activeSet[i]
            }
        }

        // Update cached weights in place (reusing capacity without heap churn)
        if lastActiveSetWeights == nil {
            lastActiveSetWeights = Array(weights)
        } else {
            lastActiveSetWeights!.removeAll(keepingCapacity: true)
            lastActiveSetWeights!.append(contentsOf: weights)
        }
        return activeSet
    }

    /// Returns the cached active-morph set from the most recent ``buildActiveSet(weights:)`` call.
    public func getActiveSet() -> [ActiveMorph] {
        return activeSet
    }

    /// Returns the GPU active-set buffer, or `nil` before allocation.
    public func getActiveSetBuffer() -> MTLBuffer? {
        return activeSetBuffer
    }

    /// Returns the number of entries currently in the active set.
    public func getActiveCount() -> Int {
        return activeSet.count
    }

    /// Returns `true` when the active set is non-empty (used by the renderer to decide whether to dispatch the morph compute pass).
    public func hasMorphsToApply() -> Bool {
        return !activeSet.isEmpty
    }

    /// Returns (allocating on first request or growing if undersized) a private-storage `MTLBuffer`
    /// sized to hold `vertexCount` `SIMD3<Float>` positions for `primitive`.
    public func getOrCreateMorphedPositionBuffer(for primitive: VRMPrimitive, vertexCount: Int) -> MTLBuffer? {
        let key = ObjectIdentifier(primitive)
        let requiredSize = vertexCount * MemoryLayout<SIMD3<Float>>.stride
        guard requiredSize > 0 else { return nil }
        if let buffer = morphedPositionBuffers[key], buffer.length >= requiredSize {
            return buffer
        }

        let buffer = device.makeBuffer(length: requiredSize, options: .storageModePrivate)
        buffer?.label = "Morph Output Positions (\(key))"
        morphedPositionBuffers[key] = buffer
        return buffer
    }

    /// Returns (allocating on first request or growing if undersized) a private-storage `MTLBuffer`
    /// sized to hold `vertexCount` `SIMD3<Float>` normals for `primitive`.
    public func getOrCreateMorphedNormalBuffer(for primitive: VRMPrimitive, vertexCount: Int) -> MTLBuffer? {
        let key = ObjectIdentifier(primitive)
        let requiredSize = vertexCount * MemoryLayout<SIMD3<Float>>.stride
        guard requiredSize > 0 else { return nil }
        if let buffer = morphedNormalBuffers[key], buffer.length >= requiredSize {
            return buffer
        }

        let buffer = device.makeBuffer(length: requiredSize, options: .storageModePrivate)
        buffer?.label = "Morph Output Normals (\(key))"
        morphedNormalBuffers[key] = buffer
        return buffer
    }

    /// Evicts any cached morphed position and normal output buffers for `primitive`.
    public func evictPrimitive(_ primitive: VRMPrimitive) {
        let key = ObjectIdentifier(primitive)
        morphedPositionBuffers.removeValue(forKey: key)
        morphedNormalBuffers.removeValue(forKey: key)
    }

    /// Drops cached morphed output buffers for primitives not in `livePrimitives`.
    public func prune(keeping livePrimitives: Set<ObjectIdentifier>) {
        morphedPositionBuffers = morphedPositionBuffers.filter { livePrimitives.contains($0.key) }
        morphedNormalBuffers = morphedNormalBuffers.filter { livePrimitives.contains($0.key) }
    }

    // MARK: - SoA Morph Accumulation with Active Set

    /// Encodes the morph-accumulation compute dispatch for one primitive into an
    /// existing `MTLComputeCommandEncoder`.
    ///
    /// Use this overload when batching multiple primitives into a single compute
    /// pass. The caller is responsible for creating/ending the encoder and for
    /// skipping primitives whose active set is empty (the renderer binds the base
    /// vertex buffer in that case).
    ///
    /// - Parameters:
    ///   - encoder: The compute encoder to receive the dispatch.
    ///   - basePositions: Per-vertex base positions (read).
    ///   - deltaPositions: SoA delta buffer
    ///     `[morph0[v0..vN], morph1[v0..vN], …]` sized at least
    ///     `morphCount * vertexCount * sizeof(SIMD3<Float>)`.
    ///   - outputPositions: Per-vertex output buffer (write).
    ///   - vertexCount: Number of vertices in this primitive.
    ///   - morphCount: Total morph targets in `deltaPositions` (not the
    ///     active count).
    /// - Returns: `true` when the dispatch was encoded; `false` when the active
    ///   set is empty, the active-set buffer or pipeline state is missing, or
    ///   (DEBUG builds only) the delta buffer is smaller than
    ///   `morphCount * vertexCount` requires.
    public func applyMorphsCompute(
        encoder: MTLComputeCommandEncoder,
        basePositions: MTLBuffer,
        deltaPositions: MTLBuffer,  // SoA layout: [morph0[v0..vN], morph1[v0..vN], ...]
        outputPositions: MTLBuffer,
        vertexCount: Int,
        morphCount: Int
    ) -> Bool {
        guard !activeSet.isEmpty else {
            vrmLog("⚠️ [VRMMorphTargetSystem] Active set is empty, skipping batched morph compute")
            return false
        }

        // Verify delta buffer size matches expected T*V (in DEBUG only)
        #if DEBUG
        let expectedDeltaSize = morphCount * vertexCount * MemoryLayout<SIMD3<Float>>.stride
        if deltaPositions.length < expectedDeltaSize {
            vrmLog("❌ [VRMMorphTargetSystem] DeltaPos buffer size mismatch")
            vrmLog("  Expected: \(expectedDeltaSize) bytes for T=\(morphCount) V=\(vertexCount)")
            vrmLog("  Actual: \(deltaPositions.length) bytes")
            // Return false to skip compute dispatch and fall back to CPU path
            return false
        }
        #endif

        guard let pipelineState = morphAccumulatePipelineState else {
            return false
        }

        encoder.setComputePipelineState(pipelineState)

        // Set buffers
        encoder.setBuffer(basePositions, offset: 0, index: 0)
        encoder.setBuffer(deltaPositions, offset: 0, index: 1)
        // Per-dispatch setBytes so batched primitives do not share one
        // overwriteable active-set buffer (the GPU sees each draw's set).
        let activeBytes = MemoryLayout<ActiveMorph>.stride * activeSet.count
        activeSet.withUnsafeBufferPointer { pointer in
            encoder.setBytes(pointer.baseAddress!, length: activeBytes, index: 2)
        }

        // Set constants
        var vCount = UInt32(vertexCount)
        var mCount = UInt32(morphCount)
        var aCount = UInt32(activeSet.count)

        encoder.setBytes(&vCount, length: MemoryLayout<UInt32>.size, index: 3)
        encoder.setBytes(&mCount, length: MemoryLayout<UInt32>.size, index: 4)
        encoder.setBytes(&aCount, length: MemoryLayout<UInt32>.size, index: 5)
        encoder.setBuffer(outputPositions, offset: 0, index: 6)

        // Dispatch threads
        let threadsPerThreadgroup = MTLSize(width: 256, height: 1, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (vertexCount + 255) / 256,
            height: 1,
            depth: 1
        )

        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

        return true
    }

    /// Encodes the morph-accumulation compute pass for one primitive into `commandBuffer`.
    ///
    /// When the active set is empty, encodes a blit that copies
    /// `basePositions` into `outputPositions` so consumers can bind the
    /// output buffer unconditionally. When the set is non-empty, dispatches
    /// the `morph_accumulate_positions` kernel with 256-wide threadgroups.
    ///
    /// - Parameters:
    ///   - basePositions: Per-vertex base positions (read).
    ///   - deltaPositions: SoA delta buffer
    ///     `[morph0[v0..vN], morph1[v0..vN], …]` sized at least
    ///     `morphCount * vertexCount * sizeof(SIMD3<Float>)`.
    ///   - outputPositions: Per-vertex output buffer (write).
    ///   - vertexCount: Number of vertices in this primitive.
    ///   - morphCount: Total morph targets in `deltaPositions` (not the
    ///     active count).
    ///   - commandBuffer: The command buffer that will own the encoded pass.
    /// - Returns: `true` when the pass (or fallback blit copy) was
    ///   encoded; `false` when encoder creation failed, the pipeline state
    ///   is missing, or (DEBUG builds only) the delta buffer is smaller
    ///   than `morphCount * vertexCount` requires.
    public func applyMorphsCompute(
        basePositions: MTLBuffer,
        deltaPositions: MTLBuffer,  // SoA layout: [morph0[v0..vN], morph1[v0..vN], ...]
        outputPositions: MTLBuffer,
        vertexCount: Int,
        morphCount: Int,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        if activeSet.count == 0 {
            // No active morphs - just copy base positions to output
            // This ensures output buffer is always valid even with no morphs
            guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
                vrmLog("[VRMMorphTargetSystem] Failed to create blit encoder for copy")
                return false
            }
            blitEncoder.label = "Morph Base Copy (no active morphs)"

            let copySize = vertexCount * MemoryLayout<SIMD3<Float>>.stride
            blitEncoder.copy(from: basePositions, sourceOffset: 0,
                           to: outputPositions, destinationOffset: 0,
                           size: copySize)
            blitEncoder.endEncoding()

            vrmLog("[VRMMorphTargetSystem] Copied base positions (no active morphs) for \(vertexCount) vertices")
            return true
        }

        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return false
        }
        computeEncoder.label = "Morph Accumulate"

        let success = applyMorphsCompute(
            encoder: computeEncoder,
            basePositions: basePositions,
            deltaPositions: deltaPositions,
            outputPositions: outputPositions,
            vertexCount: vertexCount,
            morphCount: morphCount
        )

        computeEncoder.endEncoding()
        return success
    }

    // Removed legacy GPU morph application - only compute path exists
}

// MARK: - Morph Target Data

/// CPU-side morph-target payload as parsed from glTF: optional per-vertex position, normal, and tangent deltas keyed by name.
public struct VRMMorphTarget {
    /// Display name from `mesh.extras.targetNames` (or generated fallback).
    public let name: String
    /// Per-vertex position deltas, or `nil` when the morph target has none.
    public var positionDeltas: [SIMD3<Float>]?
    /// Per-vertex normal deltas, or `nil` when the morph target has none.
    public var normalDeltas: [SIMD3<Float>]?
    /// Per-vertex tangent deltas, or `nil` when the morph target has none.
    public var tangentDeltas: [SIMD3<Float>]?

    /// Creates an empty morph target with the given name. Deltas are populated by the loader.
    public init(name: String) {
        self.name = name
    }
}

// MARK: - Expression Controller

/// VRMExpressionController manages VRM facial expressions and morph target weights.
///
/// ## Thread Safety
/// **Partially thread-safe.** Read operations are safe from any thread, but write operations
/// (setting expression weights, animations) should be performed on the main thread.
///
/// This class is marked `@unchecked Sendable` because:
/// 1. Internal state (dictionaries, arrays) is accessed without locks
/// 2. Timer-based animations use `@MainActor` isolation for state mutations
/// 3. The class is designed for single-threaded use in typical rendering scenarios
///
/// ### Safe Usage Patterns:
/// ```swift
/// // ✅ SAFE: All mutations on main thread
/// Task { @MainActor in
///     controller.setExpressionWeight(.happy, weight: 1.0)
///     controller.blink()
/// }
///
/// // ⚠️ CAUTION: Reads from background thread (no concurrent writes!)
/// DispatchQueue.global().async {
///     let weights = controller.weightsForMesh(0, morphCount: 10)  // Safe if no concurrent writes
/// }
///
/// // ❌ UNSAFE: Concurrent writes from multiple threads
/// DispatchQueue.global().async {
///     controller.setExpressionWeight(.sad, weight: 0.5)  // Data race!
/// }
/// ```
///
/// ### Animation Safety:
/// The `blink()`, `speak()`, and `animateExpression()` methods use Timer and Task
/// with `@MainActor` to ensure mutations happen on the main thread. Do not call these
/// methods from background threads.
///
/// - Note: Future versions may use actor isolation or locks for full thread-safety.
public final class VRMExpressionController: @unchecked Sendable {
    private static let presetCount = VRMExpressionPreset.allCases.count
    private static let blinkGroupOrdinals: [Int] = [
        VRMExpressionPreset.blink.ordinal,
        VRMExpressionPreset.blinkLeft.ordinal,
        VRMExpressionPreset.blinkRight.ordinal,
    ]
    private static let lookAtGroupOrdinals: [Int] = [
        VRMExpressionPreset.lookUp.ordinal,
        VRMExpressionPreset.lookDown.ordinal,
        VRMExpressionPreset.lookLeft.ordinal,
        VRMExpressionPreset.lookRight.ordinal,
    ]
    private static let mouthGroupOrdinals: [Int] = [
        VRMExpressionPreset.aa.ordinal,
        VRMExpressionPreset.ih.ordinal,
        VRMExpressionPreset.ou.ordinal,
        VRMExpressionPreset.ee.ordinal,
        VRMExpressionPreset.oh.ordinal,
    ]

    /// Trivial POD metadata extracted at registration time so override and isBinary
    /// evaluation never copies `VRMExpression` or touches ARC-retained bind arrays.
    private struct OverrideMetadata {
        var presetOrdinal: Int  // -1 for custom or preset-less expressions
        var customSlot: Int     // -1 for preset expressions
        var isBinary: Bool
        var overrideBlink: VRMExpressionOverrideType
        var overrideLookAt: VRMExpressionOverrideType
        var overrideMouth: VRMExpressionOverrideType
        var hasOverrides: Bool
    }

    // Contiguous expression storage (indexed access avoids copying VRMExpression structs per frame).
    private var presetExpressionSlots: [Int] = Array(repeating: -1, count: VRMExpressionPreset.allCases.count)
    private var registeredPresetExpressions: [VRMExpression] = []
    private var registeredPresetOrdinals: [Int] = []
    private var registeredPresetMeta: [OverrideMetadata] = []

    private var customIndexByName: [String: Int] = [:]
    private var customExpressions: [VRMExpression] = []
    private var customMeta: [OverrideMetadata] = []

    // Contiguous weight storage (zero dictionary hashing/copying per frame).
    private var presetWeights: [Float] = Array(repeating: 0, count: VRMExpressionPreset.allCases.count)
    private var effectivePresetWeights: [Float] = Array(repeating: 0, count: VRMExpressionPreset.allCases.count)
    private var customWeights: [Float] = []
    private var customWeightIsSet: [Bool] = []

    private var morphTargetSystem: VRMMorphTargetSystem?
    private var animationTimer: Timer?

    // Track morph weights per mesh (single authoritative table; reused across frames).
    private var meshMorphWeights: [Int: [Float]] = [:]  // meshIndex -> morph weights for that mesh
    private var weightsDirty = true
    /// Reused per-mesh read buffers for ``weightsForMesh(_:morphCount:)``.
    private var weightReadScratch: [Int: [Float]] = [:]
    private var cachedMorphFingerprint: UInt64 = 0
    private var morphFingerprintValid = false

    // Material color override tracking for expression-driven material colors
    private var materialColorOverrides: [Int: [VRMMaterialColorType: SIMD4<Float>]] = [:]
    private var baseMaterialColors: [Int: [VRMMaterialColorType: SIMD4<Float>]] = [:]

    /// True when at least one material color override is currently active.
    /// Renderers can use this to short-circuit per-draw override lookups.
    public var hasMaterialColorOverrides: Bool {
        return !materialColorOverrides.isEmpty
    }

    /// Creates an empty controller with all preset weights at `0`. Attach a morph-target system via ``setMorphTargetSystem(_:)`` before rendering.
    public init() {}

    deinit {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    /// Attaches the GPU morph-target system that will receive accumulated per-mesh weights.
    public func setMorphTargetSystem(_ system: VRMMorphTargetSystem) {
        self.morphTargetSystem = system
    }

    /// Registers a preset expression definition (morph binds, material colour binds, override flags).
    public func registerExpression(_ expression: VRMExpression, for preset: VRMExpressionPreset) {
        let ordinal = preset.ordinal
        let meta = OverrideMetadata(
            presetOrdinal: expression.preset?.ordinal ?? -1,
            customSlot: -1,
            isBinary: expression.isBinary,
            overrideBlink: expression.overrideBlink,
            overrideLookAt: expression.overrideLookAt,
            overrideMouth: expression.overrideMouth,
            hasOverrides: expression.overrideBlink != .none
                || expression.overrideLookAt != .none
                || expression.overrideMouth != .none
        )
        let existingSlot = presetExpressionSlots[ordinal]
        if existingSlot >= 0 {
            registeredPresetExpressions[existingSlot] = expression
            registeredPresetMeta[existingSlot] = meta
        } else {
            let slot = registeredPresetExpressions.count
            presetExpressionSlots[ordinal] = slot
            registeredPresetExpressions.append(expression)
            registeredPresetOrdinals.append(ordinal)
            registeredPresetMeta.append(meta)
        }
        weightsDirty = true
    }

    /// Registers a custom (non-preset) expression by name. Required before ``setCustomExpressionWeight(_:weight:)`` will apply non-zero weights.
    public func registerCustomExpression(_ expression: VRMExpression, name: String) {
        let existingSlot = customIndexByName[name]
        let slot: Int
        if let existingSlot {
            slot = existingSlot
            customExpressions[slot] = expression
        } else {
            slot = customExpressions.count
            customIndexByName[name] = slot
            customExpressions.append(expression)
            customWeights.append(0)
            customWeightIsSet.append(false)
        }
        let meta = OverrideMetadata(
            presetOrdinal: expression.preset?.ordinal ?? -1,
            customSlot: expression.name == name ? slot : (expression.name.flatMap { customIndexByName[$0] } ?? -1),
            isBinary: expression.isBinary,
            overrideBlink: expression.overrideBlink,
            overrideLookAt: expression.overrideLookAt,
            overrideMouth: expression.overrideMouth,
            hasOverrides: expression.overrideBlink != .none
                || expression.overrideLookAt != .none
                || expression.overrideMouth != .none
        )
        if existingSlot != nil {
            customMeta[slot] = meta
        } else {
            customMeta.append(meta)
        }
        weightsDirty = true
    }

    // MARK: - Material Color Base Values

    /// Sets the base material color for a material. Called during model setup or runtime tint updates.
    /// The renderer calls this for each material's color properties so the expression
    /// controller knows the original values to blend from.
    public func setBaseMaterialColor(materialIndex: Int, type: VRMMaterialColorType, color: SIMD4<Float>) {
        if baseMaterialColors[materialIndex] == nil {
            baseMaterialColors[materialIndex] = [:]
        }
        baseMaterialColors[materialIndex]?[type] = color
        weightsDirty = true
    }

    /// Refreshes all stored base material colors for a single material from its live
    /// properties and eagerly recomputes any active expression color overrides.
    public func refreshBaseMaterialColor(materialIndex: Int, from material: VRMMaterial) {
        setBaseMaterialColor(materialIndex: materialIndex, type: .color, color: material.baseColorFactor)
        setBaseMaterialColor(materialIndex: materialIndex, type: .emissionColor, color: SIMD4<Float>(material.emissiveFactor, 1.0))
        material.withMToon { mtoon in
            setBaseMaterialColor(materialIndex: materialIndex, type: .shadeColor, color: SIMD4<Float>(mtoon.shadeColorFactor, 1.0))
            setBaseMaterialColor(materialIndex: materialIndex, type: .matcapColor, color: SIMD4<Float>(mtoon.matcapFactor, 1.0))
            setBaseMaterialColor(materialIndex: materialIndex, type: .rimColor, color: SIMD4<Float>(mtoon.parametricRimColorFactor, 1.0))
            setBaseMaterialColor(materialIndex: materialIndex, type: .outlineColor, color: SIMD4<Float>(mtoon.outlineColorFactor, 1.0))
        }
        ensureWeightsUpdated()
    }

    /// Refreshes all stored base material colors from `model.materials` and
    /// eagerly recomputes any active expression color overrides.
    public func refreshBaseMaterialColors(from model: VRMModel) {
        for (materialIndex, material) in model.materials.enumerated() {
            setBaseMaterialColor(materialIndex: materialIndex, type: .color, color: material.baseColorFactor)
            setBaseMaterialColor(materialIndex: materialIndex, type: .emissionColor, color: SIMD4<Float>(material.emissiveFactor, 1.0))
            material.withMToon { mtoon in
                setBaseMaterialColor(materialIndex: materialIndex, type: .shadeColor, color: SIMD4<Float>(mtoon.shadeColorFactor, 1.0))
                setBaseMaterialColor(materialIndex: materialIndex, type: .matcapColor, color: SIMD4<Float>(mtoon.matcapFactor, 1.0))
                setBaseMaterialColor(materialIndex: materialIndex, type: .rimColor, color: SIMD4<Float>(mtoon.parametricRimColorFactor, 1.0))
                setBaseMaterialColor(materialIndex: materialIndex, type: .outlineColor, color: SIMD4<Float>(mtoon.outlineColorFactor, 1.0))
            }
        }
        ensureWeightsUpdated()
    }

    /// Gets the material color override for rendering, if any expression is active that affects it.
    /// Returns nil if no override is active, meaning the renderer should use the original material color.
    public func getMaterialColorOverride(materialIndex: Int, type: VRMMaterialColorType) -> SIMD4<Float>? {
        return materialColorOverrides[materialIndex]?[type]
    }

    // MARK: - Expression Weight Control

    /// Sets the weight of a preset expression and recomputes per-mesh morph weights.
    ///
    /// `weight` is clamped to [0, 1]. The full recomputation pass applies
    /// `isBinary` quantisation, group overrides (block/blend on blink, look-at, and mouth groups),
    /// and material colour blending.
    public func setExpressionWeight(_ preset: VRMExpressionPreset, weight: Float) {
        let clampedWeight = clamp(weight, min: 0, max: 1)
        let ordinal = preset.ordinal
        if presetWeights[ordinal] != clampedWeight {
            presetWeights[ordinal] = clampedWeight
            weightsDirty = true
        }
    }

    /// Sets the weight of a previously registered custom expression by name. No-op if `name` was not registered via ``registerCustomExpression(_:name:)``.
    public func setCustomExpressionWeight(_ name: String, weight: Float) {
        guard let slot = customIndexByName[name] else { return }
        let clampedWeight = clamp(weight, min: 0, max: 1)
        if !customWeightIsSet[slot] || customWeights[slot] != clampedWeight {
            customWeights[slot] = clampedWeight
            customWeightIsSet[slot] = true
            weightsDirty = true
        }
    }

    /// Set multiple custom expression weights at once (more efficient for Perfect Sync).
    ///
    /// This method is optimized for setting many custom expression weights in a single call,
    /// which is common with Perfect Sync where 52 ARKit blend shapes map directly to
    /// custom expressions.
    ///
    /// - Parameter weights: Dictionary mapping custom expression names to weights [0-1]
    public func setCustomExpressionWeights(_ weights: [String: Float]) {
        var changed = false
        for (name, weight) in weights {
            guard let slot = customIndexByName[name] else { continue }
            let clampedWeight = clamp(weight, min: 0, max: 1)
            if !customWeightIsSet[slot] || customWeights[slot] != clampedWeight {
                customWeights[slot] = clampedWeight
                customWeightIsSet[slot] = true
                changed = true
            }
        }
        if changed {
            weightsDirty = true
        }
    }

    /// Current weight of a preset expression. Returns 0 when the preset
    /// has not been set (matches the `init()` default).
    public func weight(for preset: VRMExpressionPreset) -> Float {
        presetWeights[preset.ordinal]
    }

    /// Current weight of a registered custom expression. Returns `nil`
    /// when the name has not been registered via
    /// `registerCustomExpression(_:name:)` or has not been assigned a weight yet.
    public func weight(forCustom name: String) -> Float? {
        guard let slot = customIndexByName[name], customWeightIsSet[slot] else { return nil }
        return customWeights[slot]
    }

    // MARK: - Preset Animations

    /// Plays a one-shot blink that rises to full weight over `duration` and decays back to `0` over the same `duration`.
    ///
    /// `completion` runs on the main actor after the close-eyes leg
    /// finishes. Subsequent calls cancel the prior animation timer.
    public func blink(duration: Float = 0.15, completion: (@Sendable () -> Void)? = nil) {
        animateExpression(.blink, to: 1.0, duration: duration) { [weak self] in
            self?.animateExpression(.blink, to: 0.0, duration: duration, completion: completion)
        }
    }

    /// Snaps other mood presets to `0` and sets `mood` to `intensity` (clamped to [0, 1]).
    ///
    /// Mood presets are `happy`, `angry`, `sad`, `relaxed`, `surprised`.
    /// Other expression categories (mouth, blink, look-at) are left
    /// untouched.
    public func setMood(_ mood: VRMExpressionPreset, intensity: Float = 1.0) {
        // Reset other mood expressions
        let moodExpressions: [VRMExpressionPreset] = [.happy, .angry, .sad, .relaxed, .surprised]
        for expr in moodExpressions {
            if expr != mood {
                setExpressionWeight(expr, weight: 0)
            }
        }
        setExpressionWeight(mood, weight: intensity)
    }

    /// Plays a placeholder lip-sync animation by ramping the `.aa` vowel up and back down over `duration` seconds.
    public func speak(duration: Float = 2.0) {
        // Simple lip sync animation - to be improved with proper async handling
        // For now, just animate one vowel
        animateExpression(.aa, to: 0.8, duration: duration * 0.5) { [weak self] in
            self?.animateExpression(.aa, to: 0, duration: duration * 0.5)
        }
    }

    // MARK: - Animation

    private func animateExpression(_ preset: VRMExpressionPreset,
                                  to targetWeight: Float,
                                  duration: Float,
                                  completion: (@Sendable () -> Void)? = nil) {
        // Invalidate any existing animation timer to prevent overlapping animations
        animationTimer?.invalidate()

        let startWeight = presetWeights[preset.ordinal]
        let startTime = CACurrentMediaTime()

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] timer in
            // Compute progress off-actor to avoid sending non-Sendable values
            let elapsed = Float(CACurrentMediaTime() - startTime)
            let progress = min(elapsed / duration, 1.0)
            let weight = lerp(startWeight, targetWeight, progress)

            // Hop to main actor to safely touch controller state
            Task { @MainActor [weak self] in
                self?.setExpressionWeight(preset, weight: weight)
                if progress >= 1.0 {
                    completion?()
                }
            }

            if progress >= 1.0 {
                timer.invalidate()
                self?.animationTimer = nil
            }
        }
    }

    // MARK: - Private Methods

    private func updateMorphTargets() {
        // Rebuild per-mesh weights dynamically from active expressions.
        // Keep dictionary storage: this runs every dirty expression frame.
        resetMorphWeightScratch()

        // Copy raw preset weights into pre-allocated scratch array (76 bytes, zero heap allocs).
        for i in 0..<Self.presetCount {
            effectivePresetWeights[i] = presetWeights[i]
        }

        // Apply isBinary quantization and group overrides using trivial POD metadata
        // (zero VRMExpression copies, zero ARC retain/release traffic).
        applyOverridesAndBinary()

        var activeCount = 0
        for slot in 0..<registeredPresetExpressions.count {
            let ordinal = registeredPresetOrdinals[slot]
            let weight = effectivePresetWeights[ordinal]
            guard weight > 0 else { continue }
            applyExpressionToMeshWeights(registeredPresetExpressions[slot], weight: weight)
            applyExpressionToMaterialColors(registeredPresetExpressions[slot], weight: weight)
            activeCount += 1
        }

        // Apply custom expressions with override-adjusted weights, borrowing directly from storage.
        for slot in 0..<customExpressions.count {
            let rawWeight = customWeights[slot]
            guard rawWeight > 0 else { continue }
            let effectiveWeight = customMeta[slot].isBinary ? (rawWeight < 0.5 ? 0.0 : 1.0) : rawWeight
            if effectiveWeight > 0 {
                applyExpressionToMeshWeights(customExpressions[slot], weight: effectiveWeight)
                applyExpressionToMaterialColors(customExpressions[slot], weight: effectiveWeight)
                activeCount += 1
            }
        }

        if activeCount > 0 {
            vrmLog("[VRMExpressionController] Updated morph weights for \(activeCount) active expressions across \(meshMorphWeights.keys.count) meshes")
        }
    }

    /// Recomputes per-mesh weights only when expression weights or base material colors have changed since the last read.
    internal func ensureWeightsUpdated() {
        guard weightsDirty else { return }
        updateMorphTargets()
        weightsDirty = false
        morphFingerprintValid = false
    }

    /// Drops cached per-mesh / material-color scratch. Production rebuilds
    /// go through this so dictionary storage can be retained across frames.
    func resetMorphWeightScratch() {
        meshMorphWeights.removeAll(keepingCapacity: true)
        materialColorOverrides.removeAll(keepingCapacity: true)
    }

    var meshMorphWeightStorageCapacity: Int { meshMorphWeights.capacity }
    var cachedMeshMorphWeightStorageCapacity: Int { meshMorphWeights.capacity }
    var meshMorphWeightCount: Int { meshMorphWeights.count }

    /// Applies isBinary quantization and expression-group override semantics in-place
    /// on `effectivePresetWeights` using pre-extracted POD metadata.
    private func applyOverridesAndBinary() {
        // Step 1: isBinary quantization for preset expressions (and any custom expression with preset set).
        for i in 0..<registeredPresetMeta.count {
            let meta = registeredPresetMeta[i]
            guard meta.isBinary, meta.presetOrdinal >= 0 else { continue }
            let w = effectivePresetWeights[meta.presetOrdinal]
            effectivePresetWeights[meta.presetOrdinal] = w < 0.5 ? 0.0 : 1.0
        }
        for i in 0..<customMeta.count {
            let meta = customMeta[i]
            guard meta.isBinary, meta.presetOrdinal >= 0 else { continue }
            let w = effectivePresetWeights[meta.presetOrdinal]
            effectivePresetWeights[meta.presetOrdinal] = w < 0.5 ? 0.0 : 1.0
        }

        // Step 2: Compute group suppression factors using all active expression weights.
        var blockBlink = false
        var blockLookAt = false
        var blockMouth = false
        var blendBlink: Float = 1.0
        var blendLookAt: Float = 1.0
        var blendMouth: Float = 1.0

        for i in 0..<registeredPresetMeta.count {
            let meta = registeredPresetMeta[i]
            guard meta.hasOverrides else { continue }
            let w: Float
            if meta.presetOrdinal >= 0 {
                let raw = effectivePresetWeights[meta.presetOrdinal]
                w = meta.isBinary ? (raw < 0.5 ? 0.0 : 1.0) : raw
            } else {
                continue
            }
            guard w > 0 else { continue }

            switch meta.overrideBlink {
            case .block: blockBlink = true
            case .blend: blendBlink *= (1.0 - w)
            case .none: break
            }
            switch meta.overrideLookAt {
            case .block: blockLookAt = true
            case .blend: blendLookAt *= (1.0 - w)
            case .none: break
            }
            switch meta.overrideMouth {
            case .block: blockMouth = true
            case .blend: blendMouth *= (1.0 - w)
            case .none: break
            }
        }

        for i in 0..<customMeta.count {
            let meta = customMeta[i]
            guard meta.hasOverrides else { continue }
            let w: Float
            if meta.presetOrdinal >= 0 {
                let raw = effectivePresetWeights[meta.presetOrdinal]
                w = meta.isBinary ? (raw < 0.5 ? 0.0 : 1.0) : raw
            } else if meta.customSlot >= 0 {
                let raw = customWeights[meta.customSlot]
                w = meta.isBinary ? (raw < 0.5 ? 0.0 : 1.0) : raw
            } else {
                continue
            }
            guard w > 0 else { continue }

            switch meta.overrideBlink {
            case .block: blockBlink = true
            case .blend: blendBlink *= (1.0 - w)
            case .none: break
            }
            switch meta.overrideLookAt {
            case .block: blockLookAt = true
            case .blend: blendLookAt *= (1.0 - w)
            case .none: break
            }
            switch meta.overrideMouth {
            case .block: blockMouth = true
            case .blend: blendMouth *= (1.0 - w)
            case .none: break
            }
        }

        // Step 3: Apply suppression to each group. block dominates blend.
        if blockBlink {
            for ordinal in Self.blinkGroupOrdinals { effectivePresetWeights[ordinal] = 0.0 }
        } else if blendBlink < 1.0 {
            for ordinal in Self.blinkGroupOrdinals { effectivePresetWeights[ordinal] *= blendBlink }
        }
        if blockLookAt {
            for ordinal in Self.lookAtGroupOrdinals { effectivePresetWeights[ordinal] = 0.0 }
        } else if blendLookAt < 1.0 {
            for ordinal in Self.lookAtGroupOrdinals { effectivePresetWeights[ordinal] *= blendLookAt }
        }
        if blockMouth {
            for ordinal in Self.mouthGroupOrdinals { effectivePresetWeights[ordinal] = 0.0 }
        } else if blendMouth < 1.0 {
            for ordinal in Self.mouthGroupOrdinals { effectivePresetWeights[ordinal] *= blendMouth }
        }
    }

    /// Applies material color binds from an expression, blending with base colors.
    private func applyExpressionToMaterialColors(_ expression: borrowing VRMExpression, weight: Float) {
        let count = expression.materialColorBinds.count
        guard count > 0 else { return }
        for i in 0..<count {
            let bind = expression.materialColorBinds[i]
            let materialIndex = bind.material
            let colorType = bind.type

            // Get the base color for this material/type (default to opaque white if not set)
            let baseColor = baseMaterialColors[materialIndex]?[colorType] ?? SIMD4<Float>(1, 1, 1, 1)

            // Get current override (may have been set by earlier expression in this update)
            let currentColor = materialColorOverrides[materialIndex]?[colorType] ?? baseColor

            // Blend: lerp from current toward target by weight
            let blendedColor = mix(currentColor, bind.targetValue, t: weight)

            // Store the override
            if materialColorOverrides[materialIndex] == nil {
                materialColorOverrides[materialIndex] = [:]
            }
            materialColorOverrides[materialIndex]?[colorType] = blendedColor
        }
    }

    /// Linear interpolation between two SIMD4 colors
    private func mix(_ a: SIMD4<Float>, _ b: SIMD4<Float>, t: Float) -> SIMD4<Float> {
        return a + (b - a) * t
    }

    private func applyExpressionToMeshWeights(_ expression: borrowing VRMExpression, weight: Float) {
        // Apply morph target binds per mesh. Reject binds whose morphIndex is
        // negative or beyond the per-mesh cap so a malicious VRM cannot grow
        // meshMorphWeights to an arbitrary size (DoS via unbounded allocation)
        // or crash the loader by indexing with a negative value.
        let count = expression.morphTargetBinds.count
        guard count > 0 else { return }
        for i in 0..<count {
            let bind = expression.morphTargetBinds[i]
            // Use the resolved mesh index, not the authored `node` (a node index
            // for VRM 1.0). `meshIndex` == `node` for VRM 0.x, so both paths key
            // morph weights by mesh consistently.
            let meshIndex = bind.meshIndex
            let morphIndex = bind.index

            guard morphIndex >= 0, morphIndex < maxMorphTargets else {
                vrmLog("[VRMExpressionController] Skipping out-of-range morphIndex \(morphIndex) (cap \(maxMorphTargets))")
                continue
            }

            // Remove-modify-reinsert guarantees unique backing storage (zero CoW copies).
            let delta = bind.weight * weight
            if var existing = meshMorphWeights.removeValue(forKey: meshIndex) {
                if existing.count <= morphIndex {
                    existing.append(contentsOf: repeatElement(0.0, count: morphIndex + 1 - existing.count))
                }
                existing[morphIndex] += delta
                meshMorphWeights[meshIndex] = existing
            } else {
                var arr = [Float](repeating: 0.0, count: morphIndex + 1)
                arr[morphIndex] = delta
                meshMorphWeights[meshIndex] = arr
            }
        }
    }

    /// Returns the per-morph weight array for `meshIndex`, padded or truncated to exactly `morphCount` entries.
    ///
    /// The renderer uses this to bind a fixed-size weights buffer per
    /// primitive without knowing the underlying mesh's morph layout.
    public func weightsForMesh(_ meshIndex: Int, morphCount: Int) -> [Float] {
        guard morphCount > 0 else { return [] }
        ensureWeightsUpdated()
        let source = meshMorphWeights[meshIndex]
        // Take the scratch out so CoW does not copy on fill.
        var scratch = weightReadScratch.removeValue(forKey: meshIndex) ?? []
        if scratch.count != morphCount {
            scratch = [Float](repeating: 0, count: morphCount)
        } else {
            for i in 0..<morphCount { scratch[i] = 0 }
        }
        if let source {
            let copyCount = min(source.count, morphCount)
            for i in 0..<copyCount {
                scratch[i] = source[i]
            }
        }
        weightReadScratch[meshIndex] = scratch
        return scratch
    }

    /// Stable hash of the rebuilt per-mesh morph weights. Unchanged across
    /// frames that did not mutate expression weights — the renderer uses
    /// this to skip the morph compute pass (#150).
    public func morphWeightsFingerprint() -> UInt64 {
        ensureWeightsUpdated()
        if !morphFingerprintValid {
            var hasher = Hasher()
            for key in meshMorphWeights.keys.sorted() {
                hasher.combine(key)
                if let values = meshMorphWeights[key] {
                    for value in values {
                        hasher.combine(value)
                    }
                }
            }
            cachedMorphFingerprint = UInt64(bitPattern: Int64(hasher.finalize()))
            morphFingerprintValid = true
        }
        return cachedMorphFingerprint
    }

    func weightReadScratchCapacity(for meshIndex: Int) -> Int {
        weightReadScratch[meshIndex]?.capacity ?? 0
    }



    private let maxMorphTargets = VRMConstants.Rendering.maxMorphTargets
}

// MARK: - Morph Target Shader

/// Reference Metal source for a fixed 4-target morph vertex shader. Retained as a fallback when no precompiled `.metallib` is available.
public class MorphTargetShader {
    /// Concatenated Metal source for the morph vertex stage and a simple lit fragment stage.
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct MorphVertex {
        float3 position [[attribute(0)]];
        float3 normal [[attribute(1)]];
        float2 texCoord [[attribute(2)]];
        float4 color [[attribute(3)]];
        // Morph target attributes
        float3 positionDelta1 [[attribute(4)]];
        float3 normalDelta1 [[attribute(5)]];
        float3 positionDelta2 [[attribute(6)]];
        float3 normalDelta2 [[attribute(7)]];
        float3 positionDelta3 [[attribute(8)]];
        float3 normalDelta3 [[attribute(9)]];
        float3 positionDelta4 [[attribute(10)]];
        float3 normalDelta4 [[attribute(11)]];
    };

    struct Uniforms {
        float4x4 modelMatrix;
        float4x4 viewMatrix;
        float4x4 projectionMatrix;
        float4x4 normalMatrix;
    };

    struct VertexOut {
        float4 position [[position]];
        float3 worldNormal;
        float2 texCoord;
        float4 color;
    };

    vertex VertexOut morph_vertex(MorphVertex in [[stage_in]],
                                  constant Uniforms& uniforms [[buffer(1)]],
                                  constant float* morphWeights [[buffer(2)]]) {
        // Apply morph targets
        float3 morphedPosition = in.position;
        float3 morphedNormal = in.normal;

        // Apply up to 4 morph targets (can be extended)
        morphedPosition += in.positionDelta1 * morphWeights[0];
        morphedNormal += in.normalDelta1 * morphWeights[0];

        morphedPosition += in.positionDelta2 * morphWeights[1];
        morphedNormal += in.normalDelta2 * morphWeights[1];

        morphedPosition += in.positionDelta3 * morphWeights[2];
        morphedNormal += in.normalDelta3 * morphWeights[2];

        morphedPosition += in.positionDelta4 * morphWeights[3];
        morphedNormal += in.normalDelta4 * morphWeights[3];

        // Transform to clip space
        float4 worldPosition = uniforms.modelMatrix * float4(morphedPosition, 1.0);
        float3 worldNormal = normalize((uniforms.normalMatrix * float4(morphedNormal, 0.0)).xyz);

        VertexOut out;
        out.position = uniforms.projectionMatrix * uniforms.viewMatrix * worldPosition;
        out.worldNormal = worldNormal;
        out.texCoord = in.texCoord;
        out.color = in.color;

        return out;
    }

    fragment float4 morph_fragment(VertexOut in [[stage_in]]) {
        // Simple lit shading
        float3 lightDir = normalize(float3(0.5, 1.0, 0.5));
        float3 normal = normalize(in.worldNormal);
        float NdotL = max(dot(normal, lightDir), 0.0);

        float3 ambient = float3(0.3, 0.3, 0.3);
        float3 diffuse = float3(1.0, 1.0, 1.0) * NdotL;
        float3 color = (ambient + diffuse) * in.color.rgb;

        return float4(color, in.color.a);
    }
    """
}

// MARK: - Helper Functions

private func clamp(_ value: Float, min: Float, max: Float) -> Float {
    return Swift.max(min, Swift.min(max, value))
}

private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
    return a + (b - a) * t
}

// MARK: - Expression Mixer

/// VRMExpressionMixer provides high-level expression control with auto-blink and lip sync.
///
/// ## Thread Safety
/// **NOT thread-safe.** All methods must be called from the main thread due to Timer usage.
///
/// This class is marked `@unchecked Sendable` to work with async/await patterns, but:
/// 1. Internal Timer callbacks execute on the main thread only
/// 2. The underlying VRMExpressionController requires main-thread access
/// 3. Auto-blink scheduling uses `@MainActor` tasks for thread safety
///
/// ### Safe Usage Patterns:
/// ```swift
/// // ✅ SAFE: All operations on main thread
/// Task { @MainActor in
///     let mixer = VRMExpressionMixer(controller: controller)
///     mixer.setAutoBlinkEnabled(true)
///     mixer.performLipSync(with: audioData)
/// }
///
/// // ❌ UNSAFE: Background thread usage
/// DispatchQueue.global().async {
///     mixer.setAutoBlinkEnabled(false)  // Timer operations not thread-safe!
/// }
/// ```
///
/// - Note: Always create and use VRMExpressionMixer on the main thread.
public final class VRMExpressionMixer: @unchecked Sendable {
    private var controller: VRMExpressionController
    private var autoBlinkEnabled = false
    private var blinkTimer: Timer?
    private var lastBlinkTime: TimeInterval = 0

    /// Wraps an existing ``VRMExpressionController``. Must be created on the main thread.
    public init(controller: VRMExpressionController) {
        self.controller = controller
    }

    /// Toggles automatic random blinking. Starts a 0.1 s polling timer when enabled; tears it down when disabled.
    ///
    /// Must be called from the main thread; the timer callback dispatches
    /// to `@MainActor` for the blink itself.
    public func setAutoBlinkEnabled(_ enabled: Bool) {
        autoBlinkEnabled = enabled
        if enabled {
            startAutoBlink()
        } else {
            stopAutoBlink()
        }
    }

    private func startAutoBlink() {
        guard autoBlinkEnabled else { return }
        // Invalidate existing timer before creating a new one
        blinkTimer?.invalidate()

        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }

                let currentTime = CACurrentMediaTime()
                let timeSinceLastBlink = currentTime - self.lastBlinkTime

                // Blink every 3-5 seconds randomly
                let blinkInterval = Double.random(in: 3.0...5.0)

                if timeSinceLastBlink > blinkInterval {
                    self.controller.blink()
                    self.lastBlinkTime = currentTime
                }
            }
        }
    }

    private func stopAutoBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
    }

    // MARK: - Lip Sync

    /// Drives mouth presets from raw audio amplitude as a placeholder lip-sync.
    ///
    /// Computes the mean absolute amplitude of `audioData` and routes it
    /// to the `.aa`, `.oh`, `.ih`, or `.neutral` preset depending on
    /// magnitude. Production integrations should use a proper phoneme
    /// extractor and feed weights directly through ``VRMExpressionController``.
    public func performLipSync(with audioData: [Float], sampleRate: Int = 44100) {
        // Simple lip sync based on audio amplitude
        // In a real implementation, this would analyze phonemes

        let amplitude = audioData.reduce(0) { $0 + abs($1) } / Float(audioData.count)
        let normalizedAmplitude = min(amplitude * 10, 1.0)

        // Map amplitude to mouth shapes
        if normalizedAmplitude > 0.7 {
            controller.setExpressionWeight(.aa, weight: normalizedAmplitude)
        } else if normalizedAmplitude > 0.5 {
            controller.setExpressionWeight(.oh, weight: normalizedAmplitude)
        } else if normalizedAmplitude > 0.3 {
            controller.setExpressionWeight(.ih, weight: normalizedAmplitude)
        } else {
            controller.setExpressionWeight(.neutral, weight: 1.0)
        }
    }

    deinit {
        stopAutoBlink()
    }
}
