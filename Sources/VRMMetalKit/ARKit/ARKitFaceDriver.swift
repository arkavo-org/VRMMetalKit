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

// MARK: - Source Priority Strategy

/// Strategy used by ``ARKitFaceDriver/update(sources:controller:priority:)`` to pick or merge among
/// multiple active face sources.
public enum SourcePriorityStrategy: Sendable {
    /// Selects the source with the most recent ``ARFaceSource/lastUpdate``.
    case latestActive

    /// Selects the source matching the given identifier, falling back to ``latestActive`` if unavailable.
    case primary(UUID)

    /// Merges sources by weighted average using the supplied per-`sourceID` weights.
    case weighted([UUID: Float])

    /// Selects the source with the highest tracking confidence; currently falls back to ``latestActive``
    /// because per-source confidence is not yet plumbed through.
    case highestConfidence
}

// MARK: - Face Driver

/// Drives a ``VRMExpressionController`` from `ARFaceAnchor`-shaped blend shape data.
///
/// The driver is the entry point for face tracking. Per frame, the caller hands it a fresh
/// ``ARKitFaceBlendShapes`` snapshot (typically built from `ARFaceAnchor.blendShapes` in an
/// `ARSessionDelegate` callback). The driver:
///
/// 1. Drops stale snapshots based on the `maxAge` parameter.
/// 2. Routes weights through Perfect Sync direct-mapping when available (see ``initializeForModel(_:)``),
///    or composite mapping via ``ARKitToVRMMapper`` otherwise.
/// 3. Applies per-expression smoothing through a ``FilterManager`` configured by ``SmoothingConfig``.
/// 4. Pushes the smoothed weights to the supplied ``VRMExpressionController``.
///
/// ## Mapping coverage
///
/// ARKit defines 52 blend shapes (see ``ARKitFaceBlendShapes/allKeys``). The standard composite mapper
/// (``ARKitToVRMMapper/default``) reduces them to 18 VRM expression keys: the five emotion presets
/// (happy/angry/sad/relaxed/surprised), the five visemes (aa/ih/ou/ee/oh), blink/blinkLeft/blinkRight,
/// the four eye-gaze presets (lookUp/lookDown/lookLeft/lookRight), and neutral. No ARKit shape is
/// dropped — every shape is read by at least one mapping formula in the default mapper.
///
/// Override the mapping by mutating the supplied ``ARKitToVRMMapper/mappings`` dictionary before passing
/// it to the initializer, or by replacing it with one of ``ARKitToVRMMapper/simplified`` or
/// ``ARKitToVRMMapper/aggressive``. Override smoothing per expression via ``SmoothingConfig/perExpression``.
///
/// ## Thread Safety
///
/// **Not thread-safe.** No internal lock guards the mutating state (statistics, filter manager,
/// `lastSourceID`, `perfectSyncCapability`). Call all methods from a single context — typically the
/// main thread or the ARKit delegate's serial queue. Marked `@unchecked Sendable` to participate in
/// `@MainActor` actors.
///
/// ## Usage
///
/// ### Basic Single-Source
/// ```swift
/// let driver = ARKitFaceDriver(
///     mapper: .default,
///     smoothing: .default
/// )
///
/// func onFaceUpdate(_ blendShapes: ARKitFaceBlendShapes) {
///     driver.update(
///         blendShapes: blendShapes,
///         controller: expressionController
///     )
/// }
/// ```
///
/// ### Multi-Source with Priority
/// ```swift
/// let source1 = ARFaceSource(name: "iPhone Front")
/// let source2 = ARFaceSource(name: "iPad Side")
///
/// driver.update(
///     sources: [source1, source2],
///     controller: expressionController,
///     priority: .latestActive
/// )
/// ```
///
/// ### Custom Per-Expression Smoothing
/// ```swift
/// var config = SmoothingConfig.default
/// config.perExpression["blink"] = .none  // No smoothing for blinks
/// config.perExpression["jawOpen"] = .ema(alpha: 0.1)  // Heavy smoothing for jaw
///
/// let driver = ARKitFaceDriver(mapper: .default, smoothing: config)
/// ```
public final class ARKitFaceDriver: @unchecked Sendable {
    // Configuration
    /// Composite mapper used when Perfect Sync is unavailable or for the preset side of partial Perfect Sync.
    public let mapper: ARKitToVRMMapper
    /// Smoothing configuration consulted when allocating per-key filters; mutate then call
    /// ``updateSmoothingConfig(_:)`` to apply.
    public var smoothingConfig: SmoothingConfig

