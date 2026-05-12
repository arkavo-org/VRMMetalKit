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


// VRMMetalKit - VRM 1.0 Model Loader and Renderer for Metal
//
// This package provides comprehensive support for loading and rendering
// VRM 1.0 avatars using Apple's Metal framework.

import Foundation
import Metal

/// Module facade exposing version metadata and convenience model-loading entry points.
///
/// VRMMetalKit is a Swift Package that loads VRM 1.0 (and 0.0 fallback) avatars, renders
/// them with an MToon-compliant non-photorealistic pipeline, plays VRMA animations with
/// humanoid retargeting, simulates SpringBone physics on the GPU, and drives expressions
/// and body pose from ARKit.
///
/// The struct itself is a namespace — there are no stored instances. Use the static
/// loaders to obtain a ``VRMModel``, then construct a ``VRMRenderer`` to render it,
/// or pair it with ``AnimationPlayer`` and ``VRMAnimationLoader`` for animation playback.
///
/// ## Entry Points
///
/// - ``VRMModel`` — the loaded avatar.
/// - ``VRMRenderer`` — the Metal-backed renderer.
/// - ``VRMAnimationLoader`` — loads VRMA animation files.
/// - ``AnimationPlayer`` — plays loaded animation clips against a model.
public struct VRMMetalKit {
    /// Package version string (semver).
    public static let version = "1.0.1"
    /// Build date stamp for the bundled shader library and runtime.
    public static let buildDate = "2026-01-18"
    /// Pre-compiled shader library version tag, baked into the `.metallib` resource.
    public static let shaderVersion = "v21-fix-stiffness-index"

    /// Initializes VRMMetalKit with a Metal device.
    ///
    /// Currently a no-op reserved for future global setup; calling it is safe and
    /// not required before loading a model.
    public static func initialize(device: MTLDevice) {
        // Future: Global initialization if needed
    }

    /// Logs version information to the console.
    ///
    /// The log line is only emitted when the package is built with the
    /// `VRM_METALKIT_ENABLE_LOGS` compilation flag.
    public static func logVersion() {
        #if VRM_METALKIT_ENABLE_LOGS
        vrmLog("Version: \(version) (\(buildDate)) Shader: \(shaderVersion)")
        #endif
    }

    /// Loads a VRM model from a file URL.
    ///
    /// Convenience wrapper around ``VRMModel/load(from:device:options:)`` for a file URL.
    public static func loadModel(from url: URL, device: MTLDevice? = nil) async throws -> VRMModel {
        return try await VRMModel.load(from: url, device: device)
    }

    /// Loads a VRM model from in-memory data.
    ///
    /// Convenience wrapper around ``VRMModel/load(from:filePath:device:)`` for raw `.vrm` bytes.
    public static func loadModel(from data: Data, device: MTLDevice? = nil) async throws -> VRMModel {
        return try await VRMModel.load(from: data, device: device)
    }
}

/// Short alias for ``VRMModel``.
public typealias VRM = VRMModel