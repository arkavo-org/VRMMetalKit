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

//
//  VRMLoadingOptions.swift
//  VRMMetalKit
//
//  Created by Kimi Code CLI on 2026-01-30.
//

import Foundation
@preconcurrency import Metal

// MARK: - VRMPreloadedTexture

/// Source payload for an in-memory texture supplied to ``VRMLoadingOptions/preloadedTextures``.
///
/// Allows authoring hosts (such as `VRMAuthorKit`) to feed straight-alpha RGBA8 pixel buffers
/// or already-allocated Metal textures (e.g. ASTC, BC7, or pre-uploaded RGBA8) directly into
/// `VRMModel.load(...)`, bypassing PNG encoding and ImageIO decoding.
public enum VRMPreloadedTextureSource: @unchecked Sendable {
    /// Straight-alpha RGBA8 pixel bytes (4 bytes per pixel).
    case rgba8(data: Data, width: Int, height: Int, bytesPerRow: Int? = nil)
    /// Already-allocated GPU texture adopted directly without re-upload.
    case mtlTexture(MTLTexture)
}

/// A pre-decoded or pre-uploaded texture override keyed by glTF texture index in ``VRMLoadingOptions/preloadedTextures``.
public struct VRMPreloadedTexture: Sendable {
    /// Pixel buffer or pre-allocated `MTLTexture` payload.
    public let source: VRMPreloadedTextureSource
    /// Optional color-space override (`nil` infers sRGB vs linear from the glTF material bindings).
    public let sRGB: Bool?
    /// Optional mipmap override (`nil` honors the glTF sampler's minFilter).
    public let mipmapped: Bool?
    /// Optional alpha-coverage mipmap override (`nil` infers from MASK/BLEND base-color bindings).
    public let alphaIsCoverage: Bool?

    /// Creates an in-memory texture override.
    public init(
        source: VRMPreloadedTextureSource,
        sRGB: Bool? = nil,
        mipmapped: Bool? = nil,
        alphaIsCoverage: Bool? = nil
    ) {
        self.source = source
        self.sRGB = sRGB
        self.mipmapped = mipmapped
        self.alphaIsCoverage = alphaIsCoverage
    }

    /// Convenience factory for a straight-alpha RGBA8 pixel buffer.
    public static func rgba8(
        data: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int? = nil,
        sRGB: Bool? = nil,
        mipmapped: Bool? = nil,
        alphaIsCoverage: Bool? = nil
    ) -> VRMPreloadedTexture {
        VRMPreloadedTexture(
            source: .rgba8(data: data, width: width, height: height, bytesPerRow: bytesPerRow),
            sRGB: sRGB,
            mipmapped: mipmapped,
            alphaIsCoverage: alphaIsCoverage
        )
    }

    /// Convenience factory for an already-allocated `MTLTexture` (e.g. ASTC, BC7, or RGBA8).
    public static func mtlTexture(_ texture: MTLTexture) -> VRMPreloadedTexture {
        VRMPreloadedTexture(source: .mtlTexture(texture))
    }
}

// MARK: - VRMLoadingPhase

/// Distinct stages reported by ``VRMLoadingOptions/progressCallback`` while loading a VRM model.
///
/// Each phase carries a relative ``weight`` used to convert per-phase
/// progress into a single overall percentage in ``VRMLoadingProgress``.
public enum VRMLoadingPhase: String, CaseIterable, Sendable {
    /// Parsing the GLB / glTF JSON header.
    case parsingGLTF = "Parsing GLTF"
    /// Parsing the `VRMC_vrm` (or VRM 0.0) extension block.
    case parsingVRMExtension = "Parsing VRM Extension"
    /// Preloading all binary buffers in parallel.
    case preloadingBuffers = "Preloading Buffers"
    /// Decoding and uploading textures to Metal.
    case loadingTextures = "Loading Textures"
    /// Converting glTF and VRM 0.x material properties into ``VRMMaterial`` instances.
    case loadingMaterials = "Loading Materials"
    /// Building vertex buffers, index buffers, and morph targets.
    case loadingMeshes = "Loading Meshes"
    /// Wiring up the parent/child node hierarchy and precomputing world transforms.
    case buildingHierarchy = "Building Hierarchy"
    /// Loading skin inverse-bind matrices and joint lists.
    case loadingSkins = "Loading Skins"
    /// Clamping out-of-range joint indices ("iron dome" pass).
    case sanitizingJoints = "Sanitizing Joints"
    /// Allocating GPU buffers for spring-bone simulation.
    case initializingPhysics = "Initializing Physics"
    /// Loading finished; final progress report.
    case complete = "Complete"