    // Perfect Sync support
    /// The Perfect Sync capability detected for the bound model, set by ``initializeForModel(_:)``.
    /// Defaults to `.none` until a model is bound.
    public private(set) var perfectSyncCapability: PerfectSyncCapability = .none
    private var perfectSyncMapper: PerfectSyncMapper?

    // Smoothing state
    private var filterManager: FilterManager

    // Multi-source tracking
    private var lastSourceID: UUID?
    private var lastUpdateTime: TimeInterval = 0

    // Statistics
    /// Total ``update(blendShapes:controller:maxAge:)`` calls observed (incremented before staleness check).
    public private(set) var updateCount: Int = 0
    /// Subset of ``updateCount`` that was dropped because the snapshot exceeded the supplied `maxAge`.
    public private(set) var skippedUpdates: Int = 0  // Due to stale data

    /// Creates a face driver with the given composite mapper and smoothing configuration.
    ///
    /// Defaults to ``ARKitToVRMMapper/default`` and ``SmoothingConfig/default`` for balanced behavior.
    /// Call ``initializeForModel(_:)`` once the VRM model is loaded to enable Perfect Sync detection.
    public init(
        mapper: ARKitToVRMMapper = .default,
        smoothing: SmoothingConfig = .default
    ) {
        self.mapper = mapper
        self.smoothingConfig = smoothing
        self.filterManager = FilterManager(config: smoothing)
    }

    // MARK: - Perfect Sync Initialization

    /// Initialize Perfect Sync from VRM model (call after model load).
    ///
    /// Detects whether the VRM model has Perfect Sync custom expressions
    /// (ARKit blend shape names) and configures the driver accordingly.
    /// Supports different naming conventions (camelCase, PascalCase, snake_case).
    ///
    /// - Parameter model: The loaded VRM model
    public func initializeForModel(_ model: VRMModel) {
        let result = PerfectSyncCapability.detect(from: model)
        self.perfectSyncCapability = result.capability

        switch result.capability {
        case .none:
            perfectSyncMapper = nil
        case .partial, .full:
            perfectSyncMapper = PerfectSyncMapper(
                capability: result.capability,
                nameMapping: result.nameMapping,
                fallbackMapper: mapper
            )
        }

        #if VRM_METALKIT_ENABLE_LOGS
        vrmLog("[ARKitFaceDriver] Perfect Sync: \(result.capability.description)")
        #endif
    }

    /// Create a driver configured for the given VRM model with auto-detected Perfect Sync.
    ///
    /// This is a convenience factory method that creates a driver and initializes
    /// Perfect Sync detection in one step.
    ///
    /// - Parameters:
    ///   - model: The VRM model to configure for
    ///   - mapper: ARKit to VRM expression mapper (default: `.default`)
    ///   - smoothing: Smoothing configuration (default: `.default`)
    /// - Returns: A configured ARKitFaceDriver instance
    public static func configured(
        for model: VRMModel,
        mapper: ARKitToVRMMapper = .default,
        smoothing: SmoothingConfig = .default
    ) -> ARKitFaceDriver {
        let driver = ARKitFaceDriver(mapper: mapper, smoothing: smoothing)
        driver.initializeForModel(model)
        return driver
    }

    // MARK: - Single Source Updates

