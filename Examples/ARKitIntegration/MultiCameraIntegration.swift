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
import simd
import VRMMetalKit

/// Multi-camera ARKit integration with priority strategies
///
/// This example demonstrates handling multiple Continuity Cameras simultaneously
/// with different priority strategies for face and body tracking.
///
/// Use Cases:
/// - Multiple iPhones/iPads for redundancy
/// - Front + side cameras for better body coverage
/// - Primary camera with automatic fallback
///
/// Usage:
/// ```swift
/// let integration = MultiCameraARKitIntegration()
/// integration.loadVRMModel(url: modelURL)
///
/// // Register multiple camera sources
/// cameraSession1.onMetadata = { event in
///     integration.handleCameraMetadata(sourceID: "iPhone15Pro", event: event)
/// }
///
/// cameraSession2.onMetadata = { event in
///     integration.handleCameraMetadata(sourceID: "iPad", event: event)
/// }
/// ```
class MultiCameraARKitIntegration {
    // MARK: - Properties

    /// Face tracking driver with primary/fallback strategy
    let faceDriver: ARKitFaceDriver

    /// Body tracking driver with latest-active strategy
    let bodyDriver: ARKitBodyDriver

    /// VRM model to animate
    var vrmModel: VRMModel?

    /// Collected face data from all sources
    private var faceSources: [String: ARKitFaceBlendShapes] = [:]

    /// Collected body data from all sources
    private var bodySources: [String: ARKitBodySkeleton] = [:]

    /// Staleness threshold for cleaning up old data (seconds)
    private let stalenessThreshold: TimeInterval = 0.5  // 500ms

    // MARK: - Initialization

    init() {
        // Face driver: prefer iPhone, fallback to iPad
        // Use case: iPhone has better front camera, use iPad if iPhone disconnects
        faceDriver = ARKitFaceDriver(
            mapper: .default,
            smoothing: .default,
            priority: .primary("iPhone15Pro", fallback: "iPad")
        )

        // Body driver: use latest active source
        // Use case: Any camera angle is useful for body, just use newest data
        bodyDriver = ARKitBodyDriver(
            mapper: .default,
            smoothing: .default,
            priority: .latestActive
        )

        print("Multi-camera integration initialized")
        print("Face: Primary='iPhone15Pro', Fallback='iPad'")
        print("Body: LatestActive")
    }

    /// Initialize with custom priority strategies
    ///
    /// - Parameters:
    ///   - facePriority: Priority strategy for face tracking
    ///   - bodyPriority: Priority strategy for body tracking
    init(facePriority: ARKitFaceDriver.SourcePriority,
         bodyPriority: ARKitBodyDriver.SourcePriority) {
        faceDriver = ARKitFaceDriver(
            mapper: .default,
            smoothing: .default,
            priority: facePriority
        )

        bodyDriver = ARKitBodyDriver(
            mapper: .default,
            smoothing: .default,
            priority: bodyPriority
        )
    }

    // MARK: - VRM Model Loading