    /// Relative contribution of this phase to overall load progress, in `0.0...1.0`.
    public var weight: Double {
        switch self {
        case .parsingGLTF: return 0.05
        case .parsingVRMExtension: return 0.05
        case .preloadingBuffers: return 0.03
        case .loadingTextures: return 0.34  // Textures are the slowest
        case .loadingMaterials: return 0.10
        case .loadingMeshes: return 0.20
        case .buildingHierarchy: return 0.05
        case .loadingSkins: return 0.10
        case .sanitizingJoints: return 0.05
        case .initializingPhysics: return 0.03
        case .complete: return 0.0
        }
    }
}

// MARK: - VRMLoadingProgress

/// Snapshot of VRM loading progress passed to ``VRMLoadingOptions/progressCallback``.
///
/// Combines the current ``currentPhase``, the per-phase progress, and an
/// aggregated ``overallProgress`` weighted by ``VRMLoadingPhase/weight``.
public struct VRMLoadingProgress: Sendable {
    /// The current phase of loading.
    public let currentPhase: VRMLoadingPhase
    
    /// Progress within the current phase (0.0-1.0).
    public let phaseProgress: Double
    
    /// Overall progress across all phases (0.0-1.0).
    public let overallProgress: Double
    
    /// Number of items completed in current phase (if applicable).
    public let itemsCompleted: Int
    
    /// Total number of items in current phase (if applicable).
    public let totalItems: Int
    
    /// Time elapsed since loading started.
    public let elapsedTime: TimeInterval
    
    /// Estimated time remaining.
    public let estimatedTimeRemaining: TimeInterval?
    
    /// Human-readable description of current operation.
    public let operationDescription: String
    
    /// Convenience accessor for ``overallProgress`` expressed as `0...100`.
    public var percentage: Int {
        Int((overallProgress * 100).rounded())
    }

    /// Creates a progress snapshot. Used internally by ``VRMModel`` during loading.
    public init(
        currentPhase: VRMLoadingPhase,
        phaseProgress: Double,
        overallProgress: Double,
        itemsCompleted: Int = 0,
        totalItems: Int = 0,
        elapsedTime: TimeInterval = 0,
        estimatedTimeRemaining: TimeInterval? = nil,
        operationDescription: String = ""
    ) {
        self.currentPhase = currentPhase
        self.phaseProgress = phaseProgress
        self.overallProgress = overallProgress
        self.itemsCompleted = itemsCompleted
        self.totalItems = totalItems
        self.elapsedTime = elapsedTime
        self.estimatedTimeRemaining = estimatedTimeRemaining
        self.operationDescription = operationDescription
    }
}

// MARK: - VRMLoadingOptimization

/// Option-set of performance toggles applied during VRM loading.
///
/// Use ``default`` for typical production loads or ``maximumPerformance``
/// when load latency matters more than image quality (e.g. avatar previews,
/// batch processing).
public struct VRMLoadingOptimization: OptionSet, Sendable {
    /// The raw bit pattern backing this option set.
    public let rawValue: Int

    /// Creates an optimization set from a raw bitfield.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Suppresses non-error log output during loading.
    public static let skipVerboseLogging = VRMLoadingOptimization(rawValue: 1 << 0)

    /// Re-encodes sRGB color textures as BC7 at load time (issue #359).
    ///
    /// Trades load CPU for ~4× less GPU texture bandwidth. Linear maps
    /// (normals, masks) stay RGBA8. Quality is pixel-near, not bit-identical:
    /// solid colors stay within 1/255; typical albedo mean-absolute error is
    /// ≤ 3/255 per channel. Devices that cannot sample BC keep RGBA8.
    public static let aggressiveTextureCompression = VRMLoadingOptimization(rawValue: 1 << 1)