    /// Update VRM expressions from ARKit blend shapes (single source)
    ///
    /// If Perfect Sync was initialized via `initializeForModel(_:)`, this method
    /// uses direct 1:1 mapping for matched ARKit blend shapes, providing higher
    /// fidelity facial animation.
    ///
    /// - Parameters:
    ///   - blendShapes: ARKit face blend shape data
    ///   - controller: VRM expression controller to update
    ///   - maxAge: Maximum age before data is considered stale (default: 150ms)
    public func update(
        blendShapes: ARKitFaceBlendShapes,
        controller: VRMExpressionController,
        maxAge: TimeInterval = 0.150
    ) {
        updateCount += 1

        // Check staleness
        let now = Date().timeIntervalSinceReferenceDate
        let age = now - blendShapes.timestamp
        if age > maxAge {
            skippedUpdates += 1
            vrmLog("[ARKitFaceDriver] Skipping stale data (age: \(Int(age * 1000))ms)")
            return
        }

        // Use Perfect Sync path if available
        if let psMapper = perfectSyncMapper {
            let (customWeights, presetWeights) = psMapper.evaluate(blendShapes)

            // Apply smoothing to custom weights
            var smoothedCustom: [String: Float] = [:]
            for (key, weight) in customWeights {
                smoothedCustom[key] = filterManager.update(key: key, value: weight)
            }

            // Apply smoothing to preset weights
            var smoothedPreset: [String: Float] = [:]
            for (key, weight) in presetWeights {
                smoothedPreset[key] = filterManager.update(key: key, value: weight)
            }

            // Apply weights to controller
            applyPerfectSyncWeights(custom: smoothedCustom, preset: smoothedPreset, to: controller)
        } else {
            // Standard path: Map ARKit → VRM expressions
            let rawWeights = mapper.evaluate(blendShapes)

            // Apply smoothing
            var smoothedWeights: [String: Float] = [:]
            for (expression, weight) in rawWeights {
                let smoothed = filterManager.update(key: expression, value: weight)
                smoothedWeights[expression] = smoothed
            }

            // Update controller
            applyWeights(smoothedWeights, to: controller)
        }

        lastUpdateTime = now
    }

    // MARK: - Perfect Sync Weight Application

    /// Apply Perfect Sync weights to controller.
    ///
    /// Uses batch method for custom expressions (more efficient for 52 weights)
    /// and individual calls for preset weights.
    private func applyPerfectSyncWeights(
        custom: [String: Float],
        preset: [String: Float],
        to controller: VRMExpressionController
    ) {
        // Apply custom expression weights in batch for efficiency
        if !custom.isEmpty {
            controller.setCustomExpressionWeights(custom)
        }

        // Apply preset weights individually (usually fewer in partial mode)
        for (key, weight) in preset {
            if let presetEnum = VRMExpressionPreset(rawValue: key) {
                controller.setExpressionWeight(presetEnum, weight: weight)
            }
        }
    }

    // MARK: - Multi-Source Updates

    /// Update from multiple face tracking sources
    ///
    /// Handles multiple simultaneous sources (e.g., iPhone + iPad cameras).
    /// Uses priority strategy to select or merge data.
    ///
    /// - Parameters:
    ///   - sources: Array of face sources
    ///   - controller: VRM expression controller to update
    ///   - priority: Strategy for handling multiple sources
    public func update(
        sources: [ARFaceSource],
        controller: VRMExpressionController,
        priority: SourcePriorityStrategy = .latestActive
    ) {
        // Filter to active sources only
        let activeSources = sources.filter { $0.isActive }

        guard !activeSources.isEmpty else {
            vrmLog("[ARKitFaceDriver] No active face sources")
            return
        }

        // Select source(s) based on strategy
        let selectedBlendShapes: ARKitFaceBlendShapes?

        switch priority {
        case .latestActive:
            // Use most recently updated source
            let latest = activeSources.max { $0.lastUpdate < $1.lastUpdate }
            selectedBlendShapes = latest?.blendShapes

        case .primary(let preferredID):
            // Use primary if available, else fall back to latest
            if let primary = activeSources.first(where: { $0.sourceID == preferredID }) {
                selectedBlendShapes = primary.blendShapes
            } else {
                let fallback = activeSources.max { $0.lastUpdate < $1.lastUpdate }
                selectedBlendShapes = fallback?.blendShapes
            }

        case .weighted(let weights):
            // Merge sources with weighted average
            selectedBlendShapes = mergeWeighted(sources: activeSources, weights: weights)

        case .highestConfidence:
            // TODO: Implement confidence-based selection when available
            // For now, fall back to latest active
            let latest = activeSources.max { $0.lastUpdate < $1.lastUpdate }
            selectedBlendShapes = latest?.blendShapes
        }

        guard let blendShapes = selectedBlendShapes else {
            vrmLog("[ARKitFaceDriver] No blend shapes available from sources")
            return
        }

        // Update with selected data
        update(blendShapes: blendShapes, controller: controller)
    }

