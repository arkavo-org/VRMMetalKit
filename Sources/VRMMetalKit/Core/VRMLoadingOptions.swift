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

    /// Enables aggressive texture compression; may slightly reduce visual quality.
    public static let aggressiveTextureCompression = VRMLoadingOptimization(rawValue: 1 << 1)

    /// Skips secondary UV channels (`TEXCOORD_1` and above) when present.
    public static let skipSecondaryUVs = VRMLoadingOptimization(rawValue: 1 << 2)

    /// Decodes textures concurrently where supported.
    public static let parallelTextureDecoding = VRMLoadingOptimization(rawValue: 1 << 3)

    /// Loads textures in parallel using a `TaskGroup`; large win for models with many textures.
    public static let parallelTextureLoading = VRMLoadingOptimization(rawValue: 1 << 4)

    /// Defers texture loading until first use rather than loading every texture at startup.
    public static let lazyTextureLoading = VRMLoadingOptimization(rawValue: 1 << 5)

    /// Loads meshes in parallel using a `TaskGroup`.
    public static let parallelMeshLoading = VRMLoadingOptimization(rawValue: 1 << 6)

    /// Preloads all binary buffers at the start of loading; eliminates I/O stalls during mesh and texture passes.
    public static let preloadBuffers = VRMLoadingOptimization(rawValue: 1 << 7)

    /// Builds ``VRMMaterial`` instances in parallel.
    public static let parallelMaterialLoading = VRMLoadingOptimization(rawValue: 1 << 8)

    /// Default optimization set: skip verbose logging and use parallel texture decoding.
    public static let `default`: VRMLoadingOptimization = [.skipVerboseLogging, .parallelTextureDecoding]

    /// Most aggressive optimization preset. Trades some image quality for shortest load time.
    public static let maximumPerformance: VRMLoadingOptimization = [
        .skipVerboseLogging,
        .aggressiveTextureCompression,
        .skipSecondaryUVs,
        .parallelTextureDecoding,
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
public struct VRMLoadingOptions: Sendable {

    /// Optional progress callback invoked on the `MainActor` during loading.
    public let progressCallback: (@Sendable (VRMLoadingProgress) -> Void)?

    /// Minimum interval in seconds between progress-callback invocations; throttles UI updates.
    public let progressUpdateInterval: TimeInterval

    /// When `true`, the loader honors Swift Concurrency task cancellation.
    public let enableCancellation: Bool

    /// Performance optimizations to apply during this load.
    public let optimizations: VRMLoadingOptimization

    /// When `true`, synthesize tight bone-derived colliders (limb capsules +
    /// head/brow capsule) additive to authored colliders, to reduce SpringBone
    /// clipping (issue #309). Default `true`.
    public let augmentSpringBoneColliders: Bool

    /// Creates loading options.
    ///
    /// - Parameters:
    ///   - progressCallback: Called periodically with loading progress. Runs on MainActor.
    ///   - progressUpdateInterval: Minimum seconds between progress updates (default: 0.1).
    ///   - enableCancellation: Whether to check for Task cancellation (default: true).
    ///   - optimizations: Performance optimizations to apply (default: .default).
    ///   - augmentSpringBoneColliders: Synthesize bone-derived colliders additive to authored ones (default: true).
    public init(
        progressCallback: (@Sendable (VRMLoadingProgress) -> Void)? = nil,
        progressUpdateInterval: TimeInterval = 0.1,
        enableCancellation: Bool = true,
        optimizations: VRMLoadingOptimization = .default,
        augmentSpringBoneColliders: Bool = true
    ) {
        self.progressCallback = progressCallback
        self.progressUpdateInterval = progressUpdateInterval
        self.enableCancellation = enableCancellation
        self.optimizations = optimizations
        self.augmentSpringBoneColliders = augmentSpringBoneColliders
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
        
        // Call the callback on the main actor
        if let callback = options.progressCallback {
            await MainActor.run {
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