    /// Loads textures in parallel using a `TaskGroup`; large win for models with many textures.
    public static let parallelTextureLoading = VRMLoadingOptimization(rawValue: 1 << 4)

    /// Loads meshes in parallel using a `TaskGroup`.
    public static let parallelMeshLoading = VRMLoadingOptimization(rawValue: 1 << 6)

    /// Preloads all binary buffers at the start of loading; eliminates I/O stalls during mesh and texture passes.
    public static let preloadBuffers = VRMLoadingOptimization(rawValue: 1 << 7)

    /// Builds ``VRMMaterial`` instances in parallel.
    public static let parallelMaterialLoading = VRMLoadingOptimization(rawValue: 1 << 8)

    /// Default optimization set: skip verbose logging and decode/upload textures
    /// concurrently with a bounded concurrency window (`ParallelTextureLoader`)
    /// while preserving strict error propagation.
    public static let `default`: VRMLoadingOptimization = [
        .skipVerboseLogging,
        .parallelTextureLoading
    ]

    /// Most aggressive optimization preset. Trades some image quality for shortest load time.
    public static let maximumPerformance: VRMLoadingOptimization = [
        .skipVerboseLogging,
        .aggressiveTextureCompression,
        .parallelTextureLoading,
        .parallelMeshLoading,
        .preloadBuffers,
        .parallelMaterialLoading
    ]
}

// MARK: - VRMLoadingOptions

/// Configuration passed to ``VRMModel/load(from:device:options:)`` to control progress reporting, cancellation, and load-time optimizations.
///
/// `VRMLoadingOptions` is `Sendable` and safe to share across actors. Use
/// ``default`` for the typical fast-path production load. For UI scenarios,
/// supply a ``progressCallback`` to drive a progress bar; the callback fires
/// on the `MainActor` no more often than ``progressUpdateInterval``.
///
/// ```swift
/// // Minimal: load with default optimizations and no progress.
/// let model = try await VRMModel.load(from: url, device: device)
///
/// // Progress + cancellation: pass options.
/// let options = VRMLoadingOptions(progressCallback: { progress in
///     hud.update(percentage: progress.percentage,
///                phase: progress.currentPhase.rawValue)
/// })
/// let model = try await VRMModel.load(from: url, device: device, options: options)
///
/// // Maximum performance for batch previews.
/// let fast = VRMLoadingOptions(optimizations: .maximumPerformance)
/// let preview = try await VRMModel.load(from: url, device: device, options: fast)
/// ```
///
/// ## Cancellation
/// When ``enableCancellation`` is `true` (the default), the loader checks
/// `Task.isCancelled` at each phase boundary and throws
/// ``GLTFError/loadingCancelled`` if cancellation has been requested.
///
/// A cancel that lands inside a primitive decode instead propagates Swift's
/// `CancellationError` out of the decode task group, on both the serial and
/// the parallel mesh path and regardless of ``enableCancellation``. Callers
/// that special-case cancellation must match both error types.
public struct VRMLoadingOptions: Sendable {

    /// Optional progress callback invoked on the `MainActor` during loading.
    public let progressCallback: (@Sendable (VRMLoadingProgress) -> Void)?

    /// Minimum interval in seconds between progress-callback invocations; throttles UI updates.
    public let progressUpdateInterval: TimeInterval

    /// When `true`, the loader honors Swift Concurrency task cancellation.
    public let enableCancellation: Bool

    /// Performance optimizations to apply during this load.
    public let optimizations: VRMLoadingOptimization

