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
import VRMMetalKit

/// Minimal working example for single-camera ARKit integration
///
/// This example demonstrates the simplest possible integration of VRMMetalKit's ARKit drivers
/// with ArkavoCreator's CameraMetadataEvent system. Suitable for single-camera scenarios
/// like iPhone Continuity Camera or local ARKit session.
///
/// Usage:
/// ```swift
/// let integration = BasicARKitIntegration()
/// integration.loadVRMModel(url: modelURL)
///
/// // In your camera event handler:
/// cameraSession.onMetadata = { event in
///     integration.handleCameraMetadata(event)
/// }
/// ```
class BasicARKitIntegration {
    // MARK: - Properties

    /// Face tracking driver (ARKit blend shapes → VRM expressions)
    let faceDriver: ARKitFaceDriver

    /// Body tracking driver (ARKit skeleton → VRM humanoid bones)
    let bodyDriver: ARKitBodyDriver

    /// VRM model to animate
    var vrmModel: VRMModel?

    // MARK: - Initialization

    init() {
        // Initialize face driver with default configuration
        // - mapper: .default covers all 18 VRM expressions
        // - smoothing: .default provides balanced latency/stability (EMA alpha=0.3)
        faceDriver = ARKitFaceDriver(
            mapper: .default,
            smoothing: .default
        )

        // Initialize body driver with default configuration
        // - mapper: .default maps full ARKit skeleton to VRM humanoid bones
        // - smoothing: .default for position/rotation
        // - priority: .latestActive uses most recent data (single camera = always latest)
        bodyDriver = ARKitBodyDriver(
            mapper: .default,
            smoothing: .default,
            priority: .latestActive
        )
    }

    // MARK: - VRM Model Loading

    /// Load a VRM model from file
    ///
    /// - Parameter url: URL to .vrm file
    /// - Throws: VRMLoaderError if model cannot be loaded
    func loadVRMModel(url: URL) throws {
        // Load VRM model using VRMMetalKit loader
        // (Assumes you have a Metal device available)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw VRMLoaderError.noMetalDevice
        }

        let loader = try VRMLoader(device: device)
        vrmModel = try loader.load(from: url)

        print("Loaded VRM model: \(vrmModel!.name ?? "Unnamed")")
        print("Expressions: \(vrmModel!.expressionController?.availableExpressions.count ?? 0)")
        print("Humanoid bones: \(vrmModel!.vrm?.humanoid.humanBones.count ?? 0)")
    }

    // MARK: - Camera Event Handling

    /// Handle incoming camera metadata event
    ///
    /// This is the main integration point. Call this from your camera event handler
    /// whenever new ARKit tracking data arrives.
    ///
    /// - Parameter event: CameraMetadataEvent from ArkavoCreator camera system
    func handleCameraMetadata(_ event: CameraMetadataEvent) {
        guard let vrm = vrmModel else {
            print("WARNING: No VRM model loaded")
            return
        }

        // Extract and update face tracking
        if let faceData = extractFaceBlendShapes(from: event) {
            faceDriver.update(
                blendShapes: faceData,
                controller: vrm.expressionController
            )
        }

        // Extract and update body tracking
        if let bodyData = extractBodySkeleton(from: event) {
            bodyDriver.update(
                skeleton: bodyData,
                nodes: vrm.nodes,
                humanoid: vrm.vrm?.humanoid
            )

            // Update world transforms after skeleton changes
            updateWorldTransforms(vrm: vrm)
        }
    }

    // MARK: - Data Extraction

    /// Extract ARKit face blend shapes from camera event
    ///
    /// Adapt this method to match your CameraMetadataEvent structure.
    /// This example assumes a nested `arkit` property with `faceBlendShapes`.
    ///
    /// - Parameter event: Camera metadata event
    /// - Returns: ARKitFaceBlendShapes if available, nil otherwise
    private func extractFaceBlendShapes(from event: CameraMetadataEvent) -> ARKitFaceBlendShapes? {
        // TODO: Adapt to your actual CameraMetadataEvent structure
        guard let shapes = event.arkit?.faceBlendShapes else { return nil }

        return ARKitFaceBlendShapes(
            timestamp: event.timestamp,
            shapes: shapes  // Dictionary<String, Float> of 52 ARKit shapes
        )
    }

    /// Extract ARKit body skeleton from camera event
    ///
    /// Adapt this method to match your CameraMetadataEvent structure.
    /// This example assumes a nested `arkit` property with `bodyJoints`.
    ///
    /// - Parameter event: Camera metadata event
    /// - Returns: ARKitBodySkeleton if available, nil otherwise
    private func extractBodySkeleton(from event: CameraMetadataEvent) -> ARKitBodySkeleton? {
        // TODO: Adapt to your actual CameraMetadataEvent structure
        guard let joints = event.arkit?.bodyJoints else { return nil }

        let confidence = event.arkit?.bodyTrackingConfidence ?? 0

        return ARKitBodySkeleton(
            timestamp: event.timestamp,
            joints: joints,  // Dictionary<ARKitJoint, simd_float4x4>
            isTracked: confidence > 0.5
        )
    }

    // MARK: - Transform Updates

    /// Update world transforms for all VRM nodes after skeleton changes
    ///
    /// This propagates the local transform changes made by the body driver
    /// through the node hierarchy to compute final world-space transforms.
    ///
    /// - Parameter vrm: VRM model with updated nodes
    private func updateWorldTransforms(vrm: VRMModel) {
        // Find root nodes (nodes with no parent)
        let rootNodes = vrm.nodes.filter { $0.parent == nil }

        // Update world transforms starting from roots
        for root in rootNodes {
            root.updateWorldTransform(parentTransform: nil)
        }
    }

    // MARK: - Statistics

    /// Print current driver statistics for debugging
    func printStatistics() {
        let faceStats = faceDriver.getStatistics()
        let bodyStats = bodyDriver.getStatistics()

        print("""
        === ARKit Driver Statistics ===
        Face Driver:
          - Total updates: \(faceStats.totalUpdates)
          - Skipped updates: \(faceStats.skippedUpdates)
          - Skip rate: \(String(format: "%.1f", faceStats.skipRate * 100))%

        Body Driver:
          - Update count: \(bodyStats.updateCount)
          - Last update: \(String(format: "%.3f", bodyStats.lastUpdateTime))s ago
        ===============================
        """)
    }

    /// Reset statistics for clean profiling
    func resetStatistics() {
        faceDriver.resetStatistics()
        bodyDriver.resetStatistics()
    }
}

// MARK: - Placeholder Types

/// Placeholder for ArkavoCreator's CameraMetadataEvent
///
/// Replace with your actual type. This shows the expected structure.
struct CameraMetadataEvent {
    let timestamp: TimeInterval
    let arkit: ARKitData?

    struct ARKitData {
        let faceBlendShapes: [String: Float]?
        let bodyJoints: [ARKitJoint: simd_float4x4]?
        let bodyTrackingConfidence: Float
    }
}

/// Placeholder for VRM loader error
enum VRMLoaderError: Error {
    case noMetalDevice
}