    // MARK: - Direct Weight Application

    /// Apply pre-computed expression weights to controller (bypasses mapping/smoothing)
    ///
    /// Useful for testing, debugging, or when weights are pre-computed externally.
    public func applyWeights(_ weights: [String: Float], to controller: VRMExpressionController) {
        for (expressionKey, weight) in weights {
            // Try to match to VRMExpressionPreset
            if let preset = VRMExpressionPreset(rawValue: expressionKey) {
                controller.setExpressionWeight(preset, weight: weight)
            } else {
                // Custom expression
                controller.setCustomExpressionWeight(expressionKey, weight: weight)
            }
        }
    }

    // MARK: - State Management

    /// Reset all smoothing filters
    ///
    /// Clears accumulated state. Call when switching avatars or restarting tracking.
    public func resetFilters() {
        filterManager.resetAll()
        updateCount = 0
        skippedUpdates = 0
    }

    /// Reset specific expression filter
    public func resetFilter(for expression: String) {
        filterManager.reset(key: expression)
    }

    /// Update smoothing configuration
    ///
    /// Creates new filter instances with updated config. Existing filter state is lost.
    public func updateSmoothingConfig(_ config: SmoothingConfig) {
        self.smoothingConfig = config
        self.filterManager = FilterManager(config: config)
    }

    // MARK: - Statistics

    /// Get update statistics
    public func getStatistics() -> DriverStatistics {
        return DriverStatistics(
            totalUpdates: updateCount,
            skippedUpdates: skippedUpdates,
            lastUpdateTime: lastUpdateTime
        )
    }

    // MARK: - Private Helpers

    private func mergeWeighted(
        sources: [ARFaceSource],
        weights: [UUID: Float]
    ) -> ARKitFaceBlendShapes? {
        var mergedShapes: [String: Float] = [:]
        var totalWeight: Float = 0
        var latestTimestamp: TimeInterval = 0

        for source in sources {
            guard let blendShapes = source.blendShapes,
                  let weight = weights[source.sourceID], weight > 0 else {
                continue
            }

            for (key, value) in blendShapes.shapes {
                mergedShapes[key, default: 0] += value * weight
            }
            totalWeight += weight
            // Track timestamp from blend shapes that actually contributed to merge
            latestTimestamp = max(latestTimestamp, blendShapes.timestamp)
        }

        guard totalWeight > 0 else { return nil }

        // Normalize by total weight
        for key in mergedShapes.keys {
            mergedShapes[key]! /= totalWeight
        }

        return ARKitFaceBlendShapes(timestamp: latestTimestamp, shapes: mergedShapes)
    }
}

// MARK: - Driver Statistics

/// Snapshot of ``ARKitFaceDriver`` activity counters returned by `ARKitFaceDriver.getStatistics()`.
public struct DriverStatistics: Sendable {
    /// Total number of updates processed
    public let totalUpdates: Int

    /// Number of updates skipped due to stale data
    public let skippedUpdates: Int

    /// Timestamp of last successful update
    public let lastUpdateTime: TimeInterval

    /// Skip rate (0-1)
    public var skipRate: Float {
        guard totalUpdates > 0 else { return 0 }
        return Float(skippedUpdates) / Float(totalUpdates)
    }

    /// Time since last update (in seconds)
    public var timeSinceLastUpdate: TimeInterval {
        return Date().timeIntervalSinceReferenceDate - lastUpdateTime
    }
}

// MARK: - Conditional Logging

#if VRM_METALKIT_ENABLE_LOGS
func vrmLog(_ message: String) {
    print("[VRMMetalKit] \(message)")
}
#else
@inline(__always)
func vrmLog(_ message: String) { }
#endif