    /// When `true` (the default), synthesize bone-derived colliders additive to
    /// any colliders authored in the VRM file, to reduce common SpringBone clipping
    /// artefacts (issue #309).
    ///
    /// Two shapes are synthesized:
    /// - A forward head/brow capsule, sized from the model's head-reference radius,
    ///   which eliminates front-hair-into-forehead sinking.
    /// - End-to-end leg capsules (upper-leg → ankle) that substantially reduce
    ///   skirt-panel-into-thigh clipping.
    ///
    /// Authored colliders are never mutated or removed; this is purely additive.
    /// Models with 32 or more authored collider groups skip augmentation because
    /// the 32-bit GPU group-bitmask requires one free slot for the synthetic
    /// group (up to 31 authored groups are supported).
    ///
    /// Set to `false` to restore authored-only behaviour — useful when bisecting a
    /// physics regression or validating a newly rigged model against its original
    /// collider layout. Because augmentation is default-on, resting spring-bone
    /// positions differ from pre-#309 versions on affected models.
    public let augmentSpringBoneColliders: Bool

    /// Memory and structural quotas enforced during model loading.
    public let limits: VRMLoaderLimits

    /// Optional map from glTF texture index to an in-memory raw RGBA8 buffer or pre-allocated
    /// `MTLTexture`. Matching texture indices bypass ImageIO decoding completely.
    public let preloadedTextures: [Int: VRMPreloadedTexture]

    /// When `false` (the default), CPU-side morph-target delta arrays (`positionDeltas`,
    /// `normalDeltas`, `tangentDeltas`) are released immediately after uploading to GPU
    /// SoA buffers, significantly reducing resident memory per avatar.
    ///
    /// Set to `true` when CPU inspection of morph deltas is required on a GPU-loaded model.
    /// CPU-only loads (`device == nil`) always retain CPU deltas regardless of this flag.
    public let retainCPUMorphDeltas: Bool

    /// When `false` (the default), the parsed ``GLTFDocument`` AST (`VRMModel.gltf`) is
    /// released after resource loading finishes to reclaim memory during viewing.
    ///
    /// Set to `true` when downstream code needs to inspect the raw parsed glTF document.
    public let retainGLTFDocument: Bool

    /// Creates loading options.
    ///
    /// - Parameters:
    ///   - progressCallback: Called periodically with loading progress. Runs on MainActor.
    ///   - progressUpdateInterval: Minimum seconds between progress updates (default: 0.1).
    ///   - enableCancellation: Whether to check for Task cancellation at phase
    ///     boundaries (default: true). Primitive decodes throw
    ///     `CancellationError` regardless of this flag.
    ///   - optimizations: Performance optimizations to apply (default: .default).
    ///   - augmentSpringBoneColliders: Synthesize bone-derived colliders additive to authored ones (default: true).
    ///   - limits: Configurable memory and structural quotas enforced during load (default: `.default`).
    ///   - preloadedTextures: Optional in-memory texture overrides keyed by glTF texture index (default: empty).
    ///   - retainCPUMorphDeltas: Keep CPU morph-delta arrays after GPU SoA upload (default: false).
    ///   - retainGLTFDocument: Keep the parsed `GLTFDocument` AST on `VRMModel.gltf` after load (default: false).
    public init(
        progressCallback: (@Sendable (VRMLoadingProgress) -> Void)? = nil,
        progressUpdateInterval: TimeInterval = 0.1,
        enableCancellation: Bool = true,
        optimizations: VRMLoadingOptimization = .default,
        augmentSpringBoneColliders: Bool = true,
        limits: VRMLoaderLimits = .default,
        preloadedTextures: [Int: VRMPreloadedTexture] = [:],
        retainCPUMorphDeltas: Bool = false,
        retainGLTFDocument: Bool = false
    ) {
        self.progressCallback = progressCallback
        self.progressUpdateInterval = progressUpdateInterval
        self.enableCancellation = enableCancellation
        self.optimizations = optimizations
        self.augmentSpringBoneColliders = augmentSpringBoneColliders
        self.limits = limits
        self.preloadedTextures = preloadedTextures
        self.retainCPUMorphDeltas = retainCPUMorphDeltas
        self.retainGLTFDocument = retainGLTFDocument
    }
    
    /// Default options: no progress callback, cancellation enabled, ``VRMLoadingOptimization/default`` optimizations.
    public static let `default` = VRMLoadingOptions()
}

