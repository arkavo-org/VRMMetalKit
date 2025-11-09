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

/// Strategy for handling multiple simultaneous face tracking sources
public enum SourcePriorityStrategy: Sendable {
    /// Use the most recently updated active source
    case latestActive

    /// Use a specific primary source, fall back to others if unavailable
    case primary(UUID)

    /// Merge multiple sources with weighted average
    case weighted([UUID: Float])

    /// Use the source with highest confidence (if available)
    case highestConfidence
}

// MARK: - Face Driver

/// Drives VRM facial expressions from ARKit face tracking data
///
/// ARKitFaceDriver is the primary API for integrating ARKit face tracking with VRM avatars.
/// It handles mapping, smoothing, multi-source management, and QoS.
///
/// ## Features
/// - Maps 52 ARKit blend shapes to VRM expression presets
/// - Configurable smoothing (EMA, Kalman, Windowed)
/// - Multi-source support with priority strategies
/// - Staleness detection and auto-pause
/// - Per-expression smoothing overrides
///
/// ## Thread Safety
/// **NOT thread-safe.** All methods must be called from the same thread (typically main thread).
/// Marked `@unchecked Sendable` to work with `@MainActor` contexts in ArkavoCreator.
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
    public let mapper: ARKitToVRMMapper
    public var smoothingConfig: SmoothingConfig

    // Smoothing state
    private var filterManager: FilterManager

    // Multi-source tracking
    private var lastSourceID: UUID?
    private var lastUpdateTime: TimeInterval = 0

    // Statistics
    public private(set) var updateCount: Int = 0
    public private(set) var skippedUpdates: Int = 0  // Due to stale data

    public init(
        mapper: ARKitToVRMMapper = .default,
        smoothing: SmoothingConfig = .default
    ) {
        self.mapper = mapper
        self.smoothingConfig = smoothing
        self.filterManager = FilterManager(config: smoothing)
    }

    // MARK: - Single Source Updates

    /// Update VRM expressions from ARKit blend shapes (single source)
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

        // Map ARKit → VRM expressions
        let rawWeights = mapper.evaluate(blendShapes)

        // Apply smoothing
        var smoothedWeights: [String: Float] = [:]
        for (expression, weight) in rawWeights {
            let smoothed = filterManager.update(key: expression, value: weight)
            smoothedWeights[expression] = smoothed
        }

        // Update controller
        applyWeights(smoothedWeights, to: controller)

        lastUpdateTime = now
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

        for source in sources {
            guard let blendShapes = source.blendShapes,
                  let weight = weights[source.sourceID], weight > 0 else {
                continue
            }

            for (key, value) in blendShapes.shapes {
                mergedShapes[key, default: 0] += value * weight
            }
            totalWeight += weight
        }

        guard totalWeight > 0 else { return nil }

        // Normalize by total weight
        for key in mergedShapes.keys {
            mergedShapes[key]! /= totalWeight
        }

        // Use timestamp from most recent source
        let latestTimestamp = sources.map { $0.lastUpdate }.max() ?? 0

        return ARKitFaceBlendShapes(timestamp: latestTimestamp, shapes: mergedShapes)
    }
}

// MARK: - Driver Statistics

/// Statistics about driver performance and updates
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