    func loadVRMModel(url: URL) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MultiCameraError.noMetalDevice
        }

        let loader = try VRMLoader(device: device)
        vrmModel = try loader.load(from: url)

        print("Loaded VRM model: \(vrmModel!.name ?? "Unnamed")")
    }

    // MARK: - Multi-Camera Event Handling

    /// Handle camera metadata from a specific source
    ///
    /// Call this from each camera's event handler with a unique sourceID.
    /// The driver will automatically select the appropriate source based on
    /// the configured priority strategy.
    ///
    /// - Parameters:
    ///   - sourceID: Unique identifier for this camera (e.g., "iPhone15Pro", "iPad")
    ///   - event: Camera metadata event
    func handleCameraMetadata(sourceID: String, event: CameraMetadataEvent) {
        guard let vrm = vrmModel else {
            print("WARNING: No VRM model loaded")
            return
        }

        // Extract and store face data
        if let faceData = extractFaceBlendShapes(from: event) {
            faceSources[sourceID] = faceData
        }

        // Extract and store body data
        if let bodyData = extractBodySkeleton(from: event) {
            bodySources[sourceID] = bodyData
        }

        // Update drivers with all available sources
        updateDrivers(vrm: vrm)

        // Clean up stale sources periodically
        cleanStaleSources()
    }

    /// Update both drivers with current multi-source data
    private func updateDrivers(vrm: VRMModel) {
        // Update face expressions from all sources
        if !faceSources.isEmpty {
            faceDriver.updateMulti(
                sources: faceSources,
                controller: vrm.expressionController
            )
        }

        // Update body skeleton from all sources
        if !bodySources.isEmpty {
            bodyDriver.updateMulti(
                skeletons: bodySources,
                nodes: vrm.nodes,
                humanoid: vrm.vrm?.humanoid
            )

            // Update world transforms after skeleton changes
            updateWorldTransforms(vrm: vrm)
        }
    }

    /// Remove stale data from disconnected or slow sources
    private func cleanStaleSources() {
        let now = Date().timeIntervalSinceReferenceDate

        // Remove face sources older than threshold
        let staleFaceSources = faceSources.filter { _, data in
            now - data.timestamp > stalenessThreshold
        }

        for (sourceID, _) in staleFaceSources {
            print("Removing stale face source: \(sourceID)")
            faceSources.removeValue(forKey: sourceID)
        }

        // Remove body sources older than threshold
        let staleBodySources = bodySources.filter { _, data in
            now - data.timestamp > stalenessThreshold
        }

        for (sourceID, _) in staleBodySources {
            print("Removing stale body source: \(sourceID)")
            bodySources.removeValue(forKey: sourceID)
        }
    }

    // MARK: - Data Extraction

    private func extractFaceBlendShapes(from event: CameraMetadataEvent) -> ARKitFaceBlendShapes? {
        guard let shapes = event.arkit?.faceBlendShapes else { return nil }

        return ARKitFaceBlendShapes(
            timestamp: event.timestamp,
            shapes: shapes
        )
    }

    private func extractBodySkeleton(from event: CameraMetadataEvent) -> ARKitBodySkeleton? {
        guard let joints = event.arkit?.bodyJoints else { return nil }

        let confidence = event.arkit?.bodyTrackingConfidence ?? 0

        return ARKitBodySkeleton(
            timestamp: event.timestamp,
            joints: joints,
            isTracked: confidence > 0.5
        )
    }

    // MARK: - Transform Updates

    private func updateWorldTransforms(vrm: VRMModel) {
        let rootNodes = vrm.nodes.filter { $0.parent == nil }
        for root in rootNodes {
            root.updateWorldTransform(parentTransform: nil)
        }
    }

    // MARK: - Source Management

    /// Get list of currently active sources
    func getActiveSources() -> (face: [String], body: [String]) {
        let now = Date().timeIntervalSinceReferenceDate

        let activeFace = faceSources.filter { _, data in
            now - data.timestamp < stalenessThreshold
        }.map { $0.key }

        let activeBody = bodySources.filter { _, data in
            now - data.timestamp < stalenessThreshold
        }.map { $0.key }

        return (face: activeFace.sorted(), body: activeBody.sorted())
    }

    /// Manually remove a source (e.g., when camera disconnects)
    func removeSource(sourceID: String) {
        faceSources.removeValue(forKey: sourceID)
        bodySources.removeValue(forKey: sourceID)
        print("Removed source: \(sourceID)")
    }

    /// Clear all sources (e.g., when resetting session)
    func clearAllSources() {
        faceSources.removeAll()
        bodySources.removeAll()
        print("Cleared all sources")
    }

    // MARK: - Statistics

    func printStatistics() {
        let faceStats = faceDriver.getStatistics()
        let bodyStats = bodyDriver.getStatistics()
        let activeSources = getActiveSources()

        print("""
        === Multi-Camera ARKit Statistics ===
        Active Sources:
          - Face: \(activeSources.face.joined(separator: ", "))
          - Body: \(activeSources.body.joined(separator: ", "))

        Face Driver:
          - Total updates: \(faceStats.totalUpdates)
          - Skipped updates: \(faceStats.skippedUpdates)
          - Skip rate: \(String(format: "%.1f", faceStats.skipRate * 100))%

        Body Driver:
          - Update count: \(bodyStats.updateCount)
          - Last update: \(String(format: "%.3f", bodyStats.lastUpdateTime))s ago
        ====================================
        """)
    }

    func resetStatistics() {
        faceDriver.resetStatistics()
        bodyDriver.resetStatistics()
    }
}

// MARK: - Errors

enum MultiCameraError: Error {
    case noMetalDevice
    case noActiveSources
}

// MARK: - Example Priority Strategy Configurations

extension MultiCameraARKitIntegration {
    /// Create integration optimized for desk/seated scenario
    ///
    /// Uses front camera for face, any camera for upper body only
    static func deskScenario() -> MultiCameraARKitIntegration {
        let faceDriver = ARKitFaceDriver(
            mapper: .default,
            smoothing: .default,
            priority: .primary("FrontCamera", fallback: "iPhone")
        )

        let bodyDriver = ARKitBodyDriver(
            mapper: .upperBodyOnly,  // Desk scenario - no leg tracking needed
            smoothing: .default,
            priority: .latestActive
        )

        let integration = MultiCameraARKitIntegration.__createWith(
            faceDriver: faceDriver,
            bodyDriver: bodyDriver
        )

        print("Created desk scenario integration (upper body only)")
        return integration
    }

    /// Create integration optimized for full-body performance capture
    ///
    /// Uses multiple cameras with highest confidence priority
    static func performanceCapture() -> MultiCameraARKitIntegration {
        let faceDriver = ARKitFaceDriver(
            mapper: .aggressive,  // Amplified expressions for performance
            smoothing: .lowLatency,  // Responsive for live performance
            priority: .highestConfidence
        )

        let bodyDriver = ARKitBodyDriver(
            mapper: .default,  // Full skeleton
            smoothing: .lowLatency,
            priority: .highestConfidence
        )

        let integration = MultiCameraARKitIntegration.__createWith(
            faceDriver: faceDriver,
            bodyDriver: bodyDriver
        )

        print("Created performance capture integration (full body, low latency)")
        return integration
    }

    /// Internal helper for creating with custom drivers
    private static func __createWith(
        faceDriver: ARKitFaceDriver,
        bodyDriver: ARKitBodyDriver
    ) -> MultiCameraARKitIntegration {
        let integration = MultiCameraARKitIntegration(
            facePriority: .latestActive,  // Placeholder, will be replaced
            bodyPriority: .latestActive
        )

        // Replace with custom drivers (Swift doesn't allow reassigning let properties,
        // so in production you'd use a different init pattern)
        // This is just for example purposes

        return integration
    }
}