// MARK: - VRMLoadingContext

/// Actor for thread-safe loading state management.
internal actor VRMLoadingContext {
    let options: VRMLoadingOptions
    let startTime: Date
    var phaseStartTime: Date
    var currentPhase: VRMLoadingPhase
    var phaseProgress: Double
    var lastProgressUpdate: Date
    var totalItemsInPhase: Int
    
    init(options: VRMLoadingOptions) async {
        self.options = options
        self.startTime = Date()
        self.phaseStartTime = Date()
        self.currentPhase = .parsingGLTF
        self.phaseProgress = 0.0
        self.lastProgressUpdate = Date.distantPast
        self.totalItemsInPhase = 0
    }
    
    /// Check if loading should be cancelled.
    func checkCancellation() throws {
        guard options.enableCancellation else { return }
        
        if Task.isCancelled {
            throw GLTFError.loadingCancelled
        }
    }
    
    /// Update to a new loading phase.
    func updatePhase(_ phase: VRMLoadingPhase, progress: Double = 0.0) async {
        currentPhase = phase
        phaseProgress = progress
        phaseStartTime = Date()
        
        // Report progress on phase change
        await reportProgressIfNeeded(force: true)
    }
    
    /// Update to a new phase with item count.
    func updatePhase(_ phase: VRMLoadingPhase, totalItems: Int) async {
        currentPhase = phase
        phaseProgress = 0.0
        totalItemsInPhase = totalItems
        phaseStartTime = Date()
        
        await reportProgressIfNeeded(force: true)
    }
    
    /// Update progress within current phase.
    func updateProgress(itemsCompleted: Int, totalItems: Int) async {
        phaseProgress = totalItems > 0 ? Double(itemsCompleted) / Double(totalItems) : 0.0
        await reportProgressIfNeeded()
    }
    
    /// Report progress if enough time has elapsed or forced.
    private func reportProgressIfNeeded(force: Bool = false) async {
        let now = Date()
        let timeSinceLastUpdate = now.timeIntervalSince(lastProgressUpdate)
        
        guard force || timeSinceLastUpdate >= options.progressUpdateInterval else {
            return
        }
        
        lastProgressUpdate = now
        
        // Calculate overall progress
        let elapsedTime = now.timeIntervalSince(startTime)
        let overallProgress = calculateOverallProgress()
        
        // Calculate estimated time remaining
        var estimatedTimeRemaining: TimeInterval? = nil
        if overallProgress > 0.01 {
            let totalEstimatedTime = elapsedTime / overallProgress
            estimatedTimeRemaining = totalEstimatedTime - elapsedTime
        }
        
        let loadingProgress = VRMLoadingProgress(
            currentPhase: currentPhase,
            phaseProgress: phaseProgress,
            overallProgress: overallProgress,
            itemsCompleted: Int(Double(totalItemsInPhase) * phaseProgress),
            totalItems: totalItemsInPhase,
            elapsedTime: elapsedTime,
            estimatedTimeRemaining: estimatedTimeRemaining,
            operationDescription: "\(currentPhase.rawValue) (\(Int(phaseProgress * 100))%)"
        )
        
        // Deliver the callback on the main actor, fire-and-forget: awaiting
        // the MainActor round-trip here stalls the load task whenever the
        // main thread is busy — with N concurrent model loads these forced
        // hops (every phase change) serialize the loaders against the main
        // actor. `elapsedTime` is stamped above, before the hop, so progress
        // timing stays accurate, and MainActor delivery preserves ordering.
        if let callback = options.progressCallback {
            Task { @MainActor in
                callback(loadingProgress)
            }
        }
    }
    
    /// Calculate overall progress based on phase weights.
    private func calculateOverallProgress() -> Double {
        var progress: Double = 0.0
        var reachedCurrentPhase = false
        
        for phase in VRMLoadingPhase.allCases {
            if phase == currentPhase {
                progress += phase.weight * phaseProgress
                reachedCurrentPhase = true
                break
            } else if !reachedCurrentPhase {
                progress += phase.weight
            }
        }
        
        return min(progress, 1.0)
    }
}

